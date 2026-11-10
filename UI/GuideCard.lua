-- Guide "current step" card: renders a GuideView (docs/P2_GUIDE_ENGINE_SPEC.md 7.2).
-- Compact by default (title, progress, target, 2 upcoming); MORE/LESS toggles
-- expanded mode (detail, why, badges, concurrent rows, 3 upcoming), persisted in
-- ns.db.ui.cardExpanded.
-- Render only: no quest or route logic. User actions go to ns.Guide.Confirm/Skip.
-- MainPanel attaches the card above "Current quests"; with no view it is hidden and
-- the overlay looks exactly as before.
local _, ns = ...
local T, W = ns.Theme, ns.Widgets

local Card = {}
ns.GuideCard = Card

local GAP = T.space.gap
local MAX_UPCOMING = 3         -- expanded mode
local MAX_UPCOMING_COMPACT = 2 -- compact mode (default while a guide is active)
local ROW_H = 16

local card, onLayout
local lastView      -- most recent GuideView (may arrive before the card exists)
local dirty = true  -- view changed since the last layout
local lastWidth = 0

-- Compact unless the user expanded the card (ns.db.ui.cardExpanded; nil = false)
local function Expanded()
  return ns.db and ns.db.ui and ns.db.ui.cardExpanded == true or false
end

-- Step types -----------------------------------------------------------------

local S = T.step
local TYPES = {
  ACCEPT     = { "ACCEPT", S.accept },
  OBJECTIVE  = { "OBJECTIVE", S.objective },
  COMPLETE   = { "COMPLETE", S.objective },
  KILL       = { "KILL", S.objective },
  TURNIN     = { "TURN IN", S.turnin },
  GRIND      = { "GRIND", S.grind },
  GOTO       = { "GO TO", S.travel },
  ZONE       = { "GO TO", S.travel },
  FLY        = { "FLY", S.travel },
  TRANSPORT  = { "TRAVEL", S.travel },
  HEARTH_USE = { "HEARTH", S.travel },
  HEARTH_SET = { "SET HEARTH", S.train },
  FP_LEARN   = { "FLIGHT PATH", S.train },
  TRAIN      = { "TRAIN", S.train },
  BUY        = { "BUY", S.train },
  DEATHSKIP  = { "DEATH SKIP", S.deathskip },
  ABANDON    = { "ABANDON", S.other },
  NOTE       = { "NOTE", S.other },
}
local UNKNOWN_TYPE = { "STEP", S.other }

local function TypeInfo(t) return TYPES[t or ""] or UNKNOWN_TYPE end

local BADGES = {
  optional = "OPTIONAL",
  speedrun = "SPEEDRUN",
  ["approx-location"] = "APPROX. LOCATION",
}

-- Small helpers --------------------------------------------------------------

local function SetColor(fs, c, a) fs:SetTextColor(c[1], c[2], c[3], a or c[4] or 1) end

-- Tag text with a tinted background sized to the text
local function CreateChip(parent)
  local chip = {}
  chip.text = W.Text(parent, { font = T.font.heading, size = T.size.tag, wrap = false })
  chip.bg = parent:CreateTexture(nil, "ARTWORK")
  chip.bg:SetPoint("TOPLEFT", chip.text, "TOPLEFT", -4, 3)
  chip.bg:SetPoint("BOTTOMRIGHT", chip.text, "BOTTOMRIGHT", 4, -3)
  return chip
end

local function SetChip(chip, stepType)
  local info = TypeInfo(stepType)
  local c = info[2]
  chip.text:SetText(info[1])
  SetColor(chip.text, c)
  chip.bg:SetColorTexture(c[1], c[2], c[3], T.color.chip)
end

