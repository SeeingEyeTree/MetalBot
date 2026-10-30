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
    RAID_RESPONSE = { KEEP_MULT = 1.5, INTRUDER_TTL = 450, OUR_HALF = true, THREAT_HOME = true, THREAT_HOME_R = 2400, NEED_MULT = 2.5, REINFORCE_PULL = 2500, SQUAD_MIN = 700, SQUAD_WAIT = 20, SQUAD_RALLY = 0.4 },   -- THREAT_HOME (user 2026-10-29): under_attack / the con hold count only threats near the eco, scouts at 0.1   -- OUR_HALF (user 2026-10-28): an enemy seen on our side of the map is an intruder; HOME_R is from the eco footprint
    HOME_DEFENCE = { R = 4500, SLACK = 600, POST_R = 1100, LEASH = 500, GROUP_UNDER = 6, EARLY_UNTIL = 0, EARLY_MAX = 0 },   -- v4 tuning (user 2026-10-30: fight further out): R 700 -> 4500 (anything on our side of the map is intercepted by reinforcements), posts 550 -> 1100
    MECH = { HOME_GROUND_AFTER = 3, HOME_GROUND_MIN = 2, HOME_GROUND_SHARE = 0.3, HOME_GROUND_MAX = 12, FIND_SCOUTS = 6 },
    CLICK_ARMY = { EARLY_LAUNCH = { f0 = 7200, av0 = 130, f1 = 25200, av1 = 1800 }, LAUNCH_RATIO_EARLY = 0, MIN_GROUP_UNITS = 1, STAGE_FRAC = 0.12, MAX_GROUPS = 2, UNSEEN_FIRST = true,
                   LEG_LEAD = 600, FLANK_MIN_FRAC = 1.3 },   -- LEG_LEAD (user 2026-10-29): each move ends 600 past the front-most unit, so units do not slow down between legs
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
    -- SUPPORT (user 2026-10-30, bar_framework/army_groups.lua): fixed-size support elements per army group, built up to n and then no more (not a stance share).
    -- raid = each click_army raid group (MAX_GROUPS of them), slow = the slow group while a push runs it, stage = the home blob.  A stance's plan.group_support replaces this.
    -- First guesses, to be tuned: Grunts from the spam lab (SPAM_LAB, macro) run ahead of the raids, an air scout over each raid's target every 30 s.
    SUPPORT = {
        raid = { aa = { n = 3 }, spam = { n = 6 }, scout = { every_s = 30 }, jammer = { n = 1 } },
        slow = { aa = { n = 6 }, rez = { n = 3 }, antinuke = { n = 1 }, jammer = { n = 1 } },
    },
})
