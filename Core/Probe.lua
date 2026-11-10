-- API diagnostics and event recorder. Answers "which APIs actually work in
-- Forever?" and saves results to LevelingNavigatorCharDB so they can be shared.
local _, ns = ...
local C = ns.Compat

local Probe = {}
ns.Probe = Probe

local MAX_EVENTS = 400

-- Status meanings:
--   pass    API exists and returned usable data
--   partial API exists but returned nothing (often needs a quest/NPC/etc.)
--   missing API not present in this client
--   error   API exists but threw
local function exists(fn) return type(fn) == "function" end

local function FirstQuestID()
  local quests = C.GetQuests()
  return quests[1] and quests[1].questID
end

local function CountKeys(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- Each check returns status, detail
local CHECKS = {
  { "Client build", function()
      local version, build, _, interface = GetBuildInfo()
      return "pass", string.format("%s (%s), interface %s", tostring(version), tostring(build), tostring(interface))
    end },
  { "Character info", function()
      local c = C.GetCharacter()
      if not c.level then return "partial", "UnitLevel returned nothing" end
      return "pass", string.format("%s %s %s, level %s", tostring(c.faction), tostring(c.race), tostring(c.class), C.SafeString(c.level))
    end },
  { "Experience", function()
      local c = C.GetCharacter()
      if not c.xpMax or c.xpMax == 0 then return "partial", "UnitXPMax returned 0/nil" end
      return "pass", string.format("%s / %s, rested %s", C.SafeString(c.xp), C.SafeString(c.xpMax), C.SafeString(c.rested))
    end },
  { "Quest log entries", function()
      if not (C_QuestLog and exists(C_QuestLog.GetNumQuestLogEntries)) then return "missing" end
      local entries, quests = C_QuestLog.GetNumQuestLogEntries()
      return "pass", string.format("%s entries, %s quests", tostring(entries), tostring(quests))
    end },
  { "Quest info + IDs", function()
      if not exists(C_QuestLog.GetInfo) then return "missing" end
      local id = FirstQuestID()
      if not id then return "partial", "no quests in log - accept one and run /ln probe" end
      return "pass", "first quest ID " .. id
    end },
  { "Quest objectives", function()
      if not exists(C_QuestLog.GetQuestObjectives) then return "missing" end
      local id = FirstQuestID()
      if not id then return "partial", "needs a quest in the log" end
      local objs = C_QuestLog.GetQuestObjectives(id) or {}
      local o = objs[1]
      if not o then return "partial", "quest has no objectives" end
      return "pass", string.format("%s (%s %s/%s)", tostring(o.text), tostring(o.type), tostring(o.numFulfilled), tostring(o.numRequired))
    end },
  { "Quest complete state", function()
      if not (exists(C_QuestLog.IsComplete) and exists(C_QuestLog.ReadyForTurnIn)) then return "missing" end
      return "pass", "IsComplete + ReadyForTurnIn present"
    end },
  { "Completed quest history", function()
      if not exists(C_QuestLog.GetAllCompletedQuestIDs) then
        return exists(C_QuestLog.IsQuestFlaggedCompleted) and "partial" or "missing", "only per-quest lookup"
      end
      local ids = C_QuestLog.GetAllCompletedQuestIDs() or {}
      return "pass", #ids .. " completed quests known"
    end },
  { "Quest reward XP", function()
      if not exists(GetQuestLogRewardXP) then return "missing" end
      local id = FirstQuestID()
      if not id then return "partial", "needs a quest in the log" end
      return "pass", "first quest rewards " .. C.SafeString(GetQuestLogRewardXP(id)) .. " XP"
    end },
  { "Quest objective waypoint", function()
      if not exists(C_QuestLog.GetNextWaypoint) then return "missing" end
      local id = FirstQuestID()
      if not id then return "partial", "needs a quest in the log" end
      local mapID, x, y = C_QuestLog.GetNextWaypoint(id)
      if not mapID then return "partial", "no waypoint for quest " .. id end
      return "pass", string.format("map %s at %.1f, %.1f", tostring(mapID), (x or 0) * 100, (y or 0) * 100)
    end },
  { "Active quests on map", function()
      if not exists(C_QuestLog.GetQuestsOnMap) then return "missing" end
      local mapID = C.GetPlayerPosition()
      if not mapID then return "partial", "no map ID" end
      local list = C_QuestLog.GetQuestsOnMap(mapID) or {}
      return #list > 0 and "pass" or "partial", #list .. " quest POIs on this map"
    end },
  { "Available quest givers on map", function()
      if not (C_QuestLine and exists(C_QuestLine.GetAvailableQuestLines)) then return "missing" end
      local mapID = C.GetPlayerPosition()
      if not mapID then return "partial", "no map ID" end
      local list = C_QuestLine.GetAvailableQuestLines(mapID) or {}
      local first = list[1]
      if not first then return "partial", "none reported here (may need questlines nearby)" end
      return "pass", string.format("%d, e.g. %s at %.1f, %.1f", #list, tostring(first.questName), (first.x or 0) * 100, (first.y or 0) * 100)
    end },
  { "Map ID", function()
      if not (C_Map and exists(C_Map.GetBestMapForUnit)) then return "missing" end
      local mapID = C_Map.GetBestMapForUnit("player")
      if not mapID then return "partial", "nil (normal inside instances)" end
      return "pass", string.format("%s (%s)", C.SafeString(mapID), tostring(C.GetMapName(mapID)))
    end },
  { "Player position", function()
      if not exists(C_Map.GetPlayerMapPosition) then return "missing" end
      local mapID, x, y = C.GetPlayerPosition()
      if not x then return "partial", "hidden or secret here" end
      return "pass", string.format("%.1f, %.1f", x, y)
    end },
  { "Player facing", function()
      if not exists(GetPlayerFacing) then return "missing" end
      local f = GetPlayerFacing()
      if f == nil then return "partial", "nil (restricted here)" end
      if C.IsSecret(f) then return "partial", "secret value" end
      return "pass", string.format("%.2f rad", f)
    end },
  { "World coordinates (yards)", function()
      if not exists(C_Map.GetWorldPosFromMapPos) then return "missing" end
      local mapID, x, y = C.GetPlayerPosition()
      if not x then return "partial", "needs a position" end
      local continent, world = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x / 100, y / 100))
      if not world then return "partial", "no world position" end
      local wx, wy = world:GetXY()
      return "pass", string.format("continent %s at %.0f, %.0f", tostring(continent), wx, wy)
    end },
  { "Blizzard map waypoint", function()
      if not exists(C_Map.SetUserWaypoint) then return "missing" end
      local mapID = C.GetPlayerPosition()
      local can = mapID and exists(C_Map.CanSetUserWaypointOnMap) and C_Map.CanSetUserWaypointOnMap(mapID)
      return can and "pass" or "partial", can and "allowed on this map" or "API present; not allowed on this map"
    end },
  { "Super tracking (nav arrow)", function()
      if not (C_SuperTrack and exists(C_SuperTrack.SetSuperTrackedUserWaypoint)) then return "missing" end
      return "pass", "C_SuperTrack present"
    end },
  { "Quest dialog APIs", function()
      local names = { "AcceptQuest", "CompleteQuest", "GetQuestReward", "GetNumQuestChoices", "GetQuestID", "IsQuestCompletable" }
      local missing = {}
      for _, n in ipairs(names) do if not exists(_G[n]) then missing[#missing + 1] = n end end
      if #missing > 0 then return "partial", "missing: " .. table.concat(missing, ", ") end
      return "pass", "all present (for optional auto accept/turn-in)"
    end },
  { "Gossip quest APIs", function()
      if not (C_GossipInfo and exists(C_GossipInfo.GetAvailableQuests) and exists(C_GossipInfo.SelectAvailableQuest)) then return "missing" end
      return "pass", "C_GossipInfo present"
    end },
  { "Secret value check", function()
      if not exists(issecretvalue) then return "missing", "issecretvalue not present" end
      return "pass", "issecretvalue present"
    end },
  { "SavedVariables", function()
      if ns.char.loads < 2 then return "partial", "type /reload once, then /ln probe to confirm" end
      return "pass", "data survived " .. (ns.char.loads - 1) .. " reload(s)/login(s)"
    end },
  { "Events", function()
      local n = CountKeys(ns.unknownEvents)
      if n == 0 then return "pass", "all registered events accepted" end
      local list = {}
      for e in pairs(ns.unknownEvents) do list[#list + 1] = e end
      return "partial", "unknown: " .. table.concat(list, ", ")
    end },
  { "Other addons", function()
      local found = {}
      for _, a in ipairs({ "Questie", "QuestieDB", "TomTom", "RXPGuides" }) do
        if C.IsAddOnLoaded(a) then found[#found + 1] = a end
      end
      return "pass", #found > 0 and ("loaded: " .. table.concat(found, ", ")) or "none of Questie/QuestieDB/TomTom/RXPGuides loaded"
    end },
}

function Probe.Run()
  -- Ask the client for questline data first; it can arrive asynchronously
  local mapID = C.GetPlayerPosition()
  if mapID and C_QuestLine and C_QuestLine.RequestQuestLinesForMap then
    C.Call(C_QuestLine.RequestQuestLinesForMap, mapID)
  end

  C_Timer.After(1.5, function()
    local results, counts = {}, { pass = 0, partial = 0, missing = 0, error = 0 }
    for _, check in ipairs(CHECKS) do
      local ok, status, detail = pcall(check[2])
      if not ok then status, detail = "error", tostring(status) end
      counts[status] = (counts[status] or 0) + 1
      results[#results + 1] = { name = check[1], status = status, detail = detail or "" }
    end
    local _, _, _, interface = GetBuildInfo()
    ns.char.probe = {
      time = date("%Y-%m-%d %H:%M:%S"),
      interface = interface,
      results = results,
      counts = counts,
    }
    ns.Send("PROBE_DONE")
  end)
end

-- Event recorder ---------------------------------------------------------------
-- Logs quest/XP/zone events with position and timestamp: the seed of the route
-- recorder. Arguments are stored as strings because Forever's exact payloads
-- are part of what we're verifying.

local RECORDED = {
  "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_COMPLETE",
  "QUEST_DETAIL", "QUEST_PROGRESS", "GOSSIP_SHOW", "UNIT_QUEST_LOG_CHANGED",
  "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "PLAYER_DEAD",
  "PLAYER_ALIVE", "PLAYER_UNGHOST", "TAXIMAP_OPENED", "HEARTHSTONE_BOUND",
  "SUPER_TRACKING_CHANGED", "QUEST_POI_UPDATE",
}

local function Record(event, ...)
  if not ns.char then return end
  if event == "UNIT_QUEST_LOG_CHANGED" and ... ~= "player" then return end
  local args = {}
  for i = 1, math.min(select("#", ...), 4) do
    args[i] = C.SafeString((select(i, ...)))
  end
  local mapID, x, y = C.GetPlayerPosition()
  local log = ns.char.events
  log[#log + 1] = {
    t = time(),
    e = event,
    a = table.concat(args, ","),
    m = mapID,
    x = x and math.floor(x * 10 + 0.5) / 10,
    y = y and math.floor(y * 10 + 0.5) / 10,
    lv = C.Call(UnitLevel, "player"),
    xp = C.Call(UnitXP, "player"),
  }
  while #log > MAX_EVENTS do table.remove(log, 1) end
end

for _, event in ipairs(RECORDED) do
  ns.On(event, Record)
end

function Probe.PrintLog(n)
  local log = ns.char.events
  ns.Print(string.format("Last %d of %d recorded events:", math.min(n, #log), #log))
  for i = math.max(1, #log - n + 1), #log do
    local r = log[i]
    print(string.format("  %s %s(%s) map %s %s,%s", date("%H:%M:%S", r.t), r.e, r.a, tostring(r.m), tostring(r.x), tostring(r.y)))
  end
end

ns.Listen("INIT", function()
  -- Run once per session shortly after login, once the world has loaded
  ns.On("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
    if isLogin or isReload then C_Timer.After(3, Probe.Run) end
  end)
end)
