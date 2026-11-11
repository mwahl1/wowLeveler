-- Mock GuideView fixtures (docs/P2_GUIDE_ENGINE_SPEC.md 7.2) for developing the
-- guide card before the engine exists. Not guide data: titles, coordinates and
-- labels are illustrative (Valley of Trials-like) and must not be used by routes.
--
-- Trigger: ns.Send("SHOW_MOCK_GUIDE"[, variant])
--   variant = "main" (default) | "start" | "train" | "off" (sends a nil view)
-- Intended slash command (to be routed in Core/Init.lua by its owner):
--   /ln mockguide [start|train|off]  ->  ns.Send("SHOW_MOCK_GUIDE", arg)
local _, ns = ...

local Mock = {}
ns.MockGuideView = Mock

local ROUTE = {
  id = "horde-orc-troll-start",
  title = "Durotar start",
  segment = { id = "valley-of-trials", title = "Valley of Trials", levels = { 1, 6 } },
}

local function Route(done)
  return {
    id = ROUTE.id, title = ROUTE.title, segment = ROUTE.segment,
    progress = { done = done, total = 52 },
  }
end

-- Mid-segment: kill objective in progress, concurrent steps with E and U targets,
-- death-skip suggestion.
Mock.main = {
  route = Route(14),
  current = {
    { id = "vot-788-obj1", type = "KILL", title = "Kill Mottled Boars",
      detail = "Cutting Teeth  ·  east of the Den",
      quest = { id = 788, name = "Cutting Teeth" },
      target = { map = 1411, name = "Boar pens", x = 44.6, y = 61.0, label = "O", distance = 86 },
      progress = { cur = 4, max = 10 }, badges = {}, manualConfirm = false },
    { id = "vot-789-obj1", type = "KILL", title = "Scorpid Worker tails",
      quest = { id = 789, name = "Sting of the Scorpid" },
      target = { map = 1411, x = 40.2, y = 62.5, label = "E", distance = 120 },
      progress = { cur = 2, max = 10 } },
    { id = "vot-4402-obj1", type = "OBJECTIVE", title = "Collect Cactus Apples",
      quest = { id = 4402, name = "Galgar's Cactus Apple Surprise" },
      target = { label = "U" } },
  },
  upcoming = {
    { id = "vot-788-turnin", type = "TURNIN", title = "Turn in Cutting Teeth",
      target = { map = 1411, name = "Gornek", x = 42.1, y = 68.3, label = "O" } },
    { id = "vot-790-accept", type = "ACCEPT", title = "Accept Sarkoth",
      target = { map = 1411, name = "Hana'zua", x = 40.6, y = 66.8, label = "E" } },
    { id = "vot-790-obj1", type = "KILL", title = "Kill Sarkoth",
      target = { map = 1411, x = 40.6, y = 79.5, label = "E" } },
    { id = "vot-train-4", type = "TRAIN", title = "Train level 4 spells" },
  },
  backlog = {},
  suggestions = { { kind = "deathskip", saves = 180 } },
  warnings = { "1 quest in this segment has an unknown objective location" },
}

-- First step of the segment: accept, then turn in to Gornek; observed targets.
Mock.start = {
  route = Route(0),
  current = {
    { id = "vot-4641-accept", type = "ACCEPT", title = "Accept Your Place In The World",
      detail = "Kaltunk, at the camp entrance",
      quest = { id = 4641, name = "Your Place In The World" },
      target = { map = 1411, name = "Kaltunk", x = 43.3, y = 68.5, label = "O", distance = 6 },
      badges = {}, manualConfirm = false },
  },
  upcoming = {
    { id = "vot-4641-turnin", type = "TURNIN", title = "Turn in Your Place In The World",
      target = { map = 1411, name = "Gornek", x = 42.1, y = 68.3, label = "O" } },
    { id = "vot-788-accept", type = "ACCEPT", title = "Accept Cutting Teeth" },
    { id = "vot-788-obj1", type = "KILL", title = "Kill Mottled Boars" },
  },
  backlog = {},
  suggestions = {},
  warnings = {},
}

-- Manual confirmation (spell checks unavailable), approximate location, segment
-- switch suggestion.
Mock.train = {
  route = Route(31),
  current = {
    { id = "vot-train-6", type = "TRAIN", title = "Train level 6 spells",
      detail = "Class trainer, inside the Den",
      target = { map = 1411, name = "Den", x = 42.6, y = 69.0, label = "E", distance = 34 },
      badges = { "optional", "approx-location" },
      why = "Spell checks are unavailable here; confirm when trained",
      manualConfirm = true },
  },
  upcoming = {
    { id = "dur-goto-razor-hill", type = "GOTO", title = "Run to Razor Hill" },
    { id = "dur-fp-razor-hill", type = "FP_LEARN", title = "Get the Razor Hill flight path" },
  },
  backlog = {},
  suggestions = { { kind = "segment", to = "The Barrens 12-20", reason = "you are 2 levels above Durotar" } },
  warnings = {},
}

-- The guide window draws from view.list (whole segment); mocks only list current and
-- upcoming steps, so build a list from those plus two finished steps for the done styling.
local function WithList(view)
  if view.list then return view end
  local list = {
    { id = "mock-done-1", type = "ACCEPT", status = "DONE", npc = "Kaltunk",
      quest = { name = "Your Place In The World" } },
    { id = "mock-done-2", type = "TURNIN", status = "DONE", npc = "Gornek",
      quest = { name = "Your Place In The World" } },
  }
  local function add(s, status)
    local row = {}
    for k, v in pairs(s) do row[k] = v end
    row.status = status
    if (s.type == "ACCEPT" or s.type == "TURNIN") and s.target and s.target.name then row.npc = s.target.name end
    if (s.type == "KILL" or s.type == "OBJECTIVE") and not row.subject and s.title then
      local verb, name = s.title:match("^(%a+) (.+)$")
      if verb then row.subject = { verb = verb, kind = verb == "Collect" and "item" or "npc", name = name } end
    end
    list[#list + 1] = row
  end
  for _, s in ipairs(view.current or {}) do add(s, "ACTIVE") end
  for _, s in ipairs(view.upcoming or {}) do add(s, "WAITING") end
  view.list = list
  view.primaryId = view.current and view.current[1] and view.current[1].id
  return view
end

ns.Listen("SHOW_MOCK_GUIDE", function(variant)
  if variant == "off" then
    ns.Send("GUIDE_UPDATED", nil)
    return
  end
  ns.Send("GUIDE_UPDATED", WithList(Mock[variant or "main"] or Mock.main))
end)
