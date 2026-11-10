-- Guide engine (P2 spec 4, 5, 6, 7.1, 7.2, 8a). Pure Lua 5.1 (no WoW API, no frames).
--
--   local view, events = ns.GuideEngine.Evaluate(route, state, memory)
--   ns.GuideEngine.Skip(memory, stepId);  ns.GuideEngine.Confirm(memory, stepId)
--   ns.GuideEngine.NewMemory();  ns.GuideEngine.Sanitize(memory)
--
-- Everything is derived from `state` on every call; `memory` holds only manual input
-- (skips, confirms), the last DONE set (to emit transitions only), activation times and
-- observed facts. No step index is authoritative.
--
-- Evaluation keeps per-step scratch data in module-level arrays reused between calls, so
-- the hot path allocates only the view entries it returns.
local _, ns = ...

local E = {}
ns.GuideEngine = E

local VERSION = 1
E.VERSION = VERSION
E.CONCURRENT_YARDS = 60
E.GOTO_YARDS = 20
E.MAX_CURRENT = 5
E.MAX_UPCOMING = 5

local type, pairs, tostring, floor, sqrt = type, pairs, tostring, math.floor, math.sqrt

local QUEST_TYPES = { ACCEPT = true, OBJECTIVE = true, COMPLETE = true, TURNIN = true, KILL = true, ABANDON = true }
local TRANSITIONAL = { GOTO = true, ZONE = true, FLY = true, TRANSPORT = true, HEARTH_USE = true }
E.TRANSITIONAL = TRANSITIONAL

-- Memory ----------------------------------------------------------------------------

function E.NewMemory()
  return {
    version = VERSION, segment = nil, autoSwitch = false,
    skips = {}, confirms = {}, done = {}, activeSince = {},
    facts = { knownNodes = {} }, lastIndex = nil,
    seeded = false, -- first evaluation seeds `done` silently (no STEP_DONE flood on joins)
  }
end

local function cleanSet(t, valueType)
  if type(t) ~= "table" then return {} end
  for k, v in pairs(t) do
    if type(k) ~= "string" or (valueType == "true" and v ~= true) or (valueType == "number" and type(v) ~= "number") then
      t[k] = nil
    end
  end
  return t
end

-- Repairs memory in place; old versions and corrupt fields are discarded, never trusted.
-- Returns the usable memory table (a new one when `memory` is not a table).
function E.Sanitize(m)
  if type(m) ~= "table" then return E.NewMemory() end
  if m.version ~= VERSION then
    for k in pairs(m) do m[k] = nil end
    local fresh = E.NewMemory()
    for k, v in pairs(fresh) do m[k] = v end
    return m
  end
  if type(m.segment) ~= "string" then m.segment = nil end
  m.autoSwitch = m.autoSwitch == true
  m.skips = cleanSet(m.skips, "true")
  m.confirms = cleanSet(m.confirms, "true")
  m.done = cleanSet(m.done, "true")
  m.activeSince = cleanSet(m.activeSince, "number")
  if type(m.facts) ~= "table" then m.facts = {} end
  if type(m.facts.knownNodes) ~= "table" then m.facts.knownNodes = {} end
  if type(m.lastIndex) ~= "number" then m.lastIndex = nil end
  m.seeded = m.seeded == true
  return m
end

function E.Skip(memory, stepId)
  if type(memory) == "table" and type(stepId) == "string" then
    if type(memory.skips) ~= "table" then memory.skips = {} end
    memory.skips[stepId] = true
  end
end

function E.Unskip(memory, stepId)
  if type(memory) == "table" and type(memory.skips) == "table" then memory.skips[stepId] = nil end
end

function E.Confirm(memory, stepId)
  if type(memory) == "table" and type(stepId) == "string" then
    if type(memory.confirms) ~= "table" then memory.confirms = {} end
    memory.confirms[stepId] = true
  end
end

-- Accepting a segment suggestion: the next Evaluate uses that segment
function E.ApplySuggestion(memory, suggestion)
  if type(memory) == "table" and type(suggestion) == "table" and suggestion.kind == "segment"
      and type(suggestion.to) == "string" then
    memory.segment = suggestion.to
  end
end

-- Data helpers ----------------------------------------------------------------------

local function schema() return ns.DataSchema end

local function questField(qid, key)
  local D, S = ns.Data, schema()
  local q = D and qid and D.GetQuest(qid)
  local i = q and S and S.Q[key]
  if i then return q[i] end
  return nil
end

local function questName(qid)
  local n = questField(qid, "NAME")
  if type(n) == "string" then return n end
  return qid and ("quest " .. tostring(qid)) or "quest"
end

local function entityRecord(kind, id)
  local D = ns.Data
  if not D then return nil end
  if kind == "npc" then return D.GetNPC(id) elseif kind == "object" then return D.GetObject(id) end
  return nil
end

local function entityFields(kind)
  local S = schema()
  if not S then return nil end
  if kind == "npc" then return S.NPC end
  return S.OBJ
end

