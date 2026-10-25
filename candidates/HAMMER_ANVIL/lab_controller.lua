-- lab_controller.lua -- HAMMER_ANVIL: CORE's lab config, unchanged (2026-10-25).
-- The lab rules are bar_framework/lab_rules.lua (RAID_BOT's, unchanged); the overrides below are the only difference from it.
-- An empty table is RAID_BOT.  Tunables and tables you can override: the header of lab_rules.lua (M.TUNABLES).

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "HAMMER_ANVIL: queue-based lab manager (bar_framework/lab_rules.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local LAB = VFS.Include("LuaUI/Widgets/bar_framework/lab_rules.lua")

LAB.Install(widget, WG, {
    REZ_START_FRAME = 3 * 60 * 30,    -- rez floor (user 2026-10-25): the line's T1 bot lab (REZ_LAB) makes rez bots from ~3:00 ...
    REZ_BASE = 8, REZ_MAX = 20,       -- ... keeping at least 8 alive (more with the army, up to 20)
    SINK = true,    -- sink labs make only the sink unit (a Dragon); the macro controller's SINK / SINK_UNIT must match
})
