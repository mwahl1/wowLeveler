# Leveling Navigator

A free in-game leveling guide for **World of Warcraft: Forever** (work in progress).

**Current build: Milestone 1, diagnostics + overlay.** It shows your character, XP, location and live quest objectives, and tests which game APIs work in Forever. There's no guide routing yet.

> Compatibility with Forever is **not yet verified in game**. Milestone 1 exists to verify it.

## Install
1. Go to https://github.com/mwahl1/wowLeveler, click **Code → Download ZIP**, and unzip it.
2. Rename the unzipped folder from `wowLeveler-main` to exactly `LevelingNavigator`. WoW requires the folder name to match the `.toc` file name.
3. Put it in your Forever client's AddOns folder: `World of Warcraft\<forever client folder>\Interface\AddOns\LevelingNavigator`
   The `.toc` file must sit directly inside `LevelingNavigator\`, not in a nested folder.
4. Start WoW, click **AddOns** on the character select screen, and make sure **Leveling Navigator** is checked.

## Commands
| Command | What it does |
|---|---|
| `/ln` | Show or hide the overlay |
| `/ln probe` | Re-run the API diagnostics and open the results |
| `/ln log [n]` | Print the last *n* recorded quest/XP/zone events |
| `/ln scale 0.6-1.6` | UI scale |
| `/ln alpha 0.3-1` | Window opacity |
| `/ln reset` | Reset window position and size |

Drag the title bar to move the window and the bottom-right corner to resize it. `-` minimizes it to the title bar.

## Diagnostics output
Results and recorded events are saved per character in:
`WTF\Account\<ACCOUNT>\<Realm>\<Character>\SavedVariables\LevelingNavigator.lua`
(written when you log out or `/reload`).
