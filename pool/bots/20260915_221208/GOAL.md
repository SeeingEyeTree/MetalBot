# Candidate 20260915_221208

**Component:** `macro_controller.lua` (task type: `improve_component`, baseline: `baseline_001`)

## Goal

Target the known weakness in `knowledge/game_mechanics.md` §10 / `knowledge/lessons_learned.md`
bullet #1: "the opening doesn't scale as aggressively as it should." In the stock
`com_starter.lua` blueprint, the air lab (`corap`) is item #27 of 46 in the commander's
serial build queue. Since the commander only has its own ~300 BP and builds this queue
completely alone, the air lab doesn't even start construction until roughly 26 other
items have finished. That matters a lot here because the air lab is what unlocks air
cons, and air cons are what drive this bot's entire automated mex-grid expansion engine
(`StartAirExpansion`/`TryExpand` in `macro_controller.lua`) — so the bot's real
eco-scaling machinery sits completely idle for the first several minutes of the game
waiting behind a long tail of hand-placed mexes and winds.

## Change

Added a `BuildOrderedComLayout()` helper in `macro_controller.lua` that takes a copy of
the shared `COM_STARTER.layout` blueprint data and moves the `corap` (air lab) entry to
immediately follow the `corlab` (bot lab) entry, instead of leaving it wherever it sits
in the raw data. `QueueComBlueprint` now iterates this reordered copy instead of the raw
layout. The shared `blueprints/general/com_starter.lua` file itself is untouched, so
`baseline_001` (and any other bot using the shared blueprint) is unaffected — this is a
candidate-local behavior change only. Everything else about the commander's queue
(all 46 items, positions, blueprint content) is unchanged; only the air lab's position
in the build order moves.

This was informed by `build_order_sim.py`'s balanced-mode optimal build order, which
independently favors unlocking BP-generating infrastructure (labs) early rather than
exhausting a flat list of mex/wind actions serially before infrastructure comes online.

## Expected effect

Expect the automated mex-grid expansion (air cons placing `MEX_GRID_BP` tiles) and energy
grid expansion to start noticeably earlier in wall-clock/game time, since it no longer
waits behind ~26 queue items. Success would show up as: higher metal income at the 5 and
10 minute checkpoints relative to baseline, and mex-grid states in `gridStates`/`eGridStates`
appearing earlier. Risk: moving the air lab earlier delays a few of the commander's own
mex/wind items by a small amount, so if the air-lab's own construction cost is large
relative to commander BP, there's a chance of a short-term metal/energy dip before the
expansion engine's parallel BP more than compensates — this is exactly what the match
result should reveal.
