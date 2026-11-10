# Route efficiency: how we measure it

Owner: route-optimizer. Status: **methodology + tooling implemented and offline-tested; no measured data yet.** Spec: `docs/P2_GUIDE_ENGINE_SPEC.md` section 9 (this document refines it, it does not change it). Tooling: `tools/optimizer/`.

No route content is written until this measurement layer exists. Nothing below is verified in Forever: every number is labelled, and every E number is a **placeholder – verify in Forever**.

## 1. Objective

Minimise total **/played seconds from level 1 to level 60** for a given (faction, race, class) start, subject to level feasibility (every accepted quest's required level is met when it is accepted).

Secondary outputs (never traded against the objective without saying so): deaths, deviations from the route, steps that need manual confirmation.

## 2. Labels

| Label | Meaning for a time-model number |
|---|---|
| **V** | measured by our own recorder in Forever (none yet) |
| **O** | from a Forever-specific source (QuestieDB Forever layers/traces, a Forever measurement someone else published) |
| **E** | Classic Era value assumed unchanged, or a placeholder guess. Always "placeholder – verify in Forever" until promoted |
| **U** | unknown. The model reports the term as unknown and **does not substitute a number** |

Combination rule: a sum carries its **weakest** label (V < O < E < U). A total that contains any U term is U and is not printed as a number; the tooling prints the known part separately as a lower bound. The same holds for hidden unknowns: an XP sum that skips quests with unknown XP is a lower bound (printed `>=`, labelled U), and the end level is U when XP is a lower bound or GRIND steps (time U) were needed.

## 3. Per-step time model

`T(step) = travel + interaction + combat + downtime + waits + risk`

| Term | Model | Inputs (labels in section 6) |
|---|---|---|
| travel | straight-line yards × terrain factor ÷ speed. Speed = run speed, × (1 + mount bonus) from the mount level once affordable. Hearth / flight / transport replace the leg with their own cost | spawn coordinates (E/O from M3), zone size in yards (O from QuestieDB map bounds for 49 maps; U elsewhere), run speed, terrain factor, mount rules, flight speed, hearth cast/cooldown |
| interaction | fixed cost per ACCEPT / TURNIN / object use / trainer / vendor | accept_s, turnin_s, object_use_s |
| combat | kills × (kill time(level diff, class) + loot). Item objectives: kills = count ÷ drop rate | **objective counts (U: not in the export)**, **drop rates (U: not in the export)**, kill time, mob levels (in M3: NPC min/max level, E) |
| downtime | combat time × downtime fraction (eat/drink), class-dependent | downtime_fraction |
| waits | respawn waits on contested/limited mobs and objects; boat/zeppelin schedules | respawn_wait_s, transport_wait_s |
| risk | expected deaths × death cost (corpse run or spirit healer, durability, resurrection sickness) | death_rate, ghost speed, graveyard choice, durability loss, sickness |

XP side: quest XP comes from M3 (`XP`, label in the quest's LABELS[4]: O traced in Forever, E Classic, U missing), scaled by the XP falloff for (player level − quest level). Level progression uses the XP-to-next-level table. Kill XP is **not modelled** yet (needs kill counts and the mob XP formula).

Positions: a step's target is the nearest spawn (same uiMap) of its start NPC/object, objective NPC/object/item source, or finisher, per spec 7.1. The character's starting position is U, so the first leg of every route is U.

Distances are computed in two units:
- **map percent** (always available on the same uiMap; anisotropic, only comparable within one map);
- **yards** where the map has a size: by default from `tools/.cache/forever/zone_bounds.json` (QuestieDB `conversion.json` world bounds, width = |left − right|, height = |top − bottom|, label **O**; the same data is in `Data/Meta.lua` `zoneBounds`). `--zone-sizes file.json` (`{uiMap: [width_yd, height_yd, label]}`) overrides per map. Maps without bounds stay U; we never invent sizes. A travel leg is therefore O geometry × E speed placeholders = **E**.
- Maps known to have no bounds: Zephras Isle 2521 (the Skyborne start), Riverglades 2548, Mount Hyjal 2482, Shen'dralas 2652, Darkspear Islands 2524. The CLI lists every visited map without bounds.

## 4. Metrics

| Level | Metric | Source |
|---|---|---|
| step | seconds, XP, label; unknown terms named | model / recorder |
| segment | seconds, XP gained, XP/hour, deaths, deviations (skips, out-of-order completions, returns), manual confirmations | `STEP_DONE` + recorder |
| route | total seconds to 60, seconds per level, share of time travelling / fighting / idle (interaction, downtime, waits), deaths | aggregate of segments |
| model quality | measured ÷ modelled seconds per step type and per term; coverage = share of steps with a non-U estimate | comparison |

Until zone sizes exist, **path length in map percent** (same-map legs) is the only travel metric we can compare, and only between routes on the same map.

## 5. Comparison methodology

1. **Identical boundary states.** Routes are compared segment by segment only between equal entry states: same level (± 0.5 level tolerance, stated), the same completed-quest set at entry, same class and race. Exit states must be equal too (same level target), or the comparison is XP/hour-normalised and says so.
2. **Naive baseline** (`tools/optimizer/baseline.py`): in the race's starting uiMap (Data/Meta.lua `startingQuests`), every quest the race/class/faction can do inside the baseline window (required level ≤ 12 and quest level ≤ 17 = 12 + 5 by default; `--max-req-level`, `--max-quest-level`; a definition, not game data; excluded with reason `above_baseline_window:req_level` / `:quest_level`), in simulated level order (lowest quest level whose prerequisites are done and whose required level is reached), each quest alone: ACCEPT → OBJECTIVE(s) → TURNIN. No batching, hearth, flights or death skips. When no quest is level-feasible a GRIND step (time U) is inserted. Default class Warrior (open to every Classic race; Skyborne unverified); steps of class-restricted quests carry `when = { classes = {...} }`. Route `exit = { completed = {all baseline quests} }` (spec 3.4).
   - Followed: PRE_ANY (any one positive entry done satisfies it; PRE_ALL is checked only when PRE_ANY is absent, as Questie does; a negative entry in PRE_ANY matters only when no positive entry can be satisfied, then the quest is excluded as unresolved, `negative_pre_any`), PRE_ALL (a positive entry also accepts its exclusiveTo fallback; a negative entry −X needs X itself, no fallback), exclusive groups (lowest level kept), breadcrumb before target, quest before its nextQuestInChain, `availableStartingWith` after its quest, `availableUntilCompleted` before its quest. `disabledByQuest` always holds because only one baseline quest is active at a time.
   - Excluded with a reason: repeatable, profession/rep/spell/spec/rank requirements (state unknown), prerequisites outside the start map, unresolved negative PRE_ANY, other classes' quests.
3. **Modelled vs measured.** An optimised route is "better" only if its time is lower and the inputs are labelled. Reporting rules:
   - measured (V) win: both routes recorded from identical boundary states;
   - modelled win: both routes modelled with the **same** parameter set; reported with the weakest label of the terms that differ ("E: −8 min, travel term"), never as a measurement;
   - if any differing term is U, there is no modelled win, only "unknown".
4. **Sensitivity.** For every modelled win, recompute with each E parameter at ±50 %. A win that flips sign is reported as "not robust".

## 6. Parameters

All live in `TimeModel` (`tools/optimizer/model.py`); overrides via `--params file.json` (`{name: {value, label, note}}`), which is also how recorder measurements will be fed in.

| Parameter | Value | Label | Note |
|---|---|---|---|
| run_speed | 7.0 yd/s | E | Classic base run speed; placeholder – verify in Forever |
| terrain_factor | 1.3 | E | path ÷ straight line; a guess with no source; placeholder |
| mount_level | 40 | E | Classic riding level; placeholder (Forever has "Learning to Ride" quests at level 40 in the data, cost unknown) |
| mount_speed_bonus | 0.6 | E | Classic apprentice +60 %; placeholder |
| mount_cost | – | U | |
| flight_speed | – | U | measure from taxi STEP_DONE timings |
| ghost_speed_bonus | – | U | |
| hearth_cooldown | 3600 s | E | Classic; placeholder |
| hearth_cast | 10 s | E | Classic; placeholder |
| accept_s / turnin_s | 5 s / 5 s | E | placeholder guesses |
| object_use_s | – | U | |
| kill_s_same_level | – | U | class/gear dependent |
| loot_s | – | U | |
| objective_counts | – | U | **not in the M3 export** (only objective IDs) |
| drop_rates | – | U | **not in the M3 export** (item → source IDs only) |
| downtime_fraction | – | U | class dependent |
| respawn_wait_s / transport_wait_s | – | U | |
| death_rate | – | U | |
| death_durability_loss | 10 % | E | Classic; placeholder |
| rez_sickness_min_level | 11 | E | Classic; placeholder |
| xp_falloff | ≤5: 100 %, 6: 80 %, 7: 60 %, 8: 40 %, 9: 20 %, ≥10: 10 % | E | Classic (player − quest level); placeholder |
| xp_to_level | Classic table, 400 … 209 800 | E | placeholder; Skyborne quest XP values (40 for the first quest) suggest checking this early |
| zone sizes (yards) | 49 maps from QuestieDB bounds | O | other maps U (see section 3); override per uiMap with a label |

## 7. Mechanics to verify in Forever

Each item becomes O/V only with an in-game observation (recorder event or a dated manual test noted here).

- [ ] **XP falloff** for low-level quests: XP of a quest turned in at quest level +5, +6, +8, +10 (compare with the M3 XP value).
- [ ] **XP to next level** for levels 1–20 at least (recorder: `xpMax` per level).
- [ ] **Run speed** (yd/s) on flat ground; plus terrain factor from recorded paths vs straight line.
- [ ] **Zone sizes**: confirm the QuestieDB bounds (O) on a starting map by timing a run between two known points; measure the maps with no bounds (Zephras Isle 2521 first, then 2548, 2482, 2652, 2524).
- [ ] **Mount**: level, riding cost, mount cost, speed bonus; whether the "Learning to Ride" / "Your First …" quests change these.
- [ ] **Hearthstone**: cooldown, cast time, whether anything shortens it.
- [ ] **Death costs**: durability loss %, resurrection sickness (level threshold, duration, stat penalty), **ghost speed**, corpse-run vs spirit-healer choice, **graveyard selection** rules (nearest vs zone-assigned) for death skips.
- [ ] **Flight paths**: speed, take-off/landing overhead, which nodes exist per faction.
- [ ] **Boats/zeppelins**: schedule period and travel time.
- [ ] **Kill-time model**: seconds per kill by (class, level difference, mob rank); loot time; downtime per class at levels 5/10/20/40.
- [ ] **Kill XP** formula vs level difference (needed to credit XP earned during objectives).
- [ ] **Rested XP** accrual (affects time only if logging out is part of a plan; excluded from /played by definition but changes XP/h).

## 8. How measured data flows in

1. **In game.** The engine emits `STEP_DONE {stepId, segmentId, t, level, xp, map, x, y}` on every step status change (spec 7.4). The existing recorder logs XP, level, deaths, zone changes and timestamps. Both are persisted in `LevelingNavigatorCharDB` (SavedVariables) with the route id and addon version.
2. **Export.** The user copies `WTF/Account/<acct>/<realm>/<char>/SavedVariables/LevelingNavigator.lua` (no credentials in that file).
3. **Offline import** (planned, `tools/optimizer/import_runs.py`): parse the SavedVariables Lua table (same reader as `parse_lua_table`), pair consecutive `STEP_DONE` events into per-step durations, attribute each to a term (travel = movement between targets, combat/objective time, interaction), drop steps with deviations (death, AFK gaps above a threshold, out-of-order completion), and aggregate to medians per (step type, class, level band, map).
4. **Promotion.** Aggregates are written as a `--params` override file and as per-map zone-size estimates with label **V** (our recorder), each with sample count and date. Terms with fewer than N samples (N to be set when data arrives) stay at their old label.
5. **Model check.** Re-run the baseline and any optimised route with the measured parameters; report measured ÷ modelled per term (section 4, model quality).

## 9. Current baseline (2026-11-10)

`python3 -B tools/optimizer/baseline.py --all` (Warrior; window required level ≤ 12, quest level ≤ 17; grind on). XP from M3; levels with the E XP table. Travel uses QuestieDB zone bounds (O) × E speed placeholders. **Combat is still U everywhere**, so every objective step is U and no route has a modelled total.

| Race | Map (size label) | Quests | Quest lvls | Steps | GRIND steps (XP) | Quest XP (quests w/o XP) | End lvl | Modelled time | Known part (E) | Steps with U time |
|---|---|---|---|---|---|---|---|---|---|---|
| Human | 1429 (O) | 69 | 1–12 | 182 | 0 (0) | ≥28605 (2) U | 10 U | U | 3h07m | 50/182 |
| Dwarf | 1426 (O) | 56 | 1–16 | 155 | 0 (0) | ≥25950 (2) U | 9 U | U | 3h06m | 54/155 |
| Night Elf | 1438 (O) | 61 | 1–12 | 171 | 0 (0) | ≥29265 (2) U | 10 U | U | 2h51m | 63/171 |
| Gnome | 1426 (O) | 56 | 1–16 | 155 | 0 (0) | ≥25950 (2) U | 9 U | U | 3h06m | 54/155 |
| Skyborne A | 2521 (U) | 86 | 1–13 | 261 | 2 (520) | 39505 (0) E | 11 U | U | 0h14m | 207/261 |
| Orc | 1411 (O) | 55 | 1–14 | 163 | 0 (0) | ≥32115 (1) U | 10 U | U | 3h13m | 67/163 |
| Undead | 1420 (O) | 59 | 1–13 | 184 | 1 (1465) | ≥30865 (1) U | 10 U | U | 3h31m | 75/184 |
| Tauren | 1412 (O) | 53 | 1–14 | 155 | 1 (925) | ≥27515 (1) U | 10 U | U | 3h03m | 67/155 |
| Troll | 1411 (O) | 55 | 1–14 | 163 | 0 (0) | ≥32115 (1) U | 10 U | U | 3h13m | 67/163 |
| Skyborne H | – | – | – | – | – | – | – | U | – | data gap: no starting zone |

"Known part" = travel (E) + interaction placeholders (E) of the terms that can be modelled, including the travel legs of objective steps whose combat is U: a **lower bound**, not a time estimate. It also shows how wasteful the naive one-quest-at-a-time order is (about 3 hours of modelled walking per starting zone). Skyborne Alliance has no zone bounds, so its known part is only interaction time.

The Tauren level-60 "A Donation of …" quests (required level 12, no XP in the data) are now outside the window; its remaining GRIND step (925 XP to level 10) is for "The Hunter's Way" (required level 10).

### Route file: `Guides/Baseline_Starts.lua`

Generated by `python3 -B tools/optimizer/baseline.py --write-guides` (deterministic; a test fails if the file differs from a fresh render). One `kind = "start"` def per starting zone, `source = "optimizer@baseline-<version>"`, header "naive level-ordered baseline, NOT optimized; labels E/U". Races sharing a zone share a def (Orc/Troll `{2,8}`, Dwarf/Gnome `{3,7}`); Skyborne Horde is skipped with a comment. Unlike the CLI table (Warrior), the file covers **every class**: a quest's applicable classes/races are its own masks intersected with its prerequisites' (e.g. Vile Familiars 792 excludes Warlocks, so 794 after it does too), and those steps carry `when = { classes = {...} }` (and `races` when a shared def has race-only quests). `exit = { completed = {...} }` lists only quests that apply to every class and race of the def. Skipped quests are listed per def with their reason. Class quests filed under a class sort (no uiMap) are not in any starting-zone baseline; they belong in class overlays (spec 3.5).

| Def | Races | Quests | Steps | GRIND | Skipped |
|---|---|---|---|---|---|
| baseline.start.1429 | 1 | 69 | 182 | 0 | 8 |
| baseline.start.1426 | 3, 7 | 56 | 155 | 0 | 38 |
| baseline.start.1438 | 4 | 61 | 171 | 0 | 5 |
| baseline.start.2521 | 95 | 86 | 261 | 2 | 4 |
| baseline.start.1411 | 2, 8 | 55 | 163 | 0 | 8 |
| baseline.start.1420 | 5 | 59 | 184 | 1 | 11 |
| baseline.start.1412 | 6 | 53 | 155 | 1 | 11 |

## 10. Data gaps that block time estimates

1. **Objective counts** (kills/items/objects required): not in the M3 export; every combat/object term is U.
2. **Kill time / loot / downtime per class**: no data until the recorder runs.
3. **Drop rates**: not in the export; item objectives are U even with counts.
4. **Starting position** per race (spawn point): first leg U.
5. **XP table and falloff in Forever**: level simulation (and therefore grind steps and level gating) rests on E Classic values; Skyborne quest XP is low enough that two GRIND steps appear in its zone.
6. **Skyborne Horde (raceID 96)**: no starting zone in the data (no race-specific level-1 quest). Horde-wide race masks include its bit, so that says nothing about where it starts; not assumed.
7. **Zone sizes** for maps without QuestieDB bounds (2521, 2548, 2482, 2652, 2524): travel there is U; the 49 bounded maps are O, not yet confirmed in Forever.
8. Quests with unknown start/finish location in the starting zones (a few per zone) make their legs U.
