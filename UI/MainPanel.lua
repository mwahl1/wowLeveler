-- Main overlay: character header, XP, location, live quest objectives, API status
local _, ns = ...
local T, W, C = ns.Theme, ns.Widgets, ns.Compat

local Main = {}
ns.MainPanel = Main

local PAD, GAP = T.space.pad, T.space.gap
local HEADER_H = T.space.header
local frame

-- Row pool -------------------------------------------------------------------
-- Quest rows are reused across refreshes to avoid creating frames every update.

local rows, rowCount = {}, 0

local function AcquireRow(parent)
  rowCount = rowCount + 1
  local r = rows[rowCount]
  if not r then
    r = CreateFrame("Frame", nil, parent)
    r.title = W.Text(r, { size = T.size.body })
    r.badge = W.Text(r, { font = T.font.heading, size = T.size.heading, justify = "RIGHT", wrap = false })
    r.bar = W.Bar(r, 3)
    rows[rowCount] = r
  end
  r:Show()
  return r
end

local function ReleaseRows()
  for i = 1, #rows do rows[i]:Hide() end
  rowCount = 0
end

-- Layout ---------------------------------------------------------------------

local function Create()
  frame = CreateFrame("Frame", "LevelingNavigatorFrame", UIParent)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(260, HEADER_H, 620, 900)
  end
  frame:EnableMouse(true)
  W.Skin(frame)

  -- Title bar: drag handle, accent stripe, controls
  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
  header:SetHeight(HEADER_H)
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function() frame:StartMoving() end)
  header:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    local point, _, relPoint, x, y = frame:GetPoint()
    ns.db.ui.point = { point, relPoint, x, y }
  end)
  W.Skin(header, T.color.surface)

  local stripe = header:CreateTexture(nil, "ARTWORK")
  stripe:SetPoint("TOPLEFT"); stripe:SetPoint("BOTTOMLEFT")
  stripe:SetWidth(2)
  stripe:SetColorTexture(unpack(T.color.accent))

  frame.title = W.Text(header, { font = T.font.heading, size = T.size.title, color = T.color.accent, wrap = false })
  frame.title:SetPoint("LEFT", PAD, 0)
  frame.title:SetText("LEVELING NAVIGATOR")

  frame.closeBtn = W.TextButton(header, "x", function() Main.SetShown(false) end)
  frame.closeBtn:SetPoint("RIGHT", -6, 0)
  frame.minBtn = W.TextButton(header, "-", function() Main.SetMinimized(not ns.db.ui.minimized) end)
  frame.minBtn:SetPoint("RIGHT", frame.closeBtn, "LEFT", -2, 0)

  -- Compact summary shown in the title bar while minimized
  frame.mini = W.Text(header, { size = T.size.small, color = T.color.muted, justify = "RIGHT", wrap = false })
  frame.mini:SetPoint("RIGHT", frame.minBtn, "LEFT", -6, 0)

  -- Body
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", 0, -HEADER_H)
  body:SetPoint("BOTTOMRIGHT")
  frame.body = body

  frame.charName = W.Text(body, { font = T.font.heading, size = 14, wrap = false })
  frame.charName:SetPoint("TOPLEFT", PAD, -PAD)
  frame.charLine = W.Text(body, { size = T.size.small, color = T.color.muted, wrap = false })
  frame.charLine:SetPoint("TOPLEFT", frame.charName, "BOTTOMLEFT", 0, -3)

  frame.xpBar = W.Bar(body, 6, T.color.xp)
  frame.xpBar:SetPoint("TOPLEFT", frame.charLine, "BOTTOMLEFT", 0, -GAP)
  frame.xpBar:SetPoint("RIGHT", body, "RIGHT", -PAD, 0)
  frame.xpText = W.Text(body, { size = T.size.small, color = T.color.muted, wrap = false })
  frame.xpText:SetPoint("TOPLEFT", frame.xpBar, "BOTTOMLEFT", 0, -4)

  frame.zone = W.Text(body, { size = T.size.body, wrap = false })
  frame.zone:SetPoint("TOPLEFT", frame.xpText, "BOTTOMLEFT", 0, -GAP)
  frame.coords = W.Text(body, { size = T.size.small, color = T.color.muted, justify = "RIGHT", wrap = false })
  frame.coords:SetPoint("RIGHT", body, "RIGHT", -PAD, 0)
  frame.coords:SetPoint("TOP", frame.zone, "TOP")

  local div = W.Divider(body)
  div:SetPoint("TOPLEFT", frame.zone, "BOTTOMLEFT", 0, -GAP)
  div:SetPoint("RIGHT", body, "RIGHT", -PAD, 0)

  frame.div = div

  -- Optional guide card between the location divider and the quest list.
  -- Hidden (and the layout unchanged) while no guide view is active.
  if ns.GuideCard then
    frame.guideCard = ns.GuideCard.Attach(body, div, function() Main.AnchorQuests() end)
  end

  frame.questLabel = W.Label(body, "Current quests")
  Main.AnchorQuests() -- below the divider, or below the card if a view already arrived
  frame.questCount = W.Text(body, { font = T.font.heading, size = T.size.heading, color = T.color.faint, justify = "RIGHT", wrap = false })
  frame.questCount:SetPoint("RIGHT", body, "RIGHT", -PAD, 0)
  frame.questCount:SetPoint("TOP", frame.questLabel, "TOP")

  -- Footer: diagnostics summary, click to open the probe window
  local footer = CreateFrame("Button", nil, body)
  footer:SetPoint("BOTTOMLEFT"); footer:SetPoint("BOTTOMRIGHT")
  footer:SetHeight(26)
  W.Skin(footer, T.color.surface)
  footer.text = W.Text(footer, { size = T.size.small, color = T.color.muted, wrap = false })
  footer.text:SetPoint("LEFT", PAD, 0)
  footer.text:SetPoint("RIGHT", -PAD - 14, 0)
  footer:SetScript("OnClick", function() ns.Send("SHOW_PROBE") end)
  footer:SetScript("OnEnter", function() footer.bg:SetColorTexture(0.12, 0.13, 0.16, 1) end)
  footer:SetScript("OnLeave", function() local s = T.color.surface; footer.bg:SetColorTexture(s[1], s[2], s[3], 1) end)
  frame.footer = footer

  -- Scrolling quest list between the label and the footer
  local scroll = W.ScrollArea(body)
  scroll:SetPoint("TOPLEFT", frame.questLabel, "BOTTOMLEFT", 0, -6)
  scroll:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", -PAD, 6)
  frame.scroll = scroll

  -- Resize grip
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetFrameLevel(footer:GetFrameLevel() + 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    ns.db.ui.width, ns.db.ui.height = frame:GetSize()
    local point, _, relPoint, x, y = frame:GetPoint()
    ns.db.ui.point = { point, relPoint, x, y }
    Main.Refresh()
  end)
  frame.grip = grip

  frame:SetScript("OnSizeChanged", function()
    if ns.db.ui.minimized then return end
    if ns.GuideCard then ns.GuideCard.Relayout() end
    Main.LayoutQuests()
  end)

  -- Position text is the only thing polled, and only while visible
  local elapsed = 0
  frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.25 then return end
    elapsed = 0
    Main.UpdateLocation()
  end)
