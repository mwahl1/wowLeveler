-- Availability rules (spec 6.7 and 8a), checked against synthetic quests injected into a
-- private namespace. Each test skips when ns.Availability or a schema field it needs is absent.

local MISSING_ID = 8999999 -- never present in the data (asserted)

return function(T)
  -- One uncached namespace for the whole file: injected quests must never leak into the
  -- cached namespaces the data smoke tests count.
  local shared
  local function setup(...)
    shared = shared or T.fresh("Horde", "WARRIOR")
    if not shared.Availability or type(shared.Availability.Check) ~= "function" then
      T.skip("ns.Availability.Check not present (Guide/Availability.lua not loaded)")
    end
    T.needFields(shared, ...)
    return shared, shared.Availability.Check
  end

  -- inject a fresh synthetic quest and return its ID
  local function quest(ns, fields)
    local id = T.newID()
    T.inject(ns, id, fields)
    return id
  end

  local function active() return { complete = false, objectives = {} } end

  local function expect(check, id, state, status, reasonPrefix, msg)
    local s, r = check(id, state)
    T.eq(s, status, (msg or ("quest " .. id)) .. " status (reason " .. tostring(r) .. ")")
    if reasonPrefix then
      T.ok(type(r) == "string" and r:sub(1, #reasonPrefix) == reasonPrefix,
        (msg or ("quest " .. id)) .. ": reason " .. tostring(r) .. " should start with " .. reasonPrefix)
    end
  end

  T.test("plain quest is AVAILABLE", function()
    local ns, check = setup()
    local q = quest(ns, {})
    expect(check, q, T.state{}, "AVAILABLE")
  end)

  T.test("unknown quest ID -> UNKNOWN no_data", function()
    local ns, check = setup()
    T.eq(ns.Data.GetQuest(MISSING_ID), nil, "MISSING_ID absent from data")
    expect(check, MISSING_ID, T.state{}, "UNKNOWN", "no_data")
  end)

  T.test("completed -> COMPLETED", function()
    local ns, check = setup()
    local q = quest(ns, {})
    expect(check, q, T.state{ completed = { [q] = true } }, "COMPLETED")
  end)

  T.test("in log -> ACTIVE", function()
    local ns, check = setup()
    local q = quest(ns, {})
    expect(check, q, T.state{ log = { [q] = active() } }, "ACTIVE")
  end)

  T.test("race mismatch -> UNAVAILABLE race", function()
    local ns, check = setup()
    local B = ns.DataSchema.RACE_BIT
    local q = quest(ns, { RACES = B[1] + B[95] }) -- Human + Skyborne Alliance
    expect(check, q, T.state{ raceID = 2 }, "UNAVAILABLE", "race")
    expect(check, q, T.state{ raceID = 96 }, "UNAVAILABLE", "race", "Skyborne Horde vs bit 32")
    local sky = quest(ns, { RACES = B[96] })
    expect(check, sky, T.state{ raceID = 96 }, "AVAILABLE", nil, "bit 33 allows Skyborne Horde")
  end)

  T.test("class mismatch -> UNAVAILABLE class", function()
    local ns, check = setup()
    local q = quest(ns, { CLASSES = ns.DataSchema.CLASS_BIT.MAGE })
    expect(check, q, T.state{ classFile = "WARRIOR" }, "UNAVAILABLE", "class")
    expect(check, q, T.state{ classFile = "MAGE" }, "AVAILABLE")
  end)

  T.test("PRE_ANY: any one completed", function()
    local ns, check = setup("PRE_ANY")
    local a, b = quest(ns, {}), quest(ns, {})
    local q = quest(ns, { PRE_ANY = { a, b } })
    expect(check, q, T.state{}, "UNAVAILABLE", "prereq", "none done")
    expect(check, q, T.state{ completed = { [b] = true } }, "AVAILABLE", nil, "one done")
  end)

  T.test("PRE_ALL: all must be completed", function()
    local ns, check = setup("PRE_ALL")
    local a, b = quest(ns, {}), quest(ns, {})
    local q = quest(ns, { PRE_ALL = { a, b } })
    expect(check, q, T.state{ completed = { [a] = true } }, "UNAVAILABLE", "prereq", "one of two done")
    expect(check, q, T.state{ completed = { [a] = true, [b] = true } }, "AVAILABLE", nil, "both done")
  end)

  T.test("PRE_ALL positive entry satisfied by its exclusiveTo", function()
    local ns, check = setup("PRE_ALL", "EXCLUSIVE")
    local alt = quest(ns, {})
    local pre = quest(ns, { EXCLUSIVE = { alt } })
    T.inject(ns, alt, { EXCLUSIVE = { pre } })
    local q = quest(ns, { PRE_ALL = { pre } })
    expect(check, q, T.state{ completed = { [alt] = true } }, "AVAILABLE", nil, "exclusive sibling completed")
  end)

  T.test("PRE_ALL negative entry -X needs X itself, no exclusiveTo fallback", function()
    local ns, check = setup("PRE_ALL", "EXCLUSIVE")
    local alt = quest(ns, {})
    local pre = quest(ns, { EXCLUSIVE = { alt } })
    T.inject(ns, alt, { EXCLUSIVE = { pre } })
    local q = quest(ns, { PRE_ALL = { -pre } })
    expect(check, q, T.state{ completed = { [alt] = true } }, "UNAVAILABLE", nil, "only sibling completed")
    expect(check, q, T.state{ completed = { [pre] = true } }, "AVAILABLE", nil, "X completed")
  end)

  T.test("negative entry inside PRE_ANY -> UNKNOWN negative_pre_any", function()
    local ns, check = setup("PRE_ANY")
    local pre = quest(ns, {})
    local q = quest(ns, { PRE_ANY = { -pre } })
    expect(check, q, T.state{}, "UNKNOWN", "negative_pre_any")
    expect(check, q, T.state{ completed = { [pre] = true } }, "UNKNOWN", "negative_pre_any", "even with X done")
  end)

  T.test("prerequisite missing from DB -> UNKNOWN missing_prereq", function()
    local ns, check = setup("PRE_ALL", "PRE_ANY")
    T.eq(ns.Data.GetQuest(MISSING_ID), nil, "MISSING_ID absent from data")
    local q = quest(ns, { PRE_ALL = { MISSING_ID } })
    expect(check, q, T.state{}, "UNKNOWN", "missing_prereq", "PRE_ALL")
    local q2 = quest(ns, { PRE_ANY = { MISSING_ID } })
    expect(check, q2, T.state{}, "UNKNOWN", "missing_prereq", "PRE_ANY")
  end)

  T.test("NEXT completed or active -> UNAVAILABLE", function()
    local ns, check = setup("NEXT")
    local nxt = quest(ns, {})
    local q = quest(ns, { NEXT = nxt })
    expect(check, q, T.state{ completed = { [nxt] = true } }, "UNAVAILABLE", "next_in_chain", "next completed")
    expect(check, q, T.state{ log = { [nxt] = active() } }, "UNAVAILABLE", "next_in_chain", "next active")
  end)

  T.test("EXCLUSIVE completed or active -> UNAVAILABLE", function()
    local ns, check = setup("EXCLUSIVE")
    local other = quest(ns, {})
    local q = quest(ns, { EXCLUSIVE = { other } })
    expect(check, q, T.state{ completed = { [other] = true } }, "UNAVAILABLE", "exclusive", "exclusive completed")
    expect(check, q, T.state{ log = { [other] = active() } }, "UNAVAILABLE", "exclusive", "exclusive active")
  end)

  T.test("breadcrumb target active or completed -> breadcrumb UNAVAILABLE", function()
    local ns, check = setup("BREADCRUMB_FOR")
    local target = quest(ns, {})
    local bc = quest(ns, { BREADCRUMB_FOR = target })
    expect(check, bc, T.state{ log = { [target] = active() } }, "UNAVAILABLE", "breadcrumb_target", "target active")
    expect(check, bc, T.state{ completed = { [target] = true } }, "UNAVAILABLE", "breadcrumb_target", "target completed")
    expect(check, bc, T.state{}, "AVAILABLE", nil, "target untouched")
  end)

  T.test("active breadcrumb -> target UNAVAILABLE", function()
    local ns, check = setup("BREADCRUMBS", "BREADCRUMB_FOR")
    local target = T.newID()
    local bc = quest(ns, { BREADCRUMB_FOR = target })
    T.inject(ns, target, { BREADCRUMBS = { bc } })
    expect(check, target, T.state{ log = { [bc] = active() } }, "UNAVAILABLE", "active_breadcrumb")
    expect(check, target, T.state{ completed = { [bc] = true } }, "AVAILABLE", nil, "breadcrumb completed")
  end)

  T.test("DISABLED_BY active -> UNAVAILABLE", function()
    local ns, check = setup("DISABLED_BY")
    local d = quest(ns, {})
    local q = quest(ns, { DISABLED_BY = d })
    expect(check, q, T.state{ log = { [d] = active() } }, "UNAVAILABLE", "disabled_by")
    expect(check, q, T.state{}, "AVAILABLE", nil, "disabler not active")
  end)

  T.test("AVAILABLE_UNTIL completed -> UNAVAILABLE", function()
    local ns, check = setup("AVAILABLE_UNTIL")
    local u = quest(ns, {})
    local q = quest(ns, { AVAILABLE_UNTIL = u })
    expect(check, q, T.state{ completed = { [u] = true } }, "UNAVAILABLE", "available_until")
    expect(check, q, T.state{}, "AVAILABLE", nil, "until-quest not completed")
  end)

  T.test("AVAILABLE_WITH neither active nor completed -> UNAVAILABLE", function()
    local ns, check = setup("AVAILABLE_WITH")
    local w = quest(ns, {})
    local q = quest(ns, { AVAILABLE_WITH = w })
    expect(check, q, T.state{}, "UNAVAILABLE", "available_with")
    expect(check, q, T.state{ log = { [w] = active() } }, "AVAILABLE", nil, "with-quest active")
    expect(check, q, T.state{ completed = { [w] = true } }, "AVAILABLE", nil, "with-quest completed")
  end)

  T.test("level below REQ_LEVEL -> LEVEL_TOO_LOW", function()
    local ns, check = setup("REQ_LEVEL")
    local q = quest(ns, { REQ_LEVEL = 10 })
    expect(check, q, T.state{ level = 9 }, "LEVEL_TOO_LOW")
    expect(check, q, T.state{ level = 10 }, "AVAILABLE")
  end)

  T.test("profession requirement without skills state -> UNKNOWN needs_state:skill", function()
    local ns, check = setup("SKILL")
    local q = quest(ns, { SKILL = { 185, 50 } }) -- Cooking 50
    expect(check, q, T.state{}, "UNKNOWN", "needs_state:skill")
  end)

  T.test("reputation requirement without state -> UNKNOWN needs_state:rep", function()
    local ns, check = setup("MIN_REP", "MAX_REP")
    local q = quest(ns, { MIN_REP = { 76, 3000 } })
    expect(check, q, T.state{}, "UNKNOWN", "needs_state:rep", "MIN_REP")
    local q2 = quest(ns, { MAX_REP = { 76, 3000 } })
    expect(check, q2, T.state{}, "UNKNOWN", "needs_state:rep", "MAX_REP")
  end)

  T.test("spell requirement without knownSpells -> UNKNOWN needs_state:spell", function()
    local ns, check = setup("REQ_SPELL")
    local q = quest(ns, { REQ_SPELL = 2575 })
    expect(check, q, T.state{}, "UNKNOWN", "needs_state:spell")
  end)

  -- Spec 8a "Availability decisions" (2026-11-10) -------------------------------------

  T.test("PRE_ANY: completed positive + negative entry -> satisfied; none completed -> negative_pre_any:<id>", function()
    local ns, check = setup("PRE_ANY")
    local a, n = quest(ns, {}), quest(ns, {})
    local q = quest(ns, { PRE_ANY = { a, -n } })
    expect(check, q, T.state{ completed = { [a] = true } }, "AVAILABLE", nil, "positive completed")
    expect(check, q, T.state{}, "UNKNOWN", "negative_pre_any:" .. tostring(-n), "nothing completed")
    local _, r = check(q, T.state{})
    T.eq(r, "negative_pre_any:" .. tostring(-n), "exact reason")
  end)

  T.test("PRE_ALL mixed: unmet existing entry wins over missing entry", function()
    local ns, check = setup("PRE_ALL")
    local a = quest(ns, {})
    local q = quest(ns, { PRE_ALL = { MISSING_ID, a } })
    expect(check, q, T.state{}, "UNAVAILABLE", "prereq:", "existing unmet + missing")
    expect(check, q, T.state{ completed = { [a] = true } }, "UNKNOWN", "missing_prereq:", "only missing unmet")
  end)

  T.test("missing state: nil raceID/classFile/level -> UNKNOWN needs_state:*", function()
    local ns, check = setup()
    local B, C = ns.DataSchema.RACE_BIT, ns.DataSchema.CLASS_BIT
    local qr = quest(ns, { RACES = B[2] })
    expect(check, qr, T.state{ raceID = T.NIL }, "UNKNOWN", "needs_state:race", "nil raceID")
    local qc = quest(ns, { CLASSES = C.WARRIOR })
    expect(check, qc, T.state{ classFile = T.NIL }, "UNKNOWN", "needs_state:class", "nil classFile")
    local ql = quest(ns, { REQ_LEVEL = 5 })
    expect(check, ql, T.state{ level = T.NIL }, "UNKNOWN", "needs_state:level", "nil level")
  end)

  T.test("deferred UNKNOWN: definite UNAVAILABLE wins over unresolved condition", function()
    local ns, check = setup("SKILL", "EXCLUSIVE")
    local other = quest(ns, {})
    local q = quest(ns, { SKILL = { 185, 50 }, EXCLUSIVE = { other } })
    expect(check, q, T.state{ completed = { [other] = true } }, "UNAVAILABLE", "exclusive", "skill unknown + exclusive done")
    expect(check, q, T.state{}, "UNKNOWN", "needs_state:skill", "only the unresolved condition")
    -- an unresolved prerequisite is deferred too
    local q2 = quest(ns, { PRE_ALL = { MISSING_ID }, EXCLUSIVE = { other } })
    expect(check, q2, T.state{ completed = { [other] = true } }, "UNAVAILABLE", "exclusive", "missing prereq + exclusive done")
  end)

  T.test("REQ_SPEC: needs_state:spec / spec / passes", function()
    local ns, check = setup("REQ_SPEC")
    local q = quest(ns, { REQ_SPEC = 20219 }) -- Gnomish Engineering
    expect(check, q, T.state{}, "UNKNOWN", "needs_state:spec", "no specializations table")
    expect(check, q, T.state{ specializations = {} }, "UNAVAILABLE", "spec", "without it")
    expect(check, q, T.state{ specializations = { [20222] = true } }, "UNAVAILABLE", "spec", "other spec")
    expect(check, q, T.state{ specializations = { [20219] = true } }, "AVAILABLE", nil, "with it")
    -- REQ_SPEC is not a spell: knownSpells must not satisfy it
    expect(check, q, T.state{ knownSpells = { [20219] = true } }, "UNKNOWN", "needs_state:spec", "knownSpells only")
  end)

  T.test("reputation: MIN_REP / MAX_REP thresholds, absent faction, no table", function()
    local ns, check = setup("MIN_REP", "MAX_REP")
    local qmin = quest(ns, { MIN_REP = { 76, 3000 } })
    expect(check, qmin, T.state{ reputations = { [76] = 3000 } }, "AVAILABLE", nil, "MIN_REP equal")
    expect(check, qmin, T.state{ reputations = { [76] = 9000 } }, "AVAILABLE", nil, "MIN_REP above")
    expect(check, qmin, T.state{ reputations = { [76] = 2999 } }, "UNAVAILABLE", "rep", "MIN_REP below")
    expect(check, qmin, T.state{ reputations = { [530] = 9000 } }, "UNAVAILABLE", "rep", "MIN_REP faction absent")
    expect(check, qmin, T.state{}, "UNKNOWN", "needs_state:rep", "MIN_REP no table")
    local qmax = quest(ns, { MAX_REP = { 76, 3000 } })
    expect(check, qmax, T.state{ reputations = { [76] = 2999 } }, "AVAILABLE", nil, "MAX_REP below")
    expect(check, qmax, T.state{ reputations = { [76] = 3000 } }, "UNAVAILABLE", "rep", "MAX_REP equal")
    expect(check, qmax, T.state{ reputations = { [76] = 9000 } }, "UNAVAILABLE", "rep", "MAX_REP above")
    expect(check, qmax, T.state{ reputations = {} }, "UNAVAILABLE", "rep", "MAX_REP faction absent")
    expect(check, qmax, T.state{}, "UNKNOWN", "needs_state:rep", "MAX_REP no table")
  end)

  T.test("REQ_RANKS: negative rank -> unverified; positive ranks OR logic", function()
    local ns, check = setup("REQ_RANKS")
    local neg = quest(ns, { REQ_RANKS = { { 185, -1 } } })
    expect(check, neg, T.state{ skills = { [185] = 300 } }, "UNKNOWN", "unverified:negative_ranks", "negative with skills")
    expect(check, neg, T.state{}, "UNKNOWN", nil, "negative without skills")
    local q = quest(ns, { REQ_RANKS = { { 185, 50 }, { 129, 50 } } })
    expect(check, q, T.state{ skills = { [129] = 60 } }, "AVAILABLE", nil, "second pair satisfied")
    expect(check, q, T.state{ skills = { [185] = 50 } }, "AVAILABLE", nil, "first pair exactly satisfied")
    expect(check, q, T.state{ skills = { [185] = 10, [129] = 49 } }, "UNAVAILABLE", "skill", "neither satisfied")
    expect(check, q, T.state{ skills = {} }, "UNAVAILABLE", "skill", "no skills learned")
    expect(check, q, T.state{}, "UNKNOWN", "needs_state:skill", "no skills table")
  end)

  T.test("MAX_LEVEL: above -> UNAVAILABLE max_level; equal -> not blocked", function()
    local ns, check = setup("MAX_LEVEL")
    local q = quest(ns, { MAX_LEVEL = 20 })
    expect(check, q, T.state{ level = 21 }, "UNAVAILABLE", "max_level", "above")
    expect(check, q, T.state{ level = 20 }, "AVAILABLE", nil, "equal")
  end)

  T.test("performance: Check() over every Horde quest, level-10 Orc, < 50 ms", function()
    local ns = T.addon("Horde", "WARRIOR")
    if not ns.Availability or type(ns.Availability.Check) ~= "function" then
      T.skip("ns.Availability.Check not present")
    end
    local check = ns.Availability.Check
    local ids = {}
    for id in pairs(ns.Data.quests) do ids[#ids + 1] = id end
    local state = T.state{ faction = "Horde", raceID = 2, classFile = "WARRIOR", level = 10,
      completed = { [788] = true, [4641] = true, [790] = true } }
    check(ids[1], state) -- warm up
    local t0 = os.clock()
    local counts = {}
    for i = 1, #ids do
      local s = check(ids[i], state)
      counts[s] = (counts[s] or 0) + 1
    end
    local ms = (os.clock() - t0) * 1000
    print(string.format("INFO  availability perf: %d quests in %.1f ms (AVAILABLE %d, UNAVAILABLE %d, UNKNOWN %d, LEVEL_TOO_LOW %d)",
      #ids, ms, counts.AVAILABLE or 0, counts.UNAVAILABLE or 0, counts.UNKNOWN or 0, counts.LEVEL_TOO_LOW or 0))
    T.ok(#ids > 1000, "checked " .. #ids .. " quests")
    T.ok(ms < 50, string.format("%d quests took %.1f ms (budget 50 ms)", #ids, ms))
  end)
end
