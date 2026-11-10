#!/usr/bin/env python3
"""Route-efficiency model for Leveling Navigator (offline, Python 3 stdlib only).

What lives here:
  * `World`: read-only access to the M3 export (tools/.cache/forever) with the same
    faction/class corrections the addon data uses (we import tools/build_data.py's own
    functions instead of re-implementing them), plus Data/Meta.lua's starting quests.
  * Spawn conversion to (uiMap, x, y) and distances in map-percent units and, only when a
    zone size is supplied, in yards.
  * `TimeModel`: every time-model parameter in one place, each with a V/O/E/U label.
  * `estimate_*`: per-step time estimates that carry their label and say which parts are
    unknown instead of guessing.

Labels (see CLAUDE.md): V verified in Forever by our recorder, O observed from a
Forever-specific source, E estimated (Classic Era value or placeholder), U unknown.
Nothing in this module is labelled V: we have no in-game measurements yet.

Spec: docs/P2_GUIDE_ENGINE_SPEC.md section 9; methodology: docs/ROUTE_EFFICIENCY.md.
"""

import json
import math
import os
import re
import sys

sys.dont_write_bytecode = True  # never write __pycache__ outside tools/.cache
from collections import defaultdict
from dataclasses import dataclass, field, fields

OPTIMIZER_VERSION = "0.1.0"

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
EXPORT_DIR = os.path.join(REPO, "tools", ".cache", "forever")
META_LUA = os.path.join(REPO, "Data", "Meta.lua")
CACHE_DIR = os.path.join(REPO, "tools", ".cache", "optimizer")
ZONE_BOUNDS = os.path.join(EXPORT_DIR, "zone_bounds.json")

# Reuse the data pipeline's own loaders and correction logic (read-only import; that file is
# owned by quest-data-engineer). This keeps optimizer records identical to Data/*.lua.
sys.path.insert(0, os.path.join(REPO, "tools"))
import build_data as BD  # noqa: E402

# --------------------------------------------------------------------------------------------
# Labels
# --------------------------------------------------------------------------------------------

LABELS = ("V", "O", "E", "U")
_RANK = {l: i for i, l in enumerate(LABELS)}


def worst_label(*labels):
    """Weakest label wins: V < O < E < U. Empty input -> U (nothing known)."""
    ls = [l for l in labels if l]
    if not ls:
        return "U"
    return max(ls, key=lambda l: _RANK[l])


@dataclass(frozen=True)
class Param:
    value: object          # None when unknown
    label: str             # V/O/E/U
    unit: str
    note: str

    @property
    def known(self):
        return self.value is not None and self.label != "U"


# --------------------------------------------------------------------------------------------
# Time model parameters (one place, all labelled)
# --------------------------------------------------------------------------------------------
# Every E value below is a placeholder – verify in Forever. U means we have no number at all
# and the model reports the affected term as unknown rather than inventing one.

def _p(value, label, unit, note):
    return field(default_factory=lambda: Param(value, label, unit, note))


