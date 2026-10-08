# LINE_CLICK_v13 -- user's notes after watching v12 (2026-10-08)

Base: `candidates/LINE_CLICK_v12`. Status per item: TODO / DOING / DONE (+ how it was checked).

1. **Grids stall while floating metal and energy (TODO).** Seen in the 30-min replay game (v12 = team 1): grids stuck
   at 2 from 4:00 to 7:30 with 2 idle air cons and 0 opening; 7 grids from 9:30 to 12:00, 8 until 15:00, 3-4 idle air
   cons the whole time. Something throttles them -- find it (no valid cell? pacing rule? energy gate?).
2. **Spawn / base near the map edge (TODO).** The start is ~850 elmos from the edge, so there is room for about one
   mex grid before the bot must expand sideways. Grids are also forbidden on the enemy-facing side of the line
   (`T.OnEnemySide`), i.e. the map interior. Options: allow grids toward the interior; harness start positions
   further in (StartPosType 3) for tests.
3. **Lean harder into exponential income (TODO).** Reference: bots reach ~7k m/s by 19:00 with full eco spend; with an
   army spend aim for 2-4k m/s by 19:00 (v12 had ~660 m/s at 20:00).
4. **Army floor 10% (was 20%) and more responsive production (TODO).** spine `FLOOR`; faster nano switching when
   army spend has to rise (threat).
5. **Mammoths (corsumo) and Sheldons (cormort) go to the slow group (TODO).** They joined the fast groups and slowed
   them. slow_front: Mammoth = front (with Pounders), Sheldon = back (with Lashers); lab builds Sheldons again.
6. **Rez bots: at least 30, scaling with the reclaim available (TODO).** Dying is fine. They must actually repair a
   unit under attack nearby and reclaim, instead of walking back whenever an enemy is near.
7. **Shuriken micro (TODO).** ~30 Shurikens stunned the same unit. Stun a unit, leave ONE Shuriken to keep it
   stunned, move the rest to the next enemy unit that is still moving.

Also open from the 30-min game: v12 led at 20:00 (army 82.5k vs 63.6k) but LINE_CLICK led at 30:00 (292k vs 211k).
