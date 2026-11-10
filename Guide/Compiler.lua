-- Route registry and compiler (P2 spec 3.2-3.5, 8a). Pure Lua 5.1 (no WoW API).
--
--   ns.Guides.Register(def)                         -- route files and tests; stored by def.id
--   ns.Guides.Reset()                               -- tests only
--   local route, problems = ns.Guides.Compile(character)  -- { faction, raceID, classFile }
--
-- route    = { steps = {...}, segments = { [segId] = { def, first, last } }, order = {...}, byId = {...} }
-- problems = { { severity = "error"|"warning", code = "...", msg = "..." }, ... }
--
-- Registered defs are never mutated: compiled steps are shallow copies with .segment/.index.
local _, ns = ...

local G = {}
ns.Guides = G

local registry = {}      -- id -> def
local registryOrder = {} -- ids in registration order
local registerProblems = {}

G.STEP_TYPES = {
  ACCEPT = true, OBJECTIVE = true, COMPLETE = true, TURNIN = true, KILL = true, GRIND = true,
  GOTO = true, ZONE = true, HEARTH_SET = true, HEARTH_USE = true, FP_LEARN = true, FLY = true,
  TRANSPORT = true, TRAIN = true, BUY = true, DEATHSKIP = true, ABANDON = true, NOTE = true,
}
G.KINDS = { segment = true, start = true, overlay = true }

