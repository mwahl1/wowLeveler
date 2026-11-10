#!/usr/bin/env python3
"""Naive baseline route per starting area (docs/P2_GUIDE_ENGINE_SPEC.md section 9).

Baseline definition: in the race's starting uiMap (Data/Meta.lua startingQuests), take every
quest the race/class/faction can do inside the level window (required level <= 12, quest
level <= 17 by default), order them by simulated quest level while respecting prerequisites,
and do each quest on its own: ACCEPT -> OBJECTIVE(s) -> TURNIN. No batching, no hearth, no
flight paths. This is the reference every optimized route is compared against.

Usage (from the repo root):
    python3 tools/optimizer/baseline.py --all                  # summary table, all starts
    python3 tools/optimizer/baseline.py --race 2 --steps       # step list for Orc
    python3 tools/optimizer/baseline.py --race 2 --lua         # P2 route file text on stdout
    python3 tools/optimizer/baseline.py --all --json           # write tools/.cache/optimizer/*.json
Options: --class WARRIOR, --zone-sizes sizes.json (overrides the QuestieDB bounds),
         --params overrides.json, --no-grind, --max-req-level N, --max-quest-level N

    python3 tools/optimizer/baseline.py --write-guides         # regenerate Guides/Baseline_Starts.lua

Only --write-guides writes into Guides/: one start def per starting zone (races sharing a zone share
a def), every class (class-restricted steps carry when.classes). It is a naive measuring stick, NOT
an optimized route.
"""

import argparse
import heapq
import json
import os
import sys

sys.dont_write_bytecode = True  # never write __pycache__ outside tools/.cache
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M  # noqa: E402

SOURCE = f"optimizer@baseline-{M.OPTIMIZER_VERSION}"
ALL = "ALL"  # cls value: every class; class-restricted quest steps get when.classes
GUIDES_FILE = os.path.join(M.REPO, "Guides", "Baseline_Starts.lua")
# Start defs written to Guides/Baseline_Starts.lua: races sharing a starting zone share one def.
GUIDE_STARTS = ((1,), (3, 7), (4,), (95,), (2, 8), (5,), (6,))
SKIPPED_STARTS = {96: "Skyborne Horde: no starting zone in the data (Data/Meta.lua startingQuests has no map)"}
# Default class for the baseline: Warrior is open to every Classic race (Skyborne: unverified).
# Class-restricted quests are kept only when they include this class. --class none = class-free only.
DEFAULT_CLASS = "WARRIOR"
# Baseline definition (a choice, not game data): the starting area's quests are those with a
# required level <= this. Higher quests in the same uiMap (e.g. Gnomeregan, riding quests) belong
# to later segments. --max-req-level 0 disables the cap.
DEFAULT_MAX_REQ_LEVEL = 12
# Same window on quest level: max_req_level + this (e.g. level-60 "Donation" quests that only
# require level 12 are not starting-area quests). --max-quest-level overrides.
QUEST_LEVEL_MARGIN = 5
START_RACES = (1, 3, 4, 7, 95, 2, 5, 6, 8, 96)   # all playable raceIDs; 96 = known data gap
NEEDS_STATE_RAW = (("requiredMinRep", "rep"), ("requiredMaxRep", "rep"), ("requiredSpell", "spell"),
                   ("requiredSpecialization", "spec"), ("requiredRanks", "ranks"))
BD_FLAGS = M.BD.QUEST_FLAGS


def _order_key(rec, qid):
    lvl = rec.get("LEVEL")
    req = rec.get("REQ_LEVEL")
    return (lvl if lvl is not None else (req if req is not None else 999), req or 0, qid)


# --------------------------------------------------------------------------------------------
# Quest selection
# --------------------------------------------------------------------------------------------

def class_set(rec):
    """Classes a quest record allows (classFiles)."""
    cm = rec.get("CLASSES") or 0
    if not cm or cm & M.ALL_CLASSES_MASK == M.ALL_CLASSES_MASK:
        return frozenset(M.CLASSES)
    return frozenset(c for c, b in M.CLASSES.items() if cm & b)


def race_set(rec, races):
    rm = rec.get("RACES") or 0
    return frozenset(r for r in races if not rm or rm & M.RACES[r][1])


