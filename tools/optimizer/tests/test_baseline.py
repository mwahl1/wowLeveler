import json
import os
import subprocess
import sys
import unittest

from _shared import B, M, world

PLAYABLE = (1, 2, 3, 4, 5, 6, 7, 8, 95)
_CACHE = {}


def run(race, **kw):
    key = (race, tuple(sorted(kw.items())))
    if key not in _CACHE:
        _CACHE[key] = B.build_baseline(world(), race, **kw)
    return _CACHE[key]


def positions(route):
    acc, turn = {}, {}
    for i, s in enumerate(route["steps"]):
        if s["type"] == "ACCEPT":
            acc[s["quest"]] = i
        elif s["type"] == "TURNIN":
            turn[s["quest"]] = i
    return acc, turn


# --------------------------------------------------------------------------------------------
# Synthetic data: a fake World exposing only what select_quests/order_quests read
# --------------------------------------------------------------------------------------------

class _FakeExport:
    def __init__(self, ids):
        self.quests = {i: {} for i in ids}


class FakeWorld:
    MAP = 9999

    def __init__(self, quests, outside=(), blacklist=()):
        """quests: {qid: dict of record fields (+ raw fields under 'raw')}; outside: IDs that exist
        in the database but not in the start map."""
        self.recs = {}
        for qid, f in quests.items():
            f = dict(f)
            raw = f.pop("raw", {})
            rec = {"NAME": f"q{qid}", "MAP": self.MAP, "LEVEL": 1, "REQ_LEVEL": 1, "XP": 100}
            rec.update(f)
            self.recs[qid] = (raw, rec)
        for qid in outside:
            self.recs[qid] = ({}, {"NAME": f"q{qid}", "MAP": 1, "LEVEL": 1, "REQ_LEVEL": 1})
        self.export = _FakeExport(self.recs)
        self.blacklist = set(blacklist)

    def quests(self, faction, cls=None):
        return self.recs


def select(quests, outside=(), blacklist=(), **kw):
    w = FakeWorld(quests, outside, blacklist)
    cand, edges, excluded = B.select_quests(w, 2, "WARRIOR", FakeWorld.MAP, **kw)
    order = B.order_quests(cand, edges, excluded, M.TimeModel(), grind=True)
    return order, excluded


class SyntheticRuleTests(unittest.TestCase):
    def test_blacklist_excludes_quest_and_dependents(self):
        order, excluded = select({1: {}, 2: {"PRE_ALL": [1]}, 3: {}}, blacklist=(1,))
        self.assertEqual(order, [3])
        self.assertEqual(excluded[1], "questie_blacklist")
        self.assertEqual(excluded[2], "prereq_blacklisted:1")

    def test_negative_pre_all_needs_the_quest_itself(self):
        # 1 is outside the map; 2 is in 1's exclusive group. +1 accepts the exclusiveTo fallback,
        # -1 must not (spec 6.7).
        fw = FakeWorld({2: {}, 10: {"PRE_ALL": [1]}, 11: {"PRE_ALL": [-1]}}, outside=(1,))
        fw.recs[1][1]["EXCLUSIVE"] = [2]
        cand, edges, excl = B.select_quests(fw, 2, "WARRIOR", FakeWorld.MAP)
        self.assertIn(10, cand)
        self.assertEqual(edges[10], {2})
        self.assertNotIn(11, cand)
        self.assertEqual(excl[11], "prereq_outside:1")

    def test_negative_pre_all_in_route(self):
        order, excluded = select({1: {"LEVEL": 5}, 11: {"PRE_ALL": [-1]}})
        self.assertEqual(order, [1, 11])

    def test_negative_pre_any(self):
        order, excluded = select({3: {"LEVEL": 2}, 12: {"PRE_ANY": [3, -4]}, 13: {"PRE_ANY": [-4, 5]}},
                                 outside=(5,))
        self.assertIn(12, order)
        self.assertLess(order.index(3), order.index(12))
        self.assertEqual(excluded[13], "negative_pre_any")

    def test_pre_any_takes_precedence_over_pre_all(self):
        order, excluded = select({3: {}, 14: {"PRE_ANY": [3], "PRE_ALL": [99]}}, outside=(99,))
        self.assertEqual(order, [3, 14])
        self.assertNotIn(14, excluded)
        order, excluded = select({15: {"PRE_ALL": [99]}}, outside=(99,))
        self.assertEqual(excluded[15], "prereq_outside:99")

    def test_level_window(self):
        order, excluded = select({1: {}, 2: {"REQ_LEVEL": 13, "LEVEL": 14}, 3: {"REQ_LEVEL": 12, "LEVEL": 60}},
                                 max_req_level=12, max_quest_level=17)
        self.assertEqual(order, [1])
        self.assertEqual(excluded[2], "above_baseline_window:req_level")
        self.assertEqual(excluded[3], "above_baseline_window:quest_level")

    def test_available_until_completed_ordering(self):
        # 20 is only available until 21 is completed; 21 sorts first by level, but must come after.
        order, _ = select({20: {"LEVEL": 5, "raw": {"availableUntilCompleted": 21}}, 21: {"LEVEL": 1}})
        self.assertEqual(order, [20, 21])

    def test_available_starting_with(self):
        order, excluded = select({30: {"LEVEL": 1, "raw": {"availableStartingWith": 31}}, 31: {"LEVEL": 5},
                                  32: {"raw": {"availableStartingWith": 99}}}, outside=(99,))
        self.assertEqual(order, [31, 30])
        self.assertEqual(excluded[32], "available_with_outside:99")


