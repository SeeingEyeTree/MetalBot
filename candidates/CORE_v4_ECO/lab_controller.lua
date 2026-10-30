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
    AIR_SCOUTS_EARLY = 0,         -- user 2026-10-27: the air lab comes at 5:30, so the first scouts are six GROUND scouts (corfav) from the vehicle plant (unit_controller MECH.FIND_SCOUTS = 6)
    SCOUTS_FIRST = 6,             -- user 2026-10-27: the first six units out of the vehicle plant are ground scouts (inserted at the head of its queue)
    ARMY_QUEUE_MIN = 2,           -- user 2026-10-27: every army lab keeps at least two units queued (nanos waited for the next order between units)
    SPINE_CON_FIRST = true,       -- the spine's first ground con goes ahead of the defence picks
    BUDGET_FREE_BANK = 800,       -- a metal bank over 800 lifts the army budget (labs were idle with a 2k bank)
    SINK = true,     -- sink labs make only the sink unit (a Dragon); the macro controller's SINK / SINK_UNIT must match
    AIR_AA_GATE = { MIN = 2000, RATIO = 1.0, STATIC_W = 0.25 },   -- user 2026-10-29 (BM_akumar6 game: 24% of metal into Shurikens / Wasps that died to flak + Hawks): none while the enemy AA is large
})
