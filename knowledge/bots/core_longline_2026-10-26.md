# CORE_LONGLINE (2026-10-26)

CORE with a longer line phase: 10 lanes (4 + 6 extra on the side away from the enemy, 3 bot cons share each), 32 columns (was 16), no air lab.
The 4 old lanes, the line nanos, the commander's 2 energy storages (`ESTOR_KMAX = 15`) and the rez / T2 bot / decoy sites (`SITE_K_LAST = 15`) stay where they were.
VP, VP2 and their nanos are kept; with `AIR_LAB = false` the spine starts once the vehicle lab has a site. The mex-grid transition is NOT done (no air lab, no grids).

Options (all default off): macro_runtime `EXTRA_LANES`, `LANE_CONS`, `LINE_K_LAST`, `SITE_K_LAST`, `ESTOR_KMAX`; line_transition `AIR_LAB`; line_crew `LC.AddLanes`, `LC.SetLength`, `LC.LANE_CONS`.
`eco_sim.py --set macro.KEY=value` now overrides macro options (global `SIM_MACRO_OVERRIDES`).

## eco_sim (6 seeds, --no-vacuum; sweeps ecosim/sweeps/longline1-4.json), median income m/s at 8 / 10 / 12 / 14 min
- CORE 100 / 180 / 528 / 1046; CORE_LONGLINE (5 s gap, no income gate) ~171 / 365 / 506 / 623.
- Open lanes as early as possible: 5 s gap 171/363, 20 s gap 155/264, 30 s 137/237, income ramps 126-133/205-231.
- 3 vs 4 vs 5 cons per lane: within noise. 10 lanes > 4-7 lanes. Long line with 4 lanes only: 123/170/245.
- CORE passes it by 12 min because its air lab opens the mex grids. Next step: a grid transition for the long line (grids behind the new LINE_BOX, spine already starts).
- The first long walk to a far lane takes minutes: `moveTimeout = 600 + 2 * distance` frames.
Real game not run.

## CORE_ROWS (same day): rows that scale
`candidates/CORE_ROWS` = CORE_LONGLINE without the fixed 10 lanes. The 4 lanes stay; when a con has no free lane `LC.GrowRow` (line_crew) makes a new row on the away side:
two halves (`row<i>E` / `row<i>W`, `ROW_COLS` columns each, 24) that run east and west from the middle of the line, `ROW_CONS` (3) cons per half working on the same item.
Slots off the map are dead (`LC.MAP_MARGIN`); a row with no usable half stops growth. No con past `ROW_UNIT_FRAC` (0.5) of the unit cap. T1 phase only (no air lab, no grids).
eco_sim (rows1.json, 6 seeds): con every 5 s beats any metal-bank gate (income at 10:00: 358 vs 288 / 283 / 220 / 181 for bank 100 / 150 / 300 / 600); 24 columns > 16 > 12; 2 cons per half ~ 3; 4 worse.
Final: 8:00 / 10:00 / 12:00 / 14:00 = 162 / 359 / 532 / 738 m/s (CORE 100 / 180 / 528 / 1046), 11 rows by 14:00. Real game and the off-map rule not run.

