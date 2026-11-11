-- Guide window (replaces the P0 overlay and guide card):
--   [Step N] tab + current-step box   what to do right now, ticking off as it completes
--   banner                            guide icon, "1-10 Durotar", progress
--   step list                         every step of the segment, grouped by NPC, numbered
--   footer                            settings button, addon name, resize grip
-- WoW-native styling: Friz Quadrata, Blizzard tooltip panels and quest/gossip icons.
-- Render only: no quest or route logic. Also drives the native waypoint for the current
-- step (ns.db.ui.waypoint) and flashes the box when a current step completes.
local _, ns = ...
local T, W = ns.Theme, ns.Widgets

local Win = {}
ns.GuideWindow = Win

local VERSION = "0.2.0"
local TAB_H = 20
local GAP = 4
local BANNER_H = 44
local FOOTER_H = 24
local RIGHT_COL = 24 -- block numbers in the list

local root, box, tab, main
local lastView
local inCombat = false
local wpKey        -- "map:x:y" of the waypoint we set
local skippedId    -- step skipped with /ln skip (no done-flash for it)
local lastCurrentBlock, userScrolledAt

local Px = W.Px
local function LineH() return math.floor(Px(T.space.line) + 0.5) end
local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
local function Now() return (GetTime and GetTime()) or 0 end

-- Step text ---------------------------------------------------------------------------

local SUBJECT_COLOR = { npc = T.color.mob, item = T.color.item, object = T.color.object }
local SUBJECT_ICON = { npc = T.icon.kill, item = T.icon.loot, object = T.icon.use }
local TYPE_ICON = {
  GOTO = T.icon.travel, ZONE = T.icon.travel, FLY = T.icon.travel, TRANSPORT = T.icon.travel,
  FP_LEARN = T.icon.travel, HEARTH_USE = T.icon.hearth, HEARTH_SET = T.icon.hearth,
  TRAIN = T.icon.train, BUY = T.icon.buy, GRIND = T.icon.kill, COMPLETE = T.icon.kill,
}

-- icon path, text (keywords colored unless dim)
local function RowText(row, dim)
  local function col(c, s) return dim and s or T.Color(c, s) end
  local q = row.quest and row.quest.name or ""
  if row.type == "ACCEPT" then return T.icon.accept, "Accept " .. col(T.color.quest, q) end
  if row.type == "TURNIN" then return T.icon.turnin, "Turn in " .. col(T.color.quest, q) end
  local s = row.subject
  if s then
    return SUBJECT_ICON[s.kind] or T.icon.kill, s.verb .. " " .. col(SUBJECT_COLOR[s.kind] or T.color.mob, s.name)
  end
  if row.type == "COMPLETE" then return T.icon.kill, "Complete " .. col(T.color.quest, q) end
  return TYPE_ICON[row.type] or T.icon.note, row.title or ""
end

-- Coach markers -> colors: {n}NPC{/n} {m}mob{/m} {i}item{/i} {o}object{/o} {q}quest{/q}
local MARKER_COLOR = { n = T.color.npc, m = T.color.mob, i = T.color.item, o = T.color.object, q = T.color.accent }
local function Colorize(s)
  return (s:gsub("{(%a)}(.-){/%1}", function(k, word)
    local c = MARKER_COLOR[k]
    return c and T.Color(c, word) or word
  end))
end

local UP_NEXT = 3 -- blocks shown after the current one while the full route is collapsed
local function FullList() return ns.db and ns.db.ui and ns.db.ui.fullList == true end

local function TalkText(npc, dim)
  return "Talk to " .. (dim and npc or T.Color(T.color.npc, npc))
end

local function ProgressText(row)
  local p = row.progress
  if p and p.max and p.max > 0 then return string.format("%d/%d", p.cur or 0, p.max) end
  return nil
end

-- Line pool -----------------------------------------------------------------------------
-- One line = optional tick circle, icon, text, right-aligned text. Pools are per parent.

local function NewLine(parent)
  local l = CreateFrame("Frame", nil, parent)
  l.check = l:CreateTexture(nil, "ARTWORK")
  l.check:SetTexture(T.icon.radio)
  l.icon = l:CreateTexture(nil, "ARTWORK")
  l.text = W.Text(l, { size = T.size.list, wrap = false })
  l.right = W.Text(l, { font = T.font.numbers, size = T.size.small, color = T.color.faint, justify = "RIGHT", wrap = false })
  l.right:SetPoint("RIGHT", 0, 0)
  return l
