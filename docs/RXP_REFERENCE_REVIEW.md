# RestedXP technical reference review

Reviewed: [RestedXP/RXPGuides](https://github.com/RestedXP/RXPGuides) at `7a61814` (2026-11-10), read-only, by three agents (engine, UI, QA). Nothing from that repository was executed, copied, or reused.

**License:** CC BY-NC-SA 4.0. Its NonCommercial and ShareAlike terms are incompatible with our GPLv3, so **no code, route content, text, or assets may be reused**. This document records techniques in our own words only. RXP's TOC lists interface `16001`, so it supports Forever.

## What RestedXP does well
- **Breadth of step types:** hearth batching and cooldown, item use, vendor/sell, equip, money, explore triggers, death skip with spirit-healer locations, flight-path learning, XP targets, and quest-state conditions on any step.
- **Event discipline:** element types declare their own events; events are registered only after a validity check; the global `QUEST_LOG_UPDATE` is avoided; **grace windows** cover the lag between turn-in/accept events and the completed-quest API.
- **Frame-time adaptivity:** one shared ticker running jobs round-robin; work batched across frames; pauses on loading screens and at low FPS; stops after repeated errors and rate-limits error reports; guides parsed lazily.
- **Navigation polish:** world coordinates across zones with a "wrong continent" state; the arrow redraws only when the angle or whole-yard distance changes; nearest-of-N targets; nearby pins merged; a native Blizzard waypoint that is cleared only if RXP set it.
- **Persistence hygiene:** progress stamped with the player GUID (catches recreated characters); caches reset on game version or locale change.
- **Measurement:** /played per level, deaths, and actual XP per turn-in.
- **Forever specifics (observed by RXP, unverified by us):** quest log size 40, `UnitName` returns two parts, aura secrecy via `C_Secrets.ShouldAurasBeSecret()`, raid-marker automation blocked.

## What we already handle as well or better
- **Recovery:** progress is *derived* from quest state, with implied-done, backlog and returns. RXP treats a saved step index as authoritative and recovers mostly forwards.
- **Availability:** a pure, offline port of Questie's `IsDoable`. RXP needs Questie installed at runtime.
- **Unknowns are never treated as satisfied** (`completed = nil`, secret values, missing APIs → UNKNOWN or manual confirm). RXP guards only a few call sites.
- **Offline test suite:** 135 Lua + 40 Python tests, a data validator, and performance budgets. RXP has **no tests and no linting**; its CI only packages the addon.
- **Honest labels in the UI** (verified/observed/estimated/unknown); RXP shows no confidence information.
- **Larger default type** and a compact-by-default card.
- **STEP_DONE timing events** for route measurement.

## What we're missing (prioritized)
| # | Improvement | Priority | Effort | Owner |
|---|---|---|---|---|
| 1 | Loading-screen gate (no evaluation between leaving and entering the world, +1 s; ignore a log that suddenly empties) and DONE hysteresis (a step must stay not-done for 2 evaluations before `memory.done` clears) | High | S | wow-addon-engineer |
| 2 | Recorder: actual XP from `QUEST_TURNED_IN` and `/played` from `TIME_PLAYED_MSG`, so E XP/time labels can become V | High | S | wow-addon-engineer |
| 3 | Offline route linter: every `Guides/` file compiles, quest IDs exist, no errors | High | S | qa-engineer |
| 4 | Native waypoint (`C_Map.SetUserWaypoint` + super-track; never clear a pin we didn't set; never for U targets) | High | S | wow-addon-engineer (Compat) + ui-ux |
| 5 | Combat mode (fade, force compact, hide quest list), lock frames, font-size scale | High | S | ui-ux |
| 6 | Quest-log capacity: `state.logCount`/`logMax` (probe `C_QuestLog.GetMaxNumQuestsCanAccept`, fallback 40 labelled O), view warning, optimizer constraint | Med | M | wow-addon-engineer, route-optimizer |
| 7 | GUID stamp on `CharDB.guide`; mismatch resets skips, confirms and facts | Med | S | wow-addon-engineer |
| 8 | Quest-log cache marked dirty by quest events; position-only evaluations reuse it. Rate-limit evaluation error reports | Med | S | wow-addon-engineer |
| 9 | Optional `count` on OBJECTIVE/KILL steps (partial objectives) | Med | S | lead (spec) → engine, optimizer |
| 10 | Hearth cooldown as state (HEARTH_USE WAITING with remaining time) | Med | S | wow-addon-engineer |
| 11 | New step types USE (item), SELL/VENDOR; EXPLORE trigger (probe first) | Med | M | lead (spec) → engine |
| 12 | Orphan quests (in log, not in route) shown as optional abandon suggestions | Med | S | engine + ui |
| 13 | Cross-map distance / wrong-continent state (continent per map in `Data/Meta`) | Med | M | quest-data-engineer → engine |
| 14 | Own arrow (thresholded redraw, nearest-of-N, hidden when facing is unavailable), map/minimap pins, settings panel, active-item button | Med | M | ui-ux (+ Compat probes) |
| 15 | Probe checklist additions: quest log size, `C_Secrets`, resurrection spell, two-part `UnitName` | Low | S | wow-addon-engineer |
| 16 | XP-rate setting for the optimizer; licence-compatible spirit-healer locations (never RXP's table) | Low | S/M | route-optimizer, quest-data-engineer |

## Not adopted
- An authoritative saved step index.
- Text guides parsed at runtime.
- A runtime dependency on Questie.
- The Ace3 libraries.

Our derived-state engine, QuestieDB pipeline and pure, testable modules remain the architecture.