def select_quests(world, race_id, cls, start_map, max_req_level=None, max_quest_level=None,
                  races=None, prereq_out=None):
    """Return (included {qid: (raw, rec)}, edges {qid: set(predecessors)}, excluded {qid: reason}).

    races: all raceIDs sharing this start (default [race_id]); a quest is kept if any can take it.
    cls: a classFile, None (class-free quests only) or ALL (every class).
    prereq_out: optional dict filled with the prerequisite-only edges (no ordering edges)."""
    races = list(races or [race_id])
    faction = M.RACES[race_id][2]
    allq = world.quests(faction, None if cls == ALL else cls)
    cand, excluded = {}, {}
    for qid, (raw, rec) in allq.items():
        if rec.get("MAP") != start_map:
            continue
        if not race_set(rec, races):
            continue  # another race's quest: not counted as an exclusion
        classes = rec.get("CLASSES") or 0
        if classes and classes & M.ALL_CLASSES_MASK != M.ALL_CLASSES_MASK and cls != ALL:
            if cls is None:
                excluded[qid] = "class_restricted"
                continue
            if not classes & M.CLASSES[cls]:
                continue
        if max_req_level and (rec.get("REQ_LEVEL") or 1) > max_req_level:
            excluded[qid] = "above_baseline_window:req_level"
            continue
        if max_quest_level and (rec.get("LEVEL") or 0) > max_quest_level:
            excluded[qid] = "above_baseline_window:quest_level"
            continue
        flags = rec.get("FLAGS") or 0
        if flags & BD_FLAGS["REPEATABLE"]:
            excluded[qid] = "repeatable"
            continue
        if rec.get("SKILL"):
            excluded[qid] = "needs_state:skill"
            continue
        reason = next((f"needs_state:{k}" for f, k in NEEDS_STATE_RAW if raw.get(f)), None)
        if reason:
            excluded[qid] = reason
            continue
        cand[qid] = (raw, rec)

    def exclusive_of(qid):
        r = allq.get(qid)
        return (r[1].get("EXCLUSIVE") or []) if r else []

    # Fixed point: prerequisites outside the set or exclusive conflicts remove quests,
    # which can in turn break other quests' prerequisites. Bounded by the candidate count.
    for _ in range(len(cand) + 1):
        changed = False
        edges = {}
        for qid in sorted(cand):
            raw, rec = cand[qid]
            preds, reason = set(), None
            pre_any = rec.get("PRE_ANY") or []
            pre_all = rec.get("PRE_ALL") or [] if not pre_any else []  # Questie: group only if single absent
            if pre_any:
                # Spec 8a: any one positive entry done satisfies PRE_ANY. A negative entry is
                # never satisfiable in Questie's logic, so it only matters when nothing else is.
                opts = [p for p in pre_any if p > 0 and p in cand]
                if opts:
                    preds.add(min(opts, key=lambda p: _order_key(cand[p][1], p)))
                elif any(p < 0 for p in pre_any):
                    reason = "negative_pre_any"
                else:
                    missing = [p for p in pre_any if p not in world.export.quests]
                    reason = (f"missing_prereq:{missing[0]}" if len(missing) == len(pre_any)
                              else f"prereq_outside:{min(pre_any)}")
            for p in pre_all:
                if reason:
                    break
                need = -p if p < 0 else p
                if need in cand:
                    preds.add(need)
                    continue
                alt = [e for e in exclusive_of(need) if e in cand] if p > 0 else []
                if alt:
                    preds.add(min(alt))
                elif need not in world.export.quests:
                    reason = f"missing_prereq:{need}"
                else:
                    reason = f"prereq_outside:{need}"
            aw = raw.get("availableStartingWith")
            if not reason and aw:
                if aw in cand:
                    preds.add(aw)
                else:
                    reason = f"available_with_outside:{aw}"
            if reason:
                excluded[qid] = reason
                del cand[qid]
                changed = True
                continue
            edges[qid] = preds
        # Exclusive groups: keep the first quest in level order, drop the rest
        kept = set()
        for qid in sorted(cand, key=lambda q: _order_key(cand[q][1], q)):
            # Exclusive partners for disjoint classes/races (e.g. per-class variants) don't conflict.
            mine = (class_set(cand[qid][1]), race_set(cand[qid][1], races))
            ex = [e for e in (cand[qid][1].get("EXCLUSIVE") or []) if e in kept
                  and class_set(cand[e][1]) & mine[0] and race_set(cand[e][1], races) & mine[1]]
            if ex:
                excluded[qid] = f"exclusive:{min(ex)}"
                del cand[qid]
                changed = True
            else:
                kept.add(qid)
        if not changed:
            break

    if prereq_out is not None:
        prereq_out.update({q: set(p) for q, p in edges.items()})
    # Ordering edges that are not prerequisites but are required for both quests to be doable:
    # a breadcrumb before its target; a quest before its nextQuestInChain; a quest before the
    # quest that ends its availability (availableUntilCompleted). disabledByQuest (not doable
    # while X is active) always holds here because the baseline has one quest active at a time.
    for qid in cand:
        raw, rec = cand[qid]
        until = raw.get("availableUntilCompleted")
        if until in cand and until != qid:
            edges[until].add(qid)
        bc = rec.get("BREADCRUMB_FOR")
        if bc in cand:
            edges[bc].add(qid)
        nxt = rec.get("NEXT")
        if nxt in cand and nxt != qid:
            edges[nxt].add(qid)
    return cand, edges, excluded



