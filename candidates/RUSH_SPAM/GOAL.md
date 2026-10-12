# RUSH_SPAM - a deliberately dumb "unit test" opponent

Modelled on paintkid's game (replay `2026-10-09_17-52-07-243_Full Metal Plate 1.7`, Armada, beat MetalBot in
~14 min): mex + wind spam, nano turrets, one bot lab and up to 6 vehicle plants on repeat (Pawns/Flashes), and
every unit is sent at the far side of the map. Easy to counter on purpose; it checks that a bot defends against
a constant stream of cheap units and survives an eco-spam player.

- `macro_controller.lua`: commander + con bots take the next task when idle: 3 mex, 3 wind, `corlab`, then wind
  (2.5/mex + 4/factory), `corvp` (one per 12 metal/s income, max 5 beyond the lab), 3 nanos per factory, more mex.
  Metal-everywhere maps (Full Metal Plate): mex go on a sparse lattice.
- `lab_controller.lua`: bot lab makes 6 `corck` then `corak` on repeat; vehicle plants `corgator` on repeat.
- `unit_controller.lua`: every armed mobile unit gets FIGHT to the enemy start (re-sent when idle).
- Cortex only. Lessons while building it: orders take ~30 frames to land (don't re-poll a builder sooner),
  `GetUnitCommands` is 0 for a factory mid-build (use `GetFullBuildQueue`), and BAR's stock widgets give new
  con bots a repair order (treat a builder as busy only while its first command is a build).

Test: `python bot_testing.py --bot1 candidates/RUSH_SPAM --bot2 INACTIVE_BOT --server single --end-minutes 15`
(killed the idle commander at ~9.5 min). Check `[RUSH]` rows for eco counts.
