-- lab_controller.lua -- CORE: the configuration-driven bot (2026-10-16).
-- The lab rules are bar_framework/lab_rules.lua (RAID_BOT's, unchanged); the overrides below are the only difference from it.
-- An empty table is RAID_BOT.  Tunables and tables you can override: the header of lab_rules.lua (M.TUNABLES).

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "CORE: queue-based lab manager (bar_framework/lab_rules.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local LAB = VFS.Include("LuaUI/Widgets/bar_framework/lab_rules.lua")

LAB.Install(widget, WG, {
    REZ_START_FRAME = 8 * 60 * 30,    -- rez floor (user 2026-10-25): the line's T1 bot lab (REZ_LAB) makes rez bots from 8:00 ...
    REZ_BASE = 4, REZ_MAX = 20,       -- ... keeping at least 4 alive (more with the army, up to 20).  2026-10-25 eco_sim (6 seeds): 3:00 / 8 cost 13% income at 10:00
    AIR_SCOUTS_EARLY = 3,         -- user 2026-10-26: the first three scouts are air scouts, ahead of everything in any lab that can build one
    SPINE_CON_FIRST = true,       -- the spine's first ground con goes ahead of the defence picks
    BUDGET_FREE_BANK = 800,       -- a metal bank over 800 lifts the army budget (labs were idle with a 2k bank)
    SINK = false,    -- sink labs make only the sink unit (a Dragon); the macro controller's SINK / SINK_UNIT must match
})
