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

os.execute('mkdir -p "' .. outDir .. '"')

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
dofile("support/Forever/QuestXP/xpDB-traces.lua")
dofile("support/Forever/Zones/areaIdToUiMapId.lua")
dofile("support/Forever/Zones/subZoneToParentZone.lua")
_G.QuestieLoader = nil

local zone = moduleFor("ZoneDB").private
local function decode(s) return s and assert(loadstring(s))() or {} end

writeJSON(outDir .. "/support.json", {
  questXP = moduleFor("QuestXP").db,               -- questID -> {level, xp}
  areaIdToUiMapId = decode(zone.areaIdToUiMapId),
  areaIdToUiMapIdOverride = decode(zone.areaIdToUiMapIdOverride),
  subZoneToParentZone = decode(zone.subZoneToParentZone),
  subZoneToParentZoneOverride = decode(zone.subZoneToParentZoneOverride),
})

-- Provenance -----------------------------------------------------------------------

local commit = "unknown"
local pipe = io.popen("git rev-parse HEAD 2>/dev/null")
if pipe then commit = (pipe:read("*l") or commit); pipe:close() end

summary.questiedbCommit = commit
summary.flavor = flavor.name
summary.interface = flavor.interface
summary.exportedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
summary.dynamicCorrections = "not applied"
writeJSON(outDir .. "/manifest.json", summary)

print(string.format("Applied %d static corrections. QuestieDB %s. Done in %.1fs -> %s",
  stats.applied or 0, commit:sub(1, 10), os.clock() - started, outDir))
