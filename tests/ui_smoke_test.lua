-- UI smoke test: loads Core/Init, Compat, the UI files and the auto-quest module against a
-- stubbed WoW API (every frame method exists and returns plausible values), then renders the
-- guide window with mock views, a real engine view and nil. Catches Lua errors in our own
-- logic (nil indexing, bad arithmetic, wrong field names); it says nothing about how the
-- window looks or whether Blizzard's real API behaves the same (only the game can show that).
return function(T)
  local function stubObject(kind)
    local o = { _kind = kind, _shown = true, _w = 300, _h = 400, _text = "" }
    local methods = {
      GetWidth = function(self) return self._w end,
      GetHeight = function(self) return self._h end,
      SetWidth = function(self, w) self._w = w end,
      SetHeight = function(self, h) self._h = h end,
      SetSize = function(self, w, h) self._w, self._h = w, h end,
      GetSize = function(self) return self._w, self._h end,
      GetStringWidth = function(self) return #tostring(self._text) * 6 end,
      GetStringHeight = function() return 12 end,
      SetText = function(self, t) self._text = t or "" end,
      GetText = function(self) return self._text end,
      IsShown = function(self) return self._shown end,
      IsVisible = function(self) return self._shown end,
      Show = function(self) self._shown = true end,
      Hide = function(self) self._shown = false end,
      SetShown = function(self, v) self._shown = v and true or false end,
      GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
      GetFrameLevel = function() return 1 end,
      GetVerticalScroll = function() return 0 end,
      GetParent = function(self) return self._parent end,
      CreateTexture = function(self) local t = stubObject("Texture"); t._parent = self; return t end,
      CreateFontString = function(self) local t = stubObject("FontString"); t._parent = self; return t end,
      CreateAnimationGroup = function() return stubObject("AnimationGroup") end,
      CreateAnimation = function() return stubObject("Animation") end,
      SetScript = function(self, name, fn) self["_script_" .. name] = fn end,
      HookScript = function(self, name, fn) self["_hook_" .. name] = fn end,
      GetScript = function(self, name) return self["_script_" .. name] end,
      SetBackdrop = function() end,
    }
    return setmetatable(o, { __index = function(_, k)
      return methods[k] or function() return nil end
    end })
  end

  local function installStubs()
    local frames = {}
    _G.CreateFrame = function(kind, name, parent)
      local f = stubObject(kind)
      f._parent = parent
      if name then _G[name] = f end
      frames[#frames + 1] = f
      return f
    end
    _G.UIParent = stubObject("Frame")
    _G.UISpecialFrames = {}
    _G.tinsert = table.insert
    _G.unpack = unpack
    _G.strsplit = function(sep, s)
      local out = {}
      for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
      return unpack(out)
    end
    _G.GetTime = function() return 1000 end
    _G.InCombatLockdown = function() return false end
    _G.C_Timer = { After = function(_, fn) fn() end }
    _G.print = _G.print
    _G.SlashCmdList = {}
    _G.GetCVar = function() return "1" end
    _G.C_CVar = { GetCVarBool = function() return true end, SetCVar = function() return true end }
    _G.C_Map = {}
    _G.issecretvalue = function() return false end
    -- fake HereBeDragons-Pins: records what MapPins places
    local hbd = { minimap = {}, world = {} }
    function hbd.AddMinimapIconMap(_, ref, icon, map, x, y, showParent, float)
      hbd.minimap[#hbd.minimap + 1] = { ref = ref, icon = icon, map = map, x = x, y = y, float = float }
    end
    function hbd.AddWorldMapIconMap(_, ref, icon, map, x, y) hbd.world[#hbd.world + 1] = { map = map, x = x, y = y } end
    function hbd.RemoveAllMinimapIcons() hbd.minimap = {} end
    function hbd.RemoveAllWorldMapIcons() hbd.world = {} end
    _G.LevelingNavigatorTestHBD = hbd
    _G.LibStub = function(name) if name == "HereBeDragonsLN-Pins-2.0" then return hbd end end
    _G.HBD_PINS_WORLDMAP_SHOW_PARENT = 2
    _G.UnitLevel = function() return 5 end
    _G.UnitXP = function() return 1234 end
    _G.UnitXPMax = function() return 2800 end
    _G.GetXPExhaustion = function() return 300 end
    _G.GetMaxPlayerLevel = function() return 60 end
    return frames
  end

  local function loadUI()
    local frames = installStubs()
    local ns = {}
    for _, path in ipairs({ "Core/Init.lua", "Core/Compat.lua", "UI/Theme.lua", "UI/Widgets.lua",
                            "Guide/Blocks.lua", "Guide/Coach.lua", "Core/AutoQuestLists.lua", "Core/AutoQuest.lua",
                            "UI/GuideWindow.lua", "UI/MapPins.lua", "UI/MockGuideView.lua", "UI/SettingsPanel.lua" }) do
      local chunk = assert(loadfile(path))
      chunk("LevelingNavigator", ns)
    end
    return ns, frames
  end

  -- Fires ADDON_LOADED through Init's real event-bus handler (defaults, migration, INIT)
  local function addonLoaded(frames)
    -- a settings file from the old overlay: waypoint off by accident, window hidden
    _G.LevelingNavigatorDB, _G.LevelingNavigatorCharDB = { ui = { waypoint = false, shown = false, guideWindowV2 = true } }, nil
    for _, f in ipairs(frames) do
      local onEvent = f._script_OnEvent
      if onEvent then onEvent(f, "ADDON_LOADED", "LevelingNavigator") end
    end
  end

  T.test("ui smoke: guide window creates and renders mock views, nil, and a real engine view", function()
    local ns, frames = loadUI()
    addonLoaded(frames)
    T.ok(ns.db ~= nil, "Init's ADDON_LOADED handler ran")
    T.ok(ns.GuideWindow, "GuideWindow module present")
    T.eq(ns.db.ui.waypoint, true, "settings migration turned the waypoint back on")
    T.eq(ns.db.settingsVersion, 2, "settings version stamped")
    T.eq(ns.db.autoRouteOnly, true, "auto accept defaults to route quests only")
    T.eq(ns.db.ui.width, 300, "new window default width")
    T.eq(ns.db.ui.shown, true, "a hidden flag left by the old overlay is cleared once")
    local xpText = ns.GuideWindow.lastXPText or ""
    T.ok(xpText:find("Level 5", 1, true) and xpText:find("1234 / 2800 XP (44%)", 1, true)
      and xpText:find("+300 rested", 1, true), "XP line: " .. xpText)
    ns.db.ui.xpBar = false; ns.GuideWindow.UpdateXP()
    ns.db.ui.xpBar = nil; ns.GuideWindow.UpdateXP()

    for _, v in ipairs({ "main", "start", "train" }) do
      ns.Send("SHOW_MOCK_GUIDE", v)
      local s = ns.GuideWindow.lastStats
      T.ok(s and s.boxLines > 0 and s.listLines > 0 and s.blocks > 0, "mock " .. v .. " drew lines")
    end
    ns.Send("SHOW_MOCK_GUIDE", "off")
    T.eq(ns.GuideWindow.lastStats.blocks, 0, "nil view: no blocks")
    T.eq(ns.GuideWindow.lastStats.boxLines, 1, "nil view: one message line")

    -- Real engine view from the Valley of Trials fixture
    local F = T.fixture("engine_routes")
    local eng = T.sandbox("Horde", "WARRIOR")
    eng.Guides.Reset()
    F.registerHorde(eng)
    local route = eng.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    local view = eng.GuideEngine.Evaluate(route, T.state{ level = 2, time = 5, completed = { [4641] = true },
      log = { [788] = { complete = false, objectives = { { fulfilled = 3, required = 10, finished = false } } } } },
      eng.GuideEngine.NewMemory())
    ns.Send("GUIDE_UPDATED", view)
    local s = ns.GuideWindow.lastStats
    T.eq(s.current, 3, "Cutting Teeth objective: third block (Kaltunk, Gornek, objectives)")
    T.ok(s.tab == "Step 3", "tab shows the block number: " .. tostring(s.tab))
    T.ok(s.listLines >= 2 and s.listLines <= 1 + 3 * 4, "collapsed list: heading + up to 3 blocks (" .. s.listLines .. " lines)")
    local coach = table.concat(ns.GuideWindow.lastCoach or {}, " | ")
    T.ok(coach:find("Mottled Boar", 1, true), "coach text in the box: " .. coach)
    -- Map pins: the real engine view's current step (Kill Mottled Boar) -> a red dot per spawn
    ns.GuideEngine = eng.GuideEngine -- pins read spawn points through the engine
    ns.MapPins.Refresh = ns.MapPins.Refresh -- (exists)
    ns.MapPins.Update(view)
    local hbd = _G.LevelingNavigatorTestHBD
    T.ok(#hbd.minimap >= 5, "minimap pins placed: " .. #hbd.minimap)
    T.eq(#hbd.world, #hbd.minimap, "same pins on the world map")
    T.eq(hbd.minimap[1].map, 1411, "Durotar")
    T.ok(hbd.minimap[1].x > 0 and hbd.minimap[1].x < 1, "HBD gets 0-1 coordinates")
    T.eq(hbd.minimap[1].float, false, "creature dots don't stick to the minimap edge")
    local before = #hbd.minimap
    ns.MapPins.Update(view)
    T.eq(#hbd.minimap, before, "unchanged view: pins not rebuilt or duplicated")
    ns.db.ui.pins = false; ns.MapPins.Refresh()
    T.eq(#hbd.minimap, 0, "pins off in settings: all removed")
    ns.db.ui.pins = nil
    print(string.format("INFO  ui smoke: %d map pins for the current step", before))

    ns.db.ui.fullList = true
    ns.Send("GUIDE_UPDATED", view)
    T.ok(ns.GuideWindow.lastStats.listLines >= #view.list, "full route: every step drawn")
    ns.db.ui.fullList = nil
    ns.Send("GUIDE_UPDATED", view)
    s = ns.GuideWindow.lastStats
    print(string.format("INFO  ui smoke: %d steps, %d blocks, %d list lines, title %q",
      #view.list, s.blocks, s.listLines, tostring(s.title)))
    ns.Send("STEP_DONE", { stepId = view.current[1].id })
    T.ok(ns.GuideWindow.SkipCurrent() == nil or true, "skip without an active guide does not error")

    -- Settings window and layout commands
    ns.Send("SHOW_SETTINGS")
    ns.SettingsPanel.Refresh()
    ns.Send("APPLY_LAYOUT")
    ns.Send("TOGGLE_MAIN"); ns.Send("TOGGLE_MAIN")
  end)
end
