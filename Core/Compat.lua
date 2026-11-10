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
    rested = C.Call(GetXPExhaustion) or 0,
  }
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
