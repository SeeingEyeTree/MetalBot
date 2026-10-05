# SPINE_BOT

DRAGON_BOT with the army/eco nano balancer removed and unit production moved into a **spine**.
Code: `bar_framework/spine.lua` (all logic and tunables), hooks in `macro_controller.lua` and
`lab_controller.lua`, blueprints `blueprints/general/T1Spine|T2Spine|T3Spine.lua`.
Test: `lua5.1 tests/test_spine.lua` (about 5 minutes; stub only, it cannot say whether the bot plays well).
Not yet run in a real match.

## What it does
- When the air lab finishes, a **T1 spine** goes up on the enemy-facing side of the base (the enemy is
  assumed at the point mirror of our start). The whole stack of cells and the lane beside each cell
  (the cell on the enemy side, where units walk out) is reserved so mex grids never grow over them.
- T1 labs (bot + vehicle) make a few hard-coded cons. Those cons place the **T2 spines** (T2 bot lab +
  T2 vehicle plant); T2 cons, asked for on demand, place the **T3** gantry.
- **A new cell opens when capacity < current metal income.** Capacity = what the assigned T2/T3 cells
  could spend at a theoretical 100% unit spend (each lab sized with a reference unit: Mammoth corsumo,
  Tiger correap, Demon cordemon; nanos counted toward the lab they reach; lab absorb limit
  buildTime/2.5). It does not depend on what is being spent now: cells have a long lead time, so they
  stay ahead of the economy. T2+ cells open from 3:00, at most 2 under construction.
- **army_share** (fraction of income spent on units) comes from the ordered list `SPINE.policies`:
  0 until 5:00, then a 20% floor; 100% under unit-cap pressure. Add logic with `SPINE.AddPolicy`.
  share x income -> fraction of capacity -> that fraction of each lab's nanos guard it, the rest are
  parked (`NANO.Park`, a queued WAIT). Whole nanos, 6 moves per tick.
- Labs in the spine are run by the spine through `lab_controller` (`WG.Spine`): queue kept 3 deep, cons
  first, then the lab's reference unit while share > 0.

## Things to check in the first real match
- **Lab facing.** Facing is set in code (`item.f = geo.facing`, 0 = south ... 3 = west), not from the
  blueprint, because the placer rotates `f` the opposite way to the offsets. Confirm with the tracker's
  `fac_exit_ok` / `fac_boxed` that units get out. Blueprint labs were changed to f=1 (east) so the editor
  shows them pointing at the open side.
- **Parking.** `[SPINE]` log lines print `PARK-LEAK=n` if a parked nano is still building. If the WAIT
  trick does not stop auto-assist, try ONOFF or throttle the labs' queues instead (`SPINE.CFG.PARK_NANOS`).
- Whether a 30x30 cell leaves room for the largest unit to leave the lab.
- Tracker fields to watch: `fac_bp_useful`, `nano_idle_bp`, stall/float fractions, `fac_exit_ok`.

## Known simplifications
- Cell kind order is `PLAN = {T1, T2, T2}` then T3. `T1_CONS` and `LAB_UNITS` are hard-coded tables.
- Lab queues take only the reference unit, not a doctrine mix.
- The defense interrupt is untouched. The unit controller is unchanged from DRAGON_BOT.
