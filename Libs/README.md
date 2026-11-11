# Embedded libraries

| Library | Source | License | Changes |
|---|---|---|---|
| LibStub | Questie `Libs/LibStub` (Ace3 team) | BSD (see `LibStub/LICENSE.txt`) | none |
| CallbackHandler-1.0 | Questie `Libs/CallbackHandler-1.0` (Ace3 team) | BSD (see `CallbackHandler-1.0/LICENSE.txt`) | none |
| HereBeDragons 2.0 + Pins (2.16) | Questie `Libs/HereBeDragons` at Questie `origin/master` e51da37 (includes Questie's Forever map fixes, commit 3f583f8c4) | HereBeDragons by Nevcairiel: BSD per its `.toc`; Questie modifications: GPLv3 (Questie LICENSE.md) | Renamed to `HereBeDragonsLN-2.0` / `HereBeDragonsLN-Pins-2.0` and pin template `HereBeDragonsPinsTemplateLN` so they never share a LibStub slot with Questie; the Questie setting `hideIconsOnContinents` replaced by the constant `HIDE_ON_CONTINENTS = true` |

Re-sync by copying the files again from Questie and re-applying the renames (see the header comment in each HereBeDragons file).