end

local function Pool(parent)
  return { parent = parent, lines = {}, n = 0 }
end

local function ReleaseAll(pool)
  for i = 1, #pool.lines do pool.lines[i]:Hide() end
  pool.n = 0
end

-- opts: x, y, width, check (nil = none, false = open, true = ticked), icon, text, color,
--       right, rightColor
local function PlaceLine(pool, o)
  pool.n = pool.n + 1
  local l = pool.lines[pool.n]
  if not l then
    l = NewLine(pool.parent)
    pool.lines[pool.n] = l
  end
  local h = LineH()
  local iconSize = math.floor(Px(T.space.icon) + 0.5)
  l:ClearAllPoints()
  l:SetPoint("TOPLEFT", pool.parent, "TOPLEFT", o.x or 0, -(o.y or 0))
  l:SetSize(o.width, h)

  local x = 0
  if o.check ~= nil then
    local c = iconSize - 2
    l.check:SetSize(c, c)
    l.check:ClearAllPoints()
    l.check:SetPoint("LEFT", 0, 0)
    if o.check then l.check:SetTexCoord(0.25, 0.5, 0, 1) else l.check:SetTexCoord(0, 0.25, 0, 1) end
    l.check:SetDesaturated(o.dim == true)
    l.check:Show()
    x = c + 4
  else
    l.check:Hide()
  end
  if o.icon then
    l.icon:SetTexture(o.icon)
    l.icon:SetSize(iconSize, iconSize)
    l.icon:ClearAllPoints()
    l.icon:SetPoint("LEFT", x, 0)
    l.icon:SetDesaturated(o.dim == true)
    l.icon:SetAlpha(o.dim and 0.6 or 1)
    l.icon:Show()
    x = x + iconSize + 4
  else
    l.icon:Hide()
  end

  l.right:SetText(o.right or "")
  SetColor(l.right, o.rightColor or T.color.faint)
  local rightW = o.right and ((l.right:GetStringWidth() or 0) + 6) or 0
  if o.rightCol then rightW = math.max(rightW, o.rightCol) end

  l.text:ClearAllPoints()
  l.text:SetPoint("LEFT", x, 0)
  l.text:SetWidth(math.max(10, o.width - x - rightW))
  l.text:SetText(o.text or "")
  SetColor(l.text, o.color or T.color.text)
  l:Show()
  return l, h
end

-- Frame -----------------------------------------------------------------------------------

local function StartMove()
  if root and not (ns.db and ns.db.ui.locked) then root:StartMoving() end
end

local function StopMove()
  if not root then return end
  root:StopMovingOrSizing()
  local point, _, relPoint, x, y = root:GetPoint()
  ns.db.ui.point = { point, relPoint, x, y }
end

local function Draggable(f)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", StartMove)
  f:SetScript("OnDragStop", StopMove)
end