@dataclass
class TimeModel:
    # Travel
    run_speed: Param = _p(7.0, "E", "yd/s", "Classic Era base run speed; placeholder – verify in Forever")
    terrain_factor: Param = _p(1.3, "E", "x", "path length / straight line; guess, no source; placeholder – verify in Forever")
    mount_level: Param = _p(40, "E", "level", "Classic Era riding level; placeholder – verify in Forever")
    mount_speed_bonus: Param = _p(0.6, "E", "fraction", "Classic Era apprentice mount +60%; placeholder – verify in Forever")
    mount_cost: Param = _p(None, "U", "copper", "riding skill + mount cost in Forever unknown")
    flight_speed: Param = _p(None, "U", "yd/s", "taxi speed unknown; measure with recorder")
    ghost_speed_bonus: Param = _p(None, "U", "fraction", "ghost run speed vs alive unknown in Forever")
    hearth_cooldown: Param = _p(3600, "E", "s", "Classic Era hearthstone cooldown 60 min; placeholder – verify in Forever")
    hearth_cast: Param = _p(10, "E", "s", "Classic Era hearthstone cast 10 s; placeholder – verify in Forever")
    # Interaction
    accept_s: Param = _p(5, "E", "s", "talk + read + accept at the NPC; placeholder – verify in Forever")
    turnin_s: Param = _p(5, "E", "s", "talk + choose reward + turn in; placeholder – verify in Forever")
    object_use_s: Param = _p(None, "U", "s", "per-object loot/use time unknown (cast times vary)")
    # Combat
    kill_s_same_level: Param = _p(None, "U", "s", "class/gear-dependent; needs recorder data")
    loot_s: Param = _p(None, "U", "s", "per-kill loot time; needs recorder data")
    objective_counts: Param = _p(None, "U", "count", "required kill/item counts are not in the M3 export")
    drop_rates: Param = _p(None, "U", "fraction", "item drop rates are not in the M3 export")
    # Downtime / waits / risk
    downtime_fraction: Param = _p(None, "U", "fraction", "eat/drink share of combat, class-dependent")
    respawn_wait_s: Param = _p(None, "U", "s", "mob/object respawn waits unknown")
    transport_wait_s: Param = _p(None, "U", "s", "boat/zeppelin schedules unknown in Forever")
    death_rate: Param = _p(None, "U", "deaths/step", "needs recorder data")
    death_durability_loss: Param = _p(0.10, "E", "fraction", "Classic Era 10% on death; placeholder – verify in Forever")
    rez_sickness_min_level: Param = _p(11, "E", "level", "Classic Era: spirit-healer sickness from level 11; placeholder – verify in Forever")
    # XP mechanics
    xp_falloff: Param = _p(((5, 1.0), (6, 0.8), (7, 0.6), (8, 0.4), (9, 0.2), (99, 0.1)), "E", "table",
                           "Classic Era: (player - quest level) -> XP fraction; placeholder – verify in Forever")
    xp_to_level: Param = _p((400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400,
                             12900, 14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700,
                             34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100,
                             71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500,
                             123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900,
                             180800, 187900, 195000, 202300, 209800),
                            "E", "xp", "Classic Era XP to next level for levels 1..59; placeholder – verify in Forever")

    def params(self):
        return [(f.name, getattr(self, f.name)) for f in fields(self)]

    def override(self, name, value, label, note="override"):
        if label not in LABELS:
            raise ValueError(f"bad label {label!r}")
        old = getattr(self, name)
        setattr(self, name, Param(value, label, old.unit, note))

    @classmethod
    def from_overrides(cls, path=None):
        """Optional JSON {name: {"value": v, "label": "O", "note": "..."}} (e.g. recorder imports)."""
        m = cls()
        if path:
            with open(path, encoding="utf-8") as f:
                for name, o in json.load(f).items():
                    m.override(name, o.get("value"), o["label"], o.get("note", "override"))
        return m


# --------------------------------------------------------------------------------------------
# Zone sizes (yards): from the export's zone_bounds.json (QuestieDB conversion.json map bounds,
# label from the file, O). Maps without bounds stay U; we never invent sizes.
# --------------------------------------------------------------------------------------------

class ZoneSizes:
    """uiMap -> (width_yd, height_yd, label). ZoneSizes() is empty; ZoneSizes.load() reads the bounds."""

    def __init__(self, table=None):
        self.table = {}
        for k, v in (table or {}).items():
            w, h, label = v
            if label not in LABELS:
                raise ValueError(f"bad label {label!r} for map {k}")
            self.table[int(k)] = (float(w), float(h), label)

    @classmethod
    def from_bounds(cls, path=ZONE_BOUNDS):
        """zone_bounds.json: {label, maps: {uiMap: {width, height, ...}}}. Missing file -> empty."""
        if not path or not os.path.exists(path):
            return cls()
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        label = data.get("label", "U")
        return cls({k: (v["width"], v["height"], label) for k, v in (data.get("maps") or {}).items()
                    if v.get("width") and v.get("height")})

    @classmethod
    def load(cls, bounds=ZONE_BOUNDS, overrides=None):
        """Bounds file first, then an optional override JSON {uiMap: [width_yd, height_yd, label]}."""
        sizes = cls.from_bounds(bounds)
        if overrides:
            with open(overrides, encoding="utf-8") as f:
                sizes.table.update(cls(json.load(f)).table)
        return sizes

    def missing(self, maps):
        """Sorted maps from `maps` that have no size (travel there stays U)."""
        return sorted(m for m in set(maps) if m is not None and m not in self.table)

    def get(self, ui_map):
        """(width, height, label) or (None, None, 'U')."""
        return self.table.get(ui_map, (None, None, "U"))


def dist_map_pct(a, b):
    """Straight-line distance in map-percent units between (map, x, y) points on the same map.

    Map percent is anisotropic (x and y percent are different yard lengths on non-square maps),
    so it is only good for comparing paths within the same map. None across maps."""
    if a is None or b is None or a[0] != b[0]:
        return None
    return math.hypot(a[1] - b[1], a[2] - b[2])