-- Distance in yards between two points on the same uiMap with known bounds, else nil
local function yards(map, x1, y1, x2, y2)
  if not (map and x1 and y1 and x2 and y2) then return nil end
  local meta = ns.DataMeta
  local b = meta and meta.zoneBounds and meta.zoneBounds[map]
  if not b then return nil end
  local w, h = b.left - b.right, b.top - b.bottom
  if w < 0 then w = -w end
  if h < 0 then h = -h end
  local dx, dy = (x1 - x2) / 100 * w, (y1 - y2) / 100 * h
  return sqrt(dx * dx + dy * dy)
end
E.Yards = yards

-- Target resolution (7.1): nearest spawn on the player's map, else first spawn ---------

local best = {} -- scratch: kind, id, map, x, y, score, firstKind, firstId, firstMap, firstX, firstY
local pState

local function considerEntity(kind, id)
  if id == nil then return end
  local rec = entityRecord(kind, id)
  local F = rec and entityFields(kind)
  local spawns = F and rec[F.SPAWNS]
  if type(spawns) ~= "table" then return end
  local px, py, pmap = pState.x, pState.y, pState.map
  for i = 1, #spawns - 2, 3 do
    local m, x, y = spawns[i], spawns[i + 1], spawns[i + 2]
    if best.firstKind == nil then
      best.firstKind, best.firstId, best.firstMap, best.firstX, best.firstY = kind, id, m, x, y
    end
    if pmap ~= nil and m == pmap and px and py then
      local d = yards(m, px, py, x, y)
      if d == nil then local dx, dy = px - x, py - y; d = dx * dx + dy * dy end
      if best.score == nil or d < best.score then
        best.kind, best.id, best.map, best.x, best.y, best.score = kind, id, m, x, y, d
      end
    end
  end
end

local function considerList(kind, list)
  if type(list) ~= "table" then return end
  for i = 1, #list do considerEntity(kind, list[i]) end
end

local function considerItem(itemID)
  local D, S = ns.Data, schema()
  local it = D and D.GetItem(itemID)
  if not (it and S and S.ITEM) then return end
  considerList("npc", it[S.ITEM.NPC_DROPS])
  considerList("object", it[S.ITEM.OBJECT_DROPS])
  considerList("npc", it[S.ITEM.VENDORS])
end

local function considerObjective(o)
  local S = schema()
  if type(o) ~= "table" or not (S and S.OBJ_KIND) then return end
  local K = S.OBJ_KIND
  local kind = o[1]
  if kind == K.NPC then considerEntity("npc", o[2])
  elseif kind == K.OBJECT then considerEntity("object", o[2])
  elseif kind == K.ITEM then considerItem(o[2])
  elseif kind == K.KILLCREDIT then considerList("npc", o[2])
  end
end

local function resetBest(state)
  pState = state
  best.kind, best.id, best.map, best.x, best.y, best.score = nil, nil, nil, nil, nil, nil
  best.firstKind, best.firstId, best.firstMap, best.firstX, best.firstY = nil, nil, nil, nil, nil
end

local function finishTarget(state)
  local kind, id, map, x, y = best.kind, best.id, best.map, best.x, best.y
  if kind == nil then kind, id, map, x, y = best.firstKind, best.firstId, best.firstMap, best.firstX, best.firstY end
  if kind == nil then return { label = "U" } end
  local rec = entityRecord(kind, id)
  local F = entityFields(kind)
  local label = rec and F and rec[F.LABEL] or "E"
  if label == "U" then return { label = "U" } end
  local name = rec and F and rec[F.NAME]
  local d = state.map == map and yards(map, state.x, state.y, x, y) or nil
  return { map = map, x = x, y = y, label = label, name = type(name) == "string" and name or nil,
           distance = d and floor(d + 0.5) or nil }
end

-- Returns a target table, or nil for steps without a location
local function resolveTarget(step, state)
  local t = step.target
  if type(t) == "table" and t.map and t.x and t.y then
    local d = state.map == t.map and yards(t.map, state.x, state.y, t.x, t.y) or nil
    return { map = t.map, x = t.x, y = t.y, label = t.label or "E", name = t.name,
             distance = d and floor(d + 0.5) or nil }
  end
  local q = step.quest
  if not q or not QUEST_TYPES[step.type] or step.type == "ABANDON" then return nil end
  local S = schema()
  local rec = ns.Data and ns.Data.GetQuest(q)
  if not (rec and S) then return { label = "U" } end
  local Q = S.Q
  resetBest(state)
  local typ = step.type
  if typ == "ACCEPT" then
    local st = rec[Q.START]
    if type(st) == "table" then
      considerList("npc", st[1]); considerList("object", st[2])
      if best.firstKind == nil and type(st[3]) == "table" then
        for i = 1, #st[3] do considerItem(st[3][i]) end
      end
    end
  elseif typ == "TURNIN" then
    local fin = rec[Q.FINISH]
    if type(fin) == "table" then considerList("npc", fin[1]); considerList("object", fin[2]) end
  else
    local objs = rec[Q.OBJ]
    if type(objs) == "table" then
      if (typ == "OBJECTIVE" or typ == "KILL") and step.objective then
        considerObjective(objs[step.objective])
      else
        -- COMPLETE: nearest unfinished objective
        local entry = state.log and state.log[q]
        local lo = entry and entry.objectives
        for i = 1, #objs do
          local o = lo and lo[i]
          if not (o and o.finished) then considerObjective(objs[i]) end
        end
      end
    end
  end
  return finishTarget(state)
