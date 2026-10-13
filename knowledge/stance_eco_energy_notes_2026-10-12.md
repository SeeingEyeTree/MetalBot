# STANCE_BOT eco / energy notes (2026-10-12)

Goal: STANCE_BOT scales its economy like v16 and spends all of it in a vacuum game. **Status: scaling matches v16; late metal
float remains and is energy-bound. That is the open problem.** Nothing here is committed.

## The open problem

From about 16:00 of a vacuum game metal sits at 100% of storage while spending is only 30-45% of income, and the energy bank is
low. Typical rows (STANCE_BOT, 20-min vacuum, army self-destructing):

| min | metal inc | metal pull | energy inc | energy pull | metal bank | energy bank | factories busy |
|---|---|---|---|---|---|---|---|
| 12 | 700-1000 | 600-900 | 10-14k | 8-11k | 10-40% | 72-90% | 3-9 |
| 14 | 1050-1360 | 800-1100 | 17-21k | 11-16k | 85-100% | 75-95% | 4-14 |
| 16 | 1700-2800 | 800-1700 | 16-24k | 16-25k | 100% | 63-95% | 12-24 |
| 18 | 1900-3000 | 600-1160 | 12-17k | 12-17k | 100% | 27-60% | 25-31 |
| 20 | 2100-2900 | 650-840 | 10-14k | 10-14k | 100% | 19-43% | 30-37 |

- Energy pull = energy income from ~16:00, so energy is fully used and caps spending. Army units cost ~15 E per metal; the
  energy:metal income ratio falls from ~15 at 14:00 to ~5-6 at 20:00.
- Energy income *falls* after 14:00 (21k to 10-13k). Cause not confirmed: wind output varies, and `corwin` blocks are consolidated /
  reclaimed into fusions (the consolidation reclaims the winds first), and the unit cap logic stops wind building at 80% (see below).
- v16 shows the same pattern, worse (spend 330 of 3300 at 20:00, energy bank 7-13%). So this is a shared framework problem, not
  only a STANCE_BOT one.
- At 14:00 both banks are full (metal 100%, energy 80-95%) and spending is still only ~65-75% of income: a short capacity
  problem (labs/nanos not yet built for the income jump that follows the T2 mex retrofits at ~14-16 min).

## What is known about the energy machinery (`bar_framework/line_transition.lua`)

- `EnergyBound(T, frame, res)`: "energy binds" = metal floating (>=30% of storage and >=3000) AND (bank < 50% of storage, or the
  new `EP_BANK_SECONDS`) AND pull >= 85% of income. Fractions of storage mean nothing at this scale: 50% of a 58k store is 2 s of a
  15k E/s pull. Added options (default off): `EP_BANK_SECONDS` (bank under N seconds of pull) and `EP_RATIO` (energy income under
  N x metal income, once metal income >= `EP_RATIO_MIN_INCOME`; no float test).
- `UpdateEnergyPush`: wind 2x2 blocks -> corfus by a free T2 con, `EP_INFLIGHT` jobs at once. Low yield (one fusion per block).
- `UpdateEnergyCells`: a lattice cell = 12 nanos + 16 fusions (`blueprints/general/energy_cell.lua`), `ECELL_MAX_ACTIVE` at once,
  `ECELL_TOTAL` 8. Needs a **free T2 con that can build corfus** (`T.freeT2Cons`). By default it defers to wind consolidation
  first (`ECELL_FIRST=true` skips that).
- T2 cons come from advanced air labs. The only maker was `UpdateEnergyPush`, and only from a lab with an **empty queue**;
  STANCE_BOT's lab controller keeps those queues full, so no con was ever made. Now `MakeEnergyT2Con` (used by push and, with
  `ECELL_MAKE_CON`, by cells) inserts one at the front of the queue (`EP_CON_FORCE`). 28 T2 air cons (coraca) were built in a
  game, most go to grid retrofits (`TryAssignUpgrades` keeps only `keep` cons free for the energy jobs).