# --------------------------------------------------------------------------------------------
# Real data
# --------------------------------------------------------------------------------------------

class BaselineTests(unittest.TestCase):
    def test_all_starts_handled(self):
        for race in PLAYABLE:
            res = run(race)
            self.assertNotIn("gap", res, race)
            self.assertGreater(res["summary"]["quests"], 0, race)
            self.assertEqual(res["route"]["source"], "optimizer@baseline-" + M.OPTIMIZER_VERSION)

    def test_skyborne_horde_gap_reported(self):
        res = run(96)
        self.assertIn("gap", res)
        self.assertIn("96", res["gap"])
        self.assertIn("GAP", B.summary_table([res]))

    def test_cli_all(self):
        script = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "baseline.py")
        out = subprocess.run([sys.executable, "-B", script, "--all"], capture_output=True, text=True,
                             timeout=300)
        self.assertEqual(out.returncode, 0, out.stderr)
        rows = [l.split()[0] for l in out.stdout.splitlines() if l[:1].isdigit()]
        self.assertEqual(sorted(map(int, rows)), sorted(PLAYABLE + (96,)))
        self.assertIn("GAP: Skyborne Horde (raceID 96)", out.stdout)

    def test_prerequisites_respected(self):
        for race in PLAYABLE:
            res = run(race)
            quests = world().quests(M.RACES[race][2], B.DEFAULT_CLASS)
            acc, turn = positions(res["route"])
            for q in res["order"]:
                rec = quests[q][1]
                pre_any = rec.get("PRE_ANY") or []
                pre_all = [] if pre_any else (rec.get("PRE_ALL") or [])
                if pre_any:
                    done = [p for p in pre_any if p > 0 and p in turn and turn[p] < acc[q]]
                    self.assertTrue(done, f"race {race} quest {q}: no PRE_ANY done before accept")
                for p in pre_all:
                    if p < 0:  # negative: the quest itself, no exclusiveTo fallback
                        self.assertIn(-p, turn, (race, q, p))
                        self.assertLess(turn[-p], acc[q], (race, q, p))
                    elif p in turn:
                        self.assertLess(turn[p], acc[q], f"race {race} quest {q} before prereq {p}")
                    else:
                        alts = quests.get(p, (None, {}))[1].get("EXCLUSIVE") or []
                        self.assertTrue(any(a in turn and turn[a] < acc[q] for a in alts), (race, q, p))
                nxt = rec.get("NEXT")
                if nxt in acc:
                    self.assertLess(turn[q], acc[nxt], f"race {race}: {q} must precede its next {nxt}")
                bc = rec.get("BREADCRUMB_FOR")
                if bc in acc:
                    self.assertLess(turn[q], acc[bc], f"race {race}: breadcrumb {q} before {bc}")
                until = quests[q][0].get("availableUntilCompleted")
                if until in acc:
                    self.assertLess(acc[q], acc[until], (race, q, until))

    def test_step_shape_and_order(self):
        res = run(2)
        acc, turn = positions(res["route"])
        ids = [s["id"] for s in res["route"]["steps"]]
        self.assertEqual(len(ids), len(set(ids)))
        for q in res["order"]:
            self.assertLess(acc[q], turn[q])
        for s in res["route"]["steps"]:
            self.assertIn(s["type"], ("ACCEPT", "OBJECTIVE", "COMPLETE", "TURNIN", "GRIND"))
            self.assertEqual(set(s["est"]), {"seconds", "xp", "src"})
        self.assertNotIn("when", res["route"])
        self.assertEqual(res["route"]["exit"], {"completed": res["order"]})

    def test_class_restriction_on_steps(self):
        res = run(2)
        quests = world().quests("Horde", "WARRIOR")
        for s in res["route"]["steps"]:
            if s.get("quest"):
                classes = quests[s["quest"]][1].get("CLASSES") or 0
                restricted = classes and classes & M.ALL_CLASSES_MASK != M.ALL_CLASSES_MASK
                inherited = len(res["applicability"][s["quest"]][0]) < len(M.CLASSES)
                self.assertEqual(s.get("when"), {"classes": ["WARRIOR"]} if restricted or inherited else None,
                                 s["id"])
                if restricted:
                    self.assertTrue(inherited)
        # 794 follows 792 (all classes but Warlock), so it inherits the restriction
        self.assertNotIn("WARLOCK", res["applicability"][794][0])

    def test_no_grind_mode(self):
        for race in PLAYABLE:
            res = run(race, grind=False)
            self.assertEqual(res["summary"]["grindSteps"], 0)
            self.assertNotIn("GRIND", [s["type"] for s in res["route"]["steps"]])

    def test_grind_steps_precede_gated_quests(self):
        quests = world().quests("Alliance", "WARRIOR")
        res = run(95)  # Skyborne: quest XP alone does not reach level 2 under the E XP table
        steps = res["route"]["steps"]
        self.assertIn("GRIND", [s["type"] for s in steps])
        level = 1
        for i, s in enumerate(steps):
            if s["type"] == "GRIND":
                self.assertEqual(s["est"]["src"], "U")
                self.assertIsNone(s["est"]["seconds"])
                self.assertGreater(s["target"]["level"], level)
                nxt = steps[i + 1]
                self.assertEqual(nxt["type"], "ACCEPT")
                self.assertEqual(nxt["_model"]["level"], s["target"]["level"])
            if s["type"] == "ACCEPT":
                level = s["_model"]["level"]
                self.assertLessEqual(quests[s["quest"]][1].get("REQ_LEVEL") or 1, level, s["id"])

    def test_window_excludes_high_level_quests(self):
        res = run(6)
        self.assertEqual(res["excluded"].get(99196), "above_baseline_window:quest_level")
        quests = world().quests("Horde", "WARRIOR")
        for q in res["order"]:
            self.assertLessEqual(quests[q][1].get("LEVEL") or 0, 17)
            self.assertLessEqual(quests[q][1].get("REQ_LEVEL") or 1, 12)

    def test_no_estimate_is_verified(self):
        for race in PLAYABLE:
            res = run(race)
            s = res["summary"]
            labels = [st["est"]["src"] for st in res["route"]["steps"]]
            labels += [s["modelledLabel"], s["knownPartLabel"], s["xpAwardedLabel"], s["finalLevelLabel"]]
            self.assertNotIn("V", labels, race)
            for st in res["route"]["steps"]:
                if st["est"]["seconds"] is None:
                    self.assertEqual(st["est"]["src"], "U")

    def test_hidden_unknowns_are_not_labelled_E(self):
        for race in PLAYABLE:
            s = run(race)["summary"]
            if s["xpDataUnknownQuests"]:
                self.assertEqual(s["xpAwardedLabel"], "U", race)
                self.assertTrue(s["xpAwardedIsLowerBound"])
            if s["xpDataUnknownQuests"] or s["grindSteps"]:
                self.assertEqual(s["finalLevelLabel"], "U", race)
            if s["unknownSteps"]:
                self.assertIsNone(s["modelledSeconds"])
                self.assertEqual(s["modelledLabel"], "U")

    def test_travel_uses_zone_bounds(self):
        s = run(2)["summary"]
        self.assertEqual(s["zoneSizeLabel"], "O")
        steps = run(2)["route"]["steps"]
        travel = [st["_model"]["terms"]["travel"] for st in steps if st["_model"]["terms"]["travel"][0]]
        self.assertTrue(travel)
        self.assertTrue(all(l == "E" for _, l in travel))  # O geometry x E speed placeholders
        self.assertEqual(run(95)["summary"]["zoneSizeLabel"], "U")  # Zephras Isle has no bounds

    def test_deterministic(self):
        a = B.build_baseline(world(), 4)
        b = B.build_baseline(M.World(), 4)
        self.assertEqual(json.dumps(a, sort_keys=True), json.dumps(b, sort_keys=True))
        self.assertEqual(B.route_lua(a["route"]), B.route_lua(b["route"]))

    def test_lua_output_drops_private_fields(self):
        lua = B.route_lua(run(2)["route"])
        self.assertTrue(lua.startswith("ns.Guides.Register({"))
        self.assertNotIn("_model", lua)


