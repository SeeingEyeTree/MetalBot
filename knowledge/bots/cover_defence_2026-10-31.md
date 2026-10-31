# CORE_v4: ROWS army + cover defence + radar ring (2026-10-30 / 31)

CORE_v4 = CORE_ROWS_ECO's army on CORE_v4's economy (nano-column block), plus three things built in this session:
- cover defence;
- a radar ring;
- the scout wing, with ground posts past radar cover.

Commits `7ddbf57` and `7f31a42` (main, pushed).

## Results vs CORE_ROWS_ECO (single client, 20 min)

| Spawns | Games | CORE_v4 result |
|---|---|---|
| default (`2816,1904;9472,10384`) | 2 (one per slot) | 2 wins (end score) |
| close (`METALBOT_STARTPOS=close`, ~7.3k apart) before the radar ring | 4 (two per slot) | 1 win, 3 losses |
| close, with the radar ring and the scout posts past radar | 4 (two per slot) | **4 wins**, all by killing ROWS's commander (15:44-16:57) |

- Finished eco lost by 10:00 at close spawns fell from 1.1-7.6k to 0.6-1.1k.
- ROWS still out-raids CORE_v4: more raid kills in most games. CORE_v4 wins on economy and on not losing its commander.

## How it got here (what was wrong, in order)

1. **v4's own stances / machine raided badly.** `v4_raid` and the T1/T2 raid stances had `army = "raid"` and nothing else. We switched to ROWS's machine (`rows_eco_legacy`) and `legacy/` stances, which have `raid_groups`, `batch` and `survive`.
   - User: "just use core rows stuff ... v4 stances were randomly made".
2. **raid_response `REINFORCE_PULL` detached every new group.** `CA.Detach` ran before the "is the group far away" test.
   - 630 of 653 launches ended "0 of peak N left after 0s": a launch-and-cancel loop.
   - Fixed with `CA.GroupCentre`: read first, detach only a unit that is really pulled.
3. **Defenders stood at the spine, chasing groups reinforcements could catch, while a raid seen only on radar sat on the flank.** Three causes:
   - radar dots were dropped by raid_response;
   - ground units had a dead zone at 850-1500 from the eco;
   - every standing position was on the home→enemy axis.
   - **Cover defence** (below) replaced that.
4. **FIGHT and ATTACK orders let raiders walk past.** User: "the units will stop and keep firing but the enemy units can just walk past". Cover uses MOVE only: to the line, to a cut-off point on the path, or to a chase point on a raider's path re-aimed every second.
   - Finished eco lost by 14:00 vs ROWS fell from 7-17k to 2.2k.
5. **Close spawns: attacks came into view too late.** At ~7:26 in one game an attack only came into view when it was too late to respond.
   - Two bot cons at ~5:50 now build a radar ring.
   - Ground scout posts moved past radar cover. User: "if they are in radar range they are not doing anything".
   - Close-spawn record went from 1 of 4 to 4 of 4.

Tried and removed: **slow defenders**, i.e. Pounders and Tzars made while defending a threat at the spine, 6-12 per fight, 40 at most.
- They worked, but 20-30 Pounders piled up at the labs.
- The user said: "get rid of it for now it is not worth trying to fine tune".

## Cover defence (`bar_framework/cover_defence.lua`, raid_response `COVER`)

When `RAID_RESPONSE.COVER` is set, the ground answer to every enemy group on our side goes to this planner. raid_response keeps air raids, Shuriken stuns and Wasp splits.

- **Threats**
  - What counts: TM contacts, plus radar dots. A dot's type comes from `EI.GuessType`: the most common seen enemy type fast enough for its speed. An unknown dot counts at 1.25x ("not knowing what it is makes it a bigger threat").
  - Lone scouts under 120 are ignored.
  - "Our side" = our half of the map, or within 3000 of the eco.
  - Clustered within 700 and tracked between ticks.
- **What it can hit**
  - The threatened point: the nearest eco point in a ±60° cone of the threat's heading (`MM.BaseNearestInCone`).
  - Time to reach it.
  - What production could bring in that time. Only near a lab, shared between threats, and counted only for the launch gate.
- **Assignment**
  - Defenders worth 1.2x the threat, filled in slack order (time the threat needs minus time our nearest free unit needs).
  - Drawn from units in no attack group: stage, new production, muster, home guards.
  - Running raid groups are never recalled.
- **Modes**
  - *line*: MOVE to slots across the approach, in front of the threatened eco. Pushed out 300 every 6 s while the threat doesn't attack.
  - *cut*: the threat is moving at the eco. MOVE to the first point on its path the defender can reach.
  - *fight*: contact, a dive inside 1500, or the threat on the eco. Each defender chases one raider (MOVE to its predicted path point).
  - *convert*: the threat was pushed far out and production alone now covers it. The defenders raid from where they stand (`CA.Adopt`).
- **Launch gate.** While any threat is uncovered, no raid group launches and no batch leaves (unit_runtime `holdHome` hook).
- **mb.raid.** Only threats in fight mode count, so the share machine's "attack" node no longer fires for a line held far out.
- **Log rows.** `[COVER]` per threat every 5 s, and `[COVER] launch held`. Planner errors are caught (pcall) and logged, not fatal.

## Radar ring (`bar_framework/line_transition/radar_ring.lua`, `RADAR_RING`)

- At `RADAR_RING_FRAME` (5:00; in practice ~5:50, when the line_transition update starts), 2 T1 bot cons are ordered at the head of the line's bot lab queue.
- `LT.RadarRingOwns` keeps macro_runtime from counting them as line cons. They are registered with the con broker as "radarring".
- They build 6 radar towers, 900 outside our structures, enemy side first, and rebuild lost ones. Two new cons are ordered if both die.

## Measuring (lessons)

- **Finished eco lost.** Diff the per-minute `state_dump` snapshots (buildings gone).
  - The tracker's `lost_enemy_eco_mv` used to count unfinished frames and air scouts at full cost. It read e.g. 9.1k where 1.9k of buildings died.
  - It was fixed on 2026-10-31: build progress × cost, and eco = mex / energy / labs / nanos / cons / storage only.
- **`[IDLE]` (idle_value.lua) is not "standing still".** It means "not near a comparable amount of known enemy value". A group raiding eco counts as idle. Use it only for what it is.
- **Opening army.** CORE_v4's army is 0.92x ROWS's at 6:00 and 0.75x at 9:00 over 13 games, with metal income equal.
  - eco_sim: the nano block spends ~3k more on nanos and cons by 8-9 min. With the block off, the army matches ROWS.
  - The block pays back later: income at 10:00 in the sim is 318 vs 234.
- Single-client games swing a lot. Use slot-swapped pairs, and close spawns for the hardest test.
