# DRAGON_ECO (2026-10-14)

`candidates/DRAGON_ECO` = STANCE_ECO2's economy (unchanged: same line_transition presets, capstones on 10 grids, 14 fusion jobs)
with a much simpler army, per the user:

1. **Until 1.1k m/s** the spine's T1 vehicle plants make Pounders + a few Lashers (`stances/pounder_hold.lua`, 0.85 / 0.15).
2. **At 1.1k m/s** (smoothed, held 20 s: `strategy_hooks.income_switch`) the stance becomes `mammoth_hold` (Mammoth 0.85,
   Manticore 0.15).  slot_spine plans coralab (+ one corlab enabler for the T1 bot con that places it) and, with
   `RECLAIM_UNNEEDED`, reclaims the vehicle plants (slot labs and the adopted line plant) once a lab for the new comp stands.
3. **Anti-nuke:** no T2 vehicle plant, so no Saviors.  defense_crew `COVER_FIXED_ONLY` + `COVER_REPLACE_MEX`: every cover point gets
   a static corfmd built on the nearest grid mex (the mex is reclaimed first).
4. **Dragon lab at 2000 m/s:** the macro finds open ground ~700 past the spine's front block (`SS.Front()`), registers a con-broker
   job `dragonlab` (prio 95, T1 air) and the con places a coraap there; up to 6 free air cons repair the frame (a corca has 55 BP,
   ~10 min alone).  `WG.DragonLab = { id, x, z, ready, decoys }`; line_transition never orders T2 cons from it (`T.noConLabs`).
   It makes Dragons forever; the spine's coralabs make decoy commanders (cordecom: 750 m, 300 BP) up to
   0.5 x income / 12.75, between 8 and 60, which guard (assist) it.
5. **Army (`bar_framework/perimeter_guard.lua`):** never attacks.  Squads hold posts on the edge of the union of 2800-elmo circles
   around every building (posts off the map dropped, capped at 45% of the way to the enemy), weighted toward the enemy and toward
   recent contacts; armed ground intruders inside the ring get the nearest squads (1.5x their value) on FIGHT, then they go back.
   Dragons wait 600 in front of the Dragon lab; at 50 they MOVE to the enemy base (centre of known enemy labs, else the spawn)
   and FIGHT once there; later Dragons form the next wave.  The unit controller's other army planners are off (`ARMY_MODE`).

The lab controller was rewritten (~230 lines, lab broker): `spine` (spine cons, decoys, stance) and `dragon` wants only.  No
Shurikens, Wasps, fighters, bombers, scouts or rez bots.

Log rows: `[STRAT] metal income ... switching to stance mammoth_hold`, `[SLOT] adopted corvp ...: clearing`, `[DL]`, `[LabCtrl] ...
decoys`, `cover: anti-nuke at`, `[PG]`, `[DW]`.

Tests: `test_perimeter_guard`, `test_dragon_eco_labs`, `test_dragon_eco_bot` (stub wiring), plus cases in `test_slot_spine`,
`test_strategy`, `test_antinuke_cover`.

## Games (2026-10-14, main PC, single mode, 30-min cap, vs LINE_CLICK_v16, one per slot)

Both **lost to commander kills**: slot 0 at 17:53 (Tigers), slot 1 at 16:37 (Incisors).  No Lua errors, no desync.
`runs_dragon/g1_de_v16.*`, `runs_dragon/g2_v16_de.*`; replays `2026-10-15_02-02-20-769_*` (slot 0) and `2026-10-15_02-02-46-334_*` (slot 1).
- The economy held: `metal_inc_avg` 16:00 = 3126 / 2878 (ECO2 vacuum 2994-3623).  phi at 10:00: 31.0k vs 28.5k, 36.1k vs 25.6k.
- Stance switch at 12.7 / 13.1 min, as designed.
- **The T1 -> T2 swap left the army with no production.** All 8 slots held vehicle plants.  The old full-slot swap (not
  `RECLAIM_UNNEEDED`) cleared every one of them, and the corlab enabler too, between 13:11 and 15:48.  The first coralab stood
  only at 16:54.  Slot 0's army fell to 3.2k value.