def _gain(level, rec, model):
    frac, _ = M.xp_fraction(level, rec.get("LEVEL"), model)
    if rec.get("XP") is None or frac is None:
        return 0
    return int(round(rec["XP"] * frac))


def _level_up(level, xp, model):
    while level < 60:
        n = M.xp_needed(level, model)
        if n is None or xp < n:
            break
        xp -= n
        level += 1
    return level, xp


def order_quests(cand, edges, excluded, model, grind=False):
    """Naive level order, simulated: repeatedly take the lowest (quest level, required level, id)
    quest whose prerequisites are done and whose required level the character has reached.

    When quests remain but none is level-feasible: grind=False stops and marks the rest
    level_gated (this zone's own quest XP cannot get the character there); grind=True jumps to
    the lowest required level (the step builder inserts the GRIND step). Quests that never
    become ready for other reasons are ordering_cycle."""
    indeg = {q: len(edges[q]) for q in cand}
    succ = {q: [] for q in cand}
    for q, preds in edges.items():
        for p in preds:
            succ[p].append(q)
    ready = {q for q in cand if indeg[q] == 0}
    order, level, xp = [], 1, 0
    while ready:
        ok = [q for q in ready if (cand[q][1].get("REQ_LEVEL") or 1) <= level]
        if not ok:
            if not grind:
                break
            level, xp = min((cand[q][1].get("REQ_LEVEL") or 1) for q in ready), 0
            continue
        q = min(ok, key=lambda q: _order_key(cand[q][1], q))
        ready.discard(q)
        order.append(q)
        level, xp = _level_up(level, xp + _gain(level, cand[q][1], model), model)
        for s in succ[q]:
            indeg[s] -= 1
            if indeg[s] == 0:
                ready.add(s)
    done = set(order)
    for q in sorted(set(cand) - done):
        gated = q in ready or _waits_on(q, edges, done, ready)
        excluded[q] = f"level_gated:{cand[q][1].get('REQ_LEVEL')}" if gated else "ordering_cycle"
    return order


def _waits_on(q, edges, done, ready):
    """True if q (transitively) waits on a quest that was ready but level-gated."""
    seen, stack = set(), [q]
    while stack:
        x = stack.pop()
        for p in edges.get(x, ()):
            if p in ready:
                return True
            if p not in done and p not in seen:
                seen.add(p)
                stack.append(p)
    return False


# --------------------------------------------------------------------------------------------
# Steps and estimates
# --------------------------------------------------------------------------------------------

def _objective_targets(world, rec, faction):
    """[(kind_name, points, label, work_terms)] per objective, in OBJ order, plus trigger."""
    K = M.BD.OBJ_KIND
    tm_terms = []
    for o in rec.get("OBJ") or []:
        kind = o[0]
        if kind == K["npc"]:
            pts, lab = world.npc_object_points([o[1]], [], faction)
            tm_terms.append(("kill", pts, lab, ("combat",)))
        elif kind == K["killcredit"]:
            pts, lab = world.npc_object_points(o[1], [], faction)
            tm_terms.append(("killcredit", pts, lab, ("combat",)))
        elif kind == K["object"]:
            pts, lab = world.npc_object_points([], [o[1]], faction)
            tm_terms.append(("object", pts, lab, ("object_use",)))
        elif kind == K["item"]:
            pts, lab = world.item_points(o[1], faction)
            tm_terms.append(("item", pts, lab, ("combat", "drops")))
        elif kind == K["rep"]:
            tm_terms.append(("rep", [], "U", ("rep",)))
        else:
            tm_terms.append(("spell", [], "U", ("spell",)))
    trig = rec.get("TRIGGER")
    if trig:
        tm_terms.append(("explore", [(trig[1], trig[2], trig[3])], "E", ()))
    return tm_terms


