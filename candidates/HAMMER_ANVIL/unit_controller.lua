-- unit_controller.lua -- HAMMER_ANVIL (as CORE): the unit rules are bar_framework/unit_runtime.lua (CORE's / RAID_BOT's unit controller, moved there
-- unchanged on 2026-10-25).  The strategy (stances, plan.army, share) comes from WG.Strategy, so a variant needs no code here.
-- Overrides: the header of unit_runtime.lua.

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "Node-curve contact line with sector scouting (macro_controller compatible)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local UNIT = VFS.Include("LuaUI/Widgets/bar_framework/unit_runtime.lua")

UNIT.Install(widget, WG, {
    -- bomb_run (the stances' plan.bomb_run): 30 bombers per first wave (the user's number), later waves of 12, ~4 per eco point;
    -- between waves the fighters stay with the air wing (hunts / cover) and a launch takes them as the escort
    BOMB_RUN = { LAUNCH_MIN = 30, LAUNCH_FLOOR = 30, RELAUNCH_MIN = 12, RALLY_FIGHTERS = false },
})
