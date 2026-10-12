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

local SCOUT_TARGET = 2        -- until the unit controller publishes scoutWant

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
    live = false, since = -1e9, lastLive = -1e9, fastOrdered = 0, stunOrdered = 0, need = 0, swap = false, airLab = false, fighters = false,
}
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
local SHURI_STEP        = 3
local SHURI_STEP_FRAMES = 3 * 60 * 30
local SHURI_MAX         = 45
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

local myTeamID     = nil
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
local labPending   = {}   -- [labID] = frame a defence unit was put ahead of its queue
-- Frames to leave a lab alone after ordering it.  Reading a factory's queue back
-- (GetFactoryCommands) lags on the CLIENT process -- the documented host/client
-- asymmetry (game_mechanics 2.7) that forced the macro's ORDER_GRACE_FRAMES to 90.
-- Without this, team 1 saw its just-ordered queue as still empty and re-ordered every
-- tick: five scouts in eight seconds, both labs idle at 5:00, and no fighter up
-- before the bombers.  Slightly above the macro's 90 because this gap looked longer.
local LAB_ORDER_GRACE = 120
local labOrderFrame  = {}   -- [labID] = frame this widget last ordered it
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

local function QueueEmpty(labID)
    if spGetFactoryCommands then
        local cmds = spGetFactoryCommands(labID, -1)
        return not cmds or #cmds == 0
    end
    local cmds = spGetUnitCommands(labID, -1)
    return not cmds or #cmds == 0
end

-- Put a unit NEXT in a lab's queue, ahead of whatever is waiting.  The macro keeps
-- the air lab's queue full of air constructors for the grid system, and this widget
-- used to act only when a queue was empty -- so from the weaker slot the air lab
-- never had a gap, no fighter was ever built, and bombers killed the commander at
-- 6:15.  Pattern copied from BAR's own unit_factory_quota.lua.  Position 1 (after
-- the unit currently being built) rather than 0: 0 cancels the build in progress,
-- and throwing away a half-built constructor is a pure loss.
local CMD_INSERT       = CMD and CMD.INSERT
local CMD_OPT_ALT      = (CMD and CMD.OPT_ALT) or 128
local CMD_OPT_CTRL     = (CMD and CMD.OPT_CTRL) or 64
local CMD_OPT_INTERNAL = (CMD and CMD.OPT_INTERNAL) or 8
local PENDING_TIMEOUT  = 600   -- frames before an insert that never started is retried

local function InsertNext(labID, defID)
    if not CMD_INSERT then
        spGiveOrderToUnit(labID, -defID, {}, {})
        return
    end
    local _, busyTarget = Spring.GetUnitWorkerTask(labID)
    local pos = busyTarget and 1 or 0
    spGiveOrderToUnit(labID, CMD_INSERT,
        { pos, -defID, CMD_OPT_ALT + CMD_OPT_INTERNAL }, CMD_OPT_ALT + CMD_OPT_CTRL)
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
local function StancePick(labDefID)
    local ST = WG and WG.Strategy
    if not ST then return nil end
    local set = CanBuildSet(labDefID)
    local defID
    if RAID.swap then defID = ST:Pick(function(d) return set[d] and IsFastDef(d) end) end
    if not defID then defID = ST:Pick(function(d) return set[d] end) end
    if defID then ST:Note(defID) end
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

-- One ring radar unit, ahead of the queue, if one is wanted and none was ordered lately.  Any lab that can build one.
local function MaybeRingRadar(labID, labDefID, frame)
    if RR.room <= 0 or not RR.ok or frame - RR.last < RR.GAP then return false end
    local pick = RingRadarPick(labDefID)
    if not pick then return false end
    if QueueEmpty(labID) then spGiveOrderToUnit(labID, -pick, {}, {}) else InsertNext(labID, pick) end
    RR.last, RR.room = frame, RR.room - 1
    NoteOrder(pick, frame)
    labOrderFrame[labID] = frame
    Spring.Echo(string.format("[LabCtrl] %d:%02d ring-radar     %s in %s", math.floor(frame / 1800),
        math.floor(frame / 30) % 60, UnitDefs[pick].name, UnitDefs[labDefID].name))
    return true
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
    if WG and WG.AntiNuke and WG.AntiNuke.saviorWant then return WG.AntiNuke.saviorWant end   -- defense_crew cover plan
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

