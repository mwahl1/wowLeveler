# RestedXP technical reference review

**Subject:** [RestedXP/RXPGuides](https://github.com/RestedXP/RXPGuides), commit `7a61814` (2026-11-10). Read-only shallow clone in the session scratchpad.
**Reviewers:** wow-addon-engineer (engine, events, navigation logic, persistence, Forever APIs), ui-ux-engineer (UI and interaction), qa-engineer (step types, performance, robustness, testing). All three reviews are complete.
**License:** CC BY-NC-SA 4.0. Its NonCommercial and ShareAlike terms are incompatible with our GPLv3, so **no code, route content, text or assets were copied or reused, and nothing from the repository was executed**. Techniques are recorded here in our own words; file references let anyone check them.

## Source files examined

| RXP file | Topics | What we looked at |
|---|---|---|
| `RXPGuides.toc` (+ `_TBC`, `_Vanilla`) | 1, 10 | One TOC listing several interfaces (incl. `16001`), per-game-type file gating |
| `RXPGuides.lua` | 1, 2, 5, 6, 7, 8, 10 | Forever detection (interface range, `WOW_PROJECT_CAMELOT`), shared update ticker and job round-robin, low-FPS/loading-screen pauses, error rate-limiting, GUID-stamped progress, cache reset on version/locale change, step visibility filters, combat-deferred settings |
| `functions.lua` | 2, 3, 8, 9, 10 | Step/element catalogue and per-type event tables; accept/turn-in grace windows; objective caching and server-request throttle; death skip; hearth, fly, flight-path, vendor and trainer elements; XP elements; Questie `IsDoable` hook; native waypoint set/clear; aura-secrecy handling |
| `GuideWindow.lua` | 3, 5, 6, 8 | Step progression around a saved index, sticky steps, `completewith`/`requires`, current-step frame, dimming completed rows, resize behaviour |
| `GuideLoader.lua` | 1, 7 | Lazy guide parsing with a per-frame time budget, compressed cache, coroutine imports |
| `QuestLog.lua` | 8, 10 | Expected-quest-log replay, orphan-quest cleanup, Forever quest log size |
| `map.lua` | 4, 5, 7 | Arrow frame and update thresholds, world-vector distance, wrong-continent state, nearest-of-N targets, patrol paths, pooled and merged map/minimap pins, route lines |
| `UI/V2/Core.lua` | 5 | Collapsed/expanded window heights, saved list height |
| `SettingsPanel.lua` | 5 | Settings structure (scale, fonts, arrow, pins, lock/hide toggles), combat deferral |
| `Themes.lua` | 5 | Theme tables and register/import API |
| `ActiveItemFrame.lua`, `Bindings.xml` | 5 | Secure item button, combat-lockdown handling, CLICK keybinds |
| `Targeting.lua` | 10 | Forever restriction on raid-marker automation |
| `LevelingTracker.lua` | 7, 9 | /played per level, deaths, XP per turn-in |
| `libs/compatibility.lua`, `Tips.lua` | 10 | Secret-value guards |
| `.github/workflows/package.yml` | 8 | CI scope (packaging only: no tests or linting) |

**Not examined:** route content under `Guides/`, beyond confirming which step keywords exist (licensed content, out of scope).

## Technical approaches we learned

**Events and quest state**
- Each step-element type declares the events it needs. Events are registered only after a validity check (`C_EventUtils.IsEventValid`), and the noisy global `QUEST_LOG_UPDATE` is avoided.
- **Grace windows:** a quest counts as turned in for a few seconds after `QUEST_TURNED_IN`, because the completed-quest API lags behind the event.
- Objective text that hasn't loaded yet isn't cached, and server data requests are throttled.

**Performance**
- One shared ticker (about 75 ms) runs jobs round-robin, with work spread across frames in adaptive batches.
- It pauses on loading screens, while hidden and at low FPS, stops after repeated errors, and limits error reports to one every 30 s.
- Guides are parsed lazily with a per-frame time budget.

**Navigation**
- World coordinates give cross-zone distances and a "wrong continent" state.
- The arrow re-rotates only when the angle changes by more than about π/64, and rewrites its text only when the whole-yard distance changes.
- Multi-spawn targets use the nearest spawn, nearby pins are merged, and frames come from pools.
- The native Blizzard waypoint is cleared only if RXP set it.

**Persistence**
- Progress is stamped with the player GUID, which catches a deleted and recreated character with the same name.
- Caches are reset when the game version or locale changes.

**UI**
- Separate current-step and full-list views, and completed rows dimmed.
- A settings panel for scale, fonts, arrow, pins and locking, which can't be opened in combat.
- Themes, and a secure active-item button with keybinds.

**Step types relevant to speedrunning**
- Hearthstone and bind location, hearth batching and cooldown, flight paths learned and taken.
- Zone and explore triggers, and death skip using spirit-healer locations.
- Vendor, trainer, buy, use and equip.
- XP targets and maximum level.
- Quest-state conditions on any step.

**Measurement:** /played per level, deaths, and the XP reported with each turn-in.

**Forever facts observed by RXP** (label O, unverified by us):
- quest log size is 40;
- `UnitName` returns two parts;
- aura secrecy is checked via `C_Secrets.ShouldAurasBeSecret()`;
- raid-marker automation is blocked.

**Weaknesses noted:**
- The saved step index is authoritative, so recovery is mostly forward-only.
- There are no tests or linting.
- The window re-lays out every frame while resizing.
- The default font is small (size 9).
- The settings are very dense.

## Comparison

**We are already equal or better:**
- **Recovery:** progress is derived from quest state, with implied-done, backlog and returns.
- **Availability:** a pure, offline port of Questie's rules, so Questie isn't needed at runtime.
- **Missing data:** unknowns are never treated as done.
- **Secret values:** guarded in every getter, not just a few call sites.
- **Tests:** 135 Lua tests, 40 Python tests, a data validator and performance budgets.
- **Honest labels:** the UI shows verified, observed, estimated or unknown for each value.
- **Readability:** larger default type and a compact-by-default card.
- **Timing:** STEP_DONE events for route measurement.

**Not adopted** (our architecture stays):
- an authoritative saved step index;
- text guides parsed at runtime;
- a runtime dependency on Questie;
- the Ace3 libraries.

## Improvements we're incorporating

| # | Improvement | Priority | Owner | Status |
|---|---|---|---|---|
| 1 | Turn-in grace: keep turned-in quests as pending until the completed-quest API reports them | High | wow-addon-engineer | **Done** (commit `8b6ce33`) |
| 2 | Pause evaluation during loading screens; ignore a quest log that suddenly empties; DONE hysteresis (2 evaluations) | High | wow-addon-engineer | In progress (batch 4) |
| 3 | Record actual XP from `QUEST_TURNED_IN` and `/played` from `TIME_PLAYED_MSG` (so E labels can become V) | High | wow-addon-engineer | In progress (batch 4) |
| 4 | Offline route linter in the test suite | High | qa-engineer | In progress (batch 4) |
| 5 | Native waypoint through Compat; never clear a pin we didn't set; never for U targets | High | wow-addon-engineer + ui-ux-engineer | In progress (batch 4) |
| 6 | Combat mode (fade, force compact, hide quest list), lock frames, font-size scale, step-done flash | High | ui-ux-engineer | In progress (batch 4) |
| 7 | Quest-log capacity (`logCount`/`logMax`, warning; fallback 40 labelled O for the optimizer) | Med | wow-addon-engineer, route-optimizer | In progress (engine side, batch 4) |
| 8 | GUID stamp on saved guide memory | Med | wow-addon-engineer | In progress (batch 4) |
| 9 | Quest-log snapshot cache; rate-limited error reports; stop the ticker after repeated failures | Med | wow-addon-engineer | In progress (batch 4) |
| 10 | Partial objectives (step `count`) | Med | wow-addon-engineer | In progress (batch 4) |
| 11 | Probe additions: quest log size API, `C_Secrets`, two-part `UnitName`, native waypoint API | Low | wow-addon-engineer | In progress (batch 4) |
| 12 | Hearth cooldown as state (HEARTH_USE waits with remaining time) | Med | wow-addon-engineer | Planned |
| 13 | New step types: USE (item), SELL/VENDOR, EXPLORE trigger (probe first) | Med | lead (spec) → wow-addon-engineer | Planned |
| 14 | Orphan quests (in log, not in route) as optional abandon suggestions | Med | wow-addon-engineer + ui-ux-engineer | Planned |
| 15 | Cross-map distance and wrong-continent state (continent per map in `Data/Meta`) | Med | quest-data-engineer → wow-addon-engineer | Planned |
| 16 | Own arrow (thresholded redraw, nearest-of-N, hidden without facing), map/minimap pins, settings panel, active-item button | Med | ui-ux-engineer (+ Compat probes) | Planned (P3) |
| 17 | XP-rate setting for the optimizer; licence-compatible spirit-healer locations (never RXP's table) | Low | route-optimizer, quest-data-engineer | Planned |

All statuses are offline only. Nothing is verified in game yet.
