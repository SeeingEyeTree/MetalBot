-- bar_framework/presets/line_transition.lua  -- named option groups for line_transition's `cfg` (see bot_config.lua)
--
--   cfg = BC.Preset("line_transition", "RETROFIT", "GRID_HELP", { CON_HOLD = fn })
--
-- Each group is one idea; a bot lists the ideas it wants.  The comment on a group says what it does and where it came from
-- (knowledge/session_2026-10-12_energy_eco.md has the numbers).  Anything left out keeps line_transition's default.

return {
    -- air cons wait at the back of the line instead of the front
    CONS_AT_BACK = { AIR_CON_AT_BACK = true },

    -- finished mex grids are retrofitted (upgrade blueprint) by cons the labs make for it, also while metal floats
    RETROFIT = { RETROFIT_MEX_DONE = true, UPGRADE_CONS_PER_LAB = 4, RETROFIT_FLOAT_CONS = true, RETROFIT_FLOAT_FRAC = 0,
                 RETROFIT_FLOAT_BATCH = 6 },

    -- an [AUDIT] log row every minute (what every con and nano is doing)
    AUDIT = { AUDIT_EVERY = 1800 },

    -- grids may take up to 60% of the unit cap, and any con with nothing better (at most 3 per grid) helps build them
    GRID_HELP = { GRID_CAP_FRAC = 0.60, GRID_HELPERS = true, HELP_ANY = true, HELP_MAX = 3 },

    -- energy before everything while wind is consolidated: fusions first, every spare air con and the nanos help; "energy
    -- binds" when the bank holds under 20 s of pull or income is under 15x metal income (STANCE_BOT eco session 2026-10-12)
    ENERGY_PUSH = { FUSION_HELPERS = true, ENERGY_PRIORITY = true, NANO_CREW = true, EP_BANK_SECONDS = 20, EP_RATIO = 15,
                    EP_INFLIGHT = 6, EP_CON_BATCH = 4, EP_CON_EVERY = 450, EP_CON_FORCE = true },

    -- energy cells (fusion groups): up to 4 at once, the first one early, built by cons made for it
    ENERGY_CELLS = { ECELL_MAX_ACTIVE = 4, ECELL_FIRST = true, ECELL_MAKE_CON = true },

    -- a lost grid is rebuilt, and a lost piece of the line is rebuilt (RAID_BOT game review 2026-10-13)
    RECOVER = { GRID_RECOVER = true, LINE_RECOVER = true },

    -- a second T1 air lab on the line by 8:00, with nano help (RAID_BOT round 2)
    SECOND_AIR_LAB = { SECOND_AIR_LAB = true, RESERVE_COUNT_IDLE = false, LAB2_FRAME = 8 * 60 * 30, LAB2_LATEST = 8 * 60 * 30,
                       LAB2_NANO_HELP = true },
}