if __name__ == "__main__":
    unittest.main()


class GuideFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = B.render_guides(world())

    def test_file_is_regenerated_identically(self):
        with open(B.GUIDES_FILE, encoding="utf-8") as f:
            on_disk = f.read()
        self.assertEqual(self.text, on_disk, "run: python3 -B tools/optimizer/baseline.py --write-guides")
        self.assertEqual(B.render_guides(M.World()), self.text)

    def test_header_and_starts(self):
        self.assertIn("naive level-ordered baseline, NOT optimized; labels E/U", self.text)
        self.assertIn("local _, ns = ...", self.text)
        self.assertEqual(self.text.count("ns.Guides.Register({"), len(B.GUIDE_STARTS))
        covered = sorted(r for g in B.GUIDE_STARTS for r in g)
        self.assertEqual(covered, sorted(PLAYABLE))
        self.assertIn("races = {2,8}", self.text)
        self.assertIn("races = {3,7}", self.text)
        self.assertIn("Skipped raceID 96", self.text)
        self.assertIn(f'source = "optimizer@baseline-{M.OPTIMIZER_VERSION}"', self.text)
        self.assertNotIn('"V"', self.text)

    def test_all_class_mode(self):
        res = dict(B.guide_results(world()))[(2, 8)]
        steps = {s["id"]: s for s in res["route"]["steps"]}
        when = steps["baseline.start.1411.a792"].get("when")
        self.assertEqual(when, {"classes": sorted(set(M.CLASSES) - {"WARLOCK"})})
        self.assertEqual(steps["baseline.start.1411.a794"].get("when"), when)  # inherited via prereq
        self.assertNotIn(792, res["route"]["exit"]["completed"])
        self.assertIn(788, res["route"]["exit"]["completed"])

    def test_compiles_in_lua(self):
        luac = os.path.expanduser("~/wow-tools/lua-5.1.5/src/luac")
        if not os.path.exists(luac):
            self.skipTest("luac 5.1 not installed")
        out = subprocess.run([luac, "-p", B.GUIDES_FILE], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)


