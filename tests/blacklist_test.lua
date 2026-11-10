-- Questie blacklist layer (spec 8a "Questie blacklist layer"): data flags, Meta audit info,
-- Availability, starting quests, engine badge. Route-file checks live in route_lint_test.lua.

local function hasFlag(flags, bit)
  return type(flags) == "number" and math.floor(flags / bit) % 2 == 1
end

local RACES = { Horde = { 2, 5, 6, 8, 96 }, Alliance = { 1, 3, 4, 7, 95 } }

return function(T)
  local function flag(ns, name)
    local F = ns.DataSchema.QUEST_FLAGS
    if not (F and F[name]) then T.skip("QUEST_FLAGS." .. name .. " not in the schema yet") end
    return F[name]
  end

  local function flagsOf(ns, qid)
    local q = ns.Data.GetQuest(qid)
    return q and q[ns.DataSchema.Q.FLAGS]
  end

  T.test("schema: BLACKLISTED = 256, HIDDEN_ON_MAP = 512", function()
    local ns = T.addon("Horde", "WARRIOR")
    T.eq(flag(ns, "BLACKLISTED"), 256, "BLACKLISTED")
    T.eq(flag(ns, "HIDDEN_ON_MAP"), 512, "HIDDEN_ON_MAP")
  end)

  T.test("data: 787 BLACKLISTED for Horde, 4641 not; records are kept", function()
    local ns = T.addon("Horde", "WARRIOR")
    local B = flag(ns, "BLACKLISTED")
    T.ok(ns.Data.GetQuest(787) ~= nil, "787 record kept")
    T.ok(hasFlag(flagsOf(ns, 787), B), "787 flagged BLACKLISTED")
    T.ok(not hasFlag(flagsOf(ns, 4641), B), "4641 not blacklisted")
  end)

  T.test("data: some quests are BLACKLISTED / HIDDEN_ON_MAP in each faction", function()
    for _, faction in ipairs(T.FACTIONS) do
      local ns = T.addon(faction, "WARRIOR")
      local B, H = flag(ns, "BLACKLISTED"), flag(ns, "HIDDEN_ON_MAP")
      local nb, nh = 0, 0
      for _, q in pairs(ns.Data.quests) do
        local f = q[ns.DataSchema.Q.FLAGS]
        if hasFlag(f, B) then nb = nb + 1 end
        if hasFlag(f, H) then nh = nh + 1 end
      end
      print(string.format("INFO  blacklist %s: %d BLACKLISTED, %d HIDDEN_ON_MAP quests loaded", faction, nb, nh))
      T.ok(nb > 0, faction .. " has blacklisted quests")
    end
  end)

  T.test("meta: questieBlacklist = { commit, file, count }", function()
    local ns = T.addon("Horde", "WARRIOR")
    local m = ns.DataMeta.questieBlacklist
    if m == nil then T.skip("DataMeta.questieBlacklist not generated yet") end
    T.ok(type(m.commit) == "string" and #m.commit >= 7, "commit " .. tostring(m.commit))
    T.ok(type(m.file) == "string" and m.file:find("QuestieQuestBlacklist", 1, true) ~= nil, "file " .. tostring(m.file))
    T.ok(type(m.count) == "number" and m.count > 0, "count " .. tostring(m.count))
  end)

  T.test("meta: starting quests contain no BLACKLISTED quest", function()
    for _, faction in ipairs(T.FACTIONS) do
      local ns = T.addon(faction, "WARRIOR")
      local B = flag(ns, "BLACKLISTED")
      for _, raceID in ipairs(RACES[faction]) do
        local info = ns.DataMeta.startingQuests[raceID]
        for _, qid in ipairs(info and info.quests or {}) do
          T.ok(not hasFlag(flagsOf(ns, qid), B), string.format("%s race %d starting quest %d is blacklisted", faction, raceID, qid))
        end
      end
    end
  end)

  -- Availability --------------------------------------------------------------------------

  T.test("Availability: blacklisted -> UNAVAILABLE blacklisted (after COMPLETED / ACTIVE)", function()
    local ns = T.sandbox("Horde", "WARRIOR")
    local B = flag(ns, "BLACKLISTED")
    local check = ns.Availability.Check
    local orc = T.state{ faction = "Horde", raceID = 2, level = 1 }
    local s, r = check(787, orc)
    T.eq(s, "UNAVAILABLE", "787 status (" .. tostring(r) .. ")")
    T.eq(r, "blacklisted", "787 reason")
    local q = T.newID()
    T.inject(ns, q, { FLAGS = B })
    s, r = check(q, T.state{})
    T.eq({ s, r }, { "UNAVAILABLE", "blacklisted" }, "synthetic blacklisted")
    T.eq(check(q, T.state{ completed = { [q] = true } }), "COMPLETED", "completed wins")
    T.eq(check(q, T.state{ log = { [q] = { complete = false, objectives = {} } } }), "ACTIVE", "in log wins")
    local h = T.newID()
    T.inject(ns, h, { FLAGS = flag(ns, "HIDDEN_ON_MAP") })
    T.eq(check(h, T.state{}), "AVAILABLE", "HIDDEN_ON_MAP stays available")
  end)

  -- Engine ----------------------------------------------------------------------------------

  T.test("engine: blacklisted steps stay out of current/upcoming; one warning counting distinct quests", function()
    local ns = T.sandbox("Horde", "WARRIOR")
    T.needModule(ns, "Guides", "GuideEngine")
    local B = flag(ns, "BLACKLISTED")
    for _, q in ipairs({ 787, 5843 }) do
      T.ok(hasFlag(flagsOf(ns, q), B), "premise: " .. q .. " is BLACKLISTED")
    end
    T.ok(not hasFlag(flagsOf(ns, 4641), B), "premise: 4641 is not")
    local function warningOf(view)
      for _, w in ipairs(view.warnings) do
        local n, noun = w:match("^(%d+) (quests?) skipped: not in WoW Forever")
        if n then
          T.eq(noun, tonumber(n) == 1 and "quest" or "quests", "singular/plural: " .. w)
        end
        if n then return tonumber(n), w end
      end
    end
    ns.Guides.Reset()
    ns.Guides.Register({ id = "bl.mixed", kind = "segment", faction = "Horde", levels = { 1, 60 }, steps = {
      { id = "m.a787", type = "ACCEPT", quest = 787 }, { id = "m.t787", type = "TURNIN", quest = 787 },
      { id = "m.a5843", type = "ACCEPT", quest = 5843 }, { id = "m.t5843", type = "TURNIN", quest = 5843 },
      { id = "m.a4641", type = "ACCEPT", quest = 4641 }, { id = "m.t4641", type = "TURNIN", quest = 4641 },
    } })
    local route = ns.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    local mem = ns.GuideEngine.NewMemory()
    local view = ns.GuideEngine.Evaluate(route, T.state{ faction = "Horde", raceID = 2, level = 1 }, mem)
    T.eq(view.current[1] and view.current[1].id, "m.a4641", "normal quest is current")
    for _, list in ipairs({ view.current, view.upcoming }) do
      for _, s in ipairs(list) do
        T.ok(s.quest == nil or (s.quest.id ~= 787 and s.quest.id ~= 5843), "blacklisted step listed: " .. tostring(s.id))
      end
    end
    for _, id in ipairs({ "m.a787", "m.t787", "m.a5843", "m.t5843" }) do T.ok(not mem.done[id], id .. " never DONE") end
    local n, text = warningOf(view)
    T.eq(n, 2, "warning counts distinct quests (2 quests, 4 steps): " .. tostring(text))
    -- no blacklisted quest in the window -> no such warning
    ns.Guides.Reset()
    ns.Guides.Register({ id = "bl.clean", kind = "segment", faction = "Horde", levels = { 1, 60 }, steps = {
      { id = "c.a4641", type = "ACCEPT", quest = 4641 }, { id = "c.t4641", type = "TURNIN", quest = 4641 } } })
    route = ns.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    view = ns.GuideEngine.Evaluate(route, T.state{ faction = "Horde", raceID = 2, level = 1 }, ns.GuideEngine.NewMemory())
    T.eq(warningOf(view), nil, "no blacklist warning without blacklisted quests")
  end)

  T.test("engine: HIDDEN_ON_MAP quest stays routable and carries a badge", function()
    local ns = T.sandbox("Horde", "WARRIOR")
    T.needModule(ns, "Guides", "GuideEngine")
    local H = flag(ns, "HIDDEN_ON_MAP")
    local q = T.newID()
    T.inject(ns, q, { NAME = "Hidden quest", FLAGS = H, START = { { 10176 } }, FINISH = { { 10176 } } })
    ns.Guides.Reset()
    ns.Guides.Register({ id = "bl.hidden", kind = "segment", faction = "Horde", levels = { 1, 60 },
      steps = { { id = "h.a", type = "ACCEPT", quest = q }, { id = "h.t", type = "TURNIN", quest = q } } })
    local route = ns.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    local view = ns.GuideEngine.Evaluate(route, T.state{ faction = "Horde", raceID = 2, level = 5 }, ns.GuideEngine.NewMemory())
    local c = view.current[1]
    T.eq(c and c.id, "h.a", "routable: ACCEPT current")
    T.eq(c and c.status, "ACTIVE", "ACTIVE")
    local badge
    for _, b in ipairs(c and c.badges or {}) do
      if b:lower():find("hidden", 1, true) then badge = b end
    end
    T.ok(badge ~= nil, "a hidden-on-map badge is shown (badges: " .. table.concat(c and c.badges or {}, ",") .. ")")
  end)
end
