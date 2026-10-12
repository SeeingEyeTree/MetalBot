# SCALE_BOT (2026-10-12)

Pure economy scaling, no army: ECO_V2 (rot 3 / rot 1 start) + `GRID_PLANNER` (bar_framework/eco_planner.lua) + first 2 grids build their
T2 lab early + at most 6 T2 labs (`CAPSTONE_MAX`) + idle T2 labs make extra T2 cons while metal floats (`RETROFIT_FLOAT_CONS`) +
wind blocks become AFUS (3000 E in the same 96x96 as a fusion's 850; `ENERGY_BUILDING = "corafus"`).
It is the config of bench run `t2` (this session).

Bench: `$env:METALBOT_STARTPOS="2400,1904;9888,10384"; python eco_scaling.py run --bot candidates/SCALE_BOT --server single --end-minutes 22 --duration 2700`
(spawn moved ~2.2 grids in from the map edge; the harness override is `METALBOT_STARTPOS`; ECO_V2 itself is in archive/candidates).

NOT stripped down: it still runs on the shared framework (line_transition etc.) with the army parts switched off. A from-scratch
rewrite was not done; the limit work came first (below) to say what a rewrite has to reach.

## The limit (eco_limit_sim.py: fluid model with the real unit numbers, start = bench 4:00 state)
Unit facts (cor, installed BAR): mex 50m/500e/1870bt, 2.2 m/s on this map, upkeep 3e; moho 640m/8100e/14100bt, 4x extraction, upkeep 20e;
wind 43m/175e/1680bt 25e; fusion 3600m/22000e/59000bt 850e; AFUS 9700m/48000e/329200bt 3000e; nano 230m/3200e/5300bt 200 BP;
T2 nano 840m/12800e/21000bt 600 BP; air con 115m/2200e/5200bt 55 BP.  A T1 air con can build coraap; coraca/corack build moho/fus/afus.

Best open-loop schedule (no latency, no spatial limits), minutes to 800 / 1600 / 3200 / 6400 m/s:

| useful build power | 800 | 1600 | 3200 | 6400 |
|---|---|---|---|---|
| 30% | 12.7 | 14.3 | 16.0 | 18.2 |
| 50% | 10.0 | 11.4 | 12.9 | 14.6 |
| 100% | 7.8 | 8.8 | 10.0 | 11.3 |

Ceiling at the 3000 unit cap: ~1500-1800 moho (13-16k m/s) with energy from AFUS/fusion, not a wind farm (25 E per unit slot).
Optimal early game is nano heavy (40-57% of build power on nanos 4:00-7:00).

Real bench (this bot): 800 at 11, 1600 at 13, 3200 at 16, 6400 at ~19.5 min; 20:00 income ~6.4k with ~2900 units.
That is ~5 min behind the 50% row.

## What limits it (bench, 12-20 min)
- Energy: pull == income the whole time, metal pull is only 25-45% of income and 100-260k metal is banked.  Energy pays back in 7 s (wind) /
  16 s (AFUS), so the bank means build power and logistics are the limit, not resources.
- The real bot matches the model until ~10:00 (income ~750).  From 10 to 14 min the model builds T1 mexes ~2.5x faster:
  spatial expansion and grid bootstrap latency, which the fluid model does not have.
- Every grid used to build a 2900m/28000e T2 lab (28 by 20:00): now capped at 6.
- Energy push (wind block -> AFUS): 2 at a time from 10:00 was the throttle, but raising it to 8 in flight made it WORSE
  (w1/w2: energy fell 13k -> 8k; conversions reclaim winds then starve each other for the 48k energy each AFUS needs); 16 in flight was
  as good as 2.  It needs an energy-aware limit, not a bigger one.
- Run-to-run spread at 20:00 is 4.4k-6.4k for near-identical configs: use time-to-milestone and >= 3 replicates.

Results at 20:00 (income m/s, units): t1 fusion 5506/2462; **t2 AFUS 6427/2903**; t3 AFUS + cap slack 5% 4937/2433;
w1 (8 in flight) 4433/2385; w2 (looser trigger) 3987/2386; w3 (16 in flight) 6338/2883.

## Next
1. Energy push that starts a conversion only when the bank can pay its energy (48k) and the grid's nanos stand; start from ~9:00 not 10:00.
2. Grid bootstrap: helper cons for the first 2 nanos (`GRID_HELPERS` exists, untested in this config), wind-first while energy binds.
3. Replace "consolidate at 80% of the unit cap" by a slot budget: winds -> AFUS early so moho can fill the slots.
4. A from-scratch macro if 1-3 do not close the gap.
