# Progress log

Newest first. Status vocabulary: planned → implemented → offline-tested → verified in game.

## 2026-11-10 (later)
- **P2 waves 1-3** offline-tested: M3.1 availability fields; `Guide/Availability.lua` (Questie IsDoable semantics); `Guide/Conditions.lua`, `Compiler.lua`, `Selector.lua`; `Guide/Engine.lua` (derived status, recovery/backlog, GuideView, STEP_DONE); `Core/GuideState.lua` adapter (inert without route files); guide card UI (compact/expanded, collapsible quest list, `/ln mockguide`). 133 offline tests pass; engine median ~0.9 ms per 300-step window.
- **Data:** zone world bounds for 49 maps (QuestieDB conversion.json, label O). New Forever zones lack bounds.
- **Route efficiency:** measurement model + naive baseline for all 9 starts; travel E where bounds exist; combat time still U (no kill counts/times) → no full route time yet.
- **In progress:** QA review fixes for the adapter (completed=nil → UNKNOWN, ticker on error, duplicate STEP_DONE, segment-jump seeding, single clock); RestedXP technical reference review (CC BY-NC-SA 4.0 → study only, no reuse).
- Nothing verified in game. 10 local commits unpushed (only the first commit is on GitHub).

## 2026-11-10
- **Agent workflow** set up: six project agents in `.claude/agents/`, file ownership and rules in `CLAUDE.md`.
- **P2 spec decisions** (defaults, user may override): segment switches are *suggested*, not automatic; death skips opt-in, off by default; level tolerance before suggesting a switch = 2. Importing Questie's hidden-quest blacklist **awaits user approval** (it would execute new external Lua code).
- **M3** done offline: QuestieDB `aca0da1c4a` → 5,682 quests (1,438 new Forever); faction/class corrections via QuestieDB's registry (127 per faction, 6 class-specific); validator 0 errors / 1 warning (Skyborne Horde start). Not tested in game.
- **M2** done: Lua 5.1.5 built (checksum verified), QuestieDB export verified.
- **M1 / P0** implemented: overlay, 24-check API probe, event recorder. **Pending in-game test.**
- Local commits not yet pushed (push needs user action with a new token).