local function ServiceSpineLab(SP, labID, labDefID, frame, t1)
    if not spGetUnitDefID(labID) then return end
    if SP.IsLeaving and SP.IsLeaving(labID) then return end
    local last = labOrderFrame[labID]
    if last and frame - last < SPINE_ORDER_GRACE then return end
    if not t1 and MaybeRingRadar(labID, labDefID, frame) then return end
    local cmds = spGetFactoryCommands and spGetFactoryCommands(labID, -1)
    local have = cmds and #cmds or 0
    local depth = SP.CFG.QUEUE_DEPTH
    local ordered = 0
    local sav = UnitDefNames.cormabm
    if sav and not t1 and LabCanBuild(labDefID, "cormabm") and SaviorHave() < SaviorWant() then
        spGiveOrderToUnit(labID, -sav.id, {}, {})
        ordered = ordered + 1
        have = have + 1
    end
    for _ = have + 1, depth do
        local defID = SP.NextOrder(labID, labDefID)
        if not defID and not t1 and SP.Share() > 0 and not (SP.Held and SP.Held()) then
            defID = StancePick(labDefID)
        end
        if not defID then break end
        spGiveOrderToUnit(labID, -defID, {}, {})
        ordered = ordered + 1
    end
    if ordered > 0 then labOrderFrame[labID] = frame end
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    local okU, rU = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/unit_query.lua")
    if okU then UQ = rU
    else Spring.Echo("[LabCtrl] ERROR loading unit_query: " .. tostring(rU)) end
    if DEBUG then Spring.Echo("[LabCtrl] Initialized team=" .. tostring(myTeamID)) end
end

-- A unit starting in a lab means that lab's pending insert has been honoured.  Scouts
-- are counted from here, not only once finished: counting finished scouts alone let
-- every idle lab queue one each tick while the earlier ones were still being built,
-- and one lab turned out six scouts in six seconds during an air alarm.
function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if teamID ~= myTeamID then return end
    if builderID and labPending[builderID] then labPending[builderID] = nil end
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
    labPending[unitID]   = nil
    labOrderFrame[unitID] = nil
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

local function Announce(frame, why, choice, labDefID, inserted)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[LabCtrl] %d:%02d %-14s %s in %s%s",
        math.floor(sec / 60), sec % 60, why,
        UnitDefs[choice] and UnitDefs[choice].name or "?",
        UnitDefs[labDefID] and UnitDefs[labDefID].name or "?",
        inserted and " (ahead of queue)" or ""))
end

