-- Settings window (/ln settings, or the gear in the overlay's title bar).
-- Game options (auto loot) are read from the client every time the window is shown,
-- so the checkbox always tells the truth even if it was changed in Blizzard's menu.
local _, ns = ...
local T, W = ns.Theme, ns.Widgets

local Settings = {}
ns.SettingsPanel = Settings

local frame
local items = {}

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ROW = 30

-- Rows ------------------------------------------------------------------------------
-- get() returns true / false / nil (nil = can't be read); set(on) applies the change and
-- may return false when it failed (shown as a short note).
local DEFS = {
  { section = "Game options" },
  { label = "Auto loot",
    note = "Loots everything with a normal right-click (Blizzard setting).",
    get = function() return ns.Compat.GetCVarBool("autoLootDefault") end,
    set = function(on) return ns.Compat.SetCVarBool("autoLootDefault", on) end,
    warnWhenOff = true },

  { section = "Guide" },
  { label = "Leveling guide",
    note = "Shows the current step and tracks your progress.",
    get = function() return ns.db.guideEnabled ~= false end,
    set = function(on)
      ns.db.guideEnabled = on
      ns.Send("GUIDE_ENABLED", on)
    end },
  { label = "Map waypoint",
    note = "Puts Blizzard's map pin and arrow on the current step's target.",
    get = function() return ns.db.ui.waypoint ~= false end,
    set = function(on)
      ns.db.ui.waypoint = on
      if ns.GuideWindow then ns.GuideWindow.UpdateWaypoint() end
    end },

  { label = "Map pins",
    note = "Exact spots for the current step on the minimap and world map.",
    get = function() return ns.db.ui.pins ~= false end,
    set = function(on)
      ns.db.ui.pins = on
      if ns.MapPins then ns.MapPins.Refresh() end
    end },
  { label = "XP bar",
    note = "Level, XP and rested XP under the guide title.",
    get = function() return ns.db.ui.xpBar ~= false end,
    set = function(on)
      ns.db.ui.xpBar = on
      if ns.GuideWindow then ns.GuideWindow.UpdateXP() end
    end },

  { section = "Quests" },
  { label = "Auto accept quests",
    note = "Accepts quests when you talk to the quest giver.",
    get = function() return ns.db.autoAccept == true end,
    set = function(on) ns.db.autoAccept = on end },
  { label = "Auto turn in quests",
    note = "Completes finished quests. You still pick the reward when there is a choice.",
    get = function() return ns.db.autoTurnIn == true end,
    set = function(on) ns.db.autoTurnIn = on end },
  { label = "Only quests on the route",
    note = "Auto accept skips quests the route leaves out.",
    indent = 18,
    get = function() return ns.db.autoRouteOnly ~= false end,
    set = function(on) ns.db.autoRouteOnly = on end },
}

local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end

local function CreateCheckRow(parent, def)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(ROW)
  r.def = def

  r.box = r:CreateTexture(nil, "ARTWORK")
  r.box:SetSize(14, 14)
  r.box:SetPoint("TOPLEFT", def.indent or 0, -2)
  r.box:SetTexture(WHITE)
  r.boxEdge = r:CreateTexture(nil, "BORDER")
  r.boxEdge:SetPoint("TOPLEFT", r.box, "TOPLEFT", -1, 1)
  r.boxEdge:SetPoint("BOTTOMRIGHT", r.box, "BOTTOMRIGHT", 1, -1)
  r.boxEdge:SetColorTexture(1, 1, 1, 0.25)
  r.check = r:CreateTexture(nil, "OVERLAY")
  r.check:SetPoint("CENTER", r.box, "CENTER", 0, 0)
  r.check:SetSize(8, 8)
  r.check:SetColorTexture(0.06, 0.06, 0.08, 1)

  r.label = W.Text(r, { size = T.size.body, wrap = false })
  r.label:SetPoint("TOPLEFT", r.box, "TOPRIGHT", 8, 1)
  r.label:SetText(def.label)
  r.state = W.Text(r, { font = T.font.heading, size = T.size.tag, justify = "RIGHT", wrap = false })
  r.state:SetPoint("TOPRIGHT", 0, -2)
  r.note = W.Text(r, { size = T.size.small, color = T.color.faint, wrap = false })
  r.note:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -2)
  r.note:SetPoint("RIGHT", r, "RIGHT", 0, 0)
  r.note:SetText(def.note or "")

  r:SetScript("OnEnter", function() SetColor(r.label, T.color.accent) end)
  r:SetScript("OnLeave", function() SetColor(r.label, T.color.text) end)
  r:SetScript("OnClick", function()
    local cur = def.get()
    local ok = def.set(not cur)
    Settings.Refresh()
    if ok == false then
      r.note:SetText("Could not change this right now (in combat?). Try again.")
      SetColor(r.note, T.color.warn)
    end
  end)
  return r
end

local function RenderRow(r)
  local def = r.def
  local v = def.get()
  local c
  if v == nil then
    r.box:SetVertexColor(0.2, 0.21, 0.24, 1); r.check:Hide()
    r.state:SetText("UNKNOWN"); c = T.color.faint
  elseif v then
    local a = T.color.good
    r.box:SetVertexColor(a[1], a[2], a[3], 1); r.check:Show()
    r.state:SetText("ON"); c = T.color.good
  else
    r.box:SetVertexColor(0.16, 0.17, 0.2, 1); r.check:Hide()
    r.state:SetText("OFF"); c = def.warnWhenOff and T.color.warn or T.color.faint
  end
  SetColor(r.state, c)
  r.note:SetText(def.note or "")
  SetColor(r.note, T.color.faint)
end

local function Create()
  frame = W.Panel(UIParent, "LevelingNavigatorSettingsFrame")
  frame:SetSize(380, 10)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  tinsert(UISpecialFrames, "LevelingNavigatorSettingsFrame") -- Escape closes it

  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", 4, -4); header:SetPoint("TOPRIGHT", -4, -4)
  header:SetHeight(T.space.header)
  header.bg = header:CreateTexture(nil, "BACKGROUND")
  header.bg:SetAllPoints()
  header.bg:SetColorTexture(1, 1, 1, 0.04)
  local title = W.Text(header, { font = T.font.heading, size = T.size.title, color = T.color.accent, wrap = false })
  title:SetPoint("LEFT", T.space.pad, 0)
  title:SetText("SETTINGS")
  local close = W.TextButton(header, "x", function() frame:Hide() end)
  close:SetPoint("RIGHT", -6, 0)

  local pad = T.space.pad
  local y = T.space.header + pad
  for _, def in ipairs(DEFS) do
    if def.section then
      local l = W.Label(frame, def.section)
      l:SetPoint("TOPLEFT", pad, -y - 4)
      y = y + 22
    else
      local r = CreateCheckRow(frame, def)
      r:SetPoint("TOPLEFT", pad, -y)
      r:SetPoint("RIGHT", frame, "RIGHT", -pad, 0)
      items[#items + 1] = r
      y = y + ROW + 6
    end
  end

  local hint = W.Text(frame, { size = T.size.small, color = T.color.muted })
  hint:SetPoint("TOPLEFT", pad, -y - 2)
  hint:SetPoint("RIGHT", frame, "RIGHT", -pad, 0)
  hint:SetText("Hold Shift while talking to an NPC to pause auto accept and turn in.")
  frame:SetHeight(y + 30)

  frame:SetScript("OnShow", Settings.Refresh)
end

function Settings.Refresh()
  if not (frame and frame:IsShown()) then return end
  for _, r in ipairs(items) do RenderRow(r) end
end

function Settings.Toggle()
  if not frame then return end
  frame:SetShown(not frame:IsShown())
end

ns.Listen("INIT", Create)
ns.Listen("SHOW_SETTINGS", Settings.Toggle)
if ns.On then
  -- Blizzard's own options menu can change auto loot while our window is open
  ns.On("CVAR_UPDATE", function() Settings.Refresh() end)
end
