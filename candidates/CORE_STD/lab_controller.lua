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
    SINK = true,
})