def _work_term(name, model):
    """Seconds for one objective's work beyond travel. Counts are not in the data -> U."""
    if name == "combat":
        p, k = model.objective_counts, model.kill_s_same_level
        if p.known and k.known:
            return p.value * k.value, M.worst_label(p.label, k.label)
        return None, "U"
    if name == "object_use":
        p, k = model.objective_counts, model.object_use_s
        if p.known and k.known:
            return p.value * k.value, M.worst_label(p.label, k.label)
        return None, "U"
    if name == "drops":
        return (None, "U") if not model.drop_rates.known else (0.0, model.drop_rates.label)
    return None, "U"


def applicability(cand, prereq, races):
    """{qid: (classes, races)} a quest applies to: its own masks intersected with those of its
    prerequisites (a quest after a class-only quest is class-only too)."""
    memo = {}

    def eff(q, stack):
        if q in memo:
            return memo[q]
        rec = cand[q][1]
        cs, rs = set(class_set(rec)), set(race_set(rec, races))
        for p in sorted(prereq.get(q, ())):
            if p in cand and p not in stack:
                pc, pr = eff(p, stack | {q})
                cs &= pc
                rs &= pr
        memo[q] = (frozenset(cs), frozenset(rs))
        return memo[q]

    return {q: eff(q, frozenset()) for q in sorted(cand)}


