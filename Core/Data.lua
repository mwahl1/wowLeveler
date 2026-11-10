-- Quest database loader. Data/*.lua files register their tables as source strings via
-- ns.Data.AddChunk; at login only the Neutral chunks plus the player's faction (and class
-- overrides) are compiled, so the other faction's data never becomes Lua tables.
local ADDON, ns = ...

local Data = {
  chunks = {},
  quests = {},
  npcs = {},
  objects = {},
  items = {},
  status = { state = "pending" },
}
ns.Data = Data

function Data.AddChunk(side, kind, src)
  Data.chunks[#Data.chunks + 1] = { side = side, kind = kind, src = src }
end

local function Merge(target, source)
  local n = 0
  for id, record in pairs(source) do
    target[id] = record
    n = n + 1
  end
  return n
end

-- Class overrides store only changed field indexes; false clears a field
local function ApplyClassOverrides(rows)
  local n = 0
  for questID, fields in pairs(rows) do
    local quest = Data.quests[questID]
    if quest then
      for index, value in pairs(fields) do
        if value == false then quest[index] = nil else quest[index] = value end
      end
      n = n + 1
    end
  end
  return n
end

function Data.Load()
  if Data.status.state ~= "pending" then return end
  local faction = UnitFactionGroup("player")
  local _, class = UnitClass("player")
  local started = debugprofilestop and debugprofilestop() or 0
  local errors, counts = {}, { quests = 0, npcs = 0, objects = 0, items = 0, classOverrides = 0 }

  for _, chunk in ipairs(Data.chunks) do
    local kind, chunkClass = chunk.kind:match("^([^:]+):?(.*)$")
    local wanted = chunk.side == "Neutral" or chunk.side == faction
    if wanted and (chunkClass == "" or chunkClass == class) then
      local fn, err = loadstring(chunk.src, "LevelingNavigator " .. chunk.side .. " " .. chunk.kind)
      local ok, result = false, err
      if fn then ok, result = pcall(fn) end
      if ok and type(result) == "table" then
        if kind == "classQuests" then
          -- Applied after all quest chunks are merged (chunks are ordered by kind)
          chunk.pendingRows = result
        else
          counts[kind] = (counts[kind] or 0) + Merge(Data[kind], result)
        end
      else
        errors[#errors + 1] = chunk.side .. " " .. chunk.kind .. ": " .. tostring(result)
      end
    end
  end

  for _, chunk in ipairs(Data.chunks) do
    if chunk.pendingRows then
      counts.classOverrides = counts.classOverrides + ApplyClassOverrides(chunk.pendingRows)
    end
  end

  -- Drop every source string so it can be garbage collected
  Data.chunks = {}
  collectgarbage("collect")

  -- Whole-addon memory after loading; outside the game, total Lua memory
  local memoryKB
  if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
    pcall(UpdateAddOnMemoryUsage)
    local ok, kb = pcall(GetAddOnMemoryUsage, ADDON)
    if ok then memoryKB = kb end
  end
  memoryKB = memoryKB or collectgarbage("count")

  Data.status = {
    state = #errors == 0 and "loaded" or "errors",
    faction = faction,
    class = class,
    counts = counts,
    errors = errors,
    ms = debugprofilestop and (debugprofilestop() - started) or nil,
    memoryKB = math.floor(memoryKB),
  }
  ns.Send("DATA_LOADED")
end

-- Queries -------------------------------------------------------------------------

local S -- ns.DataSchema, set once Data/Schema.lua has loaded

function Data.GetQuest(id) return Data.quests[id] end
function Data.GetNPC(id) return Data.npcs[id] end
function Data.GetObject(id) return Data.objects[id] end
function Data.GetItem(id) return Data.items[id] end

-- requiredRaces uses bits 32/33 for Skyborne, beyond the 32-bit `bit` library
function Data.RaceAllowed(mask, raceID)
  if not mask or mask == 0 then return true end
  S = S or ns.DataSchema
  local bit = S and S.RACE_BIT[raceID]
  if not bit then return false end
  return math.floor(mask / bit) % 2 == 1
end

function Data.ClassAllowed(mask, classFile)
  if not mask or mask == 0 then return true end
  S = S or ns.DataSchema
  local bit = S and S.CLASS_BIT[classFile]
  if not bit then return false end
  return math.floor(mask / bit) % 2 == 1
end

ns.On("PLAYER_LOGIN", function()
  local ok, err = pcall(Data.Load)
  if not ok then
    Data.status = { state = "errors", errors = { tostring(err) } }
    geterrorhandler()(err)
  end
end)
