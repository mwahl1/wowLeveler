-- Guide adapter: the only guide module that touches the WoW API (through ns.Compat).
-- Builds CharacterState (spec 3.1), runs ns.GuideEngine, persists memory in
-- LevelingNavigatorCharDB.guide, sends GUIDE_UPDATED and records STEP_DONE events in
-- LevelingNavigatorCharDB.stepLog.
--
-- Inert without route files: if no guide is registered (ns.Guides.Count() == 0) nothing
-- is compiled, no events are registered, and GUIDE_UPDATED is never sent, so the P0
-- behaviour is unchanged.
local _, ns = ...
local C = ns.Compat

local GS = {
  active = false,
  route = nil,       -- compiled route
  problems = nil,    -- compile problems
  memory = nil,      -- = LevelingNavigatorCharDB.guide
  view = nil,        -- last GuideView
  lastError = nil,   -- last compile/evaluate error (shown by the probe)
  routeQuests = {},  -- [questID] = true
  wantSpells = {},   -- spell IDs routes ask about (TRAIN steps, spellKnown conditions)
  wantItems = {},    -- item IDs routes ask about (BUY steps, item conditions)
  evaluations = 0,
  lastMs = nil,
}
ns.GuideState = GS

local Guide = ns.Guide or {}
ns.Guide = Guide

local MAX_STEP_LOG = 400
local POLL_SECONDS = 0.5 -- 2 Hz, only while the current step has a location on the player's map

-- Clock: one source for the whole session (GetTime if it works at activation, else time())

local clock
local function now()
  if clock == nil then
    if C.GetTime() ~= nil then clock = "GetTime" else clock = "time" end
  end
  if clock == "GetTime" then return C.GetTime() end
  if type(time) == "function" then return time() end
  return nil
end

-- Completed quests ---------------------------------------------------------------------
-- Rebuilt from GetAllCompletedQuestIDs when dirty (login, turn-in, quest removed). Turn-ins
-- seen via QUEST_TURNED_IN stay in `pendingTurnIns` and are merged into every rebuild until
-- the server list contains them. Without that API: a lazy per-quest lookup whose unreadable
-- answers go into state.completedUnknown. Without either: nil (completion unknown).

local completedSet, completedUnknown
local completedDirty = true
local pendingTurnIns = {}

local function lazyCompleted()
  local unknown = {}
  local set = setmetatable({}, { __index = function(t, questID)
    if type(questID) ~= "number" then return nil end
    local done = C.IsQuestFlaggedCompleted(questID)
    if done == nil then
      unknown[questID] = true
      return nil
    end
    unknown[questID] = nil
    rawset(t, questID, done)
    return done or nil
  end })
  return set, unknown
end

local function getCompleted()
  if completedDirty or completedSet == nil then
    completedDirty = false
    completedUnknown = nil
    local ids = C.GetAllCompletedQuestIDs()
    if ids then
      local set = {}
      for i = 1, #ids do
        local id = ids[i]
        if type(id) == "number" and not C.IsSecret(id) then set[id] = true end
      end
      for id in pairs(pendingTurnIns) do
        if set[id] then pendingTurnIns[id] = nil else set[id] = true end
      end
      completedSet = set
    elseif C.HasQuestFlaggedCompleted() then
      completedSet, completedUnknown = lazyCompleted()
      for id in pairs(pendingTurnIns) do rawset(completedSet, id, true) end
    else
      completedSet = nil
    end
  end
  return completedSet, completedUnknown
end

-- CharacterState ------------------------------------------------------------------------

local function settings()
  local db = ns.db or {}
  return {
    deathSkips = db.deathSkips == true,
    autoSwitch = db.autoSwitchSegments == true,
  }
end

local function readable(v)
  if v == nil or C.IsSecret(v) then return nil end
  return v
end

