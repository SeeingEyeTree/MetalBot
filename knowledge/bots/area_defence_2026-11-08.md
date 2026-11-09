# Area defence: one owner for defending the base (CORE_v4, 2026-11-08)

## Why
Before this, three things defended CORE_v4 and none of them knew about the others:
- **cover_defence** borrowed army units worth 1.2x every threat. It never counted the Pounder wall, so it pulled raiders out of the army even with 12 Pounders standing next to the threat.
- **The Pounder / Tzar home records** (`support/t1stop.lua`, `support/stop.lua`) stood in 3 fixed sectors 1300 from the eco centre. That put them **behind** the eco. They used FIGHT inside a 700 leash. In the 11-02 games: 36 Pounders, 0 lost, 23 kills.
- **Shurikens and Wasps** went to raids through raid_response. Otherwise they orbited the commander as home guards.

The user's request: one system that defends declared areas (the main base now, proxy bases later), keeps a checklist of enemy threat types, runs four squads (wall, air, borrowed army, construction stub), defends cost-effectively, and hands units back when they are not needed. The main point is making the Pounder wall effective.

## What it is
unit_runtime option `AREA_DEFENCE = { ... }`. It is nil by default; CORE_v4 sets `{}`. The code is `bar_framework/area_defence.lua` plus `bar_framework/defence/`:

| Part | File | What |
|---|---|---|
| Areas | `defence/areas.lua` | **Main** = labs, eco and static builders within `R_MAX` 4000 of the spawn. `AD.Declare{ id, R_MAX, members }` adds an area (proxy bases). Each area has distance / nearest-in-cone queries and an **approach map**: 16 angle bins of threat value, decay 300 s, seeded with the enemy axis. The **front** is the arc of bins with at least half the top bin's traffic. |
| Threats | `defence/threats.lua` | cover_defence's model: radar dots typed by speed, scouts at 0.1, carried tick to tick. Each threat is tagged with the area and member it points at. |
| Checklist | `defence/checklist.lua` | Rows `ground_raid` (wall size), `ground_heavy` (wall Tzars), `air_ground` (extra base AA screen + a `defence:aa` lab request + static AA for the stub), `nuke` (antinuke cover per area; stub), `long_range` (logged). Each row has seen / want / have / short / answer. |
| Wall | `defence/wall.lua` | Pounders + Tzars on the front, at the area's edge member + 450 out, so the wall stands in front of the eco. MOVE only (details below). |
| Air | `defence/air.lua` + `defence/air_micro.lua` | Every Shuriken and Wasp. Packs, AA first, then the stun / Wasp split. The split is the code moved out of raid_response unchanged. Idle, they orbit the area centre. A Dragons hook is off. |
| Army | `defence/army.lua` | cover_defence's borrowed defenders: line / cut / chase, MOVE only. Handed back when the threat is gone or over-covered; forward units go to `CA.Adopt` and raid from there. |
| Build | `defence/build.lua` | Stub: collects static-defence wants per area and logs them. Nothing is ordered. |

**Allocation.** Threats are taken most urgent first. Each has `need = 1.2 x value`, filled cheapest first: walls that can get in front in time, then the air squad, then borrowed army. Above 1.8x the need, units go back in order: army first (farthest first), then air, then a second wall.

**Raid_response.** With `GROUND_EXTERNAL` set it only answers air raids. Its raid record's ground groups are area_defence's fight groups. `mb.cover` keeps cover_defence's fields, so `holdHome` and `home_quiet_s` work unchanged.

### The wall
- **Pounders come from the stance**, because the user was worried about over-investing. The wall stances (`stances/legacy/raid_start_wall.lua`, `raid_brutes_wall.lua`) make 1 Pounder per 12 Incisors or per 10 Brutes, by count. Shares are by value: 0.864 / 0.136 and 0.913 / 0.087.
- **Want.**
  - **Floor:** one wall per 2000 elmos of the front's edge (at most 3), 4 Pounders each.
  - **Raid pressure:** t1stop's measure on the area's threats raises the busiest walls to 12 Pounders + 2 Tzars. Tzars come in once enemy T2+ ground worth 1500 is seen, or our income has stayed at 300+ for 20 s. The pressure decays, so the want falls again.
