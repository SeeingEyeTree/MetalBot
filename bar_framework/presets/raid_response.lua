-- bar_framework/presets/raid_response.lua  -- named option groups for raid_response's `cfg` (see bot_config.lua)

return {
    -- RAID_BOT (game review 2026-10-13): as raiders die, release responders down to 3x the raid's value in its channel (in the
    -- reviewed game 24 units (18k) were still chasing 2 raiders worth 470); a ground raid is not sized by the air that came with
    -- it; a released responder gets its stance behaviours back.
    RAID = { KEEP_MULT = 3.0, CHANNEL_VALUE = true, REASSIGN_STANCE = true },
}
