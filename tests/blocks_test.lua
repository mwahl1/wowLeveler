-- Step list grouping (Guide/Blocks.lua): synthetic rows plus one pass over the real route.
return function(T)
  local function B()
    local ns = T.addon("Horde", "WARRIOR")
    T.needModule(ns, "GuideBlocks")
    return ns.GuideBlocks
  end

  local function row(id, typ, status, npc)
    return { id = id, type = typ, status = status or "WAITING", npc = npc }
  end

  T.test("blocks: same-NPC accepts/turn-ins merge, objectives merge, other steps stand alone", function()
    local blocks, cur = B().Build({
      row("t1", "TURNIN", "DONE", "Gornek"),
      row("a1", "ACCEPT", "ACTIVE", "Gornek"),
      row("a2", "ACCEPT", "WAITING", "Gornek"),
      row("o1", "OBJECTIVE"), row("o2", "KILL"),
      row("a3", "ACCEPT", nil, "Galgar"),
      row("tr", "TRAIN"), row("go", "GOTO"),
      row("t2", "TURNIN", nil, "Gornek"),
    }, "a1")
    T.eq(#blocks, 6, "Gornek, objectives, Galgar, train, goto, Gornek again")
    T.eq(blocks[1].kind, "talk"); T.eq(blocks[1].npc, "Gornek"); T.eq(#blocks[1].rows, 3)
    T.eq(blocks[2].kind, "objectives"); T.eq(#blocks[2].rows, 2)
    T.eq(blocks[3].npc, "Galgar")
    T.eq(blocks[4].kind, "single"); T.eq(blocks[5].kind, "single")
    T.eq(blocks[6].npc, "Gornek", "same NPC later is a new block")
    T.eq(cur, 1, "current block holds the primary step")
    T.ok(blocks[1].current and not blocks[2].current, "only one current block")
    for i, b in ipairs(blocks) do T.eq(b.number, i, "numbered in order") end
  end)

  T.test("blocks: done only when every row is DONE or SKIPPED; accept/turn-in without NPC stands alone", function()
    local blocks, cur = B().Build({
      row("a", "ACCEPT", "DONE", "X"), row("b", "ACCEPT", "SKIPPED", "X"),
      row("c", "ACCEPT", "DONE", "Y"), row("d", "TURNIN", "ACTIVE", "Y"),
      row("e", "ACCEPT", "WAITING", nil), row("f", "ACCEPT", "WAITING", nil),
    }, "missing-id")
    T.ok(blocks[1].done, "DONE + SKIPPED = done")
    T.ok(not blocks[2].done, "one ACTIVE row = not done")
    T.eq(#blocks, 4, "accepts with unknown NPC are separate single blocks")
    T.eq(cur, nil, "no current block when primaryId is not listed")
    T.eq(#B().Build({}, nil), 0, "empty list")
  end)

  T.test("blocks: real Valley of Trials route groups by NPC (fixture data)", function()
    local F = T.fixture("engine_routes")
    local ns = T.sandbox("Horde", "WARRIOR")
    T.needModule(ns, "GuideBlocks", "GuideEngine", "Guides")
    ns.Guides.Reset()
    F.registerHorde(ns)
    local route = ns.Guides.Compile({ faction = "Horde", raceID = 2, classFile = "WARRIOR" })
    local view = ns.GuideEngine.Evaluate(route, T.state{ level = 1, time = 1 }, ns.GuideEngine.NewMemory())
    local blocks, cur = ns.GuideBlocks.Build(view.list, view.primaryId)
    T.ok(#blocks > 0 and #blocks < #view.list, "fewer blocks than steps")
    T.eq(cur, 1, "a fresh character starts in the first block")
    local rows = 0
    for _, b in ipairs(blocks) do rows = rows + #b.rows end
    T.eq(rows, #view.list, "every row lands in exactly one block")
    print(string.format("INFO  blocks: %d steps -> %d blocks", #view.list, #blocks))
  end)
end