def build_baseline(world, race_id, cls=DEFAULT_CLASS, model=None, sizes=None, grind=True,
                   max_req_level=DEFAULT_MAX_REQ_LEVEL, max_quest_level=None, races=None, route_id=None):
    """grind=True (default): when no remaining quest is level-feasible, insert a GRIND step to the
    lowest required level (time U; it also stands in for kill XP earned during objectives, which
    the model does not count). grind=False: stop there and mark the rest level_gated."""
    model = model or M.TimeModel()
    sizes = sizes if sizes is not None else M.ZoneSizes.load()
    if max_quest_level is None and max_req_level:
        max_quest_level = max_req_level + QUEST_LEVEL_MARGIN
    max_quest_level = max_quest_level or None
    name, _, faction = M.RACES[race_id]
    st = world.start(race_id)
    head = {"race": race_id, "races": sorted(races or [race_id]), "raceName": name, "faction": faction, "class": cls,
            "area": st["area"], "map": st["map"]}
    if not st["map"]:
        return dict(head, gap=f"{name} {faction} (raceID {race_id}): no starting zone in the data "
                              f"(Data/Meta.lua startingQuests has no map; see docs/DATA_COVERAGE.md)")

    races = list(races or [race_id])
    prereq = {}
    cand, edges, excluded = select_quests(world, race_id, cls, st["map"], max_req_level, max_quest_level,
                                          races, prereq)
    appl = applicability(cand, prereq, races)
    for q in sorted(cand):
        if not appl[q][0] or not appl[q][1]:
            excluded[q] = "no_applicable_class" if not appl[q][0] else "no_applicable_race"
            del cand[q]
    edges = {q: {p for p in ps if p in cand} for q, ps in edges.items() if q in cand}
    order = order_quests(cand, edges, excluded, model, grind)
    prefix = route_id or (f"baseline.r{race_id}" + (f".{cls.lower()}" if cls and cls != ALL else ""))

    steps = []
    pos = None
    level, xp = 1, 0
    xp_awarded, xp_data, xp_labels, xp_unknown = 0, 0, [], 0
    known_s, path_pct, unknown_legs = 0.0, 0.0, 0
    unknown_terms = {}
    grinds, grind_xp = 0, 0

    def add(step, target, terms, xp_est=None, xp_label=None):
        nonlocal pos, known_s, path_pct, unknown_legs
        tr = M.travel_estimate(pos, target, model, sizes)
        all_terms = dict(terms)
        all_terms["travel"] = (tr["seconds"], tr["label"])
        secs, label, unknown = M.combine(all_terms)
        for t in unknown:
            unknown_terms[t] = unknown_terms.get(t, 0) + 1
        if tr["map_pct"] is not None:
            path_pct += tr["map_pct"]
        elif step["type"] != "GRIND":
            unknown_legs += 1
        if secs is not None:
            known_s += secs
        else:
            known_s += sum(s for n, (s, l) in all_terms.items() if s is not None and l != "U")
        src = M.worst_label(label, xp_label) if xp_label else label
        step["est"] = {"seconds": round(secs) if secs is not None else None, "xp": xp_est, "src": src}
        step["_model"] = {"terms": {n: [None if s is None else round(s, 1), l] for n, (s, l) in sorted(all_terms.items())},
                          "unknown": unknown, "mapPct": None if tr["map_pct"] is None else round(tr["map_pct"], 2),
                          "target": list(target) if target else None}
        steps.append(step)
        pos = target

    for qid in order:
        raw, rec = cand[qid]
        req = rec.get("REQ_LEVEL") or 1
        if req > level:
            need = 0
            for lv in range(level, req):
                n = M.xp_needed(lv, model)
                need = None if (n is None or need is None) else need + n
            if need is not None:
                need -= xp
            grinds += 1
            grind_xp = None if (need is None or grind_xp is None) else grind_xp + need
            add({"id": f"{prefix}.g{grinds}", "type": "GRIND", "target": {"level": req, "fraction": 0}},
                None, {"grind": (None, "U")}, need, model.xp_to_level.label)
            pos = None
            level, xp = req, 0

        start = rec.get("START") or [None, None, None]
        start = list(start) + [None] * (3 - len(start))
        if start[0] or start[1]:
            pts, lab = world.npc_object_points(start[0], start[1], faction)
        elif start[2]:
            pts, lab = world.item_points(start[2][0], faction)
        else:
            pts, lab = [], "U"
        tgt = M.nearest(pos, pts)
        when = {}
        q_classes, q_races = appl[qid]
        if q_classes != frozenset(M.CLASSES):
            when["classes"] = sorted(q_classes) if cls == ALL else [cls]
        if set(q_races) != set(races):
            when["races"] = sorted(q_races)
        first_step = len(steps)
        acc = {"id": f"{prefix}.a{qid}", "type": "ACCEPT", "quest": qid}
        add(acc, tgt,
            {"interaction": (model.accept_s.value, model.accept_s.label), "location": (0.0, lab)})
        acc["_model"]["level"] = level

        for i, (kind, pts, lab, work) in enumerate(_objective_targets(world, rec, faction), 1):
            tgt = M.nearest(pos, pts)
            terms = {w: _work_term(w, model) for w in work}
            terms["location"] = (0.0, lab)
            step = {"id": f"{prefix}.o{qid}_{i}", "type": "OBJECTIVE", "quest": qid, "objective": i}
            if kind == "explore":
                step["type"] = "COMPLETE"  # area trigger (explore objective)
                del step["objective"]
            add(step, tgt, terms)

        fin = rec.get("FINISH") or [None, None]
        fin = list(fin) + [None] * (2 - len(fin))
        pts, lab = world.npc_object_points(fin[0], fin[1], faction)
        tgt = M.nearest(pos, pts)
        q_xp = rec.get("XP")
        xp_lbl = (rec.get("LABELS") or "UUUU")[3]
        frac, flab = M.xp_fraction(level, rec.get("LEVEL"), model)
        gain = None
        if q_xp is not None:
            xp_data += q_xp
            if frac is not None:
                gain = int(round(q_xp * frac))
        else:
            xp_unknown += 1
        glabel = M.worst_label(xp_lbl, flab) if gain is not None else "U"
        add({"id": f"{prefix}.t{qid}", "type": "TURNIN", "quest": qid}, tgt,
            {"interaction": (model.turnin_s.value, model.turnin_s.label), "location": (0.0, lab)},
            gain, glabel)
        if when:
            for st_ in steps[first_step:]:
                st_["when"] = dict(when)
        if gain is not None:
            xp_awarded += gain
            xp_labels.append(glabel)
            xp += gain
            level, xp = _level_up(level, xp, model)

    unknown_steps = sum(1 for s in steps if s["est"]["seconds"] is None)
    levels = [cand[q][1].get("LEVEL") for q in order if cand[q][1].get("LEVEL") is not None]
    reasons = {}
    for r in excluded.values():
        k = r.split(":")[0] if r.startswith(("prereq_outside", "missing_prereq", "exclusive", "level_gated",
                                              "available_with_outside")) else r
        reasons[k] = reasons.get(k, 0) + 1
    # Hidden unknowns make totals lower bounds: label them U, never E.
    xp_lower_bound = xp_unknown > 0
    level_unknown = xp_lower_bound or grinds > 0
    w, h, size_label = sizes.get(st["map"])
    summary = dict(head, grind=grind, maxReqLevel=max_req_level, maxQuestLevel=max_quest_level, grindXP=grind_xp,
                   zoneSizeLabel=size_label,
                   mapsWithoutSize=sizes.missing(s_["_model"]["target"][0] for s_ in steps
                                                 if s_["_model"]["target"]),
                   quests=len(order), questLevels=[min(levels), max(levels)] if levels else None,
                   excluded=len(excluded), excludedByReason=dict(sorted(reasons.items())),
                   steps=len(steps), grindSteps=grinds,
                   xpData=xp_data, xpDataUnknownQuests=xp_unknown,
                   xpAwarded=xp_awarded, xpAwardedIsLowerBound=xp_lower_bound,
                   xpAwardedLabel="U" if xp_lower_bound or not xp_labels else M.worst_label(*xp_labels),
                   finalLevel=level,
                   finalLevelLabel="U" if level_unknown else model.xp_to_level.label,
                   modelledSeconds=round(known_s) if unknown_steps == 0 else None,
                   modelledLabel=M.worst_label(*(s["est"]["src"] for s in steps)) if unknown_steps == 0 else "U",
                   knownPartSeconds=round(known_s),
                   knownPartLabel=M.worst_label(*(l for s in steps for n, (v, l) in s["_model"]["terms"].items()
                                                  if v is not None and l != "U")),
                   unknownSteps=unknown_steps, unknownTerms=dict(sorted(unknown_terms.items())),
                   pathMapPct=round(path_pct, 1), unknownLegs=unknown_legs)
    unconditional = [q for q in order if appl[q] == (frozenset(M.CLASSES), frozenset(races))
                     or (cls not in (None, ALL) and appl[q][1] == frozenset(races))]
    route = {"id": prefix, "kind": "start", "faction": faction, "races": sorted(races),
             "levels": [1, level], "entry": {"minLevel": 1},
             "exit": {"completed": unconditional} if unconditional else None,
             "source": SOURCE, "steps": steps}
    return {"summary": summary, "route": route, "excluded": dict(sorted(excluded.items())), "order": order,
            "applicability": {q: (sorted(appl[q][0]), sorted(appl[q][1])) for q in order}}


