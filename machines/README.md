# machines/ -- state machines for CORE

A machine file is one data-only Lua table (`return { ... }`) read by `bar_framework/fsm.lua` and edited in `machine_editor.html`
(open `machine_editor.html` in Chrome/Edge, **Open .lua**, edit, **Save**; `python fsm_index.py` first so the stance + signal lists exist).
CORE loads one with `MACHINE = "<name>"` in its `macro_controller.lua` (`candidates/CORE`: `core_default`). `MACHINE = false/nil` = the old
CFG switch options (`PLAN`, `LATE_STANCE`, `BURST_SWITCH`, `SHARE` ...), also the fallback if the file fails its checks (`[FSM] ERROR` rows).

Two machines per file, both ticked once a second (stance first, then share):
- `stance_machine`: nodes `{ stance = "<stances/NAME.lua>" }`; the active node's stance is the strategy's stance.
- `share_machine`: nodes `{ share = 0.35 }` or `{ hook = "match_enemy" | "v16_share", cfg = {...} }`, optional `ramp_s` (seconds to move to a new share).
  Manual overrides (`WG.StanceRequest`, `WG.ArmyShareRequest`) and the big-air-raid share (`AIR_RUSH_SHARE`) still win over the machine.

```lua
edges = { { from = "hold", to = "raid", prio = 10, hold_s = 60, min_stay_s = 90, note = "ahead for a minute",
            when = { all = { { sig = "army_ratio", op = ">=", val = 1.4 }, { ["not"] = { sig = "bad_trade" } } } } } },
any_edges = { { to = "late", when = ... } },      -- same, from every node
```
- `when`: leaves `{ sig, op, val }` (ops `> >= < <= == !=`; no op = the signal is true) combined with `all` / `any` / `not`, nested. No `when` = always.
  A test on an unknown (nil) signal is false.
- Of the edges that can fire the highest `prio` wins, then the first listed. `hold_s`: the condition must hold that long. `min_stay_s`: time in the node.
- Signals: `bar_framework/signals.lua` (one line each; also the editor's list after `python fsm_index.py`). The machines see each other through
  `stance`, `stance_army`, `stance_age_s`, `stance_plan_share` (stance machine) and `share`, `share_node`, `share_age_s` (share machine), each the
  other machine's value from the previous second.
- Every transition is logged: `[FSM] stance 4:01 hold -> raid | edge 1 | (enemy_located AND enemy_vs_army=0.20 < 0.5) | note`, and
  `[FSM] share f=.. node=.. share=..` every minute. `machine_editor.html` -> **Replay log** shows them on the graph.
- `builtin_rules.lua`: what CORE does on its own whatever the machine says (air raid -> AA rush, AA floor, raid response, rez, anti-nuke, ...);
  view-only, shown in the editor's "Built-in rules" tab and the "always on" strip.
- Checks: `python fsm_index.py --check [file]`, `python tests/run_lua.py tests/test_fsm.lua`.
