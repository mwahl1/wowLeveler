-- Declarative conditions (spec 3.4): ns.GuideConditions.Eval(cond, state) -> true | false | nil.
-- nil means "unknown" (missing state or unknown key) and must never be treated as true.

return function(T)
  local function setup()
    local ns = T.addon("Horde", "WARRIOR") -- read-only use
    T.needModule(ns, "GuideConditions")
    return ns.GuideConditions.Eval
  end

  -- each case: { cond, state-overrides, expected }; expected may be true/false/"nil"
  local function run(eval, key, cases)
    for i, c in ipairs(cases) do
      local got = eval(c[1], T.state(c[2]))
      local want = c[3]
      if want == "nil" then want = nil end
      T.eq(got, want, key .. " case " .. i)
    end
  end

  T.test("nil / empty condition holds; non-table -> nil", function()
    local eval = setup()
    T.eq(eval(nil, T.state{}), true, "nil cond")
    T.eq(eval({}, T.state{}), true, "empty cond")
    T.eq(eval("minLevel", T.state{}), nil, "string cond")
  end)

  T.test("minLevel / maxLevel / level", function()
    local eval = setup()
    run(eval, "minLevel", {
      { { minLevel = 5 }, { level = 5 }, true }, { { minLevel = 5 }, { level = 4 }, false },
      { { minLevel = 5 }, { level = T.NIL }, "nil" } })
    run(eval, "maxLevel", {
      { { maxLevel = 5 }, { level = 5 }, true }, { { maxLevel = 5 }, { level = 6 }, false },
      { { maxLevel = 5 }, { level = T.NIL }, "nil" } })
    run(eval, "level", {
      { { level = 12 }, { level = 12 }, true }, { { level = 12 }, { level = 13 }, true },
      { { level = 12 }, { level = 11 }, false }, { { level = 12 }, { level = T.NIL }, "nil" } })
  end)

  T.test("races / classes", function()
    local eval = setup()
    run(eval, "races", {
      { { races = { 2, 8 } }, { raceID = 8 }, true }, { { races = { 2, 8 } }, { raceID = 5 }, false },
      { { races = { 96 } }, { raceID = 96 }, true }, { { races = { 2 } }, { raceID = T.NIL }, "nil" } })
    run(eval, "classes", {
      { { classes = { "WARLOCK" } }, { classFile = "WARLOCK" }, true },
      { { classes = { "WARLOCK" } }, { classFile = "MAGE" }, false },
      { { classes = { "WARLOCK" } }, { classFile = T.NIL }, "nil" } })
  end)

  T.test("completed / notCompleted / inLog", function()
    local eval = setup()
    run(eval, "completed", {
      { { completed = { 788, 790 } }, { completed = { [788] = true, [790] = true } }, true },
      { { completed = { 788, 790 } }, { completed = { [788] = true } }, false },
      { { completed = { 788 } }, { completed = T.NIL }, "nil" } })
    run(eval, "notCompleted", {
      { { notCompleted = { 788, 790 } }, {}, true },
      { { notCompleted = { 788, 790 } }, { completed = { [790] = true } }, false },
      { { notCompleted = { 788 } }, { completed = T.NIL }, "nil" } })
    local active = { complete = false, objectives = {} }
    run(eval, "inLog", {
      { { inLog = { 788, 790 } }, { log = { [788] = active, [790] = active } }, true },
      { { inLog = { 788, 790 } }, { log = { [788] = active } }, false },
      { { inLog = { 788 } }, { log = T.NIL }, "nil" } })
  end)

  T.test("xpFraction", function()
    local eval = setup()
    local c = { xpFraction = { level = 12, fraction = 0.5 } }
    run(eval, "xpFraction", {
      { c, { level = 13 }, true }, { c, { level = 11 }, false },
      { c, { level = 12, xp = 500, xpMax = 1000 }, true }, { c, { level = 12, xp = 499, xpMax = 1000 }, false },
      { c, { level = 12, xp = T.NIL, xpMax = T.NIL }, "nil" }, { c, { level = T.NIL }, "nil" } })
  end)

  T.test("map", function()
    local eval = setup()
    run(eval, "map", {
      { { map = 1411 }, { map = 1411 }, true }, { { map = 1411 }, { map = 1413 }, false },
      { { map = 1411 }, {}, "nil" } }) -- map nil by default (hidden / instance)
  end)

  T.test("spellKnown / item", function()
    local eval = setup()
    run(eval, "spellKnown", {
      { { spellKnown = { 688 } }, { knownSpells = { [688] = true } }, true },
      { { spellKnown = { 688 } }, { knownSpells = {} }, false },
      { { spellKnown = { 688 } }, {}, "nil" } })
    run(eval, "item", {
      { { item = { 6948, 1 } }, { itemCounts = { [6948] = 1 } }, true },
      { { item = { 4604, 5 } }, { itemCounts = { [4604] = 4 } }, false },
      { { item = { 4604, 5 } }, { itemCounts = {} }, false },
      { { item = { 4604, 5 } }, {}, "nil" } })
  end)

  T.test("setting", function()
    local eval = setup()
    run(eval, "setting", {
      { { setting = "deathSkips" }, { settings = { deathSkips = true } }, true },
      { { setting = "deathSkips" }, { settings = { deathSkips = false } }, false },
      { { setting = "deathSkips" }, { settings = {} }, false },
      { { setting = "deathSkips" }, {}, "nil" } })
  end)

  T.test("unknown key -> nil, never true; false still wins", function()
    local eval = setup()
    T.eq(eval({ bogusKey = 1 }, T.state{}), nil, "unknown key alone")
    T.eq(eval({ bogusKey = 1, minLevel = 1 }, T.state{ level = 5 }), nil, "unknown + true")
    T.eq(eval({ bogusKey = 1, minLevel = 10 }, T.state{ level = 5 }), false, "unknown + false")
    local ns = T.addon("Horde", "WARRIOR")
    if ns.GuideConditions.UnknownKeys then
      T.eq(ns.GuideConditions.UnknownKeys({ zeta = 1, alpha = 2, minLevel = 3 }), { "alpha", "zeta" }, "UnknownKeys")
      T.eq(ns.GuideConditions.UnknownKeys({ minLevel = 3 }), nil, "UnknownKeys none")
    end
  end)

  T.test("AND semantics across keys", function()
    local eval = setup()
    local c = { minLevel = 5, races = { 2 }, completed = { 788 } }
    T.eq(eval(c, T.state{ level = 5, raceID = 2, completed = { [788] = true } }), true, "all hold")
    T.eq(eval(c, T.state{ level = 5, raceID = 5, completed = { [788] = true } }), false, "one false")
    T.eq(eval(c, T.state{ level = 5, raceID = T.NIL, completed = { [788] = true } }), nil, "one unknown")
  end)
end