# --------------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------------

def strip_private(v):
    if isinstance(v, dict):
        return {k: strip_private(x) for k, x in v.items() if not k.startswith("_") and x is not None}
    if isinstance(v, list):
        return [strip_private(x) for x in v]
    return v


def route_lua(route):
    return "ns.Guides.Register(" + M.BD.to_lua(strip_private(route)) + ")\n"


def _lua_kv(d, keys):
    to_lua = M.BD.to_lua
    return ", ".join(f"{k} = {to_lua(d[k])}" for k in keys if d.get(k) is not None)


STEP_KEYS = ("id", "type", "quest", "objective", "target", "when", "est")
EST_KEYS = ("seconds", "xp", "src")


def render_route(route):
    """One ns.Guides.Register call, one step per line (stable key order)."""
    r = strip_private(route)
    head = _lua_kv(r, ("id", "kind", "faction", "races", "levels", "entry", "exit", "source"))
    lines = ["ns.Guides.Register({", f"  {head},", "  steps = {"]
    for st in r["steps"]:
        st = dict(st)
        if "est" in st:
            st["est"] = "{" + _lua_kv(st["est"], EST_KEYS) + "}"
        parts = []
        for k in STEP_KEYS:
            if st.get(k) is None:
                continue
            parts.append(f"{k} = {st[k]}" if k == "est" else f"{k} = {M.BD.to_lua(st[k])}")
        lines.append("    { " + ", ".join(parts) + " },")
    lines += ["  },", "})"]
    return "\n".join(lines)


def _wrap_comment(prefix, items, width=100):
    out, line = [], prefix
    for it in items:
        if len(line) + len(it) + 1 > width and line != prefix:
            out.append(line.rstrip())
            line = "--   "
        line += it + " "
    out.append(line.rstrip())
    return out


