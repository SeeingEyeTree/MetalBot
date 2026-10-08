# LINE_CLICK - design notes

Moved out of CLAUDE.md on 2026-10-08 (verbatim). LINE_CLICK is the main bot; start new work from candidates/LINE_CLICK.

**`candidates/LINE_HUMAN/` + `human_control_logger.lua` record how a person controls units.** LINE_BOT's macro with an empty
`unit_controller.lua`; its `lab_controller.lua` queues only the spine's construction units (`HUMAN_QUEUES_ARMY`), so the
person queues all army units and commands them. Deploy with `.\deploy.ps1 -Bot candidates\LINE_HUMAN`, play a normal game
(the logger is deployed by every `deploy.ps1`; it writes `[HCL]` rows to the infolog and to `LuaUI/Config/metalbot_human_<date>.log`),
then `python human_control_report.py` summarises orders, army pushes/retreats, fights, lab queue, selections, groups, camera.
**`[HCL] loc` rows** (added 2026-10-07) give the LOCAL picture after every move/fight/attack/patrol/stop order and every 2 s for the selected units: each ordered
unit and each enemy within 1800 elmos of one of them, with position, distance to the nearest opponent, weapon range, hp, and `we_hit`/`they_hit` counts.
`python human_kite_report.py [log]` reads them (kite steps: how far the lead unit was from the nearest enemy, step length, who could already hit whom);
`tests/test_human_logger.lua` checks the rows against a mock Spring.
Row reference: header of `human_control_logger.lua`. Redeploy a normal bot afterwards (the logger is harmless alongside a bot).

