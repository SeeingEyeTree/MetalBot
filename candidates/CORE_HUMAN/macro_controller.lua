-- macro_controller.lua -- CORE_HUMAN (2026-10-24): CORE's economy and labs, but a person picks the stance (stance_panel.lua buttons /
-- `/stance <name>`) and micros the units.  MANUAL_STANCES replaces the automatic stance switches; unit_controller.lua is empty.
-- (CORE's header follows.)
-- macro_controller.lua -- CORE: the configuration-driven bot (2026-10-16).
-- Same bot as RAID_BOT (stances raid_open -> hold -> raid_late), with the macro and lab rules moved into the framework
-- (bar_framework/macro_runtime.lua, bar_framework/lab_rules.lua).  A bot is this config: change a key, not the code.
-- Keys and their defaults: the header and M.DEFAULTS of macro_runtime.lua.  unit_controller.lua is still RAID_BOT's, unchanged.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "CORE_HUMAN: build the line, the grids, the spine (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

MACRO.Install(widget, WG, {
    NAME        = "CORE_HUMAN",
    MANUAL_STANCES = { "raid_open", "hold", "raid_late", "tide_open", "tide_hold", "tide_push", "shiva_push",
                       "mammoth_hold", "pounder_hold", "standard_t1_defence", "standard_t2_defence" },
    SINK        = true,            -- metal sink on (metal_sink.lua): extra labs make Dragons once the spine cannot spend the income
    SINK_UNIT   = "corcrwh",       -- the sink unit: a Dragon (the framework default, named here so it is visible)
    STANCE     = "raid_open",     -- opening game plan
    HOLD_STANCE = "hold",          -- after bad trades while behind (strategy_hooks.game_plan)
    LATE_STANCE = "raid_late",     -- once the unit cap is filling (strategy_hooks.cap_switch)
    -- fast stance transitions (2026-10-16, slot_spine.lua): labs swapped in two waves, a resident T1 vehicle + T2 bot con per block,
    -- no nano parking near a swap, an idle lab becomes a T2 bot lab
    SINK_MAX    = 40,              -- 2026-10-25: 10 labs absorb ~4.3k m/s (10 x ~430) and the bank floated to 600k at 9.4k income; one lab with 32 decoys takes ~430 m/s
    SINK_PARALLEL = 5,             -- labs being placed at once (24+ are needed at 9-10k m/s)
    LT_CFG      = { T2BOT_LAB = true, DECOY_LINE = true, REZ_LAB = true },   -- REZ_LAB: a T1 bot lab on the line for the rez floor (line_transition/rez_lab.lua)        -- a T2 bot lab on the line's last slots at 600 m/s (t2bot_lab.lua): T2 bot cons for the blocks
    SPINE_CFG   = { FLOAT_MULT = 2.5, LAB_CANDIDATES = { "corlab", "corvp", "corap", "coralab", "coravp", "coraap", "corgant" }, FRONT = 600, BLOCK_PITCH = 320, WAVE_SWAP = true, BLOCK_CONS = true, IDLE_LAB_T2 = true },
    -- everything else: the defaults in macro_runtime.lua (RAID_BOT's values)
})
