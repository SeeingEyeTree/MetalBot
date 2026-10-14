# eco_sim: the fast economy simulator (2026-10-14)

`eco_sim.py` + `ecosim/` run a bot folder's **real** `macro_controller.lua`, `lab_controller.lua` and `unit_controller.lua` (plus
the vacuum self-destruct snippet, `runs_stance/vac_snippet.lua`) against a simulated engine under LuaJIT.  A 20-minute vacuum game takes
~20-30 s on one core; `--jobs 7` runs ~80 games in ~5 min.  Any change to line_transition / presets / framework code is tested exactly as
it would ship.  The point is to RANK eco ideas quickly; a real vacuum game is still the verdict.

## Commands

```
python eco_sim.py run --tag x [--seeds 1-6] [--set line_transition.KEY=VALUE] [--preset line_transition:+GROUP,-GROUP] [--phys KEY=V]
python eco_sim.py sweep ecosim/sweeps/<spec>.json [--calibrate "runs_stance/simcal_*.json"]   # variants x seeds, ranked
python eco_sim.py report ecosim/runs/<tag>/run.json      # per-2-min: income/bank/counts, BP ledger, bottleneck label; grids; spend
python eco_sim.py compare ecosim/runs/<A> ecosim/runs/<B>  # per-window medians A>B (variant dirs = seed medians) -- the "why"
python eco_sim.py calibrate runs_stance/simcal_STANCE_BOT_*.json --sim ecosim/runs/<tag>/s*/run.json   # vs real [SNAP] dumps
python eco_sim.py defs <real result json>                # regenerate ecosim/unitdefs.lua from the engine's own UnitDefs
python eco_sim.py run --trace <unitID ...>               # [TRACE] every order / command pop of those units in log.txt
```
Each run writes `ecosim/runs/<tag>/run.json` (timeline every 10 s, unit snapshots every minute, events, the bot's whole echo log,
Lua errors, missing-API list, `blocked_by`) and `log.txt`.  Tests: `python tests/test_ecosim.py` (physics checks).

## What the sim models (ecosim/world.lua; constants with sources in ecosim/physics.lua)

- Engine UnitDefs/WeaponDefs dumped from a real game (`metalbot_state_dump.lua`, now installed by the harness in both modes; its
  `[UDEF]/[UMAP]/[SNAP]` rows land in `result["state_dump"]`, the bot's `[LT]/[CB]/...` rows in `result["bot_echo"]`).
- Footprints + occupancy (8-elmo squares), engine `Pos2BuildPos`, `TestBuildOrder` 0/2, unit cap 3000.
- Orders with lag (20 frames +-6, monotonic per unit), STOP/build/MOVE/GUARD/REPAIR/RECLAIM/FIGHT/INSERT/REMOVE/ONOFF/SELFD/STOCKPILE,
  factory queues (shift x5, ctrl x20, alt front, INSERT).
- Reach: 2D distance <= buildDistance + half the target's larger footprint side.  Mobile builders fly/drive straight, lose 15 frames
  starting and 15 arriving (calibrated).
- Build: buildSpeed / buildTime per second, cost drawn pro rata.  Resources follow BAR's Builder Priority gadget (every non-commander
  builder is low priority; each is switched fully on or off in a stable order so the team keeps a margin) -- not proportional sharing.
- Metal: the engine extraction rule (cormex 0.001 x 592.5 x 4 squares = 2.37; cormoho 9.48), mex energy upkeep, BAR's Mex Upgrade
  Reclaimer (a moho goes straight onto a finished mex, which keeps extracting until the moho finishes, then is refunded).
- Energy: wind 25 (FMP constant), energyMake, negative upkeep (solar), energy converters, storage = 500 + units.
- Stock widgets: nanos get FIGHT when created/idle (unit_immobile_builder); static builders with an empty queue or WAIT auto-assist the
  nearest frame in reach ("idle" mode).  Stockpiled missiles (nuke 1500 m / 187.5k E / 180 s, anti-nuke 150 / 7.5k / 90 s).
- Army: real labs build it; armed units self-destruct 45 s after finishing (vacuum rule).  No combat, features, wrecks or pathing.

## Calibration (3 real STANCE_BOT vacuum games, `runs_stance/simcal_STANCE_BOT_*.json`, 20 [SNAP]s each)

Error = mean |ln(sim/real)| over metal income/pull and mex/moho/wind/fusion/nano/con counts at 6-20 min.  Real games differ from each
other by ~0.1-0.25 on the same measure.

| step | error | note |
|---|---|---|
| first run | -- | air lab 2:50 vs 2:54-3:39 real; 2:00 counts identical |
| + moho-on-mex (Mex Upgrade Reclaimer) | 0.215 | mohos were reclaim-then-build |
| + per-unit order sequence (jitter reordered STOP/build: seeds 2/3 stalled 1 min) | | |
| + static auto-assist, move/arrive 15 frames ("idle") | **0.168** | phys1 sweep, 8 variants |
| + stockpiling | 0.172 | |

