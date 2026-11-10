-- Fixture routes for engine tests (spec 3.2-3.5, 4, 6, 8a "Engine").
-- Real Valley of Trials quest IDs; quest relations come from the generated data:
--   4641 Your Place In The World  (breadcrumb for 788, NEXT 788)
--   788  Cutting Teeth            (kill 3098)
--   789  Sting of the Scorpid     (PRE_ANY 788, item 4862)
--   790  Sarkoth                  (NEXT 804, item 4905)
--   804  Sarkoth                  (PRE_ANY 790)
--   4402 Galgar's Cactus Apple Surprise (PRE_ANY 788, item 11583)
-- Load with T.fixture("engine_routes").

local E = {
  VOT = "eng.start.vot",
  DUROTAR = "eng.durotar.5-12",
  BARRENS = "eng.barrens.10-20",
  WARLOCK = "eng.overlay.warlock",
  DUROTAR_QUESTS = { 786, 817, 818, 791 },
  BARRENS_QUESTS = { 840, 870, 848, 869, 871, 844 },
}

-- ACCEPT, OBJECTIVE per objective (when the quest has objectives), TURNIN
local function questSteps(ns, prefix, qid, opts)
  opts = opts or {}
  local Q = ns.DataSchema.Q
  local q = ns.Data.GetQuest(qid)
  local steps = { { id = prefix .. ".a" .. qid, type = "ACCEPT", quest = qid, optional = opts.optional } }
  local objs = q and q[Q.OBJ]
  if objs and #objs > 0 and not opts.noObjectives then
    for i = 1, #objs do
      steps[#steps + 1] = { id = prefix .. ".o" .. qid .. "_" .. i, type = "OBJECTIVE", quest = qid, objective = i,
        optional = opts.optional }
    end
  end
  steps[#steps + 1] = { id = prefix .. ".t" .. qid, type = "TURNIN", quest = qid, optional = opts.optional }
  return steps
end
E.questSteps = questSteps

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do for _, s in ipairs(list) do out[#out + 1] = s end end
  return out
end

-- Valley of Trials, linear: 4641, 788, 790, 804, 789, 4402.
-- opts.optional4641 makes the 4641 steps optional.
function E.vot(ns, opts)
  opts = opts or {}
  return {
    id = E.VOT, kind = "start", faction = "Horde", races = { 2, 8 }, levels = { 1, 6 },
    exit = { completed = { 788, 790, 804, 789, 4402 } }, next = { E.DUROTAR }, source = "hand",
    steps = concat(
      questSteps(ns, "vot", 4641, { optional = opts.optional4641 }),
      questSteps(ns, "vot", 788),
      questSteps(ns, "vot", 790),
      questSteps(ns, "vot", 804),
      questSteps(ns, "vot", 789),
      questSteps(ns, "vot", 4402)),
  }
end

local function multi(ns, prefix, quests)
  local out = {}
  for _, q in ipairs(quests) do
    for _, s in ipairs(questSteps(ns, prefix, q, { noObjectives = true })) do out[#out + 1] = s end
  end
  return out
end

function E.durotar(ns)
  return { id = E.DUROTAR, kind = "segment", faction = "Horde", levels = { 5, 12 }, entry = { minLevel = 4 },
    exit = { level = 12 }, next = { E.BARRENS }, source = "hand", steps = multi(ns, "edur", E.DUROTAR_QUESTS) }
end

function E.barrens(ns)
  return { id = E.BARRENS, kind = "segment", faction = "Horde", levels = { 10, 20 }, entry = { minLevel = 9 },
    exit = { level = 20 }, source = "hand", steps = multi(ns, "ebar", E.BARRENS_QUESTS) }
end

function E.warlock()
  return { id = E.WARLOCK, kind = "overlay", faction = "Horde", classes = { "WARLOCK" },
    insert = { { after = "vot.t788", steps = { { id = "ewl.imp", type = "NOTE", text = "Summon your Imp" } } } } }
end

-- Generic start for any race from DataMeta.startingQuests (ACCEPT/TURNIN only)
function E.startFor(ns, raceID, faction)
  local info = ns.DataMeta.startingQuests[raceID]
  local quests = info and info.quests or {}
  return { id = "eng.start.r" .. raceID, kind = "start", faction = faction, races = { raceID }, levels = { 1, 6 },
    exit = { completed = quests }, source = "hand", steps = multi(ns, "s" .. raceID, quests) }
end

-- Registers the Horde VoT start + Durotar + Barrens + warlock overlay
function E.registerHorde(ns, opts)
  ns.Guides.Register(E.vot(ns, opts))
  ns.Guides.Register(E.durotar(ns))
  ns.Guides.Register(E.barrens(ns))
  ns.Guides.Register(E.warlock())
end

return E
