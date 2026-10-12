# LINE_CLICK_v17

LINE_CLICK_v16 + (2026-10-09, from the user's three games against people; log of the paintkid game pulled from TreeServer):

What the paintkid log showed (bot = team 1, 10:30 game-time, the user resigned -- the commander death was not a bot failure):
- The bot out-earned paintkid ~2.8x at 10:00 (500 vs 180 M/s) but its army was ~23 units / 1.5-2.5k value all game.
- Metal sat at the 5k storage cap from ~8:00 (`float_m` 0.93-1.0) and energy was 50-70% full, while the vehicle plants made ~23 units.
- The spine had `capacity=0 (standing 0)` until 10:04: T1 cell nanos 4 (24 held back), the T2 labs waited for ground army value >= lab
  cost (2670 >= 2600, reached at 10:00 -- a chicken-and-egg gate), T2 cells opened only at 9:04 and 9:50, "mex grids ready" at 10:22.
- Only 16 eco units were lost all game; the damage was 56 army units to Pawns (Armada armpw). So this was an unspent bank, not rebuilding.

Changes:
1. **Float release** (`bar_framework/spine.lua`, `FLOAT_*`, switched on by `SPINE_CFG` in macro_controller): when metal AND energy are both
   above 25% of storage for 5 s, every spine restriction comes off -- share 1, every held lab released (no army-value / delay gate), every
   held nano built ahead of need (also in cells with no lab yet, and in the T1 cell), nanos kept active instead of parked, the next cell
   opens without waiting for the T1 labs and at a 1.5x margin. Clears when either resource falls under 12%. Economy still decides where
   eco goes when it is the limit. Log rows: `[SPINE] FLOAT on/off`, ` FLOATING` on the status line, `lab ... released (metal and energy floating)`.
2. **Dragon sink** (`lab_controller`, `DRAGON_FLOAT_*`): an idle T2 air lab adds one Dragon (`corcrwh`) while the bank is >= 50% of storage
   and >= 1500, after the guard force is full. Idle-lab-only, so they are added as needed and never queued together.

   "Floating" = metal >= 50% of storage and >= max(1000, 20 s of income), energy >= 40% of storage, not before 5:00, held 5 s; clears
   under 12%. (First try, 25% of storage from the start, fired at 3:59 on 57 M/s income, opened a T2 cell and cost the eco: v17 slot 1
   0.33x. Do not loosen it.)

Tested (single mode, 3k cap, 20 min, v17 vs v16): slot 0 1.62x (win), slot 1 0.95x (draw) -- no difference demonstrated. Zero sync / Lua
errors. In a mirror the float rule rarely fires (first at ~18:00, Dragons from 17:54-18:26), so the mirror cannot show the paintkid fix;
that needs a scenario where the spine lags (an opponent that is outproduced early, or the nano-kill fixture) -- still to do.

Not done (by the user's choice): no stop to new eco near the unit cap; no rebuild ledger (the log did not show nanos being lost).
