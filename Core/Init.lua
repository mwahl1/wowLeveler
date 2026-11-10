-- Leveling Navigator: namespace, saved variables, event bus, slash commands
local ADDON, ns = ...

ns.ADDON = ADDON
ns.TITLE = "Leveling Navigator"

local DEFAULTS = {
  ui = {
    point = { "RIGHT", "RIGHT", -40, 60 },
    width = 330,
    height = 420,
    scale = 1,
    alpha = 0.94,
    minimized = false,
    shown = true,
    probeShown = false,
    cardExpanded = false,
    waypoint = true, -- native map waypoint for the current step's target
    combatAlpha = 0.6,
    locked = false,
    fontScale = 1,
  },
  guideEnabled = true, -- /ln guide on|off
  autoAccept = false, -- not implemented yet; reserved, off by default
  autoTurnIn = false,
}

local CHAR_DEFAULTS = {
  loads = 0,
  probe = nil,
  events = {},
}

local function ApplyDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if type(v) == "table" then
      if type(target[k]) ~= "table" then target[k] = {} end
      ApplyDefaults(target[k], v)
    elseif target[k] == nil then
      target[k] = v
    end
  end
  return target
end

-- Event bus ------------------------------------------------------------------
-- Modules subscribe with ns.On(event, fn). Events the client doesn't know are
-- recorded in ns.unknownEvents instead of throwing, so the probe can report them.

local bus = CreateFrame("Frame")
local handlers = {}
ns.unknownEvents = {}

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    local ok = pcall(bus.RegisterEvent, bus, event)
    if not ok then ns.unknownEvents[event] = true end
  end
  table.insert(handlers[event], fn)
end

bus:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], event, ...)
    if not ok then geterrorhandler()(err) end
  end
end)

-- Internal messages (not game events)
local callbacks = {}
function ns.Listen(msg, fn)
  callbacks[msg] = callbacks[msg] or {}
  table.insert(callbacks[msg], fn)
end

function ns.Send(msg, ...)
  for _, fn in ipairs(callbacks[msg] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end

-- Coalesce bursts of quest/XP events into a single UI refresh
local refreshQueued = false
function ns.RequestRefresh()
  if refreshQueued then return end
  refreshQueued = true
  local ok = C_Timer and type(C_Timer.After) == "function" and pcall(C_Timer.After, 0.1, function()
    refreshQueued = false
    ns.Send("REFRESH")
  end)
  if not ok then -- no timer: refresh now rather than never
    refreshQueued = false
    ns.Send("REFRESH")
  end
end

function ns.Print(msg)
  print("|cfff2b440Leveling Navigator|r: " .. tostring(msg))
end

-- Startup --------------------------------------------------------------------

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  LevelingNavigatorDB = ApplyDefaults(LevelingNavigatorDB or {}, DEFAULTS)
  LevelingNavigatorCharDB = ApplyDefaults(LevelingNavigatorCharDB or {}, CHAR_DEFAULTS)
  ns.db = LevelingNavigatorDB
  ns.char = LevelingNavigatorCharDB
  ns.char.loads = ns.char.loads + 1
  ns.Send("INIT")
end)

ns.On("PLAYER_ENTERING_WORLD", function()
  ns.RequestRefresh()
end)

for _, event in ipairs({
  "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
  "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_EXHAUSTION", "ZONE_CHANGED_NEW_AREA",
}) do
  ns.On(event, ns.RequestRefresh)
end

-- Slash commands -------------------------------------------------------------

SLASH_LEVELINGNAVIGATOR1 = "/ln"
SLASH_LEVELINGNAVIGATOR2 = "/levelnav"
SlashCmdList.LEVELINGNAVIGATOR = function(input)
  local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" then
    ns.Send("TOGGLE_MAIN")
  elseif cmd == "probe" then
    ns.Probe.Run()
    ns.Send("SHOW_PROBE")
  elseif cmd == "reset" then
    ns.db.ui.point = { unpack(DEFAULTS.ui.point) }
    ns.db.ui.width, ns.db.ui.height = DEFAULTS.ui.width, DEFAULTS.ui.height
    ns.db.ui.scale, ns.db.ui.alpha = DEFAULTS.ui.scale, DEFAULTS.ui.alpha
    ns.Send("APPLY_LAYOUT")
    ns.Print("Window position and size reset.")
  elseif cmd == "scale" and tonumber(arg) then
    ns.db.ui.scale = math.max(0.6, math.min(1.6, tonumber(arg)))
    ns.Send("APPLY_LAYOUT")
  elseif cmd == "alpha" and tonumber(arg) then
    ns.db.ui.alpha = math.max(0.3, math.min(1, tonumber(arg)))
    ns.Send("APPLY_LAYOUT")
  elseif cmd == "lock" then
    ns.db.ui.locked = not ns.db.ui.locked
    ns.Print(ns.db.ui.locked and "Frames locked." or "Frames unlocked.")
    ns.Send("APPLY_LAYOUT")
  elseif cmd == "font" and tonumber(arg) then
    ns.db.ui.fontScale = math.max(0.8, math.min(1.4, tonumber(arg)))
    ns.Send("APPLY_LAYOUT")
  elseif cmd == "guide" and (arg == "on" or arg == "off") then
    ns.db.guideEnabled = arg == "on"
    ns.Print(ns.db.guideEnabled and "Guide on." or "Guide off.")
    ns.Send("GUIDE_ENABLED", ns.db.guideEnabled)
  elseif cmd == "played" then
    ns.Send("REQUEST_PLAYED")
  elseif cmd == "mockguide" then
    local variant = (arg == "start" or arg == "train" or arg == "off" or arg == "main") and arg or "main"
    ns.Send("SHOW_MOCK_GUIDE", variant)
  elseif cmd == "log" then
    ns.Probe.PrintLog(tonumber(arg) or 10)
  else
    ns.Print("/ln - show/hide  |  /ln probe - API diagnostics  |  /ln log [n] - recent events")
    ns.Print("/ln scale 0.6-1.6  |  /ln alpha 0.3-1  |  /ln reset - reset window")
    ns.Print("/ln mockguide [main|start|train|off] - preview the guide card with mock data")
    ns.Print("/ln lock - lock/unlock frames  |  /ln font 0.8-1.4 - text size")
    ns.Print("/ln guide on|off - turn the leveling guide on or off")
    ns.Print("/ln played - record /played time for route measurements")
  end
end