class BlacklistTests(unittest.TestCase):
    def test_missing_audit_file_fails_clearly(self):
        with self.assertRaises(M.BlacklistMissing) as cm:
            M.load_blacklist(os.path.join(M.CACHE_DIR, "does_not_exist.json"))
        self.assertIn("Questie blacklist", str(cm.exception))
        self.assertIn("not found", str(cm.exception))

    def test_overrides_are_not_blacklisted(self):
        bl = M.load_blacklist()
        self.assertFalse(bl["blacklisted"] & bl["overridden"])
        self.assertEqual(world().blacklist, bl["blacklisted"])

    def test_no_blacklisted_quest_in_any_route(self):
        bl = world().blacklist
        for g, res in B.guide_results(world()):
            quests = {s["quest"] for s in res["route"]["steps"] if s.get("quest")}
            self.assertFalse(quests & bl, (g, sorted(quests & bl)))
            for r in g:
                single = run(r)
                self.assertFalse({s.get("quest") for s in single["route"]["steps"]} & bl, r)
        with open(B.GUIDES_FILE, encoding="utf-8") as f:
            text = f.read()
        import re
        ids = {int(m) for m in re.findall(r"quest = (\d+)", text)}
        self.assertFalse(ids & bl, sorted(ids & bl))

    def test_787_absent(self):
        self.assertIn(787, world().blacklist)
        res = dict(B.guide_results(world()))[(2, 8)]
        self.assertNotIn(787, res["order"])
        self.assertEqual(res["excluded"].get(787), "questie_blacklist")

    def test_orc_troll_first_step(self):
        res = dict(B.guide_results(world()))[(2, 8)]
        first = res["route"]["steps"][0]
        self.assertEqual(first["type"], "ACCEPT")
        self.assertIn(first["quest"], world().start(2)["quests"])
        self.assertNotIn(first["quest"], world().blacklist)
        self.assertEqual(world().start(2)["quests"], world().start(8)["quests"])

    def test_hidden_on_map_quests_stay(self):
        hidden = M.load_blacklist()["hiddenOnMap"] - world().blacklist
        for g, res in B.guide_results(world()):
            for q, reason in res["excluded"].items():
                if q in hidden:
                    self.assertNotEqual(reason, "questie_blacklist")
