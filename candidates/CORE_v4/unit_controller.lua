-- unit_controller.lua -- CORE: the unit rules are bar_framework/unit_runtime.lua (CORE's / RAID_BOT's unit controller, moved there
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

-- Creep scouts (scout_net CREEP) and the rez broker (REZ_BROKER) are unit_runtime defaults, so this stays the plain CORE controller.
-- RAID_RESPONSE (user 2026-10-27): responders shrink to 1.5x the raid's value (was 3x) and a raid not seen for 15 s (was 30 s) is over, so units do not over-chase.
-- The opening raid (user 2026-10-27; stance raid_start, army = "raid" + survive): units leave as soon as they are made, no early home guards, the first three ground units are free,
-- a small garrison after that; new production stays home while a ground raid is on the base (HOLD_HOME), six ground scouts first (FIND_SCOUTS), blind groups go to unseen ground.
UNIT.Install(widget, WG, {
    RAID_RESPONSE = { KEEP_MULT = 1.5, INTRUDER_TTL = 450, OUR_HALF = true, THREAT_HOME = true,
                      COVER = {} },   -- COVER (user 2026-10-30, game review A-D; bar_framework/cover_defence.lua): every enemy ground group on our side, radar dots too, gets defenders worth 1.2x it on a line in front of the eco it can reach (pushed out while it does not attack, cutting it off when it dives); no raid launches while one is uncovered. Replaces CONTACTS. Otherwise CORE_ROWS_ECO's army settings
      -- THREAT_HOME (user 2026-10-29): under_attack / the con hold count only threats near the eco, scouts at 0.1   -- OUR_HALF (user 2026-10-28): an enemy seen on our side of the map is an intruder; HOME_R is from the eco footprint
    HOME_DEFENCE = { R = 700, SLACK = 150, POST_R = 550, LEASH = 250, GROUP_UNDER = 6, EARLY_UNTIL = 0, EARLY_MAX = 0 },
    -- HOME_FIGHTER_SHARE / MIN (user 2026-10-31): fighters were half at home guard, the rest at the stage 12% out -- a quarter (at least 2) stays home, the rest wait forward (CLICK_ARMY FIGHTER_*)
    MECH = { HOME_GROUND_AFTER = 3, HOME_GROUND_MIN = 0, HOME_GROUND_SHARE = 0.15, HOME_GROUND_MAX = 4, FIND_SCOUTS = 6, HOME_FIGHTER_SHARE = 0.25, HOME_FIGHTER_MIN = 2 },
    CLICK_ARMY = { EARLY_LAUNCH = { f0 = 7200, av0 = 130, f1 = 25200, av1 = 1800 }, LAUNCH_RATIO_EARLY = 0, MIN_GROUP_UNITS = 1, STAGE_FRAC = 0.12, MAX_GROUPS = 2, UNSEEN_FIRST = true,
                   LEG_LEAD = 600, AIR_PRESSURE = true,
                   -- user 2026-10-31: fighters wait on the enemy's side (half way to the foe with no group out, 1500 behind the biggest group otherwise; both stepped back out of enemy AA)
                   -- and go to a raid group the moment enemy air-to-ground units are near it (split over the threatened groups).  POST_BACK 500 was too close (user)
                   FIGHTER_IDLE_FRAC = 0.5, FIGHTER_POST_BACK = 1500, FIGHTER_RESPOND = true,
                   -- user 2026-11-01: a group with its Quakers screens them (ESCORT) instead of raiding; one whose support is on the way stays out but never dives
                   -- (RESERVE); under air pressure a raid group does not outrun its AA (AA_PACE).  army_groups feeds each group's support every tick.
                   ESCORT = true, RESERVE = true, AA_PACE = true },   -- LEG_LEAD (user 2026-10-29): each move ends 600 past the front-most unit, so units do not slow down between legs
    HOLD_HOME = { VALUE = 300 },
    FAST_RAIDERS = true,        -- user 2026-10-27: raiders and raid defenders with an enemy near get orders at 3 Hz (unit_clock FAST tier)
    RAID_SQUAD = { N = 5 },     -- user 2026-10-27: five gators keep raiding (survive-first) while the army holds, refilled from the blobs
    ENEMY_INTEL = { BLIP_SCOUT_SPEED = 120 },   -- user 2026-10-29: a radar dot faster than any armed enemy type seen (Rovers ~166) is a scout, not army
    PICKET = { N = 4, FRAC = 0.4, START_FRAME = 3 * 60 * 30 },   -- user 2026-10-29: two air scouts fly a picket line across the approach for early warning
    -- SCOUT WING (user 2026-10-30, bar_framework/scout_wing.lua): owns the scout labs' units (macro SCOUT_LAB).  Air scouts: 3 orbit just outside the enemy's
    -- buildings (the ring grows as they build out), 2 orbit our base, the rest sweep the map for stale ground and lost enemy groups; ground scouts hold posts
    -- on the axis, its flanks and our approaches.  Want 6 air + 4 ground, more with income (16 / 10 at most); every loss is rebuilt at once.  { } = its defaults.
    SCOUT_WING = {},
    RAID_CARRY = true,          -- user 2026-10-29 (BM_akumar6 game): a stance flip to hold never recalls a raid; every attacking unit keeps going until it dies
    -- SUPPORT (user 2026-10-31): the AA element while enemy air-to-ground units are near a raid group (mb.raidAir, CLICK_ARMY AIR_PRESSURE; vs DEFENCE_BOT's air
    -- raids died to Shurikens / Wasps): 12 Lashers (T1) or 6 flak trucks (T2) per raid group.  The three standing AA (lab AA_STANDING) stay at home.
    -- user 2026-11-01: from 300 m/s income (held 20 s, then for good) an ARTY element -- 5 Quakers for each of 3 raid groups (support/arty.lua) -- and every raid
    -- group gets 2 flak trucks, 6 while raidAir is on (aa n_arty / n_arty_air).  No launch hold any more (min_frac removed: "units at home when we don't need to
    -- defend are a waste"): groups go out, their support is flown to them (AIR_LIFT, bar_framework/air_lift.lua: Quakers / flak trucks far from their group
    -- go by air transport to 800 behind it).  SUPPORT_FIRST: a new AA unit goes to the elements once the base screen has 2, short elements take the old
    -- GROUND_AA escorts, element AA gets no range_kite (MOVE only, air targets first).  SUPPORT_OFF_GRACE_S: an element switched off keeps its units 2 min.
    SUPPORT = { raid = { aa = { when_air = true, n_t1 = 12, n_t2 = 6, n_arty = 2, n_arty_air = 6, MOVE = true },
                         -- user 2026-11-02 ("the quakers did exactly what I wanted ... they just might not be the right unit"): "stopping power" -- 2 Tzars per
                         -- group (support/stop.lua: support/arty.lua's behaviour, SET_TARGET on the densest clump in range; heavy transports lift them).
                         -- The Quaker element is kept: arty = { n = 5, groups = 3, from_income = 300 } in place of stop brings it back.
                         stop = { n = 2, groups = 3, from_income = 300 } },
                -- user 2026-11-02 (vs CORE_ROWS_ECO, raided all game): T1 stopping power -- up to 3 home groups of 12 Pounders that hold a sector of the base
                -- (support/t1stop.lua), added slowly (one Pounder per 20 s, the "normal" lab tier) as raid pressure rises; a defending group gets its 2 Tzars
                -- first (home records come first in the hand-out)
                home = { t1stop = { n = 12 }, stop = { n = 2 } } },
    SUPPORT_FIRST = true, AIR_LIFT = true, SUPPORT_OFF_GRACE_S = 120,
})
