# LINE_CLICK_v16

LINE_CLICK_v15 + (2026-10-09, user request: nuke/anti-nuke, bomber alarm, better vision):

- `bar_framework/defense_crew.lua` (macro builds, unit controller fires): anti-nuke `corfmd` from 350 M/s (2nd at 1200, or on seeing an
  enemy silo), silo `corsilo` from 700 M/s (2nd at 1800), stockpiles, idle constructors assist the build, missiles go at the densest
  cluster of enemy build power/eco not covered by an anti-nuke and >=2500 from our base. Log rows `[DC]`.
- Air alarm: unit controller `UpdateAirAlarm` -> `mb.airAlarm` when enemy bombers are within 2800 or closing within 6500. Labs insert fighters
  ahead of queue (`alarm-fighter`, >=6 fighters), macro raises flak (`corflak`/`corrl`) near factories to 6-14. **Not tested** (no good bomber test yet).
- Scouting: `unit_controller` DEPTH grid -- the first 6 picket scouts stay on the contact line, extra scouts (one per 12 M/s above 80, up
  to 24) hold 3 rows of 8 posts, 900 elmos apart, behind the line. Tunables: `DEPTH`.

Tested: 2 mirrors v16 vs v15, 20 min, single mode: 1.32x (slot 0), 0.78x (slot 1) -- no difference demonstrated; no Lua errors; silos done by
~15-18 min, nukes launched at 17:05 / 20:05 (slot 0) and 18:25 / 19:55 (slot 1).

- Silos are now grid CAPSTONES (line_transition SILO_GRIDS = grids 6 and 12 get a corsilo instead of the T2 air lab, built by a free T2 con once the grid's nanos are up). defense_crew only stockpiles/assists/fires them. Test: v16 vs v15 20 min, 1.43x, silo capstone built 11:41, nukes 16:10 and 19:10.

- Shurikens: own standing count (lab_controller SHURI_*): ramps 0 -> 9 from 2:00 to 6:00, then +3 every 3 min (cap 45); built ahead of queue (floor-shuriken). Test: first one at 4:54 (the T1 air lab is up then), 8 ordered by 6:04.
- Wasps: AssignStuns generalised (SPLIT_WASP): damage split, not stun -- need = ceil(CURRENT hp / 900) per target, best value-per-wasp kills first, spare wasps pile onto the top 3. Untested in-engine (no Wasp responded in the 12-min test).
