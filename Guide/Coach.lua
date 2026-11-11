-- Coach: turns the current block of the route into short, direct instructions: who to go to
-- or what to kill, how far, what to do there, and what's next. No compass directions: the map
-- pins and the waypoint arrow show the way (Marshal, 2026-11-10: "less thinking, more telling").
-- Pure Lua (offline-tested, tests/coach_test.lua).
--
-- Returns plain strings with keyword markers the UI colors:
--   {n}NPC{/n}  {m}creature{/m}  {i}item{/i}  {o}object{/o}  {q}quest{/q}
local _, ns = ...

local Coach = {}
ns.GuideCoach = Coach

local FINISHED = { DONE = true, SKIPPED = true }
local MARK = { npc = "m", item = "i", object = "o" } -- objective subject kind -> marker

local function n(s) return "{n}" .. s .. "{/n}" end
local function q(s) return "{q}" .. s .. "{/q}" end

-- "A", "A and B", "A, B and C"
local function joinAnd(list)
  if #list == 0 then return "" end
  if #list == 1 then return list[1] end
  return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

local function roundYards(d)
  if d < 100 then return math.floor(d / 5 + 0.5) * 5 end
  return math.floor(d / 10 + 0.5) * 10
end

-- "here" / "40 yd" / "another zone" / nil
function Coach.Distance(player, t)
  if not t or t.label == "U" or not (t.x and t.y) then return nil end
  if player and player.map and t.map and player.map ~= t.map then return "another zone" end
  local d = t.distance
  if not d then return nil end
  if d <= 12 then return "here" end
  return roundYards(d) .. " yd"
end

local function objectiveText(row, withCount)
  local s = row.subject
  local p = row.progress
  local count = (withCount and p and p.max and p.max > 0) and string.format(" %d/%d", p.cur or 0, p.max) or ""
  if s then
    local m = MARK[s.kind] or "m"
    return s.verb .. " {" .. m .. "}" .. s.name .. "{/" .. m .. "}" .. count
  end
  return (row.title or "objective") .. count
end

local function lower(s) return (s:gsub("^%u", string.lower)) end

-- One short phrase for the block after the current one
local function nextSummary(b)
  if not b then return nil end
  if b.kind == "talk" then
    for _, r in ipairs(b.rows) do
      if r.type == "TURNIN" then return "turn in at " .. n(b.npc) end
    end
    return "talk to " .. n(b.npc)
  end
  if b.kind == "objectives" then
    local parts = {}
    for _, r in ipairs(b.rows) do
      if not FINISHED[r.status] then parts[#parts + 1] = lower(objectiveText(r, false)) end
      if #parts == 2 then break end
    end
    return #parts > 0 and joinAnd(parts) or nil
  end
  local r = b.rows[1]
  return r and r.title and lower(r.title) or nil
end

-- view: engine GuideView; blocks/curIndex: ns.GuideBlocks.Build(view.list, view.primaryId)
function Coach.Lines(view, blocks, curIndex)
  local lines = {}
  if not view then return lines end
  local block = curIndex and blocks and blocks[curIndex]
  local primary = view.current and view.current[1]
  if not (block and primary) then return lines end
  local dist = Coach.Distance(view.player, primary.target)
  local far = dist and dist ~= "here" and (" (" .. dist .. ")") or ""

  if block.kind == "talk" then
    local turnins, accepts = {}, {}
    for _, r in ipairs(block.rows) do
      if not FINISHED[r.status] and r.quest then
        if r.type == "TURNIN" then turnins[#turnins + 1] = q(r.quest.name) else accepts[#accepts + 1] = q(r.quest.name) end
      end
    end
    lines[#lines + 1] = dist == "here" and ("Talk to " .. n(block.npc) .. ".") or ("Go to " .. n(block.npc) .. far .. ".")
    local doing = {}
    if #turnins > 0 then doing[#doing + 1] = "Turn in " .. joinAnd(turnins) end
    if #accepts > 0 then doing[#doing + 1] = (#turnins > 0 and "accept " or "Accept ") .. joinAnd(accepts) end
    if #doing > 0 then lines[#lines + 1] = table.concat(doing, ", ") .. "." end
  elseif block.kind == "objectives" then
    local open, seen = {}, {}
    for _, r in ipairs(block.rows) do
      if not FINISHED[r.status] then open[#open + 1] = r end
      seen[r.id] = true
    end
    for k = 2, #(view.current or {}) do -- open objectives of other quests nearby
      local s = view.current[k]
      if not seen[s.id] and (s.type == "OBJECTIVE" or s.type == "KILL" or s.type == "COMPLETE") then open[#open + 1] = s end
    end
    if #open == 1 then
      lines[#lines + 1] = objectiveText(open[1], true) .. far .. "."
    elseif #open > 1 then
      local parts = {}
      for _, r in ipairs(open) do parts[#parts + 1] = objectiveText(r, true) end
      lines[#lines + 1] = "Same trip" .. far .. ": " .. joinAnd(parts) .. "."
    end
    if #open > 0 then lines[#lines + 1] = "Follow the dots on your minimap." end
  else
    lines[#lines + 1] = (primary.title or "Next step") .. far .. "."
  end

  -- Why the step can't be done yet (level, prerequisite), when the engine says so
  if primary.status ~= "ACTIVE" and primary.why then lines[#lines + 1] = primary.why .. "." end

  local after = nextSummary(blocks[curIndex + 1])
  if after then lines[#lines + 1] = "Then " .. after .. "." end
  return lines
end
