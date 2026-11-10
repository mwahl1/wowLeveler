#!/usr/bin/env python3
"""Build Leveling Navigator's Data/*.lua from a QuestieDB Forever export.

Input:  the JSON export written by tools/questiedb_export.lua (Option A: QuestieDB's own
        loader and correction registry did all merging).
Output: Data/Schema.lua, Data/Meta.lua, Data/Neutral.lua, Data/Horde.lua, Data/Alliance.lua,
        docs/DATA_COVERAGE.md, docs/data-gaps.csv

Usage (from the repo root):
    python3 tools/build_data.py --export tools/.cache/forever --questiedb ~/wow-tools/QuestieDB

Data labels (stored per quest as a 4-letter string: requirements, start location,
finish location, XP):
    V  verified   confirmed in Forever by our own in-game recorder (none yet)
    O  observed   from a Forever-specific source: QuestieDB's Forever snapshot layer,
                  player-session traces, or Forever-specific fixes
    E  estimated  inherited from Classic Era data, assumed unchanged in Forever
    U  unknown    missing
"""

import argparse
import csv
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict

# --------------------------------------------------------------------------------------------
# Game constants (from QuestieDB src/corrections/enum/expansions.lua, Forever section)
# --------------------------------------------------------------------------------------------

RACES = {  # raceID -> (name, mask bit, faction)
    1: ("Human", 1, "Alliance"),
    3: ("Dwarf", 4, "Alliance"),
    4: ("Night Elf", 8, "Alliance"),
    7: ("Gnome", 64, "Alliance"),
    95: ("Skyborne", 2**32, "Alliance"),
    2: ("Orc", 2, "Horde"),
    5: ("Undead", 16, "Horde"),
    6: ("Tauren", 32, "Horde"),
    8: ("Troll", 128, "Horde"),
    96: ("Skyborne", 2**33, "Horde"),
}
FACTION_MASK = {
    f: sum(bit for _, bit, fac in RACES.values() if fac == f) for f in ("Horde", "Alliance")
}
CLASSES = {  # classFile -> mask bit (Classic classKeys; Forever falls back to Classic)
    "WARRIOR": 1, "PALADIN": 2, "HUNTER": 4, "ROGUE": 8, "PRIEST": 16,
    "SHAMAN": 64, "MAGE": 128, "WARLOCK": 256, "DRUID": 1024,
}
FACTIONS = ("Horde", "Alliance")

# Positional record layouts. Data/Schema.lua is generated from these, so Lua and Python
# can never disagree about an index.
QUEST_FIELDS = [
    "NAME", "REQ_LEVEL", "LEVEL", "RACES", "CLASSES", "START", "FINISH", "OBJ",
    "PRE_ALL", "PRE_ANY", "EXCLUSIVE", "NEXT", "BREADCRUMB_FOR", "MAP", "SORT", "XP",
    "LABELS", "FLAGS", "PARENT", "MAX_LEVEL", "SKILL", "SOURCE_ITEM", "TRIGGER",
    # M3.1 availability fields (docs/P2_GUIDE_ENGINE_SPEC.md 6.7 / 8a); append only
    "BREADCRUMBS", "DISABLED_BY", "AVAILABLE_UNTIL", "AVAILABLE_WITH", "MIN_REP", "MAX_REP",
    "REQ_SPELL", "REQ_SPEC", "REQ_RANKS",
]
# M3.1 field name -> QuestieDB field name (used for the coverage report)
AVAILABILITY_FIELDS = [
    ("BREADCRUMBS", "breadcrumbs"), ("DISABLED_BY", "disabledByQuest"),
    ("AVAILABLE_UNTIL", "availableUntilCompleted"), ("AVAILABLE_WITH", "availableStartingWith"),
    ("MIN_REP", "requiredMinRep"), ("MAX_REP", "requiredMaxRep"), ("REQ_SPELL", "requiredSpell"),
    ("REQ_SPEC", "requiredSpecialization"), ("REQ_RANKS", "requiredRanks"),
]
NPC_FIELDS = ["NAME", "MIN_LEVEL", "MAX_LEVEL", "RANK", "SPAWNS", "FRIENDLY", "LABEL"]
OBJECT_FIELDS = ["NAME", "SPAWNS", "LABEL"]
ITEM_FIELDS = ["NAME", "NPC_DROPS", "OBJECT_DROPS", "VENDORS"]

QUEST_FLAGS = {
    "NEW_FOREVER": 1,       # not in the Classic Era base data
    "REPEATABLE": 2,
    "BREADCRUMB": 4,
    "DYNAMIC": 8,           # changed by a faction-dependent correction
    "CLASS_DYNAMIC": 16,    # changed differently per class (see classQuests overrides)
    "PROFESSION": 32,       # requires a profession skill
    "NO_START_LOC": 64,
    "NO_FINISH_LOC": 128,
}
OBJ_KIND = {"npc": 1, "object": 2, "item": 3, "rep": 4, "killcredit": 5, "spell": 6}

MAX_SPAWNS_PER_MAP = 10
MAX_MAPS_PER_ENTITY = 3
CHUNK_RECORDS = 800

# --------------------------------------------------------------------------------------------
# Provenance helpers
# --------------------------------------------------------------------------------------------

def layer_kind(layer_name):
    """Classify a QuestieDB correction entry name like 'Forever/traces/foreverQuestTraces.lua:Load'."""
    if not layer_name:
        return "base"
    if layer_name.startswith("Forever/legacy/") or layer_name.startswith("Shared/"):
        return "era-fix"
    if layer_name.startswith("Forever/generated/"):
        return "forever-snapshot"
    if layer_name.startswith("Forever/traces/"):
        return "forever-trace"
    if layer_name.startswith("Forever/"):
        return "forever-fix"
    return "other"


def is_forever_layer(layer_name):
    return layer_kind(layer_name).startswith("forever")


# --------------------------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------------------------

def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def int_keys(d):
    return {int(k): v for k, v in d.items()}


def load_zone_names(questiedb_dir):
    """Area ID -> readable name, from QuestieDB's zone enum (text read only, never executed)."""
    names = {}
    path = os.path.join(questiedb_dir, "src", "corrections", "enum", "zones.lua")
    if not os.path.exists(path):
        return names
    with open(path, encoding="utf-8") as f:
        for m in re.finditer(r"^\s*([A-Z0-9_]+)\s*=\s*(\d+)\s*,", f.read(), re.M):
            area = int(m.group(2))
            names.setdefault(area, m.group(1).replace("_", " ").title())
    return names


