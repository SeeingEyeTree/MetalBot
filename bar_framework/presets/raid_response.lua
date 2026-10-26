-- bar_framework/presets/raid_response.lua  -- named option groups for raid_response's `cfg` (see bot_config.lua)

return {
    -- RAID_BOT (game review 2026-10-13): as raiders die, release responders down to 3x the raid's value in its channel (in the
    -- reviewed game 24 units (18k) were still chasing 2 raiders worth 470); a ground raid is not sized by the air that came with
    -- it; a released responder gets its stance behaviours back.
    -- 2026-10-26 (the _Opal_ game): ground responders answer only inside 700 of the base and are released past 850 -- early Grunts stay home
    HOME = { HOME_R = 700, HOME_SLACK = 150 },
    RAID = { KEEP_MULT = 3.0, CHANNEL_VALUE = true, REASSIGN_STANCE = true },
}