- **The ring is too far out.** Grids spread far, so the posts sat 4.6-6.7k from the base centre with 1-3 squads.  The commander
  had no friends near it and enemies near it for minutes before it died.
- **Dragon lab:** a site was found and a con assigned at once (14:22 / 14:42), but the frames were lost again and again and no
  lab finished.  The con stayed alive in slot 0, so the cause was enemy fire on the base, or decay while the con was not
  building; not established.  No decoys and no Dragons in either game.
- Anti-nuke cover built corfmds on mexes (slot 0: 1 finished; slot 1: 2).

## Round 2 (user changes: ring 700 + density push, line con bots to the spine at the switch, clear only with a con in range, vehicle plants keep making Pounders)

`runs_dragon/g3_de_v16.*` (slot 0), `g4_v16_de.*` (slot 1); replays `2026-10-15_02-25-06-927_*`, `2026-10-15_02-25-32-229_*`.  Both
**lost to Tiger commander kills** at 17:27 / 17:44.  No Lua errors, no desync.  phi at 10:00: 29.0k vs 19.1k, 30.2k vs 28.1k
(DRAGON_ECO ahead).
- Switch at 13.3 / 13.6 min, and 3 line con bots handed to the spine both times.
- The ring started at 700 and hit R_MAX (3500) by 15:00, with an army of 58-103k in **3 squads** on 7-8 posts 5.2-6.5k from the
  centre.  On a corner base only ~3 posts fit at the angular spacing PickPosts keeps.  Lone Tigers (one unit, value ~690) walked
  past to the commander; the nearest squad (Mammoths, speed 23) was minutes away.
- Dragon lab frames were killed by enemies camped at the site (Tigers, Pounders; re-placed right next to them several times).
  The last one reached 74% with 6 helpers before the game ended.  Helpers were 0 at first: free air cons only.

## Round 3 (defenders on a line, Shuriken floor + raid Shurikens/Wasps, scouts ported back, lab jobs take a con off a nano block)

`runs_dragon/g5_de_v16.*` (slot 0), `g6_v16_de.*` (slot 1); replays `2026-10-15_02-49-01-504_*`, `2026-10-15_02-49-26-929_*`.
**Both won on phi at 30:00; both commanders survived the whole game.**  No Lua errors, no desync.
- End score: 1.19M vs 151k (army 1.0M, 918 units); 491k vs 179k (army 358k).
- Round 2's no-T2-labs bug: the handed con bots sat on nano blocks, which hold nanos for minutes, so the coralab jobs never got a
  builder (reproduced in the stub).  Fixed with slot_spine `LAB_TAKES_BLOCK_CON`.  Coralabs now stand 1:50 after the switch
  (slot 0: 13:07 -> 14:56, 5 by 19:04); "con N moves from block" fired in both games.
- The line: 64-79 defenders at 10:00, 500-760 later, one every 14-26 elmos at R 3000.  Only the nearest 3-48 answer an
  intrusion.  Slot 0 saw 58 intrusions all game.  Slot 1 took 885 intrusions, with raids up to 7.3k answered by ~11k of
  Wasps; its income lagged (16:00: 964 vs 2250) and it switched to T2 only at 17:11.
- Dragon lab: slot 0 finished at 20:07 (0 helpers until ~18:30, then 6), 60 decoys by 22:00, ~7 Dragons/min.  **Wave 1
  (50 Dragons) launched 27:40, arrived 28:41 with 48**; v16 lost 751 units/structures in the last 80 s.  Slot 1's lab finished
  21:47, 37 Dragons by 30:00, no wave.
- **Open: metal floats.** Slot 0's bank sat full (168-228k) from ~20 min, income 3.2-4.4k against 1.0-1.5k pull.  One Dragon lab
  with 60 decoys sinks ~600 m/s.  The rest went into an ever-larger ground army.

