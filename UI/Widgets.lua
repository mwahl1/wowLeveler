-- Small reusable UI building blocks styled from ns.Theme
local _, ns = ...
local T = ns.Theme

local W = {}
ns.Widgets = W

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Flat background with a 1px hairline border
function W.Skin(frame, bg, alpha)
  bg = bg or T.color.bg
  frame.bg = frame.bg or frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  frame.bg:SetAllPoints()
  frame.bg:SetColorTexture(bg[1], bg[2], bg[3], alpha or 1)

  if not frame.edges then
    frame.edges = {}
    local b = T.color.border
    for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
      local t = frame:CreateTexture(nil, "BORDER")
      t:SetColorTexture(b[1], b[2], b[3], b[4])
      if side == "TOP" or side == "BOTTOM" then
        t:SetPoint(side .. "LEFT"); t:SetPoint(side .. "RIGHT"); t:SetHeight(1)
      else
        t:SetPoint("TOP" .. side); t:SetPoint("BOTTOM" .. side); t:SetWidth(1)
      end
      frame.edges[i] = t
    end
  end
end

function W.Text(parent, opts)
  opts = opts or {}
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(opts.font or T.font.body, opts.size or T.size.body, opts.flags or "")
  local c = opts.color or T.color.text
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.75)
  fs:SetJustifyH(opts.justify or "LEFT")
  fs:SetWordWrap(opts.wrap ~= false)
  return fs
end

-- Uppercase, letter-spaced section label: "CURRENT QUESTS"
function W.Label(parent, text)
  local fs = W.Text(parent, { font = T.font.heading, size = T.size.heading, color = T.color.muted, wrap = false })
  fs:SetText(text:upper())
  return fs
end

function W.Divider(parent)
  local t = parent:CreateTexture(nil, "ARTWORK")
  local c = T.color.divider
  t:SetColorTexture(c[1], c[2], c[3], c[4])
  t:SetHeight(1)
  return t
end

-- Thin progress bar with a track; optional secondary overlay (e.g. rested XP)
function W.Bar(parent, height, color)
  local bar = CreateFrame("StatusBar", nil, parent)
  bar:SetHeight(height or 4)
  bar:SetStatusBarTexture(WHITE)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  W.SetBarColor(bar, color or T.color.accent)

  bar.track = bar:CreateTexture(nil, "BACKGROUND")
  bar.track:SetAllPoints()
  local tr = T.color.track
  bar.track:SetColorTexture(tr[1], tr[2], tr[3], tr[4])

  bar.overlay = bar:CreateTexture(nil, "BORDER")
  bar.overlay:SetPoint("TOP"); bar.overlay:SetPoint("BOTTOM")
  bar.overlay:Hide()
  return bar
end

function W.SetBarColor(bar, c)
  bar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 1)
end

-- Shows a second segment from `from` to `to` (0-1) behind the fill
function W.SetBarOverlay(bar, from, to, color)
  if not to or to <= from then bar.overlay:Hide(); return end
  local width = bar:GetWidth()
  if width <= 0 then bar.overlay:Hide(); return end
  bar.overlay:ClearAllPoints()
  bar.overlay:SetPoint("TOPLEFT", bar, "TOPLEFT", width * from, 0)
  bar.overlay:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", width * from, 0)
  bar.overlay:SetWidth(math.max(1, width * (math.min(to, 1) - from)))
  bar.overlay:SetColorTexture(color[1], color[2], color[3], 0.35)
  bar.overlay:Show()
end

-- Minimal text button with hover highlight
function W.TextButton(parent, label, onClick, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size or 20, size or 20)
  b.text = W.Text(b, { font = T.font.heading, size = T.size.title, color = T.color.muted, justify = "CENTER", wrap = false })
  b.text:SetPoint("CENTER", 0, 1)
  b.text:SetText(label)
  b:SetScript("OnEnter", function() local c = T.color.text; b.text:SetTextColor(c[1], c[2], c[3]) end)
  b:SetScript("OnLeave", function() local c = T.color.muted; b.text:SetTextColor(c[1], c[2], c[3]) end)
  b:SetScript("OnClick", onClick)
  return b
end

-- Simple vertical scroll area; content height is set by the caller
function W.ScrollArea(parent)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 30)))
  end)
  scroll:SetScript("OnSizeChanged", function(self, w) content:SetWidth(w) end)
  scroll.content = content
  return scroll
end
