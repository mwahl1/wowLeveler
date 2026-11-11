-- Offline Lua 5.1 test runner for Leveling Navigator (interface: docs/P2_GUIDE_ENGINE_SPEC.md 8a).
--
-- Run from the repo root:
--   ~/wow-tools/lua-5.1.5/src/lua tools/run_tests.lua [name-filter]
--
-- Discovers tests/*_test.lua. Each file returns `function(T) T.test("name", function() ... end) end`.
-- The optional filter is a plain substring matched against "file: test name".
-- Exit code 0 only if no test failed and no test file failed to load.

local FILTER = arg and arg[1]
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local DEFAULT_RACE = { Horde = 2, Alliance = 1 }
local CACHE_MAX = 4 -- each loaded namespace holds a full faction database; keep a few, evict oldest

local T = { CLASSES = CLASSES, FACTIONS = { "Horde", "Alliance" } }
local harnessWarnings = {}
local function hwarn(msg)
  for _, w in ipairs(harnessWarnings) do if w == msg then return end end
  harnessWarnings[#harnessWarnings + 1] = msg
end

-- Sentinels thrown through error() -------------------------------------------------
local SKIP = {}
local FailMT = { __tostring = function(f) return f.msg end }

-- File listing (macOS/Linux shell or Windows cmd) ---------------------------------------
-- Recursive, sorted, forward-slash paths relative to the current directory.
local WINDOWS = package.config:sub(1, 1) == "\\"
T.WINDOWS = WINDOWS

local function readLines(cmd)
  local lines = {}
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do
      line = line:gsub("\r$", "")
      if line ~= "" then lines[#lines + 1] = line end
    end
    p:close()
  end
  return lines
end

local cwdPrefix
function T.listFiles(dir, suffix)
  local out = {}
  if WINDOWS then
    if not cwdPrefix then
      cwdPrefix = ((readLines("cd")[1] or ""):gsub("\\", "/")) .. "/"
    end
    for _, line in ipairs(readLines('dir /b /s /a-d "' .. dir:gsub("/", "\\") .. '" 2>nul')) do
      local path = line:gsub("\\", "/")
      if path:sub(1, #cwdPrefix):lower() == cwdPrefix:lower() then path = path:sub(#cwdPrefix + 1) end
      out[#out + 1] = path
    end
  else
    out = readLines("find '" .. dir .. "' -type f 2>/dev/null")
    for i, path in ipairs(out) do out[i] = path:gsub("^%./", "") end
  end
  local filtered = {}
  for _, path in ipairs(out) do
    if not suffix or path:sub(-#suffix) == suffix then filtered[#filtered + 1] = path end
  end
  table.sort(filtered)
  return filtered
end

-- TOC parsing ----------------------------------------------------------------------
-- Core/Data.lua first, then Data\ and Guide\ entries in TOC order. UI\ and the other
-- Core\ files need the WoW client and are not loaded offline.
local function addonFiles()
  local files = { "Core/Data.lua" }
  local f = io.open("LevelingNavigator.toc", "r")
  if not f then error("LevelingNavigator.toc not found; run from the repo root") end
  for line in f:lines() do
    line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      local path = line:gsub("\\", "/")
      if path:match("^Data/") or path:match("^Guide/") then files[#files + 1] = path end
    end
  end
  f:close()
  return files
end

local compiled = {} -- path -> chunk (compile each file once per run)
local function loadAddon(faction, class)
  local ns = {}
  local handlers = {}
  ns.On = function(event, fn) handlers[event] = fn end
  ns.Send = function() end
  ns.handlers = handlers
  _G.UnitFactionGroup = function() return faction, faction end
  _G.UnitClass = function() return class, class end
  _G.debugprofilestop = function() return os.clock() * 1000 end
  _G.geterrorhandler = function() return print end

  for _, path in ipairs(addonFiles()) do
    local chunk = compiled[path]
    if chunk == nil then
      local fn, err = loadfile(path)
      if fn then
        compiled[path] = fn
        chunk = fn
      else
        compiled[path] = false
        if err and (err:match("No such file") or err:match("cannot open")) then
          hwarn("TOC lists " .. path .. " but it does not exist; skipped")
        else
          hwarn("could not compile " .. path .. ": " .. tostring(err))
        end
      end
    end
    if chunk then
      local ok, runErr = pcall(chunk, "LevelingNavigator", ns)
      if not ok then error("loading " .. path .. " for " .. faction .. "/" .. class .. ": " .. tostring(runErr), 0) end
    end
  end
  if not (ns.Data and ns.Data.Load) then error("Core/Data.lua did not define ns.Data.Load", 0) end
  ns.Data.Load()
  return ns
end

local cache, cacheOrder = {}, {}
function T.addon(faction, class)
  faction = faction or "Horde"
  class = class or "WARRIOR"
  local key = faction .. "." .. class
  if cache[key] then return cache[key] end
  local ns = loadAddon(faction, class)
  cache[key] = ns
  cacheOrder[#cacheOrder + 1] = key
  if #cacheOrder > CACHE_MAX then
    cache[table.remove(cacheOrder, 1)] = nil
    collectgarbage("collect")
  end
  return ns
end

-- Uncached namespace, for tests that mutate real records
function T.fresh(faction, class)
  return loadAddon(faction or "Horde", class or "WARRIOR")
end

-- Mutable namespaces shared across test files, kept apart from the T.addon cache so
-- injected quests and registered routes never leak into the data smoke counts.
local sandboxes = {}
function T.sandbox(faction, class)
  local key = (faction or "Horde") .. "." .. (class or "WARRIOR")
  sandboxes[key] = sandboxes[key] or loadAddon(faction or "Horde", class or "WARRIOR")
  return sandboxes[key]
end

-- Skip the current test unless ns[name] exists (module not implemented yet)
function T.needModule(ns, ...)
  for _, name in ipairs({ ... }) do
    if ns[name] == nil then T.skip("ns." .. name .. " not present (module not loaded)") end
  end
end

-- tests/fixtures/<name>.lua, loaded once; returns whatever the fixture file returns
local fixtures = {}
function T.fixture(name)
  if fixtures[name] == nil then
    local fn, err = loadfile("tests/fixtures/" .. name .. ".lua")
    if not fn then error("fixture " .. name .. ": " .. tostring(err), 2) end
    fixtures[name] = fn()
  end
  return fixtures[name]
end

-- CharacterState (spec 3.1) ---------------------------------------------------------
-- Pass T.NIL to clear a default, e.g. T.state{ raceID = T.NIL }.
T.NIL = setmetatable({}, { __tostring = function() return "T.NIL" end })
function T.state(o)
  o = o or {}
  local faction = o.faction or "Horde"
  local s = {
    time = 0,
    faction = faction,
    raceID = DEFAULT_RACE[faction] or 2,
    classFile = "WARRIOR",
    level = 1, xp = 0, xpMax = 400, restedXP = 0,
    map = nil, x = nil, y = nil,
    completed = {},
    log = {},
    onTaxi = false, isDead = false, isGhost = false,
  }
  for k, v in pairs(o) do
    if v == T.NIL then s[k] = nil else s[k] = v end
  end
  return s
end

-- Synthetic quests -------------------------------------------------------------------
local nextID = 9000000
function T.newID()
  nextID = nextID + 1
  return nextID
end

function T.hasField(ns, name) return ns.DataSchema and ns.DataSchema.Q and ns.DataSchema.Q[name] ~= nil end

-- Skip the current test unless every named quest field exists in the schema
function T.needFields(ns, ...)
  local missing = {}
  for _, name in ipairs({ ... }) do
    if not T.hasField(ns, name) then missing[#missing + 1] = name end
  end
  if #missing > 0 then T.skip("schema has no quest field(s) " .. table.concat(missing, ", ") .. " yet") end
end

function T.inject(ns, questID, fields)
  local Q = ns.DataSchema and ns.DataSchema.Q
  if not Q then error("T.inject: ns.DataSchema.Q missing", 2) end
  local rec = {}
  fields = fields or {}
  for name, value in pairs(fields) do
    local idx = Q[name]
    if not idx then error("T.inject: unknown quest field '" .. tostring(name) .. "'", 2) end
    rec[idx] = value
  end
  if fields.NAME == nil then rec[Q.NAME] = "Synthetic " .. questID end
  if fields.LABELS == nil and Q.LABELS then rec[Q.LABELS] = "UUUU" end
  if fields.FLAGS == nil and Q.FLAGS then rec[Q.FLAGS] = 0 end
  ns.Data.quests[questID] = rec
  return rec
end

-- Assertions ----------------------------------------------------------------------------
local function fail(msg, level) error(setmetatable({ msg = msg }, FailMT), level + 1) end

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local parts, n = {}, 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 8 then parts[#parts + 1] = "..." break end
    parts[#parts + 1] = "[" .. show(k) .. "]=" .. show(x)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function deepEq(a, b, seen)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do if not deepEq(v, b[k], seen) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
T.deepEq = deepEq

local function where()
  local info = debug.getinfo(3, "Sl")
  return info and (info.short_src .. ":" .. tostring(info.currentline)) or "?"
end

function T.eq(actual, expected, msg)
  if not deepEq(actual, expected) then
    fail(where() .. ": " .. (msg and (msg .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function T.ok(cond, msg)
  if not cond then fail(where() .. ": " .. (msg or "assertion failed"), 2) end
end

function T.contains(list, value, msg)
  if type(list) == "table" then
    for _, v in pairs(list) do if deepEq(v, value) then return end end
  end
  fail(where() .. ": " .. (msg and (msg .. ": ") or "") .. show(list) .. " does not contain " .. show(value), 2)
end

function T.skip(reason) error(setmetatable({ skip = true, msg = reason or "skipped" }, { __index = SKIP }), 0) end

-- Timing: median ms per call of fn over `batches` batches of `per` calls, after one warm-up call
function T.bench(fn, batches, per)
  batches, per = batches or 7, per or 20
  fn()
  local samples = {}
  for b = 1, batches do
    local t0 = os.clock()
    for _ = 1, per do fn() end
    samples[b] = (os.clock() - t0) * 1000 / per
  end
  table.sort(samples)
  local n = #samples
  local median = n % 2 == 1 and samples[(n + 1) / 2] or (samples[n / 2] + samples[n / 2 + 1]) / 2
  return median, samples[1], samples[n]
end

-- Runner ----------------------------------------------------------------------------------
local tests = {}
local loadErrors = 0
local currentFile

function T.test(name, fn)
  tests[#tests + 1] = { file = currentFile, name = name, fn = fn }
end

local testFiles = {}
for _, path in ipairs(T.listFiles("tests", "_test.lua")) do
  if path:match("^tests/[^/]+_test%.lua$") then testFiles[#testFiles + 1] = path end -- top level only
end

local started = os.clock()
print("Leveling Navigator offline tests (" .. _VERSION .. ")" .. (FILTER and ("  filter: " .. FILTER) or ""))
if #testFiles == 0 then print("no tests/*_test.lua found") end

for _, path in ipairs(testFiles) do
  currentFile = path
  local chunk, err = loadfile(path)
  local ok, defineErr = false, err
  if chunk then
    ok, defineErr = pcall(function()
      local def = chunk()
      if type(def) ~= "function" then error("test file must return function(T)", 0) end
      def(T)
    end)
  end
  if not ok then
    loadErrors = loadErrors + 1
    print("FAIL  " .. path .. " (load): " .. tostring(defineErr))
  end
end

local passed, failed, skipped = 0, 0, 0
for _, t in ipairs(tests) do
  local label = t.file .. ": " .. t.name
  if not FILTER or label:find(FILTER, 1, true) then
    local ok, err = xpcall(t.fn, function(e)
      if type(e) == "table" then return e end
      return debug.traceback(tostring(e), 2)
    end)
    if ok then
      passed = passed + 1
      print("PASS  " .. label)
    elseif type(err) == "table" and err.skip then
      skipped = skipped + 1
      print("SKIP  " .. label .. ": " .. err.msg)
    else
      failed = failed + 1
      local msg = type(err) == "table" and err.msg or tostring(err)
      print("FAIL  " .. label .. "\n      " .. msg:gsub("\n", "\n      "))
    end
  end
end

for _, w in ipairs(harnessWarnings) do print("WARN  harness: " .. w) end
print(string.format("%d passed, %d failed, %d skipped, %d file load errors  (%.1f s)",
  passed, failed, skipped, loadErrors, os.clock() - started))
-- Finding no tests is a broken run (wrong directory, listing failed), never a pass
os.exit((failed == 0 and loadErrors == 0 and #testFiles > 0) and 0 or 1)
