# Run 20260916_040755 — dynamic production-grid scaling

**Goal:** the bot user flagged directly — production capacity never grows past what
`macro_controller.lua` hard-codes at the start (2 labs from `com_starter`, plus exactly
2 `VechT1_and_BotT2` grids placed once by conBot3/conBot4). Mex and energy grids both
keep expanding for the whole game via `TryExpand`/`TryQueueEGrid`, but nothing ever added
more factories as the economy grew — a real gap, since `game_mechanics.md` §2.5 says a
lab needs roughly proportional support BP, and more mex income with no more labs to spend
it on is exactly the "uncontrolled stall" failure mode described in §1.2.

**Change:** added a new blueprint, `blueprints/general/prod_grid_vp.lua` — the existing
`VechT1_and_BotT2` layout (proven to place correctly) with its `coralab` (T2 bot lab)
entry stripped out, so repeated copies add `corvp` vehicle-plant capacity + supporting
nanos without spawning a duplicate T2 lab every time. Wrote a small Python validator
(checks for exactly one `corrl` anchor, no cell collisions, in-bounds offsets, valid
facings, known unit names) and ran it against the new blueprint plus two existing ones
as a sanity check before wiring it in — no Lua interpreter (`luac5.1`/`luac`) was
available on this machine to also run a bytecode syntax check, so that step was skipped
per the runbook's fallback.

In `macro_controller.lua`, added `TryQueueProdGrid()`, modeled directly on the existing
`TryQueueEGrid()` energy-grid scaler: every `PROD_GRID_MEX_INTERVAL` (3) completed mex
grids, and while metal storage is at least 30% full (so it doesn't commit BP to a new
factory cluster mid-stall), it queues one `prod_grid_vp` placement into the same
`pendingPlacements` queue the energy-grid system already uses to claim mex-expansion
slots — capped at `MAX_DYNAMIC_PROD_GRIDS` (4) total. No changes were needed in
`lab_controller.lua`: it already registers *any* `isFactory` unit in `widget:UnitFinished`
regardless of who built it, and `corvp` is already a key in `LAB_QUEUES`, so new vehicle
plants placed this way start producing units automatically once built.

**Expected effect:** units-built and metal income should keep climbing in the back half
of a long match instead of flattening out once the initial hard-coded production is
saturated — visible as a higher units-built count and higher army metal-value at the 15–20
minute mark relative to baseline_001, without hurting early metal income (the metal-fill
gate defers the first extra grid until there's a comfortable buffer).
