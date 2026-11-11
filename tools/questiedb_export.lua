-- Exports QuestieDB's fully corrected Forever data to JSON for our offline tools.
--
-- Uses QuestieDB's own loader (generator/flavor.lua): raw data + every Static
-- Correction layer + Derived Passes, exactly what QuestieDB's generator bakes.
-- Dynamic (faction/race-dependent) corrections are NOT applied here; they run
-- in-game in Questie and are handled later in our own pipeline.
--
-- Must be run from the root of a QuestieDB checkout, with Lua 5.1:
--   cd ~/wow-tools/QuestieDB
--   ../lua-5.1.5/src/lua ~/LevelingNavigator/tools/questiedb_export.lua <out-dir>

local outDir = assert(arg[1], "usage: lua questiedb_export.lua <out-dir>")
assert(io.open("src/config.lua", "r"), "run this from the root of a QuestieDB checkout")

local config = dofile("src/config.lua")
local flavorLoader = dofile("generator/flavor.lua")
local flavor = assert(config.flavorByName.Forever, "this QuestieDB version has no Forever flavor")

-- JSON writer ------------------------------------------------------------------

local function isArray(t)
  local count, max = 0, 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    count = count + 1
    if k > max then max = k end
  end
  -- Allow small holes ({nil, {...}}); sparse ID-keyed maps become objects
  return max <= count * 2 + 4, max
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  return keys
end

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode(v, out)
  local t = type(v)
  if v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif v % 1 == 0 and math.abs(v) < 2^53 then
      out[#out + 1] = string.format("%.0f", v)
    else
      out[#out + 1] = string.format("%.14g", v)
    end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    local array, max = isArray(v)
    if array then
      out[#out + 1] = "["
      for i = 1, max do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      for i, k in ipairs(sortedKeys(v)) do
        if i > 1 then out[#out + 1] = "," end
        encode(tostring(k), out)
        out[#out + 1] = ":"
        encode(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode " .. t)
  end
end

local function writeJSON(path, value)
  local out = {}
  encode(value, out)
  local f = assert(io.open(path, "wb"))
  f:write(table.concat(out))
  f:close()
end

-- Entities -----------------------------------------------------------------------

local WINDOWS = package.config:sub(1, 1) == "\\"
if WINDOWS then
  os.execute('mkdir "' .. outDir:gsub("/", "\\") .. '" 2>nul') -- cmd creates intermediate dirs
else
  os.execute('mkdir -p "' .. outDir .. '"')
end

local started = os.clock()
local loaded, stats = flavorLoader.load(flavor, nil, true)

local summary = { counts = {}, correctionsApplied = stats.applied }

for typeName, entry in pairs(loaded) do
  -- Convert positional tuples into objects keyed by field name
  local names = {}
  for name, index in pairs(entry.meta.keys) do names[index] = name end
  local out, n = {}, 0
  for id, row in pairs(entry.entities) do
    local obj = {}
    for index, value in pairs(row) do
      obj[names[index] or ("field" .. index)] = value
    end
    out[tostring(id)] = obj -- string keys: always a JSON object
    n = n + 1
  end
  writeJSON(outDir .. "/" .. typeName:lower() .. "s.json", out)
  summary.counts[typeName] = n
  print(string.format("%-7s %6d entities", typeName, n))
end

-- Correction layers ----------------------------------------------------------------
-- A second instance of QuestieDB's correction registry, used only to (a) record which
-- Static layer last wrote each field, and (b) apply Dynamic (faction/class) corrections.
-- The entity data above stays the authoritative result of QuestieDB's own loader.

local corrections = dofile("generator/corrections.lua")
local registry = assert(corrections.registryFor(flavor), "no correction registry")
local OWNER = registry.OWNER
local OP_OFFSET = 1000 -- tablePatch encodes add/remove operations as fieldIndex + n*1000

local raw = flavorLoader.load(flavor, nil, false)
local rawIds, provenance, layerNames = {}, {}, {}

for _, entityType in ipairs(config.entityTypes) do
  local typeName = entityType.name
  local names = {}
  for name, index in pairs(loaded[typeName].meta.keys) do names[index] = name end

  local ids = {}
  for id in pairs(raw[typeName].entities) do ids[#ids + 1] = id end
  table.sort(ids)
  rawIds[typeName] = ids

  -- Last Static layer to touch each field (approximation: noOverwrites layers counted as writers)
  local byId = {}
  for _, entry in ipairs(registry.Select({ datatype = typeName, dynamic = false, owner = OWNER })) do
    if registry.EntryApplies(entry, flavor) then
      local ok, rows = pcall(entry.func)
      if ok and type(rows) == "table" then
        layerNames[entry.name] = true
        for id, fields in pairs(rows) do
          if type(fields) == "table" then
            local key = tostring(id)
            byId[key] = byId[key] or {}
            for fieldKey in pairs(fields) do
              if type(fieldKey) == "number" then
                local index = fieldKey % OP_OFFSET
                byId[key][names[index] or ("field" .. index)] = entry.name
              end
            end
          end
        end
      elseif not ok then
        print("WARNING provenance: layer " .. tostring(entry.name) .. " failed: " .. tostring(rows))
      end
    end
  end
  provenance[typeName] = byId
end

writeJSON(outDir .. "/provenance.json", { rawIds = rawIds, lastStaticLayer = provenance })

-- Dynamic corrections per faction and class. Providers read UnitFactionGroup and
-- UnitClassBase at call time, so each combination is evaluated with stubbed values.

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, child in pairs(v) do out[k] = deepCopy(child) end
  return out
end

local function deepEqual(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local FACTIONS = { "Horde", "Alliance" }
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local dynamic, dynamicErrors, dynamicLayers = {}, {}, {}

for _, faction in ipairs(FACTIONS) do
  dynamic[faction] = {}
  for _, class in ipairs(CLASSES) do
    _G.UnitFactionGroup = function() return faction, faction end
    _G.UnitClassBase = function() return class end
    local perType = {}
    for _, entityType in ipairs(config.entityTypes) do
      local typeName = entityType.name
      local static = loaded[typeName].entities
      local names = {}
      for name, index in pairs(loaded[typeName].meta.keys) do names[index] = name end

      local work = {}
      for _, entry in ipairs(registry.Select({ datatype = typeName, dynamic = true, owner = OWNER })) do
        if registry.EntryApplies(entry, flavor) then
          local ok, rows = pcall(entry.func)
          if ok and type(rows) == "table" then
            dynamicLayers[entry.name] = true
            for id in pairs(rows) do
              if work[id] == nil and static[id] ~= nil then work[id] = deepCopy(static[id]) end
            end
            local okMerge, err = pcall(registry.MergeInto, work, rows, entry.options, entry)
            if not okMerge then dynamicErrors[#dynamicErrors + 1] = faction .. "/" .. class .. " " .. tostring(entry.name) .. ": " .. tostring(err) end
          elseif not ok then
            dynamicErrors[#dynamicErrors + 1] = faction .. "/" .. class .. " " .. tostring(entry.name) .. ": " .. tostring(rows)
          end
        end
      end

      -- Keep only fields that differ from the Static result
      local diff = {}
      for id, row in pairs(work) do
        local base = static[id] or {}
        local changed, removed = {}, {}
        for index, value in pairs(row) do
          if not deepEqual(value, base[index]) then changed[names[index] or ("field" .. index)] = value end
        end
        for index in pairs(base) do
          if row[index] == nil then removed[#removed + 1] = names[index] or ("field" .. index) end
        end
        if next(changed) or #removed > 0 then
          if #removed > 0 then changed.__removed = removed end
          if not static[id] then changed.__new = true end
          diff[tostring(id)] = changed
        end
      end
      perType[typeName] = diff
    end
    dynamic[faction][class] = perType
  end
end
_G.UnitFactionGroup, _G.UnitClassBase = nil, nil

writeJSON(outDir .. "/dynamic.json", dynamic)
for _, e in ipairs(dynamicErrors) do print("WARNING dynamic: " .. e) end

local function keysOf(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end
summary.staticLayers = keysOf(layerNames)
summary.dynamicLayers = keysOf(dynamicLayers)
summary.dynamicErrors = #dynamicErrors
print("Static layers:  " .. table.concat(summary.staticLayers, ", "))
print("Dynamic layers: " .. table.concat(summary.dynamicLayers, ", "))

-- Support data (XP, zone mapping) --------------------------------------------------
-- These files assign into QuestieLoader modules; a minimal stub captures them.

local modules = {}
local function moduleFor(name)
  modules[name] = modules[name] or { private = {} }
  return modules[name]
end
_G.QuestieLoader = {
  ImportModule = function(_, name) return moduleFor(name) end,
  CreateModule = function(_, name) return moduleFor(name) end,
}
dofile("support/Forever/QuestXP/xpDB-classic.lua")
local classicXP = {}
for id, v in pairs(moduleFor("QuestXP").db) do classicXP[id] = v end
dofile("support/Forever/QuestXP/xpDB-traces.lua")
-- Entries replaced or added by the traces file were measured from Forever players
local tracedXP = {}
for id, v in pairs(moduleFor("QuestXP").db) do
  if classicXP[id] ~= v then tracedXP[#tracedXP + 1] = id end
end
table.sort(tracedXP)
dofile("support/Forever/Zones/areaIdToUiMapId.lua")
dofile("support/Forever/Zones/subZoneToParentZone.lua")
_G.QuestieLoader = nil

local zone = moduleFor("ZoneDB").private
local function decode(s) return s and assert(loadstring(s))() or {} end

writeJSON(outDir .. "/support.json", {
  questXP = moduleFor("QuestXP").db,               -- questID -> {level, xp}
  questXPTraced = tracedXP,                        -- questIDs whose XP came from Forever traces
  areaIdToUiMapId = decode(zone.areaIdToUiMapId),
  areaIdToUiMapIdOverride = decode(zone.areaIdToUiMapIdOverride),
  subZoneToParentZone = decode(zone.subZoneToParentZone),
  subZoneToParentZoneOverride = decode(zone.subZoneToParentZoneOverride),
})

-- Provenance -----------------------------------------------------------------------

local commit = "unknown"
local pipe = io.popen(WINDOWS and "git rev-parse HEAD 2>nul" or "git rev-parse HEAD 2>/dev/null")
if pipe then commit = (pipe:read("*l") or commit); pipe:close() end

summary.questiedbCommit = commit
summary.flavor = flavor.name
summary.interface = flavor.interface
summary.exportedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
summary.dynamicCorrections = "not applied"
writeJSON(outDir .. "/manifest.json", summary)

print(string.format("Applied %d static corrections. QuestieDB %s. Done in %.1fs -> %s",
  stats.applied or 0, commit:sub(1, 10), os.clock() - started, outDir))
