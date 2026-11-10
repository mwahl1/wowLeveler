-- Game API adapter. Every call into Blizzard APIs goes through here, guarded,
-- so a missing or changed function in Forever degrades to nil instead of an error.
local _, ns = ...

local C = {}
ns.Compat = C

-- Call fn safely; returns its results, or nothing if fn is missing or errors
function C.Call(fn, ...)
  if type(fn) ~= "function" then return end
  local res = { pcall(fn, ...) }
  if not res[1] then return end
  return unpack(res, 2, table.maxn(res))
end

-- Midnight "secret values" can't be read by addon code. issecretvalue is the
-- documented check; if this client lacks it, assume values are readable.
function C.IsSecret(v)
  if type(issecretvalue) ~= "function" then return false end
  local ok, secret = pcall(issecretvalue, v)
  return ok and secret or false
end

function C.SafeString(v)
  if C.IsSecret(v) then return "<secret>" end
  if type(v) == "table" then return "<table>" end
  return tostring(v)
end

-- Character ------------------------------------------------------------------

function C.GetCharacter()
  local _, classFile = C.Call(UnitClass, "player")
  local className = C.Call(UnitClass, "player")
  local raceName = C.Call(UnitRace, "player")
  local xp, xpMax = C.Call(UnitXP, "player"), C.Call(UnitXPMax, "player")
  return {
    name = C.Call(UnitName, "player"),
    level = C.Call(UnitLevel, "player"),
    class = className,
    classFile = classFile,
    race = raceName,
    faction = C.Call(UnitFactionGroup, "player"),
    xp = xp,
    xpMax = xpMax,
    rested = C.GetRestedXP(),
  }
end

-- Rested XP: 0 when the client reports none (GetXPExhaustion returns nil), nil when the
-- API is missing, errors or returns a secret value
function C.GetRestedXP()
  if type(GetXPExhaustion) ~= "function" then return nil end
  local ok, v = pcall(GetXPExhaustion)
  if not ok or C.IsSecret(v) then return nil end
  return v or 0
end

function C.GetClassColor(classFile)
  if classFile and C_ClassColor and C_ClassColor.GetClassColor then
    local c = C.Call(C_ClassColor.GetClassColor, classFile)
    if c then return c.r, c.g, c.b end
  end
  local c = RAID_CLASS_COLORS and classFile and RAID_CLASS_COLORS[classFile]
  if c then return c.r, c.g, c.b end
  return 0.92, 0.93, 0.95
end

-- Position -------------------------------------------------------------------

-- Returns mapID, x, y (x/y in 0-100 map percent). x/y are nil where the client
-- hides position (instances) or returns secret values.
function C.GetPlayerPosition()
  if not (C_Map and C_Map.GetBestMapForUnit) then return end
  local mapID = C.Call(C_Map.GetBestMapForUnit, "player")
  if not mapID or C.IsSecret(mapID) then return end
  local pos = C.Call(C_Map.GetPlayerMapPosition, mapID, "player")
  if not pos then return mapID end
  local x, y = C.Call(pos.GetXY, pos)
  if not x or C.IsSecret(x) or C.IsSecret(y) then return mapID end
  return mapID, x * 100, y * 100
end

function C.GetMapName(mapID)
  if not (mapID and C_Map and C_Map.GetMapInfo) then return end
  local info = C.Call(C_Map.GetMapInfo, mapID)
  return info and info.name
end

-- Quests ---------------------------------------------------------------------

-- Returns an array of { questID, title, level, complete, objectives = {...} }
-- objectives use Blizzard's shape: { text, type, finished, numFulfilled, numRequired }
function C.GetQuests()
  local quests = {}
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then return quests end
  local n = C.Call(C_QuestLog.GetNumQuestLogEntries) or 0
  for i = 1, n do
    local info = C.Call(C_QuestLog.GetInfo, i)
    if info and not info.isHeader and not info.isHidden and info.questID then
      local id = info.questID
      quests[#quests + 1] = {
        questID = id,
        title = info.title,
        level = info.level,
        complete = C.Call(C_QuestLog.IsComplete, id) and true or false,
        objectives = C.Call(C_QuestLog.GetQuestObjectives, id) or {},
      }
    end
  end
  return quests
end

function C.GetProgressBarPercent(questID)
  return C.Call(GetQuestProgressBarPercent, questID)
end

function C.IsAddOnLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    return C.Call(C_AddOns.IsAddOnLoaded, name) and true or false
  end
  return C.Call(IsAddOnLoaded, name) and true or false
end

