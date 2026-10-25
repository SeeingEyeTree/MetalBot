# Ledgers: finding where a bot (or a person) loses value (2026-10-25)

`ledger_logger.lua` is a general widget (deployed for every bot, like `metalbot_stats_tracker.lua` and `human_control_logger.lua`); it only reads.
`ledger_report.py` turns its `[LED]` rows into a report and a ranked list of gaps. Why: `find_weakness.py` ranks failure classes with hand-set
scores; the ledgers put the biggest gaps in the same unit (metal-equivalent) so they can be compared across games and bots.

```powershell
python ledger_report.py                          # newest LuaUI\Config\metalbot_ledger_*.log
python ledger_report.py infolog.txt              # any file with [LED] rows (an infolog, a harness log)
python ledger_report.py a.log --vs b.log         # two games, one after the other
python ledger_report.py a.log --json             # the summary as JSON
python ledger_report.py log.txt --team 0         # --server single logs tag lines <T0>/<T1>
```
Rows go to the infolog and to `LuaUI\Config\metalbot_ledger_<date>.log` (the infolog is overwritten on each launch). Tests:
`tests/test_value_weights.lua`, `tests/test_ledger_logger.lua`, `tests/test_ledger_report.py`.

## What is worth what (`bar_framework/value_weights.lua`, every number in `M.CFG`)
Killing economy and build power takes away future value, so they are worth more than their price; killing army is worth its price.
`cost` = metal + energy / 70 (the project's `UnitValue`).

| category | value | example |
|---|---|---|
| army (mobile, armed) | cost | Dragon 6129 |
| eco | cost + 60 s of income. Mex: `extractsMetal` x 2370 m/s (T1 2.37, T2 9.48). Energy: `energyMake` (wind: 60% of its rating) / 70. Storage: cost | T2 mex 640+116+569 = 1.3k; fusion 3.9k+0.7k |
| bp (factories, nanos, constructors, decoy commanders, rez bots) | 3 x cost + 60 s x buildSpeed x 0.05 | nano 276 -> 1.4k |
| commander | 25,000 | |
| defence (armed structure), other (radar, jammers, unarmed scouts) | cost | |

Per metal of cost: build power > eco > army (checked in the test). A unit under construction counts its build progress.

## The rows
- **`[LED] spend`** every 30 s: income, pull, bank, energy, unit count / cap, labs busy / idle, idle cons, idle nanos, `bp_use`, and
  `to_<kind>` = the metal rate the builders are putting into army_ground / army_air / bp / eco / defence / commander / other (each builder's
  current build power x its target's metal per build point). `unexplained` = pull minus that sum. **`why`** when the income is not being
  spent (pull < 90% of income and the bank half full): `unit_cap`, `idle_labs`, `energy`, `build_power` (every builder busy: more BP would
  spend more), `idle_builders`, `nothing_to_build`; otherwise `spending`.
- **`[LED] fight`** one row per fight (events closer than 5 s): value LOST by us to an enemy and KILLED by us, per category, `ratio`,
  `top_lost`, `top_killed`, where, how long. Reclaims, decay and self-destruct (no attacker) are not losses. Kills are only seen when the
  enemy died in LOS. `[LED] value` each minute holds the running totals.
- **`[LED] scout`** one row per arrival wave (an enemy within 1800 elmos of our start; waves 20 s apart): `lead_s` = seconds from first seen
  (LOS or radar) to arrival, `seen_d`, `seen_by`, the first unit's type (`?` = a radar blip), `n`, `surprise` (lead < 5 s).

## What the report says
`SPEND` (income vs pulled vs **unspent**, where the metal went, why it did not, a timeline), `FIGHT` (lost vs killed by category, the enemy
future destroyed = killed eco + bp, the biggest fights, what we killed most), `SCOUT` (waves, median lead, surprise rate), then **GAPS**: the
three largest (unspent metal, net value lost, surprises).

## Limits and ideas not built
- Not shimmed for `--server single` (it reads the real engine state; run it in normal-mode games / real games).
- Radar-only kills are missed (the callin needs LOS); an enemy never seen is not in the scout ledger.
- Not built (user: "I don't need the recovery idea"): time to replace a dead Shuriken / rez bot / con after it dies.
- Next step noted by the user: a gap report merging these with `find_weakness.py` across the last N games; compare the person's fights
  (CORE_HUMAN, `human_control_logger`) with the bot's attack groups at the same army value to find the situations a behaviour should copy.
