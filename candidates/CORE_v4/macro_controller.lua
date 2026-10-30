-- macro_controller.lua -- CORE_v4 (user 2026-10-30): CORE_ROWS_ECO (support elements included) with the nano-column block instead of the mex grids
-- (line_transition/nano_cols, knowledge/bots/nano_cols_2026-10-30.md): NANO_COLS on, SECOND_SPINE off (it competes with the block for the away side).
-- Every other key is CORE_ROWS_ECO's; the block's options (ferry, recovery, T2 con lab, parking ...) are the framework defaults (LT.CFG NC_*).
-- (CORE_ROWS_ECO header follows)
-- Same bot as RAID_BOT (stances raid_open -> hold -> raid_late), with the macro and lab rules moved into the framework
-- (bar_framework/macro_runtime.lua, bar_framework/lab_rules.lua).  A bot is this config: change a key, not the code.
-- Keys and their defaults: the header and M.DEFAULTS of macro_runtime.lua.  unit_controller.lua is still RAID_BOT's, unchanged.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "CORE_v4: the line, the nano-column block, the spine, support elements (bar_framework/macro_runtime.lua)",
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
    NAME        = "CORE_v4",
    -- ROWS THAT SCALE (user 2026-10-26): the 4 lanes as CORE, then a new row (two halves running east and west from the middle of the line, ROW_CONS cons on
    -- each) whenever a con has no lane -- on the side away from the enemy, until the map edge or ROW_UNIT_FRAC of the unit cap.  A con is ordered 5 s after the last one is out
    -- (a metal-bank gate only slowed the T1 phase in eco_sim; CON_BANK_TRIGGER / CON_FALLBACK_FRAMES are the knobs).  T1 phase only; no air lab, so no mex grids yet.
    SCALE_ROWS  = true, ROW_START_FRAME = 0, GOV_ROWS = false,   -- ROW_START_FRAME 0 (was 5:00; eco_sim 8 seeds 2026-10-27: army spent by 6:00 5.6k vs 5.8k, income at 8:00 169 vs 124, at 12:00 358 vs 297, bank 4:00-7:00 ~120 vs ~180 and ~1000 with the line nano cap) -- old note: no con past the first 3 before 5:00: the opening metal goes to the army (replay 2026-10-27: no army spend 4:00-5:00, then a raid at 5:30; eco_sim: army share of spend by 6:00 12% -> 21%, income at 12:00 937 -> 658, still above CORE 528)
    HELP_LANES = true,   -- a con whose lane is done guards a builder on a lane still being built (real game 2026-10-27: 3 cons stood idle at the far end of their lanes from ~9:00)
     ROW_CONS = 3, ROW_BOTH = false, ROW_COLS = 32, ROW_UNIT_FRAC = 0.5, ROW_MAX = 3,   -- 3 grown rows on top of the 4 lanes; each is ONE lane (32 columns, east only), user 2026-10-26
    MAX_CONS    = 1e9,
    CON_GAP     = ROW_GAP, CON_INCOME = ROW_INCOME, CON_BANK_TRIGGER = 150, CON_FALLBACK_FRAMES = 5 * 30,   -- eco_sim (ecosim/sweeps/rows1.json, 6 seeds): a bank gate (100-600) is slower than a con every 5 s: income at 10:00 288 / 283 / 220 / 181 vs 358
    -- ROWS: lines that scale with cons (user 2026-10-27); everything else is CORE (state machine, Dragon sink).
    -- (scouts, AA and the raid-response floors of the lab rules still make their few units)
    -- ARMY_SHARE_FIXED (nil = off): the army share comes from CORE's state machine (MACHINE below, machines/core_default.lua), user 2026-10-27; a number pins it (0 = pure scaling)
    SINK        = true,             -- metal sink on (metal_sink.lua): extra labs make Dragons once the spine cannot spend the income
    SINK_UNIT   = "corcrwh",       -- the sink unit: a Dragon (the framework default, named here so it is visible)
    -- user 2026-10-26 (slimegirl game): nothing is known about the enemy at first, so the army share is 35% (SHARE.unscouted) and the units hold at home;
    -- once the enemy is located, game_plan's `scout` rule picks raid_open (weak enemy army) or stays on hold (strong), see strategy_hooks.game_plan
    CMDR_TO_SPINE = true,          -- user 2026-10-27: the commander moves to the spine once its part of the row is done
    ARMY_SHARE_MAX = 0.8,          -- user 2026-10-29 (BM_akumar6 game: the share sat at 1.0 for 2.5 min and the income went flat): never more than 80% to the army, at least 20% eco
    MACHINE    = "v4_raid",       -- user 2026-10-30: raid only (machines/v4_raid.lua): T1_raid -> T1_5_raid -> t2_raid -> t3_late; the options below are the fallback if it fails to load
    STANCE     = "T1_raid",       -- opening stance (the machine starts here too)
    HOLD_STANCE = "T1_raid",      -- no hold stances in v4: it always raids (raid_response still answers raids at home)
    PLAN        = { raid = "T1_raid", hold = "T1_raid", start_hold = false, scout = { min_stay = 1800 } },
    SHARE       = { unscouted = 0.35 },
    ESTOR_SLOTS = 2,               -- the last two slots of the commander row hold energy storage (line_crew)
    LATE_STANCE = "t3_late",       -- once the unit cap is filling (strategy_hooks.cap_switch)
    -- fast stance transitions (2026-10-16, slot_spine.lua): labs swapped in two waves, a resident T1 vehicle + T2 bot con per block,
    -- no nano parking near a swap, an idle lab becomes a T2 bot lab
    SINK_MAX    = 40,              -- 2026-10-25: 10 labs absorb ~4.3k m/s (10 x ~430) and the bank floated to 600k at 9.4k income; one lab with 32 decoys takes ~430 m/s
    SINK_PARALLEL = 5,             -- labs being placed at once (24+ are needed at 9-10k m/s)
    -- the 4-6k opening (CORE_6K, user 2026-10-26): few nanos on the line and the spine until 7:00 -- the metal goes to the army.  CORE_6K's other half (GRIDS_OPENING 1 / MAX 2, no air-con reserve) is NOT used:
    -- in eco_sim it cut 20-min income from ~4.9k to ~0.9k for about the same army
    -- LINE_NANO_CAP removed 2026-10-27 (user): the line builds as many nanos as it can use -- they are the build power the eco scales with; eco_sim: with the cap the bank sat at ~1300 at 5:00, without ~400

    -- the air lab (and with it the mex grids) is built at 6:00 (best of 6/7/8/9/10:00 in eco_sim, ecosim/sweeps/rows4.json; 3 one-lane rows run dry ~8:30); the spine starts early so the army is not held back
    LT_CFG      = { SHARE_GOV = true, GOV_KEEP_GRIDS = true, NANO_CREW_PAUSE_SHARE = 0.5, GOV_AIR_LAB = true, SHARE_GOV_ALPHA_CAP = 0.6, SHARE_GOV_MIN_ALPHA = 0.5,   -- the share governor makes the machine's high shares (start 1.0, push 0.8, attack 1.0) bind, capped at 60% (eco_sim opening4.json: army 37% of spend by 6:00, 28% by 8:00, income at 20:00 3.7k vs 4.8k without it)
        -- air lab at 6:00 (user 2026-10-27: 4:00 / 5:00 / 5:30 ate too much metal and energy; eco_sim, 8 seeds, 20% army, income at 20:00: 2:30 6342, 3:00 6647, 3:30 6809, 4:00 7068, 4:30 6374, 5:00 5472, 6:00 4388; with no army 3:00-3:30 is best, 8.6-8.9k)
        -- user 2026-10-27 (replay): the lab was late and the bank floated -- from 5:00 it goes down as soon as the metal bank floats (AIR_LAB_FLOAT), 7:00 at the latest
        EARLIEST_FRAME = 150 * 60, LATEST_FRAME = 210 * 60, AIR_LAB_FLOAT = true, AIR_LAB_INCOME = 110, GOV_AIR_LAB_MAX = 600,   -- mirror 2026-10-27: the army share kept the bank ~0 until 7:15, so the bank test never passed; income 110 m/s is reached ~5:30; the governor may hold the lab 20 s at most
        NANO_COLS = true,      -- user 2026-10-30: the nano-column block replaces the mex grids (eco_sim: income doubling 1.71 min vs 2.52 for the grids)
        SECOND_SPINE = false,  -- (CORE_ROWS_ECO: true) off with the block: both want the away side.  user 2026-10-27: build power in two places -- line cons that finish a lane start a second spine (line_transition/spine2.lua), so losing one is not fatal
        SPINE_EARLY = true,    -- the spine (and with it the labs' army want) starts when the vehicle plant has a site, not with the first grid: the army starts at 4:00, the air lab at 5:30.  (These four options sat inside the comment above until 2026-10-27 and were never applied.)
        NANO_FIRST = 2, GRID_REACH = true, GRID_REACH_WAIT = 1800,    -- a new grid opens only when a finished nano reaches one of its nano spots (replaces the bridge nano); after 60 s of waiting it opens anyway (eco_sim rows6.json: no wait limit 1722 m/s at 18:00, 60 s 2858, 20 s 2774, gate off 2890)
        GRID_BRIDGE = false,   -- every grid starts with 2 chained nanos; a grid out of reach of a nano gets a bridge nano from its neighbour first (user 2026-10-26)
         VP2 = true, RAID_FOCUS = false, VP_NANO_ASSIST = false, VP_NANOS_FIRST = true, AIR_LAB_NANOS_FIRST = true, AIR_LAB_NANO_ASSIST = false, VP_WAIT_AIR_LAB = false, VP_DONE_FRAME = 4 * 60 * 30 + 15 * 30, GRID_FAST_INCOME = 1, LAB_NANOS_FIRST_GRID = true, GRID_START = { cap = 2, eco = 0, nanos = 2, wait = 30 * 30 }, T2BOT_LAB = true, DECOY_LINE = true, REZ_LAB = true, REZ_LAB_INCOME = 250,
         SPAM_LAB = true },    -- SPAM_LAB (user 2026-10-30): a T1 bot lab + 4 nanos on the line that makes Grunts for the army groups' spam element (line_transition/spam_lab.lua; unit_controller SUPPORT)   -- REZ_LAB: a T1 bot lab on the line for the rez floor (line_transition/rez_lab.lua)        -- a T2 bot lab on the line's last slots at 600 m/s (t2bot_lab.lua): T2 bot cons for the blocks
    SPINE_CFG   = { CONS_MIN = 1, CONS_PER_INCOME = 500, CONS_MAX = 4, EARLY_CONS_LABS = 3, EARLY_CONS_UNTIL = 10 * 60 * 30, CON_CAP = 1, CON_CAP_UNTIL = 10 * 60 * 30, NANO_SHARE_CAP = 0.6, NANO_BUILD_UTIL = 0.45, LAB_MIN_NANOS = 2, CORE_NANOS = 2, GUARD_NANOS = false, BLOCK_LAB_NANOS = 4, RUSH_NANOS = false, RUSH_SHARE = 2, REBUILD_NANOS = true, FLOAT_MULT = 2.5, EARLY_CONS = 1, FIRST_VP = 2, FIRST_LAB_NANOS = 2, LAB_CANDIDATES = { "corlab", "corvp", "corap", "coralab", "coravp", "coraap", "corgant" }, FRONT = 600, BLOCK_PITCH = 320, WAVE_SWAP = false, BLOCK_CONS = true, IDLE_LAB_T2 = true, BUILD_AHEAD = 0.5, NANO_UTIL_GATE = 0 },
    -- SPINE_CFG (user 2026-10-27): GUARD_NANOS false = nanos in the spine are left alone (no guard of a lab), they are only parked to the army share; REBUILD_NANOS replaces nanos the enemy killed
    -- everything else: the defaults in macro_runtime.lua (RAID_BOT's values)
})
