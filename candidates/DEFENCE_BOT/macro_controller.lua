-- macro_controller.lua -- DEFENCE_BOT: CORE with the maneuver-defence stances (2026-10-16).
-- A CORE bot is this config: the stance says what to build and how it is played (stances/standard_t1_defence.lua: Brutes in blobs,
-- Pounder backstop, Rascal shadows; plan.army = "maneuver" makes the unit controller run bar_framework/maneuver_defence.lua).
-- standard_t2_defence (Tigers + Tzars, no T1 units) is taken once metal income holds INCOME_SWITCH.income.
-- No raid / hold / late stances: this bot never raids.

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "DEFENCE_BOT: build the line, the grids, the spine (bar_framework/macro_runtime.lua)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

local MACRO = VFS.Include("LuaUI/Widgets/bar_framework/macro_runtime.lua")

MACRO.Install(widget, WG, {
    NAME          = "DEFENCE_BOT",
    STANCE        = "standard_t1_defence",
    HOLD_STANCE   = false,
    LATE_STANCE   = false,
    INCOME_SWITCH = { to = "standard_t2_defence", income = 600, hold_s = 20 },   -- m/s smoothed income that holds for 20 s
    -- everything else: the defaults in macro_runtime.lua (RAID_BOT's values)
})
