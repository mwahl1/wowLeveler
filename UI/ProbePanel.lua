-- Diagnostics window: lists each API check with its status
local _, ns = ...
local T, W = ns.Theme, ns.Widgets

local frame
local rows = {}

local STATUS = {
  pass    = { "OK",      T.color.good },
  partial = { "PARTIAL", T.color.warn },
  missing = { "MISSING", T.color.bad },
  error   = { "ERROR",   T.color.bad },
}

local function Create()
  frame = CreateFrame("Frame", "LevelingNavigatorProbeFrame", UIParent)
  frame:SetSize(460, 520)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  W.Skin(frame)
  frame:Hide()
  tinsert(UISpecialFrames, "LevelingNavigatorProbeFrame") -- Escape closes it

  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
  header:SetHeight(T.space.header)
  W.Skin(header, T.color.surface)

  local title = W.Text(header, { font = T.font.heading, size = T.size.title, color = T.color.accent, wrap = false })
  title:SetPoint("LEFT", T.space.pad, 0)
  title:SetText("API DIAGNOSTICS")

  local close = W.TextButton(header, "x", function() frame:Hide() end)
  close:SetPoint("RIGHT", -6, 0)
  local rerun = W.TextButton(header, "Run again", function() ns.Probe.Run() end)
  rerun:SetWidth(80)
  W.SetFont(rerun.text, T.font.body, T.size.small)
  rerun:SetPoint("RIGHT", close, "LEFT", -8, 0)

  frame.meta = W.Text(frame, { size = T.size.small, color = T.color.muted })
  frame.meta:SetPoint("TOPLEFT", T.space.pad, -T.space.header - T.space.gap)
  frame.meta:SetPoint("RIGHT", -T.space.pad, 0)

  local scroll = W.ScrollArea(frame)
  scroll:SetPoint("TOPLEFT", frame.meta, "BOTTOMLEFT", 0, -T.space.gap)
  scroll:SetPoint("BOTTOMRIGHT", -T.space.pad, T.space.pad)
  frame.scroll = scroll
end

local function Render()
  if not frame then return end
  local p = ns.char.probe
  for _, r in ipairs(rows) do r:Hide() end
  if not p then
    frame.meta:SetText("Running checks...")
    return
  end
  frame.meta:SetText(string.format("Last run %s  ·  interface %s  ·  %d recorded events\nResults are saved in WTF\\Account\\<account>\\<realm>\\<character>\\SavedVariables\\LevelingNavigator.lua",
    p.time, tostring(p.interface), #ns.char.events))

  local content = frame.scroll.content
  local width = frame.scroll:GetWidth()
  local y = 0
  for i, res in ipairs(p.results) do
    local r = rows[i]
    if not r then
      r = CreateFrame("Frame", nil, content)
      r.status = W.Text(r, { font = T.font.heading, size = T.size.heading, wrap = false })
      r.status:SetPoint("TOPLEFT", 0, -1)
      r.status:SetWidth(64)
      r.name = W.Text(r, { size = T.size.body, wrap = false })
      r.name:SetPoint("TOPLEFT", 70, 0)
      r.detail = W.Text(r, { size = T.size.small, color = T.color.muted })
      r.detail:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
      rows[i] = r
    end
    local s = STATUS[res.status] or STATUS.error
    r.status:SetText(s[1])
    r.status:SetTextColor(s[2][1], s[2][2], s[2][3])
    r.name:SetText(res.name)
    r.detail:SetWidth(width - 70)
    r.detail:SetText(res.detail)
    local h = r.name:GetStringHeight() + 2 + r.detail:GetStringHeight()
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    r:SetSize(width, h)
    r:Show()
    y = y + h + 10
  end
  content:SetHeight(math.max(1, y))
end

ns.Listen("INIT", Create)
ns.Listen("PROBE_DONE", Render)
ns.Listen("SHOW_PROBE", function()
  frame:Show()
  Render()
end)
