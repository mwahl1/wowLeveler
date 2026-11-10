-- Data smoke tests: the real generated Data/*.lua loaded through Core/Data.lua for every
-- faction and class (spec section 10: factions / races / starts, classes).

local RACES = { Horde = { 2, 5, 6, 8, 96 }, Alliance = { 1, 3, 4, 7, 95 } }

-- Skyborne Horde (raceID 96) has no starting quests in QuestieDB yet: its start area isn't
-- in the Classic Era data the export is built from, so Meta.startingQuests[96] is written as
-- an empty list. This is a documented data gap (docs/DATA_COVERAGE.md, docs/data-gaps.csv),
-- so the test asserts the gap is REPORTED (present and empty), not that quests load. When the
-- data team fills it, this assertion fails on purpose so the special case gets removed.
local KNOWN_EMPTY_START = { [96] = true }

local function hasFlag(flags, flag)
  return type(flags) == "number" and math.floor(flags / flag) % 2 == 1
end

return function(T)
  for _, faction in ipairs(T.FACTIONS) do
    for _, class in ipairs(T.CLASSES) do
      T.test(faction .. "/" .. class .. " data loads with no errors", function()
        local ns = T.addon(faction, class)
        local st = ns.Data.status
        T.eq(st.state, "loaded", "loader state (errors: " .. table.concat(st.errors or {}, " | ") .. ")")
        T.eq(#(st.errors or {}), 0, "loader errors")
        T.eq(st.faction, faction, "status faction")
        T.eq(st.class, class, "status class")
        for _, kind in ipairs({ "quests", "npcs", "objects", "items" }) do
          T.ok((st.counts[kind] or 0) > 0, kind .. " count > 0")
        end
        -- Counts agree with what the build tool recorded
        local M = ns.DataMeta
        for _, kind in ipairs({ "quests", "npcs", "objects", "items" }) do
          local want = (M.counts.Neutral[kind] or 0) + (M.counts[faction][kind] or 0)
          T.eq(st.counts[kind], want, kind .. " count vs DataMeta")
        end
      end)

      T.test(faction .. "/" .. class .. " starting quests loaded for every race", function()
        local ns = T.addon(faction, class)
        local starts = ns.DataMeta.startingQuests
        for _, raceID in ipairs(RACES[faction]) do
          local info = starts[raceID]
          T.ok(info ~= nil, "startingQuests has an entry for race " .. raceID)
          if KNOWN_EMPTY_START[raceID] then
            T.eq(#info.quests, 0, "race " .. raceID .. " known gap reported as empty")
          else
            T.ok(#info.quests > 0, "race " .. raceID .. " has starting quests")
            for _, qid in ipairs(info.quests) do
              local q = ns.Data.GetQuest(qid)
              T.ok(q ~= nil, "race " .. raceID .. " starting quest " .. qid .. " loaded")
              -- The quest must be loaded *for this race*; class restrictions may hide it from this class
              T.ok(ns.Data.RaceAllowed(q[ns.DataSchema.Q.RACES], raceID),
                "starting quest " .. qid .. " allowed for race " .. raceID)
            end
          end
        end
      end)
    end
  end

  T.test("RaceAllowed: nil/0 mean all races, Skyborne bits 32/33", function()
    local ns = T.addon("Horde", "WARRIOR")
    local D, B = ns.Data, ns.DataSchema.RACE_BIT
    for _, raceID in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 95, 96 }) do
      T.ok(D.RaceAllowed(nil, raceID), "nil allows " .. raceID)
      T.ok(D.RaceAllowed(0, raceID), "0 allows " .. raceID)
    end
    T.eq(B[95], 2 ^ 32, "Skyborne Alliance bit")
    T.eq(B[96], 2 ^ 33, "Skyborne Horde bit")
    T.ok(D.RaceAllowed(B[96], 96), "bit 33 alone allows 96")
    T.ok(not D.RaceAllowed(B[96], 95), "bit 33 alone rejects 95")
    T.ok(D.RaceAllowed(B[95], 95), "bit 32 alone allows 95")
    T.ok(not D.RaceAllowed(B[95], 96), "bit 32 alone rejects 96")
    -- Low bits must not leak into high-bit races and vice versa
    local horde = B[2] + B[5] + B[6] + B[8] + B[96]
    for _, r in ipairs({ 2, 5, 6, 8, 96 }) do T.ok(D.RaceAllowed(horde, r), "horde mask allows " .. r) end
    for _, r in ipairs({ 1, 3, 4, 7, 95 }) do T.ok(not D.RaceAllowed(horde, r), "horde mask rejects " .. r) end
    local mixed = B[1] + B[96] -- lowest + highest bit
    T.ok(D.RaceAllowed(mixed, 1) and D.RaceAllowed(mixed, 96), "mixed mask allows 1 and 96")
    T.ok(not D.RaceAllowed(mixed, 95) and not D.RaceAllowed(mixed, 2), "mixed mask rejects 95 and 2")
    T.ok(not D.RaceAllowed(B[2], 999), "unknown race rejected by a non-zero mask")
  end)

  T.test("Valley of Trials: 788 Cutting Teeth is Horde-only", function()
    local h = T.addon("Horde", "WARRIOR")
    local q = h.Data.GetQuest(788)
    T.ok(q ~= nil, "788 loaded for Horde")
    T.eq(q[h.DataSchema.Q.NAME], "Cutting Teeth", "788 name")
    local a = T.addon("Alliance", "WARRIOR")
    T.eq(a.Data.GetQuest(788), nil, "788 not loaded for Alliance")
  end)

  T.test("Valley of Trials: 4641 start NPC 10176 exists", function()
    local ns = T.addon("Horde", "WARRIOR")
    local q = ns.Data.GetQuest(4641)
    T.ok(q ~= nil, "4641 loaded")
    local start = q[ns.DataSchema.Q.START]
    T.ok(type(start) == "table" and type(start[1]) == "table", "4641 has NPC starters")
    T.contains(start[1], 10176, "4641 starters")
    T.ok(ns.Data.GetNPC(10176) ~= nil, "NPC 10176 in ns.Data.npcs")
  end)

  -- A CLASS_DYNAMIC quest's record must differ between at least two classes of the same faction
  for _, faction in ipairs(T.FACTIONS) do
    T.test(faction .. " class overrides change CLASS_DYNAMIC quests", function()
      local base = T.addon(faction, "WARRIOR")
      local S = base.Data and base.DataSchema
      local flag = S.QUEST_FLAGS.CLASS_DYNAMIC
      local ids = {}
      for id, q in pairs(base.Data.quests) do
        if hasFlag(q[S.Q.FLAGS], flag) then ids[#ids + 1] = id end
      end
      table.sort(ids)
      T.ok(#ids > 0, faction .. " has at least one CLASS_DYNAMIC quest")
      -- Snapshot the dynamic records per class (copies, so evicted caches don't matter)
      local snap = {}
      for _, class in ipairs(T.CLASSES) do
        local ns = T.addon(faction, class)
        T.ok(ns.Data.status.counts.classOverrides >= 0, "override count present")
        local s = {}
        for _, id in ipairs(ids) do s[id] = ns.Data.quests[id] end
        snap[class] = s
      end
      local differing
      for _, id in ipairs(ids) do
        for i = 2, #T.CLASSES do
          if not T.deepEq(snap[T.CLASSES[1]][id], snap[T.CLASSES[i]][id]) then
            differing = id
            break
          end
        end
        if differing then break end
      end
      T.ok(differing ~= nil, "some CLASS_DYNAMIC quest differs between classes (" .. #ids .. " checked)")
    end)
  end
end
