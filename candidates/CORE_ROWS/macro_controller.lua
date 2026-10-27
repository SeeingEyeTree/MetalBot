-- macro_controller.lua -- CORE_ROWS (CORE + a line that scales with rows; user 2026-10-26): the configuration-driven bot (2026-10-16).
-- Same bot as RAID_BOT (stances raid_open -> hold -> raid_late), with the macro and lab rules moved into the framework
-- (bar_framework/macro_runtime.lua, bar_framework/lab_rules.lua).  A bot is this config: change a key, not the code.
-- Keys and their defaults: the header and M.DEFAULTS of macro_runtime.lua.  unit_controller.lua is still RAID_BOT's, unchanged.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "CORE_ROWS: build the line, the grids, the spine (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

-- con #n (n >= 4) is queued ROW_GAP frames after the previous one came out, (and, with CON_FALLBACK_FRAMES, even with no money in the bank)
local ROW_GAP, ROW_INCOME = setmetatable({ [2] = 20 * 30, [3] = 20 * 30 }, { __index = function() return 5 * 30 end }), { [2] = 20, [3] = 30 }

MACRO.Install(widget, WG, {
    NAME        = "CORE_ROWS",
    -- ROWS THAT SCALE (user 2026-10-26): the 4 lanes as CORE, then a new row (two halves running east and west from the middle of the line, ROW_CONS cons on
    -- each) whenever a con has no lane -- on the side away from the enemy, until the map edge or ROW_UNIT_FRAC of the unit cap.  A con is ordered 5 s after the last one is out
    -- (a metal-bank gate only slowed the T1 phase in eco_sim; CON_BANK_TRIGGER / CON_FALLBACK_FRAMES are the knobs).  T1 phase only; no air lab, so no mex grids yet.
    SCALE_ROWS  = true, ROW_CONS = 3, ROW_COLS = 24, ROW_UNIT_FRAC = 0.5,
    MAX_CONS    = 1e9,
    CON_GAP     = ROW_GAP, CON_INCOME = ROW_INCOME, CON_BANK_TRIGGER = 150, CON_FALLBACK_FRAMES = 5 * 30,   -- eco_sim (ecosim/sweeps/rows1.json, 6 seeds): a bank gate (100-600) is slower than a con every 5 s: income at 10:00 288 / 283 / 220 / 181 vs 358
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
    -- the 4-6k opening (CORE_6K, user 2026-10-26): few nanos on the line and the spine until 7:00 -- the metal goes to the army.  CORE_6K's other half (GRIDS_OPENING 1 / MAX 2, no air-con reserve) is NOT used:
    -- in eco_sim it cut 20-min income from ~4.9k to ~0.9k for about the same army
    LINE_NANO_CAP = { max = 4, untilF = 7 * 60 * 30 },
    LT_CFG      = { AIR_LAB = false, VP2 = true, RAID_FOCUS = true, VP_NANO_ASSIST = true, VP_WAIT_AIR_LAB = false, VP_DONE_FRAME = 3 * 60 * 30, GRID_FAST_INCOME = 1, LAB_NANOS_FIRST_GRID = true, GRID_START = { cap = 2, eco = 3, nanos = 1, wait = 30 * 30 }, T2BOT_LAB = true, DECOY_LINE = true, REZ_LAB = true, REZ_LAB_INCOME = 250 },   -- REZ_LAB: a T1 bot lab on the line for the rez floor (line_transition/rez_lab.lua)        -- a T2 bot lab on the line's last slots at 600 m/s (t2bot_lab.lua): T2 bot cons for the blocks
    SPINE_CFG   = { NANO_CAP = { max = 3, untilF = 7 * 60 * 30 }, CORE_NANOS = 2, RUSH_NANOS = true, FLOAT_MULT = 2.5, EARLY_CONS = 1, FIRST_VP = 2, FIRST_LAB_NANOS = 2, LAB_CANDIDATES = { "corlab", "corvp", "corap", "coralab", "coravp", "coraap", "corgant" }, FRONT = 600, BLOCK_PITCH = 320, WAVE_SWAP = true, BLOCK_CONS = true, IDLE_LAB_T2 = true, BUILD_AHEAD = 0.5, NANO_UTIL_GATE = 0.5 },
    -- everything else: the defaults in macro_runtime.lua (RAID_BOT's values)
})
