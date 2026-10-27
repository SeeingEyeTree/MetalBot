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

## Opening for a blitz (user 2026-10-27): no army to 4:00, 35% after, 8-nano spam at 1.3x -- machines/rows_default.lua
The replay of the lost game (TreeServer infolog `[LED]`): army spend ~0 from 0:00 to 5:00 (share 1.0 never bound: the rows + air lab ate all metal, bank 1-10%), then a 5:30 raid; under_attack fired 46 s after first contact, the share went 1.0 but
actual army spend fell 83 -> 41 -> 9 m/s (7:00-7:30) while 76-90 m/s went to rebuilding the 16k of lost builders/nanos. 25% of income to army to 10:00.
Capacity math (ecosim/unitdefs.lua): lab 150 BP + 8 nanos x 200 = 1750 BP. Metal per build-power-second: Grunt 0.0344, Incisor 0.0522, Pounder 0.071, opening comp (6 Incisor : 1 Pounder) 0.0556.
Nonstop spend of lab + 8 nanos: Grunts 60 m/s, opening comp 97 m/s, Pounders 124 m/s. 1.3x that: 78 / 126 / 161 m/s of metal income. One nano = 200 BP ~ 11 m/s of army.
Machine `rows_default` (copy of core_default): share 0 until 4:00 (`open`), 35% from 4:00 (`start`), a `spam` node (75%) when metal income >= 126 (1.3x the opening comp's 97) until 9:00 -- slot_spine then sizes its active nanos (share x income / 11) = all 8;
spam exits under 111 m/s or at 9:00. In eco_sim the income reaches 126 at ~7:20, so spam runs 7:23-9:05: army metal by 4:00 / 7:00 / 8:00 / 9:00 / 12:00 = 946 / 5.0k / 8.3k / 13.2k / 26.7k (CORE: 1.0k at 4:00, 5.7k at 7:00).
Not changed: the first spine block still opens at 6:00 (VP2 wait) so the 8 nanos only stand from ~6:00-7:00; NANO_CAP 8 changed nothing in the sim (the need is share-driven). Income at 20:00 3.4k (6 seeds).

## After the first win against CORE_ROWS_ECO (user 2026-10-27, "gg"): spine cons and nanos before labs
User beat rows_default (much better than before: the macro is OK now; the remaining problems are the STANCE SWAP and UNIT CONTROL). One macro problem left: the spine ordered ~5 ground cons; it should build ONE, and 4 nanos must stand before any new lab.
Done (config + slot_spine): SPINE_CFG `CONS_MIN = 1, CONS_PER_INCOME = 500, CONS_MAX = 4` (con target = 1 + income/500), `EARLY_CONS = 1` until 3 labs stand or 10:00 (`EARLY_CONS_LABS = 3`, `EARLY_CONS_UNTIL`), `FIRST_LAB_NANOS = 4`,
new `LAB_MIN_NANOS = 4` (slot_spine: a spine lab waits until 4 nanos stand per lab -- placed labs + the new one -- and ThrottleNanos' `buildNeed` is raised to that so the nanos really get built; the log says `lab corlab waits for nanos: n stand, 4 wanted`).
eco_sim: first spine lab placed ~7:00 after 4 nanos stand, 8 nanos by 7:15 (was: lab at 6:17 with 3 parked nanos); no Lua errors. NOTE: `NANO_CAP` in SPINE_CFG is NOT a slot_spine option (the [CFG] warning says so) -- it never capped anything.
STILL OPEN: eco_sim still shows 2 `spine-con corcv` orders (4:16 and 4:36; lab_rules `spine-con-first`, "spine-con-first 2" in the lab broker rows of the real game) -- one of them should go; look at lab_rules SPINE_CON_FIRST / the `spine` want when you resume.
Also open (user): stance swap (the 6:00 push at start -> t1_push, back to t1_hold at 6:45 when attacked: the army leaves and comes back) and unit control; the nano / lab-capacity facts and the 8-nano spam rule are above.
Versions on TreeServer: commit after 3267ae5 (this section). Deploy: candidates/CORE_ROWS_ECO. Machine: machines/rows_default.lua (copy of core_default with open/start/spam share nodes).

## 2026-10-27: fixes from the lost game (TreeServer infolog 20261027112118, ends 10:34)
What the log showed: 5:52 the unit controller pushed (own 1.57x the *scouted* enemy, enemy was reinforcing), 6:00 FSM `start -> t1_push`, two click_army groups left for a nano 3.4k away,
the enemy raid (7 -> 24 units) hit the spine at 6:25: 80 units / 23k lost, 16k of it build power (spine nanos). 3 spine ground cons at 6:21 (spine-con at 4:22 and 5:52 + a resident corcv at 6:17).
Scouts / AA kept being queued during the raid (`air-scout-early`, `scout-ahead`).
Changes (CORE_ROWS_ECO unless noted; framework options default off):
- `slot_spine` `CON_CAP` / `CON_CAP_UNTIL`: total ground cons (residents and every order kind count) capped at 1 until 10:00 (a dead con is replaced).
- Stance `plan.support`: `false` = no scouts / radar / ring radar / AA floor, `"unless_raided"` = none while `under_attack`. Set on core_start, t1/t2 hold and push. Rez bots, raid answers, army stay. (lab_rules, `[LabCtrl] support units OFF/on`.) These stances are shared with CORE, so CORE gets it too.
- `bar_framework/av_rates.lua`: army-value derivatives. Signals `own_av_rate`, `enemy_av_rate` (d(scouted)/dt + our kills/dt), `proj_ratio` (60 s ahead). `ArmyMode` needs the projected ratio to start a push (`proj_ratio` option, default = the ratio) and >= 1.0 for a quiet raid; `rows_default` push edges need `proj_ratio` >= 1.8 / 2.0 and a push returns to hold under 0.9. `[AV]` log rows every 30 s.
- `SPINE_GARRISON = { N = 6 }` (unit_controller) + lab want `garrison` (from 4:00): the first 6 Pounders post on the two flanks of the spine (3 each, `[GAR]` rows), never go to groups or release.
- `RAID_RESPONSE = { KEEP_MULT = 1.5, INTRUDER_TTL = 450 }`: responders shrink to 1.5x the raid's value, a raid unseen for 15 s is over.
Not done: a "raids not killing BP/eco -> slow push" edge; the exact 8:00 trigger (no row was logged for it; `[AV]` / `[UnitCtrl]` rows will show it next game).
Eco sim (3 seeds, 12 min, no vacuum): income at 12:00 556-632 before / 534-632 after; one spine con instead of two; garrison 6/6 by ~8:00 in the sim.

## 2026-10-27 (2): from the won game (TreeServer infolog 20261027120905; it ran the PRE-fix code: no [GAR]/[AV] rows, 6 spine cons)
Seen: metal income only 58 -> 99 -> 168 m/s at 4:15 / 7:00 / 8:45 while energy was 700-2000 e/s; the spine's `need` hit 29-58 nanos at share 1.0 (the attack node) and the
T1 vehicle plant's army want refilled only an EMPTY queue (+120-frame grace), so the nanos idled between units; the governor then read realized 23-40% vs alpha 60% and paused eco.
Changes (CORE_ROWS_ECO; all framework options default off):
- `ARMY_QUEUE_MIN = 2` (lab_rules): the army want tops up (mode topup, depth max(QUEUE_DEPTH, 2), grace 30 f) instead of waiting for an empty queue.
- slot_spine `NANO_SHARE_CAP = 0.6` (nanos sized for at most 60% of income, the governor's cap) and `NANO_BUILD_UTIL = 0.45` (no new spine nano while < 45% of the standing ones build; `[SLOT] nano gate` row).
- line_transition `GOV_KEEP_GRIDS = true`: the governor's eco pause no longer stops mex grids (builders, new grids, helpers); `GOV_ROWS = false` (rows keep getting cons). Retrofits, consolidation, energy, silos still pause.
- `UNIT_SWAP = { corgator = "corraid" }` (macro_controller -> strategy -> stance_loader Prepare) + `VCHEAP_UNIT`/`VP_FIRST_UNIT = corraid`: Brutes everywhere the comp or the vehicle plant's cheap pick named the Incisor.
Eco sim (3 seeds, 14 min): income at 12:00 549-706 (before 511-666); nano gate fires at 11:56+ (T2 phase).
- (3) `NANO_CREW_PAUSE_SHARE = 0.5` (line_transition / nano_crew.lua): screenshot at 9:35 showed 36 grid nanos (8k metal) and almost no grid eco. The crew now stops, releases its cons (STOP) and recruits nobody while the governor holds eco paused or the spine's army share >= 0.5 (held 20 s: `NANO_CREW_PAUSE_HOLD`); `[LT] nano crew paused` row. Not covered: nanos the grid builders place from their own blueprint (GRID_START, balance rule) -- the 10/27 log had no crew->grid assignment row, so some of those 36 may be those.
- (4) From the 13:17 game (TreeServer data/infolog.txt, ran the first deploy): the garrison stayed 0/6 all game -- Pounders were taken by the maneuver blobs / slow group before the garrison check in `unit_runtime` UnitFinished (check moved ahead of them). Army starts 4:40 (rows_default edge `minute >= 4.6667`, `GARRISON_START_FRAME` 4:40), air lab back to 5:00 (`EARLIEST/LATEST_FRAME` 9000; eco_sim: 8:00 income 105 vs ~160, 12:00 equal, 14:00 1430 vs 1040-1230), gators back (UNIT_SWAP / VCHEAP_UNIT / VP_FIRST_UNIT removed), `CMDR_TO_SPINE` (commander leaves the line when lane 1 is done, stands at the spine and guards the nearest lab; no evading after), hold stances `maneuver = { R_MIN = 900, WATCH = 600, OUT_EXTRA = 400 }` (was R_MIN 1100, WATCH 1500, OUT_EXTRA 800: blobs chased up to 3.4k from structures).
  What the game showed: user AV 2171 -> 3393 -> 7273 -> 17775 at 6/7/8/9:00 vs bot 3160 / 3580 / 3000 / 2600; every [LED] fight row has killed=0; at 6:00 bot groups stood at x 5600-7000 (spine x ~3900), at 6:49 the fight at (4231,4919) cost 43 units / 6.7k (2.9k build power) while reinforcements arrived one unit at a time ("1 units -> group of 2350 [all in]").

## 2026-10-27 (3): the opening raid (plan: survive-first raids, army-only nanos)
Data (replay `teamStats`, metal USED not produced; both games): spend was even until ~6:00 / 8:00; the bot's deaths went 5 -> 192 in the minute 6:00-7:00 (13:17 game, you 20) and 13 -> 72 -> 209 at 7/8/10:00 (12:29 game). The game is lost at the first big fight, not by spending.
Changes (CORE_ROWS_ECO unless noted):
- Army from 4:00, air lab 5:30, gators, no garrison; `SPINE_EARLY = true` (and `NANO_FIRST`, `GRID_REACH`) now really applied -- they sat inside a comment before. Share `start` node 0.6.
(REMOVED 2026-10-27, user: the army-nano idea is gone from the code) - `ARMY_NANOS_FROM/UNTIL` (line_transition `UpdateArmyNanos`, 4:00-7:00): every nano in reach of VP / VP2 / rez lab / spine labs guards the army lab with the fewest nanos at PRIO.ARMY; `VP_ASSIST_SHARE = 0`. `[LT] army nanos` rows. The sim does not model nano guards (no effect there): check in a real game.
- `stances/raid_start.lua` (army raid + `survive`, gators) is the machine's start stance; recall only on bad trade / `proj_ratio < 0.9`; T2 push after 8:00 at 500 income.
- click_army `SURVIVE` (`plan.survive` -> `CA.SetSurvive`): `SURVIVE_SET` overrides (earlier escape, wider steering, defended-target penalty), dive only into a hole (`SURVIVE_HOLE_FRAC`), else stand off / step back with hysteresis, hurt units (< 0.45 hp) retreat; `[CK] survive mode ON`, "steps back", "dives". NOT exercised by the sim (no enemy): first real game is the test.
- Opening config (`unit_controller.lua`): `HOME_DEFENCE.EARLY_MAX = 0`, `MECH.HOME_GROUND_AFTER = 3` (+ share 0.15, max 4), `CLICK_ARMY` (launch from frame 0 at 130 AV, groups of 2, 2 groups, stage 0.12, `UNSEEN_FIRST`), `HOLD_HOME` (new production stays home while a ground raid >= 300 is on the base), six ground scouts first (`SCOUTS_FIRST = 6` want in lab_rules, `FIND_SCOUTS = 6`, no air scouts), `scout_lanes.NextUnseen`.
eco_sim (4 seeds, 14 min): groups launch at 4:18 / 4:28; army spent by 6:00 5.8-7.1k (was 1.5-3.8k); income at 14:00 705 (air lab 5:00: 851; air 5:00 and no SPINE_EARLY: 1124). The user accepts the income cost.

## 2026-10-27 (4): after the first opening-raid game (won, "better")
Seen in the log: `ESCAPE to the line front` sent groups to a fixed point whatever the enemy did and ENDED them ("escaped: 8 of peak 10"); `dives: a hole (defence 0 vs core 678)` then `COMMIT` (attack orders); at 6:32 `start -> t1_hold` (proj_ratio 0.44) turned survive off and pulled the raid home; all 5-7 line nanos were army nanos, lanes 2-4 sat at m4/w3 for 3 minutes, metal banked 900-1350 from 4:00.
Changes: click_army SURVIVE -- `EngageSurvive` (no commit, no ending: evades to the least-threat of 12 headings round the core, shuns the target 60 s, keeps raiding), orbit the target (always MOVE, never FIGHT / ATTACK; SET_TARGET shoots), no core-wait stop, `FALL_FRAC = 0` (a group ends only when empty), `SURVIVE_HOLE_FRAC` 0.35 -> 0.10. `RAID_SQUAD = { N = 5 }` (unit_runtime `NET.sq`): while the army holds, 5 gators are taken out of the blobs and commanded by click_army alone (`CA.SetOnly`, survive on), refilled by the `raid-squad` lab want, kept out of the handover when raiders are already out. `ARMY_NANOS_KEEP_LINE = 2` (the 2 nanos nearest the line's builders are not claimed while the line has slots left). Air lab 6:00.
Tested only in eco_sim (no enemy): `[CK] EVADES` fired, squad path ran under a forced t1_hold with 0 Lua errors (a real bug found that way: ManeuverPlan used before its definition).
- (5) `FAST_RAIDERS` (unit_runtime option, on in CORE_ROWS_ECO): unit_clock FAST tier (10-frame period, `FAST_HOLD` 60) and army_broker `ORDER_FAST_INTERVAL` 10 (was 30 for HIGH, which capped raiders at 1 Hz whatever the tier). `ARMY.SetFastFn`: units in click_army groups, the raid squad and raid responders go FAST while an enemy is near them; groups and responders are also re-planned at frames 10 and 20 of each second. eco_sim: no errors, `fast=` in the `[UC/army]` row (16 at 8:00, 77 at 12:00); orders issued by 12:00 24.9k vs 18.1k (+38%), by 10:00 10.5k vs 8.8k.
- (6) Float fix (eco_sim 8 seeds, `scratchpad/sweep.py`: army spent by 6:00, average bank 4:00-7:00, income 8/10/12): the 4:00-5:00 float was `LINE_NANO_CAP` (max 4 line nanos; bank ~1000 vs ~180 without it) and `ROW_START_FRAME` 5:00 (rows need air cons, the air lab is at 6:00, so the eco had nothing to build from 4:30). Now no line nano cap and `ROW_START_FRAME = 0`: army6 5.76k (36%), bank ~110, income 170 / 228 / 358 (was 124 / 183 / 297 with army6 5.8k). `ARMY_NANOS` has no effect in the sim (it does not model nano guards). Army nanos are now capped at line nanos - `ARMY_NANOS_KEEP_LINE` (2) while the line still builds. Group raiders: `MIN_GROUP_UNITS = 1`, `EARLY_LAUNCH` ramp starts at 4:00 (130 AV), so one or two gators launch at once (4:18) instead of waiting for five.
- Home guards: `HOME_GROUND_AFTER` 3 free units, then ~15% (max 4) stand at posts 550 from the base (fight order, leash 250) and answer raids inside 700 (raid_response); staged units only walk to the stage point and idle.
