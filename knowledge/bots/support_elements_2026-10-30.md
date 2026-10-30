# Support elements for army groups (2026-10-30)

User request: support units (ground AA, a Grunt "spam" lab, rez bots, a mobile anti-nuke, a jammer, periodic air scouting) do not belong in a
stance. A stance builds its units all game as a share ("a flat 10% flak"), but support wants a fixed number per group: "when there are like 6
for a group it has enough aa support and more do not need to be made". So: an army-group structure that the stance fills, plus a checklist of
support elements that each group kind opts into. Branch `support-elements`; on in CORE_ROWS_ECO.

## What was built

| Piece | File | What it does |
|---|---|---|
| Group records | `bar_framework/army_groups.lua` | One record per click_army attack group (`raid`, or `slow` for the slow group) plus the `stage` (id 0, the pool). It follows `CA.Groups()` every army tick: centre, value, target, axis to the target / enemy base. A group that falls sends its support units to the pool; a new group fills from the pool first, nearest first. |
| Opt-in | unit_runtime option `SUPPORT`, stance `plan.group_support` | `{ raid = { aa = { n = 3 }, spam = { n = 6 }, scout = { every_s = 30 } }, slow = {...}, stage = {...} }`. An entry may be `aa = 4` (n), `aa = true` (the element's own N) or a table (extra keys are the element's cfg). |
| Elements | `bar_framework/support/<name>.lua` | `aa`, `spam`, `rez`, `antinuke`, `jammer`, `scout` (table below). A new element is one file plus its name in `army_groups.ELEMENTS`. |
| Ownership | army_broker roles `SUP_AA`, `SUP_SPAM`, `SUP_ANTINUKE`, `SUP_JAMMER` (PRIO.LINE) | click_army's `Members()` skips these roles. Element units are never in `combatUnits`, so the raid response / muster / home guard do not take them. They count in `mb.armyValue`. |
| Production | lab_rules `group-support` (prio 96, ahead) and `spam-lab` (topup) | Reads `WG.MetalBot.support[el] = { want, have, made, picks }`. Room = want − have − (ordered − made), the garrison rule. Want = n × group slots (raid = click_army `MAX_GROUPS`, slow = 1 while the slow group is on, stage = 1), so the labs fill the elements for groups that are not out yet, and the units wait in the pool. `SUPPORT_FROM_BUDGET` (default true) charges each order to the army-share budget: support is part of the army. The rez floor's room grows by the rez element's want. |
| Spam lab | `bar_framework/line_transition/spam_lab.lua` (`SPAM_LAB*` in `LT.CFG`) | A T1 bot lab + 4 nanos, built once a record opts into spam and income / clock allow. Site: a free 3x2 block on the line with two nano columns, else just past a lane's end (the line is full by the grids phase). Never built by the commander. Published `WG.SpamLab`; `lab.only = "spam-lab"`; nanos guard it (nano_broker SPINE prio, re-guarded every 10 s). |

| Element | Units | Behaviour (first attempt) | cfg (defaults) |
|---|---|---|---|
| `aa` | flak truck (`aa_flak_truck`, corsent) once any of our labs can build one, else the Lasher (`aa_t1_veh`) | FIGHT on a spiral BEHIND the group centre. A new AA unit goes to the base screen (GROUND_AA) until the screen has its share, then to the elements, then to the shared escort. | N 6, BEHIND 300, SPREAD 60, PICKS |
| `spam` | Grunts born in the spam lab (no other Grunt) | FIGHT AHEAD of the group centre (vision, shot sponge); in the pool, MOVE to the stage | N 6, AHEAD 500, SPREAD 90, UNIT "grunt" |
| `rez` | adopts existing rez bots (rez_crew members) | rez_broker job `group` (prio 70, urgent), only for adopted bots: repair a damaged friend within REPAIR_R of the group, else reclaim a safe wreck there (kept while it lasts), else trail behind the group | N 3, TRAIL 350, REPAIR_R 700, GROUP_PRIO 70 |
| `antinuke` | Savior (`savior`) | MOVE BEHIND the group; defense_crew still stockpiles it but no longer moves it (`WG.ArmyGroups.Owns`). Only once an enemy silo is scouted (`SILO_ONLY`). | N 1, BEHIND 200, SILO_ONLY true |
| `jammer` | `jammer_veh` (coreter), `jammer_bot` (corspec) | MOVE BEHIND the group centre | N 1, BEHIND 100 |
| `scout` | none | every `every_s`, `SN.RequestScout` over the group's target (else AHEAD of it), keyed per group, `untilMode = "arrive"` | every_s 30, AHEAD 1500, KIND "scout", TTL_S 25 |

