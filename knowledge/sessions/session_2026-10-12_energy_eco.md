# STANCE_BOT eco session (2026-10-12, evening): what was tried, what worked

Goal: STANCE_BOT's late economy. Start of session (vacuum game, 20 min, vs INACTIVE_BOT): metal income ~2.4k at 20:00 but pull only 250-360 (metal floated),
energy income collapsed 20k -> 8-11k from ~16:00, ~450k metal spent by 20:00. Now: income 3.9-4.7k, pull 3.0-3.6k, energy income 57-66k, ~1.2M spent
(3 games each, `runs_stance/ab1_summary.txt`). Numbers are interval averages (`*_avg`); the minute-mark `metal_inc` is a noisy sample.

## Worked (all behind LT.CFG flags; STANCE_BOT's `cfg = {...}` in macro_controller.lua turns them on)
- **Energy priority during wind consolidation** (`FUSION_HELPERS`, `ENERGY_PRIORITY`, `EP_INFLIGHT` 6, `EP_CON_BATCH` 4 / `EP_CON_EVERY` 450). Root cause of "no
  fusions when consolidation starts": `UpdateEnergyPush` returned early once `consolidateOn`, so `epBound` was never set, `TryAssignUpgrades` kept no T2 cons
  back and every free T2 con went to metal retrofits. Now epBound is computed during consolidation (also true when energy income < 0.9 x its peak), consolidation
  forces `corfus`, asks a lab for T2 cons, keeps `CONSOL_FUSION_CONS` T2 cons back from retrofits. Every available air con guards a fusion job's builder (closest
  job), taken from the free pool, the grid helpers or idle crew cons; nanos in reach guard the builder at the new top broker priority `NANO.PRIO.ENERGY`.
  This was the biggest single step: `oldfusion` (without it) 2629 income / 0.74M spent vs 4-4.7k / 1.1-1.2M (ab1).
- **Energy storage**: `slot_spine` NanoBlock gets rows of 4 `corestor` in the gaps between blocks (pitch 272, shared rows, held until
  `STORE_SECONDS` 5 x energy income is missing). Bank signal now means something (100k storage at 20:00).
- **Nano crew** (`NANO_CREW`): after 6 grids open, 4 air cons (recruited ahead of new grids) work as a group, all on one nano of one grid then the next, to bring
  grids to 2 nanos. First idle check bug: `GetUnitCommands(id, 0)` reads as idle in single mode, use `(id, 1)` like the placer.
- **Stance swap** (`strategy_hooks.cap_switch`): to `Late_game` (Demon/Juggernaut/Dragon) when the unit cap is 75% full and past 12 min.
- **Idle cons help**: grid helpers on any unfinished grid (`HELP_ANY`), T2 cons helping fusions can be pulled back for a retrofit.
- **Retrofit changes** (`RETROFIT_MEX_DONE`, `UPGRADE_CONS_PER_LAB` 4, `RETROFIT_FLOAT_CONS` with no float condition and front-of-queue orders): grids are retrofit-eligible
  once their mexes stand, more T2 cons. Effect not separable from noise in ab1 (`noretro` is as good); T2 mex share stays ~35-40% at 20:00.
- `AUDIT_EVERY` log rows: `[AUDIT]` per grid box counts (nanos by bucket, T2 mex %, fusions, fully-upgraded grids, T2 cons alive/free, retrofits running).

## Tried and removed / not kept
- **GRID_CAP_RESERVE** (count all 73 blueprint items against the cap): blocked grids from ~7:30 on, ramp slower. Replaced by `GRID_UNITS` 32 x grids <= `GRID_CAP_FRAC` 0.60 of cap
  (a soft ceiling; ~56 grids on a 3000 cap; the bot opens ~56-62 grids by 11:00 otherwise).
- **GRIDS_BUILDING_MAX** (limit on unfinished grids, even counting only grids with mexes left): froze the economy (income 1.5-2.1k at 20:00). Removed from code.
- **Fixed 4-con crew vs demand-based** (1 crew per 5 short grids, max 8): no better; fixed 4 kept (`NANO_CREW_GRIDS = false`).
- **NANO_CREW_FULL 12 + NANO_CREW_SIZE_FULL 16** (crew grows once all grids are open, groups of 4, tier 2 to 12 nanos): nano coverage improved
  (20 grids with all 12 at 20:00) but retrofits/fusions starved (T2 mex 8%, income 2.6k in one game; ab1 `full` slightly lowest spend). Off in STANCE_BOT.
  Idea left: release the crew once the first retrofits begin (~13-14 min).

## Open items
- 12-16 min ramp barely moved; T2 mex share ~37% and ~0-9% of grids fully upgraded at 20:00. First T2 air lab finishes ~10:29, so T2 cons start ~11:00; ~50 retrofits
  run at once from 16:00 (half-finished grids). Try `EARLY_CAPSTONES` and limiting concurrent retrofits.
- Grids open far ahead of their nanos (30+ grids with 0 nanos at 10:00).
- Audit's "fully upgraded" = 18 T2 mexes + 4 fusions (upgrade blueprint); the in-between spots (user: fusion or mex) are not counted yet.
- Variance between identical runs: `knowledge/sessions/variance_notes_2026-10-12.md`. Repeated-game tool: `python runs_stance/ab_variants.py TAG GAMES PARALLEL [variant...]`.
- Numbers to remember: T1 mex 2.37 m/s, T2 mex 9.48 m/s (`knowledge/economy_numbers.md`); Dragon 14.1 E per metal.
- Tests: `tests/test_slot_spine.lua` (51), `test_strategy` (36), `test_behavior_host` (29), `test_line_crew` (300) pass; `line_transition.lua` has no unit test (checked by vacuum games).
