# Stances: what is built, what is next (2026-10-11)

Built (first pass, no bot changes): `stance_editor.html` (unit comp editor with search, filters, BAR pictures, per-unit share,
intent/control notes), `extract_unit_data.py` (-> `stance_editor/units.json`, `stance_editor/pics/*.png` from the installed BAR
archive), `stances/` (JSON saves, Lua export, README, seed `light_raid.json` = LINE_CLICK_v16's current comp),
`tests/test_stance_export.py`. Baseline for the bot work is `candidates/LINE_CLICK_v16`.

## Status 2026-10-12
Steps 1-2 below exist as framework code, not yet in v16/v17: `strategy.lua` (stance + hooks: `army_share`, `weights`, `switch`; `InstallSpine`
is the stance share policy), `stance_loader.Pick(..., weights)`, `game_state.lua`. Item 5 (control per stance) is now machine-readable:
stance units carry `behaviors`/`cfg` (editor boxes), run by `behavior_host.lua` (`bar_framework/behaviors/README.md`). LINE_BOMB already used the
loader. Next: port a bot (e.g. a LINE_CLICK_v18 copy) so its lab controller asks `strat:Pick`, Lashers/Shurikens run as behaviours, then A/B vs v17.

## Bot work still to do
1. **Stance loader + ratio picks** (`lab_controller.lua`): read `stances/<name>.lua`; replace the hard-coded `ARMY_PICKS`/`SLOW_SHARE`/`T2Mix`
   with a value-deficit rule (queue the unit furthest below `share * total built value`), limited to what the idle lab can build.
2. **Stance share**: a policy through `spine.AddPolicy("stance", fn, index)` (`spine.lua` ~201) after `schedule`, before `threat`; the overall
   share stays separate from the comp. Switch on `LT.CFG.SHARE_GOV` (`spend_governor.lua`) if the share must actually bind.
3. **Pre-built BP in the spine**: keep enough nanos built that a jump to 50% share can be spent at once. `spine.LayoutCapacity`/`LabRate`
   already estimate per-nano/per-lab pull; `MaybeExpand` opens cells to `income`, so size it to the *maximum* stance share instead.
4. **Air labs in the mex grids** are not in the share today (`SP.IsLab` is false for them; their guard/Shuriken/Wasp spending is invisible to `S.share`).
   Either route them through the stance picks and count their pull in `spend_governor.Scan`, or fold them into the spine's lab list.
5. **Control per stance**: the editor's "control" notes are for whoever changes `click_army.lua` / `slow_front.lua` per stance.