## eco_sim pass (2026-10-14, user: "over spending on army early... spend all the eco and scale well")

`python eco_sim.py run --bot candidates/DRAGON_ECO --tag de_nvN --seeds 1-4 --jobs 4 --no-vacuum --minutes 25` (no vacuum: the army
and Dragons stay, so the sink is real) against `--tag eco2_v25` (STANCE_ECO2, vacuum).  Median metal income:

| run | 10:00 | 12:00 | 16:00 | 20:00 | what changed |
|---|---|---|---|---|---|
| STANCE_ECO2 (vacuum) | 474 | 1162 | 3028 | 7076 | baseline |
| de_nv1 | 255 | 565 | 1586 | 4436 | round-3 bot, MATCH=true, RECOVER, raid-air cap |
| de_nv2 | 244 | 415 | 1398 | 3524 | scouts / Shuriken floor wait for the air-lab hold (WG.TileLabHold) |
| de_nv3 | 540 | 1250 | 3588 | 8586 | **mb.armyValue counts perimeter_guard's army + Dragons** |
| de_nv5 | 540 | 1266 | 3560 | 7933 | more Dragon labs while metal banks (6 by 24:32) |

- **The early overspend:** the share hook compared the scouted enemy with mb.armyValue, which counted only the unit
  controller's combatUnits.  The ground army lives in perimeter_guard, so it saw ~0.5-2k while 20k stood, and held the share at
  0.3-0.6.  In the real games, v16_share's threat lifts held it at 1.0 (round 3, slot 1: share 1.00 from 6:54).
- **Scouts in the air lab:** "ahead" scout orders went in front of the air cons (18 scouts and 46 air cons by 10:00, against 0 and
  76).  Scouts and the Shuriken floor now wait while WG.TileLabHold holds the lab; raid answers still go ahead.
- **Spend:** army + Dragon spend at 20:00 went from 211 m/s (one lab, helpers free-only) to 680 m/s, and 2.2k by 24:00.  The
  first lab took ~2 min with preempting helpers (was 4.5).  The bank still reaches ~500k by 20:00; decoys are the next limit
  (74 by 20:00 against a want of 120).

## Round 4 (MATCH=true + army value fix, RECOVER, raid-air cap 0.5x, air-lab hold for scouts/floor, several Dragon labs)

`runs_dragon/g7_de_v16.*` (slot 0), `g8_v16_de.*` (slot 1); replays `2026-10-15_03-26-40-834_*`, `2026-10-15_03-27-06-134_*`.
**Both won on phi at 30:00; commanders alive to the end.**  No Lua errors, no desync.
- End score: 1.54M vs 107k (army 1.21M, metal income 5.5k vs 1.3k); 745k vs 197k (army 663k).
- Income, round 4 against round 3, in the same slot:
  - slot 0, 12:00: 978 against 789.  29:00: 5274 against 3171.
  - slot 1, 12:00: 975 against 336.  16:00: 2363 against 964.
- The T2 switch came at 12:29 / 12:30 (round 3: 13:07 / 17:11).  The first Dragon lab finished at 16:28 / 16:20 (20:07 / 21:47).
- Dragon labs and waves:
  - slot 0: 5 labs by 24:27; waves at 22:59, 25:44, 27:46, 29:40 (199 Dragons by 30:00).
  - slot 1: 3 labs; waves at 24:18, 27:02, 29:27 (102 Dragons).
- Grid recovery fired from ~11 min in both games (several grids re-run).
- Slot 1's ground line was worn down to 5-22 defenders after ~20:00 and was not rebuilt, but the base held.  Worth a look:
  the share hook should lift the share when our ground army falls under the scouted enemy's, and only counts the Dragons as army.

## 2026-10-15: back onto the normal pipeline, Dragon behaviours

What was off after round 4 (user: "implement it correctly through the normal pipeline"):
- the unit controller had `ARMY_MODE = "perimeter"` as a hard-coded constant that switched click_army / slow_front / air wing / endgame off
  for the whole game, and the Dragon waves lived inside `perimeter_guard`;