Known bias (default physics): 10-14 min income ~20-40% above the real mean (T1 build-up too fast), 16-20 min ~equal to slightly low
(base sim 4.0-4.3k vs real 4.2-5.6k at 20:00).  Grid pacing matches (56 grids by ~10 min in both, same nano-threshold timing); retrofits
start at the same time.  Runs are not bit-identical across processes (Lua `pairs` over table keys) -- ~2-5% run-to-run, plus the
seed spread (base: 3.1-5.7k at 20:00 over 8 seeds, like the real games' 4.2-5.6k).

## Tuning log: STANCE_BOT toward 7k m/s at 20:00 (sim medians; seeds in brackets)

| sweep | finding |
|---|---|
| tune1 (20 ideas x 4) | `SILO_GRIDS = {}` 4.4k -> **6.0k**; `CAPSTONE_MAX = 20` -> 5.0k; `AIR_CON_RESERVE = 0` -> **1.0k** (the con broker stops ordering cons: bot bug); T2_UP_FRONT / reserve 5 / crew 32 / afus blocks / EP_RATIO 20 / HELPER_CAP 24: no gain |
| tune2 (12 x 6, with stockpiling) | no silos + CAPSTONE_MAX 15: **7.0k** [6.2-7.4k]; silos moved to grids 40/50 + cap 20: 6.6k; base 4.0k |
| tune3 (12 x 6 around it) | + EP_INFLIGHT 10: 7.5k; CAPSTONE_MAX 10: 7.5k; T2_CONS_PER_GRID 3: 7.2k; afus blocks / GRID_CAP_FRAC 0.7 / RETROFIT_MIN_NANOS 9 / T2_UP_FRONT x6: no gain |
| tune4 (8 x 8) | **no silos, CAPSTONE_MAX 10, EP_INFLIGHT 14: 8.2k [7.0-8.9k]**; cap 10 + inflight 10: 7.9k; silos at 40/50 + cap 10 + inflight 10: 7.1k; base 4.2k [3.1-5.7k] |

How it gets there (`compare tune2/base tune2/nosilo_cap15`): the two silo capstones (grids 6, 12) are the T2 cons' top-priority job
(prio 90) at 12-14 min and cost 2 x 7.7k metal / 82k energy plus 2 x 187.5k energy per missile -- exactly when the T2 switch is energy
bound.  Without them, and with T2 air labs (2.9k m / 28k E each) only on the first 10-15 grids instead of all 56, the energy goes into
fusions (31 vs 12 by 16:00), energy stops binding (bank 100% vs 14% at 18:00), the retrofits run (338 vs 176 mohos at 18:00, 686 vs 288
at 20:00), winds consolidate (44 left vs 520) and idle build power falls from 54% to 27%.  More fusion jobs in flight (EP_INFLIGHT)
lets the energy push absorb the floating metal faster.

Bot issues the sim surfaced (not fixed): a grid at the map edge puts its T2-lab capstone off the map and a T1 con retries it every
10 frames forever; `AIR_CON_RESERVE = 0` stops air-con production; nanos waste ~45% of their BP-seconds guarding/with nothing in reach.

## Real-game confirmation

Real vacuum games (single mode, vs INACTIVE_BOT, 20 min; `runs_stance/<tag>_<bot>_0.json`), 20:00 `metal_inc_avg`:

| bot | config | sim median | real |
|---|---|---|---|
| STANCE_BOT (simcal, 3 games) | as is | 4.0-4.3k | 4248, 5567, 4562 (mean 4.8k) |
| `candidates/STANCE_ECO` (ecoreal) | no silos, CAPSTONE_MAX 15, EP_INFLIGHT 10 | 7.4-7.5k | **5697** (12:00 750, 14:00 1106, 16:00 2335, 18:00 3472) |
| `candidates/STANCE_ECO2` (ecoreal2) | no silos, CAPSTONE_MAX 10, EP_INFLIGHT 14 | 8.2k | **8081** (12:00 848, 14:00 1782, 16:00 2856, 18:00 5020) |

STANCE_ECO2 matched the sim's prediction within 2% (one game; real run-to-run spread ~25%).  Sim vs real for STANCE_ECO: the sim is ~1.3x optimistic at 18-20 min; the clearest gap is the first fusion (real: none by 14:00,
sim: 10) and T2 labs (real 25 at 20:00, sim 38).  Next calibration item: why the real energy push starts later.

## Spending the eco: the Dragon army sink (user, 2026-10-14)

"More eco is only good to spend on units."  `--sink` (physics `SINK`, world.lua "army spending sink") adds magic blocks of 1 coraap +
40 cordecom (12.6k BP) building Dragons (corcrwh 5.1k m / 72k E / 120k BP) on repeat: 535 m/s + 7.6k E/s per block, after a setup of
32.9k m / 548k E; 46 unit slots each.  A block is added while metal stays banked above max(3k, 10% storage) for 20 s, one per 20 s,
from `SINK.start` s.  Each block competes for resources like any other low-priority builder.  Score: metal into Dragons by 20/25 min.

| sweep | finding |
|---|---|
| sink1 (20 min) | Dragons by 20:00 hardly depend on the trigger (230-280k): starting early converts eco sooner but stalls it (income at 20:00 3-5k vs 8k) |
| sink25 (25 min) | **start at 16-17 min** best: 1.45M metal into Dragons by 25:00 (eager default 1.14M, 18:00 1.09M, 20:00 0.45M) |
| sinkeco (6 seeds) | with the sink, CAPSTONE_MAX 6 (1.67M) and RETROFIT_MIN_NANOS 9 (1.62M) looked better than ECO2 (1.33M); EP_RATIO 20 (0.86M) and GRID_CAP_FRAC 0.7 (1.10M) worse |
| sinkeco2 (8 seeds) | **all combos 1.60-1.71M -- within noise of ECO2 (1.60M)**: the eco knobs are on a plateau once the sink runs |

The wall is now the **unit cap**: from ~22:00 every run sits at ~2950-3000 units with 10-13 blocks, metal banks 270-600k and energy
is full while income keeps rising (~9.2k at 24:00).  More Dragons need more BP per unit slot or fewer eco units per m/s (consolidation
earlier), not more eco.  (cornanotct2 is 600 BP per slot vs cordecom's 300, if a nano T2 block can serve a lab.)
