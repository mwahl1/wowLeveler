-- Quest availability: can this character pick up this quest right now?
-- Pure Lua 5.1 (no WoW API), so it runs offline in tests.
--
-- Mirrors Questie's QuestieDB.IsDoable ordering and semantics (P2 spec 6.7 / 8a):
--   local status, reason = ns.Availability.Check(questID, state)
--   status: "COMPLETED" | "ACTIVE" | "AVAILABLE" | "LEVEL_TOO_LOW" | "UNAVAILABLE" | "UNKNOWN"
--
-- Unresolvable conditions (negative ID in PRE_ANY, prerequisite missing from the database,
-- requirement whose state the adapter did not supply) are never assumed satisfied. They are
-- remembered and the remaining checks continue: a later definite UNAVAILABLE wins (it is
-- certain), otherwise the first unresolved reason is returned as UNKNOWN before the level check.
--
-- Record fields are read by name through ns.DataSchema.Q. A name missing from the schema
-- (e.g. M3.1 fields before the data rebuild) means "field absent".
local _, ns = ...

local A = {}
ns.Availability = A

local EMPTY = {}
local floor, tostring, type = math.floor, tostring, type

local function field(q, Q, key)
  local i = Q[key]
  if i then return q[i] end
  return nil
end

-- v is a quest ID or a list of quest IDs; returns the first one that is completed (or active
-- when `log` is given), else nil.
local function firstHit(v, completed, log)
  if v == nil then return nil end
  if type(v) == "number" then
    if completed[v] or (log and log[v]) then return v end
    return nil
  end
  for i = 1, #v do
    local id = v[i]
    if completed[id] or (log and log[id]) then return id end
  end
  return nil
end

local function appendID(list, id)
  if list then return list .. "," .. tostring(id) end
  return tostring(id)
end

-- PRE_ANY (preQuestSingle): any one positive entry completed.
-- Returns nil when satisfied, else status, reason.
local function checkPreAny(pre, completed, GetQuest)
  local negative, missing, unmet
  for i = 1, #pre do
    local id = pre[i]
    if id > 0 then
      if completed[id] then return nil end
      if not missing and not GetQuest(id) then missing = id end
      unmet = appendID(unmet, id)
    elseif not negative then
      negative = id
    end
  end
  if negative then return "UNKNOWN", "negative_pre_any:" .. tostring(negative) end
  if missing then return "UNKNOWN", "missing_prereq:" .. tostring(missing) end
  return "UNAVAILABLE", "prereq:" .. (unmet or "")
end

-- PRE_ALL (preQuestGroup): every entry satisfied. Positive X: X completed or any quest in X's
-- own EXCLUSIVE list completed. Negative -X: X completed (no exclusive fallback).
local function checkPreAll(pre, completed, GetQuest, Q)
  local missing, unmet
  for i = 1, #pre do
    local id = pre[i]
    local qid = id < 0 and -id or id
    if not completed[qid] then
      local rec = GetQuest(qid)
      local ok = false
      if id > 0 and rec then
        ok = firstHit(field(rec, Q, "EXCLUSIVE"), completed) ~= nil
      end
      if not ok then
        if rec then unmet = appendID(unmet, qid)
        elseif not missing then missing = qid end
      end
    end
  end
  if unmet then return "UNAVAILABLE", "prereq:" .. unmet end
  if missing then return "UNKNOWN", "missing_prereq:" .. tostring(missing) end
  return nil
end

local function hasSkill(skills, skillID, rank)
  local have = skills[skillID]
  return have ~= nil and have >= (rank or 0)
end