-- Compact action button. `framed` draws a surface pill (primary action).
local function ActionButton(parent, label, framed, color, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(ROW_H)
  if framed then W.Skin(b, T.color.surface) end
  b.text = W.Text(b, { font = T.font.heading, size = T.size.tag, justify = "CENTER", wrap = false })
  b.text:SetPoint("CENTER", 0, 0)
  b.text:SetText(label)
  b.color = color
  SetColor(b.text, color)
  b:SetWidth(math.max(28, (b.text:GetStringWidth() or 0) + 16))
  b:SetScript("OnEnter", function() SetColor(b.text, T.color.text) end)
  b:SetScript("OnLeave", function() SetColor(b.text, b.color) end)
  b:SetScript("OnClick", onClick)
  return b
end

-- Target line: label-aware ("O"/"V" normal, "E" approximate and muted, "U" unknown)
local function FormatTarget(target)
  if not target then return nil end
  local label = target.label
  if label == "U" or not (target.x and target.y) then
    return "location unknown", T.color.faint
  end
  local approx = label == "E"
  local parts = {}
  if approx then parts[#parts + 1] = "approx." end
  if target.name then parts[#parts + 1] = target.name end
  parts[#parts + 1] = string.format("%.1f, %.1f", target.x, target.y)
  if target.distance then
    parts[#parts + 1] = string.format(approx and "~%d yd" or "%d yd", target.distance)
  end
  return table.concat(parts, "  ·  "), approx and T.color.muted or T.color.text
end

local function FormatBadges(badges, target)
  if not badges or #badges == 0 then return nil end
  local out = {}
  for _, b in ipairs(badges) do
    -- the target line already says "approx." for E locations
    if not (b == "approx-location" and target and target.label == "E") then
      out[#out + 1] = BADGES[b] or tostring(b):upper()
    end
  end
  if #out == 0 then return nil end
  return table.concat(out, "  ·  ")
end

local function FormatProgress(p)
  if not p or not p.max or p.max <= 0 then return nil end
  return string.format("%d / %d", p.cur or 0, p.max), math.min(1, (p.cur or 0) / p.max)
end

-- One subtle line: first suggestion, else first warning
local function FormatCallout(view)
  local s = view.suggestions and view.suggestions[1]
  if s then
    local text
    if s.kind == "deathskip" then
      text = "Death skip available"
      if s.saves then
        text = text .. string.format("  ·  saves ~%d min (estimated)", math.max(1, math.floor(s.saves / 60 + 0.5)))
      end
    elseif s.kind == "segment" and s.to then
      text = "Suggestion: switch to " .. s.to
      if s.reason then text = text .. "  ·  " .. s.reason end
    else
      text = "Suggestion: " .. tostring(s.text or s.reason or s.kind or "")
    end
    return text, T.color.accent, 1
  end
  local w = view.warnings and view.warnings[1]
  if w then
    local more = #view.warnings - 1
    return w .. (more > 0 and string.format("  (+%d more)", more) or ""), T.color.warn
  end
  return nil
end

-- Row pool (concurrent + upcoming) -------------------------------------------

local rows, rowCount = {}, 0

local function AcquireRow()
  rowCount = rowCount + 1
  local r = rows[rowCount]
  if not r then
    r = CreateFrame("Frame", nil, card)
    r:SetHeight(ROW_H)
    r.tag = W.Text(r, { font = T.font.heading, size = T.size.tag, wrap = false })
    r.tag:SetPoint("LEFT", 0, 0)
    r.title = W.Text(r, { size = T.size.small, wrap = false })
    r.title:SetPoint("LEFT", T.space.tagCol, 0)
    r.right = W.Text(r, { size = T.size.small, color = T.color.faint, justify = "RIGHT", wrap = false })
    r.right:SetPoint("RIGHT", 0, 0)
    rows[rowCount] = r
  end
  r:Show()
  return r
end

local function ReleaseRows()
  for i = 1, #rows do rows[i]:Hide() end
  rowCount = 0
end

-- Card frame -----------------------------------------------------------------

local function CurrentStep()
  return lastView and lastView.current and lastView.current[1]
end

local function Create(parent)
  card = CreateFrame("Frame", nil, parent)
  card:SetHeight(1)
  card:Hide()

  card.segTitle = W.Text(card, { font = T.font.heading, size = T.size.heading, color = T.color.muted, wrap = false })
  card.segCount = W.Text(card, { font = T.font.heading, size = T.size.heading, color = T.color.faint, justify = "RIGHT", wrap = false })
  card.segBar = W.Bar(card, 3, T.color.accent)

  -- Compact / expanded toggle on the card header (persisted in ns.db.ui.cardExpanded)
  card.toggleBtn = ActionButton(card, "MORE", false, T.color.faint, function()
    if not (ns.db and ns.db.ui) then return end
    ns.db.ui.cardExpanded = not Expanded()
    dirty = true
    Card.Relayout()
  end)

  card.chip = CreateChip(card)
  card.doneBtn = ActionButton(card, "DONE", true, T.color.good, function()
    local step = CurrentStep()
    if step and ns.Guide and ns.Guide.Confirm then ns.Guide.Confirm(step.id) end
  end)
  card.skipBtn = ActionButton(card, "SKIP", false, T.color.faint, function()
    local step = CurrentStep()
    if step and ns.Guide and ns.Guide.Skip then ns.Guide.Skip(step.id) end
  end)

  card.title = W.Text(card, { font = T.font.heading, size = T.size.step })
  card.detail = W.Text(card, { size = T.size.small, color = T.color.muted })
  card.why = W.Text(card, { size = T.size.small, color = T.color.faint })
  card.progBar = W.Bar(card, 4, T.color.accent)
  card.progText = W.Text(card, { size = T.size.small, color = T.color.muted, justify = "RIGHT", wrap = false })
  card.target = W.Text(card, { size = T.size.small, wrap = false })
  card.badges = W.Text(card, { font = T.font.heading, size = T.size.tag, color = T.color.faint, wrap = false })

  card.nextLabel = W.Label(card, "Up next")

  card.calloutStripe = card:CreateTexture(nil, "ARTWORK")
  card.calloutStripe:SetWidth(2)
  card.callout = W.Text(card, { size = T.size.small })
  -- Click target over the callout; only shown when it presents a suggestion
  card.calloutBtn = CreateFrame("Button", nil, card)
  card.calloutBtn:SetPoint("TOPLEFT", card.calloutStripe, "TOPLEFT", 0, 0)
  card.calloutBtn:SetPoint("BOTTOMRIGHT", card.callout, "BOTTOMRIGHT", 0, 0)
  card.calloutBtn:SetScript("OnEnter", function() SetColor(card.callout, T.color.text) end)
  card.calloutBtn:SetScript("OnLeave", function() SetColor(card.callout, T.color.muted) end)
  card.calloutBtn:SetScript("OnClick", function()
    local i = card.calloutIndex
    if i and ns.Guide and ns.Guide.ChooseSuggestion then ns.Guide.ChooseSuggestion(i) end
  end)
  card.calloutBtn:Hide()

  card.divider = W.Divider(card)

  card:SetScript("OnSizeChanged", function() Card.Relayout() end)
end

-- Positions a region at a vertical offset, full width or with a given width
local function Place(region, y, x, width)
  region:ClearAllPoints()
  region:SetPoint("TOPLEFT", card, "TOPLEFT", x or 0, -y)
  if width then region:SetWidth(width) end
end

local function Layout(width)
  local view = lastView
  local expanded = Expanded()
  ReleaseRows()
  local y = 0

  -- Segment header: "VALLEY OF TRIALS ........ 14 / 52"
  local route = view.route or {}
  local seg = route.segment or {}
  card.segTitle:SetText(((seg.title or route.title or "Guide")):upper())
  Place(card.segTitle, y, 0, width - 120)
  card.toggleBtn.text:SetText(expanded and "LESS" or "MORE")
  card.toggleBtn:ClearAllPoints()
  card.toggleBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", 6, -y + 3)
  card.toggleBtn:Show()
  local prog = route.progress
  card.segCount:ClearAllPoints()
  card.segCount:SetPoint("TOPRIGHT", card.toggleBtn, "TOPLEFT", -2, -3)
  if prog and prog.total and prog.total > 0 then
    card.segCount:SetText(string.format("%d / %d", prog.done or 0, prog.total))
    y = y + 14
    Place(card.segBar, y, 0, width)
    card.segBar:SetValue(math.min(1, (prog.done or 0) / prog.total))
    card.segBar:Show()
    y = y + 3 + GAP + 4
  else
    card.segCount:SetText("")
    card.segBar:Hide()
    y = y + 14 + GAP
  end

  -- Primary step
  local step = view.current and view.current[1]
  if step then
    -- tag chip (left) and actions (right) share one line
    SetChip(card.chip, step.type)
    Place(card.chip.text, y + 3, 4)
    card.chip.text:Show(); card.chip.bg:Show()

    card.skipBtn:ClearAllPoints()
    card.skipBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -y)
    card.skipBtn:Show()
    if step.manualConfirm then
      card.doneBtn:ClearAllPoints()
      card.doneBtn:SetPoint("RIGHT", card.skipBtn, "LEFT", -4, 0)
      card.doneBtn:Show()
    else
      card.doneBtn:Hide()
    end
    y = y + ROW_H + 6

    card.title:SetText(step.title or "")
    Place(card.title, y, 0, width)
    y = y + card.title:GetStringHeight() + 3

    if expanded and step.detail and step.detail ~= "" then
      card.detail:SetText(step.detail)
      Place(card.detail, y, 0, width)
      card.detail:Show()
      y = y + card.detail:GetStringHeight() + 3
    else
      card.detail:Hide()
    end

    if expanded and step.why and step.why ~= "" then
      card.why:SetText(step.why)
      Place(card.why, y, 0, width)
      card.why:Show()
      y = y + card.why:GetStringHeight() + 3
    else
      card.why:Hide()
    end

    local pText, pFrac = FormatProgress(step.progress)
    if pText then
      y = y + 3
      card.progText:SetText(pText)
      card.progText:ClearAllPoints()
      card.progText:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -(y - 4))
      Place(card.progBar, y, 0, width - 56)
      card.progBar:SetValue(pFrac)
      W.SetBarColor(card.progBar, pFrac >= 1 and T.color.good or T.color.accent)
      card.progBar:Show(); card.progText:Show()
      y = y + 4 + 6
    else
      card.progBar:Hide(); card.progText:Hide()
    end

    local tText, tColor = FormatTarget(step.target)
    if tText then
      card.target:SetText(tText)
      SetColor(card.target, tColor)
      Place(card.target, y, 0, width)
      card.target:Show()
      y = y + 14
    else
      card.target:Hide()
    end

    local bText = expanded and FormatBadges(step.badges, step.target)
    if bText then
      card.badges:SetText(bText)
      Place(card.badges, y + 1, 0, width)
      card.badges:Show()
      y = y + 13
    else
      card.badges:Hide()
    end

    -- Concurrent steps: same hub, do alongside the primary step
    local nCurrent = expanded and view.current and #view.current or 0
    if nCurrent > 1 then y = y + 4 end
    for i = 2, nCurrent do
      local s = view.current[i]
      local r = AcquireRow()
      local info = TypeInfo(s.type)
      r.tag:SetText(info[1]); SetColor(r.tag, info[2])
      r.title:SetText(s.title or "")
      -- label-aware: E/U targets read muted and say so on the right
      local label = s.target and s.target.label
      local loc = (label == "U" and "loc. unknown") or (label == "E" and "approx.") or nil
      SetColor(r.title, loc and T.color.muted or T.color.text)
      local right = FormatProgress(s.progress)
      if right and loc then right = right .. "  ·  " .. loc else right = right or loc end
      r.right:SetText(right or "")
      r.title:SetWidth(width - T.space.tagCol - (right and (r.right:GetStringWidth() or 0) + 8 or 0))
      Place(r, y, 0, width)
      y = y + ROW_H
    end
    y = y + GAP
  else
    card.chip.text:Hide(); card.chip.bg:Hide()
    card.doneBtn:Hide(); card.skipBtn:Hide()
    card.title:SetText("No active step")
    Place(card.title, y, 0, width)
    card.detail:Hide(); card.why:Hide(); card.progBar:Hide(); card.progText:Hide()
    card.target:Hide(); card.badges:Hide()
    y = y + card.title:GetStringHeight() + GAP
  end

  -- Upcoming
  local nUp = view.upcoming and math.min(#view.upcoming, expanded and MAX_UPCOMING or MAX_UPCOMING_COMPACT) or 0
  if nUp > 0 then
    Place(card.nextLabel, y)
    card.nextLabel:Show()
    y = y + 14
    for i = 1, nUp do
      local s = view.upcoming[i]
      local r = AcquireRow()
      local info = TypeInfo(s.type)
      r.tag:SetText(info[1]); SetColor(r.tag, info[2], 0.7)
      r.title:SetText(s.title or "")
      SetColor(r.title, T.color.muted)
      r.right:SetText("")
      r.title:SetWidth(width - T.space.tagCol)
      Place(r, y, 0, width)
      y = y + ROW_H
    end
    y = y + GAP - 2
  else
    card.nextLabel:Hide()
  end

  -- Suggestion / warning callout
  local cText, cColor, cIndex = FormatCallout(view)
  card.calloutIndex = cIndex
  if cText then
    card.callout:SetText(cIndex and (cText .. "  >") or cText)
    SetColor(card.callout, T.color.muted)
    Place(card.callout, y, 8, width - 8)
    local h = card.callout:GetStringHeight()
    card.calloutStripe:ClearAllPoints()
    card.calloutStripe:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -y + 1)
    card.calloutStripe:SetHeight(h + 2)
    card.calloutStripe:SetColorTexture(cColor[1], cColor[2], cColor[3], 0.8)
    card.callout:Show(); card.calloutStripe:Show()
    card.calloutBtn:SetShown(cIndex ~= nil)
    y = y + h + GAP
  else
    card.callout:Hide(); card.calloutStripe:Hide(); card.calloutBtn:Hide()
  end

  -- Closing divider, matching the one above the card
  card.divider:ClearAllPoints()
  card.divider:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -y)
  card.divider:SetPoint("RIGHT", card, "RIGHT", 0, 0)
  y = y + 1

  card:SetHeight(math.max(1, math.floor(y + 0.5)))
end

-- Public API -----------------------------------------------------------------

-- Called by MainPanel during its Create(). `anchor` is the region the card sits
-- below; `layoutChanged` is called whenever the card is shown, hidden or resized.
function Card.Attach(parent, anchor, layoutChanged)
  if not card then Create(parent) end
  onLayout = layoutChanged
  card:ClearAllPoints()
  card:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -GAP)
  card:SetPoint("RIGHT", parent, "RIGHT", -T.space.pad, 0)
  dirty = true
  Card.Relayout()
  return card
end

function Card.IsShown() return card ~= nil and card:IsShown() end

-- Re-lays out if the view changed or the width changed (resize, un-minimize)
function Card.Relayout()
  if not card then return end
  local wasShown = card:IsShown()
  if not lastView then
    if wasShown then
      card:Hide()
      ReleaseRows()
      if onLayout then onLayout() end
    end
    return
  end
  local width = card:GetWidth() or 0
  if width <= 0 then
    local p = card:GetParent()
    width = (p and p:GetWidth() or 0) - 2 * T.space.pad
  end
  if width <= 0 then return end -- not sized yet; stays dirty
  if not dirty and wasShown and math.abs(width - lastWidth) < 0.5 then return end
  local oldHeight = card:GetHeight()
  dirty, lastWidth = false, width
  Layout(width)
  card:Show()
  if onLayout and (not wasShown or math.abs(card:GetHeight() - oldHeight) >= 0.5) then onLayout() end
end

-- Render a GuideView; nil hides the card
function Card.Render(view)
  lastView = view
  dirty = true
  Card.Relayout()
end

ns.Listen("GUIDE_UPDATED", Card.Render)
