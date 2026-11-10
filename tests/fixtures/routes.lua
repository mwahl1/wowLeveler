-- Fixture routes for compiler/selector tests (spec 3.2-3.5, 8a).
-- Returns a table: ids, and register(ns, opts) which registers every fixture def via
-- ns.Guides.Register. Quest names/XP come from ns.Data so the fixtures follow the real data.
--
-- Not a test file (no _test suffix); load with T.fixture("routes").

local F = {
  ORC_START = "horde.start.valley_of_trials",
  UD_START = "horde.start.deathknell",
  DUROTAR = "horde.durotar.5-12",
  BARRENS = "horde.barrens.10-20",
  ALLY_START = "alliance.start.northshire",
  WARLOCK = "overlay.warlock.horde",
  VOT_QUESTS = { 4641, 788, 790, 804, 4402 },
  DUROTAR_QUESTS = { 786, 817, 818, 791 },
  BARRENS_QUESTS = { 840, 870, 848, 869, 871, 844 },
}

local function questInfo(ns, qid)
  local q = ns.Data.GetQuest(qid)
  local Q = ns.DataSchema.Q
  if not q then return "quest " .. qid, nil end
  return q[Q.NAME], q[Q.XP]
end

-- ACCEPT + TURNIN for each quest (uniform, so XP scoring treats every segment alike)
local function questSteps(ns, prefix, quests, extra)
  local steps = {}
  for _, qid in ipairs(quests) do
    local name, xp = questInfo(ns, qid)
    steps[#steps + 1] = { id = prefix .. ".a" .. qid, type = "ACCEPT", quest = qid, text = "Accept " .. name }
    if extra and extra[qid] then
      for _, s in ipairs(extra[qid]) do steps[#steps + 1] = s end
    end
    steps[#steps + 1] = { id = prefix .. ".t" .. qid, type = "TURNIN", quest = qid, text = "Turn in " .. name,
      est = xp and { xp = xp, src = "E" } or nil }
  end
  return steps
end

F.orcStart = function(ns)
  return {
    id = F.ORC_START, kind = "start", faction = "Horde", races = { 2, 8 },
    levels = { 1, 6 }, entry = { maxLevel = 8 }, exit = { completed = F.VOT_QUESTS },
    next = { F.DUROTAR }, source = "hand",
    steps = questSteps(ns, "vot", F.VOT_QUESTS, {
      [788] = { { id = "vot.c788", type = "COMPLETE", quest = 788 } },
      [790] = { { id = "vot.c790", type = "COMPLETE", quest = 790 } },
    }),
  }
end

F.udStart = function(ns)
  local quests = ns.DataMeta.startingQuests[5].quests
  return {
    id = F.UD_START, kind = "start", faction = "Horde", races = { 5 },
    levels = { 1, 6 }, entry = { maxLevel = 8 }, exit = { completed = quests },
    next = { F.DUROTAR }, source = "hand",
    steps = questSteps(ns, "dk", quests),
  }
end

F.durotar = function(ns)
  return {
    id = F.DUROTAR, kind = "segment", faction = "Horde", levels = { 5, 12 },
    entry = { minLevel = 4 }, exit = { level = 12 }, next = { F.BARRENS }, source = "hand",
    steps = questSteps(ns, "dur", F.DUROTAR_QUESTS),
  }
end

F.barrens = function(ns)
  return {
    id = F.BARRENS, kind = "segment", faction = "Horde", levels = { 10, 20 },
    entry = { minLevel = 9 }, exit = { level = 20 }, source = "hand",
    steps = questSteps(ns, "bar", F.BARRENS_QUESTS),
  }
end

F.allyStart = function(ns)
  local quests = ns.DataMeta.startingQuests[1].quests
  return {
    id = F.ALLY_START, kind = "start", faction = "Alliance", races = { 1 },
    levels = { 1, 6 }, exit = { completed = quests }, source = "hand",
    steps = questSteps(ns, "ns", quests),
  }
end

F.warlock = function()
  return {
    id = F.WARLOCK, kind = "overlay", faction = "Horde", classes = { "WARLOCK" },
    insert = {
      { after = "vot.t788", steps = { { id = "wl.imp", type = "NOTE", text = "Summon your Imp" } } },
      { atLevel = 10, steps = { { id = "wl.train10", type = "TRAIN", text = "Train level 10 spells" } } },
    },
  }
end

-- Registers every fixture def. Register order is deliberately not level order.
function F.register(ns)
  ns.Guides.Register(F.barrens(ns))
  ns.Guides.Register(F.warlock(ns))
  ns.Guides.Register(F.allyStart(ns))
  ns.Guides.Register(F.durotar(ns))
  ns.Guides.Register(F.udStart(ns))
  ns.Guides.Register(F.orcStart(ns))
end

return F