- STANCE_BOT's settings (macro_controller `LT.New{ cfg = {...} }`): `EP_BANK_SECONDS=20, EP_RATIO=15, EP_INFLIGHT=2,
  ECELL_MAX_ACTIVE=3, ECELL_FIRST=true, EP_CON_BATCH=2, EP_CON_EVERY=900, EP_CON_FORCE=true, ECELL_MAKE_CON=true`.
- Effect so far: the first energy cell starts ~13:50 (was 18:08, before these options) but a cell takes **~4.5 minutes** to
  finish (cell jobs stays at 1 from 13:50 to 18:30; wind jobs grow to 8-13 at the same time). The 2nd/3rd cells then start together at ~18:30.
  No clear improvement in late spending yet: the energy that matters has to exist by ~15:00.
- Debug lines now logged every minute while a cell is wanted: `[LT] ecell wanted: free T2 cons N, cell jobs N, wind jobs N, started N`
  and `ecell: free con ... cannot build corfus`. Remove them when done.

## Ideas not tried yet (rough order)

1. **Build energy before the metal jump, not after.** At 12:00 the ratio is ~13-15 and fine; the metal income doubles at 14-16 min
   (mex retrofits) and the energy never follows. Start cells at ~11-12 min when energy income < 15 x *projected* metal income
   (grid count / retrofit count is a proxy), so they finish by ~15:00.
2. **Cell build speed.** Check what builds the cell: one T2 air con plus the cell's own nanos (the blueprint builds nanos first).
   Give it more con BP (2-3 T2 cons per cell via `BUILDERS`/hand-off, `st.handoffProgress = C.GRID_HANDOFF`), or put the 12 nanos
   last. Also check whether the cell is energy-starved while building (fusions cost energy and the bank is low).
3. **Wind consolidation competes for the same cons** (wind jobs 8-13 at once while the cell waits). With `ECELL_FIRST`,
   `UpdateEnergyPush` still takes the free cons first. Skip consolidation while a cell is wanted and `ecellStarted < ECELL_TOTAL`.
4. **Why energy income falls 14:00 -> 20:00.** Count winds/fusions over time (`[LT] consolidating ...` lines; tracker `energy_inc`).
   If consolidation reclaims winds before the fusion stands, start the fusion first (or only consolidate when a con is idle).
5. **Unit cap logic** (`[LT] ... unit cap tight (2402/3000): grids stop building wind, consolidation on`): 80% of the cap
   (`CAP_SLACK_FRAC 0.20`) switches off wind building and marks grids for retrofit. Total units plateau at ~2400 in every
   run, so the bot stops adding buildings (winds are the cheapest energy) at 16 min. Worth testing a higher fraction in a vacuum.
6. **Spend-side alternatives while energy-bound:** build energy-cheap units (the stance mix is cordemon 50% / correap 12% / ...),
   or reclaim/idle less. The Dragon-on-float rule needs both banks >= 60% so it does not fire when energy is short.
7. Compare with the old LINE_CLICK_v13d/v14 mirror notes (`knowledge/overnight_2026-10-08.md`): the ENERGY PUSH was added there
   for the same symptom (metal at its cap, energy at 93% of income).

## Other things found this session (all in the working tree)

- `strategy_hooks.match_enemy`: threat sightings no longer lift the share (with the slot spine a share of 1 sizes nanos for all
  income and starved the mex grids); shortfall measured in seconds of income (`horizon` 60); ahead of the target by `lead` 1.5 the
  share is `ahead_floor` 0.05; both banks >= 90% -> 1.0. `[SHARE]` log row every 10 s.
- `lab_controller.lua` ARMY BUDGET: the share was only an on/off gate for the labs. Now a token bucket (income x share, 20 s
  cap) limits stance picks; metal bank >= 50% lifts it; defence floor / rush / guard picks are not limited. Dragons (`corcrwh`) in
  non-spine labs while both banks >= 60% (off at 35%).
- `slot_spine.lua`: `BUILD_AHEAD_INCOME` 500 (no nano build-ahead below it; default 500 for every slot-spine bot), `FLOAT_MULT`
  (default 1, STANCE_BOT 2.5) and `MAX_JOBS_FLOAT` 6 while both banks float, lab-to-slot match widened to 200 elmos for the lab
  the slot is waiting for, "matches no slot" log. Slot 4's `corvp` still never logs "stands" (cause unknown; the gantry takes ~2.5 min).
- `game_state.Collect{ MB = WG.MetalBot }`: in `--server single` the framework modules do not see the widgets' `WG`, so
  `state.threats/intel/armyValue` were empty. STANCE_BOT passes it. **PAINTKID_BOT and PK_BASE do not yet** (`GS.Collect` in their
  macro_controller).
- Harness: `METALBOT_DEATHMODE` (env) is read by `bot_testing.py` and `single_client.py`; `none` did **not** stop the early
  game_over, so do not rely on it.
- Grid builders: the two spines use `GroundOnly = true`, so neither takes air cons from the grid pool. The grid-rate gap vs v16
  was mostly the share/lab effects above, plus v16's gator raid killing STANCE_BOT's grid cons from ~9:20 (13 lost by 10:00)
  in bot-vs-bot games (not a vacuum effect).

## How to run the vacuum test

```powershell
# 1. copy the bot and append the self-destruct widget code to its lab_controller
Copy-Item -Recurse candidates\STANCE_BOT candidates\_VS_STANCE_BOT
Get-Content <snippet> | Add-Content candidates\_VS_STANCE_BOT\lab_controller.lua
python bot_testing.py --bot1 candidates/_VS_STANCE_BOT --bot2 INACTIVE_BOT --server single --end-minutes 20 --duration 3000 --save-result runs_stance/x.json
python runs_stance/vac_report.py x          # per-2-minute income / pull / banks / factories
```

The snippet (add at the end of lab_controller.lua): armed mobile non-builder units get `CMD.SELFD` (65) 1350 frames after
`UnitFinished`, using `widget.UnitFinished` / `widget.GameFrame` wrappers. Without it the bots kill the INACTIVE_BOT commander at
~9-12 min and the match ends; an early return in the unit controller leaves the army value stale (the share hook then reads
a wrong value). Delete the copy afterwards (`candidates/_*`). Run-to-run variation is large (energy cell timing moved by 1-5 min
between identical runs), so repeat a change at least twice before judging it.

## Files touched (uncommitted)

`bar_framework/`: `line_transition.lua`, `slot_spine.lua`, `strategy_hooks.lua`, `game_state.lua`;
`candidates/STANCE_BOT/`: `macro_controller.lua`, `lab_controller.lua`, `unit_controller.lua` (publishes `mb.armyValue`);
`tests/test_strategy.lua`, `tests/test_slot_spine.lua`; `single_client.py`, `bot_testing.py`; `runs_stance/vac_report.py`; `CLAUDE.md`.
Tests: `python tests/run_lua.py tests/test_strategy.lua` (36), `test_slot_spine` (47); the others still pass.
