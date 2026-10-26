-- CORE's default state machines (CFG.MACHINE = "core_default"): the same rules strategy_hooks.game_plan + cap_switch + match_enemy
-- applied before, written as nodes and edges.  Edit it in machine_editor.html (open this file, change, save).
-- File format: machines/README.md.  Signals: bar_framework/signals.lua.
--
-- Stance machine:
--   hold   the opening: defend near the line until the enemy is located
--   raid   raid_open: fast raiders hit build power; leaves for hold after bad trades while behind
--   late   raid_late: once the unit cap fills (permanent)
-- Share machine: one node, match_enemy (keep our army value up with the scouted enemy's; 35% until the enemy is located).
return {
  name = "core_default", version = 1,

  stance_machine = {
    initial = "hold",
    nodes = {
      hold = { stance = "hold",      x = 120, y = 120 },
      raid = { stance = "raid_open", x = 460, y = 120 },
      late = { stance = "raid_late", x = 290, y = 330 },
    },
    edges = {
      -- enemy located and weak against us -> raid (game_plan's scout rule: enemy < 0.5 x ours and under 2500)
      { from = "hold", to = "raid", prio = 20, min_stay_s = 60, note = "enemy located and weak",
        when = { all = { { sig = "enemy_located" }, { sig = "enemy_vs_army", op = "<", val = 0.5 }, { sig = "enemy_value", op = "<", val = 2500 } } } },
      -- raid -> hold: the enemy turns out strong (enemy > 0.8 x ours, or over 4000)
      { from = "raid", to = "hold", prio = 20, min_stay_s = 60, note = "enemy army is strong",
        when = { all = { { sig = "enemy_located" }, { any = { { sig = "enemy_vs_army", op = ">", val = 0.8 }, { sig = "enemy_value", op = ">", val = 4000 } } } } } },
      -- raid -> hold: behind and the raids trade badly
      { from = "raid", to = "hold", prio = 10, min_stay_s = 90, note = "behind and the raids trade badly",
        when = { all = { { sig = "army_ratio", op = "<", val = 0.85 }, { sig = "bad_trade" } } } },
      -- hold -> raid: ahead on the ground for a minute
      { from = "hold", to = "raid", prio = 10, min_stay_s = 90, hold_s = 60, note = "ahead for a minute",
        when = { sig = "army_ratio", op = ">=", val = 1.4 } },
    },
    any_edges = {
      -- cap_switch: the unit cap is filling -> the late stance for the rest of the game (no edge leaves it)
      { to = "late", prio = 100, note = "unit cap filling",
        when = { all = { { sig = "minute", op = ">=", val = 12 }, { sig = "cap_frac", op = ">=", val = 0.75 } } } },
    },
  },

  share_machine = {
    initial = "match",
    nodes = {
      match = { hook = "match_enemy", cfg = { unscouted = 0.35 }, x = 200, y = 120 },
    },
    edges = {},
  },
}