def load_zone_bounds(questiedb_dir):
    """uiMapID -> zone rectangle in world yards (Forever build), from QuestieDB's
    data/Forever/conversion.json geometry.transforms[].target_bounds (plain JSON, read only).

    Returns (bounds, info): bounds = {uiMap: {left, right, top, bottom, width, height, name, changed}},
    info = {build, path, names}: names also covers maps without bounds (added/unsupported).
    """
    path = os.path.join(questiedb_dir, "data", "Forever", "conversion.json")
    info = {"build": None, "path": path, "names": {}, "error": None}
    if not os.path.exists(path):
        info["error"] = "conversion.json not found"
        return {}, info
    geo = load_json(path).get("geometry") or {}
    info["build"] = geo.get("target_build")
    for section in ("unsupported", "added_maps", "transforms"):
        for t in geo.get(section) or []:
            if t.get("ui_map_id"):
                info["names"][int(t["ui_map_id"])] = t.get("target_name") or t.get("source_name")
    bounds = {}
    for t in geo.get("transforms") or []:
        ui, b = t.get("ui_map_id"), t.get("target_bounds") or {}
        try:
            l, r, top, bot = (float(b[k]) for k in ("left", "right", "top", "bottom"))
        except (KeyError, TypeError, ValueError):
            continue
        if not ui or not all(math.isfinite(v) for v in (l, r, top, bot)):
            continue
        width, height = abs(l - r), abs(top - bot)
        if width <= 0 or height <= 0:
            continue
        bounds[int(ui)] = {"left": round(l, 1), "right": round(r, 1), "top": round(top, 1),
                           "bottom": round(bot, 1), "width": round(width, 1), "height": round(height, 1),
                           "name": t.get("target_name"), "changed": bool(t.get("changed"))}
    return bounds, info