end
E.ResolveTarget = resolveTarget

-- Per-quest state (5.1) -----------------------------------------------------------------

local qState, qReason = {}, {}

local function logReady(entry)
  if entry.complete == true then return true end
  if entry.complete == false then return false end
  local objs = entry.objectives
  if type(objs) ~= "table" or #objs == 0 then return false end
  for i = 1, #objs do
    if not (objs[i] and objs[i].finished) then return false end
  end
  return true
end

-- DONE | READY | ACTIVE | AVAILABLE | LEVEL_TOO_LOW | UNAVAILABLE | UNKNOWN
local function questState(q, state)
  local s = qState[q]
  if s then return s, qReason[q] end
  local reason
  if state.completed and state.completed[q] then
    s = "DONE"
  elseif state.log and state.log[q] then
    s = logReady(state.log[q]) and "READY" or "ACTIVE"
  else
    s, reason = ns.Availability.Check(q, state)
    if s == "COMPLETED" then s = "DONE" end
  end
  qState[q], qReason[q] = s, reason
  return s, reason
end
E.QuestState = function(q, state)
  for k in pairs(qState) do qState[k] = nil; qReason[k] = nil end
  return questState(q, state)
end

local function isDependencyReason(reason)
  return reason ~= nil and (reason:sub(1, 7) == "prereq:" or reason:sub(1, 15) == "available_with:")
end

-- Step evaluation -------------------------------------------------------------------------

-- Scratch arrays indexed by route step index (reused between calls)
local ST, RS, MC, DEP, PASS = {}, {}, {}, {}, {}
-- ST status: DONE ACTIVE WAITING BLOCKED UNAVAILABLE SKIPPED UNKNOWN NA (not applicable),
--            plus "DEP" internally (dependency unmet; resolved to WAITING/BLOCKED)
-- RS reason string, MC manualConfirm flag, DEP backlog dependent index, PASS passed flag

local abandonDone = {} -- quest -> true when a planned ABANDON step is complete
local DEFERRED = {}    -- backlog step indices placed before their dependent
local SCHED = {}       -- quest -> true when it has a pending, schedulable step in the window

-- Status of a quest step that isn't done from the quest's not-in-log states
local function pendingFromQuest(qs, reason)
  if qs == "AVAILABLE" or qs == "LEVEL_TOO_LOW" then return "WAITING", (qs == "LEVEL_TOO_LOW" and "level" or "not_accepted") end
  if qs == "UNAVAILABLE" then
    if isDependencyReason(reason) then return "DEP", reason end
    return "UNAVAILABLE", reason
  end
  return "UNKNOWN", reason
end

local function anyAccepted(memory, route, q, from, to)
  local done = memory.done
  for i = from, to do
    local s = route.steps[i]
    if s.quest == q and (s.type == "ACCEPT" or s.type == "ABANDON") and done[s.id] then return true end
  end
  return false
end

local function grindGoal(step)
  local t = step.target
  local level, fraction
  if type(t) == "table" then level, fraction = t.level or t[1], t.fraction or t[2] end
  if type(step.xpFraction) == "table" then level, fraction = step.xpFraction.level, step.xpFraction.fraction end
  level = level or step.level
  return level, fraction
end

