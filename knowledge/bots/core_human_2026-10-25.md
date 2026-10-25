# CORE_HUMAN (2026-10-25): macro bot + person on the army

`candidates/CORE_HUMAN` = CORE's macro and lab rules, an empty unit controller, `human_control_logger.lua`, and `stance_panel.lua`
(stance buttons + army-share buttons on the right edge; `/stance`, `/share`). `MANUAL_STANCES` (macro_runtime) turns off the automatic stance
switches; `WG.StanceRequest` / `WG.ArmyShareRequest` carry the person's choice.

## Logger fix
`[HCL] cmd` / `queue` rows were mixing in the bot's own macro orders (a Lua widget's orders reach `UnitCommand` with `fromLua = false`; of 40k
rows in the 25-min game ~20k were `repair` / `build` / `guard` from the macro). The logger now remembers UI commands from
`widget:CommandNotify` (UI-only) and logs a `UnitCommand` only if it matches one (cmd + first 3 params, 90 frames; lab queue clicks 8 frames).
Everything else is counted in the ctx row's `lua_orders`. **Logs from before 2026-10-25 are mixed**: filter to army units (the macro never
orders them) when reading `metalbot_human_20261025_013407.log` and older.

## What the 2026-10-25 game says about the strategy (inferred from `metalbot_human_20261025_013407.log`, army-unit rows only)
1. **Boom behind a thin army.** Army share 10% from the first frame (30% only 11:25-13:05), so the macro puts everything into eco: 130 m/s at
   7:30, 1.0k at 12:30, 2.7k at 15:00, 9.4k at 22:30. Army value 4k at 8:15, 14k at 11:35, 56k at 14:55.
2. **Scout early, west edge.** A Rascal is sent at ~3:30 with shift-queued waypoints down the west side toward the enemy start.
3. **Early trade on the enemy's workers, mid-map.** First big fight 6:30 at (3560, 3639): 123 kills for 68 losses, mostly enemy air cons
   (corca 37), Gators, Pounders, Shurikens. Shurikens (15, later 25) are kept as one group near home (550-2500 from base), moved around as a
   mobile defence, with an occasional `attack` on a far target.
4. **The whole army as one ball, steered with MOVE.** From ~12 min the entire ground army (50-230 units, `sel=1`) is selected and given
   rapid `move` orders (a new target every 3-10 frames) 600-5000 elmos ahead, often with enemies 25-600 away (not FIGHT): the ball is
   dragged into and past contact. Fights: 13:49 441 kills / 310 losses; 18:24 24 kills / 146 losses (a bad one); 19:27 875 kills / 666 losses.
5. **Switch to a gantry doom ball at 18:46** (`shiva_push`, Shivas 100%), keeping a separate air group.
6. **Air group of Dragons + Vamps + Avengers** (25-60 Dragons) is its own selection: `move` to the enemy base, then `attack` on specific
   structures: wind generators, then **nano turrets** (enemy build power) at (3150-3650, 800-2000), 21:21-21:40. Late the 126-132 Shiva
   ball does the same (`attack` a Gator at the enemy base 23:41).
7. **Heavy control-group use** (1,208 group changes): ground ball, air group, Shurikens, rez bots handled separately.

Doctrine it follows (same as CORE's): kill build power / eco; cheap eco-first opening; big deathball late. What the bot does not yet do and
the person did: steer a ball with MOVE then flip to FIGHT/ATTACK; keep air as an independent snipe group on nano turrets; hold Shurikens as a
mobile home defence; use the commander-scale economy lead (9k m/s) to outspend.

## Dragon math (a Dragon lives ~150 s; `corcrwh` 5100 M, 72000 E, 120000 build time; sources: ecosim/unitdefs.lua, knowledge/economy_numbers.md)
Per 1 m/s of metal put into Dragons: 14.12 E/s, 23.53 build power, and `150/5100 = 0.0294` Dragons per 150 s.
A Dragon lab (`coraap`, 600 BP) with 32 decoy commanders (`cordecom`, 300 BP each, 750 M + 13000 E) has 10,200 BP: one Dragon per 11.8 s,
absorbs **433 m/s**, makes 12.75 Dragons per 150 s.

| metal into Dragons | Dragons / 150 s | build power | labs (32 decoys) | decoys | energy | afus (3000 E) | fus (850 E) | T2 mex (9.48) | units (eco+sink+Dragons) |
|---|---|---|---|---|---|---|---|---|---|
| 2,000 | 59 | 47k | 5 | 147 | 28k | 10 | 33 | 211 | ~430 |
| 4,000 | 118 | 94k | 10 | 294 | 56k | 19 | 66 | 422 | ~860 |
| 6,000 | 176 | 141k | 14 | 443 | 85k | 29 | 100 | 633 | ~1,300 |
| 9,400 (last game's income) | 277 | 221k | 22 | 693 | 133k | 45 | 156 | 992 | ~2,030 |
| 12,700 | 374 | 299k | 30 | 936 | 179k | 60 | 211 | 1,340 | ~2,740 |

Units per m/s: mex 0.1055 + afus 0.0047 + decoys and labs 0.0761 + Dragons alive 0.0294 = **0.216**. With ~250 units of other eco and a 3,000 cap,
**the cap allows about 12.7k m/s into Dragons = ~370 Dragons per 2.5 min**, with no army left. Keeping 500 units for anything else: ~10.4k m/s,
~305 Dragons. BP per unit decides it: a decoy (300 BP) beats a nano (200 BP); the 32-decoy-per-lab limit sets the lab count.

Last game: income 9.4k, **10 sink labs (SINK_MAX) absorb ~4.3k + the spine's 1.2k = 5.5k m/s**: the rest floated (bank 600k). The bot needed 22
sink labs and ~700 decoys (it queued 223 decoys in the whole game). Changed: `SINK_MAX` 10 -> 40, `SINK_PARALLEL` 3 -> 5 (CORE and CORE_HUMAN).
Eco cap (`GRID_CAP_FRAC` 0.6 = 1,800 units of grids): fine for ~9-10k m/s (sink + Dragons need ~1,000 units = 33%); at 12k m/s the sink needs
~49% of the cap, so drop it to ~0.5. Left at 0.6.

## Rez floor (new)
`bar_framework/line_transition/rez_lab.lua`: a T1 bot lab (`corlab`) on the line, site reserved at the start like the T2 bot lab's (so the line,
decoy labs and sink never take it), queued at 40 m/s income and not before 2:00. It is not adopted by the spine or sink. Lab rules (CORE and
CORE_HUMAN): `REZ_START_FRAME` 3:00, `REZ_BASE` 8, `REZ_MAX` 20 (floor of 8 alive).
