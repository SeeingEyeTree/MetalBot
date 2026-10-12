# Brief: port the spine into LINE_BOT

> **Status 2026-10-07: ported (stub-tested, not yet measured in a real match / A/B).** Design differs from the table
> below in one respect: instead of a block cell, the spine hangs off a **vehicle lab on the line** and a cell of the grid
> lattice - see `GOAL.md` ("Spine / vehicle lab"). Remaining "Done when" items: a real match and an A/B of
> `LINE_BOT` vs `candidates/LINE_NOSPINE` (`python ab_test.py --bot-a LINE_BOT --bot-b candidates/LINE_NOSPINE`).

**Goal.** LINE_BOT (see `GOAL.md`) scales its economy well but has no army, so late in a match metal and energy sit
at the storage cap with factories idle. Port TILE_BOT's spine (SPINE_BOT's unit production) so the surplus becomes
army. Do this last; everything else from TILE_BOT's late game is already in.

**Read first:** `LINE_BOT/GOAL.md` (what exists, lessons), `bar_framework/line_transition.lua` (the integration
point), and in `TILE_BOT/macro_controller.lua` search for `SPINE` / `StartSpine` / `SpineTakeCon` /
`SpineReturnCon` / `SpineBase` / `SpineMexGridsReady` / `SpineThreat` / `SpineCapPressure`. The spine itself is
`bar_framework/spine.lua` (do not rewrite it; adapt the host).

## What the spine needs from its host (`SPINE.Init{...}` in TILE_BOT)

`BP_PLACER`, `NANO` (= `BP_PLACER.NANO`), `blueprints` (`SPINE_BPS`: kind -> blueprint; T1/T2/T3 spine files in
`blueprints/general`, loaded with the same pcall pattern as TILE_BOT's `Initialize`), `baseX/baseZ/mapX/mapZ`, and
callbacks `AnchorKey`, `Reserve(key)`, `TakeCon(defID, t1Only)`, `ReturnCon(uid)`, `QueueAirCon`, `DeferStop(uid)`,
`CapPressure()`, `Threat()`, `MexGridsReady()`, `GroundArmyValue`. Then `WG.Spine = SPINE` and
`SPINE.Start(frame)`.

Per-frame/event hooks to forward: `SPINE.Update(frame, res)`, `OnUnitCreated`, `OnUnitFinished(uid, defID, x, z)`,
`OnUnitFromFactory`, `OnUnitDestroyed`, and `SPINE.OfferCon(uid)` for a new T1 air con when no grid is waiting.
`SPINE.EnergyShort(res)` is also used by TILE_BOT's grid energy interrupt (LINE_BOT uses the plain
`GRID_INTERRUPTS`; port TILE_BOT's `GridInterrupts`/`EnergyLookahead` if the spine needs it).

## Mapping onto LINE_BOT (the hard part is geometry, not wiring)

| Spine host need | TILE_BOT | LINE_BOT today |
|---|---|---|
| base cell | a cell of the 2x2 tile block whose 4-cell stack + exit lanes land outside the block, nearest the enemy (`SpineBase`) | **no block.** The line is 1024 x 752 elmos in a rotated frame (`T.lineBox`, `LT.InsideLine`). The spine stacks cells one grid cell in front of its base toward the enemy and sideways; choose a base cell so the whole stack and lanes miss the line and the first grid. Likely the grid cell on the enemy-facing side of the line. |
| `Reserve(key)` | `assignedAnchors[key] = true` | `T.assigned[key] = true` |
| con pool | `freeAirCons`, `freeT2Cons` | `T.freeAirCons`, `T.freeT2Cons` (note `TryAssignGrids(T, frame)` / `TryAssignUpgrades(T)` after returning one) |
| `QueueAirCon` | file-local | local to `line_transition.lua`: export it |
| `DeferStop` | `pendingStops` entry `{unitID, fireFrame}` | `T.pendingStops` entry is `{id, fire}` - different field names |
| cap pressure / threat | `SpineCapPressure`, `SpineThreat` (reads `WG.MetalBot`) | not present; port both |
| unit production | TILE_BOT's `lab_controller.lua` / `unit_controller.lua` (SPINE_BOT's, origin/main) | **both LINE_BOT files are no-ops**; copy TILE_BOT's, they read `WG.Spine` |

Other things the spine changes in TILE_BOT that LINE_BOT must match:
- The T1 vehicle-plant path is **off while the spine is loaded** (`MaybeQueueVehicleLab`); LINE_BOT has none.
- Start the spine **before** seeding mex-grid cells (it reserves its cells and exit lanes first). In LINE_BOT that
  means in `OnJobDone` for the lab, before `OpenFirstGrid`, or at the latest before the first `Collect`.
- `SPINE.OfferCon` takes the new air con only when `#pendingGrids == 0`; grids keep priority.
- The macro file is near Lua 5.1 limits in TILE_BOT (200 locals, 60 upvalues). `LINE_BOT/macro_controller.lua` is
  small and `line_transition.lua` keeps state in one table `T`, so put the glue in `line_transition.lua`, not in new
  file-level locals.

## Done when

1. `tests/test_line_crew.lua` still passes (it checks the opening, lab, nanos, first grid, retrofits,
   consolidation, energy storage) plus new checks: spine started, its cells reserved and not on the line.
2. A real match with `--bot1 LINE_BOT` shows `[LT]`/spine logs, army value > 0, and the economy curve in
   `GOAL.md` ("Measured") **not worse** through ~12:00. The spine competes for air cons and nanos, which is exactly
   what cost TILE_BOT grid growth before (see its air-con reserve comment), so check grid waits (`waited N s for a con`).
3. A/B it with `ab_test.py` against the pre-spine LINE_BOT (both slot orders). Army value at frame 14400 is the metric.
   Detectable effect is ~15-20%; `NO DIFFERENCE DEMONSTRATED` is a normal outcome.

**Deploy with `.\deploy.ps1 -Bot LINE_BOT`** (the default bot is DRAGON_BOT).