def dist_yards(a, b, sizes):
    """(yards, label). Label U and yards None if the map size is unknown or maps differ."""
    if a is None or b is None or a[0] != b[0]:
        return None, "U"
    w, h, label = sizes.get(a[0])
    if w is None:
        return None, "U"
    return math.hypot((a[1] - b[1]) / 100.0 * w, (a[2] - b[2]) / 100.0 * h), label


# --------------------------------------------------------------------------------------------
# Minimal Lua table literal reader (for the generated Data/Meta.lua only)
# --------------------------------------------------------------------------------------------

_TOKEN = re.compile(r'\s*(?:(\[)|(\])|(\{)|(\})|(=)|(,)|("(?:[^"\\]|\\.)*")|(-?\d+(?:\.\d+)?)|([A-Za-z_]\w*))')


def parse_lua_table(src):
    """Parse a Lua table constructor of numbers/strings/booleans/nested tables (no expressions)."""
    toks, pos = [], 0
    while pos < len(src):
        m = _TOKEN.match(src, pos)
        if not m or m.end() == pos:
            if src[pos:].strip() == "":
                break
            raise ValueError(f"unexpected Lua at {pos}: {src[pos:pos + 20]!r}")
        pos = m.end()
        kind = m.lastindex
        toks.append((kind, m.group(kind)))
    i = 0

    def value():
        nonlocal i
        kind, text = toks[i]
        i += 1
        if kind == 3:
            return table()
        if kind == 7:
            return bytes(text[1:-1], "utf-8").decode("unicode_escape")
        if kind == 8:
            return float(text) if "." in text else int(text)
        if kind == 9:
            return {"true": True, "false": False, "nil": None}.get(text, text)
        raise ValueError(f"unexpected token {text!r}")

    def table():
        nonlocal i
        arr, hashed = [], {}
        while toks[i][0] != 4:
            if toks[i][0] == 1:
                i += 1
                key = value()
                i += 2  # ] =
                hashed[key] = value()
            elif toks[i][0] == 9 and i + 1 < len(toks) and toks[i + 1][0] == 5:
                key = toks[i][1]
                i += 2
                hashed[key] = value()
            else:
                arr.append(value())
            if toks[i][0] == 6:
                i += 1
        i += 1
        if hashed:
            for n, v in enumerate(arr, 1):
                hashed[n] = v
            return hashed
        return arr

    return value()


def load_meta(path=META_LUA):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"ns\.DataMeta\s*=\s*", src)
    if not m:
        raise ValueError("ns.DataMeta not found in Meta.lua")
    return parse_lua_table(src[m.end():])


# --------------------------------------------------------------------------------------------
# World: export access with faction/class corrections
# --------------------------------------------------------------------------------------------

RACES = BD.RACES          # raceID -> (name, mask bit, faction)
CLASSES = BD.CLASSES      # classFile -> mask bit
ALL_CLASSES_MASK = sum(CLASSES.values())


