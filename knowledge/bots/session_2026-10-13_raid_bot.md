# RAID_BOT: game review fixes (2026-10-13)

## The game (STANCE_BOT vs Psyco12, Full Metal Plate)

- Replay: `2026-10-13_03-15-37-250_Full Metal Plate 1.7_2026.07.04.sdfz`.
- Live log: `BAR data\log\20261013083650_infolog.txt`.
- The bot won on macro alone: peak metal income 1767 vs 1012.

| Time | What happened | Cause |
|---|---|---|
| 0:00-8:00 | Army idle at the stage (1.2-1.6k av), with an army-value lead. | click_army never launched on the mirror guess (foe sighted at 6:01), then needed `LAUNCH_MIN_AV` 1800. |
| 8:00-15:30 | 7 groups lost 40 units / 33k for 0 kills. | Every group targeted the same nano. Groups #5-#7 were lone Demons. `LegPoint` turned away from ~3 enemy units, including fresh lab output, so groups danced while surrounded. Groups never committed and never fully retreated. |
| ~9:30 | No change of plan after a clearly bad trade (own 6967 vs enemy 8610, 0 kills / 1484 lost). | Only `cap_switch` existed. |
| 13:30-16:00 | Raid response worked but over-chased ("24 units vs 2 raiders worth 470"). | Responders were never released as raiders died. |
| 13:30-16:00 | Air labs kept making cons. | No raid gate on con orders, and the T2 air lab had no raid pick. |
| 18:30 | The bomber run that won the game. | It came from click_army's `UpdateBombers`. **air_wing logged "0 bombers, strikes 0" the whole game**, so don't hand bombers to air_wing without checking why. |

## What RAID_BOT changes

All framework options default off, so other bots are unchanged. Tests: `test_raid_army`, `test_raid_plan`, `test_con_hold`, `test_raid_bot`.

- **click_army:**
  - `EARLY_LAUNCH` (RAID_BOT: flat 300 av until 6:00, then up to 1800 by 14:00) and `LAUNCH_RATIO_EARLY` 1.0.
  - `BLIND_LAUNCH`: launch while the foe is still the mirror guess.
  - `MIN_GROUP_UNITS` 3.
  - `LAB_EXIT_R/W`: fresh lab units count 0.2 for steering.
  - `ENGAGE`:
    - COMMIT (ATTACK the build power in reach, no dodging) when surrounded, outvalued or losing with build power within 700;
    - otherwise ESCAPE all the way to our line front;
    - `[CK] COMMIT/ESCAPE` rows.
  - `HOLE_FIND`: approach from the least defended of 12 ring points round the target, and send the unseen points to the scouts.
  - `DIFF_PENALTY` 0.05.
  - `SetMode("hold")`.
  - `TradeSummary`: kills of any kind near a group vs group losses.
- **Game plan:**
  - Stances carry `plan`: `raid_open` (fast raiders + range_kite Demons), `hold` (the user's comp), `raid_late` (Late_game's comp, Demons kite).
  - Switch hooks: `chain_switch{cap_switch, game_plan}`.
  - `game_plan` goes raid → hold when the army ratio is under 0.85 AND the raids trade under 0.5 (at least 1000 lost) or 2 bad group ends. It goes hold → raid at ratio ≥ 1.4 for 60 s, with at least 90 s in a plan.
  - `income_mix` weights tilt `mass` units (Grunt, Pounder) to `quality` units (Sheldon, Mammoth, Shiva, Banisher) as income goes from 150 to 1000 m/s.
- **Units:**
  - No slow group: slow_front is not loaded, and rez bots go to rez_crew.
  - Every combat unit gets its stance behaviours.
  - `behaviors/range_kite`: holds the nearest enemy at 85-95% of our range. It doesn't kite an enemy that outranges us, and doesn't kite while defending (raid response or home guard).
- **Raid response:**
  - Sized on the raid's value in its own channel (air not counted against a ground raid).
  - Extras above 3x are moved to another raid that is short, else released, farthest first.
  - A released responder gets its stance behaviours back.
- **Air labs:**
  - `CON_HOLD` stops air/T2 con orders during a live ground raid worth ≥800.
  - The T2 air lab answers a ground raid with Wasps.
  - The Shuriken cap rises 30 → 45 while air-superior.
  - The hold plan keeps `plan.bombers` x 30 s of income in bombers while air-superior.

## In-engine checks (single mode, 20 min, vs STANCE_BOT, both slot orders)

