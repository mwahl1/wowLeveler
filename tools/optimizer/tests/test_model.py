import unittest

from _shared import M, world


class LabelTests(unittest.TestCase):
    def test_worst_label(self):
        self.assertEqual(M.worst_label("V", "E", "O"), "E")
        self.assertEqual(M.worst_label("O", "U"), "U")
        self.assertEqual(M.worst_label(), "U")

    def test_no_parameter_is_verified(self):
        for name, p in M.TimeModel().params():
            self.assertIn(p.label, ("O", "E", "U"), name)

    def test_placeholders_are_marked(self):
        for name, p in M.TimeModel().params():
            if p.label == "E":
                self.assertIn("placeholder", p.note, name)
            if p.label == "U":
                self.assertIsNone(p.value, name)

    def test_override_rejects_bad_label(self):
        m = M.TimeModel()
        with self.assertRaises(ValueError):
            m.override("run_speed", 7, "X")
        m.override("kill_s_same_level", 12.0, "O", "recorder")
        self.assertTrue(m.kill_s_same_level.known)


class DistanceTests(unittest.TestCase):
    def test_map_pct(self):
        self.assertAlmostEqual(M.dist_map_pct((1411, 0, 0), (1411, 3, 4)), 5.0)
        self.assertIsNone(M.dist_map_pct((1411, 0, 0), (1412, 3, 4)))

    def test_yards_unknown_without_zone_size(self):
        self.assertEqual(M.dist_yards((1411, 0, 0), (1411, 3, 4), M.ZoneSizes()), (None, "U"))

    def test_yards_with_override(self):
        sizes = M.ZoneSizes({"1411": [1000, 2000, "O"]})
        yd, label = M.dist_yards((1411, 0, 0), (1411, 3, 4), sizes)
        self.assertAlmostEqual(yd, ((30) ** 2 + (80) ** 2) ** 0.5)
        self.assertEqual(label, "O")

    def test_default_zone_sizes_are_empty(self):
        self.assertEqual(M.ZoneSizes().table, {})

    def test_zone_bounds_loaded(self):
        sizes = M.ZoneSizes.load()
        w, h, label = sizes.get(1411)
        self.assertEqual(label, "O")
        self.assertGreater(w, 0)
        self.assertEqual(sizes.missing([1411, 2521, 2548, 2482, 2652, 2524]), [2482, 2521, 2524, 2548, 2652])

    def test_override_wins(self):
        import json, os
        d = os.path.join(M.CACHE_DIR, "test")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "sizes.json")
        with open(path, "w") as f:
            json.dump({"2521": [1000, 1000, "V"], "1411": [1, 1, "E"]}, f)
        sizes = M.ZoneSizes.load(overrides=path)
        self.assertEqual(sizes.get(2521), (1000.0, 1000.0, "V"))
        self.assertEqual(sizes.get(1411), (1.0, 1.0, "E"))

    def test_nearest(self):
        pts = [(2, 5, 5), (1, 9, 9), (1, 1, 1)]
        self.assertEqual(M.nearest((2, 0, 0), pts), (2, 5, 5))
        self.assertEqual(M.nearest(None, pts), (1, 1, 1))          # map with most points, lowest x/y
        self.assertEqual(M.nearest(None, list(reversed(pts))), (1, 1, 1))
        self.assertEqual(M.nearest((3, 0, 0), pts), (1, 1, 1))
        self.assertIsNone(M.nearest(None, []))

    def test_travel_estimate(self):
        m = M.TimeModel()
        tr = M.travel_estimate((1411, 0, 0), (1411, 3, 4), m, M.ZoneSizes())
        self.assertIsNone(tr["seconds"])
        self.assertEqual(tr["label"], "U")
        tr = M.travel_estimate((1411, 0, 0), (1411, 3, 4), m, M.ZoneSizes({1411: [700, 700, "O"]}))
        self.assertAlmostEqual(tr["seconds"], 35 * 1.3 / 7.0)
        self.assertEqual(tr["label"], "E")  # run speed / terrain factor are placeholders


class XPTests(unittest.TestCase):
    def test_falloff(self):
        m = M.TimeModel()
        self.assertEqual(M.xp_fraction(10, 10, m), (1.0, "E"))
        self.assertEqual(M.xp_fraction(16, 10, m), (0.8, "E"))
        self.assertEqual(M.xp_fraction(40, 10, m), (0.1, "E"))
        self.assertEqual(M.xp_fraction(10, None, m), (None, "U"))

    def test_xp_table_bounds(self):
        m = M.TimeModel()
        self.assertEqual(M.xp_needed(1, m), 400)
        self.assertIsNone(M.xp_needed(60, m))


class LuaReaderTests(unittest.TestCase):
    def test_parse(self):
        t = M.parse_lua_table('{a=1,b={2,3},[5]={x="y"},c=true}')
        self.assertEqual(t, {"a": 1, "b": [2, 3], 5: {"x": "y"}, "c": True})

    def test_meta_starts(self):
        meta = M.load_meta()
        starts = meta["startingQuests"]
        for race in (1, 2, 3, 4, 5, 6, 7, 8, 95):
            self.assertTrue(starts[race]["map"], race)
        self.assertNotIn("map", starts[96])


class WorldTests(unittest.TestCase):
    def test_quest_lookup(self):
        q = world().quests("Horde", "WARRIOR")
        self.assertEqual(q[788][1]["NAME"], "Cutting Teeth")
        self.assertEqual(q[788][1]["MAP"], 1411)
        self.assertNotIn(783, q)  # Human-only quest

    def test_spawns_are_map_points(self):
        pts, label = world().spawns("Npc", 3143, "Horde")  # Gornek
        self.assertTrue(pts)
        self.assertEqual(pts[0][0], 1411)
        self.assertIn(label, ("O", "E"))

    def test_item_points(self):
        pts, _ = world().item_points(4862, "Horde")  # Scorpid Worker Tail drops
        self.assertTrue(pts)


if __name__ == "__main__":
    unittest.main()