-- Returns status, reason, manualConfirm
local function evalStep(step, state, memory, route, first, last)
  local typ = step.type
  local id = step.id

  if memory.skips[id] then return "SKIPPED", "manual" end

  local C = ns.GuideConditions
  if step.when ~= nil then
    local ok = C.Eval(step.when, state)
    if ok == false then return "NA" end
    if ok == nil then return "UNKNOWN", "condition" end
  end

  local q = step.quest
  if typ == "ACCEPT" or typ == "TURNIN" or typ == "COMPLETE" or typ == "OBJECTIVE" or typ == "KILL" then
    if q == nil then return "UNKNOWN", "no_quest" end
    if typ == "KILL" and step.objective == nil then return "UNKNOWN", "kill_without_objective" end
    local qs, reason = questState(q, state)
    if typ == "ACCEPT" then
      if qs == "DONE" or qs == "ACTIVE" or qs == "READY" then return "DONE" end
      if abandonDone[q] then return "DONE", "abandoned" end
      if qs == "AVAILABLE" then return "ACTIVE" end
      if qs == "LEVEL_TOO_LOW" then return "WAITING", "level" end
      return pendingFromQuest(qs, reason)
    elseif typ == "TURNIN" then
      if qs == "DONE" then return "DONE" end
      if qs == "READY" then return "ACTIVE" end
      if qs == "ACTIVE" then return "WAITING", "objectives" end
      if abandonDone[q] then return "SKIPPED", "abandoned" end
      return pendingFromQuest(qs, reason)
    elseif typ == "COMPLETE" then
      if qs == "DONE" or qs == "READY" then return "DONE" end
      if qs == "ACTIVE" then return "ACTIVE" end
      if abandonDone[q] then return "SKIPPED", "abandoned" end
      return pendingFromQuest(qs, reason)
    else -- OBJECTIVE / KILL
      if qs == "DONE" or qs == "READY" then return "DONE" end
      if qs == "ACTIVE" then
        local entry = state.log[q]
        local objs = entry and entry.objectives
        if step.objective == nil then return "ACTIVE" end
        if type(objs) ~= "table" or objs[step.objective] == nil then
          if memory.confirms[id] then return "DONE", "confirmed" end
          return "ACTIVE", "no_objective_state", true
        end
        if objs[step.objective].finished then return "DONE" end
        return "ACTIVE"
      end
      if abandonDone[q] then return "SKIPPED", "abandoned" end
      return pendingFromQuest(qs, reason)
    end
  end

  if typ == "ABANDON" then
    if q == nil then return "UNKNOWN", "no_quest" end
    if state.completed and state.completed[q] then return "UNAVAILABLE", "turned_in" end
    if state.log and state.log[q] then return "ACTIVE" end
    if abandonDone[q] then return "DONE" end
    return "WAITING", "not_accepted"
  end

  -- Non-quest steps: a confirmation completes any step that needs manual confirmation
  local confirmed = memory.confirms[id]

  if typ == "NOTE" then
    if confirmed then return "DONE", "confirmed" end
    return "ACTIVE", nil, true
  end

  if typ == "GRIND" then
    local level, fraction = grindGoal(step)
    if level == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "no_goal", true
    end
    if state.level == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:level", true
    end
    if state.level > level then return "DONE" end
    if state.level < level then return "ACTIVE" end
    if not fraction or fraction <= 0 then return "DONE" end
    if not (state.xp and state.xpMax and state.xpMax > 0) then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:xp", true
    end
    if state.xp / state.xpMax >= fraction then return "DONE" end
    return "ACTIVE"
  end

  local t = step.target
  local tmap = (type(t) == "table" and t.map) or step.map

  if typ == "GOTO" then
    if state.map == nil or type(t) ~= "table" or not (t.map and t.x and t.y) then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:position", true
    end
    if state.map == t.map and state.x and state.y then
      local d = yards(t.map, state.x, state.y, t.x, t.y)
      local radius = step.radius or E.GOTO_YARDS
      if d ~= nil then
        if d <= radius then return "DONE" end
      elseif (state.x - t.x) ^ 2 + (state.y - t.y) ^ 2 <= 1 then
        return "DONE"
      end
    end
    return "ACTIVE"
  end

  if typ == "ZONE" or typ == "TRANSPORT" then
    if state.map == nil or tmap == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:map", true
    end
    if state.map == tmap then return "DONE" end
    return "ACTIVE"
  end

  if typ == "FLY" then
    if state.onTaxi == nil or state.map == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:taxi", true
    end
    local facts = memory.facts
    if state.onTaxi then
      facts.taxi = type(facts.taxi) == "table" and facts.taxi or {}
      facts.taxi[id] = true
      return "ACTIVE", "in_flight"
    end
    if type(facts.taxi) == "table" and facts.taxi[id] and (tmap == nil or state.map == tmap) then return "DONE" end
    return "ACTIVE"
  end

  if typ == "HEARTH_USE" then
    if memory.activeSince[id] and state.map ~= nil and tmap ~= nil and state.map == tmap then
      if not (type(t) == "table" and t.x and t.y) then return "DONE" end
      local d = yards(tmap, state.x, state.y, t.x, t.y)
      if d ~= nil and d <= (step.radius or 100) then return "DONE" end
    end
    if tmap == nil or state.map == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:position", true
    end
    return "ACTIVE"
  end

  if typ == "HEARTH_SET" then
    local want = step.bind or (type(t) == "table" and t.bind)
    if state.bindLocation == nil or want == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:bind", true
    end
    if state.bindLocation == want then return "DONE" end
    return "ACTIVE"
  end

  if typ == "FP_LEARN" then
    local node = step.node
    local known = memory.facts.knownNodes
    if node ~= nil and (known[node] or (type(state.knownNodes) == "table" and state.knownNodes[node])) then
      return "DONE"
    end
    if confirmed then return "DONE", "confirmed" end
    return "ACTIVE", "needs_state:taxi_nodes", true
  end

  if typ == "TRAIN" then
    local spells = step.spells
    if type(spells) ~= "table" or #spells == 0 or type(state.knownSpells) ~= "table" then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:spell", true
    end
    for i = 1, #spells do
      if not state.knownSpells[spells[i]] then return "ACTIVE" end
    end
    return "DONE"
  end

  if typ == "BUY" then
    local item = step.item
    if type(item) ~= "table" or item[1] == nil or type(state.itemCounts) ~= "table" then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:item", true
    end
    if (state.itemCounts[item[1]] or 0) >= (item[2] or 1) then return "DONE" end
    return "ACTIVE"
  end

  if typ == "DEATHSKIP" then
    if not (type(state.settings) == "table" and state.settings.deathSkips) then return "NA", "setting" end
    if state.isDead == nil and state.isGhost == nil then
      if confirmed then return "DONE", "confirmed" end
      return "ACTIVE", "needs_state:death", true
    end
    local facts = memory.facts
    if state.isDead or state.isGhost then
      facts.died = type(facts.died) == "table" and facts.died or {}
      facts.died[id] = true
      return "ACTIVE", "dead"
    end
    if type(facts.died) == "table" and facts.died[id] then
      if tmap == nil or state.map == tmap then return "DONE" end
    end
    return "ACTIVE"
  end

  return "UNKNOWN", "unknown_type"
