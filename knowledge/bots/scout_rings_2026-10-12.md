# Scout rings (STANCE_BOT, 2026-10-12)

User: the map is dark; scouting must keep vision in rings round the mex grids, push the rings as far as scouts survive
without always dying, cover every path to the base, and add radar units from T2 labs as a slow trickle.

## What was wrong in v16 / STANCE_BOT
- `AssignScouts` sent every scout beyond `PICKET_SCOUTS` (6) to recon (`nRecon = #scouts - 6`), so the depth grid
  (`DepthPosts`) never received a scout. Vision was 6 line scouts on one corridor + recon scouts in the enemy half.

## What it does now (`RING.ON` in `candidates/STANCE_BOT/unit_controller.lua`)
- `bar_framework/scout_rings.lua` (pure planner, no orders; tests `tests/test_scout_rings.lua`, bot smoke
  `tests/test_scout_rings_bot.lua`):
  - footprint = support function of our buildings in 36 bearings from their centroid; rescanned every 4 s, so rings grow as
    grids are built;
  - outer ring at footprint + 450 + push; inner rings step in every 800 (max 4), posts spaced 1.7 x scout sight radius,
    map-clamped and de-duplicated (a base on an edge gets half rings), kept 2600 from the enemy base;
  - push creeps +200 / 8 s per bearing while quiet; a scout lost sets a cap 700 inside the loss (+-2 bins), a hurt scout 350,
    an armed enemy we can see caps 1100 inside it (+-1 bin); caps creep back out at 6 elmos/s, and no push resumes for 30 s;
  - fill order: posts facing the enemy first, each ring in proportion, spread so a partial fill still watches all sides.
- Unit controller: first 2 picket scouts stay on the contact line, the rest hold ring posts; recon keeps only 1-2 (fastest).
  Ring scout want = 1 per 10 metal/s of income above 60 (max 30). `[UC/rings]` log row every 30 s: scouts, radars, posts, rings,
  push avg/max, lost/hurt.
- Lab controller: a ground, unarmed unit with radar radius >= 1400 is a "ring radar unit" (found by def, not name); T2 labs
  (spine or not) order the cheapest one ahead of the queue, at most one per 45 s across all labs, up to
  `mb.ringRadarWant` = 1 + (income - 200) / 150 (max 6), and only with bank >= 150 and no stall. They stand on ring 2, spaced evenly.

## Tunables
`RING` table (unit_controller), `RS.CFG` (scout_rings.lua), `RR` (lab_controller).

## Untested / to-do
- Real-match behaviour: see the results block below. Check `[UC/rings]` lost/hurt counts and `first_enemy_near_base lead_frames`.
- Ring scouts are the SLOWEST scouts (recon takes the fastest); air scouts (Fink) die to AA and fighters.
- Footprint counts every immobile non-flying unit (turrets and lone mexes far out stretch the rings).

## Results
- 15-min single-mode smoke, STANCE_BOT (slot 0) vs v16, `runs_stance/rings1.json` (one game, no desync, no Lua failure):
  - Warning: STANCE_BOT's `first_enemy_near_base` warned at distance 11522 with `lead_frames` 2220 (74 s); v16 warned at 1095 with lead 0.
  - Radar: 5 `corvrad` radar vehicles built (the real T2 unit; found by radar radius).
  - Score: 90.2k vs 99.4k = draw (inside the 10% band); army value 25.5k vs 45.5k, so scouts/radars cost some army. One game proves nothing; paired A/B (`runs_stance/batch.py`) still to do.
- The `[UC/rings]` rows are in the per-team widget logs, not `result.json`; read lost/hurt there.

## Session end state (2026-10-12) -- user: "good enough for now"
Changes made after the first smoke run, from watching replays + `[UC/rings]` rows:
1. Outer ring fills FIRST (was: every ring in proportion, so a few scouts sat on inner rings near the base).
2. Enemy sightings no longer set lasting caps: `enemyCap` is recomputed each call, only holds while the enemy is seen.
   (Before: one Rover seen at 3000 out capped that bearing ~10 min; push avg sank to ~2100.) Loss caps recover at 15 elmos/s.
3. Log rows now `[UC/rings] at_post=N/M mean_post_dist=D` (scouts within 500 of their post / planned) plus the usual row.
   Rows are in the per-team widget log (`%TEMP%\bottest_*\solo\headless.log`, lines tagged `<T0>`), not in result.json.

Last game (`runs_stance/rings4.json`, replay `2026-10-12_18-32-26-155`): posts 4000-5800 out, but only ~half the scouts
at their post at any time; first enemy near base 4075 out / 540 frames lead (v16: 12486 / 2820); score ~even (draw band).

## Known gaps / to-do
- An early raid slipped through once. User's call: a radar building near the base is enough; not built yet (a T1 `corrad`
  by the commander / first lab would do; the macro controller is where it goes).
- Scouts lag their posts (posts move with every grid + push step; ring scouts are the slowest scouts). Ideas: snap footprint
  and push to ~400-elmo steps, give ring scouts the faster scouts (only the single fastest on recon), check the broker's
  re-order throttle (`ARMY.ORDER_MIN_INTERVAL`).
- Few scouts before ~8:30 (4-7): labs queue scouts behind the defence floor.
- Not A/B-tested: only single games vs v16 (scores 0.91x, 1.49x, 0.82x, ~1.0x -- noise). Run `runs_stance/batch.py` pairs
  before calling it better or worse in strength.
