-- Validates the generated Data/*.lua with real Lua 5.1 by running the addon's own loader
-- (Core/Data.lua) for every faction and class, with minimal stand-ins for the WoW API.
--
-- Run from the repo root:
--   ~/wow-tools/lua-5.1.5/src/lua tools/validate_data.lua

local FILES = { "Data/Schema.lua", "Data/Meta.lua", "Data/Neutral.lua", "Data/Horde.lua", "Data/Alliance.lua" }
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local FACTIONS = { "Horde", "Alliance" }

local errors, warnings = 0, 0
local function fail(msg) errors = errors + 1; if errors <= 40 then print("ERROR  " .. msg) end end
local function warn(msg) warnings = warnings + 1; if warnings <= 20 then print("WARN   " .. msg) end end

local function loadAddon(faction, class)
  local ns = {}
  local handlers = {}
  ns.On = function(event, fn) handlers[event] = fn end
  ns.Send = function() end
  _G.UnitFactionGroup = function() return faction, faction end
  _G.UnitClass = function() return class, class end
  _G.debugprofilestop = function() return os.clock() * 1000 end
  _G.geterrorhandler = function() return print end

  local function run(path)
    local chunk, err = loadfile(path)
    if not chunk then fail(path .. ": " .. tostring(err)); return false end
    local ok, runErr = pcall(chunk, "LevelingNavigator", ns)
    if not ok then fail(path .. ": " .. tostring(runErr)); return false end
    return true
  end

  if not run("Core/Data.lua") then return end
  for _, path in ipairs(FILES) do run(path) end
  collectgarbage("collect")
  ns.Data.Load()
  return ns
end

local function checkFaction(ns, faction, class)
  local D, S, M = ns.Data, ns.DataSchema, ns.DataMeta
  local st = D.status
  local tag = faction .. "/" .. class
  if st.state ~= "loaded" then
    fail(tag .. " loader state " .. tostring(st.state) .. ": " .. table.concat(st.errors or {}, " | "))
    return st
  end

  -- Counts must match what the build tool wrote into Meta
  local expected = {}
  for _, side in ipairs({ "Neutral", faction }) do
    for kind, n in pairs(M.counts[side] or {}) do expected[kind] = (expected[kind] or 0) + n end
  end
  for kind, n in pairs(expected) do
    if st.counts[kind] ~= n then fail(string.format("%s %s count %s, Meta says %d", tag, kind, tostring(st.counts[kind]), n)) end
  end

  if class ~= "WARRIOR" then return st end -- record checks don't depend on class; run once per faction

  local Q, N, O = S.Q, S.NPC, S.OBJ
  local function checkSpawns(kind, id, spawns)
    if spawns == nil then return end
    if #spawns % 3 ~= 0 then fail(kind .. " " .. id .. " spawns not triples") return end
    for i = 1, #spawns, 3 do
      local m, x, y = spawns[i], spawns[i + 1], spawns[i + 2]
      if type(m) ~= "number" or m % 1 ~= 0 or m <= 0 then fail(kind .. " " .. id .. " bad uiMap " .. tostring(m)) end
      if type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 100 or y < 0 or y > 100 then
        fail(kind .. " " .. id .. " coordinate out of range " .. tostring(x) .. "," .. tostring(y))
      end
    end
  end

  local missingRefs = 0
  for id, q in pairs(D.quests) do
    if type(q[Q.NAME]) ~= "string" then fail(tag .. " quest " .. id .. " has no name") end
    local labels = q[Q.LABELS]
    if type(labels) ~= "string" or not labels:match("^[VOEU][VOEU][VOEU][VOEU]$") then
      fail(tag .. " quest " .. id .. " bad labels " .. tostring(labels))
    end
    if type(q[Q.FLAGS]) ~= "number" then fail(tag .. " quest " .. id .. " missing flags") end
    local start, finish = q[Q.START], q[Q.FINISH]
    for _, nid in ipairs((start and start[1]) or {}) do if not D.npcs[nid] then missingRefs = missingRefs + 1 end end
    for _, nid in ipairs((finish and finish[1]) or {}) do if not D.npcs[nid] then missingRefs = missingRefs + 1 end end
    for _, oid in ipairs((start and start[2]) or {}) do if not D.objects[oid] then missingRefs = missingRefs + 1 end end
    for _, iid in ipairs((start and start[3]) or {}) do if not D.items[iid] then missingRefs = missingRefs + 1 end end
    if q[Q.RACES] and not D.RaceAllowed(q[Q.RACES], faction == "Horde" and 2 or 1)
        and not D.RaceAllowed(q[Q.RACES], faction == "Horde" and 5 or 4)
        and not D.RaceAllowed(q[Q.RACES], faction == "Horde" and 6 or 3)
        and not D.RaceAllowed(q[Q.RACES], faction == "Horde" and 8 or 7)
        and not D.RaceAllowed(q[Q.RACES], faction == "Horde" and 96 or 95) then
      fail(tag .. " quest " .. id .. " loaded but no " .. faction .. " race may take it")
    end
  end
  -- M3.1 availability fields: types only (number / list of numbers / {id, value} pair)
  local avail = { BREADCRUMBS = 0, DISABLED_BY = 0, AVAILABLE_UNTIL = 0, AVAILABLE_WITH = 0,
                  MIN_REP = 0, MAX_REP = 0, REQ_SPELL = 0, REQ_SPEC = 0, REQ_RANKS = 0 }
  for name in pairs(avail) do
    if type(Q[name]) ~= "number" then fail("schema has no quest field " .. name) end
  end
  local function isInt(v) return type(v) == "number" and v % 1 == 0 end
  local function isPair(v) return type(v) == "table" and #v == 2 and isInt(v[1]) and isInt(v[2]) end
  local function checkAvail(id, q)
    local function bad(name) fail(tag .. " quest " .. id .. " bad " .. name .. " " .. tostring(q[Q[name]])) end
    for _, name in ipairs({ "DISABLED_BY", "AVAILABLE_UNTIL", "AVAILABLE_WITH", "REQ_SPEC" }) do
      local v = q[Q[name]]
      if v ~= nil then avail[name] = avail[name] + 1; if not isInt(v) or v <= 0 then bad(name) end end
    end
    local spell = q[Q.REQ_SPELL]
    if spell ~= nil then avail.REQ_SPELL = avail.REQ_SPELL + 1; if not isInt(spell) or spell == 0 then bad("REQ_SPELL") end end
    local bc = q[Q.BREADCRUMBS]
    if bc ~= nil then
      avail.BREADCRUMBS = avail.BREADCRUMBS + 1
      if type(bc) ~= "table" or #bc == 0 then bad("BREADCRUMBS")
      else for _, v in ipairs(bc) do if not isInt(v) or v <= 0 then bad("BREADCRUMBS") break end end end
    end
    for _, name in ipairs({ "MIN_REP", "MAX_REP" }) do
      local v = q[Q[name]]
      if v ~= nil then avail[name] = avail[name] + 1; if not isPair(v) or v[1] <= 0 then bad(name) end end
    end
    local ranks = q[Q.REQ_RANKS]
    if ranks ~= nil then
      avail.REQ_RANKS = avail.REQ_RANKS + 1
      if type(ranks) ~= "table" or #ranks == 0 then bad("REQ_RANKS")
      else for _, v in ipairs(ranks) do if not isPair(v) then bad("REQ_RANKS") break end end end
    end
  end
  for id, q in pairs(D.quests) do checkAvail(id, q) end
  local parts = {}
  for _, name in ipairs({ "BREADCRUMBS", "DISABLED_BY", "AVAILABLE_UNTIL", "AVAILABLE_WITH", "MIN_REP",
                          "MAX_REP", "REQ_SPELL", "REQ_SPEC", "REQ_RANKS" }) do
    parts[#parts + 1] = name .. " " .. avail[name]
  end
  print(tag .. " availability fields: " .. table.concat(parts, ", "))

  if missingRefs > 0 then warn(tag .. ": " .. missingRefs .. " quest giver/turn-in references not in the database (see DATA_COVERAGE.md integrity section)") end

  for id, n in pairs(D.npcs) do
    if type(n[N.NAME]) ~= "string" then fail(tag .. " npc " .. id .. " has no name") end
    checkSpawns("npc", id, n[N.SPAWNS])
  end
  for id, o in pairs(D.objects) do checkSpawns("object", id, o[O.SPAWNS]) end

  -- Starting quests must be loadable for every race of this faction
  local raceFaction = { [1] = "Alliance", [3] = "Alliance", [4] = "Alliance", [7] = "Alliance", [95] = "Alliance",
                        [2] = "Horde", [5] = "Horde", [6] = "Horde", [8] = "Horde", [96] = "Horde" }
  for raceID, info in pairs(M.startingQuests) do
    if raceFaction[raceID] == faction then
      if #(info.quests or {}) == 0 then warn(tag .. " race " .. raceID .. " has no starting quests") end
      for _, qid in ipairs(info.quests or {}) do
        if not D.quests[qid] then fail(tag .. " starting quest " .. qid .. " for race " .. raceID .. " not loaded") end
      end
    end
  end
  return st
end

print("Validating Data/*.lua with " .. _VERSION)
for _, faction in ipairs(FACTIONS) do
  for _, class in ipairs(CLASSES) do
    local ns = loadAddon(faction, class)
    if ns then
      local st = checkFaction(ns, faction, class)
      if class == "WARRIOR" and st and st.counts then
        local c = st.counts
        print(string.format("%-8s quests %5d  npcs %5d  objects %4d  items %4d  load %4.0f ms  memory %5.1f MB",
          faction, c.quests, c.npcs, c.objects, c.items, st.ms or 0, (st.memoryKB or 0) / 1024))
      end
      if st and st.counts and st.counts.classOverrides > 0 then
        print(string.format("         %s: %d class overrides applied", class, st.counts.classOverrides))
      end
    end
  end
end

print(string.format("%d errors, %d warnings", errors, warnings))
os.exit(errors == 0 and 0 or 1)