def render_guides(world, model=None, sizes=None):
    """Guides/Baseline_Starts.lua text: one start def per starting zone (deterministic)."""
    commit = (world.export.manifest.get("questiedbCommit") or "unknown")[:10]
    out = [
        "-- Generated by tools/optimizer/baseline.py --write-guides. Do not edit by hand.",
        f"-- {SOURCE}: naive level-ordered baseline, NOT optimized; labels E/U",
        "-- Each start: every quest of the starting uiMap inside the baseline window (required level <= "
        f"{DEFAULT_MAX_REQ_LEVEL},",
        f"-- quest level <= {DEFAULT_MAX_REQ_LEVEL + QUEST_LEVEL_MARGIN}), in simulated level order, one quest at a time: "
        "ACCEPT -> OBJECTIVE(s) -> TURNIN.",
        "-- est.src is the weakest label of the step's estimate (E = Classic/placeholder, U = unknown: "
        "see docs/ROUTE_EFFICIENCY.md).",
        "-- Levels and GRIND steps assume every class quest's XP (all classes in one list): approximate.",
        f"-- Quest data: QuestieDB {commit} (GPLv3) via the M3 export.",
    ]
    for race, why in sorted(SKIPPED_STARTS.items()):
        out.append(f"-- Skipped raceID {race}: {why}.")
    out += ["", "local _, ns = ..."]
    for group in GUIDE_STARTS:
        lead = group[0]
        st = world.start(lead)
        res = build_baseline(world, lead, ALL, model, sizes, races=group,
                             route_id=f"baseline.start.{st['map']}")
        s_ = res["summary"]
        names = "/".join(M.RACES[r][0] for r in group)
        out += ["", f"-- {names} (races {', '.join(map(str, group))}), uiMap {st['map']}: "
                    f"{s_['quests']} quests, {s_['steps']} steps, {s_['grindSteps']} GRIND"]
        skipped = [f"{q}:{r}" for q, r in sorted(res["excluded"].items())]
        out += _wrap_comment(f"-- skipped ({len(skipped)}): ", skipped) if skipped else ["-- skipped: none"]
        out.append(render_route(res["route"]))
    return "\n".join(out) + "\n"


def guide_results(world, model=None, sizes=None):
    """(group, result) per guide start, same builds as render_guides."""
    return [(g, build_baseline(world, g[0], ALL, model, sizes, races=g,
                               route_id=f"baseline.start.{world.start(g[0])['map']}")) for g in GUIDE_STARTS]


def fmt_time(s):
    if s is None:
        return "-"
    return f"{int(s) // 3600}h{int(s) % 3600 // 60:02d}m"