local function Create()
  root = CreateFrame("Frame", "LevelingNavigatorFrame", UIParent)
  root:SetFrameStrata("MEDIUM")
  root:SetClampedToScreen(true)
  root:SetMovable(true)
  root:SetResizable(true)
  if root.SetResizeBounds then root:SetResizeBounds(240, 220, 560, 1000) end

  -- Current-step box with its "Step N" tab
  box = W.Panel(root)
  box:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -(TAB_H - 4))
  box:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -(TAB_H - 4))
  box:SetHeight(60)
  Draggable(box)
  box.pool = Pool(box)

  tab = W.Panel(root)
  tab:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 8, -4)
  tab:SetHeight(TAB_H + 2)
  tab:SetFrameLevel(box:GetFrameLevel() + 2)
  Draggable(tab)
  tab.text = W.Text(tab, { font = T.font.heading, size = T.size.small, color = T.color.accent, wrap = false })
  tab.text:SetPoint("CENTER", 0, 0)

  -- Coach text on top of the box (wrapped), divider, then the checklist
  box.coach = W.Text(box, { size = T.size.step })
  box.coach:SetSpacing(2)
  box.coachDiv = W.Divider(box)

  box.callout = W.Text(box, { size = T.size.small, color = T.color.warn })
  box.calloutBtn = CreateFrame("Button", nil, box)
  box.calloutBtn:SetAllPoints(box.callout)
  box.calloutBtn:SetScript("OnClick", function()
    local i = box.calloutIndex
    if i and ns.Guide and ns.Guide.ChooseSuggestion then ns.Guide.ChooseSuggestion(i) end
  end)

  local ok, done = pcall(CreateFrame, "Button", nil, box, "UIPanelButtonTemplate")
  if not ok then done = CreateFrame("Button", nil, box) end
  done:SetSize(64, 20)
  done:SetText("Done")
  done:SetScript("OnClick", function()
    local s = lastView and lastView.current and lastView.current[1]
    if s and ns.Guide and ns.Guide.Confirm then ns.Guide.Confirm(s.id) end
  end)
  done:Hide()
  box.doneBtn = done

  -- Flash when a current step completes
  box.flash = box:CreateTexture(nil, "OVERLAY")
  box.flash:SetPoint("TOPLEFT", 4, -4)
  box.flash:SetPoint("BOTTOMRIGHT", -4, 4)
  local g = T.color.good
  box.flash:SetColorTexture(g[1], g[2], g[3], 1)
  box.flash:SetAlpha(0)
  if box.flash.CreateAnimationGroup then
    local ag = box.flash:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0.25); a:SetToAlpha(0); a:SetDuration(0.7)
    ag:SetScript("OnFinished", function() box.flash:SetAlpha(0) end)
    box.flashAnim = ag
  end

  -- Main panel: banner, list, footer
  main = W.Panel(root)
  main:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -GAP)
  main:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)

  local banner = CreateFrame("Frame", nil, main)
  banner:SetPoint("TOPLEFT", 4, -4)
  banner:SetPoint("TOPRIGHT", -4, -4)
  banner:SetHeight(BANNER_H)
  Draggable(banner)
  banner.bg = banner:CreateTexture(nil, "BACKGROUND")
  banner.bg:SetAllPoints()
  banner.bg:SetColorTexture(1, 1, 1, 0.04)
  banner.icon = banner:CreateTexture(nil, "ARTWORK")
  banner.icon:SetSize(32, 32)
  banner.icon:SetPoint("LEFT", 6, 0)
  banner.icon:SetTexture(T.icon.guide)
  if banner.icon.SetMask then pcall(banner.icon.SetMask, banner.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  banner.title = W.Text(banner, { font = T.font.heading, size = T.size.title, justify = "CENTER", wrap = false })
  banner.title:SetPoint("TOPLEFT", banner.icon, "TOPRIGHT", 4, -1)
  banner.title:SetPoint("RIGHT", banner, "RIGHT", -8, 0)
  banner.sub = W.Text(banner, { font = T.font.heading, size = T.size.small, color = T.color.accent, justify = "CENTER", wrap = false })
  banner.sub:SetPoint("TOPLEFT", banner.title, "BOTTOMLEFT", 0, -3)
  banner.sub:SetPoint("RIGHT", banner, "RIGHT", -8, 0)
  main.banner = banner

  local footer = CreateFrame("Frame", nil, main)
  footer:SetPoint("BOTTOMLEFT", 4, 4)
  footer:SetPoint("BOTTOMRIGHT", -4, 4)
  footer:SetHeight(FOOTER_H)
  footer.bg = footer:CreateTexture(nil, "BACKGROUND")
  footer.bg:SetAllPoints()
  footer.bg:SetColorTexture(1, 1, 1, 0.04)
  footer.options = W.IconButton(footer, T.icon.options, 18, function() ns.Send("SHOW_SETTINGS") end)
  footer.options:SetPoint("LEFT", 4, 0)
  footer.text = W.Text(footer, { font = T.font.heading, size = T.size.tag, color = T.color.accent, wrap = false })
  footer.text:SetPoint("LEFT", footer.options, "RIGHT", 6, 0)
  footer.text:SetText("Leveling Navigator v" .. VERSION)
  -- Up next <-> full route
  footer.listBtn = W.TextButton(footer, "FULL ROUTE", function()
    ns.db.ui.fullList = not FullList()
    lastCurrentBlock = nil
    if FullList() then root:SetHeight(ns.db.ui.height) end
    Win.Render()
  end)
  W.SetFont(footer.listBtn.text, T.font.heading, T.size.tag)
  footer.listBtn:SetSize(84, 18)
  footer.listBtn:SetPoint("RIGHT", -16, 0)
  local grip = CreateFrame("Button", nil, footer)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", 0, 0)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() if not ns.db.ui.locked then root:StartSizing("BOTTOMRIGHT") end end)
  grip:SetScript("OnMouseUp", function()
    root:StopMovingOrSizing()
    local w, h = root:GetSize()
    ns.db.ui.width = w
    if FullList() then ns.db.ui.height = h end -- collapsed: height follows the content
    StopMove()
    Win.Render()
  end)
  footer.grip = grip
  main.footer = footer

  -- XP line under the banner: "Level 5   1,234 / 2,800 XP (44%)   +300 rested" + thin bar
  local xp = CreateFrame("Frame", nil, main)
  xp:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 6, -4)
  xp:SetPoint("TOPRIGHT", banner, "BOTTOMRIGHT", -6, -4)
  xp:SetHeight(20)
  xp.text = W.Text(xp, { size = T.size.small, wrap = false })
  xp.text:SetPoint("TOPLEFT", 0, 0)
  xp.text:SetPoint("RIGHT", xp, "RIGHT", 0, 0)
  xp.bar = W.Bar(xp, 5, T.color.xp)
  xp.bar:SetPoint("BOTTOMLEFT", 0, 0)
  xp.bar:SetPoint("BOTTOMRIGHT", 0, 0)
  main.xp = xp

  -- Step list with scroll arrows on the right
  local scroll = W.ScrollArea(main)
  scroll:SetPoint("TOPLEFT", xp, "BOTTOMLEFT", 0, -6)
  scroll:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", -22, 4)
  scroll:HookScript("OnMouseWheel", function() userScrolledAt = Now() end)
  main.scroll = scroll
  main.pool = Pool(scroll.content)
  main.highlight = scroll.content:CreateTexture(nil, "BACKGROUND")
  local hc = T.color.current
  main.highlight:SetColorTexture(hc[1], hc[2], hc[3], hc[4])
  main.highlightBar = scroll.content:CreateTexture(nil, "BORDER")
  main.highlightBar:SetColorTexture(hc[1], hc[2], hc[3], 0.9)
  main.highlightBar:SetWidth(2)

  local function ScrollBy(delta)
    local max = math.max(0, scroll.content:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.max(0, math.min(max, scroll:GetVerticalScroll() + delta)))
    userScrolledAt = Now()
  end
  local up = W.IconButton(main, T.icon.scrollUp, 24, function() ScrollBy(-LineH() * 4) end)
  up:SetPoint("TOPRIGHT", main.scroll, "TOPRIGHT", 24, 2)
  local down = W.IconButton(main, T.icon.scrollDown, 24, function() ScrollBy(LineH() * 4) end)
  down:SetPoint("BOTTOMRIGHT", main.scroll, "BOTTOMRIGHT", 24, -2)
  main.up, main.down = up, down

  root:SetScript("OnSizeChanged", function() if not Win.sizing then Win.Render() end end)
