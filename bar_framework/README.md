# bar_framework

Shared modules the bot controllers load with `VFS.Include("LuaUI/Widgets/bar_framework/<name>.lua")`
(`deploy.ps1` copies them into BAR's widget folder). Module defaults are LINE_CLICK_v16's settings; a bot overrides a
default only when it wants to differ (pass `cfg = {...}` to `Init`/`LT.New`; the "pre-v16 ... pinned" overrides in
`candidates/LINE_CLICK` etc. show how). Modules with no user left were moved to `archive/framework/`.

**Used by LINE_CLICK_v16** (and so by v17 / LINE_BOMB):

| Group | Module | Job |
|---|---|---|
| Economy | `line_crew` | the line: slots of mex/wind/nano from the commander outward |
| | `con_broker` | every air con (T1 and T2) has one owner; jobs (grid, retrofit, silo, energy cell, consolidation, second lab, line nano rebuild, nano crew, helpers) register `AddJob{prio, tier, want, start, sessions, produce}` and the broker hands out cons by priority / nearest, keeps the reserve + T2 hold, preempts helper jobs, runs the placer sessions and frees the builder when one ends; `defense_crew` seizes cons through `pool`. Con orders to labs go through `lab_broker` (`WG.LabBroker`). Header of the file shows how to add a job. Test: `tests/test_con_broker.lua` |
| | `line_transition` | air lab, then mex/wind/nano grids, retrofits, energy push/cells, silo capstones, unit-cap relief |
| | `eco_planner`, `spend_governor` | look-ahead for what a grid builds next; army-share governor (used by `line_transition`, `spine`) |
| | `defense_crew` | flak / anti-nuke / silos the grids do not build themselves |
| Army | `spine` | stack of unit-producing grid cells seeded by the vehicle lab |
| | `click_army` | human-style attack groups going for enemy build power / eco / commander |
| | `slow_front` | Lashers / Pounders / rez bots (the slow group) |
| | `line_fight`, `army_broker` | spine push/retreat logic; single owner of orders to combat units |
| | `unit_clock` | per-unit command frequency: tiers 0.5 / 1 / 2 Hz (scouts and quiet guards / normal / raiding or enemy near) and a per-unit phase, so orders spread over the second; used by `army_broker` (`SetClock`, `Flush`, `UpdateClock`); RAID_BOT only |
| | `lab_broker` | single owner of factory queue orders: a bot registers WANTS (priority, mode empty / ahead / topup / tail, `pick(lab)`), the broker does the queue read, tail order, insert-ahead with its pending gate, grace and depth fill, and logs `[LB]` orders per want; used by RAID_BOT's `lab_controller` (test `tests/test_lab_broker.lua`) |
| | `raid_response` | what the army does when enemies are behind the line: intruder groups, who answers (up to NEED_MULT x their value), intercept / stun / Wasp split, release as raiders die (cfg `KEEP_MULT`), publishes `mb.raid` / `mb.airLosses`; RAID_BOT and STANCE_BOT (`tests/test_raid_response.lua`) |
| | `bot_config` + `presets/` | `BC.Preset("<module>", "GROUP", ...)` merges named option groups (`presets/<module>.lua`); `BC.Apply` merges a bot's overrides into a module's defaults, logs `[CFG] <module> (<bot>): N changed -- ...` and warns about options that are not in the defaults (`tests/test_bot_config.lua`) |
| | `air_wing` | standing air wing (fighters, bombers) |
| | `rez_crew`, `raid_group`, `endgame`, `commander_guard` | rez/reclaim bots, raiders, "find and kill the last commander", commander evasion |
| Intel | `enemy_intel`, `recon_plan`, `scout_plan`, `scout_lanes`, `scout_rings` | remembered enemy info; scouting before and after contact; `scout_rings` = vision rings round our buildings, pushed out while scouts survive (STANCE_BOT) |
| | `threat_map`, `threat_log` | where we are threatened (and a log for `threat_map_viz`) |
| | `map_model`, `unit_query` | map geometry relative to our base; unit classification |

**Used by shared files rather than a bot:** `escape_guard`, `nano_broker` (by `blueprint_placer.lua`), `resource_utils`
(documented in `agent_harness.py`).

**Strategy framework (2026-10-12, not wired into a bot yet):** `behavior_host` + `behaviors/` (plug-and-play unit control, see
`behaviors/README.md`), `slot_spine` (nano blocks + lab slots, labs chosen from the comp; replaces `spine` for new bots), `strategy` (stances + run-time hooks for share, stance switch and unit weights), `game_state` (the one state
table the hooks read), `stance_loader` (stance files, value-deficit pick with weights). Tests: `test_behavior_host`, `test_strategy`.

**RAID_BOT (2026-10-13, game review):** options that default off, so other bots are unchanged:
- **`click_army`:**
  - `EARLY_LAUNCH` / `LAUNCH_RATIO_EARLY` / `BLIND_LAUNCH` / `MIN_GROUP_UNITS`: small groups leave early, and a group needs at least 3 units.
  - `LAB_EXIT_R/W`: fresh units at an enemy lab do not steer the legs.
  - `ENGAGE`: COMMIT to build power next to a group, or ESCAPE to the line front, when surrounded or losing.
  - `HOLE_FIND`: approach from the least defended point on a ring round the target, and scout the unseen points.
  - `SetMode("hold")`, `TradeSummary`.
  - `FIGHTER_POST`: fighters wait behind the front, out of enemy AA (`M.FighterPost`, also air_wing's `station` hook).
  - `SCOUT_ROUTE`: scout requests follow the route and look at the target.
- **`strategy_hooks`:**
  - `game_plan`: raid → hold when behind and the raids trade badly.
  - `chain_switch`.
  - `income_mix`: tilts units tagged `mass` / `quality` by income.
- **Stances:** `plan` (`Strategy:Plan()`) and per-unit `tag`.
- **`game_state`:** `armyRatio`, `trade`, `airSuperior`.
- **`line_transition`:**
  - `CON_HOLD` stops air/T2 con orders during a ground raid.
  - `GRID_RECOVER` rebuilds grids whose mex spots stay empty.
  - `SECOND_AIR_LAB` builds a second T1 air lab on the finished line.
- **`behaviors/range_kite`** (see `behaviors/README.md`).
- Tests: `test_raid_army`, `test_raid_plan`, `test_con_hold`, `test_grid_recover`, `test_raid_bot`.

**LINE_BOMB only:** `phase_plan`, `bomb_run`, `lab_recycler` (LINE_BOMB's lab controller also uses `stance_loader`).

Deploy list: `deploy.ps1`. Tests: `tests/` (see `tests/LUA_TESTING.md`).

Cross-widget state (`WG.*`): see `WG_CHANNELS.md`.
