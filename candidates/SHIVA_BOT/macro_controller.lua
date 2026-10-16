-- macro_controller.lua -- SHIVA_BOT: CORE with the shiva_push stance (2026-10-16).  Only Shivas are built (stances/shiva_push.lua);
-- click_army advances them across the map and the stance's `kite` behaviour backs the group off from anything closing on it.
-- No hold / late / T2 switch stances: it is one stance all game.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "SHIVA_BOT: build the line, the grids, the spine (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

MACRO.Install(widget, WG, {
    NAME        = "SHIVA_BOT",
    STANCE      = "shiva_push",
    HOLD_STANCE = false,
    LATE_STANCE = false,
    -- everything else: the defaults in macro_runtime.lua (RAID_BOT's values)
})
