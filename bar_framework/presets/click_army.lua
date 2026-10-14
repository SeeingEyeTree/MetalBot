-- bar_framework/presets/click_army.lua  -- named option groups for click_army's `cfg` (see bot_config.lua)

return {
    -- RAID_BOT (game review 2026-10-13): early small groups, commit to build power or escape when surrounded, hole finding round
    -- the target, SET_TARGET raiding, fighters waiting out of enemy AA, scout calls along the group's route.  The slow group is
    -- off in RAID_BOT (no slow_front); bombers stay with click_army's UpdateBombers (air_wing logged "0 bombers" all game).
    RAID = {
        SET_TARGET         = true,
        -- flat 300 until 6:00, then up to 1800 by 14:00 (first run with 350 at 3:00 -> 1800 at 10:00: the ramp held a 678-av
        -- stage back at 5:30 and the first group left at 6:30)
        EARLY_LAUNCH       = { f0 = 10800, av0 = 300, f1 = 25200, av1 = 1800 },
        LAUNCH_RATIO_EARLY = 1.0,
        BLIND_LAUNCH       = true,
        MIN_GROUP_UNITS    = 3,
        LAB_EXIT_R         = 450,
        LAB_EXIT_W         = 0.2,
        ENGAGE             = true,
        HOLE_FIND          = true,
        DIFF_PENALTY       = 0.05,
        FIGHTER_POST       = true,
        SCOUT_ROUTE        = true,
    },
}
