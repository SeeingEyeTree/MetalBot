-- macro_controller.lua -- HAMMER_ANVIL (2026-10-25): CORE with an anvil-and-hammer strategy.  Only the strategy differs from CORE.
-- The ground army only holds our line (the anvil) and the economy booms behind a 10% army share, as in the 2026-10-25 CORE_HUMAN game.
-- Air is the hammer that kills enemy build power: a one-off T1 bomber burst at ~250 m/s (strategy_hooks.burst_switch) until 30 Shadows
-- stand, launched by bomb_run the moment the burst ends, then later waves while we hold the air, then the sink's Dragon waves
-- (30, build power first).  The ground army (plan army = "defend", unit_runtime) stops raids and pushes when clearly ahead.
-- Stances: anvil_open -> anvil_burst (30 Shadows) -> anvil_hold -> anvil_late (unit cap 75% full).  Everything else is CORE's.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "HAMMER_ANVIL: CORE with the anvil (hold) / hammer (bombers, Dragons) stances (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

MACRO.Install(widget, WG, {
    NAME         = "HAMMER_ANVIL",
    -- the strategy
    STANCE       = "anvil_open",      -- boom behind a cheap T1 screen that only holds
    HOLD_STANCE  = false,             -- no raid plan to fall back from
    LATE_STANCE  = "anvil_late",      -- once the unit cap is filling: raid_late's comp, still defend / push + bomber waves
    BURST_SWITCH = { to = "anvil_burst", back = "anvil_hold", income = 250, hold_s = 20, unit = "corshad", count = 30, burst_s = 300 },   -- until 30 Shadows stand, at most 5 min
    MATCH        = false,             -- bot-vs-bot tests; set true for games against people
    SHARE        = { floor = 0.10 },  -- the person's 10% (v16_share: nothing before 3:00, raid threats lift it)
    SINK_EXTRAS  = { { n = "corcrwh", behaviors = { "dragon_raid", "dragon_defend" },
                       cfg = { dragon_raid = { wave = 30, order = { "bp", "commander", "aa", "eco" } } } } },   -- the hammer: smaller waves, build power first
    -- CORE's background, unchanged
    SINK        = true,
    SINK_UNIT   = "corcrwh",
    SINK_MAX    = 40,
    SINK_PARALLEL = 5,
    LT_CFG      = { T2BOT_LAB = true, DECOY_LINE = true, REZ_LAB = true },
    SPINE_CFG   = { FLOAT_MULT = 2.5, LAB_CANDIDATES = { "corlab", "corvp", "corap", "coralab", "coravp", "coraap", "corgant" }, FRONT = 600, BLOCK_PITCH = 320, WAVE_SWAP = true, BLOCK_CONS = true, IDLE_LAB_T2 = true },
})
