# Progress log

Newest first. Status vocabulary: planned → implemented → offline-tested → verified in game.

## 2026-11-10
- **Agent workflow** set up: six project agents in `.claude/agents/`, file ownership and rules in `CLAUDE.md`.
- **P2 spec decisions** (defaults, user may override): segment switches are *suggested*, not automatic; death skips opt-in, off by default; level tolerance before suggesting a switch = 2. Importing Questie's hidden-quest blacklist **awaits user approval** (it would execute new external Lua code).
- **M3** done offline: QuestieDB `aca0da1c4a` → 5,682 quests (1,438 new Forever); faction/class corrections via QuestieDB's registry (127 per faction, 6 class-specific); validator 0 errors / 1 warning (Skyborne Horde start). Not tested in game.
- **M2** done: Lua 5.1.5 built (checksum verified), QuestieDB export verified.
- **M1 / P0** implemented: overlay, 24-check API probe, event recorder. **Pending in-game test.**
- Local commits not yet pushed (push needs user action with a new token).
