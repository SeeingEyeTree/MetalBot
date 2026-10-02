Goal: implement the units and scouting parts of `knowledge/game_mechanics.md` that DRAGON_BOT does
not have yet. The economy is DRAGON_BOT's, unchanged except for one bug fix. The author's focus for
this bot is units and scouting, not eco.

Base: `DRAGON_BOT` as of `c1ca602` (energy look-ahead + air-con reserve merged). Every change is either
in these three files or in a NEW `bar_framework/` module that only MECH_BOT loads, so DRAGON_BOT and
the exploiter bots behave exactly as before and stay valid A/B baselines. The one shared-file edit is
additive: `unit_query.is_bomber()`.

## Changes, by game_mechanics section

| Section | Change | Where |
|---|---|---|
| 6.2 scouting | `enemy_intel`: 5-min memory of enemy units (30 min for buildings), their labs (air / T2), commander's last position, remembered defences | `bar_framework/enemy_intel.lua`, unit controller |
| 6.2 scouting | Recon: once the picket ring is up, the fastest scout (2 after 15:00) keeps re-scouting the enemy half, weighted to their base and remembered buildings, skipping sectors covered by known AA until they have been dark for 3 min. Scout count follows (2 find, 3-4 picket + recon, 5 hunting) | `bar_framework/recon_plan.lua`, unit + lab controllers |
| 6.2 radar | Con bots place radar on the enemy-facing arc instead of a full circle | macro `DispatchConBots` |
| 7 utility | One radar plane (`corawac`, from the T2 air lab; 2 after 20:00) holds behind the army and steps back from known AA | unit + lab controllers |
| 7.3 AA | Reactive fighter target: baseline 3 fighters + fighters worth 1.0x the enemy air remembered + 2 when an enemy air lab is seen, +4 for a T2 one (cap 40). T2 air labs now build `corvamp`. Fighters split: at least 4 / half stay home, the rest join the line | lab + unit controllers |
| 7 raiders | Up to 20% of army value in fast ground-attack units (Shurikens) raid the weakest remembered enemy eco: gather, approach via a flank waypoint away from their army, strike, re-target. Never retreat | `bar_framework/raid_group.lua` |
| 7 / 7.1 anti-raid | 2-6 Shurikens (25%) stay home as a fast reserve for raid response | unit controller `StaysHome` |
| 7 main army | An engaged line node keeps advancing (half speed) when our value there beats theirs by 1.3x, instead of freezing on contact (lessons 2026-09-24: the army held near home). Default line target is the real foe position | unit controller `UpdateNodes` |
| 1.4 / 7 rez | A bot lab is rebuilt outside the mex lattice after the vehicle plant, with its cell and a 3-cell lane ahead reserved from grids. Rez bots (2 + 1 per 15 army units, max 8): repair > resurrect armed wrecks > reclaim, trailing 700 elmos behind the army | macro, lab, `bar_framework/rez_crew.lua` |
| 7.2 / 1.4 retreat | Wounded units retreat to the nearest rez bot, else nano turret, else home. Raiders never retreat | unit controller `UpdateRetreats` |
| 1.5 commander | Retired from the build order when the kickstart is done (or at 8:00), walks to a spot behind the base next to a nano, builds a jammer + 2 static AA there, cloaks when energy allows, and moves away from armed enemies / attacks at any time | `bar_framework/commander_guard.lua`, macro |
| 9 endgame | "Won" = after 15:00, no armed enemy seen for 3 min, no attack in progress, our army >= 8000 and remembered enemy < 30% of it, and we have looked (front past midline or their base seen recently). Then: scouts sweep the whole map, labs build 8 bombers, bombers hit the commander as soon as it is seen, silos fire at it unless an enemy anti-nuke covers it | `bar_framework/endgame.lua`, all three controllers |
| bug | The macro adopted the next factory as "the bot lab" after the kickstart lab was reclaimed (lessons 2026-09-21) | macro `UnitCreated` |

Deliberately not done: proxy bases, combat engineers and Grunt draw-fire (the army is air), anything
in section 8, economy work, nano airlift and T3 (author's call).

## How to judge it

Nothing here has run in a real match. `lua5.1 tests/test_mech_bot.lua` only proves the code runs
and that each behaviour fires in a stub world where everything is instant (see `LUA_TESTING.md`).

Army value at 8:00 will not see most of this (lessons 2026-09-22). Measure the mechanism:

- **Survival vs the exploiters, from BOTH slots**: `commander_lost` vs RAIDER_BOT and
  GROUND_RAIDER_BOT. DRAGON_BOT's slot 1 was roughly a coin toss. `[CG]` lines show evasion.
- **Scouting**: tracker `fresh_enemy`, `believed_mv`, `arrivals_warned_n` / `lead_med`,
  `lost_unseen_*`; `[UC/intel]` once a minute (what is remembered, enemy labs, last armed sighting).
- **Roles**: tracker `rez`, `util_intel`, `home_guard_air_mv`; `[RAID]`, `[MC] REZ LAB`,
  `[LabCtrl] ... fighter target` lines.
- **Engagements**: `pm_isolated / pm_deaths`, `lost_enemy_*` (did raids kill eco?), `trade_ratio`.
- **Endgame**: needs a long match against a bot it can beat: `[END] WON-STATE`, then a commander
  kill instead of a draw on score.

Tuning guesses to check first: `AA_VALUE_RATIO` (lab), `PUSH_RATIO` (unit controller `MECH`),
`RAID_SHARE` / `MIN_ARMY` (raid_group), `COM_RETIRE_FRAME` (macro), `WON_MIN_FRAME` / `QUIET_FRAMES`
(endgame).
