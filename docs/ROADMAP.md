# Roadmap & status

Product goals: (1) **leveling speed**, i.e. the shortest practical /played time from 1 to 60, and (2) **user experience**, a polished overlay that makes the fastest route effortless.

Status labels: **planned** → **implemented** (code written) → **tested** (run in game) → **verified** (works as specified in game).

## Current status
- **Priority:** P0 (in-game test pending) and P1 in parallel
- **Milestones:** M1 implemented, untested in game. M2 done (toolchain + export verified on Mac). M3 implemented; first full pipeline run pending.
- **Tested in game:** nothing yet
- **Blockers:** game access (P0); GitHub push needs a new token (local commits unpushed)
- **Next task:** run `tools/update_data.sh --no-pull` on the Mac and report the output

## Confirmed decisions
- **D1: Client target.** Forever runs on the Mainline (Retail 12.x) client family; Midnight addon restrictions apply. TOC `## Interface: 16001` (from `Questie_Forever.toc`, 2026-11-10).
- **D2: License.** GPLv3, required to use QuestieDB data.
- **D3: Quest data via QuestieDB, Option A (final).** Generate data with QuestieDB's **own Lua 5.1 tooling and merge logic**, not a Python re-implementation. Official Lua 5.1 source (lua.org) + the QuestieDB repo, pinned to a recorded commit. External commands are reviewed first; where the agent's execution is restricted, the developer runs them locally. The import must be repeatable for QuestieDB updates.
- **D4: Offline route optimizer in Python**, a separate component that consumes the generated data. Routes are precomputed; the in-game engine only does lightweight rerouting.
- **D5: Automation.** Auto accept/turn-in optional, **off by default**, never auto-pick among multiple rewards. No combat or movement automation.
- **D6: Shared routes.** Faction routes + race-specific starts + class instruction layers. No per-race/class 1-60 guides.
- **D7: Data sources excluded.** Wowhead scraping (ToS) and RestedXP guide content (proprietary).

## Data facts (QuestieDB, checked 2026-11-10, commit `aca0da1c4a`)
- Base: 4,244 Classic quests converted to Forever coordinates, plus NPCs/objects/items.
- Forever layers: generated delta-base (1,397 new-quest entries), player-session traces (749 new-quest entries, 724 XP values), authored fixes (532 new-quest entries).
- Support: per-quest XP, areaID→uiMapID mapping, item drop tables.
- Sample check: Gornek 42.06, 68.33 Durotar; Cutting Teeth (788) 170 XP. Matches expectations.
- Caveat: part of the generated layer cites Wowhead. We use it under QuestieDB's offered GPLv3 terms, whose own license notes historic-contributor uncertainty.

## Priorities
| P | Area | Completion criteria | Status |
|---|---|---|---|
| P0 | Foundation & compatibility: probe, character detection, SavedVariables, polished overlay | Loads in Forever without Lua errors, detects character, overlay works, settings survive `/reload` | implemented (M1), untested |
| P1 | Universal quest database: QuestieDB pipeline (D3), all races/classes/factions, verified/observed/estimated/unknown labels, validation reports | Addon can query quests relevant to any character and report missing data without inventing any | research done; pipeline planned |
| P2 | Quest tracking & guide engine: current action, auto-advance, prerequisites, recovery, resume after reload; shared + race + class layers | A verified starting-zone guide can be followed without manual step advancing | live objective tracking implemented (M1); engine planned |
| P3 | Navigation & UI refinement: map/minimap pins, arrow + distance, compact/expanded modes, optional auto accept/turn-in | Starting zone followable with overlay + navigation alone | planned |
| P4 | Speedrun optimization (Python offline + light in-game rerouting): clustering, travel/combat/downtime model, hearth, flights, death skips, grinding, class efficiency | Optimized route shows measurable savings vs recorded baseline, or data gap clearly reported | planned |
| P5 | Full 1-60 coverage: all starts, faction segments, class layers, mid-level join, dungeon routes after open world | Every supported race/class has a connected 1-60 route; verified vs provisional marked | planned |
| P6 | Analytics: XP/hour, time per level, segment comparison | Recorded data identifies and improves inefficient segments | event recorder implemented (M1), untested |
| P7 | Polish & release: bugs, CPU/memory, multi-character tests, docs, repeatable DB update, stable build | Usable by someone outside development | planned |

## Milestones
| M | Priority | Scope | Status |
|---|---|---|---|
| M1 | P0 | Probe (24 API checks), overlay (character, XP, location, live objectives), event recorder, slash commands | implemented, untested |
| M2 | P1 | Lua 5.1 + QuestieDB toolchain set up locally; export of fully corrected Forever data | done: verified on Mac (5,682 quests, 104,905 corrections) |
| M3 | P1 | `tools/build_data.py` → `Data/*.lua` (faction-split, lazily compiled), labels, faction/class corrections, coverage report, Lua 5.1 validator, `tools/update_data.sh`, in-game loader + probe check | implemented; pipeline run with provenance/dynamic export pending |

## Data pipeline (P1)
`tools/update_data.sh` = `git pull` QuestieDB → `tools/questiedb_export.lua` (QuestieDB's own loader + registry, run with Lua 5.1) → `tools/build_data.py` → `tools/validate_data.lua` (runs the addon's real loader for every faction × class). Output: `Data/*.lua`, `docs/DATA_COVERAGE.md`, `docs/data-gaps.csv`.

Design: data files register source strings; at login only Neutral + the player's faction (+ class overrides) are compiled, then the strings are released. Records are positional arrays; index names live in the generated `Data/Schema.lua`. Labels per quest: requirements / start location / finish location / XP, each V/O/E/U.

## Known issues
- Not tested in game yet.
- Skyborne (Horde) starting quests: none in data (the zone's quests are flagged Alliance-only). Re-check after the dynamic-correction export; otherwise a data gap for the recorder.
- Negative prerequisite IDs (Questie convention) are not interpreted yet; reported in DATA_COVERAGE.md.
