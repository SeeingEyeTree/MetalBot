# paintkid replay (2026-10-09_17-52-07, Full Metal Plate) -- what the human did, 2026-10-12
Read with `node replay_commands.mjs <sdfz> out.json` (human commands) + `replay_analysis.py` (team stats).
- Spawns: paintkid (Armada) (1932,6082), MetalBot (9230,5857): ~7.3k apart, NOT the corner spawns. `METALBOT_STARTPOS=paintkid` reproduces them.
- Opening: mex + 6 wind, armlab (first bot lab) at 0:15, 5 cons 0:31, **armpw (Pawn) on repeat from 2:37**, 1 nano at 1:54, 6 more nanos beside the lab 2:48-2:56 (the lab is never reclaimed).
- Eco: mex/wind grids as 8-wide rows (24 mexes at 1:34, 32 at 3:51), more winds; income ~65/s 4:00-7:30, ~120/s to 10:00, peak 198. MetalBot made 523 peak and 82k metal vs his 42k -- and lost.
- Army orders: only MOVE. A lone scout loops the enemy base 2:34; first army push 4:09 (9-34 selected), again 5:00, 5:52, 10:13 (76 units).
- Production switch ~6:12: 26 nanos in two columns, 6 armvp from 7:28 (armflash/armpw later).
## Why the copy lost (fixed in candidates/PAINTKID_BOT)
1. Corner spawns (12.8k) instead of ~7.3k.
2. 15 Grunts at 4:00 sat home as the garrison (HOME_GROUND_MIN 3 / MAX 8) until 7:20 -> now 0/0.
3. Army share 50% from 4:00 + forced gator nanos froze income at ~45 m/s (v16: 134 at 7:00) -> share starts 6:00 (paintkid's switch).
Result (15 min, close spawns, vs v16): end_score win, army 401 units/39.6k vs ~0; income 841 vs 939.

## DIRECT behaviours added to click_army.lua (2026-10-12, PAINTKID_BOT only; CFG.DIRECT_*)
Shared target held 1200 frames (was re-picked every 450 -> the army zig-zagged). Per unit (uid-sorted index decides the job):
flank = every 6th unit (>=12 units) MOVEs to a waypoint 2600 off the line then FIGHTs a second target; run-by = big army
(>=40 units or av >= 3x enemy av at target) sends every 2nd unit on MOVE past the defence until 700 from the target; spread =
no resistance (enemy av at target AND around the army <= 15% of ours) every 2nd unit splits over the top targets (>=12 units each);
the enemy commander in the open (CommanderTarget) pulls ALL units. Log: `[CK] direct jobs` every 30 s, `ENEMY COMMANDER open`.
Games vs v16, paintkid spawns, 15 min: before the commander rule 0-3 (v16's eco: peak 1.4-2.5k m/s vs our 0.5-0.75k, so it
wins end_score on income even when our army deals more damage); with it 2-1 (one real commander kill, 13:57 -> 14:22).