end

-- XP line ---------------------------------------------------------------------------------

local function XPShown() return not (ns.db and ns.db.ui and ns.db.ui.xpBar == false) end

local function Num(n)
  if type(BreakUpLargeNumbers) == "function" then
    local ok, s = pcall(BreakUpLargeNumbers, n)
    if ok and s then return s end
  end
  return tostring(n)
end

function Win.UpdateXP()
  if not (main and main.xp) then return end
  local xp = main.xp
  local show = XPShown()
  xp:SetShown(show)
  -- the list starts under the XP line when it is shown, else right under the banner
  main.scroll:ClearAllPoints()
  main.scroll:SetPoint("TOPLEFT", show and xp or main.banner, "BOTTOMLEFT", show and 0 or 6, -6)
  main.scroll:SetPoint("BOTTOMRIGHT", main.footer, "TOPRIGHT", -22, 4)
  if not show then return end

  local C = ns.Compat
  local c = C and C.GetCharacter() or {}
  local level = C and C.SafeString(c.level) or "?"
  local cur, max, rested = c.xp, c.xpMax, c.rested or 0
  local readable = type(cur) == "number" and type(max) == "number" and max > 0
    and not (C.IsSecret(cur) or C.IsSecret(max))
  local maxLevel = type(GetMaxPlayerLevel) == "function" and GetMaxPlayerLevel() or 60

  if readable and c.level ~= maxLevel then
    local frac = cur / max
    local text = T.Color(T.color.accent, "Level " .. level) .. "   " .. Num(cur) .. " / " .. Num(max)
      .. string.format(" XP (%d%%)", math.floor(frac * 100))
    if type(rested) == "number" and rested > 0 then
      text = text .. "   " .. T.Color(T.color.rested, "+" .. Num(rested) .. " rested")
    end
    xp.text:SetText(text)
    Win.lastXPText = text
    xp.bar:SetValue(frac)
    W.SetBarOverlay(xp.bar, frac, frac + (type(rested) == "number" and rested or 0) / max, T.color.rested)
  else
    xp.text:SetText(T.Color(T.color.accent, "Level " .. level) .. (c.level == maxLevel and "   Max level" or ""))
    xp.bar:SetValue(c.level == maxLevel and 1 or 0)
    W.SetBarOverlay(xp.bar, 0, 0, T.color.rested)
  end