function GS.BuildState()
  local ch = C.GetCharacter()
  local map, x, y = C.GetPlayerPosition()
  local dead, ghost = C.GetDeathState()
  local completed, unknown = getCompleted()
  local state = {
    time = now(),
    faction = C.GetFaction(),
    raceID = C.GetRaceID(),
    classFile = C.GetClassFile(),
    level = readable(ch.level),
    xp = readable(ch.xp),
    xpMax = readable(ch.xpMax),
    restedXP = readable(ch.rested),
    map = map, x = x, y = y,
    completed = completed,
    completedUnknown = unknown,
    log = C.GetQuestLogState(),
    bindLocation = C.GetBindLocation(),
    onTaxi = C.IsOnTaxi(),
    isDead = dead, isGhost = ghost,
    settings = settings(),
  }
  -- Only spells/items that routes ask about; nil when the lookup API is missing
  if next(GS.wantSpells) then
    local known, any = {}, false
    for spellID in pairs(GS.wantSpells) do
      local k = C.IsSpellKnown(spellID)
      if k ~= nil then any = true; if k then known[spellID] = true end end
    end
    state.knownSpells = any and known or nil
  end
  if next(GS.wantItems) then
    local counts, any = {}, false
    for itemID in pairs(GS.wantItems) do
      local n = C.GetItemCount(itemID)
      if n ~= nil then any = true; counts[itemID] = n end
    end
    state.itemCounts = any and counts or nil
  end
  -- skills, reputations, specializations: not read yet (unverified in Forever) -> UNKNOWN
  return state
end

-- Evaluation ----------------------------------------------------------------------------

local function record(ev)
  if not ns.char then return end
  if type(ns.char.stepLog) ~= "table" then ns.char.stepLog = {} end
  local log = ns.char.stepLog
  log[#log + 1] = {
    t = type(time) == "function" and time() or ev.t,
    e = "STEP_DONE",
    a = table.concat({ tostring(ev.stepId), tostring(ev.segment), tostring(ev.seconds or "") }, ","),
    m = ev.map,
    x = ev.x and math.floor(ev.x * 10 + 0.5) / 10,
    y = ev.y and math.floor(ev.y * 10 + 0.5) / 10,
    lv = ev.level,
    xp = ev.xp,
  }
  while #log > MAX_STEP_LOG do table.remove(log, 1) end
end

local ticker
local lastPos = {}

-- Poll only while the current step's target has coordinates on the player's current map
local function wantsPolling(view)
  local cur = view and view.current and view.current[1]
  local t = cur and cur.target
  return t ~= nil and t.x ~= nil and t.y ~= nil and t.map ~= nil and t.map == lastPos.map
end

local function stopPolling()
  if ticker then
    C.Call(ticker.Cancel, ticker)
    ticker = nil
  end
end

local function updatePolling()
  local want = GS.active and wantsPolling(GS.view)
  if want and not ticker and C_Timer and C_Timer.NewTicker then
    ticker = C.Call(C_Timer.NewTicker, POLL_SECONDS, function()
      local map, x, y = C.GetPlayerPosition()
      if map ~= lastPos.map or x == nil or lastPos.x == nil
          or math.abs(x - lastPos.x) + math.abs(y - lastPos.y) > 0.05 then
        GS.Evaluate()
      end
    end)
  elseif not want then
    stopPolling()
  end
end

local function fail(err)
  GS.lastError = tostring(err)
  stopPolling()
  if geterrorhandler then geterrorhandler()(err) end
end

function GS.Evaluate()
  if not (GS.active and GS.route) then return end
  local started = debugprofilestop and C.Call(debugprofilestop)
  local okState, state = pcall(GS.BuildState)
  if not okState then return fail(state) end
  lastPos.map, lastPos.x, lastPos.y = state.map, state.x, state.y
  GS.memory.autoSwitch = state.settings.autoSwitch
  local ok, view, events, memory = pcall(ns.GuideEngine.Evaluate, GS.route, state, GS.memory)
  if not ok then return fail(view) end
  if memory and memory ~= GS.memory then
    GS.memory = memory
    if ns.char then ns.char.guide = memory end
  end
  GS.view = view
  GS.evaluations = GS.evaluations + 1
  local finished = debugprofilestop and C.Call(debugprofilestop)
  if started and finished then GS.lastMs = finished - started end
  for i = 1, #(events or {}) do record(events[i]) end
  ns.Send("GUIDE_UPDATED", view)
  updatePolling()
end

-- Route compilation (after the quest data has loaded) --------------------------------------

