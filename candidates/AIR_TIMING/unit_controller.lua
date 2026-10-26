-- unit_controller.lua -- AIR_TIMING (as CORE): the unit rules are bar_framework/unit_runtime.lua (CORE's / RAID_BOT's unit controller, moved there
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
    -- bomb_run (the stances' plan.bomb_run): 30 bombers per first wave (the user's number), later waves of 20, ~4 per eco point; between
    -- waves the fighters stay with the air wing (hunts / cover) and a launch takes them as the escort.  v3 (user 2026-10-25: "never attack
    -- in a stream ... always group up"): a wave leaves only with the bombers gathered at the station (GATHER_R), keeps its members
    -- (FIXED_WAVE: new bombers wait for the next one), "launch now" needs 20, and undefended eco is preferred (AA_MAX / AA_PENALTY).
    BOMB_RUN = { LAUNCH_MIN = 30, LAUNCH_FLOOR = 30, RELAUNCH_MIN = 20, LAUNCH_NOW_MIN = 20, GATHER_R = 600, FIXED_WAVE = true,
                 AA_MAX = 0.25, AA_PENALTY = 3, COMMIT_AA = 1.2, RALLY_FIGHTERS = false,
                 ALL_FIGHTERS = true,     -- every fighter escorts the wave (home guards too), back home when it ends
                 -- eyes: 2-5 air scouts fly with each wave over its points; before a launch 2 fighters look for targets while enemy air
                 -- is weak, and 2 scouts look ahead while the picture is thin
                 WAVE_SCOUTS_MIN = 2, WAVE_SCOUTS_MAX = 5, PRE_SCOUTS = 2, SPOT_FIGHTERS = 2, SPOT_AIR_MAX = 600 },
    -- the commander is a target only for a one-pass kill: bombers worth 47 Shadows (20% lost on the way); below that they bomb eco
    -- (STRIKE_PARK false: bomb_run keeps them).  Before this the endgame strike sent bombers one at a time whenever it saw the commander.
    ENDGAME = { STRIKE_MIN_VALUE = 10100, STRIKE_PARK = false },
    STUN_KILL = true,         -- stunned enemies get the nearest free ground units on ATTACK ([STUN] rows)
    -- fighters: home guard, the station behind the army (answering enemy air within 3500 of it or of the base), or a bombing run's escort;
    -- no sweeps over the enemy economy (user 2026-10-25: "it sends out fighters randomly")
    AIR_WING = { NO_SWEEP = true, HUNT_NEAR_R = 3500 },
})
