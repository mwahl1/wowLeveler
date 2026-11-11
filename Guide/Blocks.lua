-- Groups the engine's segment list (view.list) into numbered blocks for the step list UI:
--   talk        consecutive ACCEPT / TURNIN steps at the same NPC ("Talk to Gornek")
--   objectives  consecutive OBJECTIVE / KILL / COMPLETE steps (done together in one loop)
--   single      anything else (travel, train, hearth, grind, notes)
-- Pure Lua, no WoW API (offline-tested in tests/blocks_test.lua).
local _, ns = ...

local B = {}
ns.GuideBlocks = B

local OBJECTIVE_TYPES = { OBJECTIVE = true, KILL = true, COMPLETE = true }
local FINISHED = { DONE = true, SKIPPED = true }

function B.IsFinished(row) return row ~= nil and FINISHED[row.status] == true end

local function kindOf(row)
  if (row.type == "ACCEPT" or row.type == "TURNIN") and row.npc then return "talk" end
  if OBJECTIVE_TYPES[row.type] then return "objectives" end
  return "single"
end

-- Returns blocks (array) and the index of the block holding primaryId (nil when none)
function B.Build(list, primaryId)
  local blocks, cur = {}, nil
  local currentIndex
  for _, row in ipairs(list or {}) do
    local kind = kindOf(row)
    local join = cur ~= nil and kind ~= "single" and cur.kind == kind
      and (kind ~= "talk" or cur.npc == row.npc)
    if not join then
      cur = { kind = kind, npc = kind == "talk" and row.npc or nil, npcKind = row.npcKind, rows = {} }
      blocks[#blocks + 1] = cur
      cur.number = #blocks
    end
    cur.rows[#cur.rows + 1] = row
    if primaryId ~= nil and row.id == primaryId then
      cur.current = true
      currentIndex = cur.number
    end
  end
  for _, b in ipairs(blocks) do
    local all = true
    for _, r in ipairs(b.rows) do
      if not FINISHED[r.status] then all = false; break end
    end
    b.done = all
  end
  return blocks, currentIndex
end
