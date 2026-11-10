-- Segment selector (P2 spec 6.3, 8a). Pure Lua 5.1 (no WoW API).
--
--   local segId, suggestion = ns.GuideSelector.Choose(route, state, memory)
--   memory.segment    = current segment id (may be nil)
--   memory.autoSwitch = true to switch instead of suggesting (user setting, default off)
--   suggestion        = nil | { kind = "segment", to = segId, reason = "..." }
local _, ns = ...

local Sel = {}
ns.GuideSelector = Sel

local TOLERANCE = 2 -- levels above a segment's range before it is left (spec 8.4)
Sel.TOLERANCE = TOLERANCE

local function entryHolds(def, state)
  return ns.GuideConditions.Eval(def.entry, state) == true
end

local function levels(def)
  local lv = def.levels
  if type(lv) == "table" and lv[1] and lv[2] then return lv[1], lv[2] end
  return nil
end

local function inRange(def, level)
  local lo, hi = levels(def)
  if not lo then return true end -- no declared range: no level restriction
  if level == nil then return false end
  return lo - 1 <= level and level <= hi + TOLERANCE
end

local function notOutleveled(def, level)
  local _, hi = levels(def)
  if not hi then return true end
  return level ~= nil and level <= hi + TOLERANCE
end

-- Sum of data XP (any label) of distinct quests in the segment that are AVAILABLE or ACTIVE
function Sel.Score(route, segId, state)
  local seg = route.segments[segId]
  if not seg then return 0 end
  local D, S, A = ns.Data, ns.DataSchema, ns.Availability
  local xpIndex = S and S.Q and S.Q.XP
  local seen, total = {}, 0
  for i = seg.first, seg.last do
    local q = route.steps[i].quest
    if q and not seen[q] then
      seen[q] = true
      local status = A.Check(q, state)
      if status == "AVAILABLE" or status == "ACTIVE" then
        local rec = D.GetQuest(q)
        local xp = rec and xpIndex and rec[xpIndex]
        if type(xp) == "number" then total = total + xp end
      end
    end
  end
  return total
end

local function best(route, state)
  local bestId, bestScore, bestLow
  for i = 1, #route.order do
    local id = route.order[i]
    local seg = route.segments[id]
    local def = seg and seg.def
    if def and entryHolds(def, state) and inRange(def, state.level) then
      local score = Sel.Score(route, id, state)
      local low = levels(def) or math.huge
      -- order index breaks remaining ties: earlier wins because only strictly better replaces
      if bestId == nil or score > bestScore or (score == bestScore and low < bestLow) then
        bestId, bestScore, bestLow = id, score, low
      end
    end
  end
  return bestId
end

-- Distance from level to a segment's levels range (0 inside; unrestricted segments count as 0)
local function distance(def, level)
  local lo, hi = levels(def)
  if not lo or level == nil then return 0 end
  if level < lo then return lo - level end
  if level > hi then return level - hi end
  return 0
end

-- No segment in level range: the entry-holding segment nearest the character's level,
-- ties -> higher score, then route order. Distance ranks first because raw quest XP ignores
-- low-level XP falloff (a level-20 character must not be sent to a level 1-6 start).
local function fallback(route, state)
  local bestId, bestScore, bestDist
  for i = 1, #route.order do
    local id = route.order[i]
    local seg = route.segments[id]
    local def = seg and seg.def
    if def and entryHolds(def, state) then
      local score = Sel.Score(route, id, state)
      local dist = distance(def, state.level)
      if bestId == nil or dist < bestDist or (dist == bestDist and score > bestScore) then
        bestId, bestScore, bestDist = id, score, dist
      end
    end
  end
  return bestId
end

local function noRange(id)
  return { kind = "segment", to = id, reason = "no_segment_in_range" }
end

function Sel.Choose(route, state, memory)
  state = state or {}
  memory = memory or {}
  if not route or not route.order or #route.order == 0 then return nil end

  -- The race's start segment wins while its exit doesn't hold and the level still fits
  local startId = route.order[1]
  local startSeg = route.segments[startId]
  if startSeg and startSeg.def.kind == "start" then
    local def = startSeg.def
    if def.exit ~= nil and ns.GuideConditions.Eval(def.exit, state) ~= true and notOutleveled(def, state.level) then
      return startId
    end
  end

  local currentId = memory.segment
  local current = currentId and route.segments[currentId]
  local currentUsable = current and entryHolds(current.def, state)

  if currentUsable and notOutleveled(current.def, state.level) then
    return currentId
  end

  local bestId = best(route, state)
  if bestId == nil then
    -- Nothing in level range
    if currentUsable then
      local fb = fallback(route, state)
      if fb == nil or fb == currentId then return currentId end
      return currentId, noRange(fb)
    end
    local fb = fallback(route, state)
    if fb == nil then return nil end
    return fb, noRange(fb)
  end
  if not current then return bestId end
  if not currentUsable then return bestId end -- entry no longer holds: switch

  -- Current is usable but out-levelled
  if bestId == currentId then return currentId end
  if memory.autoSwitch then return bestId end
  return currentId, { kind = "segment", to = bestId, reason = "level_above_range" }
end