CORE_ROWS_ECO's first guess (`unit_controller.lua`):
`raid = { aa 3, spam 6, scout every 30 s, jammer 1 }`, `slow = { aa 6, rez 3, antinuke 1, jammer 1 }`, plus `SPAM_LAB = true` in `macro_controller.lua`.

## Checks

- `order_check.py check`: STANCE_ECO2, RAID_BOT and DRAGON_ECO produce the same orders as the baseline (support off = no change). The
  CORE scenario and STANCE_ECO2_vac already fail on the baseline commit: CORE's machine names deleted stances, and the vac scenario
  is missing a file.
- `tests/run_tests.py --touched`: the 6 suites that fail also fail on the baseline commit (deleted stances). `check_role_names` re-saved:
  `"army_groups"` matches the `arm*` pattern.
- eco_sim, CORE_ROWS_ECO, 4 seeds, `--no-vacuum`, metal income (m/s):

  | | 8:00 | 12:00 | 16:00 | 20:00 |
  |---|---|---|---|---|
  | baseline | 228 | 468 | 806 | 1096 |
  | support on, support outside the army budget | 196 | 415 | 748 | 1002 |
  | support on, `SUPPORT_FROM_BUDGET` | 196 | 420 | 760 | 1098 |

  Early cost: the spam lab (~6:05, ~1.4k metal and a line con at ~150 m/s income) plus 3 Lashers from 4:40. Tuning knobs: `SPAM_LAB_INCOME` /
  `SPAM_LAB_FRAME`, the raid aa n.
  The sim showed:
  - the spam lab finished 24-72 s after it was queued;
  - Grunts filled 6 per raid group, then the lab stopped;
  - AA moved from a fallen group to the next one through the pool;
  - jammers came out from ~14:30 (T2);
  - scout_net served 34 support scout requests by 14:00 (0 on the baseline).

## First real game (2026-10-30, CORE_ROWS_ECO mirror, `--server single`, `--end-minutes 25`)

The game ended at 15:22 on a commander kill (team 1 won; it was a mirror, so nothing is attributed to support). No Lua error from the new
code and no Sync error. Replay: `2026-10-30_05-57-16-145_Full Metal Plate 1.7_2026.07.04.sdfz`.
- **Spam lab.** Both sides placed it past lane 1's end; the line had no free block at 6:15 / 6:25. It finished at 8:49 (T0, 154 s after it
  was queued) and 7:44 (T1, 79 s); no nano helped build the frame. The Grunts were spent as intended: T0 made 38 and kept 18/18 by 14:30,
  T1 made 42 and had 5-14. Each raid group sat at about 6/6 spam.
- **AA.** Lashers filled 3 per raid group (6-10 made); some groups were at 1-2/3 after losses.
- **Jammer.** T1's first jammer joined a raid group at ~14:30.
- **Scouts.** Every raid group showed a scout request every 30 s.
- **Army roles at 15:00** (`[UC/army]`): T0 SUP_SPAM 18, SUP_AA 5; T1 SUP_AA 8, SUP_SPAM 2, SUP_JAMMER 1.
- **Not seen.** antinuke (no silo), rez and the slow kind (the raid stances run no slow group).

## Known gaps / to tune

- Maneuver-defence blobs (the `t1_hold` / `t2_hold` ring) are not group records. In a hold stance only the raid squad / raid sections
  (which are click_army groups) get support. `t2_hold` still has its flak share (`corsent` 9%, max 40) for that reason.
- Support AA does not join an air rush (`UpdateGroundAA`'s AIR_DEF pass covers only the GROUND_AA screen / escort).
- One spam lab for all groups. Its site past a lane's end is not reserved, so another builder can take the ground.
- The raid groups are fast (Incisors / Brutes). Lashers, Grunts and jammers are slower and trail behind them. The behaviour is the first
  attempt the user asked for: positions are a fixed offset from the group centre along its axis.
- The `scout` request kind `"scout"` lets scout_net send any free scout (ground or air); scout_net has no air-only kind.
- A Savior owned by a group still counts in lab_rules' `SaviorHave`, so the eco cover plan can end one short.
- `[SUP]` rows: per record every 30 s (`raid 3 value 27727 n 161 | aa 3/3 jammer 0/1 scout every 30s spam 6/6`) and a `wants:` row. Events:
  takes / +N from the pool / group gone / not wanted any more.