end

-- Does quest `later` depend on quest `q` (M3 PRE_ALL / PRE_ANY / AVAILABLE_WITH / PARENT)?
local function dependsOn(later, q)
  if later == q then return true end
  local D, S = ns.Data, schema()
  local rec = D and D.GetQuest(later)
  if not (rec and S) then return false end
  local Q = S.Q
  local lists = Q.PRE_ALL and rec[Q.PRE_ALL]
  if type(lists) == "table" then
    for i = 1, #lists do if lists[i] == q or lists[i] == -q then return true end end
  end
  lists = Q.PRE_ANY and rec[Q.PRE_ANY]
  if type(lists) == "table" then
    for i = 1, #lists do if lists[i] == q then return true end end
  end
  local w = Q.AVAILABLE_WITH and rec[Q.AVAILABLE_WITH]
  if w == q then return true end
  local p = Q.PARENT and rec[Q.PARENT]
  if p == q then return true end
  return false
end

-- View building ------------------------------------------------------------------------------

local OBJ_VERB = { [1] = "Kill", [2] = "Use", [3] = "Collect", [5] = "Kill" }

local function objectiveTitle(step)
  local objs = questField(step.quest, "OBJ")
  local o = type(objs) == "table" and step.objective and objs[step.objective]
  if type(o) == "table" then
    local S = schema()
    local K = S.OBJ_KIND
    local name
    if o[1] == K.NPC then
      local r = ns.Data.GetNPC(o[2]); name = r and r[S.NPC.NAME]
    elseif o[1] == K.OBJECT then
      local r = ns.Data.GetObject(o[2]); name = r and r[S.OBJ.NAME]
    elseif o[1] == K.ITEM then
      local r = ns.Data.GetItem(o[2]); name = r and r[S.ITEM.NAME]
    elseif o[1] == K.KILLCREDIT and type(o[2]) == "table" then
      local r = ns.Data.GetNPC(o[2][1]); name = r and r[S.NPC.NAME]
    end
    if type(name) == "string" then return (OBJ_VERB[o[1]] or "Complete") .. " " .. name end
  end
  return questName(step.quest) .. ": objective " .. tostring(step.objective or "")
end

local function stepTitle(step)
  if step.text then return step.text end
  local typ, q = step.type, step.quest
  if typ == "ACCEPT" then return "Accept " .. questName(q) end
  if typ == "TURNIN" then return "Turn in " .. questName(q) end
  if typ == "COMPLETE" then return "Complete " .. questName(q) end
  if typ == "ABANDON" then return "Abandon " .. questName(q) end
  if typ == "OBJECTIVE" or typ == "KILL" then return objectiveTitle(step) end
  local t = step.target
  local place = type(t) == "table" and t.name
  if typ == "GRIND" then
    local level, fraction = grindGoal(step)
    if level and fraction and fraction > 0 then
      return string.format("Grind to level %d (%d%%)", level, floor(fraction * 100 + 0.5))
    end
    return "Grind to level " .. tostring(level or "?")
  end
  if typ == "GOTO" then return "Go to " .. (place or "the marked location") end
  if typ == "ZONE" then return "Travel to " .. (place or "the next zone") end
  if typ == "FLY" then return "Fly to " .. (place or "your destination") end
  if typ == "TRANSPORT" then return "Take the transport to " .. (place or "your destination") end
  if typ == "HEARTH_SET" then return "Set your hearthstone" .. (step.bind and (" in " .. step.bind) or "") end
  if typ == "HEARTH_USE" then return "Use your hearthstone" end
  if typ == "FP_LEARN" then return "Learn the flight path" .. (place and (" at " .. place) or "") end
  if typ == "TRAIN" then return "Train new spells" end
  if typ == "BUY" then return "Buy supplies" end
  if typ == "DEATHSKIP" then return "Death skip" end
  return typ or "Step"
end

