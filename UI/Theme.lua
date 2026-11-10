-- Design tokens: every color, font and spacing value the UI uses lives here
local _, ns = ...

ns.Theme = {
  font = {
    heading = "Fonts\\FRIZQT__.TTF",
    body = "Fonts\\ARIALN.TTF",
  },
  size = {
    title = 12,
    heading = 10,
    body = 13,
    small = 11,
  },
  space = {
    pad = 12,    -- panel inner padding
    gap = 8,     -- between sections
    row = 4,     -- between rows
    header = 32, -- title bar height
  },
  color = {
    bg       = { 0.055, 0.062, 0.078 },
    surface  = { 0.090, 0.100, 0.125 },
    border   = { 1, 1, 1, 0.08 },
    divider  = { 1, 1, 1, 0.06 },
    accent   = { 0.95, 0.71, 0.25 },
    text     = { 0.93, 0.94, 0.96 },
    muted    = { 0.58, 0.61, 0.67 },
    faint    = { 0.40, 0.43, 0.48 },
    good     = { 0.36, 0.80, 0.47 },
    warn     = { 0.96, 0.74, 0.30 },
    bad      = { 0.92, 0.38, 0.38 },
    xp       = { 0.58, 0.40, 0.92 },
    rested   = { 0.30, 0.56, 0.96 },
    track    = { 1, 1, 1, 0.07 },
  },
}

-- Hex string for inline |c color codes
function ns.Theme.Hex(c)
  return string.format("ff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end