function A.Check(questID, state)
  state = state or EMPTY
  local completed = state.completed or EMPTY
  local log = state.log or EMPTY

  if completed[questID] then return "COMPLETED" end
  if log[questID] then return "ACTIVE" end

  local D = ns.Data
  local S = ns.DataSchema
  local Q = S and S.Q
  local q = D and Q and D.GetQuest(questID)
  if not q then return "UNKNOWN", "no_data" end
  local GetQuest = D.GetQuest

  local unknownReason -- first unresolved condition; returned only if nothing definite fails
  local status, reason

  -- Race / class (missing state is UNKNOWN, never UNAVAILABLE)
  local races = field(q, Q, "RACES")
  if races and races ~= 0 then
    if state.raceID == nil then unknownReason = "needs_state:race"
    elseif not D.RaceAllowed(races, state.raceID) then return "UNAVAILABLE", "race" end
  end
  local classes = field(q, Q, "CLASSES")
  if classes and classes ~= 0 then
    if state.classFile == nil then unknownReason = unknownReason or "needs_state:class"
    elseif not D.ClassAllowed(classes, state.classFile) then return "UNAVAILABLE", "class" end
  end

  -- Prerequisites: group only when single is absent (Questie)
  local preAny = field(q, Q, "PRE_ANY")
  if preAny and #preAny > 0 then
    status, reason = checkPreAny(preAny, completed, GetQuest)
  else
    local preAll = field(q, Q, "PRE_ALL")
    if preAll and #preAll > 0 then status, reason = checkPreAll(preAll, completed, GetQuest, Q) end
  end
  if status == "UNAVAILABLE" then return status, reason end
  if status == "UNKNOWN" then unknownReason = reason end

  -- Chain / exclusivity
  local hit = firstHit(field(q, Q, "NEXT"), completed, log)
  if hit then return "UNAVAILABLE", "next_in_chain:" .. tostring(hit) end
  hit = firstHit(field(q, Q, "EXCLUSIVE"), completed, log)
  if hit then return "UNAVAILABLE", "exclusive:" .. tostring(hit) end

  -- Breadcrumbs
  if firstHit(field(q, Q, "BREADCRUMB_FOR"), completed, log) then return "UNAVAILABLE", "breadcrumb_target" end
  if firstHit(field(q, Q, "BREADCRUMBS"), EMPTY, log) then return "UNAVAILABLE", "active_breadcrumb" end

  -- Quest-state gates
  hit = firstHit(field(q, Q, "DISABLED_BY"), EMPTY, log)
  if hit then return "UNAVAILABLE", "disabled_by:" .. tostring(hit) end
  hit = firstHit(field(q, Q, "AVAILABLE_UNTIL"), completed)
  if hit then return "UNAVAILABLE", "available_until:" .. tostring(hit) end
  local with = field(q, Q, "AVAILABLE_WITH")
  if with and not firstHit(with, completed, log) then
    return "UNAVAILABLE", "available_with:" .. tostring(type(with) == "table" and with[1] or with)
  end

  -- Profession skill: SKILL = {skillID, rank}; REQ_RANKS = list of {skillID, rank}, any
  -- pair satisfied (OR). Negative rank values have unverified semantics -> UNKNOWN.
  local skill, ranks = field(q, Q, "SKILL"), field(q, Q, "REQ_RANKS")
  if ranks and #ranks == 0 then ranks = nil end
  if ranks then
    for i = 1, #ranks do
      local v = ranks[i][2]
      if v and v < 0 then
        unknownReason = unknownReason or "unverified:negative_ranks"
        ranks = nil
        break
      end
    end
  end
  if skill or ranks then
    local skills = state.skills
    if not skills then
      unknownReason = unknownReason or "needs_state:skill"
    else
      if skill and not hasSkill(skills, skill[1], skill[2]) then return "UNAVAILABLE", "skill" end
      if ranks then
        local any = false
        for i = 1, #ranks do
          local r = ranks[i]
          if hasSkill(skills, r[1], r[2]) then any = true; break end
        end
        if not any then return "UNAVAILABLE", "skill" end
      end
    end
  end

  -- Reputation: MIN_REP = {factionID, value} (rep >= value); MAX_REP (rep < value)
  local minRep, maxRep = field(q, Q, "MIN_REP"), field(q, Q, "MAX_REP")
  if minRep or maxRep then
    local reps = state.reputations
    if not reps then
      unknownReason = unknownReason or "needs_state:rep"
    else
      -- A faction absent from a supplied table is not doable (Questie)
      if minRep then
        local v = reps[minRep[1]]
        if v == nil or v < minRep[2] then return "UNAVAILABLE", "rep" end
      end
      if maxRep then
        local v = reps[maxRep[1]]
        if v == nil or v >= maxRep[2] then return "UNAVAILABLE", "rep" end
      end
    end
  end

  -- Spells: REQ_SPELL positive = must know, negative = must NOT know.
  local spell = field(q, Q, "REQ_SPELL")
  if spell and spell ~= 0 then
    local spells = state.knownSpells
    if not spells then
      unknownReason = unknownReason or "needs_state:spell"
    elseif spell > 0 then
      if not spells[spell] then return "UNAVAILABLE", "spell" end
    elseif spells[-spell] then
      return "UNAVAILABLE", "spell"
    end
  end

  -- Profession specialization (Questie QuestieProfessions.HasSpecialization)
  local spec = field(q, Q, "REQ_SPEC")
  if spec and spec ~= 0 then
    local specs = state.specializations
    if not specs then
      unknownReason = unknownReason or "needs_state:spec"
    elseif not specs[spec] then
      return "UNAVAILABLE", "spec"
    end
  end

  -- Level
  local level = state.level
  local maxLevel = field(q, Q, "MAX_LEVEL")
  if level and maxLevel and level > maxLevel then return "UNAVAILABLE", "max_level" end
  if unknownReason then return "UNKNOWN", unknownReason end
  if not level then return "UNKNOWN", "needs_state:level" end
  if level < (field(q, Q, "REQ_LEVEL") or 0) then return "LEVEL_TOO_LOW" end
  return "AVAILABLE"
