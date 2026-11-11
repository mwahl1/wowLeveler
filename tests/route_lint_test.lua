-- Route linter (RXP review recommendation 1): every route file under Guides/ is loaded into a
-- fresh namespace (real data), compiled for every faction x race x class, and must compile with
-- no ERROR problems. Warnings are reported as INFO counts. Start routes must open with an ACCEPT
-- of a quest the race can take at level 1.

local RACES = { Horde = { 2, 5, 6, 8, 96 }, Alliance = { 1, 3, 4, 7, 95 } }

-- Never in a route (spec 8a blacklist layer; explicit regression list besides the flag check)
local BANNED = { [787] = "The New Horde (Questie blacklist)", [5805] = "Welcome!", [5841] = "Welcome!",
  [5842] = "Welcome!", [5843] = "Welcome!", [5844] = "Welcome!", [5847] = "Welcome!" }

local function routeFiles(T)
  return T.listFiles("Guides", ".lua") -- portable listing from tools/run_tests.lua
end

local function contains(list, v)
  if list == nil then return true end
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

return function(T)
  local files = routeFiles(T)
  local fresh = {} -- faction -> namespace (one fresh load per faction for the whole linter)

  local function nsFor(faction)
    fresh[faction] = fresh[faction] or T.fresh(faction, "WARRIOR")
    return fresh[faction]
  end

  local function loadRoutes(ns, path)
    ns.Guides.Reset()
    local chunk, err = loadfile(path)
    if not chunk then error("cannot load " .. path .. ": " .. tostring(err), 0) end
    local ok, runErr = pcall(chunk, "LevelingNavigator", ns)
    if not ok then error("running " .. path .. ": " .. tostring(runErr), 0) end
  end

  if #files == 0 then
    T.test("route lint: Guides/*.lua", function() T.skip("no route files under Guides/ yet") end)
    return
  end

  for _, path in ipairs(files) do
    for _, faction in ipairs({ "Horde", "Alliance" }) do
      T.test("route lint: " .. path .. " compiles with no errors (" .. faction .. ", all races x classes)", function()
        local ns = nsFor(faction)
        T.needModule(ns, "Guides")
        loadRoutes(ns, path)
        local errors, warnCodes, combos, nSteps = {}, {}, 0, 0
        for _, raceID in ipairs(RACES[faction]) do
          for _, class in ipairs(T.CLASSES) do
            combos = combos + 1
            local route, problems = ns.Guides.Compile({ faction = faction, raceID = raceID, classFile = class })
            nSteps = math.max(nSteps, route and #route.steps or 0)
            for _, p in ipairs(problems or {}) do
              if p.severity == "error" then
                errors[#errors + 1] = string.format("race %d %s: %s %s", raceID, class, tostring(p.code), tostring(p.msg))
              else
                local key = tostring(p.code) .. (p.code == "no_start" and (" r" .. raceID) or "")
                warnCodes[key] = (warnCodes[key] or 0) + 1
              end
            end
          end
        end
        local parts = {}
        for code, n in pairs(warnCodes) do parts[#parts + 1] = code .. "=" .. n end
        table.sort(parts)
        print(string.format("INFO  lint %s %s: %d combos, max %d steps, %d errors, warnings {%s}",
          path, faction, combos, nSteps, #errors, table.concat(parts, ", ")))
        T.eq(#errors, 0, "compile errors: " .. table.concat(errors, " | ", 1, math.min(#errors, 5)))
      end)

      T.test("route lint: " .. path .. " references no BLACKLISTED quest, 787, or Welcome! quests (" .. faction .. ")", function()
        local ns = nsFor(faction)
        T.needModule(ns, "Guides")
        loadRoutes(ns, path)
        local F = ns.DataSchema.QUEST_FLAGS
        local B = F and F.BLACKLISTED
        local bad, seen = {}, 0
        local function checkStep(defId, step)
          local q = step.quest
          if not q then return end
          seen = seen + 1
          if BANNED[q] then bad[#bad + 1] = string.format("%s %s: quest %d (%s)", defId, tostring(step.id), q, BANNED[q]) end
          local rec = ns.Data.GetQuest(q)
          local flags = rec and rec[ns.DataSchema.Q.FLAGS]
          if B and type(flags) == "number" and math.floor(flags / B) % 2 == 1 then
            bad[#bad + 1] = string.format("%s %s: quest %d is BLACKLISTED", defId, tostring(step.id), q)
          end
        end
        for _, raceID in ipairs(RACES[faction]) do
          local route = ns.Guides.Compile({ faction = faction, raceID = raceID, classFile = "WARRIOR" })
          for _, step in ipairs(route and route.steps or {}) do checkStep(tostring(step.segment), step) end
        end
        print(string.format("INFO  lint %s %s: %d quest steps checked for blacklist%s", path, faction, seen,
          B and "" or " (BLACKLISTED flag not in schema yet: only the explicit list checked)"))
        T.eq(#bad, 0, "blacklisted references: " .. table.concat(bad, " | ", 1, math.min(#bad, 5)))
      end)

      T.test("route lint: " .. path .. " start routes open with a level-1 ACCEPT (" .. faction .. ")", function()
        local ns = nsFor(faction)
        T.needModule(ns, "Guides", "Availability")
        loadRoutes(ns, path)
        local bad, checked = {}, 0
        local reportedStart = {}
        for _, raceID in ipairs(RACES[faction]) do
          for _, class in ipairs(T.CLASSES) do
            local route = ns.Guides.Compile({ faction = faction, raceID = raceID, classFile = class })
            local startId = route and route.order[1]
            local seg = startId and route.segments[startId]
            if seg and seg.def.kind == "start" then
              local def = seg.def
              local when = type(def.when) == "table" and def.when or nil
              local classOk = contains(def.classes, class) and (not when or contains(when.classes, class))
              if classOk then
                checked = checked + 1
                local step = route.steps[seg.first]
                local tag = string.format("%s race %d %s", startId, raceID, class)
                local key = startId .. "/" .. raceID
                if step and not reportedStart[key] then
                  reportedStart[key] = true
                  local q = step.quest and ns.Data.GetQuest(step.quest)
                  local name = q and q[ns.DataSchema.Q.NAME] or "?"
                  print(string.format("INFO  lint start %s race %d: first step %s %s %s \"%s\"",
                    startId, raceID, tostring(step.id), tostring(step.type), tostring(step.quest), tostring(name)))
                end
                if not step then
                  bad[#bad + 1] = tag .. ": no steps"
                elseif step.type ~= "ACCEPT" then
                  bad[#bad + 1] = tag .. ": first step " .. tostring(step.id) .. " is " .. tostring(step.type)
                else
                  local st = T.state{ faction = faction, raceID = raceID, classFile = class, level = 1 }
                  local s, r = ns.Availability.Check(step.quest, st)
                  if s ~= "AVAILABLE" then
                    bad[#bad + 1] = tag .. ": first quest " .. tostring(step.quest) .. " is " .. tostring(s) .. " (" .. tostring(r) .. ")"
                  end
                end
              end
            end
          end
        end
        print(string.format("INFO  lint %s %s: %d start openings checked, %d problems", path, faction, checked, #bad))
        T.eq(#bad, 0, "start openings: " .. table.concat(bad, " | ", 1, math.min(#bad, 5)))
      end)
    end
  end
end