def write_zone_bounds_json(path, bounds, info):
    out = {
        "source": f"QuestieDB conversion.json target_bounds, build {info['build']}",
        "label": "O",
        "units": "world yards; width = |left-right|, height = |top-bottom|",
        "maps": {str(ui): b for ui, b in sorted(bounds.items())},
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")


class Export:
    def __init__(self, export_dir):
        self.dir = export_dir
        self.manifest = load_json(os.path.join(export_dir, "manifest.json"))
        self.quests = int_keys(load_json(os.path.join(export_dir, "quests.json")))
        self.npcs = int_keys(load_json(os.path.join(export_dir, "npcs.json")))
        self.objects = int_keys(load_json(os.path.join(export_dir, "objects.json")))
        self.items = int_keys(load_json(os.path.join(export_dir, "items.json")))
        support = load_json(os.path.join(export_dir, "support.json"))
        self.xp = int_keys(support["questXP"])
        self.xp_traced = set(support.get("questXPTraced") or [])
        self.area_to_ui = int_keys(support["areaIdToUiMapId"])
        self.area_to_ui.update(int_keys(support["areaIdToUiMapIdOverride"]))
        self.sub_to_parent = int_keys(support["subZoneToParentZone"])
        self.sub_to_parent.update(int_keys(support["subZoneToParentZoneOverride"]))
        self.warnings = []
        prov_path = os.path.join(export_dir, "provenance.json")
        if os.path.exists(prov_path):
            prov = load_json(prov_path)
        else:
            # Older export: every quest is treated as new and every field as Era data
            self.warnings.append("provenance.json missing: labels are incomplete; re-run the export")
            prov = {"rawIds": {}, "lastStaticLayer": {}}
        self.raw_ids = defaultdict(set, {t: set(ids) for t, ids in prov["rawIds"].items()})
        self.last_layer = {t: int_keys(v) for t, v in prov["lastStaticLayer"].items()}
        dyn_path = os.path.join(export_dir, "dynamic.json")
        if os.path.exists(dyn_path):
            dyn = load_json(dyn_path)
        else:
            self.warnings.append("dynamic.json missing: faction/class corrections NOT applied; re-run the export")
            dyn = {}
        self.dynamic = {
            fac: {cls: {t: int_keys(rows) for t, rows in per_type.items()}
                  for cls, per_type in by_class.items()}
            for fac, by_class in dyn.items()
        }

    def field_layer(self, type_name, entity_id, field):
        return (self.last_layer.get(type_name, {}).get(entity_id) or {}).get(field)

    def ui_map(self, area_id):
        """Resolve a QuestieDB zone/area ID to an in-game uiMapID (None if unknown)."""
        if area_id is None:
            return None
        seen = set()
        a = area_id
        while a is not None and a not in seen:
            seen.add(a)
            ui = self.area_to_ui.get(a)
            if ui:
                return ui
            a = self.sub_to_parent.get(a)
        return None


# --------------------------------------------------------------------------------------------
# Dynamic corrections
# --------------------------------------------------------------------------------------------

def apply_overrides(record, diff):
    out = dict(record) if record else {}
    for field, value in diff.items():
        if field in ("__removed", "__new"):
            continue
        out[field] = value
    for field in diff.get("__removed", []):
        out.pop(field, None)
    return out


def resolve_dynamic(export, type_name, entity_id, base):
    """Return {faction: (record_for_faction, {class: record}|None, changed)}.

    Fields that are identical across all classes of a faction become the faction record;
    if any class differs, per-class records are returned as well.
    """
    result = {}
    for fac in FACTIONS:
        per_class = {}
        for cls in CLASSES:
            diff = export.dynamic.get(fac, {}).get(cls, {}).get(type_name, {}).get(entity_id)
            per_class[cls] = diff
        diffs = [json.dumps(d, sort_keys=True) for d in per_class.values()]
        changed = any(d is not None for d in per_class.values())
        if not changed:
            result[fac] = (base, None, False)
        elif len(set(diffs)) == 1:
            result[fac] = (apply_overrides(base, next(iter(per_class.values()))), None, True)
        else:
            classes = {cls: apply_overrides(base, d) if d else base for cls, d in per_class.items()}
            result[fac] = (base, classes, True)
    return result


# --------------------------------------------------------------------------------------------
# Spawns
# --------------------------------------------------------------------------------------------

def reduce_points(points, limit):
    """Deduplicate to a 0.5% grid, then farthest-point sample down to `limit` (deterministic)."""
    seen, uniq = set(), []
    for x, y in points:
        key = (round(x * 2), round(y * 2))
        if key not in seen:
            seen.add(key)
            uniq.append((x, y))
    if len(uniq) <= limit:
        return uniq
    cx = sum(p[0] for p in uniq) / len(uniq)
    cy = sum(p[1] for p in uniq) / len(uniq)
    chosen = [min(uniq, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2)]
    dist = [min((p[0] - c[0]) ** 2 + (p[1] - c[1]) ** 2 for c in chosen) for p in uniq]
    while len(chosen) < limit:
        i = max(range(len(uniq)), key=lambda k: dist[k])
        chosen.append(uniq[i])
        for k, p in enumerate(uniq):
            d = (p[0] - uniq[i][0]) ** 2 + (p[1] - uniq[i][1]) ** 2
            if d < dist[k]:
                dist[k] = d
    return chosen


def as_zone_map(v):
    """Area-keyed maps can arrive as JSON lists when area IDs are small (e.g. area 1)."""
    if not v:
        return {}
    if isinstance(v, list):
        return {i + 1: x for i, x in enumerate(v) if x is not None}
    return {int(k): x for k, x in v.items()}


def convert_spawns(export, spawns, stats):
    """{areaID: [[x, y, ...], ...]} -> flat {uiMap, x, y, uiMap, x, y, ...} (largest maps first)."""
    if not spawns:
        return None
    by_map = defaultdict(list)
    for area, coords in as_zone_map(spawns).items():
        ui = export.ui_map(area)
        if not ui:
            stats["unmapped_area"][int(area)] += 1
            continue
        for c in coords or []:
            if isinstance(c, list) and len(c) >= 2 and c[0] is not None and c[1] is not None:
                if c[0] < 0 or c[1] < 0:  # Questie uses -1,-1 for "somewhere inside an instance"
                    continue
                by_map[ui].append((float(c[0]), float(c[1])))
    if not by_map:
        return None
    flat = []
    ordered = sorted(by_map.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:MAX_MAPS_PER_ENTITY]
    for ui, points in ordered:
        for x, y in reduce_points(points, MAX_SPAWNS_PER_MAP):
            flat.extend([ui, round(x, 1), round(y, 1)])
    return flat


# --------------------------------------------------------------------------------------------
# Record builders
# --------------------------------------------------------------------------------------------

def nonempty(v):
    return v if v else None


def rep_pair(v):
    """QuestieDB {factionID, value} -> [factionID, value], or None when empty/absent."""
    if v and len(v) >= 2 and v[0]:
        return [v[0], v[1]]
    return None


def build_objectives(objs, refs):
    """QuestieDB objectives -> compact list of {kind, id[, extra]}; collects referenced IDs."""
    if not objs:
        return None
    out = []
    creatures, objects, items, rep, killcredit, spells = (list(objs) + [None] * 6)[:6]
    for o in creatures or []:
        if o and o[0] is not None:
            out.append([OBJ_KIND["npc"], o[0]])
            refs["npc"].add(o[0])
    for o in objects or []:
        if o and o[0] is not None:
            out.append([OBJ_KIND["object"], o[0]])
            refs["object"].add(o[0])
    for o in items or []:
        if o and o[0] is not None:
            out.append([OBJ_KIND["item"], o[0]])
            refs["item"].add(o[0])
    if rep and len(rep) >= 2:
        out.append([OBJ_KIND["rep"], rep[0], rep[1]])
    for o in killcredit or []:
        if o and o[0]:
            ids = [i for i in o[0] if i is not None]
            out.append([OBJ_KIND["killcredit"], ids, o[1] if len(o) > 1 else None])
            refs["npc"].update(ids)
    for o in spells or []:
        if o and o[0] is not None:
            out.append([OBJ_KIND["spell"], o[0]])
    return out or None


def quest_faction(q, export):
    """Which factions can do this quest: subset of {'Horde', 'Alliance'}."""
    races = q.get("requiredRaces") or 0
    if races:
        return {f for f in FACTIONS if races & FACTION_MASK[f]}
    # No race restriction: use the starter NPCs' friendliness when every starter agrees
    starters = (q.get("startedBy") or [None])[0] or []
    friendly = set()
    for npc_id in starters:
        f = (export.npcs.get(npc_id) or {}).get("friendlyToFaction")
        if not f:
            return set(FACTIONS)
        friendly.add(f)
    if friendly == {"H"}:
        return {"Horde"}
    if friendly == {"A"}:
        return {"Alliance"}
    return set(FACTIONS)


def location_label(export, entity_ids, type_name):
    """Label for where an NPC/object list is: best label among entities with coordinates."""
    best = "U"
    for eid in entity_ids or []:
        rec = (export.npcs if type_name == "Npc" else export.objects).get(eid)
        if not rec or not rec.get("spawns"):
            continue
        layer = export.field_layer(type_name, eid, "spawns")
        label = "O" if is_forever_layer(layer) else "E"
        if label == "O":
            return "O"
        best = "E"
    return best


def build_quest(qid, q, export, refs):
    starts = q.get("startedBy") or []
    finishes = q.get("finishedBy") or []
    start_npcs, start_objs, start_items = (list(starts) + [None] * 3)[:3]
    fin_npcs, fin_objs = (list(finishes) + [None] * 2)[:2]
    for i in start_npcs or []: refs["npc"].add(i)
    for i in fin_npcs or []: refs["npc"].add(i)
    for i in start_objs or []: refs["object"].add(i)
    for i in fin_objs or []: refs["object"].add(i)
    for i in start_items or []: refs["item"].add(i)
    if q.get("sourceItemId"):
        refs["item"].add(q["sourceItemId"])

    zone = q.get("zoneOrSort")
    ui_map = export.ui_map(zone) if zone and zone > 0 else None
    sort = zone if zone and zone < 0 else None

    trigger = None
    trig = q.get("triggerEnd")
    if trig and len(trig) >= 2 and trig[1]:
        for area, coords in as_zone_map(trig[1]).items():
            ui = export.ui_map(area)
            if ui and coords and coords[0] and len(coords[0]) >= 2:
                trigger = [trig[0], ui, round(coords[0][0], 1), round(coords[0][1], 1)]
                break

    xp_entry = export.xp.get(qid)
    xp = xp_entry[1] if xp_entry and len(xp_entry) > 1 else None

    # Labels: requirements / start location / finish location / XP
    new = qid not in export.raw_ids["Quest"]
    req_fields = ("name", "requiredLevel", "questLevel", "requiredRaces", "requiredClasses",
                  "preQuestGroup", "preQuestSingle", "objectives")
    req_label = "O" if new or any(is_forever_layer(export.field_layer("Quest", qid, f)) for f in req_fields) else "E"
    start_label = location_label(export, start_npcs, "Npc")
    if start_label == "U":
        start_label = location_label(export, start_objs, "Object")
    if start_label == "U" and start_items:
        start_label = "E"  # item-started: location comes from the item's drop sources
    finish_label = location_label(export, fin_npcs, "Npc")
    if finish_label == "U":
        finish_label = location_label(export, fin_objs, "Object")
    xp_label = "U" if xp is None else ("O" if qid in export.xp_traced else "E")

    flags = 0
    if new: flags |= QUEST_FLAGS["NEW_FOREVER"]
    if (q.get("specialFlags") or 0) & 1: flags |= QUEST_FLAGS["REPEATABLE"]
    if q.get("breadcrumbForQuestId"): flags |= QUEST_FLAGS["BREADCRUMB"]
    if q.get("requiredSkill"): flags |= QUEST_FLAGS["PROFESSION"]
    if start_label == "U": flags |= QUEST_FLAGS["NO_START_LOC"]
    if finish_label == "U": flags |= QUEST_FLAGS["NO_FINISH_LOC"]

    record = {
        "NAME": q.get("name"),
        "REQ_LEVEL": q.get("requiredLevel"),
        "LEVEL": q.get("questLevel"),
        "RACES": q.get("requiredRaces") or None,
        "CLASSES": q.get("requiredClasses") or None,
        "START": [nonempty(start_npcs), nonempty(start_objs), nonempty(start_items)]
                 if (start_npcs or start_objs or start_items) else None,
        "FINISH": [nonempty(fin_npcs), nonempty(fin_objs)] if (fin_npcs or fin_objs) else None,
        "OBJ": build_objectives(q.get("objectives"), refs),
        "PRE_ALL": nonempty(q.get("preQuestGroup")),
        "PRE_ANY": nonempty(q.get("preQuestSingle")),
        "EXCLUSIVE": nonempty(q.get("exclusiveTo")),
        "NEXT": q.get("nextQuestInChain") or None,
        "BREADCRUMB_FOR": q.get("breadcrumbForQuestId") or None,
        "MAP": ui_map,
        "SORT": sort,
        "XP": xp,
        "LABELS": req_label + start_label + finish_label + xp_label,
        "FLAGS": flags,
        "PARENT": q.get("parentQuest") or None,
        "MAX_LEVEL": q.get("requiredMaxLevel") or None,
        "SKILL": nonempty(q.get("requiredSkill")),
        "SOURCE_ITEM": q.get("sourceItemId") or None,
        "TRIGGER": trigger,
        "BREADCRUMBS": nonempty(q.get("breadcrumbs")),
        "DISABLED_BY": q.get("disabledByQuest") or None,
        "AVAILABLE_UNTIL": q.get("availableUntilCompleted") or None,
        "AVAILABLE_WITH": q.get("availableStartingWith") or None,
        "MIN_REP": rep_pair(q.get("requiredMinRep")),
        "MAX_REP": rep_pair(q.get("requiredMaxRep")),
        "REQ_SPELL": q.get("requiredSpell") or None,  # sign kept: negative = must NOT know
        "REQ_SPEC": q.get("requiredSpecialization") or None,
        "REQ_RANKS": nonempty(q.get("requiredRanks")),
    }
    return record


def build_npc(nid, n, export, stats):
    layer = export.field_layer("Npc", nid, "spawns")
    spawns = convert_spawns(export, n.get("spawns"), stats)
    return {
        "NAME": n.get("name"),
        "MIN_LEVEL": n.get("minLevel"),
        "MAX_LEVEL": n.get("maxLevel"),
        "RANK": n.get("rank") or None,
        "SPAWNS": spawns,
        "FRIENDLY": n.get("friendlyToFaction"),
        "LABEL": "U" if not spawns else ("O" if is_forever_layer(layer) else "E"),
    }


def build_object(oid, o, export, stats):
    layer = export.field_layer("Object", oid, "spawns")
    spawns = convert_spawns(export, o.get("spawns"), stats)
    return {
        "NAME": o.get("name"),
        "SPAWNS": spawns,
        "LABEL": "U" if not spawns else ("O" if is_forever_layer(layer) else "E"),
    }


def build_item(iid, it, refs):
    npc_drops = nonempty(it.get("npcDrops"))
    obj_drops = nonempty(it.get("objectDrops"))
    vendors = nonempty(it.get("vendors"))
    for i in npc_drops or []: refs["npc"].add(i)
    for i in obj_drops or []: refs["object"].add(i)
    for i in vendors or []: refs["npc"].add(i)
    return {"NAME": it.get("name"), "NPC_DROPS": npc_drops, "OBJECT_DROPS": obj_drops, "VENDORS": vendors}


def to_positional(record, fields):
    values = [record.get(f) for f in fields]
    while values and values[-1] is None:
        values.pop()
    return values


# --------------------------------------------------------------------------------------------
# Lua serialization
# --------------------------------------------------------------------------------------------

LUA_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if",
                "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


def lua_number(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if math.isnan(v) or math.isinf(v):
        raise ValueError("non-finite number")
    if v == int(v) and abs(v) < 2**53:
        return str(int(v))
    s = f"{v:.10g}"
    return s


def lua_string(s):
    out = ['"']
    for ch in s:
        if ch == '"': out.append('\\"')
        elif ch == "\\": out.append("\\\\")
        elif ch == "\n": out.append("\\n")
        elif ch == "\r": out.append("\\r")
        elif ord(ch) < 32: out.append("\\%03d" % ord(ch))
        else: out.append(ch)
    out.append('"')
    return "".join(out)


def to_lua(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return lua_number(v)
    if isinstance(v, str):
        return lua_string(v)
    if isinstance(v, (list, tuple)):
        items = list(v)
        while items and items[-1] is None:
            items.pop()
        return "{" + ",".join(to_lua(x) for x in items) + "}"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v, key=lambda k: (isinstance(k, str), k)):
            val = v[k]
            if isinstance(k, int):
                parts.append(f"[{k}]={to_lua(val)}")
            elif LUA_IDENT.match(k) and k not in LUA_KEYWORDS:
                parts.append(f"{k}={to_lua(val)}")
            else:
                parts.append(f"[{lua_string(k)}]={to_lua(val)}")
        return "{" + ",".join(parts) + "}"
    raise TypeError(f"cannot serialize {type(v)}")


def long_bracket(text):
    level = 0
    while ("]" + "=" * level + "]") in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[{text}]{eq}]"


def chunk_strings(table):
    """Split an id->record table into 'return {...}' source strings of CHUNK_RECORDS each."""
    ids = sorted(table)
    for start in range(0, len(ids), CHUNK_RECORDS):
        part = ids[start:start + CHUNK_RECORDS]
        body = ",\n".join(f"[{i}]={to_lua(table[i])}" for i in part)
        yield "return {\n" + body + "\n}"


# --------------------------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------------------------

def build(export, zone_names):
    stats = {"unmapped_area": Counter()}
    issues = []

    # 1. Per-faction final quest records (static + faction/class dynamic corrections)
    per_faction = {f: {"quests": {}, "classQuests": defaultdict(dict),
                       "refs": {"npc": set(), "object": set(), "item": set()}} for f in FACTIONS}
    dynamic_counts = Counter()
    class_dynamic_quests = set()

    for qid, q in export.quests.items():
        resolved = resolve_dynamic(export, "Quest", qid, q)
        for fac in FACTIONS:
            fac_q, class_variants, changed = resolved[fac]
            if fac not in quest_faction(fac_q, export):
                continue
            bucket = per_faction[fac]
            rec = build_quest(qid, fac_q, export, bucket["refs"])
            if changed:
                rec["FLAGS"] |= QUEST_FLAGS["DYNAMIC"]
                dynamic_counts[fac] += 1
            if class_variants:
                rec["FLAGS"] |= QUEST_FLAGS["CLASS_DYNAMIC"]
                class_dynamic_quests.add(qid)
                base_pos = to_positional(rec, QUEST_FIELDS)
                for cls, cls_q in class_variants.items():
                    cls_rec = build_quest(qid, cls_q, export, bucket["refs"])
                    cls_rec["FLAGS"] = rec["FLAGS"]
                    cls_pos = to_positional(cls_rec, QUEST_FIELDS)
                    # Store only the indexes that differ; false means "clear this field"
                    delta = {}
                    for i in range(max(len(base_pos), len(cls_pos))):
                        a = base_pos[i] if i < len(base_pos) else None
                        b = cls_pos[i] if i < len(cls_pos) else None
                        if a != b:
                            delta[i + 1] = b if b is not None else False
                    if delta:
                        bucket["classQuests"][cls][qid] = delta
            bucket["quests"][qid] = to_positional(rec, QUEST_FIELDS)

    # 2. Items referenced by each faction's quests, then NPCs/objects (incl. item sources)
    for fac in FACTIONS:
        bucket = per_faction[fac]
        refs = bucket["refs"]
        bucket["items"] = {}
        for iid in sorted(refs["item"]):
            it = export.items.get(iid)
            if it is None:
                issues.append(("missing-item", fac, iid, "referenced by a quest but not in QuestieDB"))
                continue
            it_fac = resolve_dynamic(export, "Item", iid, it)[fac][0]
            bucket["items"][iid] = to_positional(build_item(iid, it_fac, refs), ITEM_FIELDS)
        bucket["npcs"] = {}
        for nid in sorted(refs["npc"]):
            n = export.npcs.get(nid)
            if n is None:
                issues.append(("missing-npc", fac, nid, "referenced but not in QuestieDB"))
                continue
            n_fac = resolve_dynamic(export, "Npc", nid, n)[fac][0]
            bucket["npcs"][nid] = to_positional(build_npc(nid, n_fac, export, stats), NPC_FIELDS)
        bucket["objects"] = {}
        for oid in sorted(refs["object"]):
            o = export.objects.get(oid)
            if o is None:
                issues.append(("missing-object", fac, oid, "referenced but not in QuestieDB"))
                continue
            o_fac = resolve_dynamic(export, "Object", oid, o)[fac][0]
            bucket["objects"][oid] = to_positional(build_object(oid, o_fac, export, stats), OBJECT_FIELDS)

    # 3. Partition: identical records available to both factions go into Neutral
    sides = {"Neutral": {}, "Horde": {}, "Alliance": {}}
    for kind in ("quests", "npcs", "objects", "items"):
        h, a = per_faction["Horde"][kind], per_faction["Alliance"][kind]
        neutral, only_h, only_a = {}, {}, {}
        for i in set(h) | set(a):
            if i in h and i in a and h[i] == a[i]:
                neutral[i] = h[i]
            else:
                if i in h: only_h[i] = h[i]
                if i in a: only_a[i] = a[i]
        sides["Neutral"][kind], sides["Horde"][kind], sides["Alliance"][kind] = neutral, only_h, only_a
    for fac in FACTIONS:
        sides[fac]["classQuests"] = {cls: dict(rows) for cls, rows in per_faction[fac]["classQuests"].items()}

    # 4. Referential integrity on the final per-faction view
    qi = {n: i for i, n in enumerate(QUEST_FIELDS)}
    for fac in FACTIONS:
        quests = per_faction[fac]["quests"]
        for qid, rec in quests.items():
            def get(name):
                i = qi[name]
                return rec[i] if i < len(rec) else None
            for pre in (get("PRE_ALL") or []) + (get("PRE_ANY") or []):
                if pre < 0:
                    issues.append(("negative-prereq", fac, qid, f"prerequisite {pre}: Questie convention, not interpreted yet"))
                elif pre not in quests and pre not in export.quests:
                    issues.append(("missing-prereq", fac, qid, f"prerequisite {pre} not in QuestieDB"))
            for ref in get("BREADCRUMBS") or []:
                if ref not in quests and ref not in export.quests:
                    issues.append(("missing-breadcrumb", fac, qid, f"breadcrumb {ref} not in QuestieDB"))
            for name in ("DISABLED_BY", "AVAILABLE_UNTIL", "AVAILABLE_WITH"):
                ref = get(name)
                if ref and ref not in quests and ref not in export.quests:
                    issues.append(("missing-availability-quest", fac, qid, f"{name} {ref} not in QuestieDB"))
            if not get("NAME"):
                issues.append(("missing-name", fac, qid, "quest has no name"))
            if get("REQ_LEVEL") is None:
                issues.append(("missing-level", fac, qid, "quest has no required level"))

    # 5. Starting zones and quests per race, derived from the data:
    #    the starting zone is the most common zone among level-1 quests restricted to a subset
    #    of the faction that includes this race (e.g. the "Welcome!" quests); the starting
    #    quests are that zone's level-1, prerequisite-free, NPC-started quests the race can take.
    starts = {}
    area_of = {qid: (q.get("zoneOrSort") or 0) for qid, q in export.quests.items()}
    for race_id, (race_name, bit, fac) in RACES.items():
        quests = per_faction[fac]["quests"]
        zones = Counter()
        for qid, rec in quests.items():
            races = rec[qi["RACES"]] if qi["RACES"] < len(rec) else None
            req = rec[qi["REQ_LEVEL"]] if qi["REQ_LEVEL"] < len(rec) else None
            if races and races & bit and races != FACTION_MASK[fac] and (req or 0) <= 1 and area_of.get(qid, 0) > 0:
                zones[area_of[qid]] += 1
        if not zones:
            starts[race_id] = {"quests": []}
            issues.append(("no-start-zone", fac, race_id, f"{race_name}: no race-specific level-1 quest found"))
            continue
        area = zones.most_common(1)[0][0]
        start_map = export.ui_map(area)
        found = []
        for qid, rec in quests.items():
            def get(name, rec=rec):
                i = qi[name]
                return rec[i] if i < len(rec) else None
            races = get("RACES")
            start = get("START")
            if get("MAP") == start_map and (get("REQ_LEVEL") or 0) <= 1 and not get("PRE_ALL") \
                    and not get("PRE_ANY") and (not races or races & bit) and start and start[0]:
                found.append(qid)
        starts[race_id] = {"area": area, "map": export.ui_map(area), "quests": sorted(found)}

    return sides, per_faction, starts, issues, stats, dynamic_counts, class_dynamic_quests


# --------------------------------------------------------------------------------------------
# Writers
# --------------------------------------------------------------------------------------------

HEADER = "-- Generated by tools/build_data.py from QuestieDB {commit}. Do not edit by hand.\n" \
         "-- Data: QuestieDB (GPLv3), https://github.com/Questie/QuestieDB\n"


def write_schema(path, commit):
    lines = [HEADER.format(commit=commit), "local _, ns = ...", "local S = {}", "ns.DataSchema = S", ""]
    for name, fields in (("Q", QUEST_FIELDS), ("NPC", NPC_FIELDS), ("OBJ", OBJECT_FIELDS), ("ITEM", ITEM_FIELDS)):
        lines.append(f"S.{name} = {{ " + ", ".join(f"{f} = {i + 1}" for i, f in enumerate(fields)) + " }")
    lines.append("S.QUEST_FLAGS = " + to_lua(QUEST_FLAGS))
    lines.append("S.OBJ_KIND = " + to_lua({k.upper(): v for k, v in OBJ_KIND.items()}))
    lines.append("-- raceID -> requiredRaces bit. Bits 32/33 exceed the 32-bit `bit` library:")
    lines.append("-- test with math.floor(mask / bit) % 2 == 1, never bit.band.")
    lines.append("S.RACE_BIT = " + to_lua({rid: bit for rid, (_, bit, _) in RACES.items()}))
    lines.append("S.CLASS_BIT = " + to_lua(CLASSES))
    lines.append("S.LABELS = { V = \"verified\", O = \"observed\", E = \"estimated\", U = \"unknown\" }")
    lines.append("-- LABELS string positions: 1 requirements, 2 start location, 3 finish location, 4 XP")
    lines.append("-- SPAWNS are flat triples: uiMapID, x, y, uiMapID, x, y, ... (x/y in 0-100)")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_meta(path, export, starts, counts, zone_bounds, bounds_info):
    m = export.manifest
    meta = {
        "questiedbCommit": m.get("questiedbCommit"),
        "exportedAt": m.get("exportedAt"),
        "interface": m.get("interface"),
        "counts": counts,
        "startingQuests": starts,
        # uiMapID -> {left, right, top, bottom} in world yards (label O: Forever map geometry)
        "zoneBounds": {ui: {k: b[k] for k in ("left", "right", "top", "bottom")}
                       for ui, b in zone_bounds.items()},
        "zoneBoundsSource": f"QuestieDB conversion.json target_bounds, build {bounds_info['build']}",
    }
    with open(path, "w", encoding="utf-8") as f:
        f.write(HEADER.format(commit=m.get("questiedbCommit", "?")[:10]))
        f.write("local _, ns = ...\nns.DataMeta = " + to_lua(meta) + "\n")


def write_side(path, side, tables, commit):
    with open(path, "w", encoding="utf-8") as f:
        f.write(HEADER.format(commit=commit))
        f.write("-- Each chunk is compiled at login only if it matches the player's faction.\n")
        f.write("local _, ns = ...\nlocal add = ns.Data.AddChunk\n")
        for kind in ("quests", "npcs", "objects", "items"):
            for src in chunk_strings(tables.get(kind, {})):
                f.write(f'add("{side}", "{kind}", {long_bracket(src)})\n')
        for cls, rows in sorted((tables.get("classQuests") or {}).items()):
            if rows:
                f.write(f'add("{side}", "classQuests:{cls}", {long_bracket("return " + to_lua(rows))})\n')


# --------------------------------------------------------------------------------------------
# Reports
# --------------------------------------------------------------------------------------------

def write_reports(report_md, gaps_csv, export, sides, per_faction, starts, issues, stats,
                  dynamic_counts, class_dynamic_quests, zone_names, sizes, zone_bounds, bounds_info):
    qi = {n: i for i, n in enumerate(QUEST_FIELDS)}

    def field(rec, name):
        i = qi[name]
        return rec[i] if i < len(rec) else None

    # All quests available to at least one faction, by id (first faction view wins)
    allq = {}
    for fac in FACTIONS:
        for qid, rec in per_faction[fac]["quests"].items():
            allq.setdefault(qid, rec)

    def zone_label(rec):
        ui = field(rec, "MAP")
        q = export.quests.get(rec_id_lookup.get(id(rec)), {})
        area = q.get("zoneOrSort")
        if area and area > 0:
            return zone_names.get(area, f"area {area}")
        if area and area < 0:
            return f"sort {area}"
        return "no zone"

    rec_id_lookup = {id(rec): qid for qid, rec in allq.items()}

    label_counts = [Counter() for _ in range(4)]
    for rec in allq.values():
        for i, ch in enumerate(field(rec, "LABELS") or "UUUU"):
            label_counts[i][ch] += 1

    new_ids = [qid for qid, rec in allq.items() if (field(rec, "FLAGS") or 0) & QUEST_FLAGS["NEW_FOREVER"]]
    new_set = set(new_ids)
    old_ids = [qid for qid in allq if qid not in new_set]

    def gap_stats(ids):
        c = Counter()
        for qid in ids:
            rec = allq[qid]
            labels = field(rec, "LABELS") or "UUUU"
            c["total"] += 1
            c["no XP"] += labels[3] == "U"
            c["no start location"] += labels[1] == "U"
            c["no finish location"] += labels[2] == "U"
            c["no starter at all"] += field(rec, "START") is None
            c["no finisher at all"] += field(rec, "FINISH") is None
        return c

    new_gaps, old_gaps = gap_stats(new_ids), gap_stats(old_ids)

    # Gap CSV: every quest with an unknown label, new Forever content first
    rows = []
    for qid in sorted(allq, key=lambda q: (q not in new_set, q)):
        rec = allq[qid]
        labels = field(rec, "LABELS") or "UUUU"
        if "U" in labels:
            factions = "/".join(f for f in FACTIONS if qid in per_faction[f]["quests"])
            rows.append([qid, field(rec, "NAME"), "new" if qid in new_set else "classic",
                         factions, field(rec, "REQ_LEVEL"), field(rec, "LEVEL"), zone_label(rec),
                         labels[3] == "U", labels[1] == "U", labels[2] == "U", labels])
    with open(gaps_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["questID", "name", "content", "factions", "reqLevel", "questLevel", "zone",
                    "missingXP", "missingStartLoc", "missingFinishLoc", "labels"])
        w.writerows(rows)

    # Zones with the most gaps in new content
    zone_gap = Counter()
    for qid in new_ids:
        rec = allq[qid]
        if "U" in (field(rec, "LABELS") or "UUUU"):
            zone_gap[zone_label(rec)] += 1

    m = export.manifest
    out = []
    w = out.append
    w("# Data coverage report\n")
    w(f"Generated by `tools/build_data.py` from QuestieDB `{m.get('questiedbCommit', '?')[:10]}` "
      f"(exported {m.get('exportedAt')}, {m.get('correctionsApplied')} static corrections). "
      "Regenerate after every QuestieDB update. Full gap list: [`data-gaps.csv`](data-gaps.csv).\n")
    w("## Labels\n")
    w("| Label | Meaning |\n|---|---|")
    w("| **V** verified | Confirmed in Forever by our own in-game recorder (none yet: the recorder is not wired into the build) |")
    w("| **O** observed | From a Forever-specific source: QuestieDB's Forever snapshot layer, player-session traces, or Forever fixes |")
    w("| **E** estimated | Inherited from Classic Era data and assumed unchanged in Forever |")
    w("| **U** unknown | Missing |\n")
    w("## Totals\n")
    w("| | Neutral (both factions) | Horde only | Alliance only |\n|---|---|---|---|")
    for kind in ("quests", "npcs", "objects", "items"):
        w(f"| {kind} | {len(sides['Neutral'][kind])} | {len(sides['Horde'][kind])} | {len(sides['Alliance'][kind])} |")
    w("")
    w(f"Quests available to at least one faction: **{len(allq)}** "
      f"({len(old_ids)} Classic-origin, {len(new_ids)} new Forever content). "
      f"Quests in the export but available to neither faction (e.g. race-locked to non-playable races): "
      f"{len(export.quests) - len(allq)}.\n")
    w("## Label distribution (all available quests)\n")
    w("| Field | V | O | E | U |\n|---|---|---|---|---|")
    for i, name in enumerate(("Requirements", "Start location", "Finish location", "XP")):
        c = label_counts[i]
        w(f"| {name} | {c['V']} | {c['O']} | {c['E']} | {c['U']} |")
    w("")
    w("## Gaps\n")
    w("| | New Forever quests | Classic-origin quests |\n|---|---|---|")
    for key in ("total", "no XP", "no start location", "no finish location", "no starter at all", "no finisher at all"):
        w(f"| {key} | {new_gaps[key]} | {old_gaps[key]} |")
    w("")
    w("Zones with the most incomplete new Forever quests:\n")
    w("| Zone | Incomplete quests |\n|---|---|")
    for zone, n in zone_gap.most_common(15):
        w(f"| {zone} | {n} |")
    w("")
    w("## Availability fields\n")
    w("Quests (available to at least one faction) using each M3.1 availability field "
      "(spec section 6.7). Empty values in QuestieDB are stored as absent.\n")
    w("| Field | QuestieDB field | Quests |\n|---|---|---|")
    for name, qdb_name in AVAILABILITY_FIELDS:
        n = sum(1 for rec in allq.values() if field(rec, name) is not None)
        w(f"| `{name}` | `{qdb_name}` | {n} |")
    w("")
    w("## Starting zones by race\n")
    w("Derived from the data (race-specific level-1 quests → zone → that zone's level-1 quests); nothing hand-entered.\n")
    w("| Race | Faction | Zone | uiMap | Starting quests |\n|---|---|---|---|---|")
    for race_id, (race_name, _, fac) in RACES.items():
        st = starts.get(race_id) or {}
        qs = st.get("quests") or []
        names = ", ".join(f"{q} {per_faction[fac]['quests'][q][0]}" for q in qs[:5])
        more = f" (+{len(qs) - 5} more)" if len(qs) > 5 else ""
        zone = zone_names.get(st.get("area"), f"area {st.get('area')}") if st.get("area") else "**not found**"
        w(f"| {race_name} | {fac} | {zone} | {st.get('map') or '-'} | {names or '**none found**'}{more} |")
    w("")
    w("## Zone sizes (world yards)\n")
    w(f"Source: QuestieDB `data/Forever/conversion.json` `geometry.transforms[].target_bounds`, "
      f"build {bounds_info['build']} (read as plain JSON). Label **O**: Forever map geometry. "
      f"Stored in `Data/Meta.lua` (`zoneBounds`) and `tools/.cache/forever/zone_bounds.json` (with width/height).\n")
    if bounds_info.get("error"):
        w(f"**Not available:** {bounds_info['error']}.\n")
    w(f"Maps with bounds: **{len(zone_bounds)}**.\n")
    # uiMaps the data actually uses: quest MAP / TRIGGER, NPC and object spawns
    used = Counter()
    for fac in FACTIONS:
        b = per_faction[fac]
        for rec in b["quests"].values():
            if field(rec, "MAP"):
                used[field(rec, "MAP")] += 1
            trig = field(rec, "TRIGGER")
            if trig:
                used[trig[1]] += 1
        for kind, fields in (("npcs", NPC_FIELDS), ("objects", OBJECT_FIELDS)):
            si = fields.index("SPAWNS")
            for rec in b[kind].values():
                sp = rec[si] if si < len(rec) else None
                for ui in set((sp or [])[0::3]):
                    used[ui] += 1
    missing = sorted((ui for ui in used if ui not in zone_bounds), key=lambda u: -used[u])
    ui_names = dict(bounds_info["names"])
    for area, ui in sorted(export.area_to_ui.items()):
        if area in zone_names:
            ui_names.setdefault(ui, zone_names[area])
    w(f"uiMaps used by quests (zone/trigger) or NPC/object spawns with **no bounds**: {len(missing)}\n")
    if missing:
        w("| uiMap | Name | References |\n|---|---|---|")
        for ui in missing:
            w(f"| {ui} | {ui_names.get(ui) or '?'} | {used[ui]} |")
        w("")
    w("## Faction and class corrections\n")
    w(f"Applied with QuestieDB's own registry for every faction x class combination "
      f"(errors during export: {m.get('dynamicErrors', '?')}).\n")
    w(f"- Quests changed by faction corrections: Horde {dynamic_counts['Horde']}, Alliance {dynamic_counts['Alliance']}")
    w(f"- Quests whose corrections differ by class (stored as per-class overrides): {len(class_dynamic_quests)}")
    w("- Derived passes are not re-run after dynamic corrections (same as Questie's in-game overlay).\n")
    w("## Integrity checks\n")
    by_kind = Counter(i[0] for i in issues)
    if not issues:
        w("No issues found.\n")
    else:
        w("| Issue | Count |\n|---|---|")
        for k, n in by_kind.most_common():
            w(f"| {k} | {n} |")
        w("\nFirst examples:\n")
        for kind in by_kind:
            for i in [x for x in issues if x[0] == kind][:5]:
                w(f"- `{i[0]}` {i[1]} {i[2]}: {i[3]}")
        w("")
    unmapped = stats["unmapped_area"]
    w(f"Spawn coordinates dropped because their area has no in-game map ID: "
      f"{sum(unmapped.values())} points across {len(unmapped)} areas"
      + (" (top: " + ", ".join(f"{zone_names.get(a, a)} x{n}" for a, n in unmapped.most_common(5)) + ")" if unmapped else "") + ".\n")
    w("## Generated files\n")
    w("| File | Size |\n|---|---|")
    for name, size in sizes:
        w(f"| `{name}` | {size / 1024:.0f} KB |")
    w("")
    with open(report_md, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return new_gaps, old_gaps, label_counts, len(allq), len(new_ids)


# --------------------------------------------------------------------------------------------
# Validation of generated Lua (parse only, nothing executed)
# --------------------------------------------------------------------------------------------

def validate_lua(paths):
    try:
        from luaparser import ast  # optional dependency: pip install luaparser
    except ImportError:
        return None, "luaparser not installed; skipped (run tools/validate_data.lua with Lua 5.1)"
    errors = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        try:
            ast.parse(text)
        except Exception as e:  # noqa: BLE001 - report every parse failure
            errors.append(f"{path}: {str(e)[:200]}")
            continue
        for m in re.finditer(r"\[(=*)\[(return .*?)\]\1\]", text, re.S):
            try:
                ast.parse(m.group(2))
            except Exception as e:  # noqa: BLE001
                errors.append(f"{path} chunk: {str(e)[:200]}")
    return errors, None


# --------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--export", default="tools/.cache/forever", help="QuestieDB export directory")
    ap.add_argument("--questiedb", default=os.path.expanduser("~/wow-tools/QuestieDB"),
                    help="QuestieDB checkout (zone names only)")
    ap.add_argument("--out", default="Data", help="output directory for Data/*.lua")
    ap.add_argument("--docs", default="docs", help="output directory for the coverage report")
    ap.add_argument("--parse-check", action="store_true",
                    help="also parse every file with luaparser (slow, ~2 min); tools/validate_data.lua is the real check")
    args = ap.parse_args()

    export = Export(args.export)
    zone_names = load_zone_names(args.questiedb)
    commit = (export.manifest.get("questiedbCommit") or "unknown")[:10]
    zone_bounds, bounds_info = load_zone_bounds(args.questiedb)
    if bounds_info.get("error"):
        print("WARNING: zone bounds:", bounds_info["error"], bounds_info["path"])

    for warning in export.warnings:
        print("WARNING:", warning)
    sides, per_faction, starts, issues, stats, dynamic_counts, class_dyn = build(export, zone_names)

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.docs, exist_ok=True)
    paths = {
        "Schema": os.path.join(args.out, "Schema.lua"),
        "Meta": os.path.join(args.out, "Meta.lua"),
        "Neutral": os.path.join(args.out, "Neutral.lua"),
        "Horde": os.path.join(args.out, "Horde.lua"),
        "Alliance": os.path.join(args.out, "Alliance.lua"),
    }
    counts = {side: {k: len(v) for k, v in t.items() if k != "classQuests"} for side, t in sides.items()}
    write_schema(paths["Schema"], commit)
    write_meta(paths["Meta"], export, starts, counts, zone_bounds, bounds_info)
    write_zone_bounds_json(os.path.join(args.export, "zone_bounds.json"), zone_bounds, bounds_info)
    for side in ("Neutral", "Horde", "Alliance"):
        write_side(paths[side], side, sides[side], commit)

    sizes = [(os.path.relpath(p), os.path.getsize(p)) for p in paths.values()]
    new_gaps, old_gaps, label_counts, n_avail, n_new = write_reports(
        os.path.join(args.docs, "DATA_COVERAGE.md"), os.path.join(args.docs, "data-gaps.csv"),
        export, sides, per_faction, starts, issues, stats, dynamic_counts, class_dyn, zone_names, sizes,
        zone_bounds, bounds_info)

    if args.parse_check:
        errors, skipped = validate_lua(paths.values())
    else:
        errors, skipped = [], "skipped (use --parse-check, or run tools/validate_data.lua with Lua 5.1)"

    print(f"QuestieDB {commit}: {n_avail} quests available ({n_new} new Forever)")
    for side in ("Neutral", "Horde", "Alliance"):
        c = counts[side]
        print(f"  {side:8s} quests {c['quests']:5d}  npcs {c['npcs']:5d}  objects {c['objects']:4d}  items {c['items']:4d}")
    for name, size in sizes:
        print(f"  {name:22s} {size / 1024:7.0f} KB")
    print(f"New Forever quests missing: XP {new_gaps['no XP']}, start loc {new_gaps['no start location']}, "
          f"finish loc {new_gaps['no finish location']} (of {new_gaps['total']})")
    print(f"Zone bounds: {len(zone_bounds)} maps (build {bounds_info['build']})")
    print(f"Integrity issues: {len(issues)}  |  dynamic: Horde {dynamic_counts['Horde']}, "
          f"Alliance {dynamic_counts['Alliance']}, class-specific {len(class_dyn)}")
    if skipped:
        print("Lua validation:", skipped)
    elif errors:
        print(f"Lua validation: {len(errors)} ERRORS")
        for e in errors[:10]:
            print("  ", e)
        sys.exit(1)
    else:
        print("Lua validation: all files and chunks parse")


if __name__ == "__main__":
    main()
