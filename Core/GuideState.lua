-- Guide adapter: the only guide module that touches the WoW API (through ns.Compat).
-- Builds CharacterState (spec 3.1), runs ns.GuideEngine, persists memory in
-- LevelingNavigatorCharDB.guide, sends GUIDE_UPDATED and records measurement entries
-- (STEP_DONE, QUEST_XP, PLAYED) in LevelingNavigatorCharDB.stepLog.
--
-- Inert without route files: if no guide is registered (ns.Guides.Count() == 0) nothing
-- is compiled, no events are registered, and GUIDE_UPDATED is never sent, so the P0
-- behaviour is unchanged. The same applies when the user turns the guide off
-- (`/ln guide off`, ns.db.guideEnabled = false). `/ln played` works regardless.
local _, ns = ...
local C = ns.Compat

local GS = {
  active = false,
  route = nil,       -- compiled route
  problems = nil,    -- compile problems
  memory = nil,      -- = LevelingNavigatorCharDB.guide
  view = nil,        -- last GuideView
  lastError = nil,   -- last compile/evaluate error (shown by the probe)
  failures = 0,      -- consecutive evaluation failures
  skipped = 0,       -- evaluations skipped by the loading / empty-log gates
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
local POLL_SECONDS = 0.5     -- 2 Hz, only while the current step has a location on the player's map
local LOADING_GRACE = 1      -- seconds after PLAYER_ENTERING_WORLD before evaluating again
local ERROR_INTERVAL = 30    -- seconds between reports of the same error message
local MAX_FAILURES = 5       -- consecutive failures before position polling stops

-- Clock: one source for the whole session (GetTime if it works at first use, else time())

local clock
local function now()
  if clock == nil then
    if C.GetTime() ~= nil then clock = "GetTime" else clock = "time" end
  end
  if clock == "GetTime" then return C.GetTime() end
  if type(time) == "function" then return time() end
  return nil
end

-- Measurement log ----------------------------------------------------------------------

local function stepLog()
  if not ns.char then return nil end
  if type(ns.char.stepLog) ~= "table" then ns.char.stepLog = {} end
  return ns.char.stepLog
end

local function pushLog(entry)
  local log = stepLog()
  if not log then return end
  log[#log + 1] = entry
  while #log > MAX_STEP_LOG do table.remove(log, 1) end
end

local function wallTime() return type(time) == "function" and time() or nil end

local function recordStep(ev)
  pushLog({
    t = wallTime() or ev.t,
    e = "STEP_DONE",
    a = table.concat({ tostring(ev.stepId), tostring(ev.segment), tostring(ev.seconds or "") }, ","),
    m = ev.map,
    x = ev.x and math.floor(ev.x * 10 + 0.5) / 10,
    y = ev.y and math.floor(ev.y * 10 + 0.5) / 10,
    lv = ev.level,
    xp = ev.xp,
  })
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

-- Quest log snapshot ----------------------------------------------------------------------
-- Re-read only when a quest event marked it dirty; position-only evaluations reuse it.
-- A log that went from non-empty to empty without QUEST_REMOVED is a client glitch
-- (loading, phasing): that evaluation is skipped and the read retried on the next one.

local logSnapshot, logCount
local logDirty = true
local removedSinceSnapshot = false
local EMPTY_GLITCH = {}

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function getLog()
  if not logDirty then return logSnapshot, logCount end
  local log = C.GetQuestLogState()
  local n = log and countKeys(log) or nil
  if log and n == 0 and logCount and logCount > 0 and not removedSinceSnapshot then
    return EMPTY_GLITCH
  end
  logSnapshot, logCount = log, n
  logDirty, removedSinceSnapshot = false, false
  return logSnapshot, logCount
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

-- Returns the state, or nil when this evaluation must be skipped (empty-log glitch)
function GS.BuildState()
  local log, count = getLog()
  if log == EMPTY_GLITCH then return nil end
  local ch = C.GetCharacter()
  local map, x, y = C.GetPlayerPosition()
  local dead, ghost = C.GetDeathState()
  local completed, unknown = getCompleted()
  local state = {
    time = now(),
    guid = C.GetPlayerGUID(),
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
    log = log,
    logCount = count,
    logMax = C.GetMaxQuestsCanAccept(),
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

local ticker
local pollSuspended = false
local loading = false
local loadingUntil -- clock time after which the loading gate opens on its own
local lastPos = {}
local reported = {} -- error message -> time last reported

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
  local want = GS.active and not pollSuspended and not loading and wantsPolling(GS.view)
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
  local msg = tostring(err)
  GS.lastError = msg
  GS.failures = GS.failures + 1
  if GS.failures >= MAX_FAILURES then
    pollSuspended = true
    stopPolling()
  end
  local t = now() or 0
  local last = reported[msg]
  if last == nil or t - last >= ERROR_INTERVAL or t < last then
    reported[msg] = t
    if geterrorhandler then geterrorhandler()(err) end
  end
end

function GS.Evaluate()
  if not (GS.active and GS.route) then return end
  if loading then
    local t = loadingUntil and now()
    if t and t >= loadingUntil then
      loading, loadingUntil, logDirty = false, nil, true
    else
      GS.skipped = GS.skipped + 1
      return
    end
  end
  local started = debugprofilestop and C.Call(debugprofilestop)
  local okState, state = pcall(GS.BuildState)
  if not okState then return fail(state) end
  if state == nil then GS.skipped = GS.skipped + 1; return end
  lastPos.map, lastPos.x, lastPos.y = state.map, state.x, state.y
  GS.memory.autoSwitch = state.settings.autoSwitch
  local ok, view, events, memory = pcall(ns.GuideEngine.Evaluate, GS.route, state, GS.memory)
  if not ok then return fail(view) end
  GS.failures, pollSuspended = 0, false
  if memory and memory ~= GS.memory then
    GS.memory = memory
    if ns.char then ns.char.guide = memory end
  end
  GS.view = view
  GS.evaluations = GS.evaluations + 1
  local finished = debugprofilestop and C.Call(debugprofilestop)
  if started and finished then GS.lastMs = finished - started end
  for i = 1, #(events or {}) do
    recordStep(events[i])
    ns.Send("STEP_DONE", events[i]) -- real completions (UI flash)
  end
  ns.Send("GUIDE_UPDATED", view)
  updatePolling()
end

-- /played capture -------------------------------------------------------------------------
-- Only on an explicit `/ln played` (the client prints its normal chat output; Blizzard chat
-- frames are never touched). The reply is captured from TIME_PLAYED_MSG.

local played = { handler = false, pending = false }

local function onTimePlayed(_, total, thisLevel)
  if not played.pending then return end -- the player typed /played themselves: not ours
  played.pending = false
  if C.IsSecret(total) or type(total) ~= "number" then return end
  if C.IsSecret(thisLevel) or type(thisLevel) ~= "number" then thisLevel = nil end
  local lv = readable(C.Call(UnitLevel, "player"))
  if ns.char then ns.char.played = { total = total, level = thisLevel, lv = lv, t = wallTime() } end
  pushLog({ t = wallTime(), e = "PLAYED", total = total, levelTime = thisLevel, lv = lv })
end

local function ensurePlayedHandler()
  if played.handler then return end
  played.handler = true
  ns.On("TIME_PLAYED_MSG", onTimePlayed)
end

-- `/ln played`: request /played (printed normally by the client) and record the reply
function GS.RequestPlayed()
  if type(RequestTimePlayed) ~= "function" then
    ns.Print("/played is not available in this client.")
    return false
  end
  ensurePlayedHandler()
  played.pending = true
  local ok = pcall(RequestTimePlayed)
  if not ok then played.pending = false end
  return ok
end
GS.played = played

ns.Listen("REQUEST_PLAYED", function() GS.RequestPlayed() end)

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
  -- LEARNED_SPELL_IN_TAB removed: unknown to the Forever client (in-game probe 2026-11-10);
  -- SPELLS_CHANGED covers newly learned spells.
  "HEARTHSTONE_BOUND", "BAG_UPDATE_DELAYED", "SPELLS_CHANGED", "TAXIMAP_OPENED",
}
local LOG_EVENTS = { "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_WATCH_UPDATE", "UNIT_QUEST_LOG_CHANGED" }

local function markLogDirty() logDirty = true end

local function onQuestTurnedIn(_, questID, xpReward)
  if not GS.active then return end
  logDirty = true
  removedSinceSnapshot = true -- turning in the last quest empties the log legitimately
  completedDirty = true
  if type(questID) == "number" and not C.IsSecret(questID) then
    pendingTurnIns[questID] = true
    local xp = (type(xpReward) == "number" and not C.IsSecret(xpReward)) and xpReward or nil
    pushLog({ t = wallTime(), e = "QUEST_XP", quest = questID, xp = xp,
              lv = readable(C.Call(UnitLevel, "player")) })
  end
end

local function onQuestRemoved()
  if not GS.active then return end
  logDirty = true
  removedSinceSnapshot = true
  completedDirty = true
end

local function endLoading()
  if not loading then return end
  loading, loadingUntil = false, nil
  logDirty = true
  GS.Evaluate()
end

-- Starts (or extends) the loading gate for `seconds`. The timer ends it; if C_Timer is
-- missing or fails, the next event after the deadline ends it instead (see GS.Evaluate).
local function gateFor(seconds)
  loading = true
  local t = now()
  loadingUntil = t and (t + seconds) or nil
  local ok = C_Timer and type(C_Timer.After) == "function" and pcall(C_Timer.After, seconds, endLoading)
  if not ok and loadingUntil == nil then loading = false end -- no timer and no clock: no gate
end

local function onEnteringWorld()
  if not GS.active then return end
  gateFor(LOADING_GRACE)
end

local function guideEnabled()
  return not (ns.db and ns.db.guideEnabled == false)
end
GS.IsEnabled = guideEnabled

local registered = false
local function registerEvents()
  if registered then return end
  registered = true
  ns.On("QUEST_TURNED_IN", onQuestTurnedIn)
  ns.On("QUEST_REMOVED", onQuestRemoved)
  for _, event in ipairs(LOG_EVENTS) do ns.On(event, markLogDirty) end
  for _, event in ipairs(REFRESH_EVENTS) do ns.On(event, ns.RequestRefresh) end
  ns.On("PLAYER_LEAVING_WORLD", function() if GS.active then loading = true; stopPolling() end end)
  ns.On("PLAYER_ENTERING_WORLD", onEnteringWorld)
  ns.Listen("REFRESH", GS.Evaluate)
end

-- atLogin: wait for the first PLAYER_ENTERING_WORLD (+1 s), 5 s fallback. Otherwise (turned
-- on at runtime) evaluate immediately.
function GS.Activate(atLogin)
  if GS.active then return true end
  if not guideEnabled() then return false end -- turned off by the user: stay inert
  if not (ns.Guides and ns.GuideEngine and ns.Guides.Count) then return false end
  if ns.Guides.Count() == 0 then return false end -- no route files: stay inert

  local character = { faction = C.GetFaction(), raceID = C.GetRaceID(), classFile = C.GetClassFile() }
  local route, problems = ns.Guides.Compile(character)
  GS.route, GS.problems = route, problems
  if not route or #route.steps == 0 then return false end

  local guid = C.GetPlayerGUID()
  if ns.char then
    ns.char.guide = ns.GuideEngine.Sanitize(ns.char.guide, guid)
    GS.memory = ns.char.guide
  else
    GS.memory = ns.GuideEngine.Sanitize(nil, guid)
  end
  -- One-time: forget skips made with the old card's SKIP button. The first in-game test
  -- skipped every step to see the route, which left the guide saying nothing at all.
  if ns.char and not ns.char.oldSkipsCleared then
    GS.memory.skips = {}
    ns.char.oldSkipsCleared = true
  end
  collectWants(route)
  GS.active = true
  logDirty, completedDirty = true, true
  registerEvents()

  if atLogin then
    gateFor(5) -- PLAYER_ENTERING_WORLD shortens this to 1 s
  else
    loading, loadingUntil = false, nil
    GS.Evaluate()
  end
  return true
end

-- Turned off: inert like "no routes" (handlers stay registered but return immediately; no
-- evaluation, no SavedVariables writes). Clears our waypoint and hides the card.
function GS.Deactivate()
  if not GS.active then return end
  GS.active = false
  stopPolling()
  loading, loadingUntil = false, nil
  C.ClearWaypoint()
  GS.view = nil
  ns.Send("GUIDE_UPDATED", nil)
end

local dataLoaded = false
local function tryActivate(atLogin)
  local ok, err = pcall(GS.Activate, atLogin)
  if not ok then
    GS.lastError = tostring(err)
    if geterrorhandler then geterrorhandler()(err) end
  end
end

ns.Listen("DATA_LOADED", function()
  dataLoaded = true
  tryActivate(true)
end)

-- `/ln guide on|off` (Core/Init.lua stores ns.db.guideEnabled, then sends this)
ns.Listen("GUIDE_ENABLED", function(enabled)
  if enabled then
    if dataLoaded then tryActivate(false) end
  else
    GS.Deactivate()
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

-- `/ln unskip`: forgets every manual skip for this character. Returns how many were cleared.
function Guide.ClearSkips()
  if not (GS.active and GS.memory) then return 0 end
  local n = 0
  for id in pairs(GS.memory.skips or {}) do
    ns.GuideEngine.Unskip(GS.memory, id)
    n = n + 1
  end
  GS.Evaluate()
  return n
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
