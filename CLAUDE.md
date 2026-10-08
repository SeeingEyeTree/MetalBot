# MetalBot — Beyond All Reason Bot Development

## What this project is

MetalBot is an AI bot for the RTS game Beyond All Reason (BAR), implemented as Spring engine Lua widgets. The bot runs headlessly (no display) in a dedicated test harness (`bot_testing.py`) so it can be developed and benchmarked automatically.

## Main bot and test settings

**`candidates/LINE_CLICK/` is the main bot right now** (updated 2026-10-08). Start new work from it (not TILE_BOT, DRAGON_BOT or SPINE_BOT). Open ideas: `experiment_ideas.md`.
**`candidates/LINE_CLICK_v12/` beat it 5-0-1 (1.36x END_SCORE, 6 twenty-minute mirror games, both slot orders) in the
2026-10-08 overnight run** -- LINE_CLICK + click_army FORWARD_CORE and FLANK, line_transition ENERGY_PUSH, and the
commander evading real dives (commander_guard DANGER_VALUE). Everything tried that night, and the measurement
lessons: `knowledge/overnight_2026-10-08.md`.
**Best so far: `candidates/LINE_CLICK_v13d/`** (2026-10-08 daytime, from the user's notes on v12): v12 + grid expansion
fixes in line_transition (COLLECT_ALWAYS, GRID_ENEMY_SIDE, LINE_GATE off; alone 3-0 vs v12) + Mammoths/Sheldons in the
slow group, Shuriken stun allocation, brave rez crew. Rejected: 10% army floor, 30 rez bots by 8:00. `LINE_CLICK_v14`
(grids pick mex/wind/nano by resource pressure + placer order grace) stalled its grids; a placer fix (0be5f6d) is untested.
Status and next steps: `candidates/LINE_CLICK_v13/TODO.md`. Neither is promoted yet -- the user decides.
**Git:** work after v12 is on branch `bot-testing-v2` (HEAD moved off `main` mid-session); `main` stops at v12.

**Measurement rules learned 2026-10-08:** grep a run for `Sync error` (`result["desync"]`) before trusting anything past
~10 game-min (the stats tracker's `RequestPath` desynced nearly every match until it was switched off); run 20-minute
mirror A/Bs on **TreeServer** (the main PC gives slot 0 a ~1.4-1.5x edge there, TreeServer ~1.0-1.1x) and always pair
slot orders; never `Stop-Process` spring-headless by name (other sessions run matches on this PC). Tools:
`series.py` (batch of matches), `match_summary.py`, `h2h_report.py`; `--bot2 AI:BARb` plays BAR's native AI (weak vs
LINE_CLICK: a regression check, not a strength measure); `ab_test.py --end-minutes/--keep`.

**All testing uses a 5000 unit cap** (`maxunits=5000` in the harness's modoptions; BAR's default is
2000). The larger cap makes a bigger economy worth building. Results from before this change were
measured under the 2k cap and are not directly comparable.

## Bot structure

A bot is a **folder** containing three Lua widget files:

| File | Responsibility |
|---|---|
| `macro_controller.lua` | Economy: commander build order, mex expansion, factory placement |
| `lab_controller.lua` | Factory queues: what units each lab builds and in what ratio |
| `unit_controller.lua` | Combat/scouts: where units move and how they fight |

`OK_BOT/` is the original reference bot. `DRAGON_BOT/` was the main bot (sim-derived
opening, executed distributed via `blueprint_placer.lua`, then mex-grid scaling — see
`knowledge/lessons_learned.md`). `RAIDER_BOT/` and `GROUND_RAIDER_BOT/` are DRAGON_BOT-derived
**exploiter fixtures**, not champion candidates: each is tuned to hit a specific known weakness
(no AA, no ground defence) as early as possible, so `find_bot_weakness` can test threat response
on demand instead of waiting for an opponent that might raid. Copy `DRAGON_BOT/` as a starting
point for a new bot; keep exploiter variants in their own folders rather than merging them.
`MECH_BOT/` is DRAGON_BOT plus the units-and-scouting parts of `knowledge/game_mechanics.md`
(recon, raiders, rez bots, reactive AA, commander safety, endgame hunt); its new logic lives in
MECH-only `bar_framework/` modules, so DRAGON_BOT is unchanged. See `MECH_BOT/GOAL.md` for what
changed and which tracker fields measure it. It has not been run in a real match yet.
`TILE_BOT/` is DRAGON_BOT's macro with the spiral opening replaced by a human player's con-bot tile
opening: the commander builds `bad_com_start`, up to 4 con bots each build a row of a 4x4 block of
`con_bot_grid` tiles (`bar_framework/tile_crew.lua`), then an air lab hands off to the mex grids.
Its lab and unit controllers, and the spine (`bar_framework/spine.lua`), are SPINE_BOT's (origin/main).
See `TILE_BOT/GOAL.md`; `tests/test_tile_bot.lua` checks the block geometry and runs a stub smoke test.
`LINE_BOT/` is an economy-only bot: a line of mex/wind slots (`bar_framework/line_crew.lua`), then an air lab on the
6 open slots nearest its outer con and TILE_BOT's grid system (spend-pressure hand-off, capstone, T2 retrofits,
unit-cap consolidation) in `bar_framework/line_transition.lua`. Army: a vehicle lab on the line (done by 4:30) seeds
TILE_BOT's spine (`LINE_BOT/SPINE_BRIEF.md` is the history); the starter bot lab is reclaimed to fund it. Stub-tested only so far; `candidates/LINE_NOSPINE` is the economy-only A/B baseline.
`LINE_BOT/GOAL.md` has the design, measurements and lessons. Deploy it with
`.\deploy.ps1 -Bot LINE_BOT` (the default bot is DRAGON_BOT); `tests/test_line_crew.lua` runs through lupa's Lua 5.1.

