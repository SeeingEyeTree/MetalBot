# Plan: mediator + fog memory, clean observation state, per-lab stances check, mini scenarios (2026-10-16)

Written after comparing the framework with ARES-SC2 and PySC2/AlphaStar and then reading this repo. Nothing here is built yet.
Ground rules from CLAUDE.md apply: new behaviour is an opt-in framework option (default off); one owner per kind of order;
a refactor must leave `python order_check.py check` identical; run `python tests/run_tests.py` before and after.

## 0. What already exists (so we extend it, not redo it)

| Need | Already in the repo | What is actually missing |
|---|---|---|
| Fog memory | `enemy_intel.lua` (436 lines): records per enemy unit, mobile memory 5 min / position trusted 30 s, buildings 30 min and dropped when the spot is in LOS and empty, `Commander`, `Labs`, `ThreatAt`, `RaidTargets`, `EcoTargets`, `Blobs`, `RadarCovers`, `Facts`, `Summary` | Only some controllers use it (RAID_BOT's `unit_controller` does). Behaviours do not: `behavior_ctx.EnemiesNear` is live-visibility only, so `kite` / `range_kite` forget an enemy that steps into fog for one second. No confidence value, no dead-reckoning, no "when did I last see this place" grid. `enemy_intel` and `threat_map` each scan `GetAllUnits` separately. |
| Mediator | pieces of one: `wg_channels.lua` (typed `WG.*`), `game_state.Collect`, `behavior_ctx.New`, the brokers (nano / army / con / lab) | Three different ways to ask "what is near here" (ctx functions, `WG.MetalBot` fields, direct `EI.*` / `Spring.*`). `click_army` builds its own ctx (`NewArmyHost`), `unit_controller` another. No single object a behaviour or hook asks. |
| Observation state | `game_state.Collect` (economy, army, intel facts, spine, raid fields), `metalbot_stats_tracker.lua` rows every 30 s, `bot_score.py` phi | `game_state` is a table built for hooks, not a stable schema. It has no own-force breakdown by behaviour/role, no per-lab queue state, no fog freshness, no version, and nothing writes it to the log. The tracker has its own, different field set. |
| Roles | stance units carry `behaviors` / `cfg`; `behavior_host` groups units into cohorts | No query "which units are running behaviour X right now, how many, where". |
| Per-lab stances | `strategy.lua` + `stance_loader` (value-deficit pick), `slot_spine.Cover/Counts` (which labs stand), `Strategy:Tick` pushes the comp and share to `slot_spine`, lab controllers call `strat:Pick(canBuild)` per idle lab | No measure of whether the built army matches the stance. That is the "not sure it works yet" part. |
| Scenario testing | `tests/spring_stub.lua` (instant builds, teleporting moves), `tests/test_*.lua` (37 suites, e.g. `test_intercept` with fake ctx), `eco_sim.py` (economy only), `--server single` real-engine runs | Nothing runs a *combat or intel* situation end to end with a pass/fail result, in the stub or in the engine. |

Housekeeping first: `git status` shows 26 modified files whose diffs replace whole files (e.g. `stance_loader.lua` 112 -> 122 lines of
diff for a ~10-line change). That looks like a line-ending change. Commit or normalise it before the work below, otherwise no diff
or `order_check` baseline is readable.

## 1. Order of work and why

1. **Baseline** (S): normalise line endings, commit, `python tests/run_tests.py`, `python order_check.py save`.
2. **Stance conformance check** (S-M): answers "does per-lab stances work" with numbers, and is the first scenario-style test.
3. **Scenario harness, stub tier** (M): gives acceptance tests for everything after it.
4. **Mediator, read side + fog memory** (L): the main change.
5. **Observation schema + `[OBS]` log row** (M): falls out of 4.
6. **Scenario harness, engine tier** (M-L): only after 3-5, for what the stub cannot show.

Steps 2 and 3 come first because they are cheap and produce the pass/fail checks that 4 and 5 are judged by.

## 2. Per-lab stances: find out if it works

What the code does today (read, not run): `Strategy:Tick` (about 1 s) gives `slot_spine` the comp (`UnitList`, shares after the `weights`
hook) and the army share. `slot_spine.Cover` greedily picks labs by covered share per metal until `COVER_FRAC` of the comp is covered,
ignoring units under `MIN_UNIT_SHARE`; `Counts` sizes each lab type from `share * spend / absorb`. Each idle lab calls `strat:Pick`,
which takes, among what that lab can build, the unit furthest below `share * total value built`. A stance switch makes a new ledger
seeded from `armyByDef`, and may change which labs stand.

Things that could make it not work (hypotheses to test, none confirmed):
- The ledger is global but labs differ in throughput, so a saturated lab type under-builds its units and the others do not make it up.
- Units under `MIN_UNIT_SHARE`, or only buildable in a lab the cover plan did not pick, are silently never built.
- On a stance switch, the new ledger only counts existing units that are in the new stance, so the first minutes over-build the new units.
- Lab swaps on a switch cost reclaim time; a switch hook that flips back and forth would thrash (no hysteresis seen).
- `weights` hook output can push a unit's share below the cover threshold, dropping its lab.

Plan:
- **2a. Conformance report.** A script reads `[STRAT]` / `[LB]` / `[SHARE]` rows plus the tracker's army rows and prints, per stance window:
  target share vs realised share per unit (by built value), lab count planned vs standing, per-lab idle fraction, units in the comp that were
  never built, time from stance switch to the first unit of the new comp. Flag a unit more than 30% off its share after the first 3 minutes.
  Put it in `stance_report.py` (same style as `match_summary.py`).
- **2b. Stub test.** `tests/test_stance_conformance.lua`: run `strategy` + `slot_spine` + the lab broker in the stub for 10 game-minutes on two stances
  (`raid_open` -> `hold` and a stance with a small-share unit), assert realised shares within tolerance, assert no comp unit is starved, assert a
  switch does not trigger more than one lab swap per N minutes.
- **2c. Decide from the numbers.** Likely fixes, only if 2a/2b show the problem: per-lab-type ledgers (share of that lab's own spend), a
  starvation bonus in `Pick`, a hysteresis `min_dwell` on `switch`, and a warning row when the cover plan drops a unit. Each as an opt-in
  option on the module, default off.
- Acceptance: `stance_report.py` on the RAID_BOT and STANCE_ECO2 eco_sim runs shows every comp unit within tolerance, or names the cause.

## 3. Mediator (read side first) and fog memory

**Shape.** `bar_framework/world.lua` (name open; "mediator" in ARES terms). One instance per controller, built in `Initialize`, given
`WG`, the modules and `allyID` explicitly (a `VFS.Include`d module does not see the per-team `WG` in `--server single`). It owns the one
per-frame unit scan that `enemy_intel`, `threat_map` and `behavior_ctx` each do today, and exposes read-only queries:

- Enemy, fog-aware: `Enemies(x, z, r, opts)` with `opts.live`, `opts.remembered`, `opts.minConfidence`, `opts.armed`, `opts.channel`;
  records carry `{uid, defID, x, z, vx, vz, lastSeen, confidence, mobile, value, range}`. `Commander()`, `Labs()`, `EcoTargets(n)`,
  `Blobs(r)`, `ThreatAt(x, z, channel)`, `RadarCovers`, `AntiNukeCovers` (thin wrappers over `enemy_intel`).
- Fog: `Freshness(x, z)` = frames since that spot was last in LOS (coarse grid, e.g. 512-elmo cells), `Unseen(zone)`.
- Own forces: `Army()`, `ByBehavior(name)` / `Cohorts()` from `behavior_host`, `Role(uid)`, `ArmyByDef()`.
- Economy and production: `Economy()`, `Spine()`, `Labs()` (queue state from `lab_broker`).
- It is the single thing `game_state.Collect` reads from (so the snapshot and the queries cannot disagree).

**Write side, second and smaller.** A `Request(kind, args)` that forwards to the existing owner, never acting itself: `scout` -> `scout_lanes`,
`want` -> `lab_broker`, `nano` -> `nano_broker`, `army` -> `army_broker`. This keeps "one owner per kind of order".

**Fog memory work (inside `enemy_intel`, exposed through `world`).**
1. Confidence = f(age, mobile/static, last speed). Dead-reckon a mobile record along its last velocity for up to N seconds, then freeze it.
2. Use it in `behavior_ctx.EnemiesNear` behind an option (`REMEMBERED = false` by default) so `kite`, `range_kite`, `intercept` keep reacting to an
   enemy for a few seconds after it leaves sight.
3. The freshness grid (replaces the tracker's zone-only `fresh_*` numbers as the shared source; the tracker can read it).
4. Radar blips with no def: keep as low-confidence records of unknown value, not dropped.
5. One scan: `threat_map` and `enemy_intel` take their enemy list from `world` instead of calling `GetAllUnits`. Identical results is the test
   (there is already `tests/test_threat_map_cache.py` for the pattern).

**Migration order.** (a) build `world` as a facade over today's modules with no behaviour change; (b) switch `behavior_ctx` and `game_state`
onto it; (c) switch `click_army`'s ctx and `dragon_raid`'s `EnemyRecords`; (d) then the new fog options, off by default; (e) turn on in a copy
of RAID_BOT and A/B it (`ab_test.py`, pair slot orders, phi).

Acceptance:
- (a)-(c): `python order_check.py check` identical for STANCE_ECO2, RAID_BOT, DRAGON_ECO, vacuum; `tests/run_tests.py` green.
- Fog options: the fog scenarios in section 5 pass; in a `--server single` run (where truth is available) the share of true enemy value that
  is remembered, and the median position error of remembered mobile units, are logged and better than the old behaviour.

Not planned: replacing `WG.MetalBot`. It stays as the cross-widget channel; `world` reads it.

## 4. Observation state

Goal: one versioned, flat, serialisable description of "what the bot knows right now", useful today for logs, tests and hooks, and a clean
input if RL comes later. Not tied to any learning setup.

- `bar_framework/observation.lua`: `Collect(world, frame) -> obs`, `Schema()`, `Flatten(obs) -> {name = number}`, `VERSION`.
  Start from `game_state` (do not fork it; `game_state.Collect` becomes `observation.Collect` plus the hook-only extras, or the reverse).
- Blocks: `time`; `economy` (metal/energy cur, income, pull, fill, stall/float); `production` (per lab: type, queue length, idle, current want;
  spine status; unit cap fraction); `own` (value and count by channel, by behaviour/role, by stance unit, home guard, commander hp/pos);
  `enemy_known` (value by channel, labs, eco value, anti-nuke, radars, commander last seen age); `fog` (freshness for a few fixed zones,
  explored fraction, believed vs seen value); `threat` (intruder groups, raid record, air alarm); `plan` (stance, share, game plan).
  Keep to numbers and small fixed-length arrays so it flattens cleanly.
- `[OBS]` log row every 30 game-seconds, same cadence as the tracker; a parser in `match_summary.py` / a new `obs_dump.py` turns a log into
  CSV/JSONL. `bot_score.py` keeps reading the tracker for now; add a check that phi inputs agree with `[OBS]`.
- Decision log beside it: `[ACT]` rows for *decisions*, not raw orders: stance switch, share change, target picks (`pick_target`), behaviour
  assignment, lab wants (`[LB]` already), raid responses. Observation + decision pairs are the useful dataset for later imitation or RL.
- Acceptance: schema test (`tests/test_observation.lua`: every field present, numeric, finite on the stub; `Flatten` order is stable);
  a 20-min eco_sim or stub run writes `[OBS]` rows that parse; no change to `order_check`.

## 5. Mini scenarios

Two tiers. Use the stub tier for logic and the engine tier only where physics or real LOS matter.

**Tier 1, stub (`tests/scenarios/`, run by `tests/run_tests.py`).** A tiny runner on top of `tests/spring_stub.lua`: a scenario is a Lua
table `{name, bot_or_modules, setup(S), steps(frame) , timeout, pass(S)}` with helpers to spawn units, hide/reveal enemies (a fake LOS
mask so fog can be tested), advance frames and read the order log. Cheap, deterministic, no engine.
Initial set, each small:
- fog-1: enemy armed unit seen, leaves LOS for 5 s: `kite` keeps backing off with the fog option on, stops with it off (shows the option works).
- fog-2: building seen, then its spot is in LOS and empty: record dropped; building out of LOS: kept 30 min.
- fog-3: mobile enemy not seen for 6 min: forgotten; seen again: new record, confidence resets.
- fog-4: radar-only blip for a known unit: record updated, not duplicated.
- beh-1: `kite` / `range_kite` vs one approaching enemy: distance kept in the band; not against an enemy that outranges us.
- beh-2: `intercept` (extend `test_intercept`): moving raid vs stopped raid.
- beh-3: `squad_retreat` fires at <= 6 units under 60% hp with enemies near, and releases after.
- beh-4: `pick_target`: build power near an enemy lab is always target 1; held 1200 frames.
- stance-1: the conformance test from section 2b.
- stance-2: stance switch mid-game: ledger seeded, labs swapped at most once, queue not emptied.
- mediator-1: the same query asked through `world` and through the old path gives the same answer (migration guard).
- obs-1: schema test.
Pass/fail is printed one line each, like `run_tests.py` does now.

**Tier 2, real engine (`scenario.py` + a `scenario_driver.lua` widget, via `--server single`).** Single mode already runs with cheat and
godmode, so a driver widget can spawn units and read ground truth. To verify before relying on it: whether `give`-style spawning works
for headless widgets in this setup (fallback: spawn through the game's start script or a small gadget). A scenario sets up a few
units each side on a flat area, runs 60-120 game-seconds at the governor's speed, and reads `[BEH]`/`[CK]`/tracker rows and unit
survival from the log. Initial set:
- kite-vs-melee, range_kite-vs-skirmisher: units lost and damage dealt, behaviour on vs off.
- fog memory with real LOS: truth vs remembered (value recall, position error) while an enemy group walks in and out of vision.
- intercept: a raid group heads for an asset; do the responders reach the path first.
- nano relocation: a lab moves and the nanos follow within a time limit (economy-adjacent, from the spine design).
Each scenario runs as an A/B of the behaviour on/off over a few seeds; "no difference demonstrated" is a valid result (as in `ab_test.py`).
Limit the number of parallel engine runs by RAM as CLAUDE.md says (~4 GB each).

## 6. Open questions for you

1. Name and scope of the mediator: is read-side-only first acceptable, with `Request` added once the reads are migrated?
2. Should `[OBS]` replace the tracker's rows over time, or stay a second source that the tracker feeds?
3. For stances: what outcome means "works"? I assumed realised unit shares within about 30% of target after 3 minutes and no starved unit. Change if you want a different bar.
4. Which bot gets the first fog-memory A/B: a copy of RAID_BOT (already uses `enemy_intel`) is my default.