- **Surplus.** Pounders over the want, on a wall with no threat for 120 s, walk to the nearest nano and are reclaimed. At most 4 a minute go. The unit side lists them in `WG.DefenceReclaim`; on the macro side `home_defence.lua` gives up to 3 nanos in reach a reclaim at nano_broker `PRIO.DECOM` 1.2. A surplus Tzar goes back to the raid groups' stop element.
- **Block.**
  - A wall takes a threat when it reaches the threat's path (`MeetingPoint`), or the post in front of the threatened member, no more than 6 s after the threat would arrive. The block point must also be within 1500 of the wall's post.
  - The wall then makes a line across the threat's approach.
  - In contact, each Pounder runs at one enemy but never more than 400 past the block point.
  - Tzars stand 150 behind the line with the density SET_TARGET (`support/arty.lua` `AimDensity`). A Tzar farther than 1800 from its post is flown there by air_lift.

### "Do we need more units?" and defended eco bursts
- **Built cover** for a threat = the units on it + free units that reach its post before it arrives. New production is not counted.
- **Signals:** `def_margin` (the worst threat's built / need), `def_need_units` (margin < 1, or bombers coming while the air row is short), `def_covered` (margin >= 1.3 and no units needed), `def_cover_s`, `def_threats`.
- **Machine `machines/v4_defence.lua`** = v4_rows_raid with the wall stances plus:
  - `def_burst` (share 0): entered from `push_high` (8:00+, raid stance, a threat on, `def_cover_s` >= 15, at least 60 s in push_high), or from `attack`. It lasts 20 s, and ends early on `def_need_units`.
  - The attack any-edge no longer fires while `def_covered`.
- `v4_rows_raid` and the original stances are unchanged, so the committed CORE_v4 (`candidates/CORE_v4_022f31f`) still plays as before.

## Logs
`[DEF]` rows:
- areas;
- walls: floor / pressure / per-wall have / want / post / threat, and reclaims;
- per-threat cover: wall + air + army = have / need, built, mode;
- margin / NEED UNITS / covered seconds;
- handbacks;
- a score row every minute (each squad's kills and losses);
- the checklist every minute;
- build (stub) wants.

`[HD]` counts own units decommissioned. `[CFG] area_defence` shows the options.

## Not done / next
- Surplus wall units have only one way out: reclaim. The proxy-base move and the "join a fighting group" hand-off (with an air lift) are next.
- The construction squad is a stub.
- No Dragons in the air squad.
- Only the main area is declared.

## Results (2026-11-08)
**Checks.**
- `order_check`: STANCE_ECO2, RAID_BOT, DRAGON_ECO, STANCE_ECO2_vac and CORE_ROWS_ECO are **identical**, so the air_micro move and the other shared edits change no orders. CORE_v4 differs as expected, with 0 Lua errors.
- `run_tests.py`: the same 7 suites fail before and after (fsm, raid_bot, raid_plan, stance_export, dragon_eco_bot, line_bomb, defence_bot). These are pre-existing failures; raid_bot's 3 are stance files that moved to `legacy/`.
- eco_sim, CORE_v4: the floor wall forms in front of the base and grows to 3 walls as the base spreads. 10 surplus Pounders were reclaimed by nanos.

**Real games**: CORE_v4 (team 0) vs `CORE_v4_022f31f` (team 1), `--server single`, 20 min. Today's CORE_v4 also carries the uncommitted 11-04 sink / nano-col changes, so the eco side of the comparison is confounded. The first attempt crashed both macro controllers at frame 150. The cause was the uncommitted `PING_NAME_FRAME` ping in `macro_runtime.lua`: `local px, py, pz = commanderID and spGetUnitPosition(...)` kept only px. That is fixed.

| | Game 2 | Game 3 (air AA gate added) |
|---|---|---|
| Result | Draw on phi (28.4k / 28.2k) | **Win on phi** |
| End: army / income | 84k / 3.5k m/s vs 116k / 1.6k | 168k / 2.6k vs 103k / 1.3k |
| Wall (killed / lost) | 5.3k / 0 | 7.5k / 1.0k |
| Air squad (killed / lost) | 9.4k / 30.0k | 4.5k / 18.9k |
| Borrowed army (killed / lost) | 17.8k / 13.4k (317 handed back) | 36.7k / 20.0k (631 handed back) |
| Our eco / labs / nanos lost before 20:00 (enemy kills) | 7.1k vs 2.4k | **94k vs 7.0k** (80k of it at 17:00-18:00) |
| Shurikens lost | 342 vs 44 | 396 vs 56 |
| Defended bursts | 3 (8:52 for 5 s, 9:31 and 11:02 for 20 s) | — |

**Reading.**
- **The wall now fights and trades well.** The old home groups made 23 kills in a whole game.
- **Borrowed army, early game.** From 9:00 to 13:00 the new bot borrowed 2-3x less army than the old cover_defence at the same minute. Measured as summed per-row "have": at 11:00, 24k vs 72k; at 13:00, 31k vs 68k.
- **Borrowed army, late game.** From 14:00 it borrowed more, with more threats logged against its bigger base.
- **The Shurikens trade badly.**
  - Game 2: 242 of the 342 died to Lashers and flak trucks. The old bot's AA support element answers our air near its groups, and AIR_PACK dived in after 40 s.
  - Fix: a per-threat AA gate (air takes a threat only at 1.5x its AA), and no dive after the wait.
  - Game 3 showed that gate counted every Brute / Incisor as full AA, which blocked the air squad almost everywhere. It now uses enemy_intel's 0.35 for non-dedicated AA. **That fix has not been seen in a game.**
  - The Shurikens still died, mostly to Incisors (142) and fighters (94). The idle FIGHT orbit and base fights are the likely cause.
- **The 17:00 attack in game 3.** A 111-unit, ~28k enemy army against ~20k of borrowed defenders took 80k of eco: 12 T2 air labs, 138 nanos, 4 fusions. The defence saw it ("NEED UNITS", margin 0.04), but the launch gate still counted production as cover.
- **Verdict.** It does not yet clearly defend better. The wall and the early-game army savings are better; the Shurikens and big late raids are worse.

**Next.**
1. Air squad: keep idle air out of fights; maybe only answer threats near the eco or with ground support.
2. Big raids: stop counting production for the gate when margin < 0.5; recall a raid group.
3. Pressure walls only came to one wall (floor 1 all game in game 2); more walls when a second front shows.
4. A CORE_v4 snapshot without AREA_DEFENCE (today's eco) as the opponent, to drop the confound.


## Round 2 (user, same day): small walls, no Tzars, air close in
User: "They were moving around as one big group.  3 pounders is enough to slow down a push by a lot ... split the pounders up into groups of 3 or so to get
better coverage, and keep air for more close in raids ... Don't use tzars for the wall for right now."  Then, after game 5: the air does not need our
ground units near a raid ("they can go to intercept a raid even if there are no close ground units") -- the rule is the distance.

**Wall** (`defence/wall.lua`):
- Every wall is `N` = 3 Pounders. The floor is one wall per 700 elmos of the front's edge (at most 8), plus 2 walls per raid-pressure level (at most 12).
- The floor never shrinks.
- There are always enough walls for every Pounder to be in a group of 3, so no wall holds more.
- New Pounders fill the walls one at a time, busiest direction first. A quiet idle wall gives a Pounder to a short wall with more than twice its traffic.
- A threat takes at most `WALLS_PER_THREAT` = 2 walls; `LEASH` is 1200.
- The front includes every direction with at least 15% of the top traffic (`FRONT_SHARE` 0.15; it was 0.5).
- Reclaim only happens above the wanted walls' Pounders + `RESERVE` 3, taken from the quietest idle wall.
- `TZARS` = 0.

**Air** (`area_defence.lua`, `defence/air.lua`):
- The air squad comes last: after the wall and the borrowed army.
- It only takes threats within `AIR_R` 1500 of the eco (keeps them out to 1900), closest to the base first. Targets are also ranked by distance to our eco (air_micro `rank`; raid_response passes none, so its orders are unchanged).
- It only takes a threat where it beats the threat's AA (1.5x; non-dedicated AA counted at 0.35).
- Idle, it orbits with MOVE, not FIGHT.
- `AIR_NEED_GROUND` (wait for our ground units on the threat) is an option, off.

**Games** (same opponent, CORE_v4_022f31f):

| | Game 4 (walls of 3, air close in) | Game 5 (+ floor never shrinks, enough walls, front 0.15) |
|---|---|---|
| Result on phi | Win | Loss (phi led at 10:00 and 20:00; end income 2.6k vs 3.2k) |
| Wall killed / lost | 6.0k / 2.3k (one wall had 11 Pounders) | **11.4k / 3.9k**, 8 walls of 3 across the front and flanks |
| Our eco lost / theirs | 57.5k / 0.3k (raids round the flanks at 11:00) | **15.3k / 28.7k** |
| Shurikens lost | 144 (138 to flak trucks while orbiting with FIGHT) | 166 (all fights within 1.5k of the eco) |

Notes:
- **Shuriken kills read 0**: a stun does no damage.
- **Pounders run out late.** t2_raid makes none, so the walls dwindle after T2 (game 5: 23 Pounders at 15:00, 8 at 17:30).

## Round 3 (user, same day): air made simple; line cons high
**User:** "Just have shurikens go to stun anything within 1-2k elmos of the base ... don't do value matching with them.  Air does not add to value it just goes in and stuns/kills everything."

Game 7 (15 min, loss on phi) showed why the air did nothing at 9:00. The raid at the base got 2 Shurikens, and another got 1, while about 16 sat idle: the air only filled the small gap the army left.

**Now:**
- Every air unit goes at the threat closest to the eco within `AIR_R` 2000. It keeps that threat until it is `AIR_SLACK` (400) further out.
- Air is not counted in a threat's have or need, so the ground defence is the same as before.
- No AA gate and no AIR_PACK gathering. Stun / Wasp targets are taken closest to our eco first.
- Incisors count 0 as AA (threats `ZERO_AA`). This only shows in the logs now.
- CORE_v4 macro: `LINE_CONS_HIGH = true`.

**Game 8** (15 min): **win on phi**. At the end, income 1,145 vs 579 m/s and army 45.5k vs 43.3k.

| | Ours | Theirs |
|---|---|---|
| Eco / labs / nanos lost | **460** | 55k |
| Shurikens lost | 220 (146 to Lashers, 74 to Incisors) | 44 |

- 25 air dispatches; stun rows show up to 21 Shurikens on a target and 9 targets stunned at once.
- Wall: 4.5k killed, 0.26k lost. Borrowed army: 12.9k killed, 7.5k lost.

## Round 4 (user, same day): AA first, EMP stun check, keeper + hand-back, row cons high
**Air** (`defence/air_micro.lua` `AssignStuns` opts; raid_response passes none, so RAID_BOT is order-identical):
- Enemy AA goes first (`aaFirst`: dedicated AA + `AA_NAMES`, e.g. Lashers, flak). User: "I saw them target gators before lasher".
- A target counts as stunned when `Spring.GetUnitIsStunned` says so or its EMP (paralyze damage) is at its max health (`stunCheck`).
- One Shuriken stays on each stunned target. The rest are handed back and orbit home until a target needs a stun again (`spares`).
- Fixed: a freed air unit never released its RESPOND claim, so the HOME_GUARD orbit order was refused and it sat on its last order.

**LINE_CONS_HIGH** (`line_crew.lua`):
- BAR's stock "Builder Priority" widget sets every con LOW in its own UnitFinished. For the row cons, which join the crew in UnitFinished, that ran after our HIGH order; only the first cons, which join later, stayed high.
- Fix: the high order is sent again 30 frames after a con joins.
- This also changes CORE_ROWS_ECO's orders, which has LINE_CONS_HIGH on.
- The priority state itself is not logged; check it in a replay.

**Game 9** (15 min): **win on phi**. At the end, income 1,335 vs 673 m/s and army 54k vs 50k.

| | Ours | Theirs |
|---|---|---|
| Eco lost | 2.8k | 17.1k |
| Shurikens lost | 164 (128 to Incisors, 36 to Lashers; game 8: 146 to Lashers) | |

- Air killed 4.5k and lost 6.2k.
- Stun rows show spares handed back (e.g. 10:55: 16 Shurikens on 4 stunned targets, 12 handed back).

## Proxy base, proof of concept (user, same day)
**User:** "when it is clear that raiding is not working it swaps to trying to hold a proxy base 4k elmos away from enemy bp near labs ... near the edge/side of the map ... just trans 4 nanos and a con, and set up a spine with it, and try to hold it."

**Built.** `bar_framework/proxy_base.lua`, macro side, macro_runtime option `PROXY` (needs `SINK`). CORE_v4 sets `PROXY = { FORCE_FRAME = 8:00 }` for the test; remove `FORCE_FRAME` to start only on bad trades.
- **Trigger:** signals' `bad_trade` rule on `mb.trade`, held 45 s, after 8:00. One proxy at a time, up to 3 tries. The timeout counts from the last setback.
- **Spot:** a point 4000 ± 600 from the enemy's build power, within 250-700 of a map edge, the buildable one closest to our spawn. The lab exit faces the middle of the map. Enemy build power = `mb.enemyBP`, which unit_runtime publishes (enemy labs x3 plus static builders).
- **Build:** the con broker's "proxy" job sends a T1 air con, which places a T1 vehicle plant and then guards it. sink_lift sees the proxy as a site of kind "proxy" (`metal_sink` `extraSites`) and flies in 4 nano-column nanos, ahead of the sink's own sites. They build the frame, then guard the lab.
- **Hold:** `WG.ProxyBase` makes area_defence declare an area "proxy" (buildings within 1200 of the spot). That gives it threats, borrowed army, and air within AIR_R. A new wall unit joins the walls of the area nearest to it. Wall reach is now measured from each area's anchor, not the spawn.

**Game** (15 min, vs CORE_v4_022f31f): draw at the 15:00 end score (107.7k vs 104.9k; phi at 10:00 37.1k vs 27.6k).
- 8:00: spot 5504,11648 (bottom edge, 4073 from the enemy's build power). The air con flew there; frame at 9:24, lab finished at 9:53. The 4 nanos were placed by 11:02.
- Defence at the proxy: borrowed army up to 5.5k on a 33-Incisor group at 1 km. The air went once a raid was within 2k.
- 11:22: lost to ~30 Incisors. Only 543 of our army was at the lab, and there was no wall: no Pounders were made near the proxy.
- Try 2 at 11648,7040 (right edge): frame at 12:57, killed. It was then "timed out" by the bug above (fixed after the game). Try 3 was under way at 15:00.

**What it lacks:**
- The proxy lab's own production is not used for its defence.
- The borrowed army walks ~10k to get there.
- No raid stop while holding.
- Nothing builds static defence (LRPC / static creep); the construction squad is still a stub.
