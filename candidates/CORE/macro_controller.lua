-- macro_controller.lua -- CORE: the configuration-driven bot (2026-10-16).
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
    NAME        = "CORE",
    SINK        = true,            -- metal sink on (metal_sink.lua): extra labs make Dragons once the spine cannot spend the income
    SINK_UNIT   = "corcrwh",       -- the sink unit: a Dragon (the framework default, named here so it is visible)
    -- user 2026-10-26 (slimegirl game): nothing is known about the enemy at first, so the army share is 35% (SHARE.unscouted) and the units hold at home;
    -- once the enemy is located, game_plan's `scout` rule picks raid_open (weak enemy army) or stays on hold (strong), see strategy_hooks.game_plan
    MACHINE    = "core_default",  -- state machines (machines/core_default.lua, machine_editor.html): when to switch stance and army share; the options below are the fallback if it fails to load
    STANCE     = "hold",          -- opening game plan: hold until the enemy is located
    HOLD_STANCE = "hold",          -- after bad trades while behind (strategy_hooks.game_plan)
    PLAN        = { raid = "raid_open", hold = "hold", start_hold = true, scout = { min_stay = 1800 } },
    SHARE       = { unscouted = 0.35 },
    ESTOR_SLOTS = 2,               -- the last two slots of the commander row hold energy storage (line_crew)
    LATE_STANCE = "raid_late",     -- once the unit cap is filling (strategy_hooks.cap_switch)
    -- fast stance transitions (2026-10-16, slot_spine.lua): labs swapped in two waves, a resident T1 vehicle + T2 bot con per block,
    -- no nano parking near a swap, an idle lab becomes a T2 bot lab
    SINK_MAX    = 40,              -- 2026-10-25: 10 labs absorb ~4.3k m/s (10 x ~430) and the bank floated to 600k at 9.4k income; one lab with 32 decoys takes ~430 m/s
    SINK_PARALLEL = 5,             -- labs being placed at once (24+ are needed at 9-10k m/s)
    LT_CFG      = { VP2 = true, RAID_FOCUS = true, VP_NANO_ASSIST = true, VP_WAIT_AIR_LAB = false, VP_DONE_FRAME = 3 * 60 * 30, GRID_FAST_INCOME = 1, LAB_NANOS_FIRST_GRID = true, GRID_START = { cap = 2, eco = 3, nanos = 1, wait = 30 * 30 }, T2BOT_LAB = true, DECOY_LINE = true, REZ_LAB = true, REZ_LAB_INCOME = 250 },   -- REZ_LAB: a T1 bot lab on the line for the rez floor (line_transition/rez_lab.lua)        -- a T2 bot lab on the line's last slots at 600 m/s (t2bot_lab.lua): T2 bot cons for the blocks
    SPINE_CFG   = { RUSH_NANOS = true, FLOAT_MULT = 2.5, EARLY_CONS = 1, FIRST_VP = 2, FIRST_LAB_NANOS = 2, LAB_CANDIDATES = { "corlab", "corvp", "corap", "coralab", "coravp", "coraap", "corgant" }, FRONT = 600, BLOCK_PITCH = 320, WAVE_SWAP = true, BLOCK_CONS = true, IDLE_LAB_T2 = true, BUILD_AHEAD = 0.5, NANO_UTIL_GATE = 0.5 },
    -- everything else: the defaults in macro_runtime.lua (RAID_BOT's values)
})