end

-- Human-readable explanation --------------------------------------------------------

local function questName(id)
  id = tonumber(id)
  if not id then return "an unknown quest" end
  if id < 0 then id = -id end
  local D, S = ns.Data, ns.DataSchema
  local q = D and D.GetQuest(id)
  local name = q and S and S.Q and field(q, S.Q, "NAME")
  if type(name) == "string" then return name end
  return "quest " .. id
end

local function nameList(ids, joiner)
  local out
  for id in ids:gmatch("[^,]+") do
    local n = questName(id)
    out = out and (out .. joiner .. n) or n
  end
  return out or "an unknown quest"
end

local SIMPLE = {
  race = "Not available to your race",
  class = "Not available to your class",
  breadcrumb_target = "The quest this leads to is already completed or in progress",
  active_breadcrumb = "A lead-in quest for this is in your quest log",
  max_level = "You are above the maximum level for this quest",
  no_data = "No quest data available",
  skill = "Requires a profession skill you do not have",
  rep = "Your reputation does not meet the requirement (or the faction is not yet known to you)",
  spell = "Requires a spell requirement you do not meet",
  spec = "Requires a profession specialization you do not have",
  ["needs_state:race"] = "Depends on your race (not yet known)",
  ["needs_state:class"] = "Depends on your class (not yet known)",
  ["needs_state:spec"] = "Depends on your profession specialization (not yet known)",
  ["unverified:negative_ranks"] = "Profession rank requirement is not yet verified; availability unknown",
  ["needs_state:skill"] = "Depends on your profession skills (not yet known)",
  ["needs_state:rep"] = "Depends on your reputation (not yet known)",
  ["needs_state:spell"] = "Depends on your known spells (not yet known)",
  ["needs_state:level"] = "Depends on your level (not yet known)",
}

function A.Explain(questID, state)
  local status, reason = A.Check(questID, state)
  if status == "COMPLETED" then return "Already completed" end
  if status == "ACTIVE" then return "In your quest log" end
  if status == "AVAILABLE" then return "Available" end
  if status == "LEVEL_TOO_LOW" then
    local D, S = ns.Data, ns.DataSchema
    local q = D and D.GetQuest(questID)
    local req = q and S and field(q, S.Q, "REQ_LEVEL")
    return "Requires level " .. tostring(req or "?")
  end
  reason = reason or ""
  if SIMPLE[reason] then return SIMPLE[reason] end
  local kind, arg = reason:match("^([%w_]+):(.*)$")
  if kind == "prereq" then
    local D, S = ns.Data, ns.DataSchema
    local q = D and D.GetQuest(questID)
    local preAny = q and S and field(q, S.Q, "PRE_ANY")
    if preAny and #preAny > 0 and arg:find(",") then
      return "Requires one of " .. nameList(arg, ", ") .. " to be completed first"
    end
    return "Requires " .. nameList(arg, " and ") .. " to be completed first"
  elseif kind == "next_in_chain" then
    return "A later quest in this chain (" .. questName(arg) .. ") is already completed or in progress"
  elseif kind == "exclusive" then
    return "Not available because " .. questName(arg) .. " is completed or in progress"
  elseif kind == "disabled_by" then
    return "Not available while " .. questName(arg) .. " is in your quest log"
  elseif kind == "available_until" then
    return "No longer available after completing " .. questName(arg)
  elseif kind == "available_with" then
    return "Only available while " .. questName(arg) .. " is in progress or completed"
  elseif kind == "negative_pre_any" then
    return "Prerequisite data is ambiguous (" .. questName(arg) .. "); availability unknown"
  elseif kind == "missing_prereq" then
    return "Requires quest " .. tostring(arg) .. ", which is not in the quest database; availability unknown"
  end
  return "Availability unknown"
end
