-- lab_controller.lua  ─  Factory queue manager
-- Priority per idle lab: an outmatched threat first, then scouts, then the defence
-- floor (fighters, vehicle defenders), then the standing roles (rez bots, a radar
-- plane, bombers while hunting), then army: the spine's vehicle lab keeps making the
-- dive army, and the air labs make home-guard Shurikens/Wasps up to a sized standing
-- force (GUARD_*), not whenever metal looks like it is floating.
-- BLACKLIST units are never built by any lab.
--
-- MECH_BOT: the scout count comes from the unit controller (picket ring + recon), the
-- fighter target scales with the enemy air it has seen (game_mechanics 7.3), and rez
-- bots, radar planes and bombers are new kinds (1.4, 7, 9).

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID       = Spring.GetUnitDefID
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spGetMyTeamID        = Spring.GetMyTeamID
local spGetFactoryCommands = Spring.GetFactoryCommands
local spGetUnitCommands    = Spring.GetUnitCommands
local spGetTeamResources   = Spring.GetTeamResources

local DEBUG = false  -- set true to enable verbose logging

-- Floating metal and energy go into Dragons (corcrwh, the Late_game stance's sink) in any lab that can build one.
local DRAGON_FLOAT_ON, DRAGON_FLOAT_OFF = 0.6, 0.35   -- bank fill (both resources) that turns the rule on / off
local dragonFloat = false
local dragonNoted = {}                                -- [labID] = true once echoed

local SCOUT_TARGET = 2       -- until the unit controller publishes scoutWant

-- Army composition, kept deliberately simple.  Internal names, checked against the
-- BAR unit defs: human names are ambiguous ("Dragon" also matches Dragonslayer,
-- Dragon's Claw and Archaic Dragon).  Each lab resolves only what IT can build:
--   corap  (T1 air, the hand-off lab) -> Shuriken
--   coraap (T2 air, one per mex grid) -> Wasp
-- LINE_CLICK: these two are the home GUARD, built up to GUARD_* and no further; the Dragon is gone.
-- What resolved is echoed once per lab, so a miss is visible rather than silent.
local ARMY_PICKS = {
    cheap    = {"corbw"},     -- Shuriken
    main     = {"corape"},    -- Wasp
    -- The slow "trade" group (click_army.lua).  Costs match the user's: Lasher 155 m / 2400 e,
    -- Pounder 220 m / 2600 e (vehicle plant); Sheldon 400 m / 2800 e (T2 bot lab, see T2_SLOW_*).
    slowSupport = {"cormist"},   -- Lasher: long-range support
    slowScreen  = {"corlevlr"},  -- Pounder: holds the line in front of the Lashers
    -- Dedicated air-to-air.  corveng reads aaOnly=true (hits air, cannot hit ground),
    -- which is the only kind of answer a bomber raid actually respects.
    fighter  = {"corveng", "corvamp"},   -- T1 air lab / T2 air lab
    -- corvp.  corgator (speed 85) and corraid (72) are fast enough to RESPOND to a
    -- raid; corwolv/cormist are longer-ranged but too slow to chase anything.
    vcheap   = {"corgator"},
    vmain    = {"corraid"},
    -- Standing roles (game_mechanics 7): a radar plane over the army, and bombers,
    -- which are only built to hunt the commander once the game is won (9).
    radar    = {"corawac"},
    bomber   = {"corshad", "corhurc"},
}
-- Units that read as scouts (fast, unarmed) but have their own job.
local NOT_SCOUTS = { corawac = true, armawac = true }
-- STANCE_BOT (user, 2026-10-12): a slow trickle of ground radar units from T2 labs for the scout rings
-- (unit_controller.lua, scout_rings.lua).  The unit is picked from what the lab can build -- unarmed, ground, radar radius
-- of at least RR.MIN_RADIUS, cheapest first -- and is ordered at most once per RR.GAP frames across ALL labs, up to
-- mb.ringRadarWant (income based, published by the unit controller), so the army still gets the lab.
local RR = {
    MIN_RADIUS = 1400,
    GAP        = 45 * 30,
    MIN_METAL  = 150,       -- do not order while the bank is below this
    last       = -1e9,      -- frame of the last order
    room       = 0,         -- want - have, refreshed each lab tick
    ok         = false,     -- economy allows one (not stalled, bank above MIN_METAL)
    mine       = {},        -- [unitID] = true: alive ring radar units
}
-- STANCE_BOT raid response (user, 2026-10-12).  The unit controller publishes mb.raid (intruder clusters: value, channel,
-- speed) and mb.airLosses (own air units shot down by enemy fighters, last 30 s).  While a raid is live:
--   * the T1 air lab queues only stunners (Shurikens) -- or fighters when the raid is air / our air units are dying to
--     enemy fighters -- ahead of everything else it was doing;
--   * slow units (Lasher/Pounder...) are swapped for fast ones until the fast value ORDERED since the raid began is
--     NEED_MULT x the raiders' value, then the mix goes back to the stance.
local RAID = {
    TTL        = 300,    -- frames mb.raid stays live after the last intruder sighting
    AIR_LOSSES = 2,      -- air units lost to enemy fighters (30 s) that put the air lab on fighters
    NEED_MULT  = 2.0,    -- fast value to order, in raider value (matches the unit controller's RESPOND_NEED_MULT)
    FAST_SPEED = 60,     -- elmos/s: a unit at least this fast can answer a raid
    STUN_MAX   = 30,     -- Shurikens held/ordered above this: stop adding stunners
    STUN_MAX_AIRSUP = 45,  -- RAID_BOT: ...or this many while we hold air superiority (they are the best defence then)
    live = false, since = -1e9, lastLive = -1e9, fastOrdered = 0, stunOrdered = 0, need = 0, swap = false, airLab = false, fighters = false,
    waspOrdered = 0, airSup = false,
}

-- RAID_BOT (game review 2026-10-13): air superiority, the same rule as game_state.airSuperior -- our armed air worth at least
-- 1.5x the scouted enemy air, and over the last 2 min we killed at least as much air as we lost (published by the unit controller).
function RAID.AirSuperior(mb)
    if not (mb and mb.armyAir) then return false end
    local enemyAir = (mb.intel and mb.intel.airValue) or 0
    return mb.armyAir > 0 and mb.armyAir >= 1.5 * enemyAir and (mb.airKills or 0) >= (mb.airLost or 0)
end
local function IsFastDef(defID)
    local d = defID and UnitDefs[defID]
    return d ~= nil and (d.speed or 0) >= RAID.FAST_SPEED and not d.isBuilder and d.weapons ~= nil and #d.weapons > 0
end

-- LINE_CLICK -- home-guard air (Shuriken corbw, Wasp corape).  They are fast, so they slow a raid
-- down, which is what a guard is for.  The old rule built one whenever metal looked like it was
-- floating, and "floating" included income > pull + 15, which is true all through the build-up:
-- the air labs turned out guards without limit and took metal from the economy.  Now the guard is a
-- standing force with a size, rebuilt as it is lost:
--   want = GUARD_BASE + GUARD_PER_ENEMY x (enemy army value we remember)
--   capped at GUARD_INCOME_SECS seconds of metal income and at GUARD_MAX.
-- (Values are metal + energy/70, game_mechanics 2.3.)  The dive army is the vehicle lab's job
-- (spine), not these.  Surplus beyond this goes to the economy, not to more guards.
local GUARD_START_FRAME = 4 * 60 * 30   -- none before the economy has its first labs and cons
local GUARD_BASE        = 500           -- ~4 Shurikens
local GUARD_PER_ENEMY   = 0.35
local GUARD_INCOME_SECS = 45
local GUARD_MAX         = 3500
local GUARD_NAMES       = { corbw = true, corape = true }
-- LINE_CLICK_v16 (user): Shurikens are a cheap defence against anything that can attack, and there were too few early.
-- A standing COUNT of them, separate from the guard value above: ramps from SHURI_RAMP_START to SHURI_EARLY at
-- SHURI_EARLY_FRAME (8-10 by 6:00), then SHURI_STEP more every SHURI_STEP_FRAMES, up to SHURI_MAX.
local SHURI_RAMP_START  = 2 * 60 * 30
local SHURI_EARLY_FRAME = 6 * 60 * 30
local SHURI_EARLY       = 9
local SHURI_STEP        = 6   -- round 3: ~21 by 10:00, capped at 25 (user: 20-25 is enough)
local SHURI_STEP_FRAMES = 3 * 60 * 30
local SHURI_MAX         = 25
local function ShuriWant(frame)
    if frame < SHURI_RAMP_START then return 0 end
    if frame < SHURI_EARLY_FRAME then
        return math.ceil(SHURI_EARLY * (frame - SHURI_RAMP_START) / (SHURI_EARLY_FRAME - SHURI_RAMP_START))
    end
    return math.min(SHURI_MAX, SHURI_EARLY + SHURI_STEP * (1 + math.floor((frame - SHURI_EARLY_FRAME) / SHURI_STEP_FRAMES)))
end

-- LINE_CLICK -- the slow "trade" group is built here, in proportion to what the fast groups cost.
--   T1 vehicle plant: Lashers (long-range support) and Pounders (the screen) as SLOW_SHARE of what the
--   plant spends (by metal + energy/70), Lashers and Pounders SUPPORT_PER_SCREEN : 1; the rest is
--   Gators/Raiders for the fast groups.
--   T2 bot lab (the spine's Mammoth lab): Sheldons as T2_SLOW_SHARE of its value, the rest Mammoths.
-- The fast groups want damage done, the slow group wants to trade well, so it is a share of the
-- army, not all of it.
local SLOW_SHARE         = 0.35
local SUPPORT_PER_SCREEN = 2
local T2_SLOW_SHARE      = 0.35    -- LINE_CLICK_v13d: Sheldons again (slow_front plays them, behind the Mammoths)
local T2_SCREEN_NAME     = "corsumo"    -- Mammoth, what the spine orders from the T2 bot lab
local T2_SUPPORT_NAME    = "cormort"    -- Sheldon
local mix = { fastV = 0, slowV = 0, support = 0, screen = 0, mamV = 0, shelV = 0 }
-- The defence floor: built whether or not metal is floating, because it has to
-- exist BEFORE the raid, not in response to it.
local FIGHTER_TARGET  = 3      -- baseline, in units of the cheapest fighter
-- "defender" = any ground unit that can fight, from any lab, alive or ordered.  The floor was 4: a human rush of ~14
-- gators (1800 value) met 6 ground units at 5:30 and won the game in 7 minutes.  The floor is now 8 and grows with the
-- enemy ground army we have seen (DEFENDER_ENEMY_RATIO x its value, in units of the defender), up to DEFENDER_MAX.
local DEFENDER_TARGET = 8
local DEFENDER_ENEMY_RATIO = 0.5
local DEFENDER_MAX = 24
-- Reactive AA (7.3): "a standing baseline at all times, scaling up reactively once the
-- enemy is seen investing in air".  On top of the baseline, fighters worth
-- AA_VALUE_RATIO x the enemy air we remember, plus a few more the moment an enemy air
-- lab (more for a T2 one) is seen -- before its output shows up.  Values are metal +
-- energy/70, game_mechanics 2.3.  The ratio is a starting guess; the doc says to tune
-- it in test games.
local AA_VALUE_RATIO    = 1.0
local AIRLAB_FIGHTERS   = 2
local T2AIRLAB_FIGHTERS = 4
local FIGHTER_MAX       = 40
local AIR_ALARM_TTL        = 900   -- LINE_CLICK_v16: frames an air alarm keeps the labs on fighters
local AIR_ALARM_MIN        = 6     -- fighters wanted the moment bombers head for the base
local AIR_ALARM_PER_BOMBER = 1.5
-- Rez bots (1.4): a couple always, more as the army grows.
local REZ_START_FRAME   = 5 * 60 * 30  -- none before this: the opening lab's queue is the macro's
local REZ_BASE          = 2
local REZ_PER_ARMY      = 15
local REZ_MAX           = 8
local RADAR_TARGET      = 1
local RADAR_TARGET_LATE = 2
-- RAID_BOT (user 2026-10-13): a standing pool of Hawks (corawac) ready for any scout call; the scout lab puts one AHEAD of
-- its queue while the pool is short (it used to wait for an empty queue, behind cons / guards / bombers).
RAID.RADAR_POOL = 3     -- (in RAID: GameFrame is at Lua 5.1's 60-upvalue limit)
RAID.DRAGON_FIRST_INCOME = 1500 -- metal/s from which floating banks send Dragons ahead of the Wasp raid answer
RAID.SMALL_SHARE = 0.10 -- stance units under this share are picked only while below it (no flak flood)
RAID.SHURI_STANDING = 9-- Shurikens that come before the fighter floor
local RADAR_LATE_FRAME  = 20 * 60 * 30
local BOMBER_TARGET     = 8     -- while hunting only
-- LINE_CLICK_v16 AIR WING (bar_framework/air_wing.lua): a standing force of fighters (hunt enemy air cons, escort) and
-- bombers (strike eco).  Sized in seconds of metal income so it scales with the economy but stays a minority, and only
-- built while energy is not the binding resource (a corhurc costs 18,500 E, a corvamp 5,100 E).
local WING_START_FRAME    = 8 * 60 * 30
local WING_BOMBER_SECS    = 10      -- bomber value wanted = this x metal income (m/s), capped...
local WING_BOMBER_MAX     = 20000
local WING_FIGHTER_SECS   = 6
local WING_FIGHTER_MAX    = 10000
local WING_ENERGY_FRAC    = 0.20    -- build wing units only with this share of energy storage banked
local WING_ON             = true
local wingEnergyOK        = true
local wingIncome          = 0
local function WingFighterWant(frame)
    if not WING_ON or frame < WING_START_FRAME or not wingEnergyOK then return 0 end
    return math.min(WING_FIGHTER_MAX, WING_FIGHTER_SECS * wingIncome)
end
local function WingBomberWant(frame)
    if not WING_ON or frame < WING_START_FRAME or not wingEnergyOK then return 0 end
    return math.min(WING_BOMBER_MAX, WING_BOMBER_SECS * wingIncome)
end

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "Queue-based lab manager with blacklist and per-lab build orders",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── Configuration ─────────────────────────────────────────────────────────────

-- Units that should never be built by any lab.
local BLACKLIST = {
    cortitan = true,
    corsala  = true,
    corarrow = true,
    corvroc  = true,
    cortrem  = true,
    corstorm = true,
    corsok   = true,
    corkarg  = true,
}

-- ── State ─────────────────────────────────────────────────────────────────────

local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")   -- typed WG access (bar_framework/wg_channels.lua)
local myTeamID     = nil
local LB, lb       = nil, nil   -- bar_framework/lab_broker.lua and this widget's broker (wants registered in RegisterWants)
local RegisterWants           -- defined with the wants, below FighterWant
local labs         = {}   -- [labID] = labDefID
local scoutCount   = 0
local myScouts     = {}   -- [unitID] = true
local myFighters   = {}   -- [unitID] = true
-- What this widget has asked for, tracked here rather than read back from factory
-- queues.  Counting only finished (or even started) units left a blind window
-- between ORDERING a unit and its production starting -- minutes long during the
-- economy's deliberate stall -- in which every tick saw the shortfall again and
-- ordered another.  Scouts ordered at 5:40 finished at 7:52; five were queued.
local building = {}       -- [unitID] = kind: started in a lab, not finished
local ordered  = {}       -- { {defID, kind, frame}, ... } ordered, not yet started
local ORDER_TTL = 3600    -- frames before an order that never started is written off
-- Frames to leave a lab alone after ordering it.  Reading a factory's queue back
-- (GetFactoryCommands) lags on the CLIENT process -- the documented host/client
-- asymmetry (game_mechanics 2.7) that forced the macro's ORDER_GRACE_FRAMES to 90.
-- Without this, team 1 saw its just-ordered queue as still empty and re-ordered every
-- tick: five scouts in eight seconds, both labs idle at 5:00, and no fighter up
-- before the bombers.  Slightly above the macro's 90 because this gap looked longer.
local LAB_ORDER_GRACE = 120
local myDefenders  = {}   -- [unitID] = true
local myRez        = {}   -- [unitID] = true
local myRadar      = {}   -- [unitID] = true
local myBombers    = {}   -- [unitID] = true
local myGuards     = {}   -- [unitID] = true: home-guard air (GUARD_NAMES)
local myShuri      = {}   -- [unitID] = true: Shurikens, counted on their own (SHURI_*)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsScoutDef(d)
    if not d then return false end
    local mc = d.modCategories
    if mc then
        for k in pairs(mc) do
            if string.find(k, "scout") then return true end
        end
    end
    local cat = d.category
    if type(cat) == "string" and string.find(string.lower(cat), "scout") then return true end
    local name  = string.lower(d.name or "")
    local hName = string.lower((d.translatedHumanName or d.humanName) or "")
    if string.find(name,  "scout")   or string.find(hName, "scout")
    or string.find(name,  "peep")    or string.find(name,  "flea")
    or string.find(name,  "fink")    or string.find(name,  "phantom")
    or string.find(name,  "weasel")  or string.find(name,  "wheelie") then
        return true
    end
    return d.speed and d.speed > 150 and (not d.weapons or #d.weapons == 0)
end

-- Shared classifier, so "is this a fighter" means the same thing here as it does in
-- the unit controller and the stats tracker.  Loaded in Initialize.
local UQ = nil

-- Real air cover: flies, hits air, cannot hit ground.  Anything merely air-capable
-- does not count -- almost every weapon reads as air-capable unless it says otherwise.
local function IsFighterDef(defID)
    return UQ ~= nil and UQ.is_air(defID) and UQ.is_dedicated_aa(defID)
end

-- A ground unit that can fight: what the vehicle plant is for.
local function IsDefenderDef(d)
    return UQ ~= nil and d ~= nil and (d.speed or 0) > 0 and not d.canFly
       and not d.isBuilder and not d.isFactory and UQ.has_weapons(d.id)
       and not UQ.is_commander(d.id)
end

local function KindOf(defID)
    local d = defID and UnitDefs[defID]
    if not d or d.isFactory then return nil end
    if d.canResurrect and (d.speed or 0) > 0 then return "rez" end
    if NOT_SCOUTS[d.name] then return "radar" end
    if (d.speed or 0) > 0 and not d.canFly and not d.isBuilder and (not d.weapons or #d.weapons == 0)
       and (d.radarRadius or d.radarDistance or 0) >= RR.MIN_RADIUS then return "ringradar" end
    if d.name == "corbw" then return "shuri" end    -- v16: Shurikens have their own standing count (SHURI_*)
    if GUARD_NAMES[d.name] then return "guard" end
    if UQ ~= nil and UQ.is_bomber(defID) then return "bomber" end
    if IsScoutDef(d) then return "scout" end
    if IsFighterDef(defID) then return "fighter" end
    if IsDefenderDef(d) then return "defender" end
    return nil
end

local function NoteOrder(defID, frame)
    local kind = KindOf(defID)
    if kind then ordered[#ordered + 1] = { defID = defID, kind = kind, frame = frame } end
    if RAID.live and UnitDefs[defID] and UnitDefs[defID].name == "corbw" then
        RAID.stunOrdered = RAID.stunOrdered + ((UnitDefs[defID].metalCost or 0) + (UnitDefs[defID].energyCost or 0) / 70)
    end
    if RAID.live and IsFastDef(defID) then
        RAID.fastOrdered = RAID.fastOrdered + ((UnitDefs[defID].metalCost or 0) + (UnitDefs[defID].energyCost or 0) / 70)
    end
    if RAID.live and UnitDefs[defID] and UnitDefs[defID].name == "corape" then
        RAID.waspOrdered = RAID.waspOrdered + ((UnitDefs[defID].metalCost or 0) + (UnitDefs[defID].energyCost or 0) / 70)
    end
end

local armyCache = {}    -- [labDefID] = {cheap=defID, main=defID, floating=defID} or false
local armyFlip  = {}    -- [labID] = alternates cheap/main

local function MatchesName(od, wanted)
    local internal = string.lower(od.name or "")
    local human    = string.lower(od.translatedHumanName or od.humanName or "")
    for _, w in ipairs(wanted) do
        w = string.lower(w)
        if internal == w then return true end
        -- Fall back to the display name only if the internal name is not an exact
        -- match, so a rename does not silently disarm this.
        if human ~= "" and human == w then return true end
    end
    return false
end

-- Resolve ARMY_PICKS against what this lab can actually build.
local function GetArmyPicks(labDefID)
    if armyCache[labDefID] ~= nil then return armyCache[labDefID] end
    local d = UnitDefs[labDefID]
    local picks, found = {}, false
    if d and d.buildOptions then
        for _, optID in ipairs(d.buildOptions) do
            local od = UnitDefs[optID]
            -- Rez bots are builders, so they are matched by flag before the builder filter.
            if od and od.canResurrect and (od.speed or 0) > 0 and not picks.rez then
                picks.rez = optID
                found = true
            end
            if od and od.speed and od.speed > 0 and not od.isBuilder and not od.isFactory then
                for role, names in pairs(ARMY_PICKS) do
                    if not picks[role] and MatchesName(od, names) then
                        picks[role] = optID
                        found = true
                    end
                end
            end
        end
    end
    if found then
        local parts = {}
        for role, defID in pairs(picks) do
            parts[#parts + 1] = role .. "=" .. (UnitDefs[defID] and UnitDefs[defID].name or "?")
        end
        Spring.Echo("[LabCtrl] " .. (d and d.name or "?") .. " army picks: "
                    .. table.concat(parts, " "))
    end
    armyCache[labDefID] = found and picks or false
    return armyCache[labDefID]
end

local buildCache = {}   -- [labDefID] = { scouts={defID,...}, mobile={defID,...} }

local function GetBuildCache(labDefID)
    if buildCache[labDefID] then return buildCache[labDefID] end
    local d     = UnitDefs[labDefID]
    local cache = { scouts = {}, mobile = {} }
    if d and d.buildOptions then
        for _, optID in ipairs(d.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.speed and od.speed > 0
               and not od.isBuilder and not od.isFactory
               and not BLACKLIST[od.name] then
                if IsScoutDef(od) and not NOT_SCOUTS[od.name] then
                    cache.scouts[#cache.scouts + 1] = optID
                elseif od.weapons and #od.weapons > 0 then
                    cache.mobile[#cache.mobile + 1] = optID
                end
            end
        end
    end
    buildCache[labDefID] = cache
    return cache
end

local function CheapestScout(scouts)
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(scouts) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        if cost < bestCost then bestCost = cost; best = optID end
    end
    return best
end

local function PickUnit(options, metalCur)
    local CAP = 500
    local totalWeight, affordable = 0, {}
    for _, optID in ipairs(options) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        if cost <= metalCur then
            affordable[#affordable + 1] = optID
            totalWeight = totalWeight + math.sqrt(math.min(cost, CAP) + 1)
        end
    end
    if #affordable == 0 then
        local cheapest, cheapestCost = nil, math.huge
        for _, optID in ipairs(options) do
            local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
            if cost < cheapestCost then cheapestCost = cost; cheapest = optID end
        end
        return cheapest
    end
    local roll = math.random() * totalWeight
    for _, optID in ipairs(affordable) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        roll = roll - math.sqrt(math.min(cost, CAP) + 1)
        if roll <= 0 then return optID end
    end
    return affordable[#affordable]
end

-- ── Spine labs ────────────────────────────────────────────────────────────────
-- A lab inside a spine cell is run by the spine (WG.Spine, bar_framework/spine.lua).
--   * T2/T3 spine labs (Mammoth / Tiger / Demon): not run by the scout/floor/surplus logic
--     below.  They make cons first and then their army unit continuously, because how much
--     is SPENT on units is decided by how many spine nanos are working, not by whether metal
--     happens to be floating.  ServiceSpineLab keeps the queue QUEUE_DEPTH deep, asking the
--     spine what goes in next.
--   * T1 spine labs (corlab, corvp): the spine queues their hard-coded cons the same way,
--     and everything else they make goes through the normal picks below (scouts, rez bots,
--     defenders, army) -- but only once army_share is above zero.  Before that they make
--     scouts and nothing else.
local SPINE_ORDER_GRACE = 90   -- frames; a factory's queue reads back late (LAB_ORDER_GRACE)

local function UnitValueOf(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end

local function LabCanBuild(labDefID, name)
    local ld = UnitDefs[labDefID]
    if not (ld and ld.buildOptions) then return nil end
    for _, optID in ipairs(ld.buildOptions) do
        local od = UnitDefs[optID]
        if od and od.name == name then return optID end
    end
    return nil
end

-- T2 bot lab: the spine asks for a Mammoth; some of the value goes to Sheldons (long-range support
-- behind the Mammoths) instead.  The first order is a Mammoth so the screen exists before the support.
local function T2Mix(labDefID, defID)
    local d = UnitDefs[defID]
    if not (d and d.name == T2_SCREEN_NAME) then return defID end
    local shel = LabCanBuild(labDefID, T2_SUPPORT_NAME)
    local tot = mix.shelV + mix.mamV
    if shel and tot > 0 and mix.shelV / tot < T2_SLOW_SHARE then
        mix.shelV = mix.shelV + UnitValueOf(shel)
        return shel
    end
    mix.mamV = mix.mamV + UnitValueOf(defID)
    return defID
end

-- T1 vehicle plant: fast (Gator/Raider) or slow (Lasher/Pounder)?  Slow while its share of what the
-- plant has ordered is under SLOW_SHARE (after a first fast unit).  Returns the slow pick or nil.
local function SlowPick(picks)
    if not (picks.slowSupport or picks.slowScreen) then return nil end
    if RAID.swap then return nil end
    local tot = mix.fastV + mix.slowV
    if tot <= 0 or mix.slowV / tot >= SLOW_SHARE then return nil end
    if picks.slowSupport and (not picks.slowScreen or mix.support < SUPPORT_PER_SCREEN * (mix.screen + 1)) then
        return picks.slowSupport
    end
    return picks.slowScreen
end

local function NoteMix(picks, defID)
    local v = UnitValueOf(defID)
    if defID == picks.slowSupport then mix.slowV = mix.slowV + v; mix.support = mix.support + 1
    elseif defID == picks.slowScreen then mix.slowV = mix.slowV + v; mix.screen = mix.screen + 1
    else mix.fastV = mix.fastV + v end
end

-- STANCE_BOT: what a lab can build, as a set, for the strategy's picks.
local canBuildSet = {}   -- [labDefID] = { [defID] = true }
local function CanBuildSet(labDefID)
    local set = canBuildSet[labDefID]
    if not set then
        set = {}
        local ld = UnitDefs[labDefID]
        for _, o in ipairs(ld and ld.buildOptions or {}) do set[o] = true end
        canBuildSet[labDefID] = set
    end
    return set
end

-- The next army unit the stance wants from this lab (nil if it can build none of them).  The strategy owns the mix;
-- this only asks and notes the order.
-- ARMY BUDGET: the strategy's share is a ratio, but the labs only see it as on/off (share > 0 -> build army all the time), so a
-- 20% share still put the whole lab capacity on army and starved the mex grids (army 3x v16's at 10:00).  A token bucket fills at
-- income x share per second; every stance pick spends its metal cost and is refused while the bucket is empty.  A banked metal
-- stock (>= BUDGET_FREE_FILL of storage) means metal is not scarce, so the budget is lifted.  Defence floor / rush / guard picks
-- are not stance picks and are not limited.
local BUDGET_FREE_FILL = 0.5
local BUDGET_CAP_SECONDS = 20          -- the bucket never holds more than this many seconds of army income
local budget = { v = 0, frame = nil, free = false }
local function BudgetUpdate(frame, share, income, metalFill)
    local last = budget.frame
    budget.frame = frame
    budget.free = metalFill >= BUDGET_FREE_FILL
    if not last then return end
    local rate = income * share
    budget.v = math.min(budget.v + rate * (frame - last) / 30, math.max(400, rate * BUDGET_CAP_SECONDS))
end

local function StancePick(labDefID)
    local ST = WG and WG.Strategy
    if not ST then return nil end
    if budget.frame and not budget.free and budget.v <= 0 then return nil end
    local set = CanBuildSet(labDefID)
    local defID
    if RAID.swap then defID = ST:Pick(function(d) return set[d] and IsFastDef(d) end) end
    if not defID then
        -- Round 3 (the 60-flak flood): a lab whose only stance unit is a small-share one (a T2 vehicle plant in raid_late can
        -- build corsent and nothing else) took it at every order, since the pick is the most under-share unit even when
        -- that is over its share.  Small-share units go only while below their share; the rest pick as before.
        local small = {}
        for _, u in ipairs(ST.current and ST.current.units or {}) do
            if u.defID and u.share < RAID.SMALL_SHARE then small[u.defID] = true end
        end
        defID = ST:Pick(function(d) return set[d] end, nil, true)
        if not defID then defID = ST:Pick(function(d) return set[d] and not small[d] end) end
    end
    if defID then
        ST:Note(defID)
        budget.v = budget.v - ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
    end
    return defID
end

-- STANCE_BOT: the cheapest ring radar unit a lab can build (nil if none; cached per lab type).
local ringRadarPick = {}   -- [labDefID] = defID | false
local function RingRadarPick(labDefID)
    local c = ringRadarPick[labDefID]
    if c ~= nil then return c or nil end
    local best
    local ld = UnitDefs[labDefID]
    for _, optID in ipairs(ld and ld.buildOptions or {}) do
        if KindOf(optID) == "ringradar" then
            local od, bd = UnitDefs[optID], best and UnitDefs[best]
            if not bd or (od.metalCost or 0) < (bd.metalCost or 0) then best = optID end
        end
    end
    ringRadarPick[labDefID] = best or false
    if best then Spring.Echo("[LabCtrl] " .. (ld.name or "?") .. " ring radar unit: " .. UnitDefs[best].name) end
    return best
end

-- A lab of the slot spine (bar_framework/slot_spine.lua): cons first (the spine asks for them), then, for T2 labs, the
-- stance's units.  T1 labs (and the adopted vehicle plant) take their stance units in the normal picks below, after
-- scouts, the defence floor and the standing roles.
-- Saviors (cormabm, mobile anti-nuke, built by the T2 vehicle plant): how many we want at this income / enemy silos seen.
local function SaviorWant()
    local _, _, _, inc = Spring.GetTeamResources(myTeamID, "metal")
    inc = inc or 0
    local mb = WG and WG.MetalBot
    local silos = mb and mb.intel and mb.intel.silos or 0
    local cover = CH.SaviorWant(WG)   -- defense_crew cover plan
    if cover then return cover end
    local want = 0
    if inc >= 350 or silos > 0 then want = 1 end
    if inc >= 800 or (silos > 0 and inc >= 350) then want = 2 end
    if inc >= 1500 or (silos > 1 and inc >= 800) then want = 3 end
    return want
end
local function SaviorHave(labID)
    local id = UnitDefNames.cormabm and UnitDefNames.cormabm.id
    if not id then return 0 end
    local n = #(Spring.GetTeamUnitsByDefs(myTeamID, { id }) or {})
    for lab in pairs(labs) do
        for _, c in ipairs(spGetFactoryCommands and spGetFactoryCommands(lab, -1) or {}) do
            if c.id == -id then n = n + 1 end
        end
    end
    return n
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    local okU, rU = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/unit_query.lua")
    if okU then UQ = rU
    else Spring.Echo("[LabCtrl] ERROR loading unit_query: " .. tostring(rU)) end
    local okL, rL = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/lab_broker.lua")
    if okL then
        LB = rL
        lb = LB.New{ cfg = { ORDER_GRACE = LAB_ORDER_GRACE } }
        RegisterWants()
        CH.Publish(WG, "LabBroker", { LB = LB, lb = lb })    -- the macro's con orders (line_transition) go through the same broker
    else Spring.Echo("[LabCtrl] ERROR loading lab_broker: " .. tostring(rL)) end
    if DEBUG then Spring.Echo("[LabCtrl] Initialized team=" .. tostring(myTeamID)) end
end

-- A unit starting in a lab means that lab's pending insert has been honoured.  Scouts
-- are counted from here, not only once finished: counting finished scouts alone let
-- every idle lab queue one each tick while the earlier ones were still being built,
-- and one lab turned out six scouts in six seconds during an air alarm.
function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if teamID ~= myTeamID then return end
    if lb and builderID then LB.UnitStarted(lb, builderID) end
    local kind = KindOf(unitDefID)
    if kind then
        building[unitID] = kind
        for i = 1, #ordered do
            if ordered[i].defID == unitDefID then table.remove(ordered, i); break end
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d then return end

    if d.isFactory then
        labs[unitID] = unitDefID
        local labName = d.name or "?"
        if DEBUG then Spring.Echo("[LabCtrl] Lab registered id=" .. unitID .. " def=" .. labName) end

        return
    end

    building[unitID] = nil
    local kind = KindOf(unitDefID)
    if kind == "rez" then myRez[unitID] = true; return end
    if kind == "ringradar" then RR.mine[unitID] = true; return end
    if kind == "radar" then myRadar[unitID] = true; return end
    if kind == "bomber" then myBombers[unitID] = true; return end
    if kind == "guard" then myGuards[unitID] = true; return end
    if kind == "shuri" then myShuri[unitID] = true; return end
    if IsScoutDef(d) and not myScouts[unitID] then
        myScouts[unitID] = true
        scoutCount = scoutCount + 1
    elseif IsFighterDef(unitDefID) then
        myFighters[unitID] = true
    elseif IsDefenderDef(d) then
        myDefenders[unitID] = true
    end
end

function widget:UnitDestroyed(unitID)
    labs[unitID]        = nil
    myFighters[unitID]   = nil
    myDefenders[unitID]  = nil
    myRez[unitID]        = nil
    RR.mine[unitID]      = nil
    myRadar[unitID]      = nil
    myBombers[unitID]    = nil
    myGuards[unitID]     = nil
    myShuri[unitID]      = nil
    building[unitID]     = nil
    if lb then LB.Forget(lb, unitID) end
    armyFlip[unitID]     = nil
    if myScouts[unitID] then
        myScouts[unitID] = nil
        scoutCount = math.max(0, scoutCount - 1)
    end
end

local function CountAlive(set)
    local n = 0
    for uid in pairs(set) do
        if spGetUnitDefID(uid) then n = n + 1 else set[uid] = nil end
    end
    return n
end

-- Everything of a kind we already have or have asked for: alive, being built, and
-- ordered but not started.  Stale orders expire so a dropped one cannot block forever.
-- metal + energy/70 (game_mechanics 2.3)
local function UnitValue(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end

-- With `valued`, the total value (UnitValue) instead of the count.
local function Have(kind, frame, valued)
    for i = #ordered, 1, -1 do
        if frame - ordered[i].frame > ORDER_TTL then table.remove(ordered, i) end
    end
    local n = 0
    for _, o in ipairs(ordered) do
        if o.kind == kind then n = n + (valued and UnitValue(o.defID) or 1) end
    end
    for uid, k in pairs(building) do
        local defID = spGetUnitDefID(uid)
        if not defID then building[uid] = nil
        elseif k == kind then n = n + (valued and UnitValue(defID) or 1) end
    end
    local sets = { ringradar = RR.mine, scout = myScouts, fighter = myFighters, defender = myDefenders,
                   rez = myRez, radar = myRadar, bomber = myBombers, guard = myGuards, shuri = myShuri }
    local alive = sets[kind] or myDefenders
    if not valued then return n + CountAlive(alive) end
    for uid in pairs(alive) do
        local defID = spGetUnitDefID(uid)
        if defID then n = n + UnitValue(defID) else alive[uid] = nil end
    end
    return n
end

-- How much fighter value we want right now (see AA_VALUE_RATIO).
local FIGHTER_UNIT = nil
local lastFighterWant = nil
local function FighterWant(frame)
    if not FIGHTER_UNIT then
        local ud = UnitDefNames and UnitDefNames["corveng"]
        FIGHTER_UNIT = ud and UnitValue(ud.id) or 113
    end
    local intel = WG and WG.MetalBot and WG.MetalBot.intel
    local want = FIGHTER_TARGET * FIGHTER_UNIT
    if intel then
        if (intel.airLabs or 0) > 0 then want = want + AIRLAB_FIGHTERS * FIGHTER_UNIT end
        if (intel.t2AirLabs or 0) > 0 then want = want + T2AIRLAB_FIGHTERS * FIGHTER_UNIT end
        want = want + (intel.airValue or 0) * AA_VALUE_RATIO
    end
    want = math.min(want, FIGHTER_MAX * FIGHTER_UNIT)
    -- LINE_CLICK_v16: bombers heading for the base (mb.airAlarm, unit controller): fighters now, ahead of
    -- everything the labs were doing, in proportion to the wing -- AIR_ALARM_PER_BOMBER each, at least AIR_ALARM_MIN.
    local alarm = WG and WG.MetalBot and WG.MetalBot.airAlarm
    if alarm and frame - alarm.frame <= AIR_ALARM_TTL then
        local alarmWant = math.max(AIR_ALARM_MIN, math.ceil(alarm.n * AIR_ALARM_PER_BOMBER)) * FIGHTER_UNIT
        want = math.max(want, math.min(alarmWant, FIGHTER_MAX * FIGHTER_UNIT))
    end
    want = want + WingFighterWant(frame)
    local bucket = math.floor(want / FIGHTER_UNIT)
    if bucket ~= lastFighterWant then
        lastFighterWant = bucket
        local sec = math.floor(frame / 30)
        Spring.Echo(string.format("[LabCtrl] %d:%02d fighter target %.0f (~%d fighters): "
            .. "enemy air %.0f, air labs %d (T2 %d)", math.floor(sec / 60), sec % 60, want,
            bucket, intel and intel.airValue or 0, intel and intel.airLabs or 0,
            intel and intel.t2AirLabs or 0))
    end
    return want
end


-- ── The lab broker: this tick's facts, per-lab facts, and the wants ───────────
-- bar_framework/lab_broker.lua owns the queue mechanics (read, tail order, insert ahead of a busy queue, grace, pending).  This
-- file says WHAT each lab should make: GameFrame fills C (counts and room, this tick), Describe works out one lab's facts, and
-- the wants below are the rules, in priority order (high first).  A new unit rule is one AddWant, not an edit of a cascade.

local C = {}   -- this tick's counts, room, stall and resource state (GameFrame fills it; Bump moves it as orders go out)

-- an order went out: move the counts the wants read, so two labs in one tick cannot both answer the same shortfall
local function Bump(defID)
    local k = KindOf(defID)
    if k == "scout" then C.scoutRoom, C.scoutsHave = C.scoutRoom - 1, C.scoutsHave + 1
    elseif k == "fighter" then C.fighterValue = C.fighterValue + UnitValue(defID)
    elseif k == "defender" then C.defendersHave = C.defendersHave + 1
    elseif k == "rez" then C.rezRoom = C.rezRoom - 1
    elseif k == "radar" then C.radarRoom, C.radarHave = C.radarRoom - 1, C.radarHave + 1
    elseif k == "bomber" then
        C.bomberRoom = C.bomberRoom - 1
        C.wingBomberRoom = C.wingBomberRoom - UnitValue(defID)
        C.planBomberRoom = C.planBomberRoom - UnitValue(defID)
    elseif k == "guard" then C.guardHave = C.guardHave + UnitValue(defID)
    elseif k == "shuri" then C.shuriRoom = C.shuriRoom - 1; C.guardHave = C.guardHave + UnitValue(defID) end
end

-- Facts about one lab this tick: what it is (spine / T1 spine), what it can build (picks, cache), and what the defence rules
-- would give it (def, floor, raidChoice, canScout).  The wants read these; they decide nothing about the queue.
local function Describe(labID, labDefID, frame)
    local SP = C.SP
    local isSpine = (SP and SP.IsLab(labID)) and true or false
    local t1Spine = (isSpine and SP.IsT1Lab(labID)) and true or false
    local leaving = (isSpine and SP.IsLeaving and SP.IsLeaving(labID)) and true or false
    local lab = { id = labID, defID = labDefID, isSpine = isSpine, t1Spine = t1Spine,
                  skip = leaving or not spGetUnitDefID(labID), liftedHold = false }
    if lab.skip then return lab end
    -- TILE_BOT: the air lab makes the macro's air cons first, and the opening bot lab is being reclaimed -- nothing of ours goes
    -- in (or ahead of) either queue then.
    local airConsFirst = CH.TileLabHeld(WG, labID)
    -- STANCE_BOT: a raid outranks the macro's hold on the T1 air lab (it owes air cons all game); the stunner / fighter goes in
    -- AHEAD of the queue (the busy-lab branch inserts one at a time), so the cons are delayed by one build at most.
    local liftedHold = false
    -- Round 3 (user 2026-10-14): the air-con hold also gave way to nothing but raids all game (0 floor Shurikens before
    -- 11:00); the standing Shuriken force (RAID.SHURI_STANDING) may go ahead of the owed cons too.
    local shuriLift = false
    if airConsFirst and RAID.airLab and not isSpine and UnitDefs[labDefID] and UnitDefs[labDefID].name == "corap" then
        airConsFirst, liftedHold = false, true
        shuriLift = C.shuriRoom > 0 and Have("shuri", frame) < RAID.SHURI_STANDING
    end
    lab.liftedHold = liftedHold
    -- T2/T3 spine labs are the spine's alone; T1 spine labs share the normal logic
    local picks = (not isSpine or t1Spine) and not airConsFirst and GetArmyPicks(labDefID)
    if not picks then return lab end
    -- army_share is 0 for the first minutes: a T1 spine lab then makes scouts only.
    if t1Spine and SP.Share() <= 0 then picks = {} end
    lab.picks = picks
    local cache    = GetBuildCache(labDefID)
    lab.cache      = cache
    local armyA    = picks.cheap or picks.vcheap
    local armyB    = picks.main  or picks.vmain
    local defender = picks.vcheap or picks.vmain
    lab.armyA, lab.armyB = armyA, armyB

    -- DEFENCE: goes ahead of the queue if the lab is busy.
    local def, defWhy = nil, nil
    if C.rush then
        if C.urgentCh ~= "ground" and picks.fighter then
            def, defWhy = picks.fighter, "rush-air"
        elseif C.urgentCh ~= "air" then
            def, defWhy = defender or armyA or armyB, "rush-ground"
        end
    end
    local needFighter = C.fighterValue < C.fighterWant
    -- Bombers inbound: a fighter goes ahead of the queue in every lab that can build one.
    if not def and C.airAlarm and needFighter and picks.fighter then
        def, defWhy = picks.fighter, "alarm-fighter"
    end
    local defenderWant = DEFENDER_TARGET
    if defender and C.enemyGround > 0 then
        defenderWant = math.min(DEFENDER_MAX, math.max(defenderWant,
            math.ceil(DEFENDER_ENEMY_RATIO * C.enemyGround / math.max(1, UnitValueOf(defender)))))
    end
    local needDefender = C.defendersHave < defenderWant
    local floor, floorWhy = nil, nil
    local isShuriLab = picks.cheap and UnitDefs[picks.cheap] and UnitDefs[picks.cheap].name == "corbw"
    -- RAID_BOT (user 2026-10-13): a standing Shuriken force comes before the fighter floor until RAID.SHURI_STANDING stand (in
    -- the reviewed games the fighter floor -- 40 fighters against heavy enemy air -- took every slot)
    if isShuriLab and C.shuriRoom > 0 and Have("shuri", frame) < RAID.SHURI_STANDING then
        floor, floorWhy = picks.cheap, "floor-shuriken"
    elseif needFighter and picks.fighter then
        floor, floorWhy = picks.fighter, "floor-fighter"
    elseif C.shuriRoom > 0 and isShuriLab then
        floor, floorWhy = picks.cheap, "floor-shuriken"
    elseif needDefender and defender then
        floor, floorWhy = defender, "floor-defender"
    end
    local canScout = not C.rush and C.scoutRoom > 0 and #cache.scouts > 0
    -- STANCE_BOT: the T1 air lab (builds Shurikens, no ground units) makes stunners -- or fighters -- while raided
    local raidChoice = nil
    if RAID.airLab and not isSpine and picks.cheap and not picks.vcheap and not picks.vmain
       and UnitDefs[picks.cheap] and UnitDefs[picks.cheap].name == "corbw" then
        local stunMax = RAID.airSup and RAID.STUN_MAX_AIRSUP or RAID.STUN_MAX
        if RAID.fighters and picks.fighter then raidChoice = picks.fighter
        elseif not RAID.fighters and Have("shuri", frame) < stunMax and RAID.stunOrdered < math.max(RAID.need, 2 * UnitValue(picks.cheap)) then
            raidChoice = picks.cheap
        end
    end
    -- RAID_BOT: the T2 air lab answers a ground raid with Wasps (in the reviewed game it kept making T2 cons while the base was
    -- attacked and we held the air), up to the raid's need in value
    if not raidChoice and not C.dragonFirst and RAID.ground and not RAID.fighters and not isSpine and picks.main and not picks.vcheap
       and not picks.vmain and UnitDefs[picks.main] and UnitDefs[picks.main].name == "corape"
       and RAID.waspOrdered < math.max(RAID.need, 2 * UnitValue(picks.main)) then
        raidChoice = picks.main
    end
    -- the hold was lifted only for the raid answer: nothing else goes into that lab
    if liftedHold and not raidChoice then
        if shuriLift and floorWhy == "floor-shuriken" then def, canScout = nil, false
        else def, floor, canScout = nil, nil, false end
    end
    lab.def, lab.defWhy, lab.floor, lab.floorWhy, lab.canScout, lab.raidChoice = def, defWhy, floor, floorWhy, canScout, raidChoice
    return lab
end

-- every order, from any want: the bot's own bookkeeping.  n = 1 for the first unit a want placed this service (the later ones
-- are queue depth, not new decisions).
local function OnOrder(defID, lab, want, how, frame, n)
    if want.note == false then return end
    if n == 1 or want.noteAll then NoteOrder(defID, frame) end
    if n == 1 then Bump(defID) end
end

local function DragonPick(labDefID)
    local d = UnitDefNames.corcrwh
    return d and CanBuildSet(labDefID)[d.id] and d.id or nil
end

-- the spine's queue depth where there is one, else 3 (Dragons)
local function SpineDepth() local SP = C.SP; return (SP and SP.CFG and SP.CFG.QUEUE_DEPTH) or 3 end

local function RingWant(labDefID, frame)
    if RR.room <= 0 or not RR.ok or frame - RR.last < RR.GAP then return nil end
    return RingRadarPick(labDefID)
end
local function RingOrdered(defID, lab, n, how, frame) RR.last, RR.room = frame, RR.room - 1 end
local function RingLog(defID, lab, frame)
    Spring.Echo(string.format("[LabCtrl] %d:%02d ring-radar     %s in %s", math.floor(frame / 1800),
        math.floor(frame / 30) % 60, UnitDefs[defID].name, UnitDefs[lab.defID].name))
end

RegisterWants = function()
    lb.onOrder = OnOrder
    local function add(spec) LB.AddWant(lb, spec) end
    local function picks(lab) return lab.picks end

    -- ── the spine's labs (T1 and T2/T3) ── cons the spine asks for, stance units on T2, the ring radar unit on T2
    add{ name = "ring-radar-spine", prio = 130, mode = "ahead", noPending = true, grace = SPINE_ORDER_GRACE, why = "ring-radar",
         log = RingLog, onOrder = RingOrdered,
         applies = function(lab) return lab.isSpine and not lab.t1Spine end,
         pick = function(lab, frame) return RingWant(lab.defID, frame) end }
    -- Saviors (cormabm, mobile anti-nuke, built by the T2 vehicle plant), appended wherever the queue stands
    add{ name = "savior", prio = 126, mode = "tail", grace = SPINE_ORDER_GRACE, note = false,
         onOrder = function() C.saviorNeed = false end,   -- one per tick: the queue read-back lags our own order
         applies = function(lab)
             if not (lab.isSpine and not lab.t1Spine and UnitDefNames.cormabm and LabCanBuild(lab.defID, "cormabm")) then return false end
             if C.saviorNeed == nil then C.saviorNeed = SaviorHave() < SaviorWant() end
             return C.saviorNeed
         end,
         pick = function() return UnitDefNames.cormabm.id end }
    -- Keep the queue QUEUE_DEPTH deep: what the spine asks for next, then (T2) the stance's units.
    add{ name = "spine", prio = 125, mode = "topup", grace = SPINE_ORDER_GRACE, note = false, log = false,
         depth = function() return C.SP.CFG.QUEUE_DEPTH end,
         applies = function(lab) return lab.isSpine end,
         pick = function(lab)
             local SP = C.SP
             local defID = SP.NextOrder(lab.id, lab.defID)
             if not defID and not lab.t1Spine and SP.Share() > 0 and not (SP.Held and SP.Held()) then
                 defID = StancePick(lab.defID)
             end
             return defID
         end }

    -- ── defence and the standing floor ── (ahead of a busy queue, one unit at a time)
    -- A floating bank in a T2 air plant: Dragons, outranking everything below (the Wasp raid answer included).
    add{ name = "dragon-first", prio = 110, mode = "empty", why = "dragon", depth = SpineDepth,
         applies = function(lab) return lab.picks and C.dragonFirst and not lab.isSpine and not lab.liftedHold and not C.stalled end,
         pick = function(lab) return DragonPick(lab.defID) end }
    add{ name = "raid", prio = 100, mode = "ahead", why = "raid-air", applies = picks, pick = function(lab) return lab.raidChoice end }
    add{ name = "defence", prio = 95, mode = "ahead", applies = picks, pick = function(lab) return lab.def, lab.defWhy end }
    -- the floor ranks under the first scout when the lab is idle, but over the Hawk pool when the lab is busy
    add{ name = "floor", prio = 80, aheadPrio = 92, mode = "ahead", applies = picks, pick = function(lab) return lab.floor, lab.floorWhy end }
    add{ name = "radar-pool", prio = 90, mode = "ahead", applies = picks,
         pick = function(lab)
             local p = lab.picks
             if lab.id == C.scoutLab and p.radar and C.radarHave < RAID.RADAR_POOL and not C.stalled then return p.radar end
         end }
    -- ONE early scout outranks the floor so the spawn search starts at once; every scout after it waits behind defence.
    -- (Only when the lab can actually build it: letting it block the busy-lab branch deadlocked a busy air lab.)
    add{ name = "first-scout", prio = 85, mode = "empty", why = "scout", applies = picks,
         pick = function(lab) if lab.canScout and C.scoutsHave == 0 then return CheapestScout(lab.cache.scouts) end end }

    -- ── standing roles ── (bombers hunt once the game is won; rez bots, the radar plane, scouts)
    add{ name = "hunt-bomber", prio = 75, mode = "ahead", applies = picks,
         pick = function(lab) if C.bomberRoom > 0 and lab.picks.bomber then return lab.picks.bomber end end }
    add{ name = "wing-bomber", prio = 70, mode = "empty", applies = picks,
         pick = function(lab)
             local b = lab.picks.bomber
             if C.wingBomberRoom > 0 and not C.stalled and b and UnitDefs[b] and UnitDefs[b].name == "corhurc" then return b end
         end }
    add{ name = "plan-bomber", prio = 65, mode = "empty", applies = picks,
         pick = function(lab) if C.planBomberRoom > 0 and not C.stalled and lab.picks.bomber then return lab.picks.bomber end end }
    add{ name = "rez", prio = 60, mode = "empty", applies = picks,
         pick = function(lab) if C.rezRoom > 0 and lab.picks.rez then return lab.picks.rez end end }
    -- LINE_CLICK scout calls: one T2 air lab keeps the radar plane plus one Hawk per call the attack groups have out
    add{ name = "radar-plane", prio = 55, mode = "empty", applies = picks,
         pick = function(lab)
             if C.radarRoom > 0 and lab.picks.radar and not C.stalled and lab.id == C.scoutLab then
                 return lab.picks.radar, (C.callWant > 0 and "scout-call" or "radar-plane")
             end
         end }
    add{ name = "scout", prio = 50, mode = "empty", applies = picks,
         pick = function(lab) if lab.canScout then return CheapestScout(lab.cache.scouts) end end }
    -- a slow trickle of ring radar units from any lab that can build one; a lab with no army picks can still make it
    add{ name = "ring-radar", prio = 45, mode = "ahead", noPending = true, log = RingLog, onOrder = RingOrdered,
         applies = function(lab) return not lab.isSpine and (lab.empty or not lab.picks) end,
         pick = function(lab, frame) return RingWant(lab.defID, frame) end }

    -- ── the army ── the vehicle lab on the spine keeps making the dive army (the spine's share gates it)
    add{ name = "army", prio = 40, mode = "empty", log = false, noteAll = true,
         -- a lab with this much build power behind it eats one cheap unit per tick: queue a few (the spine's QUEUE_DEPTH)
         depth = function() local SP = C.SP; return (WG and WG.Strategy and SP and SP.CFG) and SP.CFG.QUEUE_DEPTH or 1 end,
         applies = function(lab) return lab.picks and lab.t1Spine and not C.stalled end,
         pick = function(lab)
             -- STANCE_BOT: the stance decides (this includes the line's first vehicle plant, adopted by the spine)
             local choice = StancePick(lab.defID)
             if not choice and not (WG and WG.Strategy) then
                 local slowUnit = SlowPick(lab.picks)
                 if slowUnit then choice = slowUnit
                 else
                     local flip = armyFlip[lab.id]
                     armyFlip[lab.id] = not flip
                     choice = (flip and lab.armyA or lab.armyB) or lab.armyA or lab.armyB
                 end
                 if choice then NoteMix(lab.picks, choice) end
             end
             return choice
         end }
    -- Floating bank: Dragons from any lab that can build one (the T2 air plant), queued QUEUE_DEPTH deep.
    add{ name = "dragon-float", prio = 35, mode = "empty", why = "dragon", depth = SpineDepth,
         applies = function(lab)
             return lab.picks and not lab.t1Spine and not lab.isSpine and dragonFloat and not C.stalled and not lab.liftedHold
         end,
         pick = function(lab)
             local d = DragonPick(lab.defID)
             if d and not dragonNoted[lab.id] then
                 dragonNoted[lab.id] = true
                 Spring.Echo("[LabCtrl] float -> Dragon in " .. (UnitDefs[lab.defID].name or "?"))
             end
             return d
         end }
    -- Air labs: guards, only up to the standing size.  No "floating" rule.
    add{ name = "guard", prio = 30, mode = "empty",
         applies = function(lab)
             return lab.picks and not lab.t1Spine and not C.stalled and not lab.liftedHold and C.guardWant - C.guardHave > 0
                    and (lab.picks.cheap or lab.picks.main)
         end,
         pick = function(lab)
             local p = lab.picks
             local flip = armyFlip[lab.id]
             armyFlip[lab.id] = not flip
             return (flip and p.cheap or p.main) or p.cheap or p.main
         end,
         log = function(defID, lab, frame)
             Spring.Echo(string.format("[LabCtrl] %d:%02d guard %s (have %.0f / want %.0f, income %.1f)",
                 math.floor(frame / 1800), math.floor(frame / 30) % 60, UnitDefs[defID] and UnitDefs[defID].name or "?",
                 C.guardHave, C.guardWant, C.metalIncome))
         end }
    -- A lab with no army picks builds NOTHING (the bot lab only makes the two con bots the build order asks for, then is reclaimed).
end

function widget:GameFrame(frame)
    if frame % 60 ~= 0 then return end
    if not myTeamID or not lb then return end

    local ok,  metalCur, metalStorage, metalPull, metalIncome = pcall(spGetTeamResources, myTeamID, "metal")
    local okE, energyCur, energyStorage, energyPull, energyIncome = pcall(spGetTeamResources, myTeamID, "energy")
    wingEnergyOK = okE and type(energyCur) == "number" and type(energyStorage) == "number" and energyStorage > 0
                   and energyCur >= WING_ENERGY_FRAC * energyStorage

    metalCur     = (ok  and type(metalCur)     == "number") and metalCur     or 0
    metalStorage = (ok  and type(metalStorage) == "number") and metalStorage or 0
    metalPull    = (ok  and type(metalPull)    == "number") and metalPull    or 0
    metalIncome  = (ok  and type(metalIncome)  == "number") and metalIncome  or 0
    energyPull   = (okE and type(energyPull)   == "number") and energyPull   or 0
    energyIncome = (okE and type(energyIncome) == "number") and energyIncome or 0
    wingIncome   = metalIncome

    -- Production urgency is judged by the unit controller, which can see both the threat and what is in range to answer it
    -- (threat_map.ProductionUrgency).
    local mb = WG and WG.MetalBot
    C.mb, C.frame, C.metalIncome = mb, frame, metalIncome
    C.urgentCh = mb and mb.urgencyChannel
    C.rush     = ((mb and mb.urgency) or "none") == "rush"
    C.SP       = WG and WG.Spine

    -- The stall guard only blocks DISCRETIONARY spending.  It used to return before anything was decided, and the economy runs
    -- a deliberate stall through the whole growth phase -- so the defence floor, which must be up before the raid, was never built.
    local metalStalling  = metalPull  > metalIncome  * 1.05
    local energyStalling = energyPull > energyIncome * 1.05
    C.stalled = (metalStalling or energyStalling) and metalCur < 50

    -- Late-game float: metal AND energy both banked -> T2 air plants spend it on Dragons (hysteresis, so it does not flap).
    local mFill = metalStorage > 0 and metalCur / metalStorage or 0
    local eFill = (okE and type(energyCur) == "number" and type(energyStorage) == "number" and energyStorage > 0)
                  and energyCur / energyStorage or 0
    BudgetUpdate(frame, (C.SP and C.SP.Share and C.SP.Share()) or 0, metalIncome, mFill)
    if mFill >= DRAGON_FLOAT_ON and eFill >= DRAGON_FLOAT_ON then dragonFloat = true
    elseif mFill < DRAGON_FLOAT_OFF or eFill < DRAGON_FLOAT_OFF then dragonFloat = false end
    -- User 2026-10-14: with a good economy and both banks floating, Dragons outrank the Wasp raid answer in the T2 air lab.
    C.dragonFirst = dragonFloat and metalIncome >= RAID.DRAGON_FIRST_INCOME

    -- Home-guard air: how much is standing/ordered against how much we want (see GUARD_*).
    C.guardHave = Have("guard", frame, true) + Have("shuri", frame, true)
    C.shuriRoom = ShuriWant(frame) - Have("shuri", frame)
    C.guardWant = 0
    if frame >= GUARD_START_FRAME then
        local enemyValue = 0
        local intel = mb and mb.intel
        if intel then enemyValue = (intel.airValue or 0) + (intel.groundValue or 0) end
        C.guardWant = math.min(GUARD_MAX, GUARD_INCOME_SECS * metalIncome, GUARD_BASE + GUARD_PER_ENEMY * enemyValue)
    end
    C.enemyGround = (mb and mb.intel and mb.intel.groundValue) or 0

    -- STANCE_BOT raid state (see RAID)
    do
        local raid = mb and mb.raid
        local live = raid ~= nil and frame - raid.frame <= RAID.TTL and (raid.value or 0) > 0
        local airLosing = mb ~= nil and (mb.airLosses or 0) >= RAID.AIR_LOSSES
        -- a new raid starts the counts over; flickering in and out of sight inside 30 s is the same raid
        if live and frame - RAID.lastLive > 900 then
            RAID.since, RAID.fastOrdered, RAID.stunOrdered, RAID.waspOrdered = frame, 0, 0, 0
        end
        if live then RAID.lastLive = frame end
        if RAID.live ~= live or RAID.fighters ~= (airLosing or (live and raid.channel == "air")) then
            Spring.Echo(string.format("[LabCtrl] %d:%02d raid %s: value %.0f %s, air losses %d",
                math.floor(frame / 1800), math.floor(frame / 30) % 60, live and "ON" or "over",
                raid and raid.value or 0, raid and raid.channel or "-", mb and mb.airLosses or 0))
        end
        RAID.live = live
        RAID.need = live and (raid.value or 0) * RAID.NEED_MULT or 0
        RAID.swap = live and raid.channel ~= "air" and RAID.fastOrdered < RAID.need
        RAID.airLab = live or airLosing
        RAID.fighters = airLosing or (live and raid.channel == "air")
        RAID.ground = live and raid.channel ~= "air"
        RAID.airSup = RAID.AirSuperior(mb)
    end
    -- RAID_BOT: the hold plan's bombers -- while the stance's plan asks for them and we hold the air, the air labs keep
    -- plan.bombers x 30 s of metal income in bombers (click_army's bomber runs use them on enemy build power).
    C.planBomberRoom = 0
    do
        local plan = WG and WG.Strategy and WG.Strategy.Plan and WG.Strategy:Plan()
        if plan and (plan.bombers or 0) > 0 and RAID.airSup then
            C.planBomberRoom = plan.bombers * 30 * metalIncome - Have("bomber", frame, true)
        end
    end

    -- Counts include what is already ordered, and are bumped as orders go out (Bump), so two labs in the same tick cannot both
    -- answer the same shortfall.
    C.fighterValue  = Have("fighter", frame, true)
    C.fighterWant   = FighterWant(frame)
    C.defendersHave = Have("defender", frame)
    C.scoutsHave    = Have("scout", frame)
    C.scoutRoom     = ((mb and mb.scoutWant) or SCOUT_TARGET) - C.scoutsHave
    C.rezRoom       = frame < REZ_START_FRAME and 0
                      or math.min(REZ_MAX, REZ_BASE + math.floor(((mb and mb.armyCount) or 0) / REZ_PER_ARMY)) - Have("rez", frame)
    C.airAlarm      = (mb and mb.airAlarm and frame - mb.airAlarm.frame <= AIR_ALARM_TTL) and true or false
    -- one T2 air lab (the lowest id that can build the Hawk) keeps the radar plane plus one Hawk per call; the others stay
    -- on Wasps / fighters
    C.callWant      = (mb and mb.callScouts) or 0
    C.radarHave     = Have("radar", frame)
    C.radarRoom     = math.max(RAID.RADAR_POOL, (frame >= RADAR_LATE_FRAME and RADAR_TARGET_LATE or RADAR_TARGET) + C.callWant)
                      - C.radarHave
    C.scoutLab = nil
    for id, defID in pairs(labs) do
        local p = GetArmyPicks(defID)
        if p and p.radar and (not C.scoutLab or id < C.scoutLab) then C.scoutLab = id end
    end
    C.bomberRoom     = (mb and mb.hunt) and (BOMBER_TARGET - Have("bomber", frame)) or 0
    -- v16 wing: bombers up to WingBomberWant (in value); room counted in units of the cheapest bomber a lab can build
    C.wingBomberRoom = WingBomberWant(frame) - Have("bomber", frame, true)
    C.saviorNeed     = nil   -- read on first use this tick (savior want)

    RR.room = ((mb and mb.ringRadarWant) or 0) - Have("ringradar", frame)
    RR.ok   = not C.stalled and metalCur >= RR.MIN_METAL

    for labID, labDefID in pairs(labs) do
        LB.Service(lb, Describe(labID, labDefID, frame), frame)
    end
    LB.Update(lb, frame)
end