def summary_table(results):
    hdr = ("race", "name", "fac", "class", "map", "quests", "lvls", "excl", "steps", "grind (XP)", "XP data (U q)",
           "XP falloff", "end lvl", "yd", "modelled", "known part", "unknown steps", "path map%")
    rows = []
    for r in results:
        s = r["summary"] if "summary" in r else r
        if s.get("gap"):
            rows.append((str(s["race"]), s["raceName"], s["faction"][0], str(s["class"]), "-", "GAP", "", "", "", "", "", "",
                         "", "", "U", "", "", ""))
            continue
        lv = s["questLevels"] or ["?", "?"]
        rows.append((str(s["race"]), s["raceName"], s["faction"][0], str(s["class"]), str(s["map"]), str(s["quests"]),
                     f"{lv[0]}-{lv[1]}", str(s["excluded"]), str(s["steps"]), f"{s['grindSteps']} ({s['grindXP']})",
                     f"{s['xpData']} ({s['xpDataUnknownQuests']})", f"{'>=' if s['xpAwardedIsLowerBound'] else ''}{s['xpAwarded']} {s['xpAwardedLabel']}",
                     f"{s['finalLevel']} {s['finalLevelLabel']}", s["zoneSizeLabel"],
                     f"{fmt_time(s['modelledSeconds'])} {s['modelledLabel']}",
                     f"{fmt_time(s['knownPartSeconds'])} {s['knownPartLabel']}",
                     f"{s['unknownSteps']}/{s['steps']}", f"{s['pathMapPct']}"))
    widths = [max(len(h), *(len(r[i]) for r in rows)) for i, h in enumerate(hdr)]
    out = ["  ".join(h.ljust(w) for h, w in zip(hdr, widths)),
           "  ".join("-" * w for w in widths)]
    out += ["  ".join(c.ljust(w) for c, w in zip(r, widths)) for r in rows]
    gaps = [r for r in results if r.get("gap") or (r.get("summary") or {}).get("gap")]
    notes = ["", "Labels: V verified, O observed, E estimated/placeholder, U unknown. Nothing here is V.",
             "modelled = full modelled /played time; U whenever any step has an unknown term. Combat is U",
             "everywhere (kill counts, kill times and drop rates are not in the data); travel is E where the",
             "map has bounds (yd = zone size label: O from QuestieDB bounds, U = no bounds, travel U).",
             "known part = sum of the modelled terms (travel, interaction placeholders); a lower bound, not a time.",
             ">= before XP: some quests have no XP in the data, so the sum is a lower bound and labelled U.",
             "end lvl is U when XP is a lower bound or GRIND steps (time U) were needed.",
             "path map% = straight-line path length in map-percent units (same-map legs only).",
             "grind (XP) = GRIND steps inserted when no quest is level-feasible, and the XP they must supply",
             "(E: Classic XP table; includes kill XP from objectives, which the model does not count)."]
    nosize = sorted({m for r in results for m in (r.get("summary") or {}).get("mapsWithoutSize", [])})
    if nosize:
        notes.append("Maps visited without zone bounds (travel U there): " + ", ".join(map(str, nosize)))
    for g in gaps:
        notes.append("GAP: " + (g.get("gap") or g["summary"]["gap"]))
    return "\n".join(out + notes)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--race", type=int, action="append", help="raceID (repeatable)")
    ap.add_argument("--all", action="store_true", help="all playable starts")
    ap.add_argument("--class", dest="cls", default=DEFAULT_CLASS, choices=sorted(M.CLASSES) + ["none"],
                    help=f"class (default {DEFAULT_CLASS}); 'none' keeps class-free quests only")
    ap.add_argument("--no-grind", dest="grind", action="store_false",
                    help="stop at the first level gate instead of inserting GRIND steps")
    ap.add_argument("--max-req-level", type=int, default=DEFAULT_MAX_REQ_LEVEL,
                    help=f"baseline window: max required level (default {DEFAULT_MAX_REQ_LEVEL}; 0 = no cap)")
    ap.add_argument("--max-quest-level", type=int, default=None,
                    help=f"baseline window: max quest level (default max-req-level + {QUEST_LEVEL_MARGIN}; 0 = no cap)")
    ap.add_argument("--zone-sizes", help="JSON {uiMap: [width_yd, height_yd, label]}")
    ap.add_argument("--params", help="JSON TimeModel overrides {name: {value, label, note}}")
    ap.add_argument("--steps", action="store_true", help="print the step list")
    ap.add_argument("--lua", action="store_true", help="print the route in P2 format (stdout only)")
    ap.add_argument("--write-guides", action="store_true",
                    help="regenerate Guides/Baseline_Starts.lua (all supported starts, every class)")
    ap.add_argument("--json", action="store_true", help=f"write JSON to {os.path.relpath(M.CACHE_DIR, M.REPO)}/")
    args = ap.parse_args(argv)
    if args.cls == "none":
        args.cls = None
    races = list(START_RACES) if args.all else (args.race or [])
    if args.write_guides:
        world = M.World()
        text = render_guides(world)
        os.makedirs(os.path.dirname(GUIDES_FILE), exist_ok=True)
        with open(GUIDES_FILE, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"wrote {os.path.relpath(GUIDES_FILE, M.REPO)}")
        for g, res in guide_results(world):
            s_ = res["summary"]
            print(f"  {res['route']['id']:<22} races {','.join(map(str, g)):<5} quests {s_['quests']:>3} "
                  f"steps {s_['steps']:>3} grind {s_['grindSteps']} skipped {s_['excluded']}")
        if not races:
            return 0
    if not races:
        ap.error("give --race <raceID> or --all")
    for r in races:
        if r not in M.RACES:
            ap.error(f"unknown raceID {r}")

    world = M.World()
    model = M.TimeModel.from_overrides(args.params)
    sizes = M.ZoneSizes.load(overrides=args.zone_sizes)
    results = []
    for r in races:
        res = build_baseline(world, r, args.cls, model, sizes, grind=args.grind,
                             max_req_level=args.max_req_level or None,
                             max_quest_level=args.max_quest_level)
        results.append(res)
        if res.get("gap"):
            continue
        if args.steps:
            print(f"# {res['summary']['raceName']} ({r}) {len(res['route']['steps'])} steps")
            for s in res["route"]["steps"]:
                e = s["est"]
                q = s.get("quest")
                qn = world.export.quests.get(q, {}).get("name", "") if q else ""
                print(f"  {s['id']:<28} {s['type']:<9} {qn[:34]:<34} sec={e['seconds']} xp={e['xp']} src={e['src']}"
                      f" unknown={','.join(s['_model']['unknown'])}")
        if args.lua:
            print(route_lua(res["route"]))
        if args.json:
            os.makedirs(M.CACHE_DIR, exist_ok=True)
            name = f"baseline_r{r}" + (f"_{args.cls.lower()}" if args.cls else "") + ".json"
            with open(os.path.join(M.CACHE_DIR, name), "w", encoding="utf-8") as f:
                json.dump(res, f, indent=1, sort_keys=True)
    print(summary_table(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
