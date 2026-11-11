-- Map pin points (Guide/Engine.lua E.TargetPoints): real Valley of Trials data.
return function(T)
  local function E()
    local ns = T.addon("Horde", "WARRIOR")
    T.needModule(ns, "GuideEngine")
    if not ns.GuideEngine.TargetPoints then T.skip("E.TargetPoints not implemented") end
    return ns.GuideEngine
  end

  T.test("pins: accept / turn-in point at the quest NPC, objective points at every spawn", function()
    local G = E()
    local giver = G.TargetPoints(788, "ACCEPT", nil, 1411)
    T.ok(#giver >= 1, "788 has a giver on Durotar")
    T.eq(giver[1].role, "giver"); T.eq(giver[1].name, "Gornek"); T.eq(giver[1].kind, "npc")
    T.ok(giver[1].x > 0 and giver[1].x < 100 and giver[1].y > 0 and giver[1].y < 100, "map percent coordinates")

    local fin = G.TargetPoints(788, "TURNIN", nil, 1411)
    T.eq(fin[1] and fin[1].role, "finisher")

    local boars = G.TargetPoints(788, "OBJECTIVE", 1, 1411)
    T.ok(#boars >= 5, "Mottled Boar spawns: " .. #boars)
    for _, p in ipairs(boars) do
      T.eq(p.map, 1411, "map filter"); T.eq(p.role, "kill"); T.eq(p.name, "Mottled Boar")
    end
    print(string.format("INFO  pins: 788 giver %s at %.1f,%.1f; %d Mottled Boar spawns", giver[1].name, giver[1].x, giver[1].y, #boars))
  end)

  T.test("pins: item objectives point at the drop sources; cap and unknown quest", function()
    local G = E()
    local loot = G.TargetPoints(789, "OBJECTIVE", 1, 1411) -- Sting of the Scorpid: item from Scorpid Workers
    T.ok(#loot >= 1, "789 item has drop-source spawns")
    T.eq(loot[1].role, "loot")
    T.eq(#G.TargetPoints(788, "OBJECTIVE", 1, 1411, 3), 3, "max caps the count")
    T.eq(#G.TargetPoints(8999998, "ACCEPT"), 0, "unknown quest: no points")
    T.eq(#G.TargetPoints(788, "OBJECTIVE", 1, 123456), 0, "other map: no points")
  end)
end
