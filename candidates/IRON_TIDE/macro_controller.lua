-- macro_controller.lua -- IRON_TIDE: CORE with a boom -> hold -> Shiva push strategy (2026-10-16).
-- Strategy = army share + unit comp: stances tide_open (T1 screen) -> tide_hold (T2 hold, income 600) -> tide_push (Shiva wave,
-- income 1100) -> raid_late once the unit cap fills.  Army share: low floor so the economy booms, lifted by the float rule and
-- by SHARE.match_enemy when we fall behind the scouted enemy.  Everything else is CORE's background.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "IRON_TIDE: CORE with the boom / hold / Shiva push stances (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

MACRO.Install(widget, WG, {
    NAME           = "IRON_TIDE",
    STANCE         = "tide_open",
    HOLD_STANCE    = false,            -- no raid plan to fall back from
    LATE_STANCE    = "raid_late",
    INCOME_SWITCH  = { to = "tide_hold", income = 600,  hold_s = 20 },
    INCOME_SWITCH2 = { to = "tide_push", income = 1100, hold_s = 20 },
    MATCH          = false,            -- bot-vs-bot tests; set true for games against people
    SHARE          = { floor = 0.15, start = 14400 },   -- no army share before 8:00 (CORE does not push early; raid response + defence floor cover raids)
    LT_CFG      = { T2BOT_LAB = true, DECOY_LINE = true },
    SPINE_CFG   = { FLOAT_MULT = 2.5, LAB_CANDIDATES = { "corlab", "corvp", "corap", "coralab", "coravp", "coraap", "corgant" }, FRONT = 600, BLOCK_PITCH = 320, WAVE_SWAP = true, BLOCK_CONS = true, IDLE_LAB_T2 = true },
})