-- Guide state getters (Core/GuideState.lua) ------------------------------------
-- Each returns nil when the API is missing, errors or returns a secret value, so the
-- guide engine falls back to manual confirmation instead of guessing.

local function plain(v)
  if v == nil or C.IsSecret(v) then return nil end
  return v
end

function C.GetTime()
  return plain(C.Call(GetTime))
end

function C.GetFaction()
  return plain(C.Call(UnitFactionGroup, "player"))
end

-- raceID is UnitRace's third return
function C.GetRaceID()
  local _, _, raceID = C.Call(UnitRace, "player")
  return plain(raceID)
end

function C.GetClassFile()
  local _, classFile = C.Call(UnitClass, "player")
  return plain(classFile)
end

-- Array of completed quest IDs, or nil if the client lacks the API
function C.GetAllCompletedQuestIDs()
  if not (C_QuestLog and type(C_QuestLog.GetAllCompletedQuestIDs) == "function") then return nil end
  local ids = C.Call(C_QuestLog.GetAllCompletedQuestIDs)
  if type(ids) ~= "table" then return nil end
  return ids
end

-- true/false, or nil when no per-quest lookup exists
function C.IsQuestFlaggedCompleted(questID)
  local fn = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted or IsQuestFlaggedCompleted
  if type(fn) ~= "function" then return nil end
  local ok, done = pcall(fn, questID)
  if not ok or C.IsSecret(done) then return nil end
  return done and true or false
end

function C.HasQuestFlaggedCompleted()
  local fn = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted or IsQuestFlaggedCompleted
  return type(fn) == "function"
end

-- Quest log in CharacterState shape: { [questID] = { complete = bool|nil, objectives = {...} } }
-- objectives: { fulfilled, required, finished } (nil fields when unreadable).
-- Returns nil if the quest log API is missing.
function C.GetQuestLogState()
  if not (C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function"
      and type(C_QuestLog.GetInfo) == "function") then
    return nil
  end
  local log = {}
  local n = plain(C.Call(C_QuestLog.GetNumQuestLogEntries)) or 0
  local hasComplete = type(C_QuestLog.IsComplete) == "function"
  local hasObjectives = type(C_QuestLog.GetQuestObjectives) == "function"
  for i = 1, n do
    local info = C.Call(C_QuestLog.GetInfo, i)
    -- A secret isHeader reads as unknown: the entry is used only if its questID is readable
    local id = type(info) == "table" and plain(info.isHeader) ~= true and plain(info.questID)
    if type(id) ~= "number" then id = nil end
    if id then
      local entry = {}
      if hasComplete then
        local ok, complete = pcall(C_QuestLog.IsComplete, id)
        if ok and not C.IsSecret(complete) then entry.complete = complete and true or false end
      end
      if hasObjectives then
        local objs = C.Call(C_QuestLog.GetQuestObjectives, id)
        if type(objs) == "table" then
          local out = {}
          for k = 1, #objs do
            local o = objs[k]
            if type(o) == "table" then
              local fin = plain(o.finished)
              if fin ~= nil then fin = fin and true or false end
              out[k] = { fulfilled = plain(o.numFulfilled), required = plain(o.numRequired), finished = fin }
            else
              out[k] = {}
            end
          end
          entry.objectives = out
        end
      end
      log[id] = entry
    end
  end
  return log
end

function C.GetBindLocation()
  return plain(C.Call(GetBindLocation))
end

function C.IsOnTaxi()
  if type(UnitOnTaxi) ~= "function" then return nil end
  local ok, v = pcall(UnitOnTaxi, "player")
  if not ok or C.IsSecret(v) then return nil end
  return v and true or false
end

-- isDead, isGhost (each nil when its API is missing)
function C.GetDeathState()
  local dead, ghost
  if type(UnitIsDead) == "function" then
    local ok, v = pcall(UnitIsDead, "player")
    if ok and not C.IsSecret(v) then dead = v and true or false end
  end
  if type(UnitIsGhost) == "function" then
    local ok, v = pcall(UnitIsGhost, "player")
    if ok and not C.IsSecret(v) then ghost = v and true or false end
  end
  if dead == nil and ghost == nil and type(UnitIsDeadOrGhost) == "function" then
    local ok, v = pcall(UnitIsDeadOrGhost, "player")
    if ok and not C.IsSecret(v) then dead = v and true or false end
  end
  return dead, ghost
end

-- true/false, or nil when no spell lookup exists
function C.IsSpellKnown(spellID)
  local fn = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsSpellKnown
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, spellID)
  if not ok or C.IsSecret(v) then return nil end
  return v and true or false