class World:
    def __init__(self, export_dir=EXPORT_DIR, meta_path=META_LUA):
        self.export = BD.Export(export_dir)
        self.meta = load_meta(meta_path)
        self._quests = {}   # (fac, cls) -> {qid: (raw, rec)}
        self._spawn_cache = {}
        self._stats = {"unmapped_area": defaultdict(int)}

    # Quests -----------------------------------------------------------------------------
    def quests(self, faction, cls=None):
        """{qid: (raw_resolved, record)} for one faction (and class, if given).

        raw_resolved: the export record after QuestieDB's faction/class corrections.
        record: build_data.build_quest output (same fields as Data/*.lua, by name)."""
        key = (faction, cls)
        if key in self._quests:
            return self._quests[key]
        out = {}
        dummy_refs = {"npc": set(), "object": set(), "item": set()}
        for qid in sorted(self.export.quests):
            q = self.export.quests[qid]
            fac_q, class_variants, _ = BD.resolve_dynamic(self.export, "Quest", qid, q)[faction]
            if cls and class_variants:
                fac_q = class_variants[cls]
            if faction not in BD.quest_faction(fac_q, self.export):
                continue
            out[qid] = (fac_q, BD.build_quest(qid, fac_q, self.export, dummy_refs))
        self._quests[key] = out
        return out

    def start(self, race_id):
        """Starting info from Data/Meta.lua: {'area', 'map', 'quests'}; map None = data gap."""
        st = (self.meta.get("startingQuests") or {}).get(race_id) or {}
        return {"area": st.get("area"), "map": st.get("map"), "quests": list(st.get("quests") or [])}

    # Spawns -----------------------------------------------------------------------------
    def _entity(self, kind, eid, faction):
        table = {"Npc": self.export.npcs, "Object": self.export.objects, "Item": self.export.items}[kind]
        base = table.get(eid)
        if base is None:
            return None
        return BD.resolve_dynamic(self.export, kind, eid, base)[faction][0]

    def spawns(self, kind, eid, faction):
        """[(uiMap, x, y), ...] and label (E/O, or U when none) for an NPC or object."""
        key = (kind, eid, faction)
        if key in self._spawn_cache:
            return self._spawn_cache[key]
        rec = self._entity(kind, eid, faction)
        pts, label = [], "U"
        if rec and rec.get("spawns"):
            flat = BD.convert_spawns(self.export, rec["spawns"], self._stats) or []
            pts = [(flat[i], flat[i + 1], flat[i + 2]) for i in range(0, len(flat), 3)]
            if pts:
                layer = self.export.field_layer(kind, eid, "spawns")
                label = "O" if BD.is_forever_layer(layer) else "E"
        self._spawn_cache[key] = (pts, label)
        return pts, label

    def _merge(self, parts):
        pts, label = [], "U"
        for p, l in parts:
            if p:
                pts.extend(p)
                label = l if label == "U" else worst_label(label, l)
        return sorted(set(pts)), label

    def npc_object_points(self, npc_ids, obj_ids, faction):
        parts = [self.spawns("Npc", i, faction) for i in sorted(npc_ids or [])]
        parts += [self.spawns("Object", i, faction) for i in sorted(obj_ids or [])]
        return self._merge(parts)

    def item_points(self, item_id, faction):
        """Drop sources (NPCs, objects) and vendors of an item."""
        it = self._entity("Item", item_id, faction) or {}
        npcs = list(it.get("npcDrops") or []) + list(it.get("vendors") or [])
        return self.npc_object_points(npcs, it.get("objectDrops") or [], faction)

    def npc_name(self, nid):
        return (self.export.npcs.get(nid) or {}).get("name")


# --------------------------------------------------------------------------------------------
# Step estimates
# --------------------------------------------------------------------------------------------

def nearest(pos, points):
    """Nearest point to pos on the same map; otherwise the lowest (x, y) point on the map with the
    most points (ties: lowest uiMap). Deterministic regardless of input order."""
    if not points:
        return None
    if pos is not None:
        same = [p for p in points if p[0] == pos[0]]
        if same:
            return min(same, key=lambda p: (dist_map_pct(pos, p), p))
    counts = defaultdict(int)
    for p in points:
        counts[p[0]] += 1
    best = min(counts, key=lambda m: (-counts[m], m))
    return min(p for p in points if p[0] == best)


def travel_estimate(pos, target, model, sizes):
    """Travel term: {'seconds', 'label', 'map_pct', 'yards'}; unknown parts stay None/U."""
    out = {"seconds": None, "label": "U", "map_pct": dist_map_pct(pos, target), "yards": None}
    if target is None or pos is None:
        return out
    if pos == target:
        out.update(seconds=0.0, label="E", yards=0.0)
        return out
    yards, ylabel = dist_yards(pos, target, sizes)
    out["yards"] = yards
    rs, tf = model.run_speed, model.terrain_factor
    if yards is None or not rs.known or not tf.known:
        return out
    out["seconds"] = yards * tf.value / rs.value
    out["label"] = worst_label(ylabel, rs.label, tf.label)
    return out


def combine(terms):
    """terms: {name: (seconds|None, label)} -> (seconds|None, label, unknown_term_names)."""
    unknown = sorted(n for n, (s, l) in terms.items() if s is None or l == "U")
    if unknown:
        return None, "U", unknown
    total = sum(s for s, _ in terms.values())
    return total, worst_label(*(l for _, l in terms.values())), []


def xp_fraction(player_level, quest_level, model):
    """(fraction, label) from the XP falloff table."""
    p = model.xp_falloff
    if not p.known or player_level is None or quest_level is None:
        return None, "U"
    diff = player_level - quest_level
    for max_diff, frac in p.value:
        if diff <= max_diff:
            return frac, p.label
    return p.value[-1][1], p.label


def xp_needed(level, model):
    p = model.xp_to_level
    if not p.known or level < 1 or level > len(p.value):
        return None
    return p.value[level - 1]