| Run | First launch | BP kills by 10:30 | Mechanism rows | Notes |
|---|---|---|---|---|
| raid1 | 6:28 / 6:31 (STANCE_BOT 9:57 / 10:52) | 11 and 6 (STANCE_BOT 0) | COMMIT 4/4, ESCAPE 3/5, approach 14/18 | Release churn seen: extras released from one cluster while new units were pulled for the one next door. |
| raid2 | 5:16 / 6:03 | 11 and 1 | moves 59/66 | Game plan worked end to end: raid → hold at 12:15 (ratio 0.84, trade 780/3401), back to raid at 13:47 (ratio 3.45). |

Changes between the runs:
- after raid1, the launch ramp was relaxed;
- after raid1, extras are moved before being released (`[INTERCEPT] move`).

Strength (legacy score A/B): raid1 0.84 and 1.22, raid2 1.09 and 0.89. **No difference demonstrated** (4 games); phi named RAID_BOT the winner in 3 of 4.

A bot-vs-bot match barely punishes idling. The real test is a game against a person, reviewed through these rows: `[CK] COMMIT/ESCAPE/approach`, `[PLAN]`, `[INTERCEPT] release/move`, `[RKITE]`, `[LT] CON HOLD`.

## Open

- RAID_BOT has lost more value than STANCE_BOT in its raids (18-28k vs 9-23k by 19:30). Check in replays whether ESCAPE fires early enough.
- `plan-bomber` never fired, because no air superiority came up in bot-vs-bot games.
- The air-superiority rule (1.5x their air and an even air trade over 2 min) is untested in a real game.
- A stance switch reclaims and swaps slot-spine labs. Watch for lab churn if the plan flips often (90 s minimum stay).

## Second round (user feedback on the replay, 2026-10-13)

The user's verdict was that RAID_BOT "did well". These are the fixes they asked for. All framework options default off; RAID_BOT turns them on.

- **Mex grids died and did not recover.** A finished grid was dropped from `gridStates` and never looked at again.
  - Fix: `line_transition` `GRID_RECOVER` keeps each finished grid's mex spots (merged over re-runs).
  - A spot empty on two looks 300 frames apart, with no raid cluster within 1500, is acted on:
    - a plain grid is re-run first in `pendingGrids`; standing items are skipped;
    - a retrofitted grid is opened for retrofit again, so a T2 con rebuilds the mohos.
  - Grids being built, re-run or retrofitted are not judged, because a retrofit reclaims its own T1 mexes.
  - Log row: `[LT] RECOVER`.
- **Second T1 air lab on the line.** `SECOND_AIR_LAB` runs from 7:00 once the line is built, or at 10:00 regardless.
  - It takes a 3x2 block of line slots, fewest mexes first. Real lines are about half mexes mixed in with the winds, so a pure-wind block often doesn't exist.
  - Up to 4 nano slots beside it.
  - The slots are reserved and the winds/mexes reclaimed by the placer (`clearBlockers`).
  - It orders its own air con. Grid helpers and the nano crew take every free con otherwise, so in the first try it never got one.
  - It is not the macro's air lab, so it is never held for air cons.