end

-- count, or nil when no item count API exists
function C.GetItemCount(itemID)
  local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, itemID)
  if not ok or C.IsSecret(v) or type(v) ~= "number" then return nil end
  return v
end

function C.GetPlayerGUID()
  return plain(C.Call(UnitGUID, "player"))
end

-- C_QuestLog.GetMaxNumQuestsCanAccept(), or nil if unavailable
function C.GetMaxQuestsCanAccept()
  if not (C_QuestLog and type(C_QuestLog.GetMaxNumQuestsCanAccept) == "function") then return nil end
  local n = plain(C.Call(C_QuestLog.GetMaxNumQuestsCanAccept))
  if type(n) ~= "number" or n <= 0 then return nil end
  return n
end

-- Native waypoint ------------------------------------------------------------------
-- We never replace or clear a waypoint the player placed. The waypoint we set is
-- remembered in LevelingNavigatorCharDB.waypoint (map, x, y in 0-100) so it can still be
-- recognised and cleared after a /reload.

local function ours()
  local w = ns.char and ns.char.waypoint
  if type(w) == "table" and type(w.map) == "number" and type(w.x) == "number" and type(w.y) == "number" then
    return w
  end
  return nil
end

local function setOurs(w)
  if ns.char then ns.char.waypoint = w end
end

-- The current user waypoint as map, x, y (0-100); nil if none or unreadable.
-- Second return false when the API to read it is missing.
local function currentWaypoint()
  if not (C_Map and type(C_Map.GetUserWaypoint) == "function") then return nil, false end
  if type(C_Map.HasUserWaypoint) == "function" and not C.Call(C_Map.HasUserWaypoint) then return nil, true end
  local cur = C.Call(C_Map.GetUserWaypoint)
  if type(cur) ~= "table" then return nil, true end
  local pos = cur.position
  local cx, cy
  if pos and type(pos.GetXY) == "function" then cx, cy = C.Call(pos.GetXY, pos) end
  local map = cur.uiMapID
  if map == nil or cx == nil or cy == nil or C.IsSecret(map) or C.IsSecret(cx) or C.IsSecret(cy) then
    return "unreadable", true
  end
  return { map = map, x = cx * 100, y = cy * 100 }, true
end

local function same(a, b)
  return type(a) == "table" and type(b) == "table" and a.map == b.map
    and math.abs(a.x - b.x) <= 0.05 and math.abs(a.y - b.y) <= 0.05
end

function C.CanSetWaypoint(uiMapID)
  if not (uiMapID and C_Map and type(C_Map.SetUserWaypoint) == "function") then return false end
  if type(C_Map.CanSetUserWaypointOnMap) ~= "function" then return false end
  return C.Call(C_Map.CanSetUserWaypointOnMap, uiMapID) == true
end

-- x/y in 0-100 map percent. Returns true when the waypoint was set. Refuses (false) when a
-- waypoint that isn't ours exists, or when existing waypoints can't be inspected.
function C.SetWaypoint(uiMapID, x, y)
  if not (x and y) or not C.CanSetWaypoint(uiMapID) then return false end
  if not (UiMapPoint and type(UiMapPoint.CreateFromCoordinates) == "function") then return false end
  local cur, readableApi = currentWaypoint()
  if not readableApi then return false end
  if cur ~= nil and not same(cur, ours()) then return false end -- the player's own (or unreadable)
  local point = C.Call(UiMapPoint.CreateFromCoordinates, uiMapID, x / 100, y / 100)
  if not point then return false end
  if not pcall(C_Map.SetUserWaypoint, point) then return false end
  setOurs({ map = uiMapID, x = x, y = y })
  if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
  end
  return true
end

-- Clears the user waypoint only if it is still the one we set. Returns true when cleared.
function C.ClearWaypoint()
  local mine = ours()
  if not mine then return false end
  if not (C_Map and type(C_Map.ClearUserWaypoint) == "function") then return false end
  local cur, readableApi = currentWaypoint()
  if not readableApi then return false end -- can't verify: leave it alone (and remember it)
  if cur == nil then setOurs(nil); return false end -- already gone
  if cur == "unreadable" then return false end -- can't verify: leave it alone
  if not same(cur, mine) then setOurs(nil); return false end -- the player replaced it
  if not pcall(C_Map.ClearUserWaypoint) then return false end
  setOurs(nil)
  return true
end

function C.HasOurWaypoint()
  return ours() ~= nil
end
