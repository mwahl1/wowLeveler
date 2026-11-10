-- Route registry + compiler (spec 3.2-3.5 and 8a "Route registry + compiler").
-- Uses fixture routes from tests/fixtures/routes.lua in private sandbox namespaces.

return function(T)
  local F = T.fixture("routes")

  local function setup(faction)
    local ns = T.sandbox(faction or "Horde", "WARRIOR")
    T.needModule(ns, "Guides")
    ns.Guides.Reset()
    F.register(ns)
    return ns
  end

  local function compile(ns, faction, raceID, classFile)
    local route, problems = ns.Guides.Compile({ faction = faction, raceID = raceID, classFile = classFile })
    T.ok(type(route) == "table", "Compile returned a route")
    T.ok(type(problems) == "table", "Compile returned a problems list")
    return route, problems
  end

  local function problemsWith(problems, severity, code)
    local out = {}
    for _, p in ipairs(problems) do
      if (not severity or p.severity == severity) and (not code or p.code == code) then out[#out + 1] = p end
    end
    return out
  end

  local function errors(problems) return problemsWith(problems, "error") end

  local function describe(problems)
    local parts = {}
    for _, p in ipairs(problems) do parts[#parts + 1] = tostring(p.severity) .. ":" .. tostring(p.code) .. ":" .. tostring(p.msg) end
    return "{" .. table.concat(parts, " | ") .. "}"
  end

  -- Faction filtering ------------------------------------------------------------------

  T.test("Horde compile excludes Alliance defs and orders start, then segments by level", function()
    local ns = setup("Horde")
    local route, problems = compile(ns, "Horde", 2, "WARRIOR")
    T.eq(#errors(problems), 0, "no errors " .. describe(problems))
    T.eq(route.order, { F.ORC_START, F.DUROTAR, F.BARRENS }, "segment order")
    T.eq(route.segments[F.ALLY_START], nil, "no Alliance start")
    T.eq(route.segments[F.UD_START], nil, "no Undead start for an Orc")
  end)

  T.test("Alliance compile excludes Horde defs and the Horde overlay", function()
    local ns = setup("Alliance")
    local route, problems = compile(ns, "Alliance", 1, "WARLOCK")
    T.eq(#errors(problems), 0, "no errors " .. describe(problems))
    T.eq(route.order, { F.ALLY_START }, "only the Alliance start")
    T.eq(route.byId["wl.imp"], nil, "Horde warlock overlay not applied")
    T.eq(route.byId["wl.train10"], nil, "Horde warlock overlay not applied (atLevel)")
    T.eq(#problemsWith(problems, nil, "unknown_quest"), 0, "Alliance start quests exist in Alliance data")
  end)

  T.test("faction = nil def is included for both factions", function()
    for _, faction in ipairs({ "Horde", "Alliance" }) do
      local ns = setup(faction)
      ns.Guides.Register({ id = "both.note", kind = "segment", levels = { 50, 60 },
        steps = { { id = "both.n1", type = "NOTE", text = "neutral" } } })
      local route = compile(ns, faction, faction == "Horde" and 2 or 1, "WARRIOR")
      T.ok(route.segments["both.note"] ~= nil, faction .. " includes the faction-less segment")
      T.eq(route.order[#route.order], "both.note", faction .. ": level-50 segment ordered last")
    end
  end)

  -- Start per race ------------------------------------------------------------------------

  T.test("start chosen per race: Orc and Troll get Valley of Trials, Undead gets Deathknell", function()
    local ns = setup("Horde")
    for _, raceID in ipairs({ 2, 8 }) do
      local route, problems = compile(ns, "Horde", raceID, "WARRIOR")
      T.eq(route.order[1], F.ORC_START, "race " .. raceID .. " start")
      T.eq(route.segments[F.UD_START], nil, "race " .. raceID .. " has no Deathknell")
      T.eq(#problemsWith(problems, nil, "no_start"), 0, "race " .. raceID .. " no no_start warning")
    end
    local route, problems = compile(ns, "Horde", 5, "WARRIOR")
    T.eq(route.order[1], F.UD_START, "Undead start")
    T.eq(route.segments[F.ORC_START], nil, "Undead has no Valley of Trials")
    T.eq(#errors(problems), 0, "no errors " .. describe(problems))
    for _, qid in ipairs(ns.DataMeta.startingQuests[5].quests) do
      T.ok(route.byId["dk.a" .. qid] ~= nil, "Deathknell accept step for " .. qid)
    end
  end)

  T.test("Skyborne Horde (96): no start -> no_start warning, segments still compiled", function()
    local ns = setup("Horde")
    local route, problems = compile(ns, "Horde", 96, "WARRIOR")
    local w = problemsWith(problems, "warning", "no_start")
    T.eq(#w, 1, "one no_start warning " .. describe(problems))
    T.eq(#errors(problems), 0, "no errors")
    T.eq(route.order, { F.DUROTAR, F.BARRENS }, "faction segments only")
  end)

  -- Route structure ---------------------------------------------------------------------------

  T.test("compiled steps carry segment/index; byId and segment ranges agree", function()
    local ns = setup("Horde")
    local route = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#route.steps > 0, "steps present")
    for i, step in ipairs(route.steps) do
      T.eq(step.index, i, "step " .. tostring(step.id) .. " index")
      T.eq(route.byId[step.id], i, "byId[" .. tostring(step.id) .. "]")
      local seg = route.segments[step.segment]
      T.ok(seg ~= nil, "step " .. tostring(step.id) .. " segment known")
      T.ok(seg.first <= i and i <= seg.last, "step " .. tostring(step.id) .. " inside its segment range")
    end
    local prevLast = 0
    for _, segId in ipairs(route.order) do
      local seg = route.segments[segId]
      T.eq(seg.first, prevLast + 1, segId .. " contiguous")
      T.ok(seg.def ~= nil and seg.def.id == segId, segId .. " keeps its def")
      prevLast = seg.last
    end
    T.eq(prevLast, #route.steps, "segments cover every step")
    -- authored order inside a segment is preserved
    T.ok(route.byId["vot.a788"] < route.byId["vot.c788"] and route.byId["vot.c788"] < route.byId["vot.t788"],
      "788 accept < complete < turn-in")
  end)

  -- Overlays -----------------------------------------------------------------------------------

  T.test("overlay not applied for other classes", function()
    local ns = setup("Horde")
    for _, class in ipairs({ "WARRIOR", "MAGE", "SHAMAN" }) do
      local route = compile(ns, "Horde", 2, class)
      T.eq(route.byId["wl.imp"], nil, class .. " has no warlock after-step")
      T.eq(route.byId["wl.train10"], nil, class .. " has no warlock atLevel step")
    end
  end)

  T.test("WARLOCK overlay: after-anchor directly follows its step, atLevel at segment start with minLevel", function()
    local ns = setup("Horde")
    local route, problems = compile(ns, "Horde", 2, "WARLOCK")
    T.eq(#errors(problems), 0, "no errors " .. describe(problems))
    T.eq(#problemsWith(problems, nil, "overlay_anchor"), 0, "anchor found")
    local imp, anchor = route.byId["wl.imp"], route.byId["vot.t788"]
    T.ok(imp ~= nil, "wl.imp inserted")
    T.eq(imp, anchor + 1, "wl.imp right after vot.t788")
    T.eq(route.steps[imp].segment, F.ORC_START, "after-step belongs to the anchor's segment")
    local train = route.byId["wl.train10"]
    T.ok(train ~= nil, "wl.train10 inserted")
    -- levels {5,12} is the first segment (in order) containing 10
    T.eq(train, route.segments[F.DUROTAR].first, "atLevel step first in Durotar 5-12")
    T.eq(route.steps[train].segment, F.DUROTAR, "atLevel step belongs to Durotar")
    T.ok(type(route.steps[train].when) == "table", "atLevel step has when")
    T.eq(route.steps[train].when.minLevel, 10, "atLevel adds when.minLevel")
    -- Original steps keep their relative order around the inserts
    T.eq(route.byId["vot.a790"], imp + 1, "next authored step follows the insert")
    T.eq(route.byId["dur.a786"], train + 1, "Durotar's first authored step follows the insert")
  end)

  T.test("overlay anchor missing -> overlay_anchor warning (Undead warlock has no vot.t788)", function()
    local ns = setup("Horde")
    local route, problems = compile(ns, "Horde", 5, "WARLOCK")
    T.ok(#problemsWith(problems, "warning", "overlay_anchor") >= 1, "overlay_anchor warning " .. describe(problems))
    T.eq(route.byId["wl.imp"], nil, "unanchored step not inserted")
    T.ok(route.byId["wl.train10"] ~= nil, "atLevel insert still applied")
  end)

  -- Validation ------------------------------------------------------------------------------------

  T.test("duplicate step id within the route -> error", function()
    local ns = setup("Horde")
    ns.Guides.Register({ id = "horde.dup", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { id = "dup.x", type = "NOTE" }, { id = "dup.x", type = "NOTE" } } })
    local _, problems = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#errors(problems) >= 1, "duplicate id reported as error " .. describe(problems))
  end)

  T.test("bare id repeated across segments -> namespaced segId/stepId with warning; explicit ids collide -> error", function()
    local ns = setup("Horde")
    ns.Guides.Register({ id = "horde.rep.a", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { id = "rep.x", type = "NOTE" } } })
    ns.Guides.Register({ id = "horde.rep.b", kind = "segment", faction = "Horde", levels = { 41, 50 },
      steps = { { id = "rep.x", type = "NOTE" } } })
    local route, problems = compile(ns, "Horde", 2, "WARRIOR")
    T.eq(#errors(problems), 0, "bare repeat is not an error " .. describe(problems))
    T.ok(#problemsWith(problems, "warning", nil) >= 1, "repeat is surfaced as a warning")
    T.eq(route.steps[route.byId["rep.x"]].segment, "horde.rep.a", "first keeps the bare id")
    T.ok(route.byId["horde.rep.b/rep.x"] ~= nil, "second namespaced as segId/stepId")

    ns.Guides.Reset()
    F.register(ns)
    ns.Guides.Register({ id = "horde.ns.a", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { id = "zone/x", type = "NOTE" } } })
    ns.Guides.Register({ id = "horde.ns.b", kind = "segment", faction = "Horde", levels = { 41, 50 },
      steps = { { id = "zone/x", type = "NOTE" } } })
    local _, p2 = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#errors(p2) >= 1, "already-namespaced duplicate is an error " .. describe(p2))
  end)

  T.test("unknown step type -> error", function()
    local ns = setup("Horde")
    ns.Guides.Register({ id = "horde.badtype", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { id = "bad.1", type = "TELEPORT" } } })
    local _, problems = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#errors(problems) >= 1, "unknown type reported as error " .. describe(problems))
  end)

  T.test("missing step id or type -> error", function()
    local ns = setup("Horde")
    ns.Guides.Register({ id = "horde.noid", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { type = "NOTE" } } })
    local _, p1 = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#errors(p1) >= 1, "missing id reported as error " .. describe(p1))
    ns.Guides.Reset()
    F.register(ns)
    ns.Guides.Register({ id = "horde.notype", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { id = "nt.1" } } })
    local _, p2 = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#errors(p2) >= 1, "missing type reported as error " .. describe(p2))
  end)

  T.test("unknown quest -> unknown_quest warning, step kept", function()
    local ns = setup("Horde")
    local ghost = 8999998
    T.eq(ns.Data.GetQuest(ghost), nil, "ghost quest absent from data")
    ns.Guides.Register({ id = "horde.ghost", kind = "segment", faction = "Horde", levels = { 30, 40 },
      steps = { { id = "ghost.a", type = "ACCEPT", quest = ghost } } })
    local route, problems = compile(ns, "Horde", 2, "WARRIOR")
    T.ok(#problemsWith(problems, "warning", "unknown_quest") >= 1, "unknown_quest warning " .. describe(problems))
    T.eq(#errors(problems), 0, "not an error")
    T.ok(route.byId["ghost.a"] ~= nil, "step kept")
  end)

  T.test("clean fixtures compile with no unknown_quest warnings (real Valley of Trials IDs)", function()
    local ns = setup("Horde")
    local _, problems = compile(ns, "Horde", 2, "WARRIOR")
    T.eq(#problemsWith(problems, nil, "unknown_quest"), 0, "all fixture quests in data " .. describe(problems))
  end)
end