- ~200 lines of Dragon-lab logic sat in `macro_controller.lua`.

Now:
- **Plan, not constant.** `stances/pounder_hold.lua`, `mammoth_hold.lua` carry `plan = { army = "perimeter" }`; the unit controller asks
  `PerimPlan()` (WG.Strategy:Plan()) every tick.  A stance without it gets the normal planners (nothing migrates between planners mid-game).
- **Dragons are units with behaviours**, like Lashers' `kite`.  `stance_loader` reads `extras = { {n, behaviors, cfg} }` (units the stance does
  not build through the spine); `Strategy:Assign` attaches them; the unit controller's HOST runs them.  `perimeter_guard` no longer knows Dragons;
  it publishes `pg.clusters` (intruder groups inside the ring).
  - `dragon_defend` (first stack slot after the raid): waiting Dragons FIGHT intruders inside the perimeter (nearest, 1.5x the group's value,
    at least 2), go back after 600 frames, otherwise gather 600 in front of the first Dragon lab.
  - `dragon_raid`: wave of 50 launches; target = enemy **commander**, else **build power** (factories, nanos, constructors), else **anti-air**,
    else the **closest eco** (else nearest structure, else the base), nearest to the wave within a class; re-picked every 240 frames and at once
    when the target dies; MOVE until within 1200, then ATTACK the unit if visible (FIGHT its place otherwise); non-commander waves split over the 3
    nearest targets; a wave under 10 Dragons returns to waiting and joins the next one.  Log rows `[DW]`.
- **`bar_framework/dragon_lab.lua`** holds the Dragon-lab job (macro_controller only wires it).
- **Does the normal stance bot rebuild the spine?**  Labs: yes (a lab that dies frees its slot and `PlanLabs` puts the missing lab back).
  Nanos and storages of a finished block: no (the block's placer session was done and never reopened); only the mex grids (`GRID_RECOVER`)
  and the line nanos near the air labs (`LINE_RECOVER`) have recovery.  New opt-in `slot_spine` `REBUILD_NANOS` (DRAGON_ECO turns it on):
  a nano an enemy destroyed is re-queued after 900 frames if no raid cluster is within 1200 of the spot (`[SLOT] ... lost, built again`).
  Not covered: energy storages in the block gaps, and nanos reclaimed by us on purpose (no attacker -> not rebuilt).
- Tests: `test_dragon_behaviors`, `test_dragon_lab`, `test_perimeter_guard`, `test_slot_spine` (REBUILD_NANOS), `test_dragon_eco_bot`.
  eco_sim (`de_pipe1`, 2 seeds, no vacuum): 10:00 540, 12:00 1236, 16:00 3498, 20:00 7712 -- same as de_nv5 (540 / 1266 / 3560 / 7933).

## Round 5 (the pipeline version above), `runs_dragon/g9_de_v16.*` (slot 0), `g10_v16_de.*` (slot 1)

**Both won by killing v16's commander with Dragons** (frame 46439 = 25:48 and 49106 = 27:16), before the 30:00 cap; no Sync errors.
- Slot 0: Dragon labs at 15:58 / 17:26 / 18:51 / 20:59; wave 1 (50) 22:29 -> targets `bp` the whole way in (nanos / labs, re-picked as each died),
  wave 2 24:38; at 25:41 both waves switched to `commander` at (9153, 11820) and killed it.  26 `dragon_defend` rows (1-2 waiting Dragons
  answering intrusions of 1-15 units).
- Slot 1: 8 labs by 27:16, waves at 23:34, 25:38, 27:06; waves 1 + 2 -> commander at 27:15.  `REBUILD_NANOS` fired twice (block 9, 24:26).
- The user's target order worked as designed: build power first, the commander the moment it was known, and the kill followed in ~7 s of the switch.
- Not yet looked at: army/ring losses, intrusion counts, phi curves against round 4 (no comparison made; two games is not an A/B).