local function collectWants(route)
  for k in pairs(GS.routeQuests) do GS.routeQuests[k] = nil end
  for k in pairs(GS.wantSpells) do GS.wantSpells[k] = nil end
  for k in pairs(GS.wantItems) do GS.wantItems[k] = nil end
  local function fromCond(cond)
    if type(cond) ~= "table" then return end
    local sk = cond.spellKnown
    if type(sk) == "table" then for i = 1, #sk do GS.wantSpells[sk[i]] = true end
    elseif type(sk) == "number" then GS.wantSpells[sk] = true end
    if type(cond.item) == "table" and cond.item[1] then GS.wantItems[cond.item[1]] = true end
  end
  for _, step in ipairs(route.steps) do
    if step.quest then GS.routeQuests[step.quest] = true end
    if step.type == "TRAIN" and type(step.spells) == "table" then
      for i = 1, #step.spells do GS.wantSpells[step.spells[i]] = true end
    end
    if step.type == "BUY" and type(step.item) == "table" and step.item[1] then GS.wantItems[step.item[1]] = true end
    fromCond(step.when)
  end
  for _, seg in pairs(route.segments) do
    fromCond(seg.def.entry); fromCond(seg.def.exit)
  end
end

local REFRESH_EVENTS = {
  "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED",
  "HEARTHSTONE_BOUND", "BAG_UPDATE_DELAYED", "LEARNED_SPELL_IN_TAB", "SPELLS_CHANGED", "TAXIMAP_OPENED",
}

local function onQuestTurnedIn(_, questID)
  if type(questID) == "number" and not C.IsSecret(questID) then
    pendingTurnIns[questID] = true
  end
  completedDirty = true
end

function GS.Activate()
  if GS.active then return true end
  if not (ns.Guides and ns.GuideEngine and ns.Guides.Count) then return false end
  if ns.Guides.Count() == 0 then return false end -- no route files: stay inert

  local character = { faction = C.GetFaction(), raceID = C.GetRaceID(), classFile = C.GetClassFile() }
  local route, problems = ns.Guides.Compile(character)
  GS.route, GS.problems = route, problems
  if not route or #route.steps == 0 then return false end

  if ns.char then
    ns.char.guide = ns.GuideEngine.Sanitize(ns.char.guide)
    GS.memory = ns.char.guide
  else
    GS.memory = ns.GuideEngine.NewMemory()
  end
  collectWants(route)
  GS.active = true

  ns.On("QUEST_TURNED_IN", onQuestTurnedIn)
  ns.On("QUEST_REMOVED", function() completedDirty = true end)
  for _, event in ipairs(REFRESH_EVENTS) do ns.On(event, ns.RequestRefresh) end
  ns.Listen("REFRESH", GS.Evaluate)
  GS.Evaluate()
  return true
end

ns.Listen("DATA_LOADED", function()
  local ok, err = pcall(GS.Activate)
  if not ok then
    GS.lastError = tostring(err)
    if geterrorhandler then geterrorhandler()(err) end
  end
end)

-- Glue for the UI (spec 7.2) ---------------------------------------------------------------

function Guide.IsActive() return GS.active end
function Guide.GetView() return GS.view end

function Guide.Skip(stepId)
  if not GS.active then return end
  ns.GuideEngine.Skip(GS.memory, stepId)
  GS.Evaluate()
end

function Guide.Unskip(stepId)
  if not GS.active then return end
  ns.GuideEngine.Unskip(GS.memory, stepId)
  GS.Evaluate()
end

function Guide.Confirm(stepId)
  if not GS.active then return end
  ns.GuideEngine.Confirm(GS.memory, stepId)
  GS.Evaluate()
end

function Guide.ChooseSuggestion(index)
  if not GS.active then return end
  local s = GS.view and GS.view.suggestions and GS.view.suggestions[index]
  if not s then return end
  if s.kind == "segment" then
    ns.GuideEngine.ApplySuggestion(GS.memory, s)
  end
  -- deathskip: performing it is the player's action; nothing changes in memory
  GS.Evaluate()
end

-- For the future auto-accept: is this quest part of the compiled route?
function Guide.IsRouteQuest(questID)
  return GS.active and GS.routeQuests[questID] == true or false
end
