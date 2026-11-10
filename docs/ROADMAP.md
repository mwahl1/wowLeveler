# Roadmap & status

Status labels: **verified** (tested in game), **built-untested**, **planned**.

## Verified facts (sources: Questie/QuestieDB repos, Warcraft Wiki, 2026-11-10)
- Forever runs on the Mainline (Retail 12.x) client family. Midnight addon restrictions (secret values) apply.
- Interface number **16001** (from `Questie_Forever.toc`). The `_Forever` TOC suffix is accepted.
- QuestieDB ships `data/Forever`: Classic quests/NPCs/objects converted to Forever coordinates (build 1.60.1). It does **not** include complete new Forever content.
- QuestieDB/Questie licensing: the team permits reuse under GPLv3, but warns that historic contributions are formally unclear. If we bundle their data, this addon must be GPLv3.

## Data strategy (minimize manual collection)
1. **Base layer:** QuestieDB Forever data (quests, NPC/object coords, prerequisites, levels), processed offline into our own compact format.
2. **Live API layer (if the probe confirms it):** Blizzard's own runtime data, i.e. objective waypoints (`C_QuestLog.GetNextWaypoint`), quest POIs on the map, available quest givers (`C_QuestLine.GetAvailableQuestLines`), reward XP. This covers new Forever quests automatically.
3. **Passive recorder:** logs accepts, turn-ins, XP, deaths and travel during normal play. It fills gaps (new quests, timings) without dedicated data runs.
4. **Not used:** Wowhead (ToS forbids scraping) and RestedXP guides (proprietary).

## Phases
| # | Phase | Status |
|---|---|---|
| 1 | Probe + polished overlay (char, XP, location, live objectives, API diagnostics, event recorder) | built-untested |
| 2 | Data pipeline: offline tool turns QuestieDB Forever data into our quest/NPC tables + recorder export | planned |
| 3 | Guide engine + recovery (step state machine, expected vs actual state) + current-step UI | planned |
| 4 | Navigation: arrow, map pins, Blizzard waypoint/super-track | planned |
| 5 | Optional auto accept / turn-in (off by default; never auto-pick among multiple rewards) | planned |
| 6 | Offline route planner (clustering, prerequisite-aware ordering, hearth/flight/death-skip cost model) + in-game local reordering | planned |
| 7 | Content: Horde 1-20 → 60, then Alliance, then dungeon variants | planned |
| 8 | Analytics: XP/hour, time per level, route comparison | planned (recorder already logs raw events) |

## Known issues
- None recorded yet (nothing tested in game).
