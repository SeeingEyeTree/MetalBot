# CLAUDE.md history -- the session logs that used to sit in the "Bot structure" section

Moved here word for word on 2026-10-14 so CLAUDE.md stays a how-to-work-here guide (it now carries a short summary and links).
Nothing below was edited.  Newest work is in `knowledge/bots/session_2026-10-13_raid_bot.md` and `CLAUDE.md` itself.

**Stances (2026-10-11):** `stance_editor.html` edits a unit comp (units + share of army spend, plus intent/control notes);
`python extract_unit_data.py` builds its unit list and pictures from the installed BAR. Saves/exports live in `stances/`
(README there). The bot does not read them yet; next steps in `knowledge/sessions/stance_next_steps.md`. Baseline is LINE_CLICK_v16.
**Strategy framework (2026-10-12, built, not yet in a bot):** `bar_framework/behavior_host.lua` + `behaviors/` (plug-and-play unit control:
`kite` backs off from ANY approaching enemy, threat-weighted; `stun_target`; per-unit tunables, stackable), `strategy.lua` (stances +
run-time hooks `army_share` / `weights` / `switch`, `InstallSpine`), `game_state.lua`. Stance units can carry `behaviors`/`cfg` (editor boxes).
Docs: `bar_framework/behaviors/README.md`. Tests: `python tests/run_lua.py tests/test_behavior_host.lua` (also `test_strategy.lua`). Next: port a
bot (copy v17 -> v18) onto it and A/B.
`bar_framework/slot_spine.lua` + `blueprints/general/NanoBlock.lua` (2026-10-12): the new spine -- 16-nano blocks with 2 lab slots in front; labs are
picked from the stance's units (`Cover`/`Counts`), swapped by reclaim when the comp changes, nanos always built ahead and re-guarding the new lab
(`Strategy:InstallSlotSpine`). Test: `tests/test_slot_spine.lua` (fake placer).
**For games vs people (2026-10-12):** STANCE_BOT's `CFG.MATCH = true` uses `strategy_hooks.match_enemy` (army share rises as our army value falls short of 1.1x the scouted enemy value / a time curve; 1.0 when metal+energy float; `[SHARE]` log rows) and T2 air labs queue Dragons (`corcrwh`) while both banks float. Set `MATCH = false` for bot-vs-bot tests (two bots would chase each other's share).
**STANCE_BOT eco work (2026-10-12, overnight):** (a) `match_enemy` no longer lets threat sightings lift the share (with the slot spine share 1 = nanos for all income = starved grids); shortfall is measured in seconds of income (`horizon` 60); ahead of the enemy (>=1.5x) the share drops to 0.05. (b) `lab_controller` ARMY BUDGET: a token bucket (income x share) limits stance picks -- the share was only an on/off lab gate before (army 3x v16's at 10:00). (c) slot_spine: `BUILD_AHEAD_INCOME` 500 (no nano build-ahead below it), `FLOAT_MULT` / `MAX_JOBS_FLOAT` (capacity look-ahead while both banks float; STANCE_BOT sets 2.5), lab-to-slot match 200 elmos for the expected lab. (d) line_transition options, all default off, STANCE_BOT turns them on through `LT.New{cfg=}`: `EP_BANK_SECONDS`, `EP_RATIO` (energy look-ahead), `EP_CON_FORCE`, `ECELL_MAKE_CON`, `ECELL_FIRST`, `ECELL_MAX_ACTIVE`. (e) T2 air labs queue Dragons while both banks float. (f) `game_state.Collect{MB=WG.MetalBot}`: in --server single the framework modules do not see the widgets' WG, so threat/intel reads were empty before.
**Vacuum test** (eco only, no commander-kill ending): copy the bot, append a self-destruct snippet to its lab_controller (armed mobile units `CMD.SELFD` 45 s after they finish), run vs INACTIVE_BOT `--end-minutes 20`; `runs_stance/vac_report.py <result tags>` prints income/pull/bank/factories per 2 min. (`METALBOT_DEATHMODE=none` is accepted by the harness but did NOT stop the early game_over.) Result: STANCE_BOT's eco scales like v16's (12:00 ~800-1000, 20:00 ~2400 metal income), but from ~16:00 metal floats (spend ~700 of 2400) because energy binds (~15 E per metal of army; energy income falls 20k -> 13k). The energy cell now starts ~13:50 (was 18:08) but takes ~4.5 min; more energy build speed is the open item.
**STANCE_BOT eco session (2026-10-12, evening):** energy priority during wind consolidation (fusions first, every available air con + nanos help), energy storages in the NanoBlock gaps, nano crew, `Late_game` stance when the cap is 75% full, earlier retrofits, `[AUDIT]` log rows. Vacuum 20-min result: income 3.9-4.7k, pull 3.0-3.6k, ~1.2M metal spent (was 2.4k / 0.3k / 0.45M). Notes: `knowledge/sessions/session_2026-10-12_energy_eco.md` (tried/worked/removed), `knowledge/sessions/variance_notes_2026-10-12.md` (run-to-run drift), `knowledge/economy_numbers.md`; repeated-game tool `runs_stance/ab_variants.py`. Compare runs on `*_avg` tracker fields, never the minute-mark `metal_inc`.
`candidates/STANCE_BOT/` = v16 + these systems (stance `stances/line_ground.lua`); ~even vs v16 (2-2 at 30 min). Session notes, results and to-do:
`knowledge/bots/session_2026-10-12_stance_framework.md`; batch tester `runs_stance/batch.py`.

**`candidates/RAID_BOT/` (2026-10-13)** is STANCE_BOT plus the fixes from a review of STANCE_BOT's game against a person. STANCE_BOT won that game on macro alone: its army idled until 8:00, and its raids traded 33k for 0 kills.
- **Game plans:** stances `raid_open`, then `hold` after bad trades while behind (`strategy_hooks.game_plan`), then `raid_late`. Each stance file carries a `plan`.
- **click_army:**
  - early small groups;
  - COMMIT to build power or ESCAPE when surrounded;
  - hole finding round the target;
  - hold mode.
- **Unit behaviour:**
  - range_kite Demons and Banishers;
  - no slow group;
  - raid response releases units above 3x the raid's ground value;
  - air labs make Wasps/Shurikens, not cons, during a ground raid (`CON_HOLD`).
- **Hold comp** (the user's): Grunts, Pounders, Sheldons, Mammoths, Shivas, Banishers. `income_mix` tilts it from mass to quality as income grows.
- **Second round:**
  - mex grid recovery (`GRID_RECOVER`);
  - a second T1 air lab on the line;
  - a standing Shuriken force at home;
  - coraak/corsent as a base AA screen and army escort;
  - fighters and Hawks wait at a post behind the front, out of enemy AA;
  - raid groups call Hawks along their route, from a standing pool of 3.
- **Framework flags:** all default off.
- **Unit clock (2026-10-14):** `bar_framework/unit_clock.lua` gives each unit a tier (LOW 0.5 Hz: scouts / quiet guards with no enemy near; NORMAL 1 Hz; HIGH 2 Hz: raiding, urgent duty or an enemy within 1200, held 90 frames) and a phase from its id. `army_broker` holds non-urgent orders until the unit's own frame (`Flush` every frame, `UpdateClock` once a second) and scales its order rate limit by tier; while any unit is HIGH the unit controller re-plans retreats / responses / click_army at a half step too. RAID_BOT loads it; other bots do not. Test: `tests/test_unit_clock.lua`.
- **Notes:** `knowledge/bots/session_2026-10-13_raid_bot.md`.