end

-- Rendering -----------------------------------------------------------------------------

local function ZoneTitle(view)
  local seg = view.route and view.route.segment or {}
  local lv = seg.levels
  local levels = (type(lv) == "table" and lv[1] and lv[2]) and (lv[1] .. "-" .. lv[2] .. " ") or ""
  local title = seg.title
  -- generated routes use their id as title ("baseline.start.1411"): show the zone instead
  if not title or title:find("%.") then
    local t = view.current and view.current[1] and view.current[1].target
    local map = t and t.map
    if not map and ns.Compat then map = ns.Compat.GetPlayerPosition() end
    title = (map and ns.Compat and ns.Compat.GetMapName(map)) or "Leveling route"
  end
  return levels .. title
end

-- One subtle line under the box: first suggestion, else first warning
local function Callout(view)
  local s = view.suggestions and view.suggestions[1]
  if s then
    if s.kind == "deathskip" then
      local t = "Death skip available"
      if s.saves then t = t .. string.format(" (saves ~%d min)", math.max(1, math.floor(s.saves / 60 + 0.5))) end
      return t, T.color.accent, 1
    elseif s.kind == "segment" and s.to then
      return "Switch to " .. s.to .. (s.reason and (": " .. s.reason) or "") .. "  >", T.color.accent, 1
    end
  end
  local w = view.warnings and view.warnings[1]
  if w then return w, T.color.warn end
  return nil
end

