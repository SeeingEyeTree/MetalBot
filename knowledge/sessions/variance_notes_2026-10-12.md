# Run-to-run drift (same bot, different result) -- notes, 2026-10-12

Not investigated in depth; this is a place to start. Data: `runs_stance/ab_variants.py ab1 3 3` (3 vacuum games per variant, summary in `runs_stance/ab1_summary.txt`).

## What the repeats show
Spread (sd) of the same bot across 3 games, at 20:00:

| variant | metal income | total metal spent | sd of spent |
|---|---|---|---|
| full | 3958 +-542 | 1.11M | 8% |
| nofullcrew | 4709 +-1006 | 1.22M | 12% |
| noretro | 4091 +-625 | 1.23M | 15% |
| oldfusion (pre-session fusion rules) | 2629 +-51 | 0.74M | 3.6% |

- The old fusion rules are nearly deterministic (sd 2%); the new systems (fusion helpers stealing cons, energy-priority nanos, mass retrofits) make
  outcomes swing 10-20%. So the drift is **amplified by feedback** in the new eco systems -- a small timing difference early snowballs.
- Within the new variants (full / nofullcrew / noretro) the means differ by less than the spread: n=3 cannot separate them.
- The minute-mark `metal_inc` is noisier still; always compare `*_avg` fields and `metal_used`.

## Candidate sources, cheapest to check first
1. `candidates/STANCE_BOT/lab_controller.lua` ~line 449: `math.random()` in a weighted unit pick (unseeded). Check whether the slot-spine/stance path calls it.
   Seed it (`math.randomseed(1)`) and see if the spread shrinks.
2. **Order timing.** In `--server single` the governor changes game speed with CPU load to hold order round trip near `--target-lag`; commands
   land on different frames in different runs, and 3 games in parallel change that load. Probe: pin `--speed N` and run the same bot twice
   alone vs. next to two others; compare.
3. Iteration order: `pairs()` over tables keyed by tables or sparse unit ids (e.g. `taken[gs]`, `T.helpers`, `T.nanoCrew`) -- the first element can differ
   whenever insertion history differs. Deterministic only if everything before it was identical.
4. Wall-clock reads: none found in `bar_framework/` / STANCE_BOT (`os.clock`, `GetTimer`, `os.time` grep was empty).
5. Early-game ordering: which air con grabs which grid, how many grids open before the first nanos stand (grids opened by 9:00 varied 35-47).

## How to find the first divergence
Run the same bot twice with a pinned speed, then diff `tracker_timeline` rows (30 game-second eco/units rows) and the `[LT]` log lines;
the first row that differs names the system to look at. Keep the vacuum snippet in both so nothing else (enemy) adds noise.
