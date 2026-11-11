# Leveling Navigator: project instructions

Free in-game leveling guide addon for **World of Warcraft: Forever** (Retail 12.x client family, `## Interface: 16001`, Midnight addon restrictions apply). GPLv3. Repo: github.com/mwahl1/wowLeveler.

Product goals, in order: accurate 1-60 coverage, fastest practical leveling (/played time), reliable automatic quest tracking, dynamic recovery, excellent UI.

## Approved architecture (do not re-litigate)
- **Guides** = shared faction routes + race-specific starting routes + class-specific overlays + dynamic quest-state detection. Spec: `docs/P2_GUIDE_ENGINE_SPEC.md`.
- **Quest data = Option A (final):** QuestieDB's own Lua 5.1 loader and correction registry produce the data; we never re-implement its merge rules. Pipeline: `tools/update_data.sh`.
- **Python** for offline tools and route optimization; **Lua 5.1** for the addon.
- Only adapter modules (`Core/Compat.lua`, `Core/GuideState.lua`) call WoW APIs. `Guide/*.lua` is pure Lua and runs offline.
- Data labels: V verified (our in-game data), O observed (Forever-specific sources), E estimated (Classic Era), U unknown.

## Agent workflow
Specialist agents live in `.claude/agents/`. The lead coordinates; specialists implement.

| Agent | Owns (sole editor) |
|---|---|
| lead-architect | `CLAUDE.md`, `docs/ROADMAP.md`, `docs/PROGRESS.md`, `docs/*_SPEC.md`, `.claude/agents/` |
| wow-addon-engineer | `Core/`, `Guide/`, `LevelingNavigator.toc` |
| quest-data-engineer | `tools/questiedb_export.lua`, `tools/build_data.py`, `tools/update_data.sh`, `tools/validate_data.lua`, `Data/`, `docs/DATA_COVERAGE.md`, `docs/data-gaps.csv` |
| route-optimizer | `tools/optimizer/`, `Guides/`, `docs/ROUTE_EFFICIENCY.md` |
| ui-ux-engineer | `UI/` |
| qa-engineer | `tests/`, `tools/run_tests.lua` (reviews everything else read-only) |

Rules:
- The lead delegates independent tasks in parallel and defines shared interfaces first. Two agents never edit the same file at once.
- Agents make routine technical and implementation decisions themselves and record notable ones in the relevant spec.
- Do not ask the user to re-approve architecture already in this repo.
- Keep working offline while P0 awaits in-game testing.
- Before reporting completion: run the tests, have qa-engineer review, and fix failures.
- After each milestone: update statuses in `docs/ROADMAP.md` and add a short dated entry to `docs/PROGRESS.md`.

## Commands
```
~/wow-tools/lua-5.1.5/src/lua tools/run_tests.lua      # offline Lua test suite (exit 0 = pass)
~/wow-tools/lua-5.1.5/src/lua tools/validate_data.lua  # generated data validator
tools/update_data.sh --no-pull                          # rebuild Data/ (export runs QuestieDB code)
python3 tools/build_data.py                             # rebuild Data/ from the existing export only
```
Windows (Git Bash; Lua 5.1.5 built from the verified lua.org tarball with `python -m ziglang cc`):
```
~/wow-tools/lua-5.1.5/src/lua.exe tools/run_tests.lua
~/wow-tools/lua-5.1.5/src/lua.exe tools/validate_data.lua
python -B -m unittest discover -s tools/optimizer/tests   # needs tools/.cache/forever: run update_data.sh once
sh tools/update_data.sh --no-pull                          # Questie must be checked out at the pinned commit
```
The addon folder in the game (`_forever_\Interface\AddOns\LevelingNavigator`) is a junction to the repo: edits are live after `/reload`.

## Status vocabulary
planned → implemented → offline-tested → **verified in game**. Only the user can supply in-game results. Never claim in-game verification without them.

## Ask the user only for
Genuinely blocking information; security-sensitive approvals; irreversible actions; decisions that materially change product scope.

## Never without the user's approval
- Pushing to any remote, publishing releases, or changing repository settings/permissions.
- Running new external code (anything beyond the approved QuestieDB pipeline and the user-built Lua 5.1), or working around a security block. If blocked, stop and give the user the exact command.
- Destructive operations (history rewrites of pushed commits, deleting user files, `git reset --hard`, force pushes).
- Handling credentials. Never write tokens into files, commits, logs or chat.

Also: no unbounded loops; don't retry a failing command more than twice without changing something.

## Code conventions
- Lua: `local ADDON, ns = ...` modules; read data records by name via `ns.DataSchema` (`S.Q.NAME`), never by index; Skyborne race bits (32/33) are tested arithmetically, never with `bit.band`; guard every WoW API call.
- WoW fonts: Latin-1 glyphs only.
- Generated files (`Data/*.lua`, coverage report) are never edited by hand.
- Commit messages end with the attribution lines the harness provides.