end

-- Rendering ------------------------------------------------------------------

-- "Current quests" sits below the guide card when it is shown, else below the
-- location divider (the original P0 layout). The scroll list follows the label.
function Main.AnchorQuests()
  if not frame or not frame.questLabel then return end
  local below = (ns.GuideCard and ns.GuideCard.IsShown()) and frame.guideCard or frame.div
  frame.questLabel:ClearAllPoints()
  frame.questLabel:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -GAP)
end

function Main.ApplyLayout()
  local ui = ns.db.ui
  frame:ClearAllPoints()
  frame:SetPoint(ui.point[1], UIParent, ui.point[2], ui.point[3], ui.point[4])
  frame:SetScale(ui.scale)
  frame:SetAlpha(ui.alpha)
  frame:SetWidth(ui.width)
  frame:SetHeight(ui.minimized and HEADER_H or ui.height)
  frame.body:SetShown(not ui.minimized)
  frame.grip:SetShown(not ui.minimized)
  frame.mini:SetShown(ui.minimized)
  frame.minBtn.text:SetText(ui.minimized and "+" or "-")
  frame:SetShown(ui.shown)
end

function Main.SetMinimized(min)
  ns.db.ui.minimized = min
  Main.ApplyLayout()
  Main.Refresh()
end

function Main.SetShown(shown)
  ns.db.ui.shown = shown
  frame:SetShown(shown)
  if not shown then ns.Print("Hidden. Type /ln to show it again.") end
end

function Main.UpdateLocation()
  local mapID, x, y = C.GetPlayerPosition()
  frame.zone:SetText(C.GetMapName(mapID) or GetZoneText() or "Unknown zone")
  if x then
    frame.coords:SetText(string.format("%.1f, %.1f", x, y))
  else
    frame.coords:SetText("position hidden")
  end
end

local function Colored(c, text) return "|c" .. T.Hex(c) .. text .. "|r" end

function Main.UpdateCharacter()
  local c = C.GetCharacter()
  frame.charName:SetText(c.name or "")
  frame.charName:SetTextColor(C.GetClassColor(c.classFile))
  frame.charLine:SetText(string.format("Level %s %s %s  ·  %s", C.SafeString(c.level), c.race or "", c.class or "", c.faction or ""))

  local xp, max, rested = c.xp or 0, c.xpMax or 0, c.rested or 0
  if max > 0 and not C.IsSecret(xp) then
    local frac = xp / max
    frame.xpBar:SetValue(frac)
    W.SetBarOverlay(frame.xpBar, frac, frac + rested / max, T.color.rested)
    local restedText = rested > 0 and ("  ·  " .. Colored(T.color.rested, BreakUpLargeNumbers(rested) .. " rested")) or ""
    frame.xpText:SetText(string.format("%d%%  ·  %s / %s XP", frac * 100, BreakUpLargeNumbers(xp), BreakUpLargeNumbers(max)) .. restedText)
    frame.mini:SetText(string.format("Lv %s  ·  %d%%", C.SafeString(c.level), frac * 100))
  else
    frame.xpBar:SetValue(0)
    frame.xpText:SetText(c.level == GetMaxPlayerLevel() and "Max level" or "XP unavailable")
    frame.mini:SetText("Lv " .. C.SafeString(c.level))
  end
