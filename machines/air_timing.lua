-- AIR_TIMING's rules as a machine (anvil_open -> one T1 bomber burst -> anvil_hold, anvil_late at the cap).  NOT wired in: AIR_TIMING
-- still uses BURST_SWITCH.  Differences: the burst ends after burst_s (the real hook also ends on 30 Shadows alive), and there is no
-- "burst held while unsafe" log.  Shown here as an example of a machine whose share depends on the stance (share machine reads `stance`).
return {
  name = "air_timing", version = 1,

  stance_machine = {
    initial = "open",
    nodes = {
      open  = { stance = "anvil_open",  x = 100, y = 120 },
      burst = { stance = "anvil_burst", x = 400, y = 120 },
      hold  = { stance = "anvil_hold",  x = 700, y = 120 },
      late  = { stance = "anvil_late",  x = 400, y = 330 },
    },
    edges = {
      { from = "open", to = "burst", hold_s = 20, note = "rich enough and not outgunned",
        when = { all = { { sig = "metal_income", op = ">=", val = 250 }, { ["not"] = { sig = "army_ratio", op = "<", val = 0.8 } } } } },
      { from = "burst", to = "hold", prio = 20, note = "outgunned: abort",
        when = { sig = "army_ratio", op = "<", val = 0.5 } },
      { from = "burst", to = "hold", prio = 10, note = "burst over",
        when = { sig = "stance_age_s", op = ">=", val = 300 } },
    },
    any_edges = {
      { to = "late", prio = 100, note = "unit cap filling",
        when = { all = { { sig = "minute", op = ">=", val = 12 }, { sig = "cap_frac", op = ">=", val = 0.75 } } } },
    },
  },

  share_machine = {
    initial = "boom",
    nodes = {
      boom  = { hook = "match_enemy", cfg = { floor = 0.10 }, x = 150, y = 120 },
      burst = { share = 0.65, ramp_s = 20, x = 450, y = 120 },
    },
    edges = {
      { from = "boom",  to = "burst", note = "the stance machine started the burst", when = { sig = "stance", op = "==", val = "anvil_burst" } },
      { from = "burst", to = "boom",  note = "burst finished",                       when = { sig = "stance", op = "!=", val = "anvil_burst" } },
    },
  },
}
