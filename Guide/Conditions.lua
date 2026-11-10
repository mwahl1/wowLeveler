-- Declarative route conditions (P2 spec 3.4), shared by the Compiler, Selector and Engine.
-- Pure Lua 5.1 (no WoW API).
--
--   local result = ns.GuideConditions.Eval(cond, state)   -- true | false | nil (unknown)
--   local bad = ns.GuideConditions.UnknownKeys(cond)      -- nil or { key, ... } (compile-time)
--
-- A condition table is an AND of its keys. Any false key -> false; otherwise any unknown key
-- -> nil; otherwise true. A nil/empty condition holds (true). Missing state is unknown (nil),
-- never assumed. Unknown keys evaluate to nil, never silently true.
local _, ns = ...

local C = {}
ns.GuideConditions = C

local EMPTY = {}
local type = type

-- Is `v` (a scalar) equal to `want`, or contained in `want` when it is a list?
local function matches(want, v)
  if type(want) ~= "table" then return want == v end
  for i = 1, #want do
    if want[i] == v then return true end
  end
  return false
end

local function asList(v)
  if type(v) == "table" then return v end
  return { v }
end

local EVAL = {}

EVAL.minLevel = function(v, s)
  if s.level == nil then return nil end
  return s.level >= v
end

EVAL.maxLevel = function(v, s)
  if s.level == nil then return nil end
  return s.level <= v
end

-- (exit) level reached
EVAL.level = EVAL.minLevel

EVAL.races = function(v, s)
  if s.raceID == nil then return nil end
  return matches(v, s.raceID)
end

EVAL.classes = function(v, s)
  if s.classFile == nil then return nil end
  return matches(v, s.classFile)
end

EVAL.completed = function(v, s)
  local done = s.completed
  if not done then return nil end
  if type(v) ~= "table" then return done[v] == true end
  for i = 1, #v do
    if not done[v[i]] then return false end
  end
  return true
end

EVAL.notCompleted = function(v, s)
  local done = s.completed
  if not done then return nil end
  if type(v) ~= "table" then return not done[v] end
  for i = 1, #v do
    if done[v[i]] then return false end
  end
  return true
end

-- Every listed quest is in the log
EVAL.inLog = function(v, s)
  local log = s.log
  if not log then return nil end
  if type(v) ~= "table" then return log[v] ~= nil end
  for i = 1, #v do
    if log[v[i]] == nil then return false end
  end
  return true
end

-- { level = L, fraction = f }: past level L, or at L with xp/xpMax >= f
EVAL.xpFraction = function(v, s)
  if type(v) ~= "table" or v.level == nil then return nil end
  local level = s.level
  if level == nil then return nil end
  if level > v.level then return true end
  if level < v.level then return false end
  if s.xp == nil or s.xpMax == nil or s.xpMax <= 0 then return nil end
  return s.xp / s.xpMax >= (v.fraction or 0)
end

-- Current uiMapID equals the value (or one of a list)
EVAL.map = function(v, s)
  if s.map == nil then return nil end
  return matches(v, s.map)
end

-- { spellID, ... }: all known
EVAL.spellKnown = function(v, s)
  local known = s.knownSpells
  if not known then return nil end
  v = asList(v)
  for i = 1, #v do
    if not known[v[i]] then return false end
  end
  return true
end

-- { itemID, count }: at least count (default 1)
EVAL.item = function(v, s)
  local counts = s.itemCounts
  if not counts or type(v) ~= "table" or v[1] == nil then return nil end
  return (counts[v[1]] or 0) >= (v[2] or 1)
end

-- User setting flag, e.g. "deathSkips"; read from state.settings
EVAL.setting = function(v, s)
  local settings = s.settings
  if not settings then return nil end
  return settings[v] and true or false
end

C.KEYS = EVAL

function C.Eval(cond, state)
  if cond == nil then return true end
  if type(cond) ~= "table" then return nil end
  state = state or EMPTY
  local unknown = false
  for key, value in pairs(cond) do
    local fn = EVAL[key]
    local r
    if fn then r = fn(value, state) end
    if r == false then return false end
    if r == nil then unknown = true end
  end
  if unknown then return nil end
  return true
end

-- Keys the vocabulary does not know (for compile warnings); nil when all are known
function C.UnknownKeys(cond)
  if type(cond) ~= "table" then return nil end
  local bad
  for key in pairs(cond) do
    if not EVAL[key] then
      bad = bad or {}
      bad[#bad + 1] = tostring(key)
    end
  end
  if bad then table.sort(bad) end
  return bad
end