end

-- Lays out quest rows in the scroll area; called on refresh and on resize
local questsCache = {}
function Main.LayoutQuests()
  local content = frame.scroll.content
  local width = frame.scroll:GetWidth()
  if width <= 0 then return end
  ReleaseRows()

  local y = 0
  local function AddRow(text, opts)
    local r = AcquireRow(content)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", content, "TOPLEFT", opts.indent or 0, -y)
    r:SetWidth(width - (opts.indent or 0))
    r.title:SetFont(opts.font or T.font.body, opts.size or T.size.body, "")
    local c = opts.color or T.color.text
    r.title:SetTextColor(c[1], c[2], c[3])
    r.title:ClearAllPoints()
    r.title:SetPoint("TOPLEFT")
    r.title:SetWidth(width - (opts.indent or 0) - (opts.badge and 70 or 0))
    r.title:SetText(text)
    local h = r.title:GetStringHeight()

    r.badge:SetText(opts.badge or "")
    r.badge:ClearAllPoints()
    r.badge:SetPoint("TOPRIGHT", 0, -1)
    if opts.badgeColor then r.badge:SetTextColor(opts.badgeColor[1], opts.badgeColor[2], opts.badgeColor[3]) end

    if opts.progress then
      r.bar:ClearAllPoints()
      r.bar:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -3)
      r.bar:SetWidth(r.title:GetWidth())
      r.bar:SetValue(opts.progress)
      W.SetBarColor(r.bar, opts.progress >= 1 and T.color.good or T.color.accent)
      r.bar:Show()
      h = h + 6
    else
      r.bar:Hide()
    end
    r:SetHeight(h)
    y = y + h + (opts.after or T.space.row)
  end

  if #questsCache == 0 then
    AddRow("Your quest log is empty. Accept a quest to see live objective tracking here.", { color = T.color.muted, size = T.size.small })
  end

  for _, q in ipairs(questsCache) do
    local done, total = 0, #q.objectives
    for _, o in ipairs(q.objectives) do if o.finished then done = done + 1 end end
    local badge, badgeColor
    if q.complete then
      badge, badgeColor = "TURN IN", T.color.good
    elseif total > 0 then
      badge, badgeColor = done .. "/" .. total, T.color.faint
    end
    AddRow(q.title or ("Quest " .. q.questID), { font = T.font.heading, size = 12, badge = badge, badgeColor = badgeColor, after = 3 })

    for _, o in ipairs(q.objectives) do
      local progress
      if o.type == "progressbar" then
        progress = (C.GetProgressBarPercent(q.questID) or 0) / 100
      elseif (o.numRequired or 0) > 1 then
        progress = (o.numFulfilled or 0) / o.numRequired
      end
      local color = o.finished and T.color.faint or T.color.text
      AddRow(o.text or "?", { indent = 10, size = T.size.small, color = color, progress = (not o.finished) and progress or nil, after = 3 })
    end
    y = y + GAP
  end
  content:SetHeight(math.max(1, y))
end

function Main.UpdateFooter()
  local p = ns.char.probe
  if not p then
    frame.footer.text:SetText("Running API diagnostics...")
    return
  end
  local c = p.counts
  local summary = string.format("API check  %s  %s  %s",
    Colored(T.color.good, c.pass .. " ok"),
    Colored(T.color.warn, c.partial .. " partial"),
    Colored(T.color.bad, (c.missing + c.error) .. " failed"))
  frame.footer.text:SetText(summary .. "   " .. Colored(T.color.faint, "details >"))
end

function Main.Refresh()
  if not frame or not frame:IsShown() then return end
  Main.UpdateCharacter()
  if ns.db.ui.minimized then return end
  Main.UpdateLocation()
  if ns.GuideCard then ns.GuideCard.Relayout() end
  questsCache = C.GetQuests()
  local ready = 0
  for _, q in ipairs(questsCache) do if q.complete then ready = ready + 1 end end
  frame.questCount:SetText(ready > 0 and string.format("%d  ·  %d READY", #questsCache, ready) or tostring(#questsCache))
  Main.LayoutQuests()
  Main.UpdateFooter()
end

ns.Listen("INIT", function()
  Create()
  Main.ApplyLayout()
end)
ns.Listen("REFRESH", Main.Refresh)
ns.Listen("PROBE_DONE", Main.Refresh)
ns.Listen("APPLY_LAYOUT", function() Main.ApplyLayout(); Main.Refresh() end)
ns.Listen("TOGGLE_MAIN", function()
  ns.db.ui.shown = not ns.db.ui.shown
  Main.ApplyLayout()
  Main.Refresh()
end)
