# MetalBot — Beyond All Reason Bot Development

## What this project is

MetalBot is an AI bot for the RTS game Beyond All Reason (BAR), implemented as Spring engine Lua widgets. The bot runs headlessly (no display) in a dedicated test harness (`bot_testing.py`) so it can be developed and benchmarked automatically.

## Main bot and test settings

**`candidates/LINE_CLICK_v16/` is the main bot** (user, 2026-10-12: v16 is the best version; future work builds off it).
It is LINE_CLICK + the v12-v16 changes: forward-core/flanking army, grid expansion fixes, energy push, resource-pressure grids,
energy cells, capstone silos + anti-nuke, rez bots, depth scouts. Its design notes are in `knowledge/v16_2026-10-09.md`
(economy bench: `knowledge/eco_scaling_2026-10-09.md`). **Every flag v16 turned on is now the framework default**, so the
controllers pass no overrides; `candidates/LINE_CLICK` (the older main bot, a regression opponent), `LINE_HUMAN`, `ECO_BENCH`
and `ARMY_BENCH` pin their old behaviour explicitly (a "pre-v16 ... pinned" comment next to the override).
`candidates/LINE_CLICK_v17` (paintkid-game fixes) and `candidates/LINE_BOMB` (stance system + T1 bomber rush) derive from v16
and are untested/in progress; `candidates/RUSH_SPAM` is a deliberately dumb eco-spam opponent. Open ideas: `experiment_ideas.md`.
**Retired 2026-10-12 (moved, not deleted -- see `archive/README.md`):** LINE_BOT, TILE_BOT, SPINE_BOT, MECH_BOT, DRAGON_BOT and every
older LINE_CLICK_vN / TILE_V2 candidate now live under `archive/bots/` and `archive/candidates/`. Earlier history (v12, v13d, v14):
`knowledge/overnight_2026-10-08.md`. Remaining top-level bots: `OK_BOT` (reference), `INACTIVE_BOT` (pure-eco opponent),
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
and kept in `draw_score`. `ab_test.py --metric` defaults to phi. See `knowledge/scoring.md` (v4). (2) **Start positions default to `2400,1904;9888,10384`**
(corner starts moved ~2.2 mex grids in); `METALBOT_STARTPOS="x0,z0;x1,z1"` overrides, `paintkid` = the paintkid replay's spawns (~7.3k apart), `map` = the
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
are in `knowledge/claude_md_history_2026-10-14.md`, word for word; the per-topic notes are `knowledge/session_2026-10-12_stance_framework.md`,
`knowledge/session_2026-10-12_energy_eco.md`, `knowledge/session_2026-10-13_raid_bot.md`, `knowledge/variance_notes_2026-10-12.md`. Short version:
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
- **Cross-widget state:** `WG.*` channels and the `WG.MetalBot` fields are documented in `bar_framework/WG_CHANNELS.md`; read them through
  `game_state.lua` where you can.
- **Tests:** `python tests/run_tests.py` runs every suite in parallel (see `tests/LUA_TESTING.md`); run it before and after a refactor.
- **Checking a refactor:** run the same stub scenario through the old and the new controller with `Spring.GiveOrderToUnit` wrapped to print every
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

## Running a test

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
  knowledge/raid_runs/ — saved exploiter-bot match results and analysis
```
