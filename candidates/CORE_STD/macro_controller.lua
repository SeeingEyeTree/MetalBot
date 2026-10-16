-- macro_controller.lua -- CORE_STD (CORE + standard_t1/t2_defence + sink); CORE: the configuration-driven bot (2026-10-16).
-- Same bot as RAID_BOT (stances raid_open -> hold -> raid_late), with the macro and lab rules moved into the framework
-- (bar_framework/macro_runtime.lua, bar_framework/lab_rules.lua).  A bot is this config: change a key, not the code.
-- Keys and their defaults: the header and M.DEFAULTS of macro_runtime.lua.  unit_controller.lua is still RAID_BOT's, unchanged.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "CORE: build the line, the grids, the spine (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

MACRO.Install(widget, WG, {
    NAME = "CORE_STD", SINK = true,                          -- sink on: Dragons (corcrwh) from T2 air labs in front of the spine
    STANCE = "standard_t1_defence", HOLD_STANCE = false, LATE_STANCE = false,
    INCOME_SWITCH = { to = "standard_t2_defence", income = 1100, hold_s = 20 },
    INCOME_SWITCH2 = { to = "shiva_push", income = 2500, hold_s = 20 },     -- the gantry stance: Shivas only, one gantry per block
    LT_CFG      = { T2BOT_LAB = true, DECOY_LINE = true },        -- a T2 bot lab on the line's last slots at 600 m/s (t2bot_lab.lua): T2 bot cons for the blocks
    SPINE_CFG = { FLOAT_MULT = 2.5, FRONT = 600, BLOCK_PITCH = 320, GATE_MARGIN = 0, LAB_CANDIDATES = { "corvp", "coravp", "corlab", "coralab", "corgant", "corap", "coraap" },
                  WAVE_SWAP = true, BLOCK_CONS = true, IDLE_LAB_T2 = true },
})