**`candidates/LINE_CLICK/` is LINE_BOT with a human-style, aggressive army** (built from the LINE_HUMAN logs and the user's
notes: win by killing enemy build power and eco, not by trading efficiently; a dive that kills a 220 m nano is worth 600-800 m
of units). Same macro; its unit controller is LINE_BOT's with the contact line and `line_fight.lua` push replaced by
`bar_framework/click_army.lua`: ground units stage at ~45% of the way to the enemy (MOVE only). Up to 3 attack groups run AT ONCE,
each on a different target (a target near another group's target scores x0.2), ranked by damage value (build power x4 + cost + eco),
ATTACK the building, fall back only when the group is spent (<30% of its peak) or has nothing left to hit. A group launches when the
army value at the stage is >= 1800 and >= 2.5x the value still walking to it (or >= 5400 regardless); with 3 groups out, new units go
straight to the weakest group. **A 4th, slow group** takes every unit slower than 55 (Mammoth `corsumo` = 23; Tigers at 69 stay fast) plus just enough
fast escorts for mass (<=35% of its slow value), so the Mammoths no longer drag the fast groups; it is on top of the 3 fast groups (4 max).
**SUPERSEDED in LINE_CLICK (2026-10-07):** the 4th/slow group below is switched off (`CA.Init{cfg={SLOW_SPEED=0}}`). Lashers `cormist`, Pounders `corlevlr`
and rez bots `cornecro` are played by `bar_framework/slow_front.lua`, modelled on the user's own games (`human_control_logger.lua` + `human_kite_report.py`).
**AGGRESSIVE (user, after the first in-engine run):** the Lashers ALWAYS carry a **FIGHT** order toward the nearest enemy in sight (else in 800 legs toward the objective: the
richest wreck field ahead, ending 250 PAST it, else the enemy base); FIGHT is attack-move, so units stop when something is in range and walk on after. No standoff distance, no standing
idle out of range. **They back off ONLY when something is moving quickly toward them** (a charge: enemies closing >= 55 elmos/s that can hit within 4 s, worth >= 10% of the group,
from `Spring.GetUnitVelocity`): a **MOVE** 400 away (a FIGHT will not walk back), the Pounders meet the charge, then FIGHT again. Zero damage taken is NOT the goal. The group's core
is its FORWARD cluster (a centroid of everyone was dragged home by new units). **Pounders** hover ~200 in front of the Lashers and meet any enemy that dives within 350 of a Lasher
(a spot behind them is reached by MOVE). **Rez bots** reclaim/resurrect only wrecks BEHIND the Lashers, repair hurt Lashers/Pounders, trail 350 behind, step back when an enemy is near.
Lab: no Sheldons (`T2_SLOW_SHARE = 0`); Mammoths count as fast units. `HUMAN_SLOW = true` in `unit_controller.lua` hands the three unit types to a player again (no Lua orders; the logger records them).
Log rows `[SF]`; tests `tests/test_slow_front.lua` (27 checks, hand-placed geometry) and `tests/test_click_army.lua`. Seen in-engine once; being tuned.
Old description of the click_army slow group (still in the code, off for LINE_CLICK): **The slow group trades, it does not hunt:** fast groups want damage done (BP/eco/commander); the slow group wants cost-effective trades against the enemy
ARMY. T1 = Lashers `cormist` (155 m, long range, support) + Pounders `corlevlr` (220 m, the screen, assumed from the 220 m / 2600 e match;
`corgarp` also fits that cost); T2 = Sheldons `cormort` (400 m, 850 range, support) + Mammoths `corsumo` (screen). Fast escorts count as screen.
**Both kinds of group attack the other side and never defend:** units in an attack group are never pulled home (`CA.InGroup`); only reinforcements (new units and
ones waiting at the stage), home guards and air respond to units attacking the main base. The slow group's objective is always the enemy's main base (the densest
cluster of standing structures, re-picked every 300 frames; the enemy start until one is known). It stops only for a REAL fight (enemy value near >= 0.5x its own);
a few strays are not chased (its FIGHT orders still shoot whatever is in range on the way), and it holds at the edge of STATIC defences worth > 2x the group.
The screen holds `SLOW_SCREEN_AHEAD` in front of the support's spot and steps out only for an enemy within 450 of a support. The support is only worth
anything while it FIRES, so its default is a FIGHT order toward the base, always, and the kiting is about its weapon range (the shortest range among the
supports, read from the unit defs): out of range in a real fight it closes in (to 0.8 x range), in range it stands and shoots where it is. **It gives ground only
when at risk of dying:** outvalued (enemy value near > 1.5x its own) AND the nearest enemy inside 0.6 x its range (released at 1.0x or 0.9 x range), or a single
unit under 40% health with the enemy within 1.3 x range. Then it backs off with a short MOVE (<= 300 elmos, never out of range, the whole depth of the line
kept in range), and the screen holds the line meanwhile.
**The slow group moves as LINES, not a ball:** supports stand 4 deep per spot and the line widens one spot (110 elmos) at a time only when a spot is full (8 Lashers =
2 spots, 20 = 5); the screen is a thinner line in front (2 per spot) spanning the same width. Slots are assigned by where each unit already stands across
the line, so the group does not reshuffle. Holding is exact (no creep or slide: a formation is centred on its AVERAGE, not its front rank). With nothing in sight it advances in 600-elmo legs toward the enemy army (else the enemy start) and holds at the edge of defences.
**Scouting (`bar_framework/scout_lanes.lua`, LINE_CLICK only; `scout_plan.lua` is untouched):** in FIND mode two scouts sweep the ENEMY half: each goes first to one
of the two far enemy-side corners, then inward toward the middle of the enemy's spawn region (the mirror estimate), nearest unseen sector first, never revisiting
a sector for 3 min, and our half only once the enemy half is swept. Tests: `tests/test_scout_lanes.lua`. The lab controller builds the mix: slow units are ~35% of the vehicle plant's value
(`SLOW_SHARE`, 2 Lashers per Pounder) and Sheldons ~35% of the T2 bot lab's value (`T2_SLOW_SHARE`).
**Targets:** damage value = cost + 4 x build power + eco bonus, factories x0.15 (`LAB_FACTOR`: labs are tough and not what starves the enemy).
The **enemy commander** outranks all of it when open (seen < 30 s ago, guard value around it <= 0.3 x the group, group >= 1200): every group goes for it.
**Scout calls:** each attacking group publishes two points ahead of it (`CA.ScoutRequests()`); Hawks (`corawac`) beyond the first radar plane fly
there (unit controller, role `SCOUT_CALL`), and one T2 air lab (lowest id that can build the Hawk) keeps `radar + mb.callScouts` Hawks up.
Hurt squads (<=6 units) retreat; fighters escort the biggest group; 8+ bombers strike together. It waits for a real enemy-start fix
(`MM.FoeSource() ~= "mirror"`; the mirror guess is thousands of elmos off on Full Metal Plate). Its `lab_controller.lua` also builds the
home-guard Shurikens/Wasps only up to a sized standing force (`GUARD_*`; LINE_BOT built ~300 in the stub in 14 min because "floating"
included income > pull + 15). Judge it on enemy BP/eco destroyed (`[CK]` log rows: dives, targets, KILLs, totals), then A/B on army value.
`tests/test_click_army.lua` (32 checks) runs through `lupa.lua51`. `enemy_intel` now also carries `bp`/`eco` per class (additive).
