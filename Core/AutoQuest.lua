-- Automatic quest accept and turn-in.
--
-- Ported from Questie's Modules/Auto/AutoQuesting.lua (https://github.com/Questie/Questie),
-- which the Questie team permits copying under GPLv3 (see Questie LICENSE.md). Adapted to
-- Leveling Navigator: our settings, our guard helpers (ns.Compat), and a "route quests only"
-- filter so the guide never picks up quests the route leaves out.
--
-- Settings (ns.db): autoAccept, autoTurnIn, autoRouteOnly. Holding Shift while talking to
-- an NPC pauses automation until every quest window has closed (Questie's behaviour).
-- Never picks a reward when there is more than one choice, and never auto-accepts escort
-- quests or turns in quests on the disallowed lists (Core/AutoQuestLists.lua).
local _, ns = ...
local C = ns.Compat

local Auto = {}
ns.AutoQuest = Auto

local shouldRun = true -- false after Shift was held, until all quest windows close

local function Enabled(key) return ns.db ~= nil and ns.db[key] == true end

local function Readable(v)
  return v ~= nil and not C.IsSecret(v)
end

function Auto.IsModifierHeld()
  return C.Call(IsShiftKeyDown) == true
end

-- NPC GUID "Creature-0-...-<npcID>-..." -> npcID, or nil
local function NpcID(unit)
  local guid = C.Call(UnitGUID, unit)
  if not Readable(guid) or type(guid) ~= "string" then return nil, guid == nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind == "Creature" or kind == "Vehicle" then return tonumber(id), true end
  return nil, true
end

-- Questie: leave the interaction manual when the NPC can't be checked
local function AllowedNPC(unit)
  local npcID, readable = NpcID(unit)
  if not readable then return false end
  local L = ns.AutoQuestLists
  return not (npcID and L and L.npcs[npcID])
end

local function CurrentQuestID()
  local id = C.Call(GetQuestID)
  if not Readable(id) or type(id) ~= "number" then return 0 end
  return id
end

-- Route filter: with the guide active and autoRouteOnly on, only route quests qualify
local function OnRoute(questID)
  if not (ns.db and ns.db.autoRouteOnly ~= false) then return true end
  local G = ns.Guide
  if not (G and G.IsActive and G.IsActive()) then return true end
  if not questID or questID == 0 then return false end -- unknown quest: stay manual
  return G.IsRouteQuest(questID)
end

local function AllowedToAccept(questID)
  local L = ns.AutoQuestLists
  if L and questID > 0 and L.accept[questID] then return false end
  return OnRoute(questID)
end

local function AllowedToTurnIn(questID)
  local L = ns.AutoQuestLists
  return not (L and questID > 0 and L.turnIn[questID])
end

-- Off the route (guide inactive or route filter off) we skip grey and repeatable quests
local function WantAvailable(q)
  if type(q) ~= "table" then return false end
  local id = Readable(q.questID) and q.questID or 0
  if id > 0 and ns.AutoQuestLists and ns.AutoQuestLists.accept[id] then return false end
  local G = ns.Guide
  local routeFilter = ns.db and ns.db.autoRouteOnly ~= false and G and G.IsActive and G.IsActive()
  if routeFilter then return id > 0 and G.IsRouteQuest(id) end
  return not q.isTrivial and not q.repeatable
end

-- Quest dialog events ---------------------------------------------------------------

local function OnQuestDetail()
  if not (shouldRun and Enabled("autoAccept")) or Auto.IsModifierHeld() then return end
  if not AllowedNPC("questnpc") then return end
  local id = CurrentQuestID()
  if id == 0 or not AllowedToAccept(id) then return end
  C.Call(AcceptQuest)
end

local function OnQuestProgress()
  if not (shouldRun and Enabled("autoTurnIn")) or Auto.IsModifierHeld() then return end
  if not C.Call(IsQuestCompletable) then return end
  if not (AllowedToTurnIn(CurrentQuestID()) and AllowedNPC("questnpc")) then return end
  C.Call(CompleteQuest)
end

local function OnQuestComplete()
  if not (shouldRun and Enabled("autoTurnIn")) or Auto.IsModifierHeld() then return end
  local choices = C.Call(GetNumQuestChoices) or 0
  if not Readable(choices) or choices > 1 then return end -- the player picks the reward
  if not (AllowedToTurnIn(CurrentQuestID()) and AllowedNPC("questnpc")) then return end
  C.Call(GetQuestReward, 1)
end

local function OnQuestAcceptConfirm()
  if not Enabled("autoAccept") then return end
  C.Call(ConfirmAcceptQuest)
end

-- Gossip NPC (modern C_GossipInfo; selectors take quest IDs)
local function OnGossipShow()
  if not shouldRun then return end
  if Auto.IsModifierHeld() or not AllowedNPC("npc") then shouldRun = false; return end
  local G = C_GossipInfo
  if not G then return end

  if Enabled("autoTurnIn") and type(G.GetActiveQuests) == "function" then
    for _, q in ipairs(C.Call(G.GetActiveQuests) or {}) do
      if q.isComplete and Readable(q.questID) and AllowedToTurnIn(q.questID) then
        C.Call(G.SelectActiveQuest, q.questID)
        return
      end
    end
  end

  if Enabled("autoAccept") and type(G.GetAvailableQuests) == "function" then
    for _, q in ipairs(C.Call(G.GetAvailableQuests) or {}) do
      if WantAvailable(q) then
        C.Call(G.SelectAvailableQuest, q.questID)
        return
      end
    end
  end
end

-- Classic-style quest greeting (numbered list)
local function OnQuestGreeting()
  if not shouldRun then return end
  if Auto.IsModifierHeld() or not AllowedNPC("npc") then shouldRun = false; return end

  if Enabled("autoTurnIn") then
    for i = 1, C.Call(GetNumActiveQuests) or 0 do
      local _, isComplete = C.Call(GetActiveTitle, i)
      local id = C.Call(GetActiveQuestID, i)
      if isComplete and (not Readable(id) or AllowedToTurnIn(id)) then
        C.Call(SelectActiveQuest, i)
        return
      end
    end
  end

  if Enabled("autoAccept") then
    for i = 1, C.Call(GetNumAvailableQuests) or 0 do
      -- Forever returns the quest ID as the 5th value (see Questie GetQuestGreetingQuestID)
      local isTrivial, _, isRepeatable, _, id = C.Call(GetAvailableQuestInfo, i)
      if WantAvailable({ questID = id, isTrivial = isTrivial, repeatable = isRepeatable }) then
        C.Call(SelectAvailableQuest, i)
        return
      end
    end
  end
end

-- Re-enable after Shift once every quest window has closed. Wait a moment: between
-- dialogs there is a short gap where all windows are closed (Questie).
local function Visible(f) return f ~= nil and f.IsVisible and f:IsVisible() end
local function AllQuestWindowsClosed()
  return not (Visible(GossipFrame) or Visible(QuestFrameGreetingPanel) or Visible(QuestFrameDetailPanel)
    or Visible(QuestFrameProgressPanel) or Visible(QuestFrameRewardPanel))
end

local function StartStoppedTalkingTimer()
  if not (C_Timer and C_Timer.After) then shouldRun = true; return end
  C_Timer.After(0.5, function()
    if not shouldRun and AllQuestWindowsClosed() then shouldRun = true end
  end)
end

ns.Listen("INIT", function()
  ns.On("QUEST_DETAIL", OnQuestDetail)
  ns.On("QUEST_PROGRESS", OnQuestProgress)
  ns.On("QUEST_COMPLETE", OnQuestComplete)
  ns.On("QUEST_ACCEPT_CONFIRM", OnQuestAcceptConfirm)
  ns.On("GOSSIP_SHOW", OnGossipShow)
  ns.On("QUEST_GREETING", OnQuestGreeting)
  ns.On("GOSSIP_CLOSED", StartStoppedTalkingTimer)
  ns.On("QUEST_FINISHED", StartStoppedTalkingTimer)
end)