local function problem(list, severity, code, msg)
  list[#list + 1] = { severity = severity, code = code, msg = msg }
end

function G.Register(def)
  if type(def) ~= "table" then
    problem(registerProblems, "error", "bad_def", "Register called with " .. type(def))
    return
  end
  local id = def.id
  if type(id) ~= "string" or id == "" then
    problem(registerProblems, "error", "missing_id", "route definition without an id")
    return
  end
  if registry[id] then
    problem(registerProblems, "warning", "duplicate_def", "route " .. id .. " registered twice; last one wins")
  else
    registryOrder[#registryOrder + 1] = id
  end
  registry[id] = def
end

function G.Reset()
  registry, registryOrder, registerProblems = {}, {}, {}
end

function G.Get(id) return registry[id] end

-- Number of registered route definitions (0 = no route files: the guide stays inert)
function G.Count() return #registryOrder end

local function contains(list, v)
  if list == nil then return true end -- nil = no restriction
  if type(list) ~= "table" then return list == v end
  for i = 1, #list do
    if list[i] == v then return true end
  end
  return false
end

local function lowLevel(def)
  return type(def.levels) == "table" and def.levels[1] or math.huge
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function checkConditions(problems, where, cond)
  local C = ns.GuideConditions
  local bad = C and C.UnknownKeys(cond)
  if bad then
    problem(problems, "warning", "unknown_condition",
      where .. ": unknown condition key(s) " .. table.concat(bad, ", ") .. " (evaluates as unknown)")
  end
end

-- Validates and copies a def's step list. Invalid steps are reported as errors and dropped.
local function copySteps(problems, owner, steps)
  local out, seen = {}, {}
  if type(steps) ~= "table" then return out end
  for i = 1, #steps do
    local s = steps[i]
    local where = owner .. " step " .. i
    if type(s) ~= "table" then
      problem(problems, "error", "bad_step", where .. " is not a table")
    elseif type(s.id) ~= "string" or s.id == "" then
      problem(problems, "error", "missing_step_id", where .. " has no id")
    elseif s.type == nil then
      problem(problems, "error", "missing_step_type", where .. " (" .. s.id .. ") has no type")
    elseif not G.STEP_TYPES[s.type] then
      problem(problems, "error", "unknown_step_type", where .. " (" .. s.id .. ") has unknown type " .. tostring(s.type))
    elseif seen[s.id] then
      problem(problems, "error", "duplicate_step", owner .. ": duplicate step id " .. s.id)
    else
      seen[s.id] = true
      local c = copy(s)
      c.sourceId = s.id
      checkConditions(problems, owner .. " step " .. s.id .. " when", s.when)
      if s.quest ~= nil and not (ns.Data and ns.Data.GetQuest(s.quest)) then
        problem(problems, "warning", "unknown_quest",
          owner .. " step " .. s.id .. ": quest " .. tostring(s.quest) .. " is not in the quest data")
      end
      out[#out + 1] = c
    end
  end
  return out
end

function G.Compile(character)
  character = character or {}
  local problems = {}
  for i = 1, #registerProblems do problems[i] = registerProblems[i] end

  local faction, raceID, classFile = character.faction, character.raceID, character.classFile

  -- Select defs ----------------------------------------------------------------
  local starts, segments, overlays = {}, {}, {}
  for _, id in ipairs(registryOrder) do
    local def = registry[id]
    if def.faction == nil or def.faction == faction then
      if def.kind == "start" then
        if raceID ~= nil and contains(def.races, raceID) then starts[#starts + 1] = def end
      elseif def.kind == "segment" then
        segments[#segments + 1] = def
      elseif def.kind == "overlay" then
        if classFile ~= nil and contains(def.classes, classFile) then overlays[#overlays + 1] = def end
      else
        problem(problems, "error", "unknown_kind", "route " .. id .. " has unknown kind " .. tostring(def.kind))
      end
    end
  end

  local function byLevelThenId(a, b)
    local la, lb = lowLevel(a), lowLevel(b)
    if la ~= lb then return la < lb end
    return a.id < b.id
  end
  table.sort(starts, byLevelThenId)
  table.sort(segments, byLevelThenId)

  local orderDefs = {}
  if #starts == 0 then
    problem(problems, "warning", "no_start", "no start route for race " .. tostring(raceID) .. " (" .. tostring(faction) .. ")")
  else
    orderDefs[1] = starts[1]
    if #starts > 1 then
      problem(problems, "warning", "multiple_start",
        "several start routes match race " .. tostring(raceID) .. "; using " .. starts[1].id)
    end
  end
  for i = 1, #segments do orderDefs[#orderDefs + 1] = segments[i] end

  -- Per-segment step lists -----------------------------------------------------
  local lists, order = {}, {}
  for i = 1, #orderDefs do
    local def = orderDefs[i]
    order[i] = def.id
    checkConditions(problems, def.id .. " entry", def.entry)
    checkConditions(problems, def.id .. " exit", def.exit)
    lists[i] = copySteps(problems, def.id, def.steps)
  end

  -- Overlays (applied in id order) ----------------------------------------------
  table.sort(overlays, function(a, b) return a.id < b.id end)
  for _, ov in ipairs(overlays) do
    for n, ins in ipairs(type(ov.insert) == "table" and ov.insert or {}) do
      local owner = ov.id .. " insert " .. n
      local steps = copySteps(problems, owner, ins.steps)
      local placed = false
      if ins.after ~= nil then
        for li = 1, #lists do
          local list = lists[li]
          for si = 1, #list do
            if list[si].sourceId == ins.after or list[si].id == ins.after then
              for k = #steps, 1, -1 do table.insert(list, si + 1, steps[k]) end
              placed = true
              break
            end
          end
          if placed then break end
        end
        if not placed then
          problem(problems, "warning", "overlay_anchor", owner .. ": anchor step " .. tostring(ins.after) .. " not found")
        end
      elseif ins.atLevel ~= nil then
        local n = ins.atLevel
        for li = 1, #orderDefs do
          local lv = orderDefs[li].levels
          if type(lv) == "table" and lv[1] and lv[2] and lv[1] <= n and n <= lv[2] then
            for k = #steps, 1, -1 do
              local s = steps[k]
              local when = s.when and copy(s.when) or {}
              if when.minLevel == nil or when.minLevel < n then when.minLevel = n end
              s.when = when
              table.insert(lists[li], 1, s)
            end
            placed = true
            break
          end
        end
        if not placed then
          problem(problems, "warning", "overlay_anchor", owner .. ": no segment covers level " .. tostring(n))
        end
      else
        problem(problems, "warning", "overlay_anchor", owner .. ": insert has neither after nor atLevel")
      end
    end
  end

  -- Flatten ---------------------------------------------------------------------
  local route = { steps = {}, segments = {}, order = order, byId = {} }
  local steps, byId = route.steps, route.byId
  for li = 1, #orderDefs do
    local def = orderDefs[li]
    local first = #steps + 1
    for _, s in ipairs(lists[li]) do
      local id = s.id
      if byId[id] then
        -- Bare ids are namespaced by segment on collision; already-namespaced ids are errors
        local namespaced = def.id .. "/" .. id
        if not id:find("/", 1, true) and not byId[namespaced] then
          problem(problems, "warning", "step_namespaced",
            "step id " .. id .. " repeats in " .. def.id .. "; compiled as " .. namespaced)
          id = namespaced
        else
          problem(problems, "error", "duplicate_step", "duplicate step id " .. id .. " in compiled route")
          id = nil
        end
      end
      if id then
        s.id = id
        s.segment = def.id
        s.index = #steps + 1
        steps[s.index] = s
        byId[id] = s.index
      end
    end
    route.segments[def.id] = { def = def, first = first, last = #steps }
  end

  return route, problems
end
