-- Segment selector (spec 6.3, 8a "Selector"): ns.GuideSelector.Choose(route, state, memory).

return function(T)
  local F = T.fixture("routes")

  local function allDone(...)
    local done = {}
    for _, list in ipairs({ ... }) do for _, q in ipairs(list) do done[q] = true end end
    return done
  end

  local function setup(register)
    local ns = T.sandbox("Horde", "WARRIOR")
    T.needModule(ns, "Guides", "GuideSelector", "GuideConditions", "Availability")
    ns.Guides.Reset()
    if register then register(ns) else F.register(ns) end
    local route, problems = ns.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    for _, p in ipairs(problems or {}) do
      T.ok(p.severity ~= "error", "fixture compile error: " .. tostring(p.code) .. " " .. tostring(p.msg))
    end
    return ns, route
  end

  local function orc(o)
    o.faction, o.raceID, o.classFile = "Horde", 2, "WARRIOR"
    return T.state(o)
  end

  T.test("first login at level 1 -> start segment", function()
    local ns, route = setup()
    local seg, sug = ns.GuideSelector.Choose(route, orc{ level = 1 }, {})
    T.eq(seg, F.ORC_START, "segment")
    T.eq(sug, nil, "no suggestion")
  end)

  T.test("start wins while its exit doesn't hold and level <= levels[2]+2", function()
    local ns, route = setup()
    local seg = ns.GuideSelector.Choose(route, orc{ level = 7 }, {})
    T.eq(seg, F.ORC_START, "level 7, nothing done")
    seg = ns.GuideSelector.Choose(route, orc{ level = 8 }, { segment = F.DUROTAR })
    T.eq(seg, F.ORC_START, "level 8 with a remembered segment, start not done")
  end)

  T.test("level 11 with start done -> Barrens 10-20 (highest available XP)", function()
    local ns, route = setup()
    local state = orc{ level = 11, completed = allDone(F.VOT_QUESTS) }
    local S = ns.GuideSelector
    if S.Score then
      T.ok(S.Score(route, F.BARRENS, state) > S.Score(route, F.DUROTAR, state),
        "fixture premise: Barrens outscores Durotar at 11")
    end
    local seg, sug = S.Choose(route, state, {})
    T.eq(seg, F.BARRENS, "segment")
    T.eq(sug, nil, "first choice: no suggestion")
  end)

  T.test("remembered segment kept within tolerance (level <= levels[2]+2)", function()
    local ns, route = setup()
    for _, level in ipairs({ 11, 13, 14 }) do
      local seg, sug = ns.GuideSelector.Choose(route,
        orc{ level = level, completed = allDone(F.VOT_QUESTS) }, { segment = F.DUROTAR })
      T.eq(seg, F.DUROTAR, "kept at level " .. level)
      T.eq(sug, nil, "no suggestion at level " .. level)
    end
  end)

  T.test("level > levels[2]+2 -> current segment plus suggestion, not a silent switch", function()
    local ns, route = setup()
    local state = orc{ level = 15, completed = allDone(F.VOT_QUESTS) }
    local seg, sug = ns.GuideSelector.Choose(route, state, { segment = F.DUROTAR })
    T.eq(seg, F.DUROTAR, "stays on current segment")
    T.ok(type(sug) == "table", "suggestion returned")
    T.eq(sug.kind, "segment", "suggestion kind")
    T.eq(sug.to, F.BARRENS, "suggests Barrens")
    T.ok(type(sug.reason) == "string" and sug.reason ~= "", "suggestion has a reason")
    -- auto-switch is opt-in
    local seg2, sug2 = ns.GuideSelector.Choose(route, state, { segment = F.DUROTAR, autoSwitch = true })
    T.eq(seg2, F.BARRENS, "autoSwitch switches")
    T.eq(sug2, nil, "no suggestion when switching")
  end)

  T.test("unusable remembered segment -> best directly", function()
    local ns, route = setup()
    local state = orc{ level = 11, completed = allDone(F.VOT_QUESTS) }
    local seg, sug = ns.GuideSelector.Choose(route, state, { segment = "no.such.segment" })
    T.eq(seg, F.BARRENS, "unknown remembered id")
    T.eq(sug, nil, "no suggestion")
  end)

  T.test("level-25 join with no fitting segment -> best available segment + reason", function()
    local ns, route = setup()
    local state = orc{ level = 25, completed = allDone(F.VOT_QUESTS) }
    local seg, sug = ns.GuideSelector.Choose(route, state, {})
    T.ok(seg ~= nil and route.segments[seg] ~= nil,
      "a segment is returned even though none fits level 25 (got " .. tostring(seg) .. ")")
    T.ok(type(sug) == "table" and type(sug.reason) == "string" and sug.reason ~= "",
      "a reason explains the out-of-range choice")
  end)

  -- Spec 8a fallback rule (regression): with no segment in level range, the nearest level
  -- range wins, not raw quest XP (raw XP ignores low-level falloff).
  T.test("fallback at level 20: nearest range (Durotar) beats a higher-XP start; remembered segment handling", function()
    local bigQ
    local START = "horde.start.fallback"
    local ns, route = setup(function(ns)
      bigQ = T.newID()
      T.inject(ns, bigQ, { NAME = "Big start quest", REQ_LEVEL = 1, LEVEL = 3, XP = 50000 })
      local def = F.orcStart(ns)
      def.id = START
      def.entry = { minLevel = 1 }          -- still eligible at 20
      def.exit = { level = 6 }              -- start done by level
      table.insert(def.steps, { id = "fb.big", type = "ACCEPT", quest = bigQ })
      ns.Guides.Register(def)
      ns.Guides.Register(F.durotar(ns))
    end)
    local S = ns.GuideSelector
    T.eq(route.order, { START, F.DUROTAR }, "only start + Durotar")
    local state = orc{ level = 20 }
    if S.Score then
      T.ok(S.Score(route, START, state) > S.Score(route, F.DUROTAR, state),
        "premise: start has more available quest XP than Durotar")
    end

    local seg, sug = S.Choose(route, state, {})
    T.eq(seg, F.DUROTAR, "fallback picks nearest range, never the start")
    T.ok(type(sug) == "table", "suggestion explains the fallback")
    T.eq(sug and sug.kind, "segment", "kind")
    T.eq(sug and sug.to, F.DUROTAR, "suggestion points at the fallback")
    T.eq(sug and sug.reason, "no_segment_in_range", "reason")

    -- remembered usable out-levelled segment, fallback differs -> keep + suggestion
    seg, sug = S.Choose(route, state, { segment = START })
    T.eq(seg, START, "remembered start kept")
    T.eq(sug and sug.to, F.DUROTAR, "suggests the fallback")
    T.eq(sug and sug.reason, "no_segment_in_range", "reason")

    -- remembered segment IS the fallback -> no suggestion
    seg, sug = S.Choose(route, state, { segment = F.DUROTAR })
    T.eq(seg, F.DUROTAR, "remembered Durotar kept")
    T.eq(sug, nil, "no suggestion when fallback equals current")
  end)

  T.test("deterministic tie-breaking: equal score -> lower levels[1], then route order", function()
    local tieQ
    local function register(order)
      return function(ns)
        F.register(ns)
        tieQ = tieQ or T.newID()
        T.inject(ns, tieQ, { NAME = "Tie quest", REQ_LEVEL = 25, LEVEL = 30, XP = 1000 })
        local defs = {
          a = { id = "horde.tie.a", kind = "segment", faction = "Horde", levels = { 30, 40 },
                steps = { { id = "tieA.1", type = "ACCEPT", quest = tieQ } } },
          b = { id = "horde.tie.b", kind = "segment", faction = "Horde", levels = { 30, 40 },
                steps = { { id = "tieB.1", type = "ACCEPT", quest = tieQ } } },
          low = { id = "horde.tie.low", kind = "segment", faction = "Horde", levels = { 29, 40 },
                steps = { { id = "tieL.1", type = "ACCEPT", quest = tieQ } } },
        }
        for _, k in ipairs(order) do ns.Guides.Register(defs[k]) end
      end
    end
    local state = orc{ level = 30, completed = allDone(F.VOT_QUESTS) }

    -- equal levels[1]: winner must not depend on registration order
    local ns, r1 = setup(register({ "a", "b" }))
    local first = ns.GuideSelector.Choose(r1, state, {})
    T.ok(first == "horde.tie.a" or first == "horde.tie.b", "a tie segment chosen (got " .. tostring(first) .. ")")
    for _ = 1, 3 do T.eq(ns.GuideSelector.Choose(r1, state, {}), first, "repeat call stable") end
    local ns2, r2 = setup(register({ "b", "a" }))
    T.eq(ns2.GuideSelector.Choose(r2, state, {}), first, "registration order does not change the winner")
    T.eq(r1.order, r2.order, "route order independent of registration order")
    -- the winner is the earlier one in route.order
    local posA, posB
    for i, id in ipairs(r1.order) do
      if id == "horde.tie.a" then posA = i elseif id == "horde.tie.b" then posB = i end
    end
    T.eq(first, posA < posB and "horde.tie.a" or "horde.tie.b", "earlier in order wins")

    -- lower levels[1] wins an equal score
    local ns3, r3 = setup(register({ "b", "a", "low" }))
    T.eq(ns3.GuideSelector.Choose(r3, state, {}), "horde.tie.low", "levels {29,40} beats {30,40}")
  end)
end