local function RenderBox(view, blocks, curIndex, width)
  local pool = box.pool
  ReleaseAll(pool)
  local pad = 10
  local inner = width - 2 * pad
  local y = pad + 2
  local block = curIndex and blocks[curIndex]
  if not block then box.coach:Hide(); box.coachDiv:Hide() end

  if not view then
    tab.text:SetText("Guide")
    local enabled = not (ns.db and ns.db.guideEnabled == false)
    local _, h = PlaceLine(pool, { x = pad, y = y, width = inner, icon = T.icon.note,
      text = enabled and "No route for this character yet." or "The guide is off. Turn it on in Settings.",
      color = T.color.muted })
    y = y + h
  elseif block then
    tab.text:SetText("Step " .. block.number)
    local B = ns.GuideBlocks
    -- Coach: what to do, where, what to combine, what's next
    local lines = ns.GuideCoach and ns.GuideCoach.Lines(view, blocks, curIndex) or {}
    if #lines > 0 then
      box.coach:SetText(Colorize(table.concat(lines, "\n")))
      box.coach:ClearAllPoints()
      box.coach:SetPoint("TOPLEFT", box, "TOPLEFT", pad, -y)
      box.coach:SetWidth(inner)
      box.coach:Show()
      y = y + box.coach:GetStringHeight() + 6
      box.coachDiv:ClearAllPoints()
      box.coachDiv:SetPoint("TOPLEFT", box, "TOPLEFT", pad, -y)
      box.coachDiv:SetPoint("RIGHT", box, "RIGHT", -pad, 0)
      box.coachDiv:Show()
      y = y + 6
      Win.lastCoach = lines
    else
      box.coach:Hide(); box.coachDiv:Hide()
    end
    if block.kind == "talk" then
      local _, h = PlaceLine(pool, { x = pad, y = y, width = inner, icon = T.icon.talk, text = TalkText(block.npc) })
      y = y + h
    end
    local shown = {}
    for _, row in ipairs(block.rows) do
      local fin = B.IsFinished(row)
      local icon, text = RowText(row, false)
      local _, h = PlaceLine(pool, { x = pad, y = y, width = inner, check = fin, icon = icon, text = text,
        right = ProgressText(row), rightColor = fin and T.color.good or T.color.text })
      y = y + h
      shown[row.id] = true
    end
    -- Concurrent steps outside this block (open objectives of other quests nearby)
    for k = 2, #(view.current or {}) do
      local s = view.current[k]
      if not shown[s.id] then
        local icon, text = RowText(s, false)
        local _, h = PlaceLine(pool, { x = pad, y = y, width = inner, check = false, icon = icon, text = text,
          right = ProgressText(s), rightColor = T.color.text })
        y = y + h
      end
    end
  else
    tab.text:SetText("Guide")
    local _, h = PlaceLine(pool, { x = pad, y = y, width = inner, icon = T.icon.note,
      text = "Route finished for this segment.", color = T.color.muted })
    y = y + h
  end

  -- Callout (warning or clickable suggestion)
  local cText, cColor, cIndex = nil, nil, nil
  if view then cText, cColor, cIndex = Callout(view) end
  box.calloutIndex = cIndex
  if cText then
    y = y + 2
    box.callout:SetText(cText)
    SetColor(box.callout, cColor)
    box.callout:ClearAllPoints()
    box.callout:SetPoint("TOPLEFT", box, "TOPLEFT", pad, -y)
    box.callout:SetWidth(inner)
    box.callout:Show()
    box.calloutBtn:SetShown(cIndex ~= nil)
    y = y + box.callout:GetStringHeight() + 2
  else
    box.callout:Hide(); box.calloutBtn:Hide()
  end

  local primary = view and view.current and view.current[1]
  if primary and primary.manualConfirm then
    box.doneBtn:ClearAllPoints()
    box.doneBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", -pad, -y - 2)
    box.doneBtn:Show()
    y = y + 26
  else
    box.doneBtn:Hide()
  end

  tab:SetWidth(math.max(56, (tab.text:GetStringWidth() or 0) + 22))
  box:SetHeight(math.floor(y + pad + 0.5))
end

