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

## core_default v2 (2026-10-26)
`start` (stance `core_start`: 76% Incisor / 24% Pounder, share 1.0) for 6:00 -> `t1_hold` or `t1_push` (T1 units only) -> `t2_hold` / `t2_push` (income >= 500; ~18-23% T1
filler) -> `core_late` (Demon + Tiger; the Dragon sink is separate) at the unit cap. Share machine: `start` 1.0 -> `hold_low` 0.22 / `push_high` 0.55 by the stance's
army mode, `catch_up` (match_enemy) when a good scout shows an enemy army as big as ours, `attack` 1.0 while `under_attack` or `enemy_near_base >= 600`.
New signals: `enemy_scouted` (located + 12 units seen), `enemy_known_units`, `under_attack`, `enemy_near_base` (raid_response's intruder value inside our territory).
Hold stances stand further out: the stance plan `maneuver = { R_MIN = 1100 }` (default ring 700); any perimeter_guard / maneuver_defence option can be set per stance there,
and it is re-applied on every stance change (`maneuver_defence.Reconfigure`).
The 4k-at-6:00 opening is config in `candidates/CORE/macro_controller.lua` `LT_CFG`: `VP_WAIT_AIR_LAB = false` (the vehicle lab goes first), `VP_DONE_FRAME` 3:00, `VP_NANO_ASSIST`
(the lab's nanos keep building it while the share is >= 0.6, line_transition). eco_sim: ~4.2k army spent at 6:00 (was ~2.0k), income 10-14 min ~25% lower, 20 min about the same.

## rows_default T1 states and unit behaviours (2026-10-28)
Four T1 stance nodes: `start` (`raid_start`: Incisors, 2 raid groups) -> `start_brutes` (`raid_brutes`: Brutes, 3 groups, batch reinforcement; edge at `metal_income >= 250`) and
`t1_hold` (ring + `raid_sections`: a blob nothing is attacking is sent out as a raid group and never recalled) <-> `t1_push` (2 Brute raid groups + 1 slow Pounder group,
Lashers kite). Stance plan fields added for this (all default off): `raid_groups` (click_army MAX_GROUPS), `slow_group`, `batch` + `prod_s` (batch reinforcement),
`raid_sections = { n, quiet_s, min_units, cooldown_s }`.

**How to change what a unit does.** Open the stance node in `machine_editor.html` (after `python fsm_index.py`): each unit shows its share, the *named behaviours* it carries as
chips (hover for what each does) and a "driven by" line naming the owner when it has none. Edit `stances/<name>.lua`:
- a unit row `{ n = "corraid", share = .., behaviors = { "brute_raid" }, cfg = { brute_raid = { log_every = 900 } } }`; `extras = { { n = "cormist", behaviors = { "range_kite" } } }` for units
  the stance does not build but still controls (Lashers, left-over Incisors, the Dragons get theirs from the sink).
- the owner of a unit's orders is the *plan*: `army = "raid"` -> click_army raid group (slow group below speed 50 with `slow_group`), `"hold"` -> maneuver blob, AA units
  (`coraak corsent corcrash cormist`) -> AA post. A behaviour is a name + extra micro on top of that owner; `gator_raid` / `brute_raid` issue no orders, they only name the units
  and log `[BEH] m:ss <name>: n units (GROUP=.. RESPOND=..)` every minute.
- behaviours: `bar_framework/behaviors/*.lua` (`bar_framework/behaviors/README.md`): `range_kite` (steps back at the edge of its range), `kite`, `shadow`, `stun_target`, `intercept`
  (raid_response gives it to fast responders), `dragon_raid` / `dragon_defend`, `gator_raid`, `brute_raid`.
