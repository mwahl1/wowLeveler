-- Guide adapter: the only guide module that touches the WoW API (through ns.Compat).
-- Builds CharacterState (spec 3.1), runs ns.GuideEngine, persists memory in
-- LevelingNavigatorCharDB.guide, sends GUIDE_UPDATED and records STEP_DONE events.
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
  routeQuests = {},  -- [questID] = true
  wantSpells = {},   -- spell IDs routes ask about (TRAIN steps, spellKnown conditions)
  wantItems = {},    -- item IDs routes ask about (BUY steps, item conditions)
  evaluations = 0,
  lastMs = nil,
}
ns.GuideState = GS

local Guide = ns.Guide or {}
ns.Guide = Guide

local MAX_EVENTS = 400 -- same cap as the probe's recorder
local POLL_SECONDS = 0.5 -- 2 Hz, only while the current step has a location

-- Completed quests ---------------------------------------------------------------------
-- Rebuilt from GetAllCompletedQuestIDs when dirty (login, turn-in, quest removed). Without
-- that API, a lazy per-quest lookup; without either, nil (engine treats state as unknown).

local completedSet
local completedDirty = true

local function lazyCompleted()
  return setmetatable({}, { __index = function(t, questID)
    local done = C.IsQuestFlaggedCompleted(questID)
    if done == nil then return nil end
    rawset(t, questID, done)
    return done or nil
  end })
end

local function getCompleted()
  if completedDirty or completedSet == nil then
    completedDirty = false
    local ids = C.GetAllCompletedQuestIDs()
    if ids then
      local set = {}
      for i = 1, #ids do
        local id = ids[i]
        if type(id) == "number" then set[id] = true end
      end
      completedSet = set
    elseif C.HasQuestFlaggedCompleted() then
      completedSet = lazyCompleted()
    else
      completedSet = nil
    end
  end
  return completedSet
end

-- CharacterState ------------------------------------------------------------------------

local function settings()
  local db = ns.db or {}
  return {
    deathSkips = db.deathSkips == true,
    autoSwitch = db.autoSwitchSegments == true,
  }
end

function GS.BuildState()
  local ch = C.GetCharacter()
  local map, x, y = C.GetPlayerPosition()
  local dead, ghost = C.GetDeathState()
  local state = {
    time = C.GetTime() or (type(time) == "function" and time()) or nil,
    faction = ch.faction,
    raceID = C.GetRaceID(),
    classFile = C.GetClassFile(),
    level = not C.IsSecret(ch.level) and ch.level or nil,
    xp = not C.IsSecret(ch.xp) and ch.xp or nil,
    xpMax = not C.IsSecret(ch.xpMax) and ch.xpMax or nil,
    restedXP = not C.IsSecret(ch.rested) and ch.rested or nil,
    map = map, x = x, y = y,
    completed = getCompleted(),
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
  local log = ns.char and ns.char.events
  if type(log) ~= "table" then return end
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
  while #log > MAX_EVENTS do table.remove(log, 1) end
end

local ticker
local lastPos = {}

local function hasLocation(view)
  local cur = view and view.current and view.current[1]
  local t = cur and cur.target
  return t ~= nil and t.x ~= nil and t.y ~= nil
end

local function updatePolling()
  local want = GS.active and hasLocation(GS.view)
  if want and not ticker and C_Timer and C_Timer.NewTicker then
    ticker = C.Call(C_Timer.NewTicker, POLL_SECONDS, function()
      local map, x, y = C.GetPlayerPosition()
      if map ~= lastPos.map or x == nil or lastPos.x == nil
          or math.abs(x - lastPos.x) + math.abs(y - lastPos.y) > 0.05 then
        GS.Evaluate()
      end
    end)
  elseif not want and ticker then
    C.Call(ticker.Cancel, ticker)
    ticker = nil
  end
end

function GS.Evaluate()
  if not (GS.active and GS.route) then return end
  local started = debugprofilestop and C.Call(debugprofilestop)
  local state = GS.BuildState()
  lastPos.map, lastPos.x, lastPos.y = state.map, state.x, state.y
  GS.memory.autoSwitch = state.settings.autoSwitch
  local ok, view, events, memory = pcall(ns.GuideEngine.Evaluate, GS.route, state, GS.memory)
  if not ok then
    if geterrorhandler then geterrorhandler()(view) end
    return
  end
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
  if type(questID) == "number" and not C.IsSecret(questID) and type(completedSet) == "table" then
    rawset(completedSet, questID, true)
  end
  completedDirty = true
end

function GS.Activate()
  if GS.active then return true end
  if not (ns.Guides and ns.GuideEngine and ns.Guides.Count) then return false end
  if ns.Guides.Count() == 0 then return false end -- no route files: stay inert

  local character = { faction = C.Call(UnitFactionGroup, "player"), raceID = C.GetRaceID(), classFile = C.GetClassFile() }
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
  if not ok and geterrorhandler then geterrorhandler()(err) end
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
  elseif s.kind == "deathskip" and s.step then
    -- Accepting a death skip is the player's action; nothing to change in memory
  end
  GS.Evaluate()
end

-- For the future auto-accept: is this quest part of the compiled route?
function Guide.IsRouteQuest(questID)
  return GS.active and GS.routeQuests[questID] == true or false
end
