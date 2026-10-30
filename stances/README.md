# Stances

A stance is a unit comp: which units to build and what share of the **army spend** each gets. The overall army
share (how much of income goes to the army) is controlled separately; a stance only decides what that spend buys.

Edit with `stance_editor.html` (open it in a browser; run `python extract_unit_data.py` once to build
`stance_editor/units.json` and the unit pictures from the installed BAR).

- `*.json`: editor save files (shares, locks, notes). Edit these.
- `*.lua`: **Export Lua** output, read by the bot:
  `M.name`, `M.intent`, `M.control`, `M.suggestedShare` (notes), and `M.units = { {n, share, ratio, perK, cost, note}, ... }`.
  - `share`: fraction of army spend (sums to 1).
  - `ratio`: unit-count weight = share / cost, normalised to sum 1.
  - `perK`: units per 1000 metal-equivalent of army spend. Cost is metal + energy/70, same as `UnitValue` in lab_controller.lua.

`M.plan.group_support` (optional, 2026-10-30): the support elements this stance's army groups opt into, replacing the bot's `SUPPORT`
(unit_runtime option) while the stance runs, e.g. `group_support = { raid = { spam = { n = 6 }, scout = { every_s = 20 } }, slow = { aa = 6 } }`.
Support units are a fixed number per group ("enough"), not a share: do not put flak / jammers / Saviors in `M.units` for that.
See `bar_framework/army_groups.lua` and `knowledge/bots/support_elements_2026-10-30.md`.

Intended use by a controller: keep a running value built per unit; when a lab is idle, queue the unit whose built value is
furthest below `share * total built value` (the same value-deficit rule as `mix`/`SlowPick` in lab_controller.lua).
`stance_next_steps` in `knowledge/` lists the bot work still to do.