function widget:GameFrame(frame)
    if frame % 60 ~= 0 then return end
    if not myTeamID then return end

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

    -- Production urgency is judged by the unit controller, which can see both the
    -- threat and what is in range to answer it (threat_map.ProductionUrgency).
    local mb       = WG and WG.MetalBot
    local urgency  = (mb and mb.urgency) or "none"
    local urgentCh = mb and mb.urgencyChannel
    local rush     = urgency == "rush"

    -- The stall guard now only blocks DISCRETIONARY spending.  It used to return
    -- before anything was decided, and the economy runs a deliberate stall through
    -- the whole growth phase -- so the defence floor, which exists precisely because
    -- it must be up before the raid, was silently never built.
    local metalStalling  = metalPull  > metalIncome  * 1.05
    local energyStalling = energyPull > energyIncome * 1.05
    local stalled        = (metalStalling or energyStalling) and metalCur < 50

    -- Home-guard air: how much is standing/ordered against how much we want (see GUARD_*).
    local guardHave = Have("guard", frame, true) + Have("shuri", frame, true)
    local shuriRoom = ShuriWant(frame) - Have("shuri", frame)
    local guardWant = 0
    if frame >= GUARD_START_FRAME then
        local enemyValue = 0
        local intel = mb and mb.intel
        if intel then enemyValue = (intel.airValue or 0) + (intel.groundValue or 0) end
        guardWant = math.min(GUARD_MAX, GUARD_INCOME_SECS * metalIncome,
                             GUARD_BASE + GUARD_PER_ENEMY * enemyValue)
    end

    local enemyGround = (mb and mb.intel and mb.intel.groundValue) or 0

    -- STANCE_BOT raid state (see RAID)
    do
        local raid = mb and mb.raid
        local live = raid ~= nil and frame - raid.frame <= RAID.TTL and (raid.value or 0) > 0
        local airLosing = mb ~= nil and (mb.airLosses or 0) >= RAID.AIR_LOSSES
        -- a new raid starts the counts over; flickering in and out of sight inside 30 s is the same raid
        if live and frame - RAID.lastLive > 900 then RAID.since, RAID.fastOrdered, RAID.stunOrdered = frame, 0, 0 end
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
    end

    -- Counts include what is already ordered, and are bumped as orders go out below,
    -- so two labs in the same tick cannot both answer the same shortfall.
    local fighterValue  = Have("fighter", frame, true)
    local fighterWant   = FighterWant(frame)
    local defendersHave = Have("defender", frame)
    local scoutsHave    = Have("scout", frame)
    local scoutRoom     = ((mb and mb.scoutWant) or SCOUT_TARGET) - scoutsHave
    local rezRoom       = frame < REZ_START_FRAME and 0
                          or math.min(REZ_MAX, REZ_BASE
                            + math.floor(((mb and mb.armyCount) or 0) / REZ_PER_ARMY))
                          - Have("rez", frame)
    -- LINE_CLICK scout calls: one T2 air lab (the lowest id that can build the Hawk) keeps the
    -- radar plane plus one Hawk per call the attack groups have out (mb.callScouts, published by the
    -- unit controller).  The other T2 labs stay on Wasps / fighters.
    local callWant      = (mb and mb.callScouts) or 0
    local radarRoom     = (frame >= RADAR_LATE_FRAME and RADAR_TARGET_LATE or RADAR_TARGET)
                          + callWant - Have("radar", frame)
    local scoutLab = nil
    for id, defID in pairs(labs) do
        local p = GetArmyPicks(defID)
        if p and p.radar and (not scoutLab or id < scoutLab) then scoutLab = id end
    end
    local bomberRoom    = (mb and mb.hunt) and (BOMBER_TARGET - Have("bomber", frame)) or 0
    -- v16 wing: bombers up to WingBomberWant (in value); room counted in units of the cheapest bomber a lab can build
    local wingBomberRoom = WingBomberWant(frame) - Have("bomber", frame, true)

    RR.room = ((mb and mb.ringRadarWant) or 0) - Have("ringradar", frame)
    RR.ok   = not stalled and metalCur >= RR.MIN_METAL

    local SP = WG and WG.Spine
    for labID, labDefID in pairs(labs) do
        local isSpine  = SP and SP.IsLab(labID)
        local t1Spine  = isSpine and SP.IsT1Lab(labID)
        if isSpine then ServiceSpineLab(SP, labID, labDefID, frame, t1Spine) end
        local leaving = isSpine and SP.IsLeaving and SP.IsLeaving(labID)
        local recent = labOrderFrame[labID] and frame - labOrderFrame[labID] < LAB_ORDER_GRACE
        -- T2/T3 spine labs are the spine's alone; T1 spine labs share the normal logic.
        -- TILE_BOT: the air lab makes the macro's air cons first, and the opening bot lab
        -- is being reclaimed -- nothing of ours goes in (or ahead of) either queue then.
        local airConsFirst = WG and WG.TileLabHold and WG.TileLabHold(labID)
        -- STANCE_BOT: a raid outranks the macro's hold on the T1 air lab (it owes air cons all game); the stunner / fighter
        -- goes in AHEAD of the queue (the busy-lab branch inserts one at a time), so the cons are delayed by one build at most.
        local liftedHold = false
        if airConsFirst and RAID.airLab and not isSpine and UnitDefs[labDefID] and UnitDefs[labDefID].name == "corap" then
            airConsFirst, liftedHold = false, true
        end
        local picks  = (not isSpine or t1Spine) and not recent and not airConsFirst and not leaving
                       and spGetUnitDefID(labID) and GetArmyPicks(labDefID)
        -- army_share is 0 for the first minutes: a T1 spine lab then makes scouts only.
        if picks and t1Spine and SP.Share() <= 0 then picks = {} end
        if picks then
            local cache    = GetBuildCache(labDefID)
            local armyA    = picks.cheap or picks.vcheap
            local armyB    = picks.main  or picks.vmain
            local defender = picks.vcheap or picks.vmain

            -- DEFENCE: goes ahead of the queue if the lab is busy.
            local def, defWhy = nil, nil
            if rush then
                if urgentCh ~= "ground" and picks.fighter then
                    def, defWhy = picks.fighter, "rush-air"
                elseif urgentCh ~= "air" then
                    def, defWhy = defender or armyA or armyB, "rush-ground"
                end
            end
            local needFighter  = fighterValue  < fighterWant
            -- Bombers inbound: a fighter goes ahead of the queue in every lab that can build one.
            local airAlarm = mb and mb.airAlarm and frame - mb.airAlarm.frame <= AIR_ALARM_TTL
            if not def and airAlarm and needFighter and picks.fighter then
                def, defWhy = picks.fighter, "alarm-fighter"
            end
            local defenderWant = DEFENDER_TARGET
            if defender and enemyGround > 0 then
                defenderWant = math.min(DEFENDER_MAX, math.max(defenderWant,
                    math.ceil(DEFENDER_ENEMY_RATIO * enemyGround / math.max(1, UnitValueOf(defender)))))
            end
            local needDefender = defendersHave < defenderWant
            local floor, floorWhy = nil, nil
            if needFighter and picks.fighter then
                floor, floorWhy = picks.fighter, "floor-fighter"
            elseif shuriRoom > 0 and picks.cheap and UnitDefs[picks.cheap] and UnitDefs[picks.cheap].name == "corbw" then
                floor, floorWhy = picks.cheap, "floor-shuriken"
            elseif needDefender and defender then
                floor, floorWhy = defender, "floor-defender"
            end
            local canScout = not rush and scoutRoom > 0 and #cache.scouts > 0
            -- STANCE_BOT: the T1 air lab (builds Shurikens, no ground units) makes stunners -- or fighters -- while raided
            local raidChoice = nil
            if RAID.airLab and not isSpine and picks.cheap and not picks.vcheap and not picks.vmain
               and UnitDefs[picks.cheap] and UnitDefs[picks.cheap].name == "corbw" then
                if RAID.fighters and picks.fighter then raidChoice = picks.fighter
                elseif not RAID.fighters and Have("shuri", frame) < RAID.STUN_MAX and RAID.stunOrdered < math.max(RAID.need, 2 * UnitValue(picks.cheap)) then
                    raidChoice = picks.cheap
                end
            end
            -- the hold was lifted only for the raid answer: nothing else goes into that lab
            if liftedHold and not raidChoice then def, floor, canScout = nil, nil, false end

            if QueueEmpty(labID) then
                -- rush -> ONE early scout -> floor -> more scouts -> surplus army.  The
                -- single early scout outranks the floor so the spawn search starts at
                -- once; every scout after it waits behind defence.  (Only here, where
                -- the lab can actually build it: letting it block the busy-lab branch
                -- below deadlocked a busy air lab -- no scout, and no fighter either.)
                local choice, why = def, defWhy
                if raidChoice then choice, why = raidChoice, "raid-air" end
                if not choice and canScout and scoutsHave == 0 then
                    choice, why = CheapestScout(cache.scouts), "scout"
                end
                if not choice then choice, why = floor, floorWhy end
                -- Standing roles, ahead of more scouts and surplus army.
                if not choice and bomberRoom > 0 and picks.bomber then
                    choice, why = picks.bomber, "hunt-bomber"
                end
                if not choice and wingBomberRoom > 0 and not stalled and picks.bomber
                   and UnitDefs[picks.bomber] and UnitDefs[picks.bomber].name == "corhurc" then
                    choice, why = picks.bomber, "wing-bomber"
                end
                if not choice and rezRoom > 0 and picks.rez then
                    choice, why = picks.rez, "rez"
                end
                if not choice and radarRoom > 0 and picks.radar and not stalled and labID == scoutLab then
                    choice, why = picks.radar, (callWant > 0 and "scout-call" or "radar-plane")
                end
                if not choice and canScout then
                    choice, why = CheapestScout(cache.scouts), "scout"
                end
                if not choice and not t1Spine then MaybeRingRadar(labID, labDefID, frame) end
                -- The vehicle lab on the spine keeps making the dive army (spine share gates it above).
                if not choice and t1Spine and not stalled then
                    -- STANCE_BOT: the stance decides (this includes the line's first vehicle plant, adopted by the spine)
                    choice, why = StancePick(labDefID), "army"
                    if not choice and not (WG and WG.Strategy) then
                        local slowUnit = SlowPick(picks)
                        if slowUnit then
                            choice, why = slowUnit, "army"
                        else
                            local flip = armyFlip[labID]
                            armyFlip[labID] = not flip
                            choice, why = (flip and armyA or armyB) or armyA or armyB, "army"
                        end
                        if choice then NoteMix(picks, choice) end
                    end
                -- Air labs: guards, only up to the standing size.  No "floating" rule, no Dragons.
                elseif not choice and not t1Spine and not stalled and not liftedHold and guardWant - guardHave > 0
                       and (picks.cheap or picks.main) then
                    local flip = armyFlip[labID]
                    armyFlip[labID] = not flip
                    choice, why = (flip and picks.cheap or picks.main) or picks.cheap or picks.main, "guard"
                end
                -- A lab with no army picks builds NOTHING (the bot lab only makes the
                -- two con bots the build order asks for, then is reclaimed).
                if choice then
                    spGiveOrderToUnit(labID, -choice, {}, {})
                    labOrderFrame[labID] = frame
                    NoteOrder(choice, frame)
                    -- STANCE_BOT: a lab with this much build power behind it eats one cheap unit per tick; queue a few
                    -- (the spine's QUEUE_DEPTH) so army units are not limited to one order per 4 s per lab.
                    if why == "army" and WG and WG.Strategy and SP and SP.CFG then
                        for _ = 2, SP.CFG.QUEUE_DEPTH do
                            local more = StancePick(labDefID)
                            if not more then break end
                            spGiveOrderToUnit(labID, -more, {}, {})
                            NoteOrder(more, frame)
                        end
                    end
                    local k = KindOf(choice)
                    if k == "scout" then
                        scoutRoom, scoutsHave = scoutRoom - 1, scoutsHave + 1
                    elseif k == "fighter" then fighterValue = fighterValue + UnitValue(choice)
                    elseif k == "defender" then defendersHave = defendersHave + 1
                    elseif k == "rez" then rezRoom = rezRoom - 1
                    elseif k == "radar" then radarRoom = radarRoom - 1
                    elseif k == "bomber" then bomberRoom = bomberRoom - 1; wingBomberRoom = wingBomberRoom - UnitValue(choice)
                    elseif k == "guard" then guardHave = guardHave + UnitValue(choice)
                    elseif k == "shuri" then shuriRoom = shuriRoom - 1; guardHave = guardHave + UnitValue(choice) end
                    if why ~= "army" then
                        if why == "guard" then
                            Spring.Echo(string.format("[LabCtrl] %d:%02d guard %s (have %.0f / want %.0f, income %.1f)",
                                math.floor(frame / 1800), math.floor(frame / 30) % 60,
                                UnitDefs[choice] and UnitDefs[choice].name or "?", guardHave, guardWant, metalIncome))
                        else
                            Announce(frame, why, choice, labDefID, false)
                        end
                    end
                end
            else
                -- Busy (usually the macro's constructors): defence goes in next, once,
                -- and waits for that unit to actually start before inserting again, so
                -- the economy's own units are delayed by one build at most.
                local ins, insWhy = def or floor, def and defWhy or floorWhy
                if raidChoice then ins, insWhy = raidChoice, "raid-air" end
                -- Hunting: bombers go ahead of the queue too; the game is already won
                -- and the only thing left to buy is the commander kill.
                if not ins and bomberRoom > 0 and picks.bomber then
                    ins, insWhy = picks.bomber, "hunt-bomber"
                end
                local pend = labPending[labID]
                if ins and (not pend or frame - pend > PENDING_TIMEOUT) then
                    InsertNext(labID, ins)
                    labPending[labID] = frame
                    labOrderFrame[labID] = frame
                    NoteOrder(ins, frame)
                    local k = KindOf(ins)
                    if k == "fighter" then fighterValue = fighterValue + UnitValue(ins)
                    elseif k == "defender" then defendersHave = defendersHave + 1
                    elseif k == "shuri" then shuriRoom = shuriRoom - 1
                    elseif k == "bomber" then bomberRoom = bomberRoom - 1 end
                    Announce(frame, insWhy, ins, labDefID, true)
                end
            end
        elseif not isSpine and not recent and not leaving and spGetUnitDefID(labID) then
            -- a lab with no army picks (a T2 lab that only makes support units) can still make the ring radar unit
            MaybeRingRadar(labID, labDefID, frame)
        end
    end
end
