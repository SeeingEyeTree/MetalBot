# MetalBot — Beyond All Reason Bot Development

## What this project is

MetalBot is an AI bot for the RTS game Beyond All Reason (BAR), implemented as Spring engine Lua widgets. The bot runs headlessly (no display) in a dedicated test harness (`bot_testing.py`) so it can be developed and benchmarked automatically.

## Bot structure

A bot is a **folder** containing three Lua widget files:

| File | Responsibility |
|---|---|
| `macro_controller.lua` | Economy: commander build order, mex expansion, factory placement |
| `lab_controller.lua` | Factory queues: what units each lab builds and in what ratio |
| `unit_controller.lua` | Combat/scouts: where units move and how they fight |

`OK_BOT/` is the original reference bot. `DRAGON_BOT/` is the current main bot (sim-derived
opening, executed distributed via `blueprint_placer.lua`, then mex-grid scaling — see
`knowledge/lessons_learned.md`). `RAIDER_BOT/` and `GROUND_RAIDER_BOT/` are DRAGON_BOT-derived
**exploiter fixtures**, not champion candidates: each is tuned to hit a specific known weakness
(no AA, no ground defence) as early as possible, so `find_bot_weakness` can test threat response
on demand instead of waiting for an opponent that might raid. Copy `DRAGON_BOT/` as a starting
point for a new bot; keep exploiter variants in their own folders rather than merging them.

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

### Via Tailscale (recommended)

Both Pis are accessible via Tailscale. This method works from anywhere and automatically handles results:

**Pi 1** (dme43@100.68.112.80, local 192.168.1.170) — has `~/MetalBot` and `~/bar_data`; runs matches
**Pi 2** (iamtree@100.86.20.115, local 192.168.1.172) — has the USB flash drive AND `~/MetalBot`/`~/bar_data` (provisioned 2026-09-15 via a direct Pi-to-Pi tar transfer from Pi 1); runs matches too

```powershell
python remote_testing.py --bot1 OK_BOT --bot2 MY_BOT --pi-host 100.68.112.80 --save-replay
```

Options:
- `--pi-host 100.68.112.80` — Tailscale IP for Pi 1 (dme43)
- `--pi-host 100.86.20.115` — Tailscale IP for Pi 2 (iamtree)
- `--usb-mount /mnt/usb` — USB drive mount path (auto-detected; the drive currently actually sits at `/media/iamtree/USB321FD`, not `/mnt/usb`)
- `--result-dir metalbot_results` — Relative path on USB for saving results

All results/replays are archived to iamtree's USB regardless of which Pi ran the match — see `remote_testing.archive_to_iamtree()`.
- `--skip-deploy` — Skip syncing bot files (faster for iterative tests)

Results are automatically saved to USB flash drive and synced back if available.

### Direct SSH (legacy method)

For direct SSH without Tailscale:

```bash
ssh -i ~/.ssh/id_ed25519_nopass dme43@192.168.1.170 \
  "cd ~/MetalBot && BAR_DATA_DIR=/home/dme43/bar_data python3 bot_testing.py \
   --bot1 OK_BOT --bot2 MY_BOT --duration 300 --save-replay"
```

Copy replays back:
```powershell
scp -i ~/.ssh/id_ed25519_nopass `
  "dme43@192.168.1.170:/home/dme43/bar_data/demos/*.sdfz" `
  "C:\Users\malco\AppData\Local\Programs\Beyond-All-Reason\data\demos\"
```

### Pi Setup (for new Pi provisioning)

Both Pi 1 and Pi 2 have `~/MetalBot` as a real git clone (branch `bot-testing-v2`) and
`~/bar_data` with the engine + game content (aarch64 Debian 12 build). To update either
Pi with newly committed code:
```bash
ssh -i ~/.ssh/id_ed25519_nopass dme43@100.68.112.80   "cd ~/MetalBot && git pull"
ssh -i ~/.ssh/id_ed25519_nopass iamtree@100.86.20.115 "cd ~/MetalBot && git pull"
```
`git pull` only picks up committed + pushed changes — uncommitted local edits still need
manual scp. `bar_data/` is not part of the git repo.

For provisioning a brand-new Pi: install git (`sudo apt install git`), clone the repo, then
copy `~/bar_data` from an existing provisioned Pi (same architecture required — both current
Pis are aarch64). A same-LAN Pi-to-Pi copy won't work directly between these two specific
Pis ("No route to host" between their 192.168.1.x addresses) — route it over their Tailscale
IPs instead, e.g. `tar -C ~ -cf - bar_data | ssh iamtree@<new-pi-tailscale-ip> "tar -C ~ -xf -"`.

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
fix them; `improve_bot` does that). Both Pis need the new `bot_testing.py` and tracker;
`remote_testing.py` does not sync them.

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
  saturates the ~2000 unit cap in a 300s match, so end-of-match numbers can't tell two
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
  ab_test.py           — CORRECT way to compare two bots: both slot orders, frame-18000 metric
  find_weakness.py     — ranks likely weaknesses from a result's tracker_timeline
  bot_score.py         — state value phi per team per checkpoint (config: score_config.json)
  score_eval.py        — does phi predict winners? noise in mirrors; weight fitting
  replay_analysis.py   — economy/combat telemetry from a .sdfz replay (needs a clean game-end)
  build_order_sim.py   — beam-search opening optimizer; modes incl. max_rate and config-driven
                          `raid` (raid_configs/*.json: unit milestones, required/weight)
  blueprint_gen.py     — turns a build_order_sim.py result into a blueprint .lua + layout image;
                          reserves an exit corridor (M.keepout) for ground-unit factories
  OK_BOT/              — original reference bot (Cortex faction)
  DRAGON_BOT/          — current main bot: sim-derived opening + mex-grid scaling
  RAIDER_BOT/          — exploiter: air raid (bombers) on an early timer
  GROUND_RAIDER_BOT/   — exploiter: ground raid (Incisors + fighter escort) on an early timer
    macro_controller.lua
    lab_controller.lua
    unit_controller.lua
  blueprint_placer.lua — shared helper (distributed build orders, mex grid expansion)
  bar_framework/       — shared widgets loaded via VFS.Include (escape_guard, nano_broker, ...)
  blueprints/          — blueprint .lua files + the build_order_sim.py results they came from
  raid_configs/        — build_order_sim.py `raid` mode configs
  knowledge/raid_runs/ — saved exploiter-bot match results and analysis
```
