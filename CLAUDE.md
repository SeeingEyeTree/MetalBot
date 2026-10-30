# MetalBot — Beyond All Reason Bot Development

## What this project is

MetalBot is an AI bot for the RTS game Beyond All Reason (BAR), implemented as Spring engine Lua widgets. The bot runs headlessly (no display) in a dedicated test harness (`bot_testing.py`) so it can be developed and benchmarked automatically.

## Main bot and test settings

**2026-10-30: `candidates/CORE_v4` is the main CORE** (`deploy.ps1` and `eco_sim.py` default to it): CORE_ROWS_ECO + support elements + the nano-column block (`NANO_COLS`, instead of the mex grids; second spine off), run by the raid-only machine `machines/v4_raid.lua` (T1_raid -> T1_5_raid -> t2_raid -> t3_late; raid_response still answers raids at home; T1_5_raid / t2_raid / t3_late give every group spam + scout support elements). `candidates/CORE_v4_ECO` = CORE_v4 at 0% army (pure-eco tests). **Default spawns are now `2816,1904;9472,10384`** (~400 elmos further in, so the block's 3 columns fit; `ecosim/physics.lua` START matches). **A game vs INACTIVE_BOT defaults to** `--server single`, 20 min, a replay and `METALBOT_DEATHMODE=neverend` (the army killed the idle commander at 11:50 otherwise; the match now quits cleanly after the score). `candidates/CORE_ROWS_ECO` is the OLD eco-rows baseline restored from commit d4f046a (grids, second spine, no support), with its machine `machines/rows_eco_legacy.lua`; it and RAID_BOT use stances from `stances/legacy/` (the user dropped them from the main list). The harness now copies `machines/` and `stances/` (recursively) into each match. Notes: `knowledge/bots/nano_cols_2026-10-30.md`.

**2026-10-28: `candidates/CORE_ROWS_ECO` is the main CORE** (user, after a game where it beat him: it out-spent him 1.2x at 10:00 and 2.1x at 20:00); `deploy.ps1` and `eco_sim.py` default to it. New strategies are variants of it (config only, as for CORE). `candidates/CORE` stays as the older baseline (`order_check.py` still runs it). What it adds over CORE: rows that scale with cons (`SCALE_ROWS`), the air lab gated on income (`AIR_LAB_INCOME` 110 m/s from 5:00) or a float, a second spine behind the line started by line cons that finish a lane (`SECOND_SPINE`, `line_transition/spine2.lua`, `spine_set.lua`), `BLOCK_LAB_NANOS` 4 (a lab in a block per 4 nanos), `GUARD_NANOS` false (spine nanos never guard a lab, only park), and the `rows_default` machine (its `t1_push` node uses `raid_start`). `METALBOT_STARTPOS=close` = close positions. 2026-10-26: `candidates/CORE` was the baseline (README.md explains it and how to swap strategies). The v16 notes below are history.

**`candidates/LINE_CLICK_v16/` is the main bot** (user, 2026-10-12: v16 is the best version; future work builds off it).
It is LINE_CLICK + the v12-v16 changes: forward-core/flanking army, grid expansion fixes, energy push, resource-pressure grids,
energy cells, capstone silos + anti-nuke, rez bots, depth scouts. Its design notes are in `knowledge/bots/v16_2026-10-09.md`
(economy bench: `knowledge/eco_scaling_2026-10-09.md`). **Every flag v16 turned on is now the framework default**, so the
controllers pass no overrides; `candidates/LINE_CLICK` (the older main bot, a regression opponent), `LINE_HUMAN`, `ECO_BENCH`
and `ARMY_BENCH` pin their old behaviour explicitly (a "pre-v16 ... pinned" comment next to the override).
`candidates/LINE_CLICK_v17` (paintkid-game fixes) and `candidates/LINE_BOMB` (stance system + T1 bomber rush) derive from v16
and are untested/in progress; `candidates/RUSH_SPAM` is a deliberately dumb eco-spam opponent. Open ideas: `experiment_ideas.md`.
**Retired 2026-10-12 (moved, not deleted -- see `archive/README.md`):** LINE_BOT, TILE_BOT, SPINE_BOT, MECH_BOT, DRAGON_BOT and every
older LINE_CLICK_vN / TILE_V2 candidate now live under `archive/bots/` and `archive/candidates/`. Earlier history (v12, v13d, v14):
`knowledge/sessions/overnight_2026-10-08.md`. Remaining top-level bots: `OK_BOT` (reference), `INACTIVE_BOT` (pure-eco opponent),
`RAIDER_BOT` / `GROUND_RAIDER_BOT` (exploiter fixtures for `find_bot_weakness`).
**Git:** work after v12 is on branch `bot-testing-v2` (`main` stops at v12).

**Measurement rules learned 2026-10-08:** grep a run for `Sync error` (`result["desync"]`) before trusting anything past
~10 game-min (the stats tracker's `RequestPath` desynced nearly every match until it was switched off); run 20-minute
mirror A/Bs on **TreeServer** (the main PC gives slot 0 a ~1.4-1.5x edge there, TreeServer ~1.0-1.1x) and always pair
slot orders; never `Stop-Process` spring-headless by name (other sessions run matches on this PC). Tools:
`series.py` (batch of matches), `match_summary.py`, `h2h_report.py`; `--bot2 AI:BARb` plays BAR's native AI (weak vs
LINE_CLICK: a regression check, not a strength measure); `ab_test.py --end-minutes/--keep`.

**Defaults changed 2026-10-12:** (1) **phi (bot_score.py v4) decides the end-of-match winner** (`winner_method` "phi"); it counts a side's economy only to the
extent it can be protected/spent (a side with <5% of the enemy's army keeps none). The legacy `army_mv + 60 x income` is still printed ("Legacy end score")
and kept in `draw_score`. `ab_test.py --metric` defaults to phi. See `knowledge/scoring.md` (v4). (2) **Start positions default to `2400,1904;9888,10384`** (2026-10-30: now `2816,1904;9472,10384`, see the top)
(corner starts moved ~2.2 mex grids in); `METALBOT_STARTPOS="x0,z0;x1,z1"` overrides, `close` = close positions, the paintkid replay's spawns (~7.3k apart; the old name `paintkid` still works), `map` = the
map's own starts. (3) **Line rotation defaults to rot 3 (west half) / rot 1 (east half)** (`LC.FORCE_ROT` in line_crew.lua; the global `LC_FORCE_ROT = false`
before loading restores the old rule; tests for the old geometry set it).

**All testing uses a 3000 unit cap** (`maxunits=3000` in the harness's modoptions; BAR's default is
2000; changed from 5000 on 2026-10-09 because 5k made the late game too slow, per the user). The larger
cap makes a bigger economy worth building. Results from before this change were measured under the 2k
or 5k cap and are not directly comparable.

## Bot structure

A bot is a **folder** containing three Lua widget files:

| File | Responsibility |
|---|---|
| `macro_controller.lua` | Economy: commander build order, the line, mex/wind grids, vehicle lab + spine, commander safety |
| `lab_controller.lua` | Factory queues: what units each lab builds and in what ratio |
| `unit_controller.lua` | Combat/scouts: where units move and how they fight |

The controllers are thin; the logic is in `bar_framework/` (see `bar_framework/README.md` for what each module does and
who uses it). LINE_CLICK_v16's economy is a line of mex/wind slots (`line_crew.lua`), an air lab, then mex grids
(`line_transition.lua`); the army is a vehicle lab on the line seeding the spine (`spine.lua`), played by `click_army.lua`
(up to 3 attack groups hitting enemy build power / eco / commander), `slow_front.lua` (Lashers/Pounders/rez bots) and
`scout_lanes.lua`. Doctrine: win by killing enemy build power/eco/commander, not by trade efficiency. Judge it on enemy
BP/eco destroyed (`[CK]`, `[SF]` log rows), then A/B on army value. Deploy with `.\deploy.ps1` (default bot is
`candidates\LINE_CLICK_v16`; `-Bot <folder>` for another). Tests (lupa Lua 5.1, see `tests/LUA_TESTING.md`): `test_click_army`,
`test_slow_front`, `test_scout_lanes`, `test_line_crew`, `test_click_forward`, `test_line_bomb`.

**`candidates/LINE_HUMAN/` + `human_control_logger.lua`** record how a person controls units (the line economy, empty unit
controller, the person queues and commands the army). Deploy with `.\deploy.ps1 -Bot candidates\LINE_HUMAN`;
`python human_control_report.py` and `python human_kite_report.py` read the `[HCL]` logs.

**Stances, strategy framework, STANCE_BOT, RAID_BOT (2026-10-11 .. 14).** The session-by-session notes that used to sit here (stance editor,
behaviour host, slot spine, the STANCE_BOT eco sessions and vacuum test, the game-vs-people mode, RAID_BOT's game-review fixes, the unit clock)
are in `knowledge/sessions/claude_md_history_2026-10-14.md`, word for word; the per-topic notes are `knowledge/bots/session_2026-10-12_stance_framework.md`,
`knowledge/sessions/session_2026-10-12_energy_eco.md`, `knowledge/bots/session_2026-10-13_raid_bot.md`, `knowledge/sessions/variance_notes_2026-10-12.md`. Short version:
- **Stances** (`stances/*.lua`, edited in `stance_editor.html`) are unit comps plus a `plan`; `bar_framework/strategy.lua`
  holds the current one and runs three hooks (`army_share`, `weights`, `switch`; ready-made ones in `strategy_hooks.lua`). Units carry behaviours
  (`behavior_host.lua`, `behaviors/`: `kite`, `range_kite`, `stun_target`, `intercept`).
- **`candidates/STANCE_BOT/`** = v16 + stances + the slot spine (`slot_spine.lua`, `NanoBlock`) + the energy-economy systems (line_transition options
  `EP_*` / `ECELL_*` / `RETROFIT_*` ..., see the presets below) + the lab army budget. ~even vs v16 (2-2 at 30 min). Vacuum eco test and its
  recipe: the history file. Compare runs on `*_avg` tracker fields, never the minute-mark `metal_inc`. `CFG.MATCH = true` is for games vs people
  (army share follows the scouted enemy); set it `false` for bot-vs-bot tests.
- **`candidates/RAID_BOT/`** = STANCE_BOT + the fixes from a review of its game against a person: stances `raid_open` -> `hold` (after bad trades
  while behind) -> `raid_late`; click_army early small groups, COMMIT / ESCAPE, hole finding; `range_kite`; raid response that releases extras
  (`raid_response.lua`, preset `RAID`); mex grid recovery; a second air lab; Shuriken force; ground AA; `unit_clock.lua` (per-unit command rate,
  RAID_BOT only; `tests/test_unit_clock.lua`). Its lab controller runs on the lab broker (below).

**How a bot is put together (2026-10-14).** A controller is a thin list of framework modules plus configuration; the rules live in the framework.
- **A strategy = army share + unit comp (user, 2026-10-14).** A new bot is made by copying a working bot (STANCE_ECO2 / RAID_BOT /
  DRAGON_ECO) and changing only its strategy: the stances (`stances/*.lua`: what the spine's labs build and in what ratio, which
  also decides which labs stand in the spine), the strategy hooks (`army_share`, `switch`, `weights`), and config/presets.  Everything
  else is **background every strategy keeps**: economy (line, grids, retrofits, energy, grid/line recovery), spine nano parking
  (the share hook sizes it), scouting (scouts, radar plane, ring radars, depth scouts), raid response (Shuriken floor, Shuriken/Wasp
  answers, home-guard air), AA, the air-lab hold (`WG.TileLabHold`), anti-nuke cover, commander safety, and `mb.armyValue` /
  `WG.MetalBot` publishing.  **Do not rewrite the lab or unit controller for a new strategy, and never drop a background system
  because the strategy does not mention it.**  New behaviour goes in as an opt-in framework option or a stance `plan` field
  (default off), next to what is there.  DRAGON_ECO's first version broke this (a from-scratch lab controller and a unit-controller
  mode that switched planners off).  It lost scouting, raid response and nano parking, and the army overspent until they were put
  back (`knowledge/bots/dragon_eco_2026-10-14.md`).
- **Check a new strategy in eco_sim first** (`python eco_sim.py run --bot <folder> --seeds 1-4 --no-vacuum`; compare with
  `eco_sim.py compare` against the bot it was copied from).  An early income gap there usually means the army share is wrong
  (`[SHARE]` rows: `own=` must count the whole army).
- **Config:** a module's defaults live in its `CFG` table; a bot overrides them with `cfg = BC.Preset("<module>", "GROUP", ..., { own = tweaks })`
  (`bar_framework/bot_config.lua`; the groups are `bar_framework/presets/<module>.lua`, each commented). `BC.Apply` logs one row per module,
  `[CFG] line_transition (RAID_BOT): 30 changed -- ...`, and warns about an option that is not in the module's defaults (a typo), so a game log
  says which flags it ran with. Options that default to nil on purpose are listed in the module's `NIL_OPTIONS`. `tests/test_bot_config.lua` checks
  every preset key is a real option.
- **One owner per kind of order:** `nano_broker` (nanos), `army_broker` (combat units), `con_broker` (air constructors: jobs ask for cons),
  `lab_broker` (factory queues: a bot registers *wants*, the broker does queue read / tail order / insert ahead / grace / pending / depth, and logs
  `[LB]` orders per want). RAID_BOT's `lab_controller.lua` is a list of wants (`RegisterWants`); adding a unit rule is one `add{...}`.
  `tests/test_lab_broker.lua`.
- **Raid response:** `bar_framework/raid_response.lua` (intruder groups, who answers, the stun / Wasp split, the raid record the labs read). RAID_BOT
  and STANCE_BOT both use it; they differ only by its cfg (`BC.Preset("raid_response", "RAID")`, or none).
- **Shared services (2026-10-16, C1-C5): ask these instead of re-deriving.** `bar_framework/build_tree.lua` (who can build what: labs for a unit, which cons place a
  lab, air-only labs, enabler chains), `roles.lua` (unit roles per faction: `Roles.Get("decoy")`; `tests/check_role_names.py` blocks new unit-name literals),
  `eco_ledger.lua` (spine saturation, energy target, unit cap, decoy demand; consumers register on `WG.EcoLedger`), `con_broker` pools (`CB.TakeAny` / `CB.GiveBack`:
  the spine's ground cons are the pool `spine-ground`; borrow through the broker, never through `slot_spine` tables), and the per-frame unit snapshot in `unit_query.lua`
  (`UQ.snapshot(team)`: one `GetTeamUnits` walk per frame, shared). A new feature that needs one of these answers adds to the service, not a new copy.
- **Cross-widget state:** `WG.*` channels and the `WG.MetalBot` fields are documented in `bar_framework/WG_CHANNELS.md`; read them through
  `game_state.lua` where you can.
- **Tests:** `python tests/run_tests.py` runs every suite in parallel (see `tests/LUA_TESTING.md`); run it before and after a refactor.
- **Checking a refactor (2026-10-16): `python order_check.py save` / `check`** runs four eco_sim games (STANCE_ECO2, RAID_BOT, DRAGON_ECO, a vacuum one;
  ~1 min in parallel) with `ECOSIM_ORDER_DUMP` and diffs every order of every game against a saved baseline (the sim uses a fixed `pairs` order in
  that mode, so identical code gives identical streams).  `tests/check_lua_unbound.py <dir>` finds a name a split-out module uses without binding.
  `line_transition.lua` was split into `bar_framework/line_transition/*.lua` this way (316k orders identical).
- **Checking a refactor (older method):** run the same stub scenario through the old and the new controller with `Spring.GiveOrderToUnit` wrapped to print every
  order, and diff the order streams (`tests/test_raid_bot.lua` is a good scenario; seed `math.randomseed`; sort the lines if the scenario's `pairs`
  order is not stable). The lab broker, config and raid-response changes were verified this way (0 differences in 34k+ orders).

### Key Lua API calls used by bots

```lua
Spring.GetMyTeamID()           -- returns 0 or 1 (patched at test time)
Spring.GetTeamUnits(teamID)    -- list of unit IDs for a team
Spring.GetUnitDefID(uid)       -- unit definition index
Spring.GetUnitPosition(uid)    -- x, y, z world coords
Spring.GiveOrderToUnit(uid, CMD.MOVE, {x,y,z}, {})
Spring.GiveOrderToUnit(uid, CMD.FIGHT, {x,y,z}, {})
Spring.GetTeamResources(teamID, "metal")  -- returns current, storage, pull, income, expense
UnitDefs[defID].name           -- unit internal name (e.g. "cormex", "corcom")
UnitDefs[defID].customParams.iscommander  -- true for commanders
```

Widgets respond to Spring callbacks:
- `widget:GameStart()` — game clock begins
- `widget:GameFrame(n)` — called every frame (30 fps game-time)
- `widget:UnitCreated(uid, defID, teamID, builderID)`
- `widget:UnitDestroyed(uid, defID, teamID, attackerID, ...)`
- `widget:UnitFinished(uid, defID, teamID)`

**Economy simulator (2026-10-14): `eco_sim.py` + `ecosim/`** runs a bot's real Lua widgets against a simulated engine (positions,
footprints, builder reach/travel, BAR's builder-priority stall rule, extraction, stockpiles) under LuaJIT: a 20-min vacuum game in ~25 s,
~80 per 5 min with `sweep`.  Use it to rank eco ideas (`run`, `sweep`, `report`, `compare`, `calibrate`), then confirm the best in real
vacuum games.  Calibrated against real `[SNAP]` dumps (`metalbot_state_dump.lua`, installed by the harness); ~1.3x optimistic at 18-20 min
for tuned configs.  Docs, calibration and the tuning log: `knowledge/eco_sim.md`.  `candidates/STANCE_ECO` (no silo capstones, T2 lab
capstones on 15 grids, 10 fusion jobs) reached 5.7k m/s at 20:00 in a real vacuum game and `candidates/STANCE_ECO2` (capstones on
10 grids, 14 fusion jobs) **6.6-8.2k, mean 7.6k over 4 games** (sim 8.0k; STANCE_BOT 4.2-5.6k).
**`candidates/DRAGON_ECO`** (2026-10-14) = STANCE_ECO2's eco + a defend-then-Dragons army (Pounders -> Mammoths at
1.1k m/s, perimeter ring, Dragon lab + decoy commanders, waves of 50); first 2 games vs v16 lost to commander snipes, rounds 3-4 won
on phi; **2026-10-15 moved onto the normal pipeline**: the perimeter army is the stance plan `army = "perimeter"` (not a constant), the
Dragons carry the stance's `extras` behaviours `dragon_defend` (wait + help defend) / `dragon_raid` (waves of 50: commander, then build
power, AA, closest eco), the Dragon labs are the metal sink, `bar_framework/metal_sink.lua` (2026-10-16: any sink unit, spots 4 nanos apart, starts at 85% of the spine's spend capacity), and `slot_spine` `REBUILD_NANOS` rebuilds lost nanos.  See
`knowledge/bots/dragon_eco_2026-10-14.md`.

**T1 overhaul (2026-10-28).** `map_model` `MM.SetBase` / `BaseDist` / `Base` = the eco footprint (refreshed every 120 frames by `unit_runtime` `NetFootprint`; the spawn `MM.Home()` stays the axis). The threat map's `PosWeight`, raid_response's `HOME_R` (`OutsideHome`), the air alarm, home-guard posts and the AA ring measure from it, not from the commander's spawn; raid_response `OUR_HALF` (CORE_ROWS_ECO on) counts an enemy on our side of the map as an intruder, and `HOLD_HOME` is proportional (raid `need` / `committed`). T1 stances: `start` (`raid_start`, 2 groups) -> `start_brutes` (`raid_brutes`, 3 groups, income >= 250) / `t1_hold` (ring + `plan.raid_sections`: a quiet blob goes out as a raid group, never recalled) <-> `t1_push` (2 Brute groups + 1 slow Pounder group). New stance `plan` fields (default off): `raid_groups`, `slow_group`, `batch` + `prod_s`, `raid_sections`. Named behaviours `gator_raid` / `brute_raid` (name only, `[BEH]` rows); Lashers get `range_kite`; `click_army` `EVADE_FOE_PULL` steers an evade toward the enemy base. The machine editor shows each unit's behaviours and its "driven by" owner (`machines/README.md`). Real game vs CORE: batch reinforcement fixed 160 single-file gators behind two groups of 3; hold / push / sections not yet seen in a real game.

**Game reviews from replays (2026-10-29): `replay_logs.py <demo.sdfz> --bot-team N --bot-dir <LuaUI/Widgets snapshot> --out <dir>`** plays a replay back with the bot's widgets
(orders stubbed) plus the tracker / ledger / state dump for both teams, and writes per-team logs + a `result.json` the usual tools read (~11 min for a 30-min game). Snapshot
`LuaUI/Widgets` before a deploy replaces the code that played. First review: `knowledge/sessions/akumar_fmp_2026-10-28.md` (CORE_ROWS_ECO lost to a 56-skill player; ranked fix list).
Its low-risk fixes went into CORE_ROWS_ECO on 2026-10-29, all opt-in and listed in that note's "Implemented" table: `ARMY_SHARE_MAX` 0.8, raid_response `THREAT_HOME`, a linear `rows_default` v3 (raid first, hold last resort, no `t1_push`), `RAID_CARRY`, `idle_value.lua`, click_army `LEG_LEAD`, `PICKET` air scouts, lab_rules `AIR_AA_GATE`, `BLIP_SCOUT_SPEED`, the `eco_ratio` / `enemy_def` signals.
`bar_framework/air_transport.lua` moves a unit with an air transport (engine test `python tests/engine/transport_test.py`; a Valkyrie cannot lift an HLLT).

**Army groups + support elements (2026-10-30, branch `support-elements`).** Support units are not a stance share any more: `bar_framework/army_groups.lua` keeps a record per click_army attack group (`raid` / `slow`) plus the `stage` (the pool), and each kind opts into fixed-size support elements (`bar_framework/support/*.lua`: `aa`, `spam`, `rez`, `antinuke`, `jammer`, `scout`) through the unit_runtime option `SUPPORT = { raid = {...}, slow = {...} }` or a stance's `plan.group_support`. The labs build each element to its want and stop (lab_rules `group-support`, charged to the army budget); the spam element's Grunts come from a T1 bot lab + 4 nanos (`line_transition/spam_lab.lua`, `SPAM_LAB`). On in CORE_ROWS_ECO; first guesses, untuned. `[SUP]` rows. Notes, eco_sim numbers, gaps: `knowledge/bots/support_elements_2026-10-30.md`.

**Nano-column block (2026-10-30, merged into main with support elements; bot `candidates/CORE_v4`).** `LT_CFG.NANO_COLS` replaces the mex grids with a block B N B N B N B (nano columns with a building column each side) beyond the line, built by fronts growing up and down (T1 air cons: nano rows, mex / wind blocks; T2 cons: retrofits to moho / fusion), nano focus at high builder priority, parking to the army share, nano reclaim behind retrofits, an air-transport ferry of 2 line nanos to start it (`bar_framework/line_transition/nano_cols/`). Test bot `candidates/CORE_NANO_COLS`. eco_sim (8 seeds, spawns `2816,1904;9472,10384` so 3 columns fit): mean income doubling 200->3200 m/s 1.71 min vs 2.52 for the grids at 0%, 8.8k vs 6.3k at 20:00. Off by default (flag off = identical orders). Notes: `knowledge/bots/nano_cols_2026-10-30.md`. eco_sim now reports doubling times (`dbl_*`) and models builder priority and air transports; `METALBOT_DEATHMODE=neverend` quits cleanly after the end score.

**AIR_TIMING + unit_runtime (2026-10-25).** CORE's unit controller is now `bar_framework/unit_runtime.lua` (`UNIT.Install`). CORE's
`unit_controller.lua` is a stub, so **a new CORE variant is three short config files, not a copy.** `candidates/AIR_TIMING` = CORE with
the stances `anvil_open` (10% share, the ground only holds) -> `anvil_burst` (a one-off T1 bomber burst, `BURST_SWITCH` /
`strategy_hooks.burst_switch`, stance `plan.share`) -> `anvil_hold`, plus smaller build-power-first Dragon waves. Notes:
`knowledge/bots/air_timing_2026-10-25.md`. Framework changes from it (every bot on unit_runtime / lab_rules / line_transition):
plan army `"defend"` (maneuver blobs + push when ahead; `"hold"`'s parked ring is gone), plan `bomb_run`; **air defence**
(`mb.airRaid`: an AA floor once a bomber is seen; a large raid clears every lab's queue for AA via lab_broker mode `"flush"`,
`AIR_RUSH_SHARE` 1.0, all ground AA + fighters to the raid); **T1 air con recovery** (`AIR_CON_LABS`: a deficit turns a grid capstone
into a T1 air lab; cons spread over all T1 air labs). Known bug left: `endgame.Strike` parks bombers so click_army's bomber runs never fly.

**CORE_HUMAN, ledgers, test tracker (2026-10-25).**
- **`candidates/CORE_HUMAN/`** = CORE's macro and lab rules with an EMPTY unit controller: a person micros the army, `human_control_logger.lua` records it.
  `stance_panel.lua` (right-edge buttons, `/stance <name|next|prev>`, `/share <0-100|auto>`) picks the stance and the army share (macro_runtime
  `MANUAL_STANCES`, `WG.StanceRequest`, `WG.ArmyShareRequest`). Deploy: `.\deploy.ps1 -Bot candidates\CORE_HUMAN`. The logger now attributes orders with
  `widget:CommandNotify` (UI only): `[HCL] cmd/queue` rows are the person's, the rest is `lua_orders` (older logs mix in the macro's orders: filter to army units).
  Notes + a read of a game + Dragon/sink math: `knowledge/bots/core_human_2026-10-25.md`.
- **CORE (and CORE_HUMAN) changes:** `REZ_LAB` (a reserved, urgent T1 bot lab on the line, `line_transition/rez_lab.lua`) + rez floor (`REZ_START_FRAME` 3:00, `REZ_BASE` 8,
  `REZ_MAX` 20); `SINK_MAX` 40 / `SINK_PARALLEL` 5 (10 sink labs absorbed ~4.3k m/s and the bank floated to 600k at 9.4k income); the minelayer (Trapper, `cormlv`)
  is no longer picked as a con (`BT.PlacesEconomy`); `SHURI_LIFT_ALWAYS` (CORE_HUMAN) keeps the Shuriken floor without a raid signal.
- **Ledgers:** `ledger_logger.lua` writes `[LED] spend / fight / value / scout` rows, `python ledger_report.py [log]` reports them and ranks the GAPS. A unit's worth
  (`bar_framework/value_weights.lua`): army = cost, eco = cost + 60 s of income, build power = 3 x cost + 60 s of throughput, commander 25k. `knowledge/ledgers.md`.
  `find_weakness.py` on CORE (runs_tide, 10/16): metal float first, then early warning, undefended eco, AA cover; the 10/25 games agree on float.
- **Rez broker + creep (2026-10-25).** `bar_framework/rez_broker.lua` (unit_runtime `REZ_BROKER`, on by default for every CORE variant: CORE, AIR_TIMING) is the one owner of rez-bot orders: registered jobs
  (`wreck` reclaims, and resurrects only while the metal bank is over 50% (`RESURRECT_BANK`), `repair`, `trail`; add logic with `RB.AddJob{name, prio, find, valid, claim}`), commitment (`MIN_HOLD` / `MAX_HOLD`), wreck / friend
  reservations; rez_crew only supplies the finders. The line's rez lab is published as `WG.RezLab`; lab_rules' `rez-lab` want owns its queue (`lab.only` in lab_broker) so no
  scout / floor / radar rule can fill it, and other labs stop making rez bots while it stands. `scout_net` `CREEP` (unit_runtime default on; `SCOUT_NET = { CREEP = false }` opts out): parked units for vision that GROW like zerg creep: a post grid, a new unit takes a post adjacent to the creep (held posts, our sight, the base, a radar's cover) toward the enemy; front points (enemy groups, the enemy base, where a unit died or met an enemy) forbid posts on or behind them; ground radar units grow a wider net as they are built; a creep unit with an enemy in its vision gets an urgent RETREAT claim even while walking; income-gated (`CREEP_*` options). lab_rules `scout-ahead` inserts scouts into busy queues (`SCOUT_AHEAD`) -- the old empty-queue scout rule never fired in a working lab. Tests: `test_rez_broker`, `test_scout_net`.
- **Test tracker:** `python tests/run_tests.py` logs every run (`tests/test_tracker.json`, `test_history.jsonl`, git-ignored); a suite with 20 passes in a row is
  skipped; `--touched` also runs stable suites covering a changed file, `--all` runs everything, `--status` shows streaks. Coverage = the repo paths a suite's source names
  plus `tests/covers.json`. `tests/LUA_TESTING.md`.

**State machines (2026-10-26).** *When* CORE changes stance and army share is data, not hook code: `machines/<name>.lua` (a stance machine + an army-share machine,
nodes = stances / share values, edges = boolean conditions over named signals, `bar_framework/signals.lua`), run by `bar_framework/fsm.lua`, loaded by `MACHINE = "core_default"`
in `candidates/CORE/macro_controller.lua` (`false` = the old CFG switch options, also the fallback). The two machines read each other through the `stance*` / `share*` signals.
Edit them graphically in `machine_editor.html` (run `python fsm_index.py` first; it also shows the always-on built-in rules from `machines/builtin_rules.lua`). Every transition logs
`[FSM] ...`. Format and workflow: `machines/README.md`. Test: `tests/test_fsm.lua`. A new "when" rule = an edge or a signal, not a new hook.

## Running a test

**Default testing policy (user, 2026-10-26) -- overrides the longer advice below when they conflict:**
1. **Eco sim first.** Anything that does not involve the army fighting -- economy, build orders, building an army, scouting patterns (the sim has no real enemy to see) --
   is tested in `eco_sim.py`, not a real game. Only fighting needs a real game.
2. **Otherwise run ONE real game** long enough to see the change. An early-game change = a 10-minute game (`--end-minutes 10`). No A/B, no repeats, no slot pairs, no baseline
   unless the user asks for one.
3. **Do not write new Lua unit tests** unless something broke in a real game (then a regression test for that break is fine). Do not run `tests/run_tests.py` as the test of a change;
   running the existing suites after a refactor is still fine.
4. **No one-off bots for a test.** Make the test a variant of CORE (stance + config, `candidates/CORE`-derived). If a variant cannot do the test, say why before building anything else.

### Locally (Windows)

```powershell
cd C:\Users\malco\OneDrive\Documents\GitHub\MetalBot
python bot_testing.py --bot1 OK_BOT --bot2 MY_BOT --duration 300 --save-replay
```

- `--bot1` / `--bot2` — folder names (relative to repo) or absolute paths
- `--duration` — real-wall-clock seconds to run (game runs at `--speed`, default 10x)
- `--server spectator|host` — default `spectator`: a third, bot-less headless process hosts so
  both bots get the same order latency. `host` is the old layout (team 0 hosts) and gives team 1
  several game-seconds of extra lag at high speed — see `knowledge/lessons_learned.md`
- `--speed auto|N` — default `auto`: the spectator host's Speed Governor moves the speed between
  `--min-speed` (2) and `--max-speed` (40) to hold the bots' order round trip near `--target-lag`
  (30 frames). In a DRAGON_BOT mirror that is ~11x early, ~7x by 8 min, ~2x by 10 min as the sim
  gets heavier. A number pins the speed (lag then grows with it: ~20 frames at 10x, ~40 at 20x,
  and the bots fall behind once the sim can't keep up). The result prints `Order latency` and
  `Game speed` blocks
- `--profile` — logs `[PROF]` lines: per-widget Lua milliseconds per game-minute on each bot process
- `--save-replay` — saves a `.sdfz` replay to BAR's demos folder

### Single-client mode (`--server single`, added 2026-10-08)

One `spring-headless` process runs **both** bots (`single_client.py`; `ab_test.py --server single`,
`$env:SERIES_EXTRA="--server single"` for `series.py`). The normal layout runs three processes that each simulate the
whole game; here a spectator host turns on `cheat` + `godmode 3`, NullAI leads both teams, and every bot widget is
wrapped in a per-team shim (own team id, fog via the team's LOS/radar, orders only to own units, per-team `WG`, log
lines tagged `<T0>`/`<T1>` and split back into per-team logs). A 20-minute LINE_CLICK mirror takes ~2.5-3.5 min wall
(normal: ~12 min, and it often hits the wall-clock backstop first) and ~4 GB of RAM instead of ~11 GB.
Things that bit while building it (details in the `single_client.py` docstring):
- Widget orders still go through the engine's local network loop, so its own governor holds the order round trip near
  `--target-lag` (pinned at 150-280x the lag was 150-320 frames and the bots fell apart).
- BAR's stock automation widgets (nano turrets on FIGHT etc.) do nothing for a spectator; each team gets a shimmed
  copy (`STOCK_WIDGETS`). Without them the bots spent ~35% less by 5:00.
- It pins its main thread to core 8 (`main_core_masks(4)[3]`); the engine default core is the one a normal match's P0 gets.
- LuaUI garbage outran BAR's per-Update collector at high game speed (1.2 GB, LUA_ERRMEM after END_SCORE, process
  never quit); `GC_WIDGET` now collects per sim frame (peak ~550 MB, `[MEM]` rows). BAR fixes the all-Lua limit at
  1536 MB in modrules, so it cannot be raised. `result["lua_failure"]` flags any Lua OOM or removed match widget.
- Radar blips show a unit type only with the engine's rule (seen in LOS **and** on radar ever since, bits 4+8).
- Speed (2026-10-08): single mode disables BAR's ~193 display-only widgets (`UI_WIDGET_PREFIXES`; AdvPlayersList
  alone cost ~8 s a game), and `bar_framework/threat_map.lua` scans our combatants once per frame instead of once per
  incident per call (identical results, `tests/test_threat_map_cache.py`) -- that loop was most of the unit
  controller's time. LuaUI time per 20-min LINE_CLICK_v12 vs LINE_CLICK game 170 s -> 25-56 s; game-minutes 1->20
  took 319 s before, 164 s after (one game each, games vary ~1.5x). Simulation is now the main cost.
- **Run single matches in parallel -- the remaining big speed-up.** Each match is one engine process on one core
  (~4 GB RAM; this PC has 8 physical cores). `claim_core()` locks a free physical core per match
  (`%TEMP%\metalbot_single_core_<n>.lock`, released when the process exits; cores 8, 6, 4, ... first, the three a
  normal match pins last), so just start several `bot_testing.py --server single` runs at once. Measured 2026-10-08:
  3 full 20-min v12 vs LINE_CLICK games side by side took 272 s in total (247-271 s each vs ~212 s alone: shared
  memory bandwidth costs ~20% per match) = **~2.3x throughput**, all ended cleanly. Limit by RAM (~4 GB each, more in
  long games) and leave cores for anything else running. `series.py` is still sequential; launch several series (or
  match processes) yourself. Not worth it: more bot Lua work (all widget Lua is ~20% of a game now, <1.25x even if
  removed) or a higher `--target-lag` (the governor only limits the first ~8 min; after that the sim is CPU-bound).
- Long games: from ~30 game-min the sim runs at ~1x with big armies, so a 60-min game takes roughly 40-60 min wall;
  pass `--duration` of ~5400+ (the default backstop for `--end-minutes 60` is ~27 min). Two 60-min attempts ended
  cleanly on commander kills at 32 and 39 min (lag <=50 frames, LuaUI <=390 MB); a full 60:00 run is still unchecked.
**Validation (2026-10-08, main PC):** behaviour matches normal mode (spent 3.0k/9.8k/26.7k at 3/5/8 min vs
2.9k/9.1k/25.5k; army at 10:00 11.2k vs 11.4k); fog audit (engine LOS bits vs LOS map at unit positions) agrees on
1993/1994 in-LOS checks, ~93% of enemy checks hidden; per-team metal/energy match the replay's engine team stats within
~1%; order lag p90 19-31 frames all game; zero Lua errors. Mirrors (6 x 20 min LINE_CLICK): slot0/slot1 END_SCORE
0.96, 1.21, 1.04, 0.99, 1.03, 0.59 -- geo-mean 0.95, no slot-0 edge, per-game spread ~1.28x. v12 vs LINE_CLICK
(12 games): v12 3 commander kills, score-game geo-mean 0.96 -- the TreeServer 1.36x did NOT reproduce, but normal mode
on the main PC didn't either (2 games, geo-mean 0.89). **Normal mode's late game runs under huge order lag on the main
PC** (governor at its 2x floor from ~12 min: lag ~160 frames at 15:00, 600-850 at 18:00, slot 1 worse); single mode
holds ~20-30 frames all game, so the two modes are not comparable and 20-min normal-mode results are partly a lag test.

### Remote test machine: TreeServer (Windows laptop)

A second Windows laptop, set up 2026-10-05, runs the same harness so the main PC stays free.
(`remote_testing.py` only knows the two Raspberry Pis; TreeServer is not wired into it.)

- Tailscale IP `100.104.234.20`, login `malco` (the device name is `TreeServer`, not the login).
  Key-only SSH: `ssh -i ~/.ssh/id_ed25519_nopass malco@100.104.234.20`.
- Repo clone: `C:\Users\malco\Documents\GitHub\MetalBot` (plain Documents, not OneDrive); update with
  `git pull`, then run `deploy.ps1` there. BAR is installed in the same place as on the main PC, so the
  harness works unchanged.
- Node.js is not installed, so `replay_analysis.py` won't run there yet.
- It sleeps after 30 min idle on purpose. Start the keep-awake script on it before a test session; SSH
  and Tailscale drop while it sleeps and it can't be woken remotely.
- Run both bots of an A/B on the same machine. TreeServer's CPU differs from the main PC's, so the
  speed governor reaches a different game speed and results are not directly comparable across machines.
- If a match there ends implausibly early (the first smoke test ended after ~38 game-seconds with every
  building self-destroyed; later runs were normal), rerun before trusting it. Cause unknown.

## How matches end

A match runs normally until **`--end-minutes`** of game time (default 60). Then both commanders
self-destruct and the winner is declared from stats, not from which suicide the engine
processed first. Each process scores only its **own** team (a headless client cannot see the
other; the tracker's `[TRK] init` line logs `fullview=0` in both), and Python compares the two:

    score = army metal value (finished, armed, mobile units) + --eco-weight (default 60) x metal income/s

A score must beat the other by 10% to win; otherwise the result is a draw (`end_score_tied`) —
it deliberately does NOT fall back to units built. `--duration` is only a real-time backstop; if
it fires first the result is tagged `end_score_wallclock` / `end_reason: wallclock` and is not a
full-length verdict. Default `--duration` is derived from `--end-minutes` (~frames/80 + 300s).

## Stats tracker

`metalbot_stats_tracker.lua` is a general widget (also deployed to BAR by `deploy.ps1`). Each
headless process gets its own copy, so it logs only what that bot can see. Every 30 game-seconds it
writes `[TRK] eco | units | army | intel | combat` rows plus once-only `event` lines; the harness
parses them into `result["tracker_timeline"]` (dicts with `kind`, `frame`, `team` and the fields).
The header comment in the file is the reference for every field. The signals that matter for finding
weaknesses:

- **Economy/production:** stall and float fractions, metal pull vs income, `units_total`/`unit_cap`,
  factories busy/idle, build power idle.
- **Threat response:** `first_enemy_seen`, `first_enemy_near_base` (with `warned_dist`/`lead_frames`),
  `first_damage_taken`, `first_army`, `first_defense`, `first_aa` (dedicated AA only), and how much
  of the army/defence can hit air (`*_hits_air`, `aa_dedicated`) or ground.
- **Awareness:** `los_frac`, `radar_frac`, `explored_frac` (share of the map ever seen);
  `fresh_home/corridor/enemy/mex` (age-weighted, by zone), `believed_mv` (remembered enemy),
  `arrivals_n`/`arrivals_warned_n`/`lead_med`, `lost_unseen_*`. Enemies are found with
  `GetAllUnits()`; `GetVisibleUnits` is camera-culled, so intel in results before 2026-09-23 is blind.
- **Ability to act:** `fac_bp`, `fac_bp_open`, `fac_bp_useful` (lab support BP capped per
  game_mechanics 2.5), `mob_bp`, `nano_idle_bp`, `army_em`, `army_m_per_bp`, `build_sites`,
  `ground_fac`/`fac_exit_ok` (path out of each ground lab), `stuck_units`, `air_trans`, `max_tech`;
  `fac_boxed` event. Eco row: `metal_pull_avg`/`energy_pull_avg`/`*_inc_avg` (interval averages).
- **Roles and home defence:** `home_guard_gnd_mv`/`home_guard_air_mv` (armed value near base),
  `rez`, `util_intel` (mobile radar/jammer).
- **Attrition:** `cons_alive`, `lost_cons`, `cons_all_dead`/`cons_restored` events, `lost_enemy_*`
  (enemy-attributed losses; `lost_*` also counts the bot's own reclaims), `killers=`, `lost_to_air`.
- **Engagement shape:** `pm_deaths`/`pm_isolated`/`pm_support_avg` (did our units die alone?),
  `groups`/`main_share` (is the army one group?).
- **Cover and strategic threats:** `fac_aa_cover`/`fac_aa_ded_cover`, `fighters`; `antinuke`,
  `fac_antinuke_cover`, `silo`, `lrpc`; enemy `first_enemy_nuke`/`first_enemy_lrpc`.
- **Commander:** a `cmdr` row (hp, distance from base, enemies/friends/AA/anti-nuke near it) and
  `commander_lost killer=`.
- **Radar blips:** radar-only contacts are tracked; a moving blip's speed is matched to unit types
  (either/or): `first_radar_moving`, `blip_*`, and `WG.StatsTracker.DecodeSpeed(speed)` for bots.
- Not tracked: cloaked/stealth units (see `knowledge/game_mechanics.md` 7.5).

`python find_weakness.py result.json` reads those rows and ranks likely weaknesses; the
`/find_bot_weakness <bot>` command wraps it into a full diagnosis (it reports weaknesses, it does not
fix them; `improve_bot` does that).

## Reading test results

The test prints a summary at the end:

```
Non-commander units built:
  Team 0 (BOT_A): 758    ← more units = better economy/production
  Team 1 (BOT_B): 602

Sanity checks:
  [PASS] Team 0 built 758 non-commander unit(s)
  [PASS] Team 1 built 602 non-commander unit(s)
```

**Do not compare two bots with a single match.** There is a large advantage to whichever bot
is passed as `--bot1` (slot 0) — large enough that a bot beats *itself* from slot 0. Use:

```powershell
python ab_test.py --bot-a candidates/MY_BOT --bot-b pool/bots/champion_v1
```

It runs one match per slot order by default (`--repeat N` for more) and compares the bots
**within each match** (A value / B value), which cancels match-wide swings; the geometric
mean over both slot orders cancels the slot bias. A winner must lead in every match and clear
~2σ of the paired noise: ×1.15 at one match per slot, ×1.08 at three (`PAIR_LOG_SD`,
re-measure as A/Bs accumulate). One match per slot catches ~15% effects and breakages; raise
`--repeat` for smaller effects or when ranking several bots. Also check the mechanism directly
(the log line or tracker field the change should move). **`NO DIFFERENCE DEMONSTRATED` is the
normal honest outcome** — log it as that, not as a narrow win or regression.

Two separately measured reasons a single match proves nothing: the slot-0 advantage above,
and run-to-run noise between byte-identical bots.

**Noise compounds, so measure early.** Spread between identical bots, army value: 1.07x at
frame 7200, 1.14x at 14400, ~1.35x at 18000, 2.00x at 36000. `ab_test.py` defaults to **army
value at frame 14400** (8 game-min) — the latest point still under ~1.15x noise. **Detectable
effect ≈ 15–20%; anything smaller is not measurable here at any frame.** A *longer* match is a
*worse* measurement — do not raise `--duration` hoping for a cleaner signal.

Use `python checkpoint_map.py <abtest-temp-dir>` to chart signal against noise per frame when
a result is ambiguous.

- **Army metal value at frame 18000** (10 game-minutes) is the metric, not units built. Slot 0
  saturated the old ~2000 unit cap in a 300s match (the cap is now 5000), so end-of-match numbers can't tell two
  competent bots apart.
- Each team's numbers must be read from its own process — team 0 from P0, team 1 from P1.
  `fullview=1` does not give cross-team visibility in headless.
- If a team built 0 units, the bot crashed or failed to connect.
- Game speed is automatic by default (see `--speed`); `--speed 100` was the old setting and reached
  ~1500-2000 frames/s early on this PC, but with one-sided order latency (see `--server`).
- Lua errors mentioning `gui_pip.lua` / `CreateShader` are BAR's own stock widget failing
  headless. They appear in every run and are harmless.

Everything in `knowledge/strategy_log.jsonl` logged before 2026-09-18 was measured under a
broken harness and is void — see the top of `knowledge/lessons_learned.md`.

### State-value score (`bot_score.py`, report only)

`python bot_score.py result.json [--detail FRAME] [--ref other.json:TEAM]` estimates how strong
each side's position is (phi, in metal-equivalents) at checkpoints. It breaks the score down into
materiel, economy, **ability to act** (the scarcest of metal, energy and build power, and names
that binding constraint), exposure and awareness. It is computed from the tracker rows, so old
results can be re-scored; weights live in `score_config.json`. `bot_testing.py` prints it and saves
it as `result["phi"]`, and `ab_test.py --metric phi` compares on it. It does **not** decide
winners yet. `score_eval.py <results...>` checks it against real outcomes and mirror-match noise;
the rationale and validation log are in `knowledge/scoring.md`. Update that log whenever the
weights change.

### Replays (`--save-replay` + `replay_analysis.py`)

A saved replay records **both** teams from the engine's own team statistics, so it is the one
place to see each side's numbers from a single source (each process's logs only see its own
team). The harness prints the path (`Replay saved: ...data\demos\<name>.sdfz`).

```powershell
python replay_analysis.py "<path>.sdfz" --no-history        # text report, both teams
python replay_analysis.py "<path>.sdfz" --no-history --json # full analysis as JSON
```

Omit `--no-history` to also append a record to `knowledge/replay_history.jsonl`. It reports per team:
metal/energy produced, energy wasted, peak income, units produced/lost/killed, damage
dealt/received, first combat contact, and checkpoints at 120/240/450/600 s of game time. Needs
Node.js and `npm install sdfz-demo-parser` (already installed in this repo), and a match
that ended cleanly (a killed process leaves a 0-byte `.sdfz`). Its "Duration" line is not the
game length; use the checkpoints.

## Deploying changes

After editing any Lua file, run the deploy skill so changes are reflected in the BAR widget folder:

```
/deploy
```

Or the deploy skill runs automatically when a `.lua` file is created or modified.

## Project layout

```
MetalBot/
  bot_testing.py       — test harness (single match; rarely what you want directly)
  single_client.py     — --server single: both bots in one engine process (shim, governor, stock widgets)
  ab_test.py           — CORRECT way to compare two bots: both slot orders, frame-18000 metric
  find_weakness.py     — ranks likely weaknesses from a result's tracker_timeline
  bot_score.py         — state value phi per team per checkpoint (config: score_config.json)
  score_eval.py        — does phi predict winners? noise in mirrors; weight fitting
  ledger_logger.lua    — widget: [LED] spend / fight / scouting-lead ledgers; ledger_report.py reads them (knowledge/ledgers.md)
  stance_panel.lua     — widget: stance + army-share buttons for CORE_HUMAN (MANUAL_STANCES)
  replay_analysis.py   — economy/combat telemetry from a .sdfz replay (needs a clean game-end)
  build_order_sim.py   — beam-search opening optimizer; modes incl. max_rate, `spend` (most metal spent
                          with an army floor by a deadline) and config-driven
                          `raid` (raid_configs/*.json: unit milestones, required/weight)
  blueprint_gen.py     — turns a build_order_sim.py result into a blueprint .lua + layout image;
                          reserves an exit corridor (M.keepout) for ground-unit factories
  OK_BOT/              — original reference bot (Cortex faction)
  INACTIVE_BOT/        — builds nothing: the opponent for pure-economy runs
  RAIDER_BOT/          — exploiter: air raid (bombers) on an early timer
  GROUND_RAIDER_BOT/   — exploiter: ground raid (Incisors + fighter escort) on an early timer
  candidates/          — bots under test; LINE_CLICK_v16 is the main one (each folder: macro/lab/unit_controller.lua)
  blueprint_placer.lua — shared helper (distributed build orders, mex grid expansion)
  bar_framework/       — shared modules loaded via VFS.Include; bar_framework/README.md says what each does
  tests/               — plain-Lua tests: spring_stub.lua + test_*.lua (tests/LUA_TESTING.md)
  archive/             — retired bots, candidates, framework modules, tests, root files (archive/README.md); not deployed
  blueprints/          — blueprint .lua files + the build_order_sim.py results they came from
  raid_configs/        — build_order_sim.py `raid` mode configs
  knowledge/            — game info + how bots are built (README.md indexes it; bots/ design notes, plans/ open work, sessions/ dated logs)
  knowledge/raid_runs/ — saved exploiter-bot match results and analysis
```