local function RenderList(view, blocks, curIndex, width)
  local pool = main.pool
  ReleaseAll(pool)
  local scroll = main.scroll
  local content = scroll.content
  local B = ns.GuideBlocks
  local y, curTop, curBottom = 0, nil, nil
  local hideHighlight = true

  -- Collapsed (default): only the next few blocks after the current one, no finished ones
  local shown = blocks
  if not FullList() then
    shown = {}
    local from = (curIndex or 0) + 1
    for i = from, #blocks do
      if not blocks[i].done then shown[#shown + 1] = blocks[i] end
      if #shown >= UP_NEXT then break end
    end
    local _, h = PlaceLine(pool, { x = 0, y = 0, width = width, text = "UP NEXT", color = T.color.accent })
    y = h + 2
  end

  for _, b in ipairs(shown) do
    local top = y
    local dim = b.done
    local num = tostring(b.number)
    local first = true
    local function numberCol()
      if first then first = false; return num end
      return nil
    end
    if b.kind == "talk" then
      local _, h = PlaceLine(pool, { x = 0, y = y, width = width, icon = T.icon.talk, dim = dim,
        text = TalkText(b.npc, dim), color = dim and T.color.done or T.color.text,
        right = numberCol(), rightCol = RIGHT_COL })
      y = y + h
    end
    for _, row in ipairs(b.rows) do
      local fin = B.IsFinished(row)
      local icon, text = RowText(row, dim or fin)
      local prog = ProgressText(row)
      local right = numberCol()
      if prog and not right then right = prog end
      local _, h = PlaceLine(pool, { x = b.kind == "talk" and 10 or 0, y = y, width = width - (b.kind == "talk" and 10 or 0),
        icon = icon, dim = dim or fin, text = text, color = (dim or fin) and T.color.done or T.color.text,
        right = right, rightColor = T.color.faint, rightCol = RIGHT_COL })
      y = y + h
    end
    if b.current then
      curTop, curBottom = top, y
      hideHighlight = false
    end
    y = y + math.floor(Px(6) + 0.5)
  end

  if #shown == 0 then
    local _, h = PlaceLine(pool, { x = 0, y = y, width = width, text = "Nothing else in this zone.", color = T.color.muted })
    y = y + h
  end

  if hideHighlight then
    main.highlight:Hide(); main.highlightBar:Hide()
  else
    main.highlight:ClearAllPoints()
    main.highlight:SetPoint("TOPLEFT", content, "TOPLEFT", -4, -(curTop - 2))
    main.highlight:SetSize(width + 8, curBottom - curTop + 4)
    main.highlight:Show()
    main.highlightBar:ClearAllPoints()
    main.highlightBar:SetPoint("TOPLEFT", main.highlight, "TOPLEFT", 0, 0)
    main.highlightBar:SetHeight(curBottom - curTop + 4)
    main.highlightBar:Show()
  end
  content:SetHeight(math.max(1, y))
  if not FullList() then
    scroll:SetVerticalScroll(0)
    return y
  end

  -- Keep the current block at the top, unless the player scrolled in the last 8 seconds
  if curTop and curIndex ~= lastCurrentBlock and not (userScrolledAt and Now() - userScrolledAt < 8) then
    local max = math.max(0, content:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.max(0, math.min(max, curTop - 4)))
    lastCurrentBlock = curIndex
  end
  return y
end

function Win.Render()
  if not (root and root:IsShown()) then return end
  local width = root:GetWidth()
  if not width or width <= 0 then return end
  local view = lastView
  local blocks, curIndex = {}, nil
  if view and ns.GuideBlocks then blocks, curIndex = ns.GuideBlocks.Build(view.list, view.primaryId) end

  RenderBox(view, blocks, curIndex, width)

  local banner = main.banner
  if view then
    banner.title:SetText(ZoneTitle(view))
    local p = view.route and view.route.progress
    banner.sub:SetText(p and p.total and p.total > 0 and string.format("%d of %d steps done", p.done or 0, p.total) or "")
  else
    banner.title:SetText("Leveling Navigator")
    banner.sub:SetText("")
  end

  local listWidth = main.scroll:GetWidth()
  local listH
  if listWidth and listWidth > 0 then listH = RenderList(view, blocks, curIndex, listWidth) end

  -- Collapsed list: the window fits its content. Full route: the height the player chose.
  local want = ns.db.ui.height
  if not FullList() and listH then
    local xpH = (main.xp and main.xp:IsShown()) and 24 or 0
    local mainH = 4 + BANNER_H + xpH + 6 + listH + 6 + FOOTER_H + 8
    want = (TAB_H - 4) + box:GetHeight() + GAP + mainH
  end
  if math.abs((root:GetHeight() or 0) - want) > 0.5 and not Win.sizing then
    Win.sizing = true -- SetHeight fires OnSizeChanged -> Render; don't recurse
    root:SetHeight(want)
    Win.sizing = false
  end
  main.footer.listBtn.text:SetText(FullList() and "UP NEXT ONLY" or "FULL ROUTE")
  main.up:SetShown(FullList()); main.down:SetShown(FullList())
  -- what was drawn (offline smoke test, /ln debugging)
  Win.lastStats = { blocks = #blocks, current = curIndex, boxLines = box.pool.n, listLines = main.pool.n,
                    title = banner.title:GetText(), tab = tab.text:GetText() }
end

-- Native waypoint -------------------------------------------------------------------------

local function WaypointEnabled()
  return not (ns.db and ns.db.ui and ns.db.ui.waypoint == false)
end

function Win.WaypointEligible(t)
  if not (t and t.map and t.x and t.y) or t.label == "U" then return false end
  local C = ns.Compat
  if C and C.CanSetWaypoint and not C.CanSetWaypoint(t.map) then return false end
  return true
end

-- Sets the waypoint when the current target changes; clears ours when the guide ends,
-- the target becomes unknown, or waypoints are turned off in Settings.
function Win.UpdateWaypoint()
  local C = ns.Compat
  if not (C and C.SetWaypoint) then return end
  local step = lastView and lastView.current and lastView.current[1]
  local t = step and step.target
  if WaypointEnabled() and Win.WaypointEligible(t) then
    local key = t.map .. ":" .. t.x .. ":" .. t.y
    if key ~= wpKey then
      wpKey = key -- remembered even if the call fails, so it is not retried every update
      C.SetWaypoint(t.map, t.x, t.y)
    end
  elseif wpKey then
    wpKey = nil
    if C.ClearWaypoint then C.ClearWaypoint() end
  end
end

-- Layout, visibility, combat ----------------------------------------------------------------

local function PanelAlpha()
  local ui = ns.db.ui
  if inCombat then return math.min(ui.alpha, tonumber(ui.combatAlpha) or 0.6) end
  return ui.alpha
end

function Win.ApplyLayout()
  if not root then return end
  local ui = ns.db.ui
  W.SetFontScale(ui.fontScale)
  root:ClearAllPoints()
  root:SetPoint(ui.point[1], UIParent, ui.point[2], ui.point[3], ui.point[4])
  root:SetScale(ui.scale)
  root:SetAlpha(PanelAlpha())
  root:SetSize(ui.width, ui.height)
  main.footer.grip:SetShown(not ui.locked)
  root:SetShown(ui.shown)
  Win.UpdateXP()
  Win.Render()
end

function Win.SetShown(shown)
  ns.db.ui.shown = shown
  root:SetShown(shown)
  if shown then Win.Render() else ns.Print("Hidden. Type /ln to show it again.") end
end

local function SetCombat(on)
  inCombat = on and true or false
  if root then root:SetAlpha(PanelAlpha()) end
end

-- `/ln skip`: skips the current step. Returns its title.
function Win.SkipCurrent()
  local step = lastView and lastView.current and lastView.current[1]
  if not (step and ns.Guide and ns.Guide.Skip) then return nil end
  skippedId = step.id
  ns.Guide.Skip(step.id)
  return step.title or step.id
end

local function InCurrent(view, id)
  for _, s in ipairs(view and view.current or {}) do
    if s.id == id then return true end
  end
  return false
end

local function OnStepDone(event)
  local id = type(event) == "table" and event.stepId or nil
  if id == nil or id == skippedId then return end
  if InCurrent(lastView, id) and box and box.flashAnim then
    box.flashAnim:Stop()
    box.flashAnim:Play()
  end
end

function Win.OnView(view)
  if skippedId ~= nil and not InCurrent(view, skippedId) then skippedId = nil end
  lastView = view
  Win.Render()
  Win.UpdateWaypoint()
end

ns.Listen("INIT", function()
  -- First load of the new window: its own default size, and visible. The old overlay had a
  -- close button; a "hidden" flag left over from it hid the new window, which has no close
  -- button, with no visible way back except /ln (first in-game test, 2026-11-10).
  local ui = ns.db.ui
  if not ui.guideWindowV3 then
    ui.guideWindowV3 = true
    ui.guideWindowV2 = nil
    ui.width, ui.height = 300, 460
    ui.shown = true
  end
  Create()
  Win.ApplyLayout()
  if InCombatLockdown and InCombatLockdown() then SetCombat(true) end
end)
ns.Listen("GUIDE_UPDATED", Win.OnView)
-- Core/Init.lua coalesces PLAYER_XP_UPDATE / PLAYER_LEVEL_UP / UPDATE_EXHAUSTION into REFRESH
ns.Listen("REFRESH", function() Win.UpdateXP() end)
ns.Listen("STEP_DONE", OnStepDone)
ns.Listen("APPLY_LAYOUT", Win.ApplyLayout)
ns.Listen("TOGGLE_MAIN", function()
  ns.db.ui.shown = not ns.db.ui.shown
  Win.ApplyLayout()
end)
if ns.On then
  ns.On("PLAYER_REGEN_DISABLED", function() SetCombat(true) end)
  ns.On("PLAYER_REGEN_ENABLED", function() SetCombat(false) end)
end