- **Standing Shuriken force.**
  - Shurikens are home guards (the old never-raid rule lived in raid_group, which LINE_CLICK doesn't load).
  - The Shuriken floor (up to 9 standing) comes before the fighter floor. In the second test game the fighter floor (40 fighters against heavy enemy air) took every slot.
- **Ground AA** (`coraak`: longer range, slightly less effective; `corsent`: short range, very effective):
  - added to all three RAID stances (3-6% each);
  - kept out of click_army, because they are AA-only;
  - 40% (2-10 units) hold posts on a ring of 1100 round the base;
  - the rest FIGHT just behind the biggest attack group, else at the stage;
  - a dead screen post is refilled from the escorts.
- **Fighters closer to the front.** `click_army` `FIGHTER_POST` is 900 behind the biggest attack group (else the stage), stepped back 300 at a time while the known enemy AA there is above 150.
  - click_army's fighters FIGHT there instead of flying over the group.
  - air_wing's idle station uses the same point (`station` hook). It used to be 12% of the way from home, i.e. next to home.
- **Scout calls with corawac** (user: they had been lost):
  - `SCOUT_ROUTE` makes a group's requests point along its actual route (hole/flank waypoint), at the target itself, and at the unseen ring points.
  - Every Hawk is in the call pool (`CALL_RADAR_KEEP` 0).
  - Idle Hawks wait spread round the fighter post.
  - The T2 air lab keeps a standing pool of 3 Hawks, inserted ahead of its queue when short.

**Bug caught by the stub:** RAID_BOT's lab-controller `GameFrame` hit Lua 5.1's 60-upvalue limit. In-game the whole lab controller would have failed to load. New lab constants now live in the `RAID` table.

**In-engine check** (vs STANCE_BOT, 20 min; replay `2026-10-13_06-14-43-901_Full Metal Plate 1.7_2026.07.04.sdfz`):
- second air lab queued at 8:37, finished 9:54;
- 28 `RECOVER` rows;
- radar-pool 13, ground AA 16 orders;
- COMMIT 6, ESCAPE 14;
- no Lua errors.

STANCE_BOT won that game on phi (army 142k vs 107k; RAID_BOT had more income, 2614 vs 1972). One game, so noise. The Shuriken-floor priority was added after that game.

Tests: `test_grid_recover` (new), plus additions to `test_raid_army` (fighter post, scout route) and `test_raid_bot` (second lab, home Shuriken, AA screen, Hawk pool).

## Third round: review of game 3 (findings below; changes made 2026-10-14 are listed at the end)

The game: RAID_BOT (T0) vs STANCE_BOT (T1), 20 min, single mode.
- Replay: `2026-10-13_06-14-43-901_Full Metal Plate 1.7_2026.07.04.sdfz`.
- Log: `%TEMP%\bottest_20261013_021436_25136\solo\infolog.txt`.
- Per-minute parser: `an.py` in the session scratchpad. It reads `[STATS] built/destroyed` and `[TRK] units/eco`.
- The user's observations are marked **(user)**; everything else was measured from the log.

### 1. Nuke vs Savior (user: a nuke did real damage to STANCE_BOT; a Savior covered the spot but finished charging 15-30 s too late)

| Launch | By | Target | Lost by the victim in the next 50 s (includes combat around it) |
|---|---|---|---|
| 15:45 | RAID_BOT | (11712, 7776) | ~16k |
| 16:20 | STANCE_BOT | (2152, 3608) | 16k: 141 winds, 62 mexes; RAID_BOT's grid recovery fired for 11 grids at 16:58-17:08 |
| 18:05 | RAID_BOT | (9056, 12256), 15.6k cluster | ~38k |
| 18:20 | STANCE_BOT | (2464, 1472) | — |
| 18:45 | RAID_BOT | (9056, 12256) again | ~23k |

- STANCE_BOT had 5-7 Saviors (cormabm) from 12:00, the last built 14:04. So the Savior in question had stood for minutes, not seconds.
- `defense_crew.Stockpile` orders up to `ANTINUKE_STOCK` (3) missiles per anti-nuke on every update. With COVER on and BUILD_ANTINUKE off, it stockpiles from the moment the Savior exists. Energy never stalled (stall_e 0.00 all game).
- That leaves likely causes for a late charge:
  - (a) the Savior was ordered to a new cover point and charged/moved;
  - (b) the stockpile build itself is slow;
  - (c) several Saviors split the stockpile resources.
- **To check next:**
  - log `GetUnitStockpile` (have, queued, build %) per Savior every 30 s;
  - read a Savior's stockpile time from its def;
  - give the Savior nearest the most valuable cluster (or the one an enemy silo can reach) priority;
  - and when an enemy silo is seen, make sure every anti-nuke has at least 1 ready before any extra.
- Also: STANCE_BOT never logged `first_enemy_nuke`, so it never saw RAID_BOT's silo, while RAID_BOT saw STANCE_BOT's at 13:00.

### 2. Too few Shurikens early; too many air cons (user: ~0 Shurikens at ~10 min, tons of idle air cons, "something orders more cons than needed")

| Minute | 6 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|
| RAID_BOT Shurikens alive | 2 | 4 | 6 | 6 | 4 | 17 |
| STANCE_BOT Shurikens alive | 6 | 11 | 20 | 24 | 30 | — |
| RAID_BOT T1 air cons (corca) | 13 | 36 | 51 | 69 | 69 | — |

- At 10:00 RAID_BOT had 79 mobile builders, with 2.1k build power idle (~38 air cons' worth). At 9:00 it was 3.3k.
- **Cause found:**
  - The air lab status read "aircons free 0, ordered 2" in essentially every minute row from 3:45 to 14:45.
  - `KeepAirConReserve` wants `#freeAirCons + ordered >= pendingGrids + AIR_CON_RESERVE (2) + nano crew want`. It counts only cons in `freeAirCons`.
  - The idle cons sit in other roles: fusion helpers (41 rows), grid helpers, the nano crew, the spine. They never show as free, so it re-orders 2 cons forever.
  - With an air con always ordered, `WG.TileLabHold` holds the first T1 air lab all game. The lab controller then puts nothing in it except during a raid. Before 11:00 RAID_BOT's corap got 0 floor-Shuriken orders, only raid answers (15 Shurikens + 20 fighters).
- **To do:**
  - count idle air cons (alive, not building, not moving to a job) toward the reserve;
  - cap air cons per open grid / helper job;
  - never let the con hold block the standing Shuriken floor.
  - The Shuriken-floor priority added after this game only helps a lab that isn't held.
  - The second air lab (finished 9:54) was the only lab free to build them.

### 3. Second T1 air lab came too late (user: start earlier; all nearby nanos should work on the reclaim and the lab)

- **Timeline:**
  - it waited for the line to finish (`SlotsRemaining` > 0 until 8:34);
  - its con came at 8:36;
  - one air con reclaimed 6 winds and built 4 nanos, then the lab;
  - it finished at 9:54 (78 s).
- **To do:**
  - start it around 5-6 min whatever the line's state;
  - put every line nano within reach on the reclaim (`NANO.Reclaim`) and then on guarding the lab frame;
  - build the lab before its own nanos;
  - mark the slots `reserved` before the line builders reach them.

### 4. The line was damaged and its nanos never rebuilt (user: lost line nanos meant less build power for new air cons; only the nanos around the T1 air labs matter)

| Minute | 10 | 12 | 14 | 16 | 18 |
|---|---|---|---|---|---|
| RAID_BOT line nanos | 14 | 7 | 7 | 7 | 7 |

- From 12:00 lane 2 also kept 4 slots empty ("L2 left4") for the rest of the game.
- **Cause:** line slots are only rebuilt by their lane's builder (`line_crew.OnUnitDestroyed` frees the slot). After the line is built the builders are released, so nobody rebuilds anything.
- **To do:** a line-recovery job like the grid recovery. Watch the nano spots (and the lab-nano slots) within reach of each T1 air lab. When one is empty for two looks with no raid near, a free air con (or a T2 con) rebuilds it. Lane mex/wind slots are lower priority.

### 5. Other problems found in the game

- **Flak flood after the late stance.**
  - Army at 20:00: corsent 60 units (25% of army value) against a 5% share.
  - `raid_late` (taken at 17:42, unit cap 75%) contains corsent as the only unit a T2 vehicle plant can build. The stance pick takes the most under-share unit the lab can build, so every coravp order became flak.
  - corgant (Demons) and coraap (Dragons) were fine.
  - Fix options:
    - `positiveOnly` picks for labs whose units are a small share;
    - let slot_spine reclaim or idle labs the new stance barely uses;
    - or keep the ground AA out of the late stance and size it by a separate rule (e.g. against enemy air value).
- **Wasps are heavy.** corape was 37% of army value at 15:00 (54 units), from raid response plus guards. Check whether the raid-answer Wasp orders (need = 2x raid value) re-trigger on every new raid.
- **Grid recovery worked.**
  - It made 16 recoveries; each grid was recovered once, so no loop.
  - Every re-run was picked up by a con within ~1 min.
  - The first came at 11:48.
  - At 20:18 three retrofitted grids (22 spots each) were re-opened for retrofit; that was the end-of-game self-destruct, not a real loss.
- **Hawk pool.** It kept 2-3 Hawks from 15:00; 13 pool orders, 4 scout-call rows. Scout calls are rare because few groups were out at once. Check the routes in the replay.
- **Result.** STANCE_BOT won on phi (army 142k vs 107k) while RAID_BOT had more income (2614 vs 1972). Part of RAID_BOT's army value at the end was the 60 flak.

### Changes made 2026-10-14 (stub tests pass; no in-engine game yet)
- **Nuke/Savior (user: the victim had expanded into a new spot and its Savior was too late; stockpile logic is left alone):**
  `defense_crew` `COVER_UNFINISHED` counts structures under construction in the cover plan, `COVER_PERIOD_SILO` 150 re-plans faster
  once an enemy silo is seen, and a `cover: Savior <id> at (x, z) goal_dist N` row is logged every 30 s.
- **Air cons / Shurikens:** `line_transition` `RESERVE_COUNT_IDLE` counts every idle air con toward the reserve (RAID_BOT on);
  `lab_controller` lets the standing Shuriken floor (`RAID.SHURI_STANDING`) go ahead of owed air cons in the held T1 air lab.
- **Second air lab:** `LAB2_FRAME`/`LAB2_LATEST` 5:30 (RAID_BOT) so it no longer waits for the line; `LAB2_NANO_HELP` has the nanos in
  reach reclaim the winds/mexes on the site and then guard the lab frame.
- **Line recovery:** `LINE_RECOVER` rebuilds line nano spots within `LINE_RECOVER_R` (700) of an air lab, after two looks with no raid
  near, with a free air con (`[LT] RECOVER line nano` rows).
- **Flak flood:** `StancePick` takes small-share units (`RAID.SMALL_SHARE` 0.10) only while below their share.
- **Not done:** Wasp re-trigger check; the new options have no dedicated tests yet (idle-con reserve, line recovery, lab2 nano help).
- **Check in the next game:** the Savior rows, Shurikens at 10:00 (was 6), idle build power at 10:00 (was 2.1k), lab 2 finish time
  (was 9:54), line nanos at 12:00 (was 7), corsent share of army at 20:00 (was 25%).
