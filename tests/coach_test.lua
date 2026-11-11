-- Coach text (Guide/Coach.lua): distances (no compass), talk/objective/other blocks, "then" line.
return function(T)
  local function C()
    local ns = T.addon("Horde", "WARRIOR")
    T.needModule(ns, "GuideCoach", "GuideBlocks")
    return ns
  end

  local function joined(lines) return table.concat(lines, " | ") end

  local function view(current, list, player)
    return { current = current, list = list, primaryId = current[1] and current[1].id, player = player }
  end

  T.test("coach: distances are rounded; no compass words anywhere", function()
    local Co = C().GuideCoach
    local p = { map = 1411, x = 50, y = 50 }
    T.eq(Co.Distance(p, { map = 1411, x = 50.1, y = 50, distance = 8, label = "O" }), "here")
    T.eq(Co.Distance(p, { map = 1411, x = 60, y = 50, distance = 123, label = "O" }), "120 yd")
    T.eq(Co.Distance(p, { map = 1411, x = 60, y = 50, distance = 43, label = "O" }), "45 yd")
    T.eq(Co.Distance(p, { label = "U" }), nil, "unknown location says nothing")
    T.eq(Co.Distance(p, { map = 1, x = 1, y = 1, label = "E" }), "another zone")
    T.eq(Co.Direction, nil, "no compass helper")
  end)

  T.test("coach: talk block says who, how far, and what to turn in / accept", function()
    local ns = C()
    local list = {
      { id = "t1", type = "TURNIN", status = "ACTIVE", npc = "Gornek", quest = { name = "Cutting Teeth" } },
      { id = "a1", type = "ACCEPT", status = "WAITING", npc = "Gornek", quest = { name = "Wayward Weapons" } },
      { id = "a2", type = "ACCEPT", status = "WAITING", npc = "Gornek", quest = { name = "Sting of the Scorpid" } },
      { id = "o1", type = "OBJECTIVE", status = "WAITING", subject = { verb = "Kill", kind = "npc", name = "Scorpid Worker" } },
    }
    local v = view({ { id = "t1", type = "TURNIN", status = "ACTIVE",
      target = { map = 1411, x = 40, y = 60, distance = 40, label = "O" } } }, list, { map = 1411, x = 50, y = 50 })
    local blocks, cur = ns.GuideBlocks.Build(v.list, v.primaryId)
    local text = joined(ns.GuideCoach.Lines(v, blocks, cur))
    T.eq(text, "Go to {n}Gornek{/n} (40 yd). | Turn in {q}Cutting Teeth{/q}, accept {q}Wayward Weapons{/q} and {q}Sting of the Scorpid{/q}. | Then kill {m}Scorpid Worker{/m}.")
    for _, w in ipairs({ "north", "south", "east", "west" }) do T.ok(not text:find(w), "no compass word: " .. w) end

    v.current[1].target.distance = 6
    text = joined(ns.GuideCoach.Lines(v, blocks, cur))
    T.ok(text:find("Talk to {n}Gornek{/n}.", 1, true), "standing next to the NPC: " .. text)
  end)

  T.test("coach: nearby objectives are one trip, with counts and the minimap hint", function()
    local ns = C()
    local list = {
      { id = "o1", type = "OBJECTIVE", status = "ACTIVE", progress = { cur = 4, max = 10 },
        subject = { verb = "Kill", kind = "npc", name = "Mottled Boar" } },
      { id = "t1", type = "TURNIN", status = "WAITING", npc = "Gornek", quest = { name = "Cutting Teeth" } },
    }
    local current = {
      { id = "o1", type = "OBJECTIVE", status = "ACTIVE", target = { map = 1411, x = 60, y = 50, distance = 150, label = "O" } },
      { id = "o9", type = "OBJECTIVE", status = "ACTIVE", progress = { cur = 1, max = 5 },
        subject = { verb = "Collect", kind = "item", name = "Abandoned Training Weapon" } },
    }
    local v = view(current, list, { map = 1411, x = 50, y = 50 })
    local blocks, cur = ns.GuideBlocks.Build(v.list, v.primaryId)
    local text = joined(ns.GuideCoach.Lines(v, blocks, cur))
    T.eq(text, "Same trip (150 yd): Kill {m}Mottled Boar{/m} 4/10 and Collect {i}Abandoned Training Weapon{/i} 1/5. | Follow the dots on your minimap. | Then turn in at {n}Gornek{/n}.")
  end)

  T.test("coach: single objective, waiting step explains why, empty without a current block", function()
    local ns = C()
    local list = { { id = "o1", type = "KILL", status = "WAITING", progress = { cur = 0, max = 1 },
      subject = { verb = "Kill", kind = "npc", name = "Sarkoth" } } }
    local v = view({ { id = "o1", type = "KILL", status = "WAITING", why = "Requires level 4",
      target = { map = 1411, x = 50, y = 70, distance = 200, label = "E" } } }, list, { map = 1411, x = 50, y = 50 })
    local blocks, cur = ns.GuideBlocks.Build(v.list, v.primaryId)
    local text = joined(ns.GuideCoach.Lines(v, blocks, cur))
    T.eq(text, "Kill {m}Sarkoth{/m} 0/1 (200 yd). | Follow the dots on your minimap. | Requires level 4.")
    T.eq(ns.GuideCoach.Lines(nil), {}, "no view")
    T.eq(ns.GuideCoach.Lines(view({}, {}, nil), {}, nil), {}, "no current block")
  end)

  T.test("coach: real engine view produces instructions for the Valley of Trials", function()
    local F = T.fixture("engine_routes")
    local ns = T.sandbox("Horde", "WARRIOR")
    T.needModule(ns, "GuideCoach", "GuideBlocks", "GuideEngine", "Guides")
    ns.Guides.Reset()
    F.registerHorde(ns)
    local route = ns.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    local v = ns.GuideEngine.Evaluate(route, T.state{ level = 2, time = 1, map = 1411, x = 43.3, y = 68.5,
      completed = { [4641] = true }, log = { [788] = { complete = false, objectives = { { fulfilled = 3, required = 10 } } } } },
      ns.GuideEngine.NewMemory())
    local blocks, cur = ns.GuideBlocks.Build(v.list, v.primaryId)
    local lines = ns.GuideCoach.Lines(v, blocks, cur)
    print("INFO  coach (VoT, Cutting Teeth 3/10): " .. joined(lines))
    T.ok(joined(lines):find("Kill {m}Mottled Boar{/m} 3/10", 1, true), "names the creature and the count")
  end)
end