local function stepProgress(step, state, status)
  local q = step.quest
  local entry = q and state.log and state.log[q]
  local objs = entry and entry.objectives
  if (step.type == "OBJECTIVE" or step.type == "KILL") and type(objs) == "table" and step.objective then
    local o = objs[step.objective]
    if o and o.required then return { cur = o.fulfilled or 0, max = o.required } end
  elseif step.type == "COMPLETE" and type(objs) == "table" and #objs > 0 then
    local n = 0
    for i = 1, #objs do if objs[i] and objs[i].finished then n = n + 1 end end
    return { cur = n, max = #objs }
  elseif step.type == "BUY" and type(step.item) == "table" and type(state.itemCounts) == "table" then
    return { cur = state.itemCounts[step.item[1]] or 0, max = step.item[2] or 1 }
  end
  return nil
end

local WHY_MANUAL = "Can't be detected automatically here; confirm when done"

local function stepView(route, i, state, memory, extraWhy)
  local step = route.steps[i]
  local status, reason, manual = ST[i], RS[i], MC[i] == true
  local q = step.quest
  local target = resolveTarget(step, state)
  local badges = {}
  if step.optional or step.type == "DEATHSKIP" then badges[#badges + 1] = "optional" end
  if type(step.tags) == "table" then
    for k = 1, #step.tags do badges[#badges + 1] = step.tags[k] end
  end
  if target and target.label == "E" then badges[#badges + 1] = "approx-location" end

  local why = step.note or extraWhy
  if not why then
    if manual then
      why = WHY_MANUAL
    elseif q and (status == "WAITING" or status == "BLOCKED" or status == "UNAVAILABLE" or status == "UNKNOWN")
        and (reason == nil or reason:find(":") or reason == "race" or reason == "class" or reason == "level") then
      local s = ns.Availability.Check(q, state)
      if s ~= "AVAILABLE" and s ~= "ACTIVE" and s ~= "COMPLETED" then why = ns.Availability.Explain(q, state) end
    end
  end

  local detail
  if target and target.name then detail = target.name end
  if q and step.type ~= "ACCEPT" and step.type ~= "TURNIN" and step.type ~= "COMPLETE" then
    detail = detail and (questName(q) .. "  ·  " .. detail) or questName(q)
  end

  local entry = q and state.log and state.log[q]
  return {
    id = step.id, type = step.type, status = status, reason = reason,
    segment = step.segment, index = i,
    title = stepTitle(step), detail = detail,
    quest = q and { id = q, name = questName(q), objectives = entry and entry.objectives or nil } or nil,
    target = target,
    progress = stepProgress(step, state, status),
    badges = badges, why = why, manualConfirm = manual,
    est = step.est,
  }
end

-- Evaluate ------------------------------------------------------------------------------------

local function segmentIndex(route, segId)
  for i = 1, #route.order do
    if route.order[i] == segId then return i end
  end
  return nil
end

local function emptyView(warnings, suggestions)
  return { route = nil, current = {}, upcoming = {}, backlog = {}, suggestions = suggestions or {},
           warnings = warnings or {} }
end

function E.Evaluate(route, state, memory)
  memory = E.Sanitize(memory)
  state = state or {}
  local events = {}
  if type(route) ~= "table" or type(route.steps) ~= "table" or type(route.order) ~= "table" then
    return emptyView({ "No route loaded" }), events, memory
  end
  local C = ns.GuideConditions

  -- Segment choice (6.3), then advance past segments whose exit already holds
  local segId, suggestion = ns.GuideSelector.Choose(route, state, memory)
  local suggestions = {}
  if suggestion then suggestions[1] = suggestion end
  if segId == nil then
    memory.segment = nil
    return emptyView({ "No route segment fits this character yet" }, suggestions), events, memory
  end
  for _ = 1, #route.order do
    local seg = route.segments[segId]
    if not (seg and seg.def.exit ~= nil and C.Eval(seg.def.exit, state) == true) then break end
    local nextId
    if type(seg.def.next) == "table" then
      for k = 1, #seg.def.next do
        if route.segments[seg.def.next[k]] then nextId = seg.def.next[k]; break end
      end
    end
    if not nextId then
      local oi = segmentIndex(route, segId)
      nextId = oi and route.order[oi + 1]
    end
    if not nextId or C.Eval(route.segments[nextId].def.entry, state) == false then break end
    segId = nextId
  end
  memory.segment = segId

  local seg = route.segments[segId]
  local oi = segmentIndex(route, segId)
  local nextSeg = oi and route.order[oi + 1] and route.segments[route.order[oi + 1]]
  local first, segLast = seg.first, seg.last
  local last = nextSeg and nextSeg.last or segLast
  local steps = route.steps

  -- Reset scratch state
  for k in pairs(qState) do qState[k] = nil; qReason[k] = nil end
  for k in pairs(abandonDone) do abandonDone[k] = nil end
  for i = first, last do ST[i], RS[i], MC[i], DEP[i], PASS[i] = nil, nil, nil, nil, nil end

  -- Planned abandons (6.5): ABANDON done = accepted earlier, now neither in log nor completed
  for i = first, last do
    local s = steps[i]
    if s.type == "ABANDON" and s.quest and not memory.skips[s.id] then
      local q = s.quest
      if not (state.log and state.log[q]) and not (state.completed and state.completed[q])
          and anyAccepted(memory, route, q, first, last) then
        abandonDone[q] = true
      end
    end
  end

  -- Pass 1: raw statuses
  for i = first, last do
    local st, rs, mc = evalStep(steps[i], state, memory, route, first, last)
    ST[i], RS[i], MC[i] = st, rs, mc
  end

  -- Pass 2: pointer (6.4). The furthest DONE step in the active segment that has at least as
  -- many done as pending non-transitional steps before it, so one out-of-order completion far
  -- ahead does not drag the pointer.
  local pointer
  do
    local doneN, pendN = 0, 0
    for i = first, segLast do
      local st = ST[i]
      if not TRANSITIONAL[steps[i].type] then
        if st == "DONE" then
          if doneN >= pendN then pointer = i end
          doneN = doneN + 1
        elseif st == "SKIPPED" then
          doneN = doneN + 1
        elseif st == "ACTIVE" or st == "WAITING" or st == "DEP" or st == "BLOCKED" then
          pendN = pendN + 1
        end
      end
    end
  end

  -- Pass 3: passed steps (before the pointer, not done)
  local backlogN = 0
  local deferred = DEFERRED
  for k = #deferred, 1, -1 do deferred[k] = nil end
  if pointer then
    for i = first, pointer - 1 do
      local st, step = ST[i], steps[i]
      if st == "ACTIVE" or st == "WAITING" or st == "DEP" or st == "BLOCKED" then
        local q = step.quest
        local inLog = q and state.log and state.log[q]
        if TRANSITIONAL[step.type] then
          ST[i], RS[i], MC[i] = "DONE", "implied", nil
        elseif inLog and step.type ~= "ABANDON" then
          -- quest is open in the log: its steps stay where they are (shown as open objectives)
        elseif step.optional or step.type == "DEATHSKIP" then
          ST[i], RS[i] = "SKIPPED", "passed"
        elseif step.recover == "skip" or not q then
          ST[i], RS[i] = "SKIPPED", "passed"
        else
          local dep
          for j = pointer + 1, last do
            local lq = steps[j].quest
            if lq and ST[j] ~= "NA" and ST[j] ~= "SKIPPED" and ST[j] ~= "DONE" and dependsOn(lq, q) then
              dep = j
              break
            end
          end
          if dep then
            PASS[i] = true
            backlogN = backlogN + 1
            if step.recover ~= "return" then
              DEP[i] = dep
              deferred[#deferred + 1] = i
            end
          else
            ST[i], RS[i] = "SKIPPED", "passed"
          end
        end
      end
    end
  end

  -- Transitional steps (and DEATHSKIP) are implied done when the next applicable step after
  -- them is done (a later pending step resets this)
  do
    local laterDone = false
    for i = last, first, -1 do
      local st, typ = ST[i], steps[i].type
      if st == "DONE" then
        laterDone = true
      elseif (TRANSITIONAL[typ] or typ == "DEATHSKIP") and (st == "ACTIVE" or st == "WAITING") then
        if laterDone then ST[i], RS[i], MC[i] = "DONE", "implied", nil end
      elseif st == "ACTIVE" or st == "WAITING" or st == "DEP" or st == "BLOCKED" or st == "UNKNOWN" then
        laterDone = false
      end
    end
  end

  -- Pass 4: dependency-unmet quest steps -> WAITING when a prerequisite is scheduled in the
  -- window (pending), else BLOCKED
  -- Scheduled = the prerequisite is open in the log and has a pending step, or its ACCEPT
  -- step is still pending in the window (a skipped accept doesn't count). One pass.
  local anyDep = false
  for k in pairs(SCHED) do SCHED[k] = nil end
  for j = first, last do
    local sj = ST[j]
    if sj == "DEP" then anyDep = true end
    local pq = steps[j].quest
    if pq and sj ~= "NA" and sj ~= "SKIPPED" and sj ~= "UNAVAILABLE" and sj ~= "DONE"
        and (steps[j].type == "ACCEPT" or (state.log and state.log[pq] ~= nil)) then
      SCHED[pq] = true
    end
  end
  if anyDep then
    for i = first, last do
      if ST[i] == "DEP" then
        local scheduled = false
        local ids = RS[i]:match(":(.*)$")
        if ids then
          for idStr in ids:gmatch("[^,]+") do
            local pq = tonumber(idStr)
            if pq and SCHED[pq] then scheduled = true; break end
          end
        end
        ST[i] = scheduled and "WAITING" or "BLOCKED"
      end
    end
  end

  -- Current / concurrent / upcoming (6.1), in effective order: deferred backlog steps are
  -- placed immediately before their first dependent step
  local view = {
    route = nil, current = {}, upcoming = {}, backlog = {}, suggestions = suggestions, warnings = {},
  }
  local currentIdx
  local fallbackIdx -- first pending non-ACTIVE step, shown when nothing is actionable
  local order = {} -- effective order of pending candidates (small)
  local function consider(i)
    local st = ST[i]
    if st == "ACTIVE" or st == "WAITING" or st == "BLOCKED" or st == "UNKNOWN" then
      order[#order + 1] = i
      if st == "ACTIVE" and not currentIdx then currentIdx = i end
      if st ~= "ACTIVE" and not fallbackIdx then fallbackIdx = i end
    end
  end
  local nDeferred = #deferred
  for i = first, last do
    for k = 1, nDeferred do
      if DEP[deferred[k]] == i then consider(deferred[k]) end
    end
    if not DEP[i] then consider(i) end
    if currentIdx and #order >= E.MAX_CURRENT + E.MAX_UPCOMING + 20 then break end
  end
  local primary = currentIdx or fallbackIdx
  memory.lastIndex = primary

  if primary then
    local pv = stepView(route, primary, state, memory)
    view.current[1] = pv
    local inCurrent = { [primary] = true }
    if currentIdx then
      local pt = pv.target
      local focusOnMap = pt and pt.map ~= nil and pt.map == state.map
      for k = 1, #order do
        if #view.current >= E.MAX_CURRENT then break end
        local i = order[k]
        if i ~= primary and ST[i] == "ACTIVE" then
          local step = steps[i]
          local q = step.quest
          local open = q and (step.type == "OBJECTIVE" or step.type == "KILL" or step.type == "COMPLETE")
            and state.log and state.log[q] ~= nil
          local near = false
          if not open then
            local t = resolveTarget(step, state)
            if pt and t and pt.map and t.map == pt.map and pt.x and t.x then
              local d = yards(pt.map, pt.x, pt.y, t.x, t.y)
              near = d ~= nil and d <= E.CONCURRENT_YARDS
            end
            -- Zone focus (6.6): current has no usable location, a later step in the same
            -- segment has one on the player's map
            if not near and not focusOnMap and (not pt or pt.label == "U" or not pt.x)
                and t and t.map ~= nil and t.map == state.map and step.segment == segId then
              near = true
              focusOnMap = true
            end
          end
          if open or near then
            view.current[#view.current + 1] = stepView(route, i, state, memory)
            inCurrent[i] = true
          end
        end
      end
    end
    local startK = #order + 1
    for k = 1, #order do
      if order[k] == primary then startK = k + 1; break end
    end
    for k = startK, #order do
      if #view.upcoming >= E.MAX_UPCOMING then break end
      local i = order[k]
      if not inCurrent[i] then view.upcoming[#view.upcoming + 1] = stepView(route, i, state, memory) end
    end
  end

  -- Backlog entries (required returns)
  for i = first, (pointer or first) - 1 do
    if PASS[i] then
      local depIdx = DEP[i]
      local dq
      if not depIdx then
        for j = (pointer or first) + 1, last do
          if steps[j].quest and dependsOn(steps[j].quest, steps[i].quest) then depIdx = j; break end
        end
      end
      dq = depIdx and steps[depIdx].quest
      local why = dq and ("Needed for " .. questName(dq) .. " later") or "Needed later in the route"
      view.backlog[#view.backlog + 1] = {
        step = stepView(route, i, state, memory, why), reason = why,
        dependent = depIdx and steps[depIdx].id or nil,
      }
    end
  end

  -- Death-skip suggestion when one is the current step and an estimate exists
  local cur = primary and steps[primary]
  if cur and cur.type == "DEATHSKIP" and ST[primary] == "ACTIVE" then
    local saves = type(cur.est) == "table" and cur.est.saves or nil
    if saves then suggestions[#suggestions + 1] = { kind = "deathskip", saves = saves, step = cur.id } end
  end

  -- Route / progress / warnings
  local def = seg.def
  local doneN, totalN, unknownN = 0, 0, 0
  local S = schema()
  local labelIdx = S and S.Q.LABELS
  local seenQ, startU, finishU = {}, 0, 0
  for i = first, segLast do
    local st = ST[i]
    if st ~= "NA" then
      totalN = totalN + 1
      if st == "DONE" or st == "SKIPPED" then doneN = doneN + 1 end
      if st == "UNKNOWN" then unknownN = unknownN + 1 end
    end
    local q = steps[i].quest
    if q and not seenQ[q] and st ~= "NA" then
      seenQ[q] = true
      local rec = labelIdx and ns.Data.GetQuest(q)
      local labels = rec and rec[labelIdx]
      if type(labels) == "string" then
        if labels:sub(2, 2) == "U" then startU = startU + 1 end
        if labels:sub(3, 3) == "U" then finishU = finishU + 1 end
      end
    end
  end
  local w = view.warnings
  if finishU > 0 then
    w[#w + 1] = finishU .. (finishU == 1 and " quest in this segment has an unknown turn-in location"
                                          or " quests in this segment have unknown turn-in locations")
  end
  if startU > 0 then
    w[#w + 1] = startU .. (startU == 1 and " quest in this segment has an unknown start location"
                                        or " quests in this segment have unknown start locations")
  end
  if unknownN > 0 then
    w[#w + 1] = unknownN .. (unknownN == 1 and " step can't be evaluated (missing data)"
                                            or " steps can't be evaluated (missing data)")
  end

  view.route = {
    id = route.id or route.order[1], title = route.title or def.title or def.id,
    segment = { id = segId, title = def.title or def.id, levels = def.levels },
    progress = { done = doneN, total = totalN },
  }

  -- Transitions: STEP_DONE events, activation times, last DONE set (window only)
  local done, since = memory.done, memory.activeSince
  local t = state.time
  local emit = memory.seeded
  memory.seeded = true
  for i = first, last do
    local id, st = steps[i].id, ST[i]
    if st == "DONE" then
      if not done[id] then
        done[id] = true
        local started = since[id]
        if emit then events[#events + 1] = {
          kind = "STEP_DONE", stepId = id, segment = steps[i].segment, t = t,
          level = state.level, xp = state.xp, map = state.map, x = state.x, y = state.y,
          seconds = (started and t) and (t - started) or nil,
        } end
      end
      since[id] = nil
    else
      done[id] = nil
      if st == "ACTIVE" then
        if since[id] == nil and t ~= nil then since[id] = t end
      else
        since[id] = nil
      end
    end
  end

  return view, events, memory
end
