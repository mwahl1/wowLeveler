-- Exact map pins for the current step, on the minimap and the world map.
--   quest giver      gold "!"        (floats on the minimap edge when out of range)
--   turn-in NPC      gold "?"        (floats on the minimap edge when out of range)
--   creature to kill red dot         at every spawn point
--   item to loot     blue dot        at every spawn of the creatures / objects that drop it
--   object to use    yellow dot      at every spawn point
-- Points come from the quest database (ns.GuideEngine.TargetPoints). Drawing uses
-- HereBeDragons-Pins (Libs/HereBeDragons, Questie's copy with its Forever map fixes).
-- Settings: ns.db.ui.pins (default on).
local _, ns = ...
local T = ns.Theme

local Pins = {}
ns.MapPins = Pins

local REF = "LevelingNavigator"
local MAX_POINTS = 60      -- per step
local NPC_SIZE, DOT_SIZE = 16, 9
local WHITE = "Interface\\Buttons\\WHITE8X8"
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local HBDP = LibStub and LibStub("HereBeDragonsLN-Pins-2.0", true)

local DOT_COLOR = { kill = T.color.mob, loot = T.color.item, use = T.color.object }
local ROLE_TEXT = { giver = "Quest giver", finisher = "Turn in here", kill = "Kill", loot = "Loot", use = "Use" }

local function Enabled() return HBDP ~= nil and not (ns.db and ns.db.ui and ns.db.ui.pins == false) end

-- Pin frames: one pool per surface (a frame can only be placed on one map at a time)
local pools = { minimap = { free = {}, used = {} }, world = { free = {}, used = {} } }

local function OnEnter(self)
  if not GameTooltip or not self.point then return end
  local p = self.point
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(p.name or "?", 1, 1, 1)
  local role = ROLE_TEXT[p.role] or ""
  if self.quest then role = role .. (role ~= "" and ": " or "") .. self.quest end
  if role ~= "" then GameTooltip:AddLine(role, 1, 0.82, 0) end
  GameTooltip:AddLine("Leveling Navigator", 0.5, 0.5, 0.53)
  GameTooltip:Show()
end
local function OnLeave() if GameTooltip then GameTooltip:Hide() end end

local function NewPin()
  local f = CreateFrame("Button", nil, UIParent)
  f:SetFrameStrata("MEDIUM")
  -- quest NPC: Blizzard "!" / "?" icon, unmasked
  f.quest = nil
  f.questIcon = f:CreateTexture(nil, "ARTWORK")
  f.questIcon:SetAllPoints()
  -- objective: colored dot with a dark ring (both circle-masked)
  f.ring = f:CreateTexture(nil, "BACKGROUND")
  f.ring:SetAllPoints()
  f.ring:SetTexture(WHITE)
  f.ring:SetVertexColor(0, 0, 0, 0.85)
  f.dot = f:CreateTexture(nil, "ARTWORK")
  f.dot:SetPoint("TOPLEFT", 1.5, -1.5)
  f.dot:SetPoint("BOTTOMRIGHT", -1.5, 1.5)
  f.dot:SetTexture(WHITE)
  for _, tex in ipairs({ f.ring, f.dot }) do
    if tex.SetMask then pcall(tex.SetMask, tex, CIRCLE_MASK) end
  end
  f:SetScript("OnEnter", OnEnter)
  f:SetScript("OnLeave", OnLeave)
  return f
end

local function Acquire(surface)
  local pool = pools[surface]
  local f = table.remove(pool.free) or NewPin()
  pool.used[#pool.used + 1] = f
  return f
end

local function Style(f, p, quest)
  f.point, f.quest = p, quest
  if p.role == "giver" or p.role == "finisher" then
    f:SetSize(NPC_SIZE, NPC_SIZE)
    f.ring:Hide(); f.dot:Hide()
    f.questIcon:SetTexture(p.role == "giver" and T.icon.accept or T.icon.turnin)
    f.questIcon:Show()
  else
    f:SetSize(DOT_SIZE, DOT_SIZE)
    f.questIcon:Hide()
    local c = DOT_COLOR[p.role] or T.color.mob
    f.dot:SetVertexColor(c[1], c[2], c[3], 1)
    f.ring:Show(); f.dot:Show()
  end
end

function Pins.Clear()
  if HBDP then
    pcall(HBDP.RemoveAllMinimapIcons, HBDP, REF)
    pcall(HBDP.RemoveAllWorldMapIcons, HBDP, REF)
  end
  for _, pool in pairs(pools) do
    for i = #pool.used, 1, -1 do
      local f = pool.used[i]
      f:Hide()
      f.point, f.quest = nil, nil
      pool.free[#pool.free + 1] = f
      pool.used[i] = nil
    end
  end
end

-- Steps whose points are pinned: the current block's unfinished rows plus the other current
-- steps (open objectives nearby)
local FINISHED = { DONE = true, SKIPPED = true }
local function PinnedSteps(view)
  local out, seen = {}, {}
  local B = ns.GuideBlocks
  if B and view.list then
    local blocks, cur = B.Build(view.list, view.primaryId)
    local block = cur and blocks[cur]
    for _, r in ipairs(block and block.rows or {}) do
      if not FINISHED[r.status] then out[#out + 1] = r; seen[r.id] = true end
    end
  end
  for _, s in ipairs(view.current or {}) do
    if not seen[s.id] and not FINISHED[s.status] then out[#out + 1] = s; seen[s.id] = true end
  end
  return out
end

local lastKey

-- Rebuilds the pins when the set of pinned steps (or a step's status) changes
function Pins.Update(view)
  if not Enabled() or not view then
    if lastKey ~= nil then Pins.Clear(); lastKey = nil end
    return
  end
  local E = ns.GuideEngine
  if not (E and E.TargetPoints) then return end
  local steps = PinnedSteps(view)
  local keyParts = {}
  for _, s in ipairs(steps) do keyParts[#keyParts + 1] = s.id .. ":" .. tostring(s.status) end
  local key = table.concat(keyParts, ",")
  if key == lastKey then return end
  lastKey = key
  Pins.Clear()

  local placed = {} -- "map:x:y" -> true, one pin per spot (same NPC for turn-in + accept)
  local count = 0
  -- turn-ins first so a spot with both shows "?"
  table.sort(steps, function(a, b) return (a.type == "TURNIN" and 0 or 1) < (b.type == "TURNIN" and 0 or 1) end)
  for _, s in ipairs(steps) do
    local qid = s.quest and s.quest.id
    if qid then
      local points = E.TargetPoints(qid, s.type, s.objective, nil, MAX_POINTS)
      for _, p in ipairs(points) do
        local spot = p.map .. ":" .. p.x .. ":" .. p.y
        if not placed[spot] then
          placed[spot] = true
          local npcPin = p.role == "giver" or p.role == "finisher"
          local mini = Acquire("minimap")
          Style(mini, p, s.quest.name)
          pcall(HBDP.AddMinimapIconMap, HBDP, REF, mini, p.map, p.x / 100, p.y / 100, true, npcPin)
          local world = Acquire("world")
          Style(world, p, s.quest.name)
          pcall(HBDP.AddWorldMapIconMap, HBDP, REF, world, p.map, p.x / 100, p.y / 100,
            HBD_PINS_WORLDMAP_SHOW_PARENT)
          count = count + 1
        end
      end
    end
  end
  Pins.lastCount = count
end

-- Settings changed: drop every pin, then redraw from the current view (if pins are on)
function Pins.Refresh()
  Pins.Clear()
  lastKey = nil
  Pins.Update(ns.Guide and ns.Guide.GetView and ns.Guide.GetView() or nil)
end

ns.Listen("GUIDE_UPDATED", Pins.Update)