## CORE_ROWS3 and where the mex-grid transition belongs (eco_sim, 6 seeds, 16 min, no vacuum)
`candidates/CORE_ROWS3` = CORE_ROWS with `ROW_MAX = 3` (3 grown rows = 6 halves of 24 columns, 3 cons each, on top of the 4 lanes; 640 slots, 4 + 6 lanes, 28 cons). All three rows are made by 6:40.
Income m/s at 8/10/12/14/16: 160 / 321 / 386 / 472 / 502 (it tops out at ~509 once every slot stands, 15:00).
- Slots still unbuilt: peak ~300 at 7:00 (after row 3 opens), ~200 at 9:00, ~140 at 10:00, ~65 at 12:00, ~10 at 14:00, 0 at 15:00 (a seed spread of +-3 per minute).
- Original 4 lanes finish 9:30-9:50; the row halves 11:00-15:00.
- Metal bank: 1-3k at 9:00, 4-7k at 10:00, 12k at 15:00 (floating from ~10:00). Pull/income stays ~1 until 14:00, then pull falls to ~0.4 of income.
- Build power: idle 6% at 9:00, 31% at 10:00, 42% at 11:00, 54% at 15:00. The line cannot use its BP from ~10:00 (slots left < ~150).
**Point for the transition: ~9:00 (unbuilt line slots ~200 = ~30% of 640, bank crossing ~2k, idle BP still ~6%).** The grid chain (air lab + cons walking out + first cells) needs ~1-1.5 min before it can take metal, so opening at 9:00 has it ready as the line runs dry at ~10:00.
A bank-based trigger (bank > ~2k and slots left < ~200) or a slot-left trigger (LC.SlotsRemaining <= 30% of the line's slots) both fire in 8:40-9:30 across seeds; neither is implemented. In a real game the army competes for the metal, so the bank would float later: re-check the trigger there.

## CORE_ROWS4: one-way rows + the air lab back (user 2026-10-26)
`candidates/CORE_ROWS4` = CORE_ROWS3 with `ROW_BOTH = false` (each grown row is ONE lane of `ROW_COLS` = 32 columns running east, 3 cons; `ROW_MAX` 3) and the air lab on again at 8:00
(line_transition `EARLIEST_FRAME` = `LATEST_FRAME` = 8:00). New: `SPINE_EARLY` (spine starts once the vehicle lab has a site, so a late air lab does not hold the army back; CORE's spine started
when the first grid opened), `LINE_BOX` now includes the rows `ROW_MAX` will grow (grids land beyond them). Lab is built on lane 4 (away side); first grid cell goes beyond the rows.
eco_sim (ecosim/sweeps/rows4.json, 6 seeds, 18 min), median income m/s at 8 / 10 / 12 / 14 / 16 / 18:
- CORE 100 / 180 / 528 / 1064 / 1827 / 2603
- lab at 6:00 (now CORE_ROWS4's setting) 147 / 210 / 492 / 1228 / **1901** / **2885** (best; beats CORE from 14:00)
- lab at 7:00 148 / 211 / 308 / 880 / 1718 / 2090
- lab at 8:00 147 / 224 / 302 / 832 / 1624 / 2008 (the lab takes ~70 s to build, grids open ~9:10)
- lab at 9:00 / 10:00 147 / 237 / 272 / 526 / 1414 / 1882 and 254 / 290 / 326 / 329 (stalls: the rows run dry long before the grids start)
- 6 rows + lab 8:00: 152 / 258 / 378 / 966 / 1654 / 2065 (a little better than 3 rows). 6 rows + lab 9:00 flatlines at 550 from 14:00 (not investigated; likely a stuck grid or a con wedged).
Reading: with 3 one-lane rows the line holds ~480 slots and runs dry ~8:30-9:00, so the lab belongs at ~6:00-6:30 (rows3 had 640 slots and wanted ~9:00). Rule of thumb: lab queued when ~35-40% of the line's slots are still unbuilt.

## CORE_ROWS5: nano-first grids + bridge nanos (user 2026-10-26)
`candidates/CORE_ROWS5` = CORE_ROWS4 + line_transition `NANO_FIRST = 2` (every grid's first jobs are 2 nanos, in chain order: a nano a finished nano reaches first, then each next the nearest the one before;
interrupt `nano_first`, priority 5; the first grid uses GRID_START eco 0 / nanos 2) and `GRID_BRIDGE` (a new grid none of whose nano spots a finished nano reaches: its con first builds a bridge nano =
the nearest unbuilt nano spot of another grid that IS covered (taken off that grid's queue, `GRID_BRIDGE_RANGE` 700), so the standing nanos assist it and it then reaches the new grid; log `no nano reaches it`).
Code: grid_core `X.NanoFirstQueue`. eco_sim (6 seeds, 18 min) vs ROWS4: income 144/209/450/1140/1934/2881 vs 144/210/492/1220/1953/2862 (8/10/12/14/16/18 min) = no measurable difference;
nano spend in 12:00-14:00 +60% (30 -> 48) but the grids' 7th nano is not earlier (grid 2: 12:47 vs 11:26, grid 1: 10:36 vs 10:52). The sim cannot show a gain from earlier build power here (BP is not the limit).

## CORE_ROWS6: grids open only when a finished nano reaches them (user 2026-10-26)
`candidates/CORE_ROWS6` = CORE_ROWS5 with `GRID_REACH` (grid_core `X.GridReachable`: after the first grid a cell opens only if a FINISHED nano reaches one of its nano spots; waits `GRID_REACH_WAIT` frames,
then opens the best cell anyway) instead of the bridge nano (`GRID_BRIDGE = false`). With it the first nanos of a grid face its free neighbour cells (one nano per neighbour), so the next cell becomes reachable sooner.
eco_sim (rows6.json, 6 seeds, income at 18:00): gate off 2890; wait 20 s 2774; wait 60 s 2858 (the setting); wait 120 s (first try) 1722 -- the second grid waited ~2 min for the first grid's nanos.
Fewer air cons (same sweep, all vs base 1722 with the 120 s gate): AIR_CON_RESERVE 1 -> 1656, 0 -> 1319; NANO_CREW_SIZE 6 -> 1724, 4 -> 1616; GRID_START cap 1 -> 1637: no gain from fewer air cons anywhere; reserve 0 is clearly worse (the air-con floor matters).
Line cons idling (rows6b logs): per status row 2-3 of 12 builders idle; the commander lane's builder after its lane is done, and a nano-lane con when LINE_NANO_CAP (4 nanos until 7:00) blocks its nano work; row cons mostly walk (24 columns of stops) rather than idle.

## Shared lanes: guard the leader (user 2026-10-26)
The first version made the cons of a shared lane give themselves the SAME build order as a mate (or REPAIR its frame) -- only when the mate's item was in reach of where they stood, so cons that arrived
staggered never met, and a duplicate build order is not the normal way to help. Now (line_crew `Decide`/`Step`, phase `guard`): the con that started an item is its leader; a lane-mate with nothing to do
GUARDs it (follows it and assists what it builds) and keeps guarding for 2 s while the leader is between items, then picks its own slot. eco_sim: leader + 2 guards per row lane (status rows `L5:build, L5:guard, L5:guard`);
income 18:00 2708 (6 seeds) vs 2815 before -- noise. Real game not checked.

## CORE_ROWS_ECO: pure scaling, no army (user 2026-10-27) -- and a bug it found
`candidates/CORE_ROWS_ECO` = CORE_ROWS6 + `ARMY_SHARE_FIXED = 0` (new macro option: the army share is always this; nil = the machine) + no Dragon sink (macro and lab `SINK = false`), air lab at 3:30.
Scouts / AA / raid-response floors still make their few units. `ARMY_SHARE_FIXED = 0.35` gives CORE's opening share back (eco_sim: 2996 at 20:00 -- the army costs a third of the income).
**Bug found**: line_transition `UpdateWait` returned before claiming the air-lab site while `frame < EARLIEST_FRAME`; a line that finished before the lab's time (fast line, nano cap off) ate every open
slot of lane 4 ("no 6 open slots (3x2) left in an outer lane") -> no air lab, no grids, income flat at ~380-470 for the rest of the game (about 1 seed in 3 of the diagnostic sweeps, incl. rows6 lab9 / lab10 earlier).
Fixed: the site is claimed (reserved) early, only the order waits for EARLIEST_FRAME.
eco_sim, income at 20:00 (8 seeds, rows_eco_lab*.json): lab at 2:00 8114, 3:00 8648, 3:30 8594, 4:00 8447, 4:30 7842, 5:00 7232, 5:30 6032, 6:00 ~5200, 7:00 4506; STANCE_ECO2 (old target, same sim) 7142-7443; CORE 4062; CORE_ROWS6 (with army) 3986.
Income at 12 / 16 / 18 min with lab 3:30: 1277 / 3767 / 6166 (STANCE_ECO2 956 / 2751 / 4560). Toggling CORE's extras one at a time (nano caps, decoy/rez/T2 labs, VP2, reach gate) moved it 5.2k -> 6.1-6.7k each; all off 6.6k with lab 6:00.
So the old 7-7.6k target is hit and passed in the sim (the sim is ~1.3x optimistic at 18-20 min: STANCE_ECO2 real 6.6-8.2k, sim 7.1-8.0k).

## CORE_ROWS_ECO with a 20% army share; first real game (user 2026-10-27)
Real game (bot_testing --server single, vs INACTIVE_BOT, 12 min, lab at 3:30, no army): no Lua errors, no desync, air lab queued 3:30 / up 4:00, first grid cell 4:00; the shared-lane guards work
(`L5:build, L5:guard, L5:guard`); metal income 3 / 5 / 7 / 9 / 11 / 12 min = 30 / 64 / 157 / 308 / 773 / 1252 m/s (eco_sim 28 / 69 / 154 / 329 / ~680 / 1470: sim ~1.15x optimistic at 12 min).
Early-game math (eco_sim per-minute rows + unit costs): a mex 50 m + ~500 E, ~1870 build time = 22 s of one con (BP 85) -> +2.37 m/s; a wind ~43 m, ~1680 BT = ~20 s; a mex + wind pair costs ~93 m, takes ~42 s of one con and pays its metal back in ~40 s,
so each con adds ~0.056 m/s per second until metal limits it; a nano (230 m, BP 200) adds ~0.13 m/s per second of assist. Income grows ~x1.5 per minute from 3:00 to 7:00 (28 -> 154), then the grids take over (x1.7 per min at 8-10:00).
Army share (eco_sim, 8 seeds, income at 20:00, lab 3:30): 0% 8900, 10% 7716, 20% 6809, 35% 5440 -- about -20% income per +10% share.
**With ARMY_SHARE_FIXED = 0.2 the air lab belongs at ~4:00** (2:30 6342, 3:00 6647, 3:30 6809, 4:00 7068, 4:30 6374, 5:00 5472, 6:00 4388; the peak is broad, 3:00-4:30 within noise); with no army it is 3:00-3:30. Set to 4:00.
