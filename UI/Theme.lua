-- Design tokens: every color, font, texture and spacing value the UI uses lives here.
-- WoW-native look: Friz Quadrata (the game's UI font), Blizzard tooltip panels, Blizzard
-- quest/gossip icons. Only textures that ship with the game client are referenced.
local _, ns = ...

ns.Theme = {
  font = {
    heading = "Fonts\\FRIZQT__.TTF",
    body = "Fonts\\FRIZQT__.TTF",
    numbers = "Fonts\\ARIALN.TTF",
  },
  size = {
    title = 13,
    heading = 10,
    body = 12,
    small = 11,
    step = 13,   -- current-step box lines
    tag = 9,
    list = 12,   -- step list lines
  },
  space = {
    pad = 10,    -- panel inner padding
    gap = 8,     -- between sections
    row = 4,     -- between rows
    header = 30, -- title bar height (settings / diagnostics windows)
    tagCol = 66,
    line = 17,   -- one step line (scaled with the font)
    icon = 14,   -- inline icon size
  },
  color = {
    bg       = { 0.035, 0.045, 0.075 },
    surface  = { 0.075, 0.090, 0.140 },
    panelBg  = { 0.02, 0.03, 0.06, 0.88 },  -- tooltip-style panel background
    panelEdge = { 0.62, 0.64, 0.70, 1 },    -- silver tooltip border
    border   = { 1, 1, 1, 0.10 },
    divider  = { 1, 1, 1, 0.08 },
    accent   = { 1.00, 0.82, 0.00 },        -- Blizzard gold (NORMAL_FONT_COLOR)
    text     = { 1.00, 1.00, 1.00 },
    muted    = { 0.70, 0.70, 0.72 },
    faint    = { 0.50, 0.50, 0.53 },
    done     = { 0.48, 0.48, 0.50 },        -- finished steps in the list
    good     = { 0.25, 0.90, 0.35 },
    warn     = { 1.00, 0.60, 0.20 },
    bad      = { 1.00, 0.30, 0.30 },
    xp       = { 0.58, 0.40, 0.92 },
    rested   = { 0.30, 0.56, 0.96 },
    track    = { 1, 1, 1, 0.07 },
    chip     = 0.16,
    current  = { 1.00, 0.82, 0.00, 0.10 },  -- highlight behind the current list block
    -- keyword colors in step text
    npc      = { 0.30, 0.95, 0.40 },        -- people to talk to
    mob      = { 1.00, 0.42, 0.36 },        -- creatures to kill
    item     = { 0.45, 0.78, 1.00 },        -- items to loot / use
    object   = { 1.00, 0.82, 0.30 },        -- world objects
    quest    = { 1.00, 1.00, 1.00 },        -- quest names
  },
  -- Inline icons (|T path:size|t), all from the game client
  icon = {
    talk    = "Interface\\GossipFrame\\GossipGossipIcon",
    accept  = "Interface\\GossipFrame\\AvailableQuestIcon",
    turnin  = "Interface\\GossipFrame\\ActiveQuestIcon",
    kill    = "Interface\\CURSOR\\Attack",
    loot    = "Interface\\CURSOR\\Pickup",
    use     = "Interface\\CURSOR\\Interact",
    travel  = "Interface\\GossipFrame\\TaxiGossipIcon",
    train   = "Interface\\GossipFrame\\TrainerGossipIcon",
    buy     = "Interface\\GossipFrame\\VendorGossipIcon",
    hearth  = "Interface\\Icons\\INV_Misc_Rune_01",
    note    = "Interface\\FriendsFrame\\InformationIcon",
    guide   = "Interface\\Icons\\Ability_Rogue_Sprint",
    radio   = "Interface\\Buttons\\UI-RadioButton", -- 4-frame strip: empty, checked, ...
    options = "Interface\\Buttons\\UI-OptionsButton",
    scrollUp   = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
    scrollDown = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
  },
  -- Step-type tag colors (settings, diagnostics and mock views)
  step = {
    accept    = { 1.00, 0.82, 0.00 },
    turnin    = { 0.25, 0.90, 0.35 },
    objective = { 1.00, 0.42, 0.36 },
    travel    = { 0.45, 0.66, 0.96 },
    grind     = { 0.66, 0.50, 0.94 },
    train     = { 0.40, 0.80, 0.82 },
    other     = { 0.70, 0.70, 0.72 },
    deathskip = { 0.70, 0.72, 0.78 },
  },
}

-- Hex string for inline |c color codes
function ns.Theme.Hex(c)
  return string.format("ff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

-- "|cffRRGGBBtext|r"
function ns.Theme.Color(c, text)
  return "|c" .. ns.Theme.Hex(c) .. tostring(text) .. "|r"
end

-- Inline texture, sized to the current font scale by the caller
function ns.Theme.Icon(path, size)
  size = size or 14
  return "|T" .. path .. ":" .. size .. ":" .. size .. ":0:0|t"
end