**`candidates/LINE_HUMAN/` + `human_control_logger.lua`** record how a person controls units (LINE_BOT macro, empty unit controller, the
person queues and commands the army). Deploy with `.\deploy.ps1 -Bot candidates\LINE_HUMAN`; `python human_control_report.py` and
`python human_kite_report.py` read the `[HCL]` logs. Details: `candidates/LINE_CLICK/GOAL.md` and the header of `human_control_logger.lua`.

**`candidates/LINE_CLICK/` is the MAIN BOT.** LINE_BOT's economy plus a human-style aggressive army (`bar_framework/click_army.lua`: up to 3
simultaneous attack groups hitting different enemy targets, ranked by build power + eco; `bar_framework/slow_front.lua`: Lashers/Pounders/rez bots
played from the user's own games; `bar_framework/scout_lanes.lua`: enemy-side scouting). Doctrine: win by killing enemy build power/eco/commander,
not by trade efficiency. Judge it on enemy BP/eco destroyed (`[CK]`, `[SF]` log rows), then A/B on army value. Full design, rulings and tunables:
`candidates/LINE_CLICK/GOAL.md`. Tests (lupa Lua 5.1, see `tests/LUA_TESTING.md`): `test_click_army`, `test_slow_front`, `test_scout_lanes`.

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
Results are **not comparable** with normal-mode results (less order lag). First mirror batch (6 x 20-min LINE_CLICK,
main PC): slot0/slot1 END_SCORE 0.96, 1.21, 1.04, 0.99, 1.03, 0.59 -- geo-mean 0.95 (no slot-0 edge seen; normal mode
gives slot 0 ~1.4x here), per-game spread ~1.28x, scores 78-110k, no desyncs possible. Six games are not a noise floor:
keep pairing slot orders and add mirrors before trusting a small A/B difference in this mode.

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
  DRAGON_BOT/          — earlier main bot: sim-derived opening + mex-grid scaling
  RAIDER_BOT/          — exploiter: air raid (bombers) on an early timer
  GROUND_RAIDER_BOT/   — exploiter: ground raid (Incisors + fighter escort) on an early timer
  MECH_BOT/            — DRAGON_BOT + game_mechanics units/scouting (see MECH_BOT/GOAL.md)
  TILE_BOT/            — con-bot tile opening + SPINE_BOT lab/unit controllers (TILE_BOT/GOAL.md)
    macro_controller.lua
    lab_controller.lua
    unit_controller.lua
  blueprint_placer.lua — shared helper (distributed build orders, mex grid expansion)
  bar_framework/       — shared widgets loaded via VFS.Include (escape_guard, nano_broker, ...);
                          MECH_BOT only: enemy_intel, recon_plan, raid_group, rez_crew,
                          endgame, commander_guard
  tests/               — plain-Lua tests: spring_stub.lua + test_*.lua (tests/LUA_TESTING.md)
  archive/             — retired files (old bot.lua, new_bot.lua, original_bot_tmp, unused visualisers); not deployed
  candidates/          — bots under test; LINE_CLICK is the main one (tracked in git)
  blueprints/          — blueprint .lua files + the build_order_sim.py results they came from
  raid_configs/        — build_order_sim.py `raid` mode configs
  knowledge/raid_runs/ — saved exploiter-bot match results and analysis
```
