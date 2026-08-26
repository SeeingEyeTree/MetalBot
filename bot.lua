-- This is a widget that plays metal maps on BAR.

-- We use the widget api because I don't have the willpower to write
-- Tens of thousands of LOC, and the widget api abstracts it for us

-- If anyone has a fix for anything in here please let me know

-- To my knowledge, this is the best bot for metal maps
-- on BAR, as I don't think anyone else has taken the liberty
-- to make one *specifically* for metal maps

-- Take this code, and tweak it, try out new formulas
-- Maybe you'll get better results!

-- I'll try to update this with fixes every now and then

-- GPLv3 or later licensed

-- Have fun!

local widget = widget
local Spring = Spring
local math   = math
local table  = table
local string = string
local CMD    = CMD

local spGetUnitPosition       = Spring.GetUnitPosition
local spGetFactoryCommands    = Spring.GetFactoryCommands
local spGetUnitDefID          = Spring.GetUnitDefID
local spGetUnitHealth         = Spring.GetUnitHealth
local spGetUnitCommands       = Spring.GetUnitCommands
local spGiveOrderToUnit       = Spring.GiveOrderToUnit
local spGetUnitsInCylinder    = Spring.GetUnitsInCylinder
local spGetFeaturesInCylinder = Spring.GetFeaturesInCylinder
local spGetGroundHeight       = Spring.GetGroundHeight
local spTestBuildOrder        = Spring.TestBuildOrder
local spGetTeamResources      = Spring.GetTeamResources
local spGetMyTeamID           = Spring.GetMyTeamID
local spGetMyAllyTeamID       = Spring.GetMyAllyTeamID
local spGetTeamUnits          = Spring.GetTeamUnits
local spGetGaiaTeamID         = Spring.GetGaiaTeamID
local spGetTeamList           = Spring.GetTeamList
local spAreTeamsAllied        = Spring.AreTeamsAllied
local spGetFeaturePosition    = Spring.GetFeaturePosition
local spGetUnitBuildFacing    = Spring.GetUnitBuildFacing
local spGetUnitTeam           = Spring.GetUnitTeam
local spGetUnitRulesParam     = Spring.GetUnitRulesParam
local spGetUnitAllyTeam       = Spring.GetUnitAllyTeam
local spGetUnitHeading        = Spring.GetUnitHeading
local spGetUnitFlanking       = Spring.GetUnitFlanking
local spGetUnitVelocity       = Spring.GetUnitVelocity
local spGetProjectilePosition = Spring.GetProjectilePosition
local spGetProjectileVelocity = Spring.GetProjectileVelocity

local mFloor  = math.floor
local mCeil   = math.ceil
local mRandom = math.random
local mCos    = math.cos
local mSin    = math.sin
local mMax    = math.max
local mMin    = math.min
local mHuge   = math.huge
local mAbs    = math.abs
local mSqrt   = math.sqrt
local mRad    = math.rad
local mDeg    = math.deg
local mAtan2  = math.atan2
local mPi     = math.pi


local tInsert = table.insert
local tRemove = table.remove
local tSort   = table.sort
local tClear  = table.clear

local sLower  = string.lower
local sFind   = string.find
local sFormat = string.format

do
    local rawUnits    = spGetUnitsInCylinder
    local rawFeatures = spGetFeaturesInCylinder
    local function ClampInMap(x, z, r)
        local mapX = Game.mapSizeX or 8192
        local mapZ = Game.mapSizeZ or 8192
        if r > mapX * 0.5 then r = mFloor(mapX * 0.5) end
        if r > mapZ * 0.5 then r = mFloor(mapZ * 0.5) end
        if x < r then x = r elseif x > mapX - r then x = mapX - r end
        if z < r then z = r elseif z > mapZ - r then z = mapZ - r end
        return x, z, r
    end
    function spGetUnitsInCylinder(x, z, r, ...)
        x, z, r = ClampInMap(x, z, r)
        return rawUnits(x, z, r, ...)
    end
    function spGetFeaturesInCylinder(x, z, r)
        x, z, r = ClampInMap(x, z, r)
        return rawFeatures(x, z, r)
    end
end

local function UnitHash(unitID, salt)
    local h = (unitID * 2654435761 + salt * 40503) % 2147483647
    h = (h * 48271) % 2147483647
    return (h % 100000) / 100000
end

--  do an offset as we don't want units to stack!
local function GetSpreadPos(unitID, tx, tz, minR, maxR)
    local a = (unitID * 137.50776405 % 360) * (math.pi / 180)
    local rr = math.sqrt(UnitHash(unitID, 2)) * (maxR - minR) + minR
    local sx = tx + mCos(a) * rr
    local sz = tz + mSin(a) * rr
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local minX, maxX = 50, mapX - 50
    local minZ, maxZ = 50, mapZ - 50
    if sx < minX then sx = minX + (minX - sx) elseif sx > maxX then sx = maxX - (sx - maxX) end
    if sz < minZ then sz = minZ + (minZ - sz) elseif sz > maxZ then sz = maxZ - (sz - maxZ) end
    -- a target right on the border can still mirror outside, so clamp it as a fallback
    if sx < minX then sx = minX elseif sx > maxX then sx = maxX end
    if sz < minZ then sz = minZ elseif sz > maxZ then sz = maxZ end
    return sx, sz
end

-- Fairly niche mechanic
-- Flanking bonus: attacking from front and rear at once boosts damage, so
-- spread attackers to opposite sides
-- This probably also has the benefit of being harder to attack all of the units at the same time
local function GetFlankSpreadPos(unitID, tx, tz, minR, maxR, targetID)
    local rr = math.sqrt(UnitHash(unitID, 2)) * (maxR - minR) + minR
    local a
    local rearX, rearZ = nil, nil
    if targetID and spGetUnitFlanking then
        local _, _, _, _, fx, _, fz = spGetUnitFlanking(targetID)
        if fx ~= nil and (fx ~= 0 or fz ~= 0) then rearX, rearZ = -fx, -fz end
    end
    if rearX ~= nil then
        local rearAngle = mAtan2(rearZ, rearX)
        a = rearAngle + (UnitHash(unitID, 5) - 0.5) * 2 * 1.2
    else
        a = (unitID * 137.50776405 % 360) * (math.pi / 180)
    end
    local sx = tx + mCos(a) * rr
    local sz = tz + mSin(a) * rr
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local minX, maxX = 50, mapX - 50
    local minZ, maxZ = 50, mapZ - 50
    if sx < minX then sx = minX + (minX - sx) elseif sx > maxX then sx = maxX - (sx - maxX) end
    if sz < minZ then sz = minZ + (minZ - sz) elseif sz > maxZ then sz = maxZ - (sz - maxZ) end
    if sx < minX then sx = minX elseif sx > maxX then sx = maxX end
    if sz < minZ then sz = minZ elseif sz > maxZ then sz = maxZ end
    return sx, sz
end


-- Keep the last retreat direction per unit, so that retreats don't zigzag.
local retreatDirCache = {}

-- This is the trapper's target spot. It's only re-rolled after placing/failing to place a mine.
local trapperTargets = {}

local TANGENTIAL_ANGLES = {
    { mCos(mRad( 45)), mSin(mRad( 45)) },
    { mCos(mRad( 60)), mSin(mRad( 60)) },
    { mCos(mRad( 75)), mSin(mRad( 75)) },
    { mCos(mRad( 90)), mSin(mRad( 90)) },
    { mCos(mRad(-45)), mSin(mRad(-45)) },
    { mCos(mRad(-60)), mSin(mRad(-60)) },
    { mCos(mRad(-75)), mSin(mRad(-75)) },
    { mCos(mRad(-90)), mSin(mRad(-90)) },
}
local TANGENTIAL_ANGLE_COUNT = #TANGENTIAL_ANGLES

local CMD_DGUN        = (CMD and (CMD.MANUALFIRE or CMD.DGUN)) or 37899
local CMD_STOP         = (CMD and CMD.STOP) or 0
local CMD_WAIT         = (CMD and CMD.WAIT) or 5
local CMD_CLOAK        = 37382 -- BAR's cloak command
local CMD_RESURRECT    = (CMD and CMD.RESURRECT) or 125
local CMD_FIRE_STATE   = (CMD and CMD.FIRE_STATE) or 25200
local CMD_MOVE_STATE   = (CMD and CMD.MOVE_STATE) or 25201

local function SafeGetWeaponDef(weaponDefIdx)
    if not weaponDefIdx then return nil end
    local ok, wd = pcall(function() return WeaponDefs[weaponDefIdx] end)
    return ok and wd or nil
end

local canStrafeCache = {}

function widget:GetInfo()
    return {
        name      = "Metal Bot",
        desc      = "Bot plays metal maps",
        author    = "vexalous",
        date      = "2026",
        license   = "GNU GPL, v3 or later",
        layer     = 0,
        enabled   = true
    }
end

local cfg = {
    BUILD_RADIUS          = 1000,   -- max radius the flood-fill build-spot search explores
    CHECK_INTERVAL        = 10,
    THREAT_INTERVAL       = 30,     -- frames between enemy/threat scans (≈1s)
    COMBAT_REAIM_INTERVAL = 60,     -- frames between mid-move re-aims

    -- Cap units/frame when we're slow. It's probably best to optimize the code, but if
    -- we can't do that, atleast we can do this.

    LOAD_TARGET_MS        = 1.0,
    LOAD_CEILING_MS       = 2.5,
    LOAD_MAX_SCALE        = 8,
    LOAD_MAX_UNITS_PER_FRAME = 40,
    LOAD_ADAPT_EVERY      = 15,     -- (≈0.5s)
    LOAD_EMA              = 0.1,
    LOAD_MIN_FPS          = 20,
    LOAD_MIN_FPS_RECOVER  = 26,

    BUILD_SPACING         = 384,    -- grid spacing for factory/eco placement
    ENERGY_GRID_SPACING   = 64,
    SHIELD_GRID_SPACING   = 256,
    TURRET_SPACING        = 80,
    MIN_SPACING           = 32,     -- I don't think you can build stuff this close, but it (might?) help out performance wise adding this
    LAVA_MARGIN           = 12,     -- build/move this far above the lava level

    ANTI_NUKE_KEEPOUT      = 160,
	
	-- Hardcoded variables are fragile, but it's whatever.
	-- The important thing to note is that this not a hard ban,
	-- it simply allows us to build other things once we have enough m/s.

    METAL_MAP_MEX_INCOME_TARGET = 300,

    MEX_GROWTH_FLOOR     = 2,       -- we should have this many mex builders while income < target (x mapAreaScale)
    STALL_PULL_METAL_RATIO  = 0.25, -- stall-pull thresholds are a fraction of our income, not fixed m/s
    STALL_PULL_ENERGY_RATIO = 0.25,

    RECLAIM_RANGE         = 650,    -- This scales with map size
    RECLAIM_MIN_METAL_SECONDS = 4,  -- a wreck is reclaimed only if worth this many seconds of income
    RETREAT_HEALTH_RATIO  = 0.15,   -- below this HP a unit retreats
    TANGENTIAL_RETREAT_DIST = 700,

    SELFD_HP_RATIO       = 0.20,    -- nearly-dead big units self-D as a weapon when enemies worth DOOM_RATIO x cost are on top TODO: fix this, it doesn't work
    SELFD_MIN_BLAST_RADIUS = 300,   -- min selfDExplosion AoE to be a "bomb" (generic pops are <= ~96)
    SELFD_DOOM_RATIO     = 0.20,

    KITE_TRIGGER_RATIO   = 0.95,    -- back off when an enemy closes inside this x our range
    KITE_STANDOFF_RATIO  = 1.0,
    KITE_LEAD_FRAMES     = 15,
    KITE_TANK_HOP        = 0.3,
    KITE_DEADBAND        = 16,

	-- normally you would use guard here, but when a unit reverses
 	-- guarding can lead to the guarding unit ending up infront of the unit its guarding
 	-- I actuallly am not sure this is even working properly TODO: look into this

    SUPPORT_BEHIND_DIST  = 140,

    COMMANDER_SCAN_RADIUS   = 1200,
    -- This ones up for debate, but I'm not sure whether retreating a specific amount is best (what if the enemy leaves?)
    -- But also, (what if they leave our LOS, but they can still see us?)
    COMMANDER_RETREAT_DIST  = 800,
    CON_HEAL_THRESHOLD     = 0.9,

    TURRET_SEARCH_RADIUS  = 400,    -- keep 'em close to the lab!

    CMD_MOVE              = 10,
    CMD_PATROL            = 15,
    CMD_ATTACK            = 20,
    CMD_GUARD             = 25,
    CMD_REPAIR            = 40,
    CMD_RECLAIM           = 90,
    CMD_SELFD             = 65,
    CMD_STOP              = CMD_STOP,
    CMD_WAIT              = CMD_WAIT,
    CMD_CLOAK             = CMD_CLOAK,
    CMD_DGUN              = CMD_DGUN,
    CMD_RESURRECT         = CMD_RESURRECT,
    CMD_FIRE_STATE        = CMD_FIRE_STATE,
    CMD_MOVE_STATE        = CMD_MOVE_STATE,
    CMD_FLY               = (CMD and CMD.IDLEMODE) or nil,

    ENEMY_RECLAIM_MIN_COST_SECONDS = 2,  -- don't reclaim enemies worth < this many seconds of income
    ENEMY_RECLAIM_CHASE_RANGE  = 500,    -- how far mobile cons chase enemies to reclaim them

    ARMY_MIN_SIZE          = 2,          -- send atleast *something*

    UNEASE_FLOOR_INCOME_SECONDS = 30, 
    UNEASE_ARMY_RATIO      = 0.5,
    UNEASE_OVERRUN_RATIO   = 1.25,  -- recall defenders worth a minimum of threat + ~25%

    PERIMETER_PATROL_RING  = 700,
    UNEASE_WATCH_RING      = 800, 
    UNEASE_SCAN_BUFFER     = 1500,
    PERIMETER_PATROL_PROBES = 8,

    DEFENSE_TARGET_RADIUS  = 1300,  -- army attacks nearest static defense within this range

    DEFENSE_MIN_PER_FACTORY   = 1,
    DEFENSE_ARMY_TURRET_RATIO = 5,

    UNIT_PICK_COST_CAP_SECONDS = 30,
    INCOME_WINDOW_BASE         = 12,
    INCOME_WINDOW_COST_RATIO   = 0.001,

    ATTACK_SCOUT_DURATION  = 1200,

    SCOUT_COVERAGE_RATIO   = 0.5,
    SCOUT_LOCK_TTL         = 2400,
    SCOUTS_PER_FACTORY     = 1,

    ECONOMY_SATURATION_RATIO = 0.85,
    ECONOMY_INCOME_SLACK     = 1.5,

    ADV_FACTORY_TIER_RATIO  = 2,

    -- We're on metal maps, so hardcoding this probably isn't
    -- an issue, but who knows

    ADV_FACTORY_PAYBACK_SECS = 120,

    AOE_DAMAGE_RADIUS     = 256,
    CLUSTER_THRESHOLD     = 2,

    CONS_PER_FACTORY      = 6,	   -- We do this to prevent con spams
    CONS_BASE             = 8,

    MEX_SKIP_DIST         = 1000,  -- skip walking to a mex spot further than this

    ARMY_DEPRECIATION_RATE = 0.02, -- get the army moving, t1s are more useful early on

    ANTI_CLUMP_MIN         = 220,
    ANTI_CLUMP_MAX         = 650,  -- anti-clump ring kept wide on purpose; a tight disc clumped the whole army
}

local st = {
    frameNum                     = 0,
    buildCache                   = {},
    lastFactoryOrderFrame        = {},
    claimedSpots                 = {},

    myFactories                  = {},
    myFactoriesCount             = 0,
    factoryGuards                = {},
    factoryTurrets               = {},
    conTurretHomes               = {},
    factoryWaitState             = {},
    incompleteFactories          = {},
    incompleteFactoryCount       = 0,
    hasAdvancedFactory  = false,
    hasT2Lab            = false,
    combatReaimFrame             = {},
    pendingFactoryBlueprints     = 0,
    factoriesNeedingTurrets      = {},
    factoriesNeedingTurretsCount = 0,

    myCommanders                 = {},
    myCommanderCount             = 0,

    conUnitCount                 = 0,
    advConCount                  = 0,
    mexUnitCount                 = 0,
    combatUnitCount              = 0,
    myCombatUnits                = {},
    myCombatUnitCount            = 0,
    unclaimedMexCount            = 0,
    unclaimedMetalSpots          = {},

    lazCount                     = 0,
    jammerCount                  = 0,
    radarCount                   = 0,
    radarTowerCount              = 0,

    activeMexBuilders            = 0,
    activeEnergyBuilders         = 0,

    energyStalling               = false,
    metalStalling                = false,
    economySaturated             = false,
    metalIncome                  = 0,
    energyIncome                 = 0,
    metalPull                    = 0,
    energyPull                   = 0,
    currentMetal                 = 0,
    currentEnergy                = 0,
    currentEnergyStorage         = 0,
    currentMetalStorage          = 0,
    pendingCommittedMetal        = 0,

    cachedPrimeTargetPos         = nil,
    cachedPrimeTargetID          = nil,
    cachedPrimeTargetCost        = nil,

	-- Proof of concept, but generally,
    -- when a hidden enemy damages us, extrapolate the shell's trajectory back
    -- by its weapon range to guess where the shooter is; lets us retaliate
    -- into fog when nothing is visible.

    suspectedThreatX             = nil,
    suspectedThreatZ             = nil,
    suspectedThreatFrame         = -999999,
    metalSpots                   = {},
    claimedMexList               = {},

    baseCenterX                  = nil,
    baseCenterY                  = nil,
    baseCenterZ                  = nil,
    baseRadius                   = 0,
    baseStructureCount           = 0,

    enemyBases                   = {},
    enemyDefenses               = {},
    raiders                      = {},
    raiderCount                  = 0,
    unease                       = 0,    -- weighted strength of enemy units near base
    uneaseX                      = nil,  -- weighted centroid of the threatening group
    uneaseZ                      = nil,
    scoutSectors                 = {},
    scoutAssignments             = {},
    scoutIntelVersion            = {},
    scoutUnitCount               = 0,

    intelVersion                 = 0,   -- bumped whenever enemy-base intel changes

    myAntinukes                  = {},
    antinukeCount                = 0,
    pendingAntinukeBlueprints    = 0,
    defenseCount                 = 0,   -- total defensive *things*
    defenseGroundCount           = 0,   -- ground attack towers (can also deal damage to air units, but aren't AA)
    defenseAACount               = 0,   -- AA-only towers

    selfDingUnits                = {},  -- our units should flee so they're not caught in the blast
    selfDingCount                = 0,

    currentDefenders             = {},  -- units recalled to intercept a threatening group

    frontierX                    = nil, -- forward expansion axis (toward enemy / map center)
    frontierZ                    = nil,

    plan = {
        mode          = "mex",   -- "mex" | "energy" | "army"
        frame         = 0,
        mexScore      = 0,
        energyScore   = 0,
        armyScore     = 0,       -- value of attacking now (depreciation + tempo)
        metalSurplus  = 0,       -- metalIncome - metalPull (per second)
        energyDeficit = 0,       -- energyPull - energyIncome (per second)
    },

    enemyTech                  = 0,   -- highest metal cost seen among enemy units (decays)
    ourTech                    = 0,   -- highest metal cost among our combat units
    armyValue                  = 0,   -- total metal of our fielded combat units
    enemyArmyValue             = 0,   -- total metal of enemy MOBILE combat units seen (decays)

    fireStateSet                 = {},
    moveStateSet                 = {},
    flyStateSet                  = {},

    -- let's get a exclusive lock here so we don't
	-- put two of the same support units on one unit
    supportGuardOwners = { radar = {}, jammer = {}, aa = {} },
    supportTarget               = {},

    aaThreats                    = {},

    army = {
        state           = "searching",
        targetX         = nil,
        targetY         = nil,
        targetZ         = nil,
        targetKey       = nil,
        stateFrame      = 0,
    },

    turretDbg = {
        consWithTurret = 0,   -- number of cons who can build a turret
        needTurrets    = 0,   -- labs waiting for their turret ring
        fired          = 0,
        noCon          = 0,   -- this con can't build turrets
        noNeed         = 0,   -- con *could* build turrets but no lab needs a ring
        noAfford       = 0,   -- target chosen but turrets are unaffordable
        noSpot         = 0,   -- FindBuildSpot found no tile
        placed         = 0,
        probeTiles     = 0,
        probeBlocked   = 0,
        probeInacc     = 0,   -- We can't get there (void, lava, etc) :(
        probeOverlap   = 0,   -- too close to the ordering con itself
        probeTest      = 0,
        probeExit      = 0,
        probeBounds    = 0,
        lastDef        = nil,
        lastSpacing    = 0,
        lastRingOut    = 0,
    },
    attackDbg = {
        issued          = 0, -- This is the total number of attack orders issued by the bot
        airIssued       = 0, -- This should be a number (if we have an air lab)
        groundIssued    = 0, -- This should be 0
        groundCleared   = 0, -- This should be 0
        lastIssuedDef   = nil,
        lastGroundDef   = nil,
    },
    uneaseDbg = {
        detected       = 0,
        fired          = 0,
        noCands        = 0,   -- fired but had no combat units to send
        recalled       = 0,
        lastUnease     = 0,   -- unease at the last fired recall
    },
}

local ui = {
    showGUI = false,
    active  = true,
    vsx     = 0,
    vsy     = 0,
    btnW    = 160,
    btnH    = 40,
    btnX    = 0,
    btnY    = 0
}

-- Build spot checks are expensive
-- Cache them so computer doesn't explode
local buildCacheTTL      = 600
local buildTestCache     = {}
local buildExitCache     = {}
local buildTestCount     = {}
local buildExitCount     = 0
local buildCacheLastClear = -9999
local BUILD_CACHE_COALESCE = 15

local OBSTACLE_SCAN_CELL = 512
local OBSTACLE_SCAN_PAD  = 400
local obstacleScanCache  = {}

local function ClearBuildCaches()
    buildTestCache = {}
    buildExitCache = {}
    buildTestCount = {}
    buildExitCount = 0
    obstacleScanCache = {}
end

local function OnWorldChange()
    local fr = st.frameNum or 0
    if fr - buildCacheLastClear >= BUILD_CACHE_COALESCE then
        ClearBuildCaches()
        buildCacheLastClear = fr
    end
end

local aaWeaponCache = {}

function cfg.IsAAWeapon(uDefID, weaponDefID)
    if not weaponDefID then return false end
    local perUnit
    if uDefID then
        perUnit = aaWeaponCache[uDefID]
        if not perUnit then
            perUnit = {}
            aaWeaponCache[uDefID] = perUnit
        end
    end
    local cached = perUnit and perUnit[weaponDefID]
    if cached ~= nil then return cached end

    local result = false

    local d = uDefID and UnitDefs[uDefID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local mount = d.weapons[i]
            if mount.weaponDef == weaponDefID then
                local ot = mount.onlyTargets
                if ot and ot.vtol then
                    result = true
                    for cat, on in pairs(ot) do
                        if on and cat ~= "vtol" then result = false break end
                    end
                end
                break
            end
        end
    end

    local wDef = WeaponDefs[weaponDefID]
    if not result and wDef then
        local ot = wDef.onlyTargets
        if ot and ot.vtol then
            result = true
            for cat, on in pairs(ot) do
                if on and cat ~= "vtol" then result = false break end
            end
        else
            local onlyCat = sLower(wDef.onlyTargetCategory or "")
            if onlyCat ~= "" and onlyCat ~= "notair" then
                result = onlyCat == "vtol"
                if not result then
                    for token in onlyCat:gmatch("%S+") do
                        if token == "vtol" then result = true break end
                    end
                    if result then
                        for token in onlyCat:gmatch("%S+") do
                            if token ~= "vtol" then result = false break end
                        end
                    end
                end
            end
        end
        if not result then
            local wName = sLower(wDef.name or "")
            local wType = sLower(wDef.type or "")
            result = (sFind(wName, "flak") or sFind(wType, "aa")) and true or false
        end
    end

    if perUnit then perUnit[weaponDefID] = result end
    return result
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
    if not attackerID then return end

    local ax, _, az = spGetUnitPosition(attackerID)

    if attackerDefID and cfg.IsAAWeapon(attackerDefID, weaponDefID) and ax then
        st.aaThreats[attackerID] = { x = ax, z = az, frame = st.frameNum }
    end

	-- POC Nonsense
    if not ax and projectileID then
        local px, _, pz = spGetProjectilePosition(projectileID)
        if px then
            local fx, fz = px, pz
            local vx, _, vz = spGetProjectileVelocity(projectileID)
            if vx and (vx ~= 0 or vz ~= 0) then
                local wDef = weaponDefID and WeaponDefs[weaponDefID]
                local wRange = (wDef and wDef.range) or 600
                local vlen = math.sqrt(vx * vx + vz * vz)
                if vlen > 0.001 then
                    fx = px - (vx / vlen) * wRange
                    fz = pz - (vz / vlen) * wRange
                end
            end
            st.suspectedThreatX = fx
            st.suspectedThreatZ = fz
            st.suspectedThreatFrame = st.frameNum
            -- Retarget the army now, not on the next threat scan.
            st.army.targetX = fx
            st.army.targetZ = fz
            st.army.targetKey = "fire_origin"
            if st.army.state ~= "attacking" then st.army.state = "attacking" end
        end
    end
end

local function CleanupAAThreats(frame)
    local expiryFrame = frame - 1800
    for id, threat in pairs(st.aaThreats) do
        if threat.frame < expiryFrame or not spGetUnitDefID(id) then
            st.aaThreats[id] = nil
        end
    end
end

local function GetGameID()
    return Spring.GetGameRulesParam("GameID") or (Game and Game.gameID) or "0"
end

-- We have to do this because when spectating the game, it shows all units as ours
-- This confuses the bot and causes a lot of lag from failed commands
-- Also worth nothing, that the engine reports everyone as spectating during the
-- pre-game countdown, so only run this once the game is started.
local function IsSpectating()
    if not Spring.GetSpectatingState then return false end
    local s = Spring.GetSpectatingState()
    if not (s and s ~= 0) then return false end
    return (Spring.GetGameFrame() or 0) > 0
end

function widget:Initialize()
    ui.active = true
    ui.vsx, ui.vsy = Spring.GetViewGeometry()
    ui.btnX = mFloor((ui.vsx - ui.btnW) / 2)
    ui.btnY = mFloor((ui.vsy - ui.btnH) / 2)
    Spring.Echo("[MetalAI] Loaded")

    if IsSpectating() then return end

    local myTeam = spGetMyTeamID()
    if myTeam then
        local units = spGetTeamUnits(myTeam)
        if units then
            for i = 1, #units do
                local uID = units[i]
                local dID = spGetUnitDefID(uID)
                local d = dID and UnitDefs[dID]
                if d and not d.isFactory and not d.isBuilder and d.speed and d.speed > 0 and d.weapons and #d.weapons > 0 then
                    spGiveOrderToUnit(uID, CMD_FIRE_STATE, {2}, {})
                    st.fireStateSet[uID] = true
                end
                if d and d.canFly and cfg.CMD_FLY then
                    spGiveOrderToUnit(uID, cfg.CMD_FLY, { 0 }, 0)
                    st.flyStateSet[uID] = true
                end
            end
        end
    end

    st.scoutSectors = {}
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local sectorSize = 1024
    local sectorCount = 0
    for x = 0, mapX - 1, sectorSize do
        for z = 0, mapZ - 1, sectorSize do
            local key = x .. "_" .. z
            st.scoutSectors[key] = {
                x = x + sectorSize / 2,
                z = z + sectorSize / 2,
                lastScouted = 0
            }
            sectorCount = sectorCount + 1
        end
    end

    st.scoutSectorCount = sectorCount
    st.mapAreaScale = (mapX * mapZ) / (8192 * 8192)
    st.mapLinearScale = mSqrt(st.mapAreaScale)
    st.scoutMaxActive = mMax(1, mCeil(sectorCount * cfg.SCOUT_COVERAGE_RATIO))
    st.metalMapMexSpacing = (Game.extractorRadius or 24) * 4

    -- If you want to tweak the bot while playing, you'll love this
    -- Remember where the enemies base is so we can reload the widget without forgetting! :)
    local gid = GetGameID()
    local bc = WG and WG.MetalAIBaseCache
    if bc and bc.gameID == gid then
        if bc.bases and next(bc.bases) ~= nil then
            st.enemyBases = bc.bases
            local n = 0
            for _ in pairs(bc.bases) do n = n + 1 end
            Spring.Echo("[MetalAI] restored " .. n .. " enemy base(s) from match cache")
        end
        if bc.enemyDefenses then
            st.enemyDefenses = bc.enemyDefenses
        end
        if bc.army and bc.army.state then
            st.army.state = bc.army.state
            st.army.targetX = bc.army.targetX
            st.army.targetY = bc.army.targetY
            st.army.targetZ = bc.army.targetZ
            st.army.targetKey = bc.army.targetKey
            st.army.stateFrame = bc.army.stateFrame or 0
        end
        if bc.scoutSectors then
            st.scoutSectors = bc.scoutSectors
        end
        if bc.factoryWaitState then
            st.factoryWaitState = bc.factoryWaitState
        end
    end
end

function widget:KeyPress(key, mods, isRepeat)
    if mods.ctrl and mods.shift and (key == 117 or key == 85) then
        ui.showGUI = not ui.showGUI
        return true
    end
    return false
end

function widget:ViewResize(viewSizeX, viewSizeY)
    ui.vsx = viewSizeX
    ui.vsy = viewSizeY
    ui.btnX = mFloor((ui.vsx - ui.btnW) / 2)
    ui.btnY = mFloor((ui.vsy - ui.btnH) / 2)
end

function widget:DrawScreen()
    if not ui.showGUI then return end
    if ui.active then gl.Color(0.2, 0.7, 0.2, 0.8) else gl.Color(0.7, 0.2, 0.2, 0.8) end
    gl.Rect(ui.btnX, ui.btnY, ui.btnX + ui.btnW, ui.btnY + ui.btnH)
    gl.Color(1, 1, 1, 1)
    gl.Text(ui.active and "METALAI: ON" or "METALAI: OFF", ui.btnX + (ui.btnW / 2), ui.btnY + (ui.btnH / 2) - 4, 16, "cv")
end

function widget:IsAbove(x, y)
    return x >= ui.btnX and x <= (ui.btnX + ui.btnW) and y >= ui.btnY and y <= (ui.btnY + ui.btnH)
end

function widget:MousePress(x, y, button)
    if ui.showGUI and button == 1 and widget:IsAbove(x, y) then
        ui.active = not ui.active
        Spring.Echo("[MetalAI] " .. (ui.active and "ENABLED" or "DISABLED"))
        return true
    end
    return false
end

function widget:UnitCreated(unitID, unitDefID, teamID)
    OnWorldChange()
    if IsSpectating() then return end
    if not teamID or teamID ~= spGetMyTeamID() then return end
    local d = unitDefID and UnitDefs[unitDefID]
    if d and not d.isFactory and not d.isBuilder and d.speed and d.speed > 0 and d.weapons and #d.weapons > 0 then
        spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {2}, {})
        st.fireStateSet[unitID] = true
    end
    if d and d.canFly and cfg.CMD_FLY then
        spGiveOrderToUnit(unitID, cfg.CMD_FLY, { 0 }, 0)
        st.flyStateSet[unitID] = true
    end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
    OnWorldChange()
    st.factoryGuards[unitID] = nil
    st.factoryWaitState[unitID] = nil
    st.lastFactoryOrderFrame[unitID] = nil
    st.fireStateSet[unitID] = nil
    st.moveStateSet[unitID] = nil
    st.flyStateSet[unitID] = nil
    st.combatReaimFrame[unitID] = nil
    retreatDirCache[unitID] = nil
    trapperTargets[unitID] = nil
    st.supportTarget[unitID] = nil

    for key, assign in pairs(st.scoutAssignments) do
        if assign.unitID == unitID then st.scoutAssignments[key] = nil end
    end
    st.scoutIntelVersion[unitID] = nil

    for key, base in pairs(st.enemyBases) do
        if base.id == unitID then st.enemyBases[key] = nil end
    end
end

function widget:FeatureCreated()
    OnWorldChange()
end

function widget:FeatureDestroyed()
    OnWorldChange()
end

local function GetHumanName(d)
    local n = d and (d.translatedHumanName or d.humanName)
    return n and sLower(n) or ""
end

local function GetDescription(d)
    local t = d and (d.translatedTooltip or d.description)
    return t and sLower(t) or ""
end

local function IsGuardingValidTarget(unitID, maxRange)
    local currentCmds = spGetUnitCommands(unitID, 1)
    if currentCmds and #currentCmds > 0 and currentCmds[1].id == cfg.CMD_GUARD then
        local target = currentCmds[1].params[1]
        if target and spGetUnitDefID(target) then
            -- A finished lab that's waited assists nothing, so guarding
            -- it is useless. One still under construction is worth helping.
            if st.factoryWaitState[target] then
                local thp, tmax = spGetUnitHealth(target)
                if thp and tmax and thp >= tmax then return false end
            end
            if maxRange then
                local ux, _, uz = spGetUnitPosition(unitID)
                local tx, _, tz = spGetUnitPosition(target)
                if ux and tx then
                    local dx, dz = tx - ux, tz - uz
                    if dx*dx + dz*dz > maxRange * maxRange then
                        return false
                    end
                end
            end
            return true
        end
    end
    return false
end

-- I like to keep mine layers separate from everything else, one, because
-- I'm not too sure of their feasability in a real game
-- and two, because they're not meant to be combat units.
local function IsTrapper(uDef)
    if not uDef then return false end
    local name = uDef.name and sLower(uDef.name) or ""
    if sFind(name, "trap") then return true end
    if uDef.customParams and (uDef.customParams.trap ~= nil or uDef.customParams.istrap ~= nil) then return true end
    if uDef.isBuilder and uDef.buildOptions then
        for i = 1, #uDef.buildOptions do
            local optDef = UnitDefs[uDef.buildOptions[i]]
            if optDef and sFind(sLower(optDef.name or ""), "mine") then return true end
        end
    end
    return false
end

local function CanStrafeByDefID(uDefID)
    if not uDefID then return false end
    if canStrafeCache[uDefID] ~= nil then return canStrafeCache[uDefID] end
    local uDef = UnitDefs[uDefID]
    local result = false
    if uDef and uDef.speed and uDef.speed > 0 and not uDef.isBuilding and not uDef.canFly then
        if not uDef.weapons or #uDef.weapons == 0 then
            result = true
        else
            local allTurreted = true
            for i = 1, #uDef.weapons do
                local wd = uDef.weapons[i].weaponDef
                local wDef = wd and SafeGetWeaponDef(wd)
                if wDef and wDef.turret == false then
                    allTurreted = false
                    break
                end
            end
            result = allTurreted
        end
    end
    canStrafeCache[uDefID] = result
    return result
end

local function GetUnitForward(unitID)
    local heading = spGetUnitHeading(unitID)
    if not heading then return 0, 1 end      -- fallback: facing +Z
    local theta = (heading / 65536) * 2 * math.pi
    return mSin(theta), mCos(theta)
end

-- Cache lava level, for the most lava level is unimportant, but some metal maps *can*
-- have lava on them, and so we want to be accomadating
-- nil on non-lava maps; values < -9000 mean "not initialised yet".
local lavaLevelCache = nil
local lavaCheckFrame = -999999
local function GetLavaLevel()
    local gf = Spring.GetGameFrame()
    if gf - lavaCheckFrame < 30 then return lavaLevelCache end
    lavaCheckFrame = gf
    local lv = Spring.GetGameRulesParam("lavaLevel")
    if lv == nil or lv < -9000 then
        lavaLevelCache = nil
    else
        lavaLevelCache = lv
    end
    return lavaLevelCache
end

-- Unit's take damage below this level
local dangerLevelCache = nil
local dangerCheckFrame = -999999
local voidWaterMap = nil
local function IsVoidWaterMap()
    if voidWaterMap ~= nil then return voidWaterMap end
    voidWaterMap = false
    local ok, mapinfo = pcall(function()
        if VFS and VFS.Include then return VFS.Include("mapinfo.lua") end
    end)
    if ok and type(mapinfo) == "table" then
        local vw = mapinfo.voidwater
        if vw == nil then vw = mapinfo.voidWater end
        if vw and vw ~= false then voidWaterMap = true return true end
    end
    local ok2, vw2 = pcall(function() return gl and gl.GetMapRendering and gl.GetMapRendering("voidWater") end)
    if ok2 and vw2 then voidWaterMap = true return true end
    return false
end

local function GetDangerLevel()
    local gf = Spring.GetGameFrame()
    if gf - dangerCheckFrame < 60 then return dangerLevelCache end
    dangerCheckFrame = gf
    local lava = GetLavaLevel()
    if lava then dangerLevelCache = lava return dangerLevelCache end
    if IsVoidWaterMap() then dangerLevelCache = 0 return dangerLevelCache end
    local _, _, currMin = Spring.GetGroundExtremes()
    if currMin and currMin < -100 then
        dangerLevelCache = currMin + 50
        return dangerLevelCache
    end
    dangerLevelCache = nil
    return dangerLevelCache
end

local VOID_CELL = 128
local voidGrid = {}
local voidCols = 0
local voidRows = 0
local voidScanX = 0
local voidScanZ = 0
local voidScanInit = false

local function StepVoidScan()
    if Spring.GetGameFrame() < 2 then return end
    if not voidScanInit then
        local mapX = Game.mapSizeX or 8192
        local mapZ = Game.mapSizeZ or 8192
        voidCols = mCeil(mapX / VOID_CELL)
        voidRows = mCeil(mapZ / VOID_CELL)
        voidScanInit = true
    end
    local danger = GetDangerLevel()
    if not danger then return end
    local minSafe = danger + cfg.LAVA_MARGIN
    for _ = 1, 24 do
        local col = voidGrid[voidScanX]
        if not col then col = {} voidGrid[voidScanX] = col end
        col[voidScanZ] = spGetGroundHeight((voidScanX + 0.5) * VOID_CELL, (voidScanZ + 0.5) * VOID_CELL) < minSafe
        voidScanZ = voidScanZ + 1
        if voidScanZ >= voidRows then
            voidScanZ = 0
            voidScanX = voidScanX + 1
            if voidScanX >= voidCols then voidScanX = 0 end
        end
    end
end

local function IsInaccessible(x, z)
    local danger = GetDangerLevel()
    if not danger then return false end
    local cx = mFloor(x / VOID_CELL)
    local cz = mFloor(z / VOID_CELL)
    local col = voidGrid[cx]
    local v = col and col[cz]
    if v == nil then
        v = spGetGroundHeight(x, z) < danger + cfg.LAVA_MARGIN
        if not col then col = {} voidGrid[cx] = col end
        col[cz] = v
    end
    return v
end

local function NudgeOutOfLava(x, z, towardX, towardZ)
    if not IsInaccessible(x, z) then return x, z end
    local dx, dz = towardX - x, towardZ - z
    local len = math.sqrt(dx*dx + dz*dz)
    if len < 1 then return x, z end
    dx, dz = dx / len, dz / len
    for i = 1, 16 do
        x = x + dx * 32
        z = z + dz * 32
        if not IsInaccessible(x, z) then return x, z end
    end
    return x, z
end

local function GetTangentialRetreat(unitID, ux, uz, threatX, threatZ, dist)
    local awayX, awayZ = ux - threatX, uz - threatZ
    local awayLenSq = awayX * awayX + awayZ * awayZ
    if awayLenSq < 0.01 then
        -- Threat on top of us: pick an arbitrary away direction.
        -- TODO: make this *not* arbitrary
        awayX, awayZ, awayLenSq = 1.0, 0.0, 1.0
    end
    local awayLen = math.sqrt(awayLenSq)
    local invLen = 1.0 / awayLen
    local awayNX, awayNZ = awayX * invLen, awayZ * invLen

    -- Map edge clamp bound
    local mapX  = Game.mapSizeX or 8192
    local mapZ  = Game.mapSizeZ or 8192
    local maxX  = mapX - 50
    local maxZ  = mapZ - 50
    local minX  = 50
    local minZ  = 50

    -- Forward current-unit vector from heading (fallback to facing +Z if null).
    local fwdX, fwdZ = GetUnitForward(unitID)
    local fwdLenSq = fwdX * fwdX + fwdZ * fwdZ
    if fwdLenSq < 0.01 then
        fwdX, fwdZ = 0.0, 1.0
    elseif fwdLenSq > 1.0001 then
        local fl = math.sqrt(fwdLenSq)
        fwdX = fwdX / fl
        fwdZ = fwdZ / fl
    end

    -- If we are already well-aligned with the away direction (~17 deg), just retreat directly.
    local dotAlign = fwdX * awayNX + fwdZ * awayNZ
    if dotAlign > 0.3 then
        retreatDirCache[unitID] = nil
        local tx = ux + awayNX * dist
        local tz = uz + awayNZ * dist
        if tx < minX then tx = minX elseif tx > maxX then tx = maxX end
        if tz < minZ then tz = minZ elseif tz > maxZ then tz = maxZ end
        tx, tz = NudgeOutOfLava(tx, tz, ux, uz)
        return tx, tz
    end

    -- Try each precomputed tangential angle, keep the one that best escapes
    -- the threat (plus a small bias toward the last retreat direction).
    local prevX, prevZ
    local cached = retreatDirCache[unitID]
    if cached then prevX, prevZ = cached[1], cached[2] end

    local bestScore = -2
    local bestAwayDot = -2
    local bestDirX = awayNX
    local bestDirZ = awayNZ

    for i = 1, TANGENTIAL_ANGLE_COUNT do
        local a = TANGENTIAL_ANGLES[i]
        local cosA = a[1]
        local sinA = a[2]
        local tangX = fwdX * cosA - fwdZ * sinA
        local tangZ = fwdX * sinA + fwdZ * cosA
        local awayDot = tangX * awayNX + tangZ * awayNZ
        local score = awayDot
        if prevX then score = score + 0.25 * (tangX * prevX + tangZ * prevZ) end
        if score > bestScore then
            bestScore = score
            bestAwayDot = awayDot
            bestDirX = tangX
            bestDirZ = tangZ
        end
    end

    -- Every tangent points back at the enemy, just retreat straight away
    if bestAwayDot < -0.55 then
        retreatDirCache[unitID] = nil
        bestDirX = awayNX
        bestDirZ = awayNZ
    else
        retreatDirCache[unitID] = { bestDirX, bestDirZ }
    end

    local tx = ux + bestDirX * dist
    local tz = uz + bestDirZ * dist
    if tx < minX then tx = minX elseif tx > maxX then tx = maxX end
    if tz < minZ then tz = minZ elseif tz > maxZ then tz = maxZ end
    tx, tz = NudgeOutOfLava(tx, tz, ux, uz)
    return tx, tz
end

local function FactoryTurretInfo(facDefID)
    local d = UnitDefs[facDefID]
    local cost = d and (d.metalCost or 0) or 0
    if cost >= 4000 then return 12, 200 end
    if cost >= 1000 then return 8, 160 end
    return 6, 128
end

local vehFacCache = {}
local function IsVehicleFactory(uDefID)
    if not uDefID then return false end
    if vehFacCache[uDefID] ~= nil then return vehFacCache[uDefID] end
    local d = UnitDefs[uDefID]
    if not d or not d.isFactory then vehFacCache[uDefID] = false return false end

    local name = d.name and sLower(d.name) or ""
    local hName = GetHumanName(d)

    if d.minWaterDepth and d.minWaterDepth > 0 then vehFacCache[uDefID] = false return false end

    -- look at moveDef categories, if its not there, then name checks are the fallback
    local mc = d.modCategories
    if mc then
        if mc.bot and not mc.tank then vehFacCache[uDefID] = false return false end
        if mc.tank and not mc.bot then vehFacCache[uDefID] = true return true end
    end

    if sFind(name, "kbot") or sFind(name, "botlab") or sFind(name, "kbotlab") then vehFacCache[uDefID] = false return false end
    if sFind(hName, "kbot") or sFind(hName, "bot lab") or sFind(hName, "kbot lab") or sFind(hName, "k-bots") then vehFacCache[uDefID] = false return false end
    if (sFind(name, "bot") or sFind(hName, "bot")) and not sFind(name, "tank") and not sFind(hName, "tank") then vehFacCache[uDefID] = false return false end

    if sFind(name, "veh") or sFind(name, "vehicle") or sFind(name, "tank") or sFind(hName, "veh") or sFind(hName, "vehicle") or sFind(hName, "tank") then vehFacCache[uDefID] = true return true end
    if sFind(name, "vp") then vehFacCache[uDefID] = true return true end
    if sFind(hName, "vehicle plant") or sFind(hName, "vehicle lab") then vehFacCache[uDefID] = true return true end

    local groundVehCount, groundBotCount = 0, 0
    if d.buildOptions then
        for i = 1, #d.buildOptions do
            local bd = UnitDefs[d.buildOptions[i]]
            if bd and bd.speed and bd.speed > 0 and not bd.canFly and not bd.minWaterDepth then
                local isVeh, isBot = false, false
                local bmc = bd.modCategories
                if bmc then
                    if bmc.bot then isBot = true
                    elseif bmc.tank then isVeh = true end
                end
                if not isVeh and not isBot then
                    local bn = sLower(bd.name or "")
                    if sFind(bn, "veh") or sFind(bn, "tank") or sFind(bn, "lev") or sFind(bn, "rustler") or sFind(bn, "flash") or sFind(bn, "weasel") or sFind(bn, "gator") or sFind(bn, "logger") or sFind(bn, "heavyart") or sFind(bn, "mortartn") or sFind(bn, "pincer") or sFind(bn, "rodos") then
                        isVeh = true
                    elseif sFind(bn, "bot") or sFind(bn, "peew") or sFind(bn, "pew") or sFind(bn, "rocko") or sFind(bn, "rock") or sFind(bn, "zeus") or sFind(bn, "spider") or sFind(bn, "flea") or sFind(bn, "chicken") or sFind(bn, "klack") or sFind(bn, "switch") or sFind(bn, "kbot") then
                        isBot = true
                    end
                end
                if isVeh then groundVehCount = groundVehCount + 1
                elseif isBot then groundBotCount = groundBotCount + 1 end
            end
        end
    end

    if groundVehCount >= groundBotCount and groundVehCount > 0 then vehFacCache[uDefID] = true return true end
    vehFacCache[uDefID] = false
    return false
end

local airFactoryCache = {}
local function IsAirFactory(uDefID)
    if not uDefID then return false end
    if airFactoryCache[uDefID] ~= nil then return airFactoryCache[uDefID] end
    local d = UnitDefs[uDefID]
    local result = false
    if d and d.isFactory and d.buildOptions and #d.buildOptions > 0 then
        local total, airCount = 0, 0
        for i = 1, #d.buildOptions do
            local bd = UnitDefs[d.buildOptions[i]]
            if bd then
                total = total + 1
                if bd.canFly then airCount = airCount + 1 end
            end
        end
        result = total > 0 and (airCount == total)
    end
    airFactoryCache[uDefID] = result
    return result
end

local function GetCheapestVehicleFactory(cache)
    if not cache or not cache.factories then return nil end
    local cheapest, cheapestCost = nil, mHuge
    for i = #cache.factories, 1, -1 do
        local fID = cache.factories[i]
        if IsVehicleFactory(fID) then
            local cost = UnitDefs[fID] and UnitDefs[fID].metalCost or mHuge
            if cost < cheapestCost then cheapestCost = cost cheapest = fID end
        end
    end
    return cheapest
end

local function GetCheapestMobileDefense(cache)
    if not cache or not cache.mobile then return nil end
    local cheapest, cheapestCost = nil, mHuge
    for i = 1, #cache.mobile do
        local d = UnitDefs[cache.mobile[i]]
        if d and d.weapons and #d.weapons > 0 then
            local cost = d.metalCost or mHuge
            if cost < cheapestCost then cheapestCost = cost cheapest = cache.mobile[i] end
        end
    end
    return cheapest
end

local function GetAdvancedVehicleFactory(cache)
    local factories = cache and cache.factories
    if not factories or #factories == 0 then 
        return nil 
    end

    local unitDefs = UnitDefs
    local isVehicleFactory = IsVehicleFactory

    local best, bestCost = nil, -1
    local count = #factories

    for i = 1, count do
        local fID = factories[i]
        if isVehicleFactory(fID) then
            local def = unitDefs[fID]
            local cost = def and def.metalCost or 0
            if cost > bestCost then
                bestCost = cost
                best = fID
            end
        end
    end

    return best
end


local function GetNearestUnclaimedMetalSpot(ux, uz)
    local spots = st.unclaimedMetalSpots
    if not spots or #spots == 0 then 
        return nil, mHuge 
    end

    local claims = st.claimedMexList
    if not claims then claims = {} end

    local bestSpot, bestDistSq = nil, mHuge
    local CLAIM_RADIUS_SQ = 4096

    for i = 1, #spots do
        local spot = spots[i]
        local sx, sz = spot.x, spot.z
        local isClaimed = false

        for k = 1, #claims do
            local claim = claims[k]
            local dx = claim.x - sx
            local dx2 = dx * dx
            if dx2 < CLAIM_RADIUS_SQ then
                local dz = claim.z - sz
                local dz2 = dz * dz
                if dz2 < CLAIM_RADIUS_SQ and (dx2 + dz2) < CLAIM_RADIUS_SQ then
                    isClaimed = true
                    break
                end
            end
        end

        if not isClaimed then
            local dx = sx - ux
            local dx2 = dx * dx
            if dx2 < bestDistSq then
                local dz = sz - uz
                local dz2 = dz * dz
                if dz2 < bestDistSq then
                    local distSq = dx2 + dz2
                    if distSq < bestDistSq then
                        bestDistSq = distSq
                        bestSpot = spot
                    end
                end
            end
        end
    end

    return bestSpot, bestDistSq
end


local function CheckEmergencyEconomy(unitID)
    local cmds = spGetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return false end

    local cmd = cmds[1]
    local cmdId = cmd.id

    if cmdId < 0 then
        local buildDefID = -cmdId
        local buildDef = UnitDefs[buildDefID]
        if not buildDef then return false end

        local params = cmd.params
        if not params or not params[1] or not params[3] then return false end
        local tx, tz = params[1], params[3]

        local nearbyUnits = spGetUnitsInCylinder(tx, tz, 50)
        local incUnitID = nil
        
        if nearbyUnits then
            for i = 1, #nearbyUnits do
                local nID = nearbyUnits[i]
                if spGetUnitDefID(nID) == buildDefID then
                    incUnitID = nID
                    break
                end
            end
        end

        if incUnitID then -- skip if already >5% built
            local hp, maxHp = spGetUnitHealth(incUnitID)
            if hp and maxHp and maxHp > 0 and (hp / maxHp) > 0.05 then 
                return false 
            end
        end

        local isMex = buildDef.extractsMetal and buildDef.extractsMetal > 0
        local isEnergy = false

        if buildDef.energyMake and buildDef.energyMake > 0 then 
            isEnergy = true
        else
            local windGen = buildDef.windGenerator
            if windGen == true or (type(windGen) == "number" and windGen > 0) then 
                isEnergy = true
            else
                local name = sLower(buildDef.name or "")
                -- plain-text search (4th arg) is much faster
                if sFind(name, "solar", 1, true) or sFind(name, "wind", 1, true) 
                   or sFind(name, "fusion", 1, true) or sFind(name, "geo", 1, true) then 
                    isEnergy = true 
                end
            end
        end

        if isMex or isEnergy then return false end

        if st.energyStalling then return "energy" end
        if st.metalStalling then return "metal" end
    else
        if cmdId == cfg.CMD_RECLAIM then return false end
        
        if st.energyStalling then return "energy" end
        if st.metalStalling then return "metal" end
    end
    
    return false
end


local function IsUnitBuildingFactory(unitID)
    local cmds = Spring.GetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return false end
    local cmd = cmds[1]
    if cmd.id < 0 then
        local defID = -cmd.id
        local d = UnitDefs[defID]
        if d and d.isFactory then return true end
    end
    return false
end

local function NeedsOrders(unitID, isFactory, isAttacker, isGraverobber)
    if isFactory then
        if spGetFactoryCommands then
            local factoryCmds = spGetFactoryCommands(unitID, 1)
            return not (factoryCmds and #factoryCmds > 0)
        end
        local currentCmds = spGetUnitCommands(unitID, 1)
        return not (currentCmds and #currentCmds > 0)
    end

    local cmds = spGetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return true end

    local cmd = cmds[1]
    local cmdId = cmd.id
    local params = cmd.params

    if cmdId == cfg.CMD_REPAIR then
        local target = params and params[1]
        if not target then return true end
        local hp, maxHp = spGetUnitHealth(target)
        if hp and maxHp and hp >= maxHp then return true end
    end

    if cmdId == cfg.CMD_RECLAIM or cmdId == cfg.CMD_PATROL or cmdId == CMD_RESURRECT then
        if not isAttacker then
            local mShort = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
            local eShort = mMax(0, (st.energyPull or 0) - (st.energyIncome or 0))
            if mShort >= (st.metalIncome or 0) * cfg.STALL_PULL_METAL_RATIO or eShort >= (st.energyIncome or 0) * cfg.STALL_PULL_ENERGY_RATIO then return true end
        end
        
        -- GRAVEROBBERS ARE BROKEN TODO: This
        if isGraverobber then
            local cmdCount = st.myCommanderCount
            for i = 1, cmdCount do
                local cID = st.myCommanders[i]
                local chp, cmax = spGetUnitHealth(cID)
                if chp and cmax and chp < cmax then return true end
            end
            
            local armyState = st.army.state
            if (armyState == "attacking" or armyState == "searching") and st.myCombatUnitCount > 0 and st.army.targetX then
                local ux2, _, uz2 = spGetUnitPosition(unitID)
                if ux2 then
                    local dx, dz = st.army.targetX - ux2, st.army.targetZ - uz2
                    if dx*dx + dz*dz > 2250000 then return true end
                end
            end
        end
    end




    if cmdId == cfg.CMD_GUARD then
        local target = params and params[1]
        if not target or not spGetUnitDefID(target) then return true end

        if st.factoryWaitState[target] then
            local thp, tmax = spGetUnitHealth(target)
            if thp and tmax and thp >= tmax then return true end
        end

        if st.metalStalling or st.energyStalling then
            local mShort = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
            local eShort = mMax(0, (st.energyPull or 0) - (st.energyIncome or 0))
            if (mShort >= (st.metalIncome or 0) * cfg.STALL_PULL_METAL_RATIO or eShort >= (st.energyIncome or 0) * cfg.STALL_PULL_ENERGY_RATIO) and math.random() < 0.25 then
                return true
            end
            return false
        end
        
        if st.incompleteFactoryCount > 0 and math.random() < 0.1 then return true end
        
        if isAttacker then
            if st.raiderCount > 0 then return true end
            if next(st.enemyBases) ~= nil then return true end 
            if math.random() < 0.05 then return true end
        else
            if math.random() < 0.01 then return true end
        end
        
        local armyState = st.army.state
        -- GRAVEROBBERS ARE BROKEN TODO: This
        if isGraverobber and (armyState == "attacking" or armyState == "searching") and st.myCombatUnitCount > 0 then return true end
        
        return false
    end

    if isAttacker then
        local CMD_ATTACK = cfg.CMD_ATTACK
        local CMD_MOVE = cfg.CMD_MOVE
        local CMD_GUARD = cfg.CMD_GUARD
        local CMD_PATROL = cfg.CMD_PATROL

        return (cmdId ~= CMD_ATTACK and cmdId ~= CMD_MOVE and cmdId ~= CMD_GUARD and cmdId ~= CMD_PATROL)
    end

    return false
end


local function SortByMetalCostDesc(a, b)
    local cA = UnitDefs[a] and UnitDefs[a].metalCost or 0
    local cB = UnitDefs[b] and UnitDefs[b].metalCost or 0
    return cA > cB
end

local function SortFactoriesVehicleFirst(a, b)
    local aVeh = IsVehicleFactory(a) and 1 or 0
    local bVeh = IsVehicleFactory(b) and 1 or 0
    if aVeh ~= bVeh then return aVeh > bVeh end
    return SortByMetalCostDesc(a, b)
end

local function SortByMetalCostAsc(a, b)
    local cA = UnitDefs[a] and UnitDefs[a].metalCost or 0
    local cB = UnitDefs[b] and UnitDefs[b].metalCost or 0
    return cA < cB
end

-- pick a random affordable defense; list is sorted cheapest-first
local function SelectBalancedDefense(list, currentMetal)
    if not list or #list == 0 then return nil end
    currentMetal = currentMetal or 0
    
    local affordable = {}
    for i = 1, #list do
        local defID = list[i]
        if UnitDefs[defID] and (UnitDefs[defID].metalCost or 0) <= currentMetal then
            affordable[#affordable + 1] = defID
        end
    end
    
    -- Nothing affordable: return the cheapest anyway.
    if #affordable == 0 then return list[1] end
    
    return affordable[math.random(#affordable)]
end

local function PickPreferAir(list, isRandom)
    if not list or #list == 0 then return nil end
    local airOptions = {}
    for i = 1, #list do
        local d = UnitDefs[list[i]]
        if d and d.canFly and not (d.transportCapacity and d.transportCapacity > 0) then
            airOptions[#airOptions + 1] = list[i]
        end
    end
    if #airOptions > 0 then return isRandom and airOptions[math.random(#airOptions)] or airOptions[1] end
    
    local nonAirOptions = {}
    for i = 1, #list do
        local d = UnitDefs[list[i]]
        if d and not d.canFly then
            nonAirOptions[#nonAirOptions + 1] = list[i]
        end
    end
    if #nonAirOptions > 0 then return isRandom and nonAirOptions[math.random(#nonAirOptions)] or nonAirOptions[1] end
    
    return isRandom and list[math.random(#list)] or list[1]
end

local function IsAmphibiousCon(name, d)
	-- I know I should be accomdatating to all metal maps, and *maybe*
	-- amphibious cons can be useful (somewhere?)
	-- but in all metal maps that we have so far, there's generally no area where
	-- making amphibious cons is better
	-- they're more expesnive with worse stats
    -- If it were a metal map with a sea,
    -- i'd much rather make an air con
    local hName = GetHumanName(d)
    local desc = GetDescription(d)
    if sFind(hName, "amphibious") or sFind(desc, "amphibious") then
        if d and d.isBuilder and d.speed and d.speed > 0 and not d.canFly then return true end
    end
    if d and d.modCategories and d.modCategories.phib then
        if d.isBuilder and d.speed and d.speed > 0 and not d.canFly then return true end
    end
    if sFind(name, "amph") then return true end
    if sFind(name, "acaorn") then return true end
    if sFind(name, "aconv") then return true end
    if sFind(name, "amcon") then return true end
    if sFind(name, "csub") then return true end
    if d and d.customParams and d.customParams.is_amphibious then return true end
    return false
end

local function IsArtillery(d)
    if d.weapons and d.weapons[1] then
        local wd = d.weapons[1].weaponDef and SafeGetWeaponDef(d.weapons[1].weaponDef)
        if wd and wd.range and wd.range > 850 then return true end
    end
    return false
end

local antinukeDefCache = {}
local function IsAntiNukeDef(uDefID)
    if antinukeDefCache[uDefID] ~= nil then return antinukeDefCache[uDefID] end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d then
        local name = d.name and sLower(d.name) or ""
        if sFind(name, "anti_nuke") or sFind(name, "antinuke") or sFind(name, "nukeguard") then
            result = true
        elseif d.weapons then
            for wi = 1, #d.weapons do
                local wDef = d.weapons[wi].weaponDef and WeaponDefs[d.weapons[wi].weaponDef]
                if wDef then
                    local wType = wDef.type and sLower(wDef.type) or ""
                    if sFind(wType, "antinuke") or ((wDef.interceptor or 0) ~= 0 and wDef.coverageRange) then result = true break end
                end
            end
        end
    end
    antinukeDefCache[uDefID] = result
    return result
end
cfg.IsAntiNukeDef = IsAntiNukeDef

local antinukeCoverageCache = {}
local function GetAntiNukeCoverage(defID)
    if not defID then return 0 end
    local cached = antinukeCoverageCache[defID]
    if cached ~= nil then return cached end
    local d = UnitDefs[defID]
    local best = 0
    if d and d.weapons then
        for i = 1, #d.weapons do
            local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and (wDef.interceptor or 0) ~= 0 and wDef.coverageRange then
                if wDef.coverageRange > best then best = wDef.coverageRange end
            end
        end
    end
    antinukeCoverageCache[defID] = best
    return best
end
cfg.GetAntiNukeCoverage = GetAntiNukeCoverage

local defenseDefCache = {}
local function IsDefenseDef(defID)
    if not defID then return false end
    local cached = defenseDefCache[defID]
    if cached ~= nil then return cached end
    local d = UnitDefs[defID]
    local result = false
    if d then
        local isMobile = d.speed and d.speed > 0
        local hasWpn = d.weapons and #d.weapons > 0
        local isShield = false
        if hasWpn then
            for i = 1, #d.weapons do
                local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
                if wDef and wDef.isShield then isShield = true break end
            end
        end
        local isAntinuke = IsAntiNukeDef(defID)
        local isMex = d.extractsMetal and d.extractsMetal > 0
        local isEnergy = (d.energyMake and d.energyMake > 0) or (d.windGenerator and d.windGenerator > 0)
        local isRadar = (d.radarDistance and d.radarDistance > 0) or (d.sonarDistance and d.sonarDistance > 0)
        if not isMobile and hasWpn and not d.isFactory and not d.isBuilder
            and not isShield and not isAntinuke and not isMex and not isEnergy and not isRadar then
            result = true
        end
    end
    defenseDefCache[defID] = result
    return result
end
cfg.IsDefenseDef = IsDefenseDef

local aaOnlyDefCache = {}
local function IsAAOnlyDef(defID)
    if not defID then return false end
    local cached = aaOnlyDefCache[defID]
    if cached ~= nil then return cached end
    if not IsDefenseDef(defID) then aaOnlyDefCache[defID] = false return false end
    local d = UnitDefs[defID]
    local result = false
    if d and d.weapons and #d.weapons > 0 then
        result = true
        for i = 1, #d.weapons do
            if not cfg.IsAAWeapon(defID, d.weapons[i].weaponDef) then result = false break end
        end
    end
    aaOnlyDefCache[defID] = result
    return result
end

local function IsScoutDef(d)
    if not d then return false end
    local mc = d.modCategories
    if mc then
        for k in pairs(mc) do
            if sFind(k, "scout") then return true end
        end
    end
    local cat = d.category
    if type(cat) == "string" and sFind(cat, "SCOUT") then return true end
    local name = d.name and sLower(d.name) or ""
    local hName = GetHumanName(d)
    if sFind(name, "scout") or sFind(hName, "scout") or sFind(name, "peep") or sFind(name, "flea") or sFind(name, "fink") or sFind(name, "phantom") or sFind(name, "weasel") or sFind(name, "wheelie") then
        return true
    end
    return (d.speed and d.speed > 150 and (not d.weapons or #d.weapons == 0))
end

local function IsWallDef(d)
    if not d then return false end
    if d.speed and d.speed > 0 then return false end
    if (d.weapons and #d.weapons > 0) then return false end
    if (d.metalCost or 0) > 100 then return false end
    local name = d.name and sLower(d.name) or ""
    local hName = GetHumanName(d)
    if sFind(name, "drag") or sFind(name, "claw") or sFind(name, "maw") or sFind(name, "teeth") or sFind(name, "wall") then return true end
    if sFind(hName, "dragon") or sFind(hName, "teeth") then return true end
    return false
end

local function GetBuildCache(uDefID)
    local cached = st.buildCache[uDefID]
    if cached then return cached end

    local c = { factories = {}, mex = {}, energyAdv = {}, energyWind = {}, energySolar = {}, cons = {}, mobile = {}, artillery = {}, defenses = {}, defensesGround = {}, defensesAA = {}, other = {}, conTurrets = {}, shields = {}, antinukes = {}, jammers = {}, radars = {}, radarTowers = {}, laz = {}, trappers = {}, scouts = {} }
    local opts = UnitDefs[uDefID] and UnitDefs[uDefID].buildOptions

    if opts then
        for i = 1, #opts do
            local bID = opts[i]
            local d = UnitDefs[bID]
            if d then
                local name = d.name and sLower(d.name) or ""
                local hName = GetHumanName(d)
                local isWaterUnit = (d.minWaterDepth and d.minWaterDepth > 0) or (d.needWater)

                if isWaterUnit or sFind(name, "torpedo") or sFind(name, "tidal") or sFind(name, "sonar") or sFind(name, "shipyard") or sFind(name, "subpen") then isWaterUnit = true end
                if not isWaterUnit and d.weapons then
                    for wi = 1, #d.weapons do
                        local wDef = d.weapons[wi].weaponDef and WeaponDefs[d.weapons[wi].weaponDef]
                        if wDef then
                            local wType = wDef.type and sLower(wDef.type) or ""
                            local wName = wDef.name and sLower(wDef.name) or ""
                            if sFind(wType, "torpedo") or sFind(wName, "torpedo") or sFind(wName, "depthcharge") then isWaterUnit = true break end
                        end
                    end
                end

                local isCloaked = d.canCloak or sFind(name, "cloak")
                local isTransport = (d.transportCapacity and d.transportCapacity > 0) or d.isTransport
                if not (isWaterUnit or isCloaked or isTransport) and not sFind(name, "juno") then
                    local isMobile = d.speed and d.speed > 0
                    local isMex = d.extractsMetal and d.extractsMetal > 0
                    local isWindGenDef = false
                    if d.windGenerator then
                        if type(d.windGenerator) == "number" and d.windGenerator > 0 then isWindGenDef = true
                        elseif type(d.windGenerator) == "boolean" and d.windGenerator == true then isWindGenDef = true end
                    end

                    local isEnergy = (not isMobile) and ((d.energyMake and d.energyMake > 0) or isWindGenDef or sFind(name, "win") or sFind(hName, "wind") or sFind(hName, "turbine") or sFind(name, "solar") or sFind(hName, "solar") or sFind(name, "fusion") or sFind(hName, "fusion") or sFind(name, "geo") or sFind(hName, "geo"))
                    local isConTurret = d.isBuilder and not isMobile and not (d.canResurrect)
                    -- DON'T MAKE CONVERTORS!!
                    local isConverter = (not isMobile) and (
                        (d.makesMetal and d.makesMetal > 0) or (d.metalMake and d.metalMake > 0)
                        or ((d.energyMake and d.energyMake > 0) and ((d.metalUse and d.metalUse > 0) or (d.metalUpkeep and d.metalUpkeep > 0)))
                    )
                    local isShield = false
                    if d.weapons then
                        for wi = 1, #d.weapons do
                            local wDef = SafeGetWeaponDef(d.weapons[wi].weaponDef)
                            if wDef and wDef.isShield then isShield = true break end
                        end
                    end
                    if not isShield then
                        isShield = sFind(name, "shield") or sFind(name, "aegis") or sFind(name, "aspis") or sFind(name, "corash") or sFind(name, "deflector") or sFind(name, "gate")
                    end
                    local isRadarTower = (d.radarDistance and d.radarDistance > 0) or (d.sonarDistance and d.sonarDistance > 0)

                    if IsAntiNukeDef(bID) and not (d.speed and d.speed > 0) then tInsert(c.antinukes, bID)
                    elseif isShield and not isMobile then tInsert(c.shields, bID)
                    elseif d.isFactory then tInsert(c.factories, bID)
                    elseif isMobile then
                        local isLaz = d.canResurrect or sFind(name, "lazarus") or sFind(name, "graverobber") or sFind(name, "zagreus")
                        local isTrapper = IsTrapper(d)

                        if isLaz then
                            tInsert(c.laz, bID)
                        elseif isTrapper then
                            tInsert(c.trappers, bID)
                        elseif d.isBuilder and d.buildOptions and #d.buildOptions > 0 then
                            if not IsAmphibiousCon(name, d) then
                                tInsert(c.cons, bID)
                            end
                        elseif IsArtillery(d) then
                            tInsert(c.artillery, bID)
                        else
                            local isJammer = (d.radarDistanceJam and d.radarDistanceJam > 0) or sFind(name, "jammer") or sFind(name, "jam")
                            local isRadar = (d.radarDistance and d.radarDistance > 0 and not d.weapons) or sFind(name, "radar")
                            local isScoutDef = IsScoutDef(d)
                            if isJammer then tInsert(c.jammers, bID)
                            elseif isRadar then tInsert(c.radars, bID)
                            elseif isScoutDef then tInsert(c.scouts, bID)
                            else tInsert(c.mobile, bID) end
                        end
                    elseif isMex then tInsert(c.mex, bID)
                    elseif isConverter then -- DON'T MAKE CONVERTORS!!
                    elseif isConTurret then tInsert(c.conTurrets, bID)
                    elseif isEnergy then
                        local isAdvEnergy = (d.metalCost and d.metalCost >= 1000) or sFind(name, "fusion") or sFind(hName, "fusion") or sFind(name, "afus")
                        local isWind = isWindGenDef or sFind(name, "win") or sFind(hName, "wind") or sFind(hName, "turbine")
                        local isSolar = sFind(name, "solar") or sFind(hName, "solar")
                        local isGeo = sFind(name, "geo") or sFind(hName, "geo")
                        if isAdvEnergy or isGeo then tInsert(c.energyAdv, bID)
                        elseif isWind then tInsert(c.energyWind, bID)
                        elseif isSolar then tInsert(c.energySolar, bID)
                        else tInsert(c.other, bID) end
                    elseif isRadarTower then tInsert(c.radarTowers, bID)
                    elseif IsDefenseDef(bID) then
                        tInsert(c.defenses, bID)
                        if IsAAOnlyDef(bID) then tInsert(c.defensesAA, bID)
                        else tInsert(c.defensesGround, bID) end
                    else tInsert(c.other, bID) end
                end
            end
        end
    end

    tSort(c.factories, SortFactoriesVehicleFirst)
    tSort(c.mex, SortByMetalCostDesc)
    tSort(c.energyAdv, SortByMetalCostDesc)
    tSort(c.energyWind, SortByMetalCostDesc)
    tSort(c.energySolar, SortByMetalCostDesc)
    tSort(c.shields, SortByMetalCostDesc)
    tSort(c.antinukes, SortByMetalCostDesc)
    tSort(c.defenses, SortByMetalCostAsc)
    tSort(c.defensesGround, SortByMetalCostAsc)
    tSort(c.defensesAA, SortByMetalCostAsc)
    tSort(c.cons, SortByMetalCostAsc)
    
    st.buildCache[uDefID] = c
    return c
end


local function GetFacingVector(facing)
    if facing == 0 then return 0, 1
    elseif facing == 1 then return 1, 0
    elseif facing == 2 then return 0, -1
    elseif facing == 3 then return -1, 0
    end
    return 0, 1
end

local function GetNearestFactoryPos(ux, uz)
    if st.myFactoriesCount == 0 then return ux, uz end
    local bestFx, bestFz, bestDist = ux, uz, mHuge
    for j = 1, st.myFactoriesCount do
        local fID = st.myFactories[j]
        local fx, _, fz = spGetUnitPosition(fID)
        if fx then
            local dx, dz = fx - ux, fz - uz
            local dist = dx * dx + dz * dz
            if dist < bestDist then bestDist, bestFx, bestFz = dist, fx, fz end
        end
    end
    return bestFx, bestFz
end

local function GetDominantFactoryDefID()
    if st.myFactoriesCount == 0 then return nil end
    local counts, bestDef, bestCount = {}, nil, 0
    for j = 1, st.myFactoriesCount do
        local fDefID = spGetUnitDefID(st.myFactories[j])
        if fDefID then
            counts[fDefID] = (counts[fDefID] or 0) + 1
            if counts[fDefID] > bestCount then bestCount = counts[fDefID] bestDef = fDefID end
        end
    end
    return bestDef
end

local cheapestMexInfo = nil
local function GetCheapestMexInfo()
    if cheapestMexInfo then return cheapestMexInfo end
    local best, bestCost = nil, mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and d.extractsMetal and d.extractsMetal > 0 and not d.isFactory then
            local cost = d.metalCost or mHuge
            if cost < bestCost then bestCost, best = cost, d end
        end
    end
    cheapestMexInfo = { def = best, cost = bestCost }
    return cheapestMexInfo
end

-- metal/s a new mex adds
local function GetMexGain()
    local count = st.mexUnitCount or 0
    local income = st.metalIncome or 0
    if count > 0 and income > 0 then
        return income / count
    end
    local info = GetCheapestMexInfo()
    local em = (info.def and info.def.extractsMetal) or 0.0008
    return em * 30 * (Game.mapHardness or 100)
end

-- cheapest energy producer; BAR expresses production three ways
-- (energyMake, negative energyUpkeep, windGenerator)
local cheapestEnergyInfo = nil
local function GetCheapestEnergyInfo()
    if cheapestEnergyInfo then return cheapestEnergyInfo end
    local best, bestCost = nil, mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and not d.isFactory then
            local makesEnergy = (d.energyMake and d.energyMake > 0)
                or (d.energyUpkeep and d.energyUpkeep < 0)
                or (d.windGenerator and d.windGenerator > 0)
            if makesEnergy then
                local cost = d.metalCost or mHuge
                if cost < bestCost then bestCost, best = cost, d end
            end
        end
    end
    local output = 0
    if best then
        if best.energyMake and best.energyMake > 0 then output = best.energyMake
        elseif best.energyUpkeep and best.energyUpkeep < 0 then output = -best.energyUpkeep
        elseif best.windGenerator and best.windGenerator > 0 then output = best.windGenerator end
    end
    cheapestEnergyInfo = { def = best, cost = bestCost, output = output }
    return cheapestEnergyInfo
end

local function GetEnergyGain()
    local info = GetCheapestEnergyInfo()
    return (info.output and info.output > 0 and info.output) or 15
end

local cheapestFactoryInfo = nil
local function GetCheapestFactoryInfo()
    if cheapestFactoryInfo then return cheapestFactoryInfo end
    local best, bestCost = nil, mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and d.isFactory then
            local cost = d.metalCost or mHuge
            if cost < bestCost then bestCost, best = cost, d end
        end
    end
    cheapestFactoryInfo = { def = best, cost = bestCost }
    return cheapestFactoryInfo
end

-- The speed a combat unit must have to double as a scout,
-- My thinking is factions scouts can have different speeds, so let's not hardcode anything
local scoutSpeedThreshold = nil
local function GetScoutSpeedThreshold()
    if scoutSpeedThreshold then return scoutSpeedThreshold end
    local best = mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and IsScoutDef(d) and d.speed and d.speed > 0 then
            if d.speed < best then best = d.speed end
        end
    end
    scoutSpeedThreshold = (best ~= mHuge) and best or 45
    return scoutSpeedThreshold
end

-- blast radius from the unit's selfDExplosion weapon TODO: work on this
local selfDBlastCache = {}
local function GetSelfDBlastRadius(defID)
    if selfDBlastCache[defID] ~= nil then return selfDBlastCache[defID] end
    local d = defID and UnitDefs[defID]
    local result = 0
    if d then
        local sdn = d.selfDExplosion
        if sdn and sdn ~= "" then
            local wn = WeaponDefNames[sdn] or WeaponDefNames[sLower(sdn)]
            local wid = wn and wn.id
            local wd = wid and WeaponDefs[wid]
            if wd then result = wd.damageAreaOfEffect or wd.areaOfEffect or 0 end
        end
    end
    selfDBlastCache[defID] = result
    return result
end

-- 60 upvalue limit stuff
cfg.GetMexGain            = GetMexGain
cfg.GetEnergyGain         = GetEnergyGain
cfg.GetScoutSpeedThreshold = GetScoutSpeedThreshold
cfg.GetSelfDBlastRadius   = GetSelfDBlastRadius
cfg.GetSpreadPos          = GetSpreadPos
cfg.GetFlankSpreadPos     = GetFlankSpreadPos
cfg.IsTrapper             = IsTrapper
cfg.GetTangentialRetreat  = GetTangentialRetreat

local function CanAffordBuild(defID, isEssential)
    local d = UnitDefs[defID]
    if not d then return true end
    local cost = d.metalCost or 0
    if cost <= 0 then return true end
    local available = mMax(0, st.currentMetal - st.pendingCommittedMetal)
    if isEssential then
        if cost <= 160 then return true end
        return available >= cost * 0.5 or not st.metalStalling
    end
    -- judge non-essential builds against a short income window
    local incomeWindow = 12
    if st.metalStalling then
        return cost <= mMax(st.metalIncome * 2, 40) -- let small builds go in a brief stall
    end
    if cost <= available then return true end
    return cost <= mMax(st.metalIncome * incomeWindow, 60)
end

-- without this the bot won't build t3
local function CanAffordCombatUnit(defID)
    local d = UnitDefs[defID]
    if not d then return true end
    local cost = d.metalCost or 0
    if cost <= 0 then return true end
    local available = mMax(0, st.currentMetal - st.pendingCommittedMetal)
    if st.metalStalling then
        return cost <= mMax(st.metalIncome * 2, 40) -- don't idle the factory in a brief stall
    end
    if cost <= available then return true end
    local incomeWindow = cfg.INCOME_WINDOW_BASE + cost * cfg.INCOME_WINDOW_COST_RATIO
    return cost <= mMax(st.metalIncome * incomeWindow, 60)
end
cfg.CanAffordCombatUnit = CanAffordCombatUnit

cfg.CanTechUpToFactory = function(fID)
    local def = UnitDefs[fID]
    if not def then return false end

    local techLevel = def.customParams and tonumber(def.customParams.techlevel) or 1

    if techLevel <= 1 then
        if st.hasT2Lab or (st.hasAdvancedFactory and (st.advConCount or 0) > 0) then
            return false
        end
        return true
    end

    local cost = def.metalCost or 0

    local paybackSecs = cfg.ADV_FACTORY_PAYBACK_SECS or 1
    local requiredIncome = cost / paybackSecs

    if (st.metalIncome or 0) >= requiredIncome then
        return true
    end

    local currentMetal = st.currentMetal or 0
    local pendingMetal = st.pendingCommittedMetal or 0
    local availableMetal = mMax(0, currentMetal - pendingMetal)

    return availableMetal >= cost
end


local STANDARD_FACINGS = { 0, 1, 2, 3 }

local function FindBuildSpot(ux, uz, defID, spacingOverride, excludeUnitID, preferRadius, blockAnchorR2, preferFacing, radial, tight, radialAnchorHalf)
    local d = UnitDefs[defID]
    local isBuildingFactory = d and d.isFactory and not IsAirFactory(defID)
    -- con turrets are not a rez bot and not a factory.
    local isConTurret = d and d.isBuilder and (not d.speed or d.speed == 0) and not d.canResurrect and not d.isFactory

    local frame = st.frameNum or 0

    -- With a preferred facing (initial factory), try it first on every tile
    local facingOrder = STANDARD_FACINGS
    if preferFacing then
        facingOrder = { preferFacing, (preferFacing + 1) % 4, (preferFacing + 2) % 4, (preferFacing + 3) % 4 }
    end

    local xsize = d and d.xsize or 4
    local zsize = d and d.zsize or 4
    local actualSpacing = mMax(xsize, zsize) * 8 + 16
    if spacingOverride then actualSpacing = spacingOverride end

    local stepSize = mMax(16, mFloor(actualSpacing / 16) * 16)
    if stepSize < 32 then stepSize = 32 end

    local gridStartX = mFloor(ux / stepSize) * stepSize
    local gridStartZ = mFloor(uz / stepSize) * stepSize

    local mapMaxX = Game.mapSizeX or 8192
    local mapMaxZ = Game.mapSizeZ or 8192

    -- spatial hash grid
    local obsGrid = {}
    local cellSize = 256

    local function AddObstacle(x, z, r2)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        local col = obsGrid[cellX]
        if not col then
            col = {}
            obsGrid[cellX] = col
        end
        local cell = col[cellZ]
        if not cell then
            cell = {}
            col[cellZ] = cell
        end
        -- Flat layout: x, z, r2
        local n = #cell
        cell[n + 1] = x
        cell[n + 2] = z
        cell[n + 3] = r2
    end

    -- no matter how big I make this exit corridor
    -- some con bots going to block it
    local function AddExitCorridor(cx, cz, dirX, dirZ, halfWidth)
        local px, pz = -dirZ, dirX
        local start = mMax(32, halfWidth or 32)
        for dist = start, 960, 60 do
            for lat = -40, 40, 40 do
                AddObstacle(cx + dirX * dist + px * lat, cz + dirZ * dist + pz * lat, 40 * 40)
            end
        end
    end

    local function IsBlocked(x, z)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        for cx = -1, 1 do
            local col = obsGrid[cellX + cx]
            if col then
                for cz = -1, 1 do
                    local cell = col[cellZ + cz]
                    if cell then
                        local n = #cell
                        local i = 1
                        while i <= n do
                            local ox = cell[i]
                            local oz = cell[i + 1]
                            local or2 = cell[i + 2]
                            local ddx = x - ox
                            local ddz = z - oz
                            if (ddx * ddx + ddz * ddz) < or2 then
                                return true
                            end
                            i = i + 3
                        end
                    end
                end
            end
        end
        return false
    end

    local function BlockedForUnit(x, z, halfW)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        local hw = halfW or 0
        for cx = -1, 1 do
            local col = obsGrid[cellX + cx]
            if col then
                for cz = -1, 1 do
                    local cell = col[cellZ + cz]
                    if cell then
                        local n = #cell
                        local i = 1
                        while i <= n do
                            local ox = cell[i]
                            local oz = cell[i + 1]
                            local r = math.sqrt(cell[i + 2]) + hw
                            local ddx = x - ox
                            local ddz = z - oz
                            if (ddx * ddx + ddz * ddz) < r * r then return true end
                            i = i + 3
                        end
                    end
                end
            end
        end
        return false
    end

    -- detect open ground
    local function ObstacleNear(x, z, radius)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        local span = math.ceil(radius / cellSize)
        local r2 = radius * radius
        for cx = cellX - span, cellX + span do
            local col = obsGrid[cx]
            if col then
                for cz = cellZ - span, cellZ + span do
                    local cell = col[cz]
                    if cell then
                        local n = #cell
                        local i = 1
                        while i <= n do
                            local ox = cell[i]
                            local oz = cell[i + 1]
                            local ddx = x - ox
                            local ddz = z - oz
                            if (ddx * ddx + ddz * ddz) < r2 then return true end
                            i = i + 3
                        end
                    end
                end
            end
        end
        return false
    end

    -- straight-line exit check for factories
    local function IsExitCorridorClear(cx, cz, dirX, dirZ, halfWidth)
        local px, pz = -dirZ, dirX
        local halfW = mMax(48, halfWidth or 32)
        local start = mMax(32, halfWidth or 32)
        for dist = start, 480, 40 do
            local bx = cx + dirX * dist
            local bz = cz + dirZ * dist
            if IsBlocked(bx, bz) then return false end
            for lat = 32, halfW, 32 do
                if IsBlocked(bx + px * lat, bz + pz * lat) then return false end
                if IsBlocked(bx - px * lat, bz - pz * lat) then return false end
            end
        end
        return true
    end

    -- Flood fill from a start point till we reach somewhere open.
    -- TODO: optimizations here are always nice, especially with more cons
    -- Also TODO: This algorithm still needs improvements, it's not perfect, like t3 units getting trapped.
    local function HasExitPath(ex, ez, opts)
        local step = opts.step or 96
        local maxRadius = cfg.BUILD_RADIUS
        local clearR = 360
        local maxDist2 = maxRadius * maxRadius
        local escDist2 = opts.escapeDist and (opts.escapeDist * opts.escapeDist) or nil
        local wallX, wallZ = opts.wallX, opts.wallZ
        local halfW = opts.halfW or 16
        local wallEffR2 = nil
        if opts.wallR2 then
            local wr = math.sqrt(opts.wallR2) + halfW
            wallEffR2 = wr * wr
        end
        -- stay on the map, this caused issues when a factory faced one of the map walls
        -- and the flood fill thought that it was open ground
        local mapMaxX = (Game.mapSizeX or 8192) - 80
        local mapMaxZ = (Game.mapSizeZ or 8192) - 80
        -- offset so the lattice never aligns with build grids (reads dense fields as sealed)
        local lx, lz = ex, ez
        if opts.originOffset then lx, lz = ex + opts.originOffset, ez + opts.originOffset end

        -- Cache floods by start + params
        local frame = st.frameNum or 0
        local bk = step .. "_" .. (opts.escapeDist or 0) .. "_" .. (opts.originOffset or 0) .. "_" .. halfW .. "_" .. (opts.wallR2 or 0) .. "_" .. (opts.anchorR2 or 0) .. "_" .. (opts.excl or 0)
        local exitMap = buildExitCache[bk]
        if not exitMap then exitMap = {} buildExitCache[bk] = exitMap end
        local lx0 = mFloor(lx / step)
        local lz0 = mFloor(lz / step)
        local wlx0 = (wallX and mFloor(wallX / step)) or 0
        local wlz0 = (wallZ and mFloor(wallZ / step)) or 0
        local ckey = (lx0 * 8192 + lz0) * 8388608 + wlx0 * 8192 + wlz0
        local ce = exitMap[ckey]
        if ce and frame - ce.f <= buildCacheTTL then return ce.r, ce.d end

        -- Start off-map: nothing to march out to.
        if lx < 80 or lz < 80 or lx > mapMaxX or lz > mapMaxZ then return false, 0 end

        local openX = { lx }
        local openZ = { lz }
        local openD = { 0 }
        local seen = {}
        seen[lx0 * 4096 + lz0] = true
        local k = 1
        local len = 1
        local res = false
        local resDepth = 0
        while k <= len do
            local cx, cz, cd = openX[k], openZ[k], openD[k]
            k = k + 1
            local clear = false
            if cx >= 80 and cz >= 80 and cx <= mapMaxX and cz <= mapMaxZ then
                clear = not ObstacleNear(cx, cz, clearR)
                if clear and wallX then
                    local wx = cx - wallX
                    local wz = cz - wallZ
                    if wx * wx + wz * wz < clearR * clearR then clear = false end
                end
            end
            if clear then res = true resDepth = cd break end
            local dx0, dz0 = cx - lx, cz - lz
            if escDist2 and dx0 * dx0 + dz0 * dz0 > escDist2 then res = true resDepth = cd break end
            if dx0 * dx0 + dz0 * dz0 <= maxDist2 then
                for dxi = -1, 1 do
                    for dzi = -1, 1 do
                        if dxi ~= 0 or dzi ~= 0 then
                            local nx = cx + dxi * step
                            local nz = cz + dzi * step
                            if nx >= 80 and nz >= 80 and nx <= mapMaxX and nz <= mapMaxZ then
                                local nkey = mFloor(nx / step) * 4096 + mFloor(nz / step)
                                if not seen[nkey] then
                                    seen[nkey] = true
                                    local blocked = false
                                    -- No corner-cutting: a diagonal step needs both
                                    -- adjacent cardinal cells free.
                                    if dxi ~= 0 and dzi ~= 0 then
                                        blocked = BlockedForUnit(cx + dxi * step, cz, halfW) or BlockedForUnit(cx, cz + dzi * step, halfW)
                                    end
                                    if not blocked then
                                        blocked = BlockedForUnit(nx, nz, halfW)
                                    end
                                    if not blocked and wallEffR2 then
                                        local wx = nx - wallX
                                        local wz = nz - wallZ
                                        if wx * wx + wz * wz < wallEffR2 then blocked = true end
                                    end
                                    if not blocked then
                                        len = len + 1
                                        openX[len] = nx
                                        openZ[len] = nz
                                        openD[len] = cd + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        exitMap[ckey] = { r = res, d = resDepth, f = frame }
        buildExitCount = buildExitCount + 1
        if buildExitCount > 80000 then
            buildExitCache = {}
            buildExitCount = 0
        end
        return res, resDepth
    end

    -- the obstacle scan is filtered to our team (enemies are caught by spTestBuildOrder)
    local myTeamID = spGetMyTeamID()
    local oCellX = mFloor(ux / OBSTACLE_SCAN_CELL)
    local oCellZ = mFloor(uz / OBSTACLE_SCAN_CELL)
    local oKey = oCellX * 8192 + oCellZ
    local oce = obstacleScanCache[oKey]
    if not oce or (frame - oce.f) > buildCacheTTL then
        local scX = (oCellX + 0.5) * OBSTACLE_SCAN_CELL
        local scZ = (oCellZ + 0.5) * OBSTACLE_SCAN_CELL
        local scanR = cfg.BUILD_RADIUS + OBSTACLE_SCAN_PAD
        oce = { f = frame, units = spGetUnitsInCylinder(scX, scZ, scanR, myTeamID), feats = spGetFeaturesInCylinder(scX, scZ, scanR) }
        obstacleScanCache[oKey] = oce
    end
    local nearbyUnits = oce.units
    if nearbyUnits then
        for i = 1, #nearbyUnits do
            local nID = nearbyUnits[i]
            local nx, _, nz = spGetUnitPosition(nID)
            local ndID = spGetUnitDefID(nID)
            local nd = ndID and UnitDefs[ndID]
            if nx and nz and nd then
                local obsRadius = 0
                if nd.isFactory then
                    if IsAirFactory(ndID) then obsRadius = 120
                    else
                        -- con turrets hug the lab, eco has to stay away
                        if isConTurret then
                            obsRadius = (mMax(nd.xsize or 8, nd.zsize or 8) * 8) / 2 + 8
                        else
                            obsRadius = select(2, FactoryTurretInfo(ndID))
                        end
                        local unitFacing = spGetUnitBuildFacing(nID) or 0
                        local dirX, dirZ = GetFacingVector(unitFacing)
                        AddExitCorridor(nx, nz, dirX, dirZ, (mMax(nd.xsize or 8, nd.zsize or 8) * 8) / 2)
                    end
                elseif nd.isBuilding then 
                    obsRadius = (nd.xsize and nd.xsize * 8 or 16) + 8 
                end
                if excludeUnitID and nID == excludeUnitID then obsRadius = 0 end
                if obsRadius > 0 then AddObstacle(nx, nz, obsRadius * obsRadius) end
            end
        end
    end

    local nearbyFeatures = oce.feats
    if nearbyFeatures then
        for i = 1, #nearbyFeatures do
            local fID = nearbyFeatures[i]
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx and fz then AddObstacle(fx, fz, 32 * 32) end
        end
    end

    for _, claim in pairs(st.claimedSpots) do
        local cr2 = claim.r2
        -- con turrets can (and should) sit inside a lab's keep-out
        -- eco needs to stay away
        if claim.isFactory and not claim.isAirFactory and isConTurret then
            local cDef = claim.defID and UnitDefs[claim.defID]
            local cR = (mMax(cDef and cDef.xsize or 8, cDef and cDef.zsize or 8) * 8) / 2 + 8
            cr2 = cR * cR
        end
        AddObstacle(claim.x, claim.z, cr2)
        if claim.isFactory and not claim.isAirFactory then
            local dirX, dirZ = GetFacingVector(claim.facing or 0)
            local cDef = claim.defID and UnitDefs[claim.defID]
            AddExitCorridor(claim.x, claim.z, dirX, dirZ, (mMax(cDef and cDef.xsize or 8, cDef and cDef.zsize or 8) * 8) / 2)
        end
    end

    -- Re-add the anchor (commander/con) as a real obstacle: TestBuildOrder never
    -- checks unit collisions, so without this the new build could land on the
    -- builder itself.
    if blockAnchorR2 and blockAnchorR2 > 0 then
        AddObstacle(ux, uz, blockAnchorR2)
    end

    -- half-footprint of the excluded builder
    local exclR = nil
    if excludeUnitID then
        local eID = spGetUnitDefID(excludeUnitID)
        local eDef = eID and UnitDefs[eID]
        if eDef then exclR = (mMax(eDef.xsize or 1, eDef.zsize or 1) * 8) / 2 end
    end

    local maxRing = mFloor(cfg.BUILD_RADIUS / stepSize)

    -- We should prefer spots within the builder's own build distance; and only fall back
    -- to the full search radius only if nothing is buildable nearby.
    local preferRing = preferRadius and mFloor(preferRadius / stepSize) or maxRing
    if preferRing < 0 then preferRing = 0 elseif preferRing > maxRing then preferRing = maxRing end

    -- Once we know where an enemy base is, grow the base
    -- away from the enemy
    local fdx, fdz = nil, nil
    local isMex = d.extractsMetal and d.extractsMetal > 0
    local isMine = sFind(sLower(d.name or ""), "mine") ~= nil
    if not isMex and not isMine and st.enemyBases and next(st.enemyBases) ~= nil then
        local refX, refZ = st.baseCenterX or ux, st.baseCenterZ or uz
        local bestD = mHuge
        for _, b in pairs(st.enemyBases) do
            if b.lastSeen then
                local bdx, bdz = b.x - refX, b.z - refZ
                local bd = bdx * bdx + bdz * bdz
                if bd < bestD then bestD, fdx, fdz = bd, bdx, bdz end
            end
        end
        if fdx then
            local fl = math.sqrt(fdx * fdx + fdz * fdz)
            if fl > 1 then fdx, fdz = fdx / fl, fdz / fl end
        end
    end

    local function ClaimSpot(key, tx, tz, f)
        if not key then return end
        local halfR = ((mMax(xsize, zsize) * 8) / 2 + 8)
        st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = halfR * halfR, isFactory = false, isAirFactory = false, facing = f, defID = defID, isMex = false }
    end

    local diagReject = nil
    local diagActive = false

    local function TryTile(gx, gz)
        if diagActive then diagReject = nil end
        if gx < 0 or gz < 0 or gx >= mapMaxX or gz >= mapMaxZ then if diagActive then diagReject = "bounds" end return nil end
        local tx = mFloor(gx / 16 + 0.5) * 16
        local tz = mFloor(gz / 16 + 0.5) * 16
        if IsBlocked(tx, tz) then if diagActive then diagReject = "blocked" end return nil end
        -- Never build into void/lava
        if IsInaccessible(tx, tz) then if diagActive then diagReject = "inacc" end return nil end
        -- Never overlap the builder itself (it's excluded from the obstacle
        -- grid above, so this is the only guard).
        if exclR then
            local ex, _, ez = spGetUnitPosition(excludeUnitID)
            if ex then
                local req = (mMax(xsize, zsize) * 8) / 2 + exclR + 12
                local adx, adz = tx - ex, tz - ez
                if adx * adx + adz * adz < req * req then if diagActive then diagReject = "overlap" end return nil end
            end
        end
        -- cached spTestBuildOrder + ground height
        local tkey = (tx * 1048576 + tz) * 4
        local tbc = buildTestCache[defID]
        local ty = nil
        if diagActive then diagReject = "test" end
        for fi = 1, 4 do
            local f = facingOrder[fi]
            local te
            if tbc then te = tbc[tkey + f] end
            local ok
            if te and (frame - te.f) <= buildCacheTTL then
                ok = te.r
                if not ty then ty = te.y end
            else
                if not ty then ty = spGetGroundHeight(tx, tz) end
                ok = spTestBuildOrder(defID, tx, ty, tz, f) ~= 0
                if not tbc then tbc = {} buildTestCache[defID] = tbc end
                local cnt = (buildTestCount[defID] or 0) + 1
                if cnt > 32768 then
                    tbc = {} buildTestCache[defID] = tbc
                    buildTestCount[defID] = 0
                else
                    buildTestCount[defID] = cnt
                end
                tbc[tkey + f] = { r = ok, y = ty, f = frame }
            end
            if ok then
                local facClear = true
                if isBuildingFactory then
                    local dirX, dirZ = GetFacingVector(f)
                    local facHalf = (mMax(xsize, zsize) * 8) / 2
                    -- Is the exit corridor directly clear and theres a real walking path out?
                    if not IsExitCorridorClear(tx, tz, dirX, dirZ, facHalf) then
                        facClear = false
                        if diagActive then diagReject = "exit" end
                    end
                    if facClear and not HasExitPath(tx + dirX * (facHalf + 40), tz + dirZ * (facHalf + 40), { step = 64, halfW = 24, anchorR2 = blockAnchorR2, excl = excludeUnitID }) then
                        facClear = false
                        if diagActive then diagReject = "exit" end
                    end
                else
                    -- the builder shouldn't wall itself in
                    if not isConTurret and ObstacleNear(ux, uz, 400) then
                        local wallR = (mMax(xsize, zsize) * 8) / 2 + 8
                        if not HasExitPath(ux, uz, { step = 64, originOffset = 32, escapeDist = 800, wallX = tx, wallZ = tz, wallR2 = wallR * wallR, anchorR2 = blockAnchorR2, excl = excludeUnitID }) then
                            facClear = false
                            if diagActive then diagReject = "exit" end
                        end
                    end
                end

                if facClear then
                    local key = mFloor(tx) .. "_" .. mFloor(tz)
                    return tx, ty, tz, f, key
                end
            end
        end
        return nil
    end

    if radial then
        local rOut = preferRadius or cfg.BUILD_RADIUS
        local rMin = mMax(stepSize, mFloor(((radialAnchorHalf or 0) + (mMax(xsize, zsize) * 8) / 2 + 8) / stepSize + 1) * stepSize)
        if st.turretDbg then
            diagActive = true
            local tDef = UnitDefs[defID]
            st.turretDbg.lastDef = (tDef and tDef.name) or defID
            st.turretDbg.lastSpacing = stepSize
            st.turretDbg.lastRingOut = rOut
        end
        for r = rMin, rOut, stepSize do
            local n = mMax(6, mFloor((2 * math.pi * r) / stepSize))
            for s = 0, n - 1 do
                local ang = (s / n) * (2 * math.pi)
                local rx, ry, rz, rf, rk = TryTile(ux + math.cos(ang) * r, uz + math.sin(ang) * r)
                if rx then
                    diagActive = false
                    ClaimSpot(rk, rx, rz, rf)
                    return rx, ry, rz, rf, rk
                end
                if diagActive then
                    st.turretDbg.probeTiles = st.turretDbg.probeTiles + 1
                    if diagReject == "blocked" then st.turretDbg.probeBlocked = st.turretDbg.probeBlocked + 1
                    elseif diagReject == "inacc" then st.turretDbg.probeInacc = st.turretDbg.probeInacc + 1
                    elseif diagReject == "overlap" then st.turretDbg.probeOverlap = st.turretDbg.probeOverlap + 1
                    elseif diagReject == "exit" then st.turretDbg.probeExit = st.turretDbg.probeExit + 1
                    elseif diagReject == "bounds" then st.turretDbg.probeBounds = st.turretDbg.probeBounds + 1
                    else st.turretDbg.probeTest = st.turretDbg.probeTest + 1 end
                end
            end
        end
        diagActive = false
        return nil
    end

    if preferFacing then
        local dirX, dirZ = GetFacingVector(preferFacing)
        local tx, ty, tz, f, key = TryTile(ux + dirX * stepSize, uz + dirZ * stepSize)
        if tx then ClaimSpot(key, tx, tz, f) return tx, ty, tz, f, key end
    end

    local ax, az = 1, 0
    if fdx then
        if mAbs(fdx) >= mAbs(fdz) then ax, az = (fdx >= 0 and 1 or -1), 0
        else ax, az = 0, (fdz >= 0 and 1 or -1) end
    end
    local px, pz = -az, ax

    local bestTX, bestTY, bestTZ, bestF, bestKey = nil, nil, nil, nil, nil
    local bestScore = -mHuge

    local function consider(gx, gz, withinPrefer)
        local tx, ty, tz, f, key = TryTile(gx, gz)
        if tx then
            if not fdx or not withinPrefer then ClaimSpot(key, tx, tz, f) return tx, ty, tz, f, key end
            -- cover depth minus how far toward the enemy it sits, with a mild
            -- distance penalty so the builder still prefers close
            local ok, cover = HasExitPath(tx, tz, {})
            if not ok then cover = maxRing end
            local proj = (tx - ux) * fdx + (tz - uz) * fdz
            local dist = math.sqrt((tx - ux) * (tx - ux) + (tz - uz) * (tz - uz))
            local score = cover * 96 - proj - dist * 0.5
            if score > bestScore then
                bestScore = score
                bestTX, bestTY, bestTZ, bestF, bestKey = tx, ty, tz, f, key
            end
        end
        return nil
    end

    for lat = 0, preferRing do
        local latOff = lat
        for s = 1, (lat == 0 and 1 or 2) do
            if s == 2 then latOff = -lat end
            for along = -preferRing, preferRing do
                local gx = gridStartX + (ax * along + px * latOff) * stepSize
                local gz = gridStartZ + (az * along + pz * latOff) * stepSize
                local r1, r2, r3, r4, r5 = consider(gx, gz, true)
                if r1 then return r1, r2, r3, r4, r5 end
            end
        end
    end
    if bestTX then ClaimSpot(bestKey, bestTX, bestTZ, bestF) return bestTX, bestTY, bestTZ, bestF, bestKey end

    -- Tight mode (eco/mex): only build close in; never send the builder
    -- sprinting to the far edge of the search ring.
    if tight then return nil end

    -- Phase 2: nothing buildable within the prefer square - extend outward.
    for lat = 0, maxRing do
        local latOff = lat
        for s = 1, (lat == 0 and 1 or 2) do
            if s == 2 then latOff = -lat end
            for along = -maxRing, maxRing do
                local gx = gridStartX + (ax * along + px * latOff) * stepSize
                local gz = gridStartZ + (az * along + pz * latOff) * stepSize
                local r1, r2, r3, r4, r5 = consider(gx, gz, false)
                if r1 then return r1, r2, r3, r4, r5 end
            end
        end
    end
    return nil
end


local spGetFeatureResources  = Spring.GetFeatureResources
local spGetFeatureResurrect  = Spring.GetFeatureResurrect

local function FindReclaimTarget(ux, uz, isStalling, radiusOverride)
    local reclaimRange = cfg.RECLAIM_RANGE * (st.mapLinearScale or 1)
    local radius = radiusOverride or (isStalling and (reclaimRange * 2) or reclaimRange)
    local feats = spGetFeaturesInCylinder(ux, uz, radius)
    if not feats or #feats == 0 then return nil end

    local minMetal = (st.metalIncome or 0) * cfg.RECLAIM_MIN_METAL_SECONDS
    local bestID, bestScore = nil, -mHuge
    local bestX, bestZ

    for i = 1, #feats do
        local fID = feats[i]
        local metal = spGetFeatureResources(fID)
        if metal and metal >= minMetal then
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx then
                local dx, dz = fx - ux, fz - uz
                local dist = math.sqrt(dx * dx + dz * dz) + 1
                local score = metal / (dist * dist * dist)
                if score > bestScore then
                    bestScore = score
                    bestID = fID
                    bestX, bestZ = fx, fz
                end
            end
        end
    end

    return bestID, bestX, bestZ
end

local function FindResurrectTarget(ux, uz, radius)
    local feats = spGetFeaturesInCylinder(ux, uz, radius)
    if not feats then return nil end
    local bestID, bestScore = nil, -mHuge
    local bestX, bestZ, bestMetal
    for i = 1, #feats do
        local fID = feats[i]
        local rezName = spGetFeatureResurrect(fID)
        if rezName and rezName ~= "" then
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx then
                local dx, dz = fx - ux, fz - uz
                local dist = math.sqrt(dx*dx + dz*dz) + 1
                -- prefer high-value wrecks, and only lightly weigh distance
                local metal = spGetFeatureResources(fID) or 0
                local score = metal / (1 + dist * 0.02)
                if score > bestScore then bestScore, bestID, bestX, bestZ, bestMetal = score, fID, fx, fz, metal end
            end
        end
    end
    return bestID, bestX, bestZ, bestMetal
end

local function FindEnemyReclaimTarget(ux, uz, radius, myTeamID, myAllyTeamID, mobileChaser)
    local nearby = spGetUnitsInCylinder(ux, uz, radius)
    if not nearby or #nearby == 0 then return nil end

    myAllyTeamID = myAllyTeamID or spGetMyAllyTeamID()

    local isChaser = mobileChaser ~= nil
    local minCost = isChaser and ((st.metalIncome or 0) * cfg.ENEMY_RECLAIM_MIN_COST_SECONDS) or 0
    local bestID, bestScore = nil, -mHuge
    local bestX, bestZ

    for i = 1, #nearby do
        local nID = nearby[i]
        local nAllyTeam = spGetUnitAllyTeam(nID)

        if nAllyTeam and nAllyTeam ~= myAllyTeamID then
            local nDefID = spGetUnitDefID(nID)
            local nDef = nDefID and UnitDefs[nDefID]

            if nDef and not (isChaser and nDef.canFly) then
                local metalCost = nDef.metalCost or 0

                if metalCost >= minCost then
                    local nx, _, nz = spGetUnitPosition(nID)
                    if nx then
                        -- skip enemies fleeing toward their base
                        local movingAway = false
                        if isChaser then
                            local vx, _, vz = spGetUnitVelocity(nID)
                            if vx then
                                local refX = st.baseCenterX or ux
                                local refZ = st.baseCenterZ or uz
                                local towardX = refX - nx
                                local towardZ = refZ - nz
                                movingAway = (vx * towardX + vz * towardZ < 0)
                            end
                        end

                        if not movingAway then
                            local dx, dz = nx - ux, nz - uz
                            local distSq = dx * dx + dz * dz

                            local hp, maxHp = spGetUnitHealth(nID)
                            local damageBonus = 0.25
                            if hp and maxHp and maxHp > 0 then
                                damageBonus = damageBonus + (1.0 - (hp / maxHp))
                            end

                            local score = (metalCost * damageBonus) / (distSq + 1)

                            if score > bestScore then
                                bestScore = score
                                bestID = nID
                                bestX, bestZ = nx, nz
                            end
                        end
                    end
                end
            end
        end
    end

    return bestID, bestX, bestZ
end

local aaUnitCache = {}

-- remember enemy structure locations so we
-- can queue a bomb order without having LOS
-- this would be cleared once we do get LOS
-- so the worst is a wasted bombing
local bomberCache = {}
local function IsBomberDef(uDefID)
    if not uDefID then return false end
    local cached = bomberCache[uDefID]
    if cached ~= nil then return cached end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.canFly and d.weapons then
        for i = 1, #d.weapons do
            local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and wDef.type and sLower(wDef.type) == "aircraftbomb" then result = true break end
        end
    end
    bomberCache[uDefID] = result
    return result
end
cfg.IsBomberDef = IsBomberDef

-- an aircraft whose only weapons are AA is a fighter
-- don't be distracted by it
local fighterCache = {}
local function IsFighterDef(uDefID)
    if fighterCache[uDefID] ~= nil then return fighterCache[uDefID] end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.canFly and d.weapons then
        local hasGround = false
        for i = 1, #d.weapons do
            if not cfg.IsAAWeapon(uDefID, d.weapons[i].weaponDef) then hasGround = true break end
        end
        result = not hasGround
    end
    fighterCache[uDefID] = result
    return result
end
cfg.IsFighterDef = IsFighterDef

local junoBomberCache = {}
local function IsJunoBomberDef(uDefID)
    if not uDefID then return false end
    local cached = junoBomberCache[uDefID]
    if cached ~= nil then return cached end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.canFly and d.weapons then
        for i = 1, #d.weapons do
            local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and wDef.customParams and wDef.customParams.junotype then
                result = true
                break
            end
        end
    end
    junoBomberCache[uDefID] = result
    return result
end
cfg.IsJunoBomberDef = IsJunoBomberDef

-- what the Juno pulse can actually kill, ignore everything else
local function IsJunoVulnerableDef(d)
    if not d then return false end
    if d.modCategories and d.modCategories.mine then return true end
    if IsScoutDef(d) then return true end
    if (d.radarDistance and d.radarDistance > 0) then return true end
    if (d.sonarDistance and d.sonarDistance > 0) then return true end
    if (d.radarDistanceJam and d.radarDistanceJam > 0) then return true end
    if d.stealth then return true end
    return false
end
cfg.IsJunoVulnerableDef = IsJunoVulnerableDef

local function IsAntiAirUnit(uDefID)
    if not uDefID then return false end
    local cached = aaUnitCache[uDefID]
    if cached ~= nil then return cached end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.weapons then
        for i = 1, #d.weapons do
            if cfg.IsAAWeapon(uDefID, d.weapons[i].weaponDef) then
                result = true
                break
            end
        end
    end
    aaUnitCache[uDefID] = result
    return result
end

-- attack range, AA-aware: maxWeaponRange includes AA guns, which would make
-- ground units kite at the wrong distance. Fighters keep full range.
local groundRangeCache = {}
local function GetGroundRange(uDefID)
    if not uDefID then return 0 end
    if groundRangeCache[uDefID] ~= nil then return groundRangeCache[uDefID] end
    local d = uDefID and UnitDefs[uDefID]
    local best = 0
    if d then
        if d.canFly then
            best = d.maxWeaponRange or 0
        elseif d.weapons then
            for i = 1, #d.weapons do
                local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
                if not cfg.IsAAWeapon(uDefID, d.weapons[i].weaponDef) and wDef then
                    if (wDef.range or 0) > best then best = wDef.range or 0 end
                end
            end
        end
    end
    groundRangeCache[uDefID] = best
    return best
end
cfg.GetGroundRange = GetGroundRange

function cfg.GetAAWeaponRange(uDefID)
    local perUnit
    if uDefID then
        perUnit = aaWeaponCache[uDefID]
        if not perUnit then
            perUnit = {}
            aaWeaponCache[uDefID] = perUnit
        end
    end
    if perUnit and perUnit.range ~= nil then return perUnit.range end
    local d = uDefID and UnitDefs[uDefID]
    local best = 0
    if d and d.weapons then
        for i = 1, #d.weapons do
            local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and cfg.IsAAWeapon(uDefID, d.weapons[i].weaponDef) then
                if (wDef.range or 0) > best then best = wDef.range or 0 end
            end
        end
    end
    if perUnit then perUnit.range = best end
    return best
end

function cfg.GetEngageRange(uDefID, targetDef)
    if targetDef and targetDef.canFly then
        local gr = cfg.GetGroundRange(uDefID)
        local ar = cfg.GetAAWeaponRange(uDefID)
        if ar > gr then return ar end
    end
    return cfg.GetGroundRange(uDefID)
end

-- Rough single-weapon DPS: a relative lethality estimate only
local function GetWeaponDPS(wDef)
    if not wDef then return 0 end
    local dm = wDef.damages
    local dmg = dm and (dm[0] or dm.default or 0) or 0
    local reload = wDef.reload or 1
    if reload <= 0 then reload = 1 end
    return (dmg / reload) * (wDef.salvoSize or 1) * (wDef.projectiles or 1)
end

-- Total DPS of a unit's ground-capable weapons, AA skipped
local unitDPSCache = {}
local function GetUnitDPS(defID)
    if not defID then return 0 end
    local cached = unitDPSCache[defID]
    if cached ~= nil then return cached end
    local d = UnitDefs[defID]
    local total = 0
    if d and d.weapons then
        for i = 1, #d.weapons do
            local wDef = SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef then
                local wType = wDef.type and sLower(wDef.type) or ""
                local wName = wDef.name and sLower(wDef.name) or ""
                local onlyCat = wDef.onlyTargetCategory and sLower(wDef.onlyTargetCategory) or ""
                local isAA = sFind(wName, "flak") or sFind(wType, "aa") or sFind(onlyCat, "vtol")
                if not isAA then total = total + GetWeaponDPS(wDef) end
            end
        end
    end
    unitDPSCache[defID] = total
    return total
end
cfg.GetUnitDPS = GetUnitDPS

local function GetEnemyUnitsInCylinder(x, z, radius)
    if Spring.ENEMY_UNITS then
        return spGetUnitsInCylinder(x, z, radius, Spring.ENEMY_UNITS)
    end
    return spGetUnitsInCylinder(x, z, radius)
end

local function FindBestClusterTarget(fromX, fromZ, searchRadius, aoeRadius, shooterDefID)
    local nearby = GetEnemyUnitsInCylinder(fromX, fromZ, searchRadius)
    if not nearby or #nearby == 0 then return nil end

    -- Structure-of-arrays to avoid hundreds of small tables.
    local eID, eX, eZ, eCost = {}, {}, {}, {}
    local enCount = 0
    -- ground non-AA units and bombers should ignore air
    -- AA-only fighters can't hit ground.
    -- ignore cheap scouts, fire at will would attack them anyways
    local shooterDef = shooterDefID and UnitDefs[shooterDefID]
    local skipAir = shooterDef and (
        (not shooterDef.canFly and not IsAntiAirUnit(shooterDefID))
        or (shooterDef.canFly and not IsFighterDef(shooterDefID))
    )
    local skipGround = shooterDef and shooterDef.canFly and IsFighterDef(shooterDefID)
    local skipGroundScout = shooterDef and not shooterDef.canFly
    -- Never treat our own/allied/gaia units as targets.
    local myTeamID = spGetMyTeamID()
    local gaiaID = spGetGaiaTeamID()

    for i = 1, #nearby do
        local tID = nearby[i]
        local tTeam = spGetUnitTeam(tID)
        if tTeam and tTeam ~= myTeamID and tTeam ~= gaiaID and not spAreTeamsAllied(myTeamID, tTeam) then
            local tDefID = spGetUnitDefID(tID)
            local tDef = tDefID and UnitDefs[tDefID]
            if tDef and not (skipAir and tDef.canFly)
                and not (skipGround and not tDef.canFly)
                and not (skipGroundScout and not tDef.canFly and IsScoutDef(tDef)) then
                local ex, _, ez = spGetUnitPosition(tID)
                if ex and ez then
                    enCount = enCount + 1
                    eID[enCount] = tID
                    eX[enCount] = ex
                    eZ[enCount] = ez
                    eCost[enCount] = tDef.metalCost or 50
                end
            end
        end
    end

    if enCount == 0 then return nil end
    
    if enCount == 1 then
        local x, z = eX[1], eZ[1]
        return x, spGetGroundHeight(x, z), z, eID[1], 1, eCost[1], false
    end

    if not aoeRadius then aoeRadius = cfg.AOE_DAMAGE_RADIUS end
    local AoESq = aoeRadius * aoeRadius
    local invHalfAoESq = 2 / AoESq

    local bestIdx, bestMetal, bestClusterSize = 1, 0, 0
    local bestCentroidX, bestCentroidZ = eX[1], eZ[1]

    for i = 1, enCount do
        local cx, cz = eX[i], eZ[i]
        local totalMetal = eCost[i]
        local clusterCount = 1
        local sumX, sumZ = cx, cz
        
        for j = 1, enCount do
            if j ~= i then
                local dx = eX[j] - cx
                local dx2 = dx * dx
                if dx2 < AoESq then
                    local dz = eZ[j] - cz
                    local dz2 = dz * dz
                    if dz2 < AoESq then
                        local dSq = dx2 + dz2
                        if dSq < AoESq then
                            clusterCount = clusterCount + 1
                            totalMetal = totalMetal + eCost[j] / (1 + dSq * invHalfAoESq)
                            sumX = sumX + eX[j]
                            sumZ = sumZ + eZ[j]
                        end
                    end
                end
            end
        end
        
        -- weigh by cost, not density, give a mild density bonus for AOE value
        local score = totalMetal * (1 + 0.1 * (clusterCount - 1))
        
        if score > bestMetal then
            bestMetal = score
            bestIdx = i
            bestClusterSize = clusterCount
            bestCentroidX = sumX / clusterCount
            bestCentroidZ = sumZ / clusterCount
        end
    end

    local groundAttack = bestClusterSize >= cfg.CLUSTER_THRESHOLD
    local cx, cz = bestCentroidX, bestCentroidZ
    if not groundAttack then
        cx = eX[bestIdx]
        cz = eZ[bestIdx]
    end
    
    local cy = spGetGroundHeight(cx, cz)
    return cx, cy, cz, eID[bestIdx], bestClusterSize, bestMetal, groundAttack
end

cfg.FindBombTargetFromMemory = function(fromX, fromZ)
    local bases = st.enemyBases
    if not bases then return nil end

    local bestScore, bestX, bestY, bestZ = 0, nil, nil, nil

    for _, b in pairs(bases) do
        if b.lastSeen and b.lastSeen > 0 then
            local dx, dz = b.x - fromX, b.z - fromZ
            local dSq = dx * dx + dz * dz
            local score = (b.cost or 100) / (1 + mSqrt(dSq) * 0.01)
            if b.isFactory then score = score * 1.25 end
            if score > bestScore then
                bestScore = score
                bestX, bestY, bestZ = b.x, b.y or 0, b.z
            end
        end
    end

    return bestX, bestY, bestZ
end


local function GetForwardTarget()
    if st.frontierX and st.frontierZ then return st.frontierX, st.frontierZ end
    if st.baseCenterX then
        local bestD, bX, bZ = mHuge, nil, nil
        for _, b in pairs(st.enemyBases) do
            if b.lastSeen then
                local dx, dz = b.x - st.baseCenterX, b.z - st.baseCenterZ
                local d = dx*dx + dz*dz
                if d < bestD then bestD, bX, bZ = d, b.x, b.z end
            end
        end
        if bX then return bX, bZ end
    end
    return nil, nil
end





local function ComputeStrategicPlan(frame)
    local mexInfo = GetCheapestMexInfo()
    local mexDef = mexInfo.def
    local mexExtract   = mexDef and mexDef.extractsMetal or 1.0
    local mexEnergyUpkeep = mexDef and mexDef.energyCost or 0

    local metalSurplus = (st.metalIncome or 0) - (st.metalPull or 0)      -- >0: earning > spending
    local energyDeficit = (st.energyPull or 0) - (st.energyIncome or 0)   -- >0: energy short

    -- How much of a new mex's metal can we actually put to use right now?
    local metalUseFactor
    if st.metalStalling then metalUseFactor = 1.5
    elseif metalSurplus < 0 then metalUseFactor = 1.0
    elseif metalSurplus > (st.metalIncome or 0) * 0.25 then metalUseFactor = 0.2
    else metalUseFactor = 0.6 end

    local n = mMax(1, st.mexUnitCount)
    local mexScore = mexExtract * (1.0 / (1.0 + 0.08 * n)) * metalUseFactor
    -- Penalize if we cannot even feed the mexes we already have
    if mexEnergyUpkeep > 0 and energyDeficit > 0 then
        mexScore = mexScore * ((st.energyIncome or 0) / mMax(1, energyDeficit + (st.energyIncome or 0)))
    end

    -- energy value
    local energyScore = 0.1
    if energyDeficit > 0 then
        energyScore = 1.0 + energyDeficit / mMax(1, st.energyIncome or 1)
    elseif st.currentEnergyStorage and st.currentEnergyStorage > 0 and st.currentEnergy < st.currentEnergyStorage * 0.35 then
        energyScore = 0.6
    end

    -- opportunity cost of inaction, a held army becomes more useless
    -- as the enemy techs up
    local ourTech = mMax(1, st.ourTech or 1)
    local enemyTech = mMax(ourTech, st.enemyTech or ourTech)
    local techPressure = mMin(6, enemyTech / ourTech)

    local armyValue = st.armyValue or 0
    local depreciation = armyValue * techPressure * cfg.ARMY_DEPRECIATION_RATE

    local tempo = 0
    for _, b in pairs(st.enemyBases) do
        if b.lastSeen then
            local bDefID = b.id and spGetUnitDefID(b.id)
            local bDef = bDefID and UnitDefs[bDefID]
            if bDef then
                tempo = tempo + (bDef.buildTime or 0)
            end
        end
    end

    local raiderThreat = (st.raiderCount or 0) * 5
    local myArmy = st.myCombatUnitCount or 0
    local armyReadiness = myArmy / mMax(cfg.ARMY_MIN_SIZE * 3, myArmy + cfg.ARMY_MIN_SIZE)
    local armyScore = (depreciation + tempo + raiderThreat) * armyReadiness
    if st.army.state == "attacking" then armyScore = armyScore * 1.5 end

    -- a real energy deficit must be fixed before any other spend (an army is
    -- worthless if its factories are stalled)
    local mode = "mex"
    if energyDeficit > (st.energyIncome or 0) * 0.5 then
        mode = "energy"
    elseif armyScore >= mexScore and armyScore >= energyScore and armyScore >= 1.0 then
        mode = "army"
    elseif energyScore >= mexScore and energyScore >= 0.6 then
        mode = "energy"
    end

    st.plan.frame = frame
    st.plan.mode = mode
    st.plan.mexScore = mexScore
    st.plan.energyScore = energyScore
    st.plan.armyScore = armyScore
    st.plan.metalSurplus = metalSurplus
    st.plan.energyDeficit = energyDeficit
end


-- stalling = demand exceeds production and the bank is nearly empty
cfg.IsResourceStalling = function(cur, pull, income)
    if (pull or 0) <= (income or 0) then return false end
    return (cur or 0) < mMax(50, (income or 0) * 2)
end

local function UpdateMacroState(myTeam, units)
    st.pendingCommittedMetal = 0

    if WG and WG['resource_spot_finder'] then
        st.metalSpots = WG['resource_spot_finder'].metalSpotsList or {}
    else
        st.metalSpots = {}
    end

    st.unclaimedMetalSpots = {}
    st.unclaimedMexCount = 0
    -- The occupancy scan is the most expensive part so only refresh it every other pass
    if st.frameNum % (cfg.CHECK_INTERVAL * 2) == 0 then
        if st.metalSpots and #st.metalSpots > 0 then
            for i = 1, #st.metalSpots do
                local spot = st.metalSpots[i]
                local isOccupied = false
                if spot.x and spot.z then
                    local nearby = spGetUnitsInCylinder(spot.x, spot.z, 80, myTeam)
                    if nearby then
                        for j = 1, #nearby do
                            local nDefID = spGetUnitDefID(nearby[j])
                            local nDef = nDefID and UnitDefs[nDefID]
                            if nDef and nDef.extractsMetal and nDef.extractsMetal > 0 then
                                isOccupied = true break
                            end
                        end
                    end
                end
                if not isOccupied then
                    st.unclaimedMexCount = st.unclaimedMexCount + 1
                    st.unclaimedMetalSpots[#st.unclaimedMetalSpots + 1] = {x = spot.x, z = spot.z}
                end
            end
        end
    end

    local okM, mCur, mStorage, mPull, mIncome = pcall(spGetTeamResources, myTeam, "metal")
    if okM then
        st.metalStalling = cfg.IsResourceStalling(mCur, mPull, mIncome)
    else mCur, mStorage, mPull, mIncome = 0, 0, 0, 0 st.metalStalling = true end
    st.metalIncome, st.metalPull, st.currentMetal, st.currentMetalStorage = mIncome or 0, mPull or 0, mCur or 0, mStorage or 0

    local okE, eCur, eStorage, ePull, eIncome = pcall(spGetTeamResources, myTeam, "energy")
    if okE then
        st.energyStalling = cfg.IsResourceStalling(eCur, ePull, eIncome)
    else eCur, eStorage, ePull, eIncome = 0, 0, 0, 0 st.energyStalling = true end
    st.energyIncome, st.energyPull, st.currentEnergy, st.currentEnergyStorage = eIncome or 0, ePull or 0, eCur or 0, eStorage or 0

    local growthFactor = st.metalPull > 0 and (st.metalIncome / st.metalPull) or 2.0
    st.economySaturated = (not st.metalStalling) and (not st.energyStalling) and st.currentMetalStorage > 0
        and (st.currentMetal / st.currentMetalStorage) > cfg.ECONOMY_SATURATION_RATIO and growthFactor > cfg.ECONOMY_INCOME_SLACK

    st.myFactories, st.factoryGuards, st.factoryTurrets = {}, {}, {}
    st.incompleteFactories, st.factoriesNeedingTurrets = {}, {}
    st.myCommanders = {}
    st.myCommanderCount = 0
    st.baseCenterX, st.baseCenterY, st.baseCenterZ, st.baseRadius, st.baseStructureCount = nil, nil, nil, 0, 0
    st.conUnitCount, st.mexUnitCount, st.combatUnitCount = 0, 0, 0
    st.advConCount = 0
    st.scoutUnitCount = 0
    st.supportGuardOwners.radar = {}
    st.supportGuardOwners.jammer = {}
    st.supportGuardOwners.aa = {}
    st.myCombatUnits, st.myCombatUnitCount = {}, 0
    st.activeMexBuilders, st.activeEnergyBuilders = 0, 0
    st.ourTech, st.armyValue = 0, 0
    st.myFactoriesCount, st.incompleteFactoryCount, st.factoriesNeedingTurretsCount = 0, 0, 0
    st.hasAdvancedFactory = false
    st.hasT2Lab = false
    st.myAntinukes, st.antinukeCount = {}, 0
    st.defenseCount = 0
    st.defenseGroundCount = 0
    st.defenseAACount = 0
    st.selfDingUnits, st.selfDingCount = {}, 0
    st.turretDbg.consWithTurret = 0

    st.pendingFactoryBlueprints = 0
    st.pendingAntinukeBlueprints = 0
    st.claimedMexList = {}
    for _, claim in pairs(st.claimedSpots) do
        if claim.isFactory and (st.frameNum - claim.frame) < 900 then
            st.pendingFactoryBlueprints = st.pendingFactoryBlueprints + 1
        elseif claim.isAntinuke and (st.frameNum - claim.frame) < 900 then
            st.pendingAntinukeBlueprints = st.pendingAntinukeBlueprints + 1
        elseif claim.isMex then
            st.claimedMexList[#st.claimedMexList + 1] = claim
        end
    end

    st.lazCount, st.jammerCount, st.radarCount = 0, 0, 0
    st.radarTowerCount = 0

    local structPos, structCnt, sumSX, sumSZ = {}, 0, 0, 0

    -- prune conTurretHomes entries whose turret/build order no longer exists
    local seenHomeKeys = {}

    for i = 1, #units do
        local uID = units[i]
        local d = UnitDefs[spGetUnitDefID(uID)]
        if d then
            local isCmd = d.customParams and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
            if isCmd or (d.name and sFind(sLower(d.name), "commander")) then
                st.myCommanderCount = st.myCommanderCount + 1
                st.myCommanders[st.myCommanderCount] = uID
            end

            if d.isFactory then
                st.myFactoriesCount = st.myFactoriesCount + 1
                st.myFactories[st.myFactoriesCount] = uID
                st.factoryGuards[uID] = 0
                st.factoryTurrets[uID] = 0

                local hp, maxHp = spGetUnitHealth(uID)
                if hp and maxHp and hp < maxHp then
                    st.incompleteFactoryCount = st.incompleteFactoryCount + 1
                    st.incompleteFactories[st.incompleteFactoryCount] = uID
                else
                    local techLevel = d.customParams and tonumber(d.customParams.techlevel) or 1
                    if techLevel >= 2 then
                        st.hasAdvancedFactory = true
                        if techLevel == 2 then
                            st.hasT2Lab = true
                        end
                    end
                end
            end

            if IsAntiNukeDef(spGetUnitDefID(uID)) then
                st.antinukeCount = st.antinukeCount + 1
                st.myAntinukes[st.antinukeCount] = uID
            end

            if IsDefenseDef(spGetUnitDefID(uID)) then
                st.defenseCount = st.defenseCount + 1
                if IsAAOnlyDef(spGetUnitDefID(uID)) then st.defenseAACount = st.defenseAACount + 1
                else st.defenseGroundCount = st.defenseGroundCount + 1 end
            end

            -- Track units mid self-destruct so allies can flee the blast.
            if d.speed and d.speed > 0 and Spring.GetUnitSelfDTime(uID) > 0 then
                local sx, _, sz = spGetUnitPosition(uID)
                if sx then
                    st.selfDingCount = st.selfDingCount + 1
                    st.selfDingUnits[st.selfDingCount] = { id = uID, x = sx, z = sz, blastRadius = cfg.GetSelfDBlastRadius(spGetUnitDefID(uID)) }
                end
            end

            if not d.speed or d.speed == 0 then
                local sx, _, sz = spGetUnitPosition(uID)
                if sx then
                    structCnt = structCnt + 1
                    structPos[structCnt] = { sx, sz }
                    sumSX, sumSZ = sumSX + sx, sumSZ + sz
                end
            end
        end
    end

    if structCnt > 0 then
        local cx, cz = sumSX / structCnt, sumSZ / structCnt
        local maxDistSq = 0
        for i = 1, structCnt do
            local dx, dz = structPos[i][1] - cx, structPos[i][2] - cz
            if dx*dx + dz*dz > maxDistSq then maxDistSq = dx*dx + dz*dz end
        end
        st.baseCenterX, st.baseCenterY, st.baseCenterZ, st.baseRadius, st.baseStructureCount = cx, spGetGroundHeight(cx, cz), cz, math.sqrt(maxDistSq), structCnt
    end

    for i = 1, #units do
        local uID = units[i]
        local d = UnitDefs[spGetUnitDefID(uID)]
        if d and not d.isFactory then
            if d.isBuilder and d.speed and d.speed > 0 then
                local cN = d.name and sLower(d.name) or ""
                local isCmdDef = (d.customParams and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)) or (sFind(cN, "commander") and true or false)
                local isLazDef = d.canResurrect or sFind(cN, "lazarus") or sFind(cN, "graverobber") or sFind(cN, "zagreus")
                local isTrapperDef = IsTrapper(d)
                if not isCmdDef and not isLazDef and not isTrapperDef then
                    st.conUnitCount = st.conUnitCount + 1
                    if (d.metalCost or 0) >= 250 then st.advConCount = st.advConCount + 1 end
                    -- Diagnostics: how many fielded cons can build a con turret.
                    local bc = st.buildCache[spGetUnitDefID(uID)]
                    if bc and bc.conTurrets and #bc.conTurrets > 0 then
                        st.turretDbg.consWithTurret = st.turretDbg.consWithTurret + 1
                    end
                end
                local cmds = spGetUnitCommands(uID, 10)
                local countedEco = false
                if cmds then
                    for c = 1, #cmds do
                        local cmdId = cmds[c].id
                        if cmdId == cfg.CMD_GUARD then
                            local target = cmds[c].params[1]
                            if target and st.factoryGuards[target] ~= nil then st.factoryGuards[target] = st.factoryGuards[target] + 1 end
                        elseif cmdId < 0 then
                            local bDef = UnitDefs[-cmdId]
                            if bDef then
                                if not countedEco then
                                    if bDef.extractsMetal and bDef.extractsMetal > 0 then st.activeMexBuilders = st.activeMexBuilders + 1 countedEco = true
                                    elseif (bDef.energyMake and bDef.energyMake > 0) or sFind(sLower(bDef.name or ""), "wind") or sFind(sLower(bDef.name or ""), "solar") or sFind(sLower(bDef.name or ""), "fusion") or sFind(sLower(bDef.name or ""), "geo") then
                                        st.activeEnergyBuilders = st.activeEnergyBuilders + 1 countedEco = true
                                    end
                                end
                                if bDef.isBuilder and (not bDef.speed or bDef.speed == 0) then
                                    local tx, tz = cmds[c].params[1], cmds[c].params[3]
                                    if tx and tz then
                                        local hk = mFloor(tx) .. "_" .. mFloor(tz)
                                        local homeF = st.conTurretHomes[hk]
                                        if homeF then
                                            seenHomeKeys[hk] = true
                                            st.factoryTurrets[homeF] = (st.factoryTurrets[homeF] or 0) + 1
                                        else
                                            local bestF, bestDist = nil, cfg.TURRET_SEARCH_RADIUS * cfg.TURRET_SEARCH_RADIUS
                                            for j = 1, st.myFactoriesCount do
                                                local fID = st.myFactories[j]
                                                local fx, _, fz = spGetUnitPosition(fID)
                                                if fx then
                                                    local dx, dz = fx - tx, fz - tz
                                                    if dx*dx + dz*dz < bestDist then bestDist, bestF = dx*dx + dz*dz, fID end
                                                end
                                            end
                                            if bestF then st.factoryTurrets[bestF] = (st.factoryTurrets[bestF] or 0) + 1 end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            elseif d.isBuilder and (not d.speed or d.speed == 0) then
                local tx, _, tz = spGetUnitPosition(uID)
                if tx then
                    local hk = mFloor(tx) .. "_" .. mFloor(tz)
                    local homeF = st.conTurretHomes[hk]
                    if homeF then
                        seenHomeKeys[hk] = true
                        st.factoryTurrets[homeF] = (st.factoryTurrets[homeF] or 0) + 1
                    else
                        local bestF, bestDist = nil, cfg.TURRET_SEARCH_RADIUS * cfg.TURRET_SEARCH_RADIUS
                        for j = 1, st.myFactoriesCount do
                            local fID = st.myFactories[j]
                            local fx, _, fz = spGetUnitPosition(fID)
                            if fx then
                                local dx, dz = fx - tx, fz - tz
                                if dx*dx + dz*dz < bestDist then bestDist, bestF = dx*dx + dz*dz, fID end
                            end
                        end
                        if bestF then st.factoryTurrets[bestF] = (st.factoryTurrets[bestF] or 0) + 1 end
                    end
                end
            else
                local name = sLower(d.name or "")
                local isLaz = d.canResurrect or sFind(name, "lazarus") or sFind(name, "graverobber") or sFind(name, "zagreus")
                local isJammer = (d.radarDistanceJam and d.radarDistanceJam > 0) or sFind(name, "jammer") or sFind(name, "jam")
                local isRadar = (d.radarDistance and d.radarDistance > 500 and not (d.weapons and #d.weapons > 0)) or sFind(name, "radar")

                if d.extractsMetal and d.extractsMetal > 0 then st.mexUnitCount = st.mexUnitCount + 1
                elseif isLaz then st.lazCount = st.lazCount + 1
                elseif isJammer then
                    st.jammerCount = st.jammerCount + 1
                    if d.speed and d.speed > 0 and not d.isBuilder then
                        local tg = st.supportTarget[uID]
                        if tg and spGetUnitDefID(tg) then st.supportGuardOwners.jammer[tg] = uID end
                    end
                elseif isRadar and d.speed and d.speed > 0 then
                    st.radarCount = st.radarCount + 1
                    if not d.isBuilder then
                        local tg = st.supportTarget[uID]
                        if tg and spGetUnitDefID(tg) then st.supportGuardOwners.radar[tg] = uID end
                    end
                elseif isRadar then
                    st.radarTowerCount = st.radarTowerCount + 1
                elseif (d.customParams and d.customParams.unitgroup == "aa") and d.speed and d.speed > 0 and not d.isBuilder then
                    -- mobile AA is support, not combat, so keep it out of
                    -- myCombatUnits so that it can't end up guarding another AA
                    local tg = st.supportTarget[uID]
                    if tg and spGetUnitDefID(tg) then st.supportGuardOwners.aa[tg] = uID end
                elseif IsScoutDef(d) then st.scoutUnitCount = st.scoutUnitCount + 1
                elseif not d.isBuilder and (d.speed and d.speed > 0) and (d.weapons and #d.weapons > 0) and not IsAntiNukeDef(spGetUnitDefID(uID)) then
                    st.combatUnitCount = st.combatUnitCount + 1
                    st.myCombatUnitCount = st.myCombatUnitCount + 1
                    st.myCombatUnits[st.myCombatUnitCount] = uID
                    local uCost = d.metalCost or 0
                    st.armyValue = st.armyValue + uCost
                    if uCost > st.ourTech then st.ourTech = uCost end
                end
            end
        end
    end

    for hk in pairs(st.conTurretHomes) do
        if not seenHomeKeys[hk] then st.conTurretHomes[hk] = nil end
    end

    for j = 1, st.myFactoriesCount do
        local fID = st.myFactories[j]
        local hp, maxHp = spGetUnitHealth(fID)
        -- ring the lab from 50% construction up
        if hp and maxHp and hp >= maxHp * 0.5 and (st.factoryTurrets[fID] or 0) < (FactoryTurretInfo(spGetUnitDefID(fID))) then
            st.factoriesNeedingTurretsCount = st.factoriesNeedingTurretsCount + 1
            st.factoriesNeedingTurrets[st.factoriesNeedingTurretsCount] = fID
        end
    end
    st.turretDbg.needTurrets = st.factoriesNeedingTurretsCount
end



-- Only LOS-verified units become targets, so no chasing radar ghosts.
-- This should catch the niche case where radar picks up enemy structures,
-- then the radar get's destroyed, and it creates a ghost
-- it will clear automatically whenever we do get LOS,
-- but I don't want to commit our entire army unless we are certain
-- that there is something there
local function UpdateThreat(myTeam, myUnits, frame)
    -- Cleanup old enemy bases
    local enemyBases = st.enemyBases
    local spIsPosInLos = Spring.IsPosInLos
    local spGetUnitHealth = Spring.GetUnitHealth
    local myAllyTeamID = spGetMyAllyTeamID()
    
    if enemyBases then
        for key, base in pairs(enemyBases) do
            -- If we have LOS on the structure, check if it's still there
            if spIsPosInLos(base.x, 0, base.z, myAllyTeamID) then
                local hp = base.id and spGetUnitHealth(base.id)
                if hp and hp > 0 then
                    base.lastSeen = frame
                    base.lastRadarSeen = frame
                else
                    enemyBases[key] = nil
                    st.intelVersion = st.intelVersion + 1
                end
            end
        end
    else
        enemyBases = {}
        st.enemyBases = enemyBases
    end

    -- enemy defenses keep coords + weapon range after LOS fades
    local enemyDefenses = st.enemyDefenses
    if not enemyDefenses then enemyDefenses = {} st.enemyDefenses = enemyDefenses end
    for dID, dEnt in pairs(enemyDefenses) do
        if spIsPosInLos(dEnt.x, 0, dEnt.z, myAllyTeamID) then
            local hp = spGetUnitHealth(dID)
            if hp and hp > 0 then
                dEnt.lastSeen = frame
            else
                enemyDefenses[dID] = nil
            end
        end
    end

    -- Init raiders and find enemy teams
    local raiders = {}
    local raiderCount = 0
    
    local gaiaTeam = spGetGaiaTeamID()
    local enemyTeams, eTeamCount = {}, 0
    local tList = spGetTeamList()

    for i = 1, #tList do
        local team = tList[i]
        if team ~= gaiaTeam and not spAreTeamsAllied(myTeam, team) then 
            eTeamCount = eTeamCount + 1 
            enemyTeams[eTeamCount] = team 
        end
    end

    -- Update scout sectors
    local refX, refZ = st.baseCenterX, st.baseCenterZ
    if not refX and st.myCommanders[1] then refX, _, refZ = spGetUnitPosition(st.myCommanders[1]) end
    refX, refZ = refX or 0, refZ or 0
    local scoutSectors = st.scoutSectors
    local floor = mFloor

    -- center in LOS counts as scouted, no need to walk in
    if scoutSectors then
        for key, sector in pairs(scoutSectors) do
            if spIsPosInLos(sector.x, 0, sector.z, myAllyTeamID) then
                sector.lastScouted = frame
            end
        end
    end

    -- Anything physically inside the sector guarantees that it is scouted
    for i = 1, #myUnits do
        local x, _, z = spGetUnitPosition(myUnits[i])
        if x then
            local key = (floor(x / 1024) * 1024) .. "_" .. (floor(z / 1024) * 1024)
            if scoutSectors and scoutSectors[key] then 
                scoutSectors[key].lastScouted = frame 
            end
        end
    end

    -- Scan enemy units
    local highestThreat, bestX, bestY, bestZ, bestDist, bestID = -1, nil, nil, nil, mHuge, nil
    local bestCost = 0
    -- scan from past the base perimeter outward: a raider chewing mexes at the
    -- edge triggers the same response as one at the core
    local scanR = (cfg.UNEASE_SCAN_BUFFER * st.mapLinearScale) + (cfg.UNEASE_WATCH_RING * st.mapLinearScale) + (st.baseRadius or 0)
    local SCAN_SQ = scanR * scanR
    local unitDefs = UnitDefs
    local spGetUnitTeam = Spring.GetUnitTeam
    local spGetUnitDefID = Spring.GetUnitDefID
    local spGetUnitPosition = Spring.GetUnitPosition
    local maxVisibleCost = 0 -- enemy tech ceiling, this feeds aggression
    -- metal-weighted: a juggernaut alarms more than scoutspam
    -- TODO: make this dps not metal based
    local unease = 0
    local uneaseSumX, uneaseSumZ, uneaseWeight = 0, 0, 0
    local enemyArmyValue = 0 -- total visible enemy mobile metal

    for eIdx = 1, eTeamCount do
        local eUnits = spGetTeamUnits(enemyTeams[eIdx])
        if eUnits then
            for i = 1, #eUnits do
                local uID = eUnits[i]
                local eDefID = spGetUnitDefID(uID)
                local eDef = eDefID and unitDefs[eDefID]
                if eDef then
                    local threat = 10
                    local customParams = eDef.customParams
                    local isCmd = customParams and (customParams.iscommander ~= nil or customParams.is_commander ~= nil)

                    if not isCmd and eDef.name then
                        isCmd = sFind(sLower(eDef.name), "commander", 1, true) ~= nil
                    end

                    -- any structure counts as their base
                    local isBaseWorthy = false
                    if isCmd then threat = 10000 isBaseWorthy = true
                    elseif eDef.isFactory then threat = 5000 isBaseWorthy = true
                    elseif eDef.isBuilding then
                        threat = 1000
                        isBaseWorthy = true
                    end

                    local ex, ey, ez = spGetUnitPosition(uID)
                    if ex then
                        local inLos = spIsPosInLos(ex, ey, ez, myAllyTeamID)
                        if inLos and not isCmd and eDef.metalCost and eDef.metalCost > maxVisibleCost then
                            maxVisibleCost = eDef.metalCost
                        end

                        if inLos and eDef.speed and eDef.speed > 0 and eDef.weapons and #eDef.weapons > 0 then
                            enemyArmyValue = enemyArmyValue + (eDef.metalCost or 50)
                        end

                        -- lastRadarSeen = radar blip, lastSeen = verified in LOS.
                        if isBaseWorthy then
                            local gx, gz = floor(ex / 500), floor(ez / 500)
                            local key = gx .. "_" .. gz
                            local base = enemyBases[key]
                            
                            if base then
                                base.x, base.y, base.z = ex, ey, ez
                                base.id = uID
                                base.defID = eDefID
                                base.cost = eDef.metalCost or 100
                                base.isFactory = eDef.isFactory or nil
                                if inLos then
                                    base.lastSeen = frame
                                    base.lastRadarSeen = frame
                                else
                                    base.lastRadarSeen = frame
                                end
                            else
                                enemyBases[key] = {
                                    id = uID, x = ex, y = ey, z = ez,
                                    defID = eDefID,
                                    cost = eDef.metalCost or 100,
                                    isFactory = eDef.isFactory or nil,
                                    lastSeen = inLos and frame or 0,
                                    lastRadarSeen = frame
                                }
                                -- New enemy base discovered, so let scouts re-aim.
                                st.intelVersion = st.intelVersion + 1
                            end

                            -- remember armed buildings with exact coords + range (LOS-only)
                            if inLos and eDef.maxWeaponRange and eDef.maxWeaponRange > 0 then
                                local gRange = cfg.GetGroundRange(eDefID)
                                local cur = enemyDefenses[uID]
                                if cur then
                                    cur.x, cur.z, cur.range = ex, ez, gRange
                                    cur.lastSeen = frame
                                else
                                    enemyDefenses[uID] = {
                                        defID = eDefID, x = ex, z = ez,
                                        range = gRange,
                                        cost = eDef.metalCost or 50,
                                        lastSeen = frame
                                    }
                                end
                            end
                        end

                        local dx = ex - refX
                        local dx2 = dx * dx

                        if dx2 < SCAN_SQ then
                            local dz = ez - refZ
                            local dz2 = dz * dz

                            if dz2 < SCAN_SQ then
                                local dist = dx2 + dz2
                                local eSpeed = eDef.speed

                                if dist < SCAN_SQ and eSpeed and eSpeed > 0 and inLos then
                                    raiderCount = raiderCount + 1
                                    raiders[raiderCount] = uID
                                    local uw = eDef.metalCost or 50
                                    unease = unease + uw
                                    uneaseSumX = uneaseSumX + ex * uw
                                    uneaseSumZ = uneaseSumZ + ez * uw
                                    uneaseWeight = uneaseWeight + uw
                                end

                                -- prime target needs true LOS too
                                if inLos and (threat > highestThreat or (threat == highestThreat and dist < bestDist)) then
                                    highestThreat = threat
                                    bestDist = dist
                                    bestX, bestY, bestZ = ex, ey, ez
                                    bestID = uID
                                    bestCost = eDef.metalCost or 50
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    st.raiders = raiders
    st.raiderCount = raiderCount
    st.unease = unease
    if uneaseWeight > 0 then
        st.uneaseX = uneaseSumX / uneaseWeight
        st.uneaseZ = uneaseSumZ / uneaseWeight
    else
        st.uneaseX, st.uneaseZ = nil, nil
    end

    -- this doesn't inhibit scaling to higher tiers,
    -- if our enemey is weak, but it does give
    -- us a fairly rough idea of how advanced the enemy is
    st.enemyTech = mMax(maxVisibleCost, (st.enemyTech or 0) * 0.995)

    -- same idea for total visible mobile combat metal
    st.enemyArmyValue = mMax(enemyArmyValue, (st.enemyArmyValue or 0) * 0.99)

    if bestID then
        st.cachedPrimeTargetPos = { bestX, bestY, bestZ }
        st.cachedPrimeTargetID = bestID
        st.cachedPrimeTargetCost = bestCost
    else
        st.cachedPrimeTargetPos = nil
        st.cachedPrimeTargetID = nil
        st.cachedPrimeTargetCost = nil
    end
end



local function PickArmyTarget(frame)
    local primeTargetID = st.cachedPrimeTargetID
    local primeTargetPos = st.cachedPrimeTargetPos
    
    if primeTargetID and primeTargetPos then
        local hp = spGetUnitHealth(primeTargetID)
        if hp and hp > 0 then
            local primeCost = st.cachedPrimeTargetCost or 0
            local commitThreshold = mMax((st.metalIncome or 0) * cfg.UNEASE_FLOOR_INCOME_SECONDS, (st.armyValue or 0) * cfg.UNEASE_ARMY_RATIO)
            if primeCost >= commitThreshold then
                return primeTargetPos[1], primeTargetPos[2], primeTargetPos[3], "prime"
            end
        end
    end

    local enemyBases = st.enemyBases
    if not enemyBases then return nil end

    local bestKey, bestBase, bestDist = nil, nil, mHuge
    local rx, rz = st.army.targetX or 0, st.army.targetZ or 0
    
    for key, base in pairs(enemyBases) do
        if base.lastSeen then
            local dx, dz = base.x - rx, base.z - rz
            local distSq = dx * dx + dz * dz
            
            if distSq < bestDist then 
                bestDist = distSq
                bestBase = base
                bestKey = key 
            end
        end
    end
    
    if bestBase then
        -- hit the known defense at this base first
        local dBest = nil
        if st.enemyDefenses then
            local bestD2 = (cfg.DEFENSE_TARGET_RADIUS * st.mapLinearScale) * (cfg.DEFENSE_TARGET_RADIUS * st.mapLinearScale)
            for dID, dEnt in pairs(st.enemyDefenses) do
                local dx, dz = dEnt.x - bestBase.x, dEnt.z - bestBase.z
                local d2 = dx*dx + dz*dz
                if d2 < bestD2 then bestD2, dBest = d2, dEnt end
            end
        end
        if dBest then
            return dBest.x, spGetGroundHeight(dBest.x, dBest.z), dBest.z,
                "defense_" .. mFloor(dBest.x) .. "_" .. mFloor(dBest.z)
        end
        return bestBase.x, bestBase.y, bestBase.z, bestKey
    end
    
    -- retaliate toward where a hidden shooter's shells come from
    if st.suspectedThreatX and (frame - st.suspectedThreatFrame) < 600 then
        return st.suspectedThreatX, spGetGroundHeight(st.suspectedThreatX, st.suspectedThreatZ), st.suspectedThreatZ, "fire_origin"
    end
    
    return nil
end


local function UpdateArmyCoordination(frame)
    local function GetAnyKnownTarget()
        return PickArmyTarget(frame)
    end

    if st.army.state == "attacking" then
        local tx, ty, tz, tkey = GetAnyKnownTarget()
        if tx then
            if tkey ~= st.army.targetKey then
                st.army.targetX, st.army.targetY, st.army.targetZ, st.army.targetKey = tx, ty, tz, tkey
            end
            if tkey == "prime" and st.cachedPrimeTargetID then
                local px, py, pz = spGetUnitPosition(st.cachedPrimeTargetID)
                if px then
                    st.army.targetX, st.army.targetY, st.army.targetZ = px, py, pz
                end
            end
        else
            st.army.state, st.army.stateFrame = "searching", frame
            st.army.targetX, st.army.targetY, st.army.targetZ, st.army.targetKey = nil, nil, nil, nil
        end
    elseif st.army.state == "searching" then
        local tx, ty, tz, tkey = GetAnyKnownTarget()
        if tx then
            st.army.state, st.army.targetX, st.army.targetY, st.army.targetZ, st.army.targetKey, st.army.stateFrame = "attacking", tx, ty, tz, tkey, frame
        elseif frame - st.army.stateFrame > cfg.ATTACK_SCOUT_DURATION then
            -- Cycle the state to force re-evaluation
            st.army.stateFrame = frame
            st.army.targetKey = "map_scout_" .. frame
        end
    end
end



local function SortDefenders(a, b)
    return a.eta < b.eta
end

local function UpdateDefenseCoordination(frame)
    if tClear then
        tClear(st.currentDefenders)
    else
        for k in pairs(st.currentDefenders) do st.currentDefenders[k] = nil end
    end

    local udbg = st.uneaseDbg
    if not st.unease or st.unease <= 0 then return end
    udbg.detected = udbg.detected + 1
    if not st.uneaseX then return end
    udbg.fired = udbg.fired + 1
    udbg.lastUnease = mFloor(st.unease)

    local cands = {}
    for i = 1, st.myCombatUnitCount do
        local uID = st.myCombatUnits[i]
        local ux, _, uz = spGetUnitPosition(uID)
        if ux then
            local ddx, ddz = ux - st.uneaseX, uz - st.uneaseZ
            local uDef = UnitDefs[spGetUnitDefID(uID)]
            local speed = uDef and uDef.speed or 0
            cands[#cands + 1] = { id = uID, eta = (speed > 0) and (mSqrt(ddx * ddx + ddz * ddz) / speed) or mHuge }
        end
    end
    if #cands == 0 then
        udbg.noCands = udbg.noCands + 1
        return
    end
    tSort(cands, SortDefenders)
    local budget = st.unease * cfg.UNEASE_OVERRUN_RATIO
    local spent, recalled = 0, 0
    for i = 1, #cands do
        if spent >= budget then break end
        local uID = cands[i].id
        -- performance thing, skip re-issuing if already heading to the threat.
        -- it's much cheaper to do this on our end, then send the network packet
        -- and wait for a response, there's also a concern that we'll be packet limited
        -- if we send too many packets
        local cs = spGetUnitCommands(uID, 1)
        local c1 = cs and cs[1]
        local already = (c1 and c1.id == cfg.CMD_MOVE and c1.params and c1.params[1] and c1.params[3]
            and ((st.uneaseX - c1.params[1]) * (st.uneaseX - c1.params[1]) + (st.uneaseZ - c1.params[3]) * (st.uneaseZ - c1.params[3]) < 160 * 160))
        if not already then
            spGiveOrderToUnit(uID, cfg.CMD_MOVE, { st.uneaseX, spGetGroundHeight(st.uneaseX, st.uneaseZ), st.uneaseZ }, {})
        end
        st.currentDefenders[uID] = true
        -- Already-heading units count toward the budget too
        local uDef = spGetUnitDefID(uID) and UnitDefs[spGetUnitDefID(uID)]
        spent = spent + ((uDef and uDef.metalCost) or 50)
        recalled = recalled + 1
        udbg.recalled = udbg.recalled + 1
    end
end

local function CountActiveScouts(frame)
    local count = 0
    for key, assign in pairs(st.scoutAssignments) do
        if frame - assign.frame < cfg.SCOUT_LOCK_TTL then count = count + 1 else st.scoutAssignments[key] = nil end
    end
    return count
end

local function AssignScoutOrder(unitID, frame)
    local ux, _, uz = spGetUnitPosition(unitID)
    if not ux then return false end
    for key, assign in pairs(st.scoutAssignments) do
        if assign.unitID == unitID or (frame - assign.frame) >= cfg.SCOUT_LOCK_TTL then st.scoutAssignments[key] = nil end
    end
    local activeScouts = CountActiveScouts(frame)
    if activeScouts >= st.scoutMaxActive then
        -- Scouts never fall back to guarding
        return false
    end

    local targetBase, bestScore = nil, -1
    
    -- prioritize bases further away that have been seen recently
    for key, base in pairs(st.enemyBases) do
        local dx = base.x - (st.baseCenterX or 0)
        local dz = base.z - (st.baseCenterZ or 0)
        local distSq = dx * dx + dz * dz
        local score = base.lastSeen * (distSq > 0 and math.sqrt(distSq) or 1)
        
        if score > bestScore then 
            bestScore = score 
            targetBase = base 
        end
    end
    if not targetBase and st.cachedPrimeTargetPos then targetBase = {x = st.cachedPrimeTargetPos[1], z = st.cachedPrimeTargetPos[3]} end

    if targetBase then
        -- get close enough to spot it, with an angle offset so scouts spread around it
        local angle = mAtan2(targetBase.z - (st.baseCenterZ or 0), targetBase.x - (st.baseCenterX or 0))
        local flankAngle = angle + (math.random() > 0.5 and 0.4 or -0.4)
        local dist = math.random(400, 1000)

        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
        local flankX = mMax(0, mMin(targetBase.x + mCos(flankAngle) * dist, mapX))
        local flankZ = mMax(0, mMin(targetBase.z + mSin(flankAngle) * dist, mapZ))
        flankX, flankZ = NudgeOutOfLava(flankX, flankZ, ux, uz)

        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { flankX, spGetGroundHeight(flankX, flankZ), flankZ }, {})
        st.scoutAssignments[tostring(unitID)] = { unitID = unitID, frame = frame }
        return true
    end

    -- Our enemy is probably most likely sitting in a corner
    -- if not we'll find out eventually
    local bestScore, bestKey, bestSector = -mHuge, nil, nil
    local frontierX, frontierZ = st.frontierX, st.frontierZ
    local mapCX, mapCZ = (Game.mapSizeX or 8192) * 0.5, (Game.mapSizeZ or 8192) * 0.5
    local maxCornerDist = math.sqrt(mapCX * mapCX + mapCZ * mapCZ)
    -- hard-penalise our half of the map, but we don't want to set this to 0,
    -- because someone could cheese that, but we do want to penalize our side
    -- a turtelling enemy on our side *could* end up never being found
    local homeX, homeZ = st.baseCenterX, st.baseCenterZ
    if not homeX and st.myCommanders[1] then homeX, _, homeZ = spGetUnitPosition(st.myCommanders[1]) end
    local axisX, axisZ
    if frontierX and frontierZ and homeX then
        axisX, axisZ = frontierX - homeX, frontierZ - homeZ
    elseif homeX then
        axisX, axisZ = mapCX - homeX, mapCZ - homeZ
    else
        axisX, axisZ = 0, 0
    end
    local axisLen = math.sqrt(axisX * axisX + axisZ * axisZ)
    if axisLen > 1e-6 then
        axisX, axisZ = axisX / axisLen, axisZ / axisLen
    else
        axisX, axisZ = 0, 0
    end
    for key, sector in pairs(st.scoutSectors) do
            if not st.scoutAssignments[key] then
                -- skip void/inaccessible sectors
                if not IsInaccessible(sector.x, sector.z) then
                    local dx, dz = sector.x - ux, sector.z - uz
                    local dist = math.sqrt(dx*dx + dz*dz) + 1
                    local staleness = frame - sector.lastScouted
                    local sdx, sdz = sector.x - mapCX, sector.z - mapCZ
                    local distFromCenter = math.sqrt(sdx*sdx + sdz*sdz)
                    -- up to 5x at the corners, linear to 1x at the center
                    local cornerBoost = 1 + mMax(0, 1 - distFromCenter / mMax(1, maxCornerDist)) * 4
                    local score = staleness * staleness * staleness * cornerBoost / (dist + 250)
                    if sdx * axisX + sdz * axisZ < 0 then
                        score = score * 0.02
                    end
                    if frontierX and frontierZ then
                        local fdx, fdz = sector.x - frontierX, sector.z - frontierZ
                        local fdist = math.sqrt(fdx*fdx + fdz*fdz)
                        score = score * (1 + mMax(0, 1 - fdist / 4000)) -- up to ~2x near the frontier
                    end
                if score > bestScore then bestScore, bestKey, bestSector = score, key, sector end
            end
        end
    end
    if bestSector then
        local tx, tz = mFloor(bestSector.x + math.random(-200, 200)), mFloor(bestSector.z + math.random(-200, 200))
        tx, tz = NudgeOutOfLava(tx, tz, ux, uz)
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { tx, spGetGroundHeight(tx, tz), tz }, {})
        st.scoutAssignments[bestKey] = { unitID = unitID, frame = frame }
        return true
    end
    return false
end

local SPREAD_HOLD_DIST = 160
local function GiveSpreadMove(unitID, ux, uz, tx, tz, minR, maxR, targetID)
    local sx, sz = GetFlankSpreadPos(unitID, tx, tz, minR, maxR, targetID)
    sx, sz = NudgeOutOfLava(sx, sz, ux, uz)
    local dx, dz = sx - ux, sz - uz
    if dx * dx + dz * dz >= SPREAD_HOLD_DIST * SPREAD_HOLD_DIST then
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
    end
end

-- no combat unit is ever left idle
local function PushFrontier(unitID, ux, uz)
    local fX, fZ = GetForwardTarget()
    if fX then
        local dir = mAtan2(fZ - uz, fX - ux)
        local lat = (UnitHash(unitID, 6) - 0.5) * 2.2
        local leg = 600 + UnitHash(unitID, 7) * 400
        local tx = ux + mCos(dir + lat) * leg
        local tz = uz + mSin(dir + lat) * leg
        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
        tx = mMax(80, mMin(tx, mapX - 80))
        tz = mMax(80, mMin(tz, mapZ - 80))
        tx, tz = NudgeOutOfLava(tx, tz, ux, uz)
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { tx, spGetGroundHeight(tx, tz), tz }, {})
    else
        -- no enemy known: push toward the far half of the map instead of roaming our side
        local homeX, homeZ = st.baseCenterX, st.baseCenterZ
        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
        local dirX, dirZ = mapX * 0.5 - (homeX or ux), mapZ * 0.5 - (homeZ or uz)
        local dirLen = math.sqrt(dirX * dirX + dirZ * dirZ)
        local px, pz = ux, uz
        if dirLen > 1e-6 then
            dirX, dirZ = dirX / dirLen, dirZ / dirLen
            local lat = (UnitHash(unitID, 6) - 0.5) * 1.6
            local leg = 700 + UnitHash(unitID, 7) * 500
            local dir = mAtan2(dirZ, dirX)
            px = ux + mCos(dir + lat) * leg
            pz = uz + mSin(dir + lat) * leg
        else
            local sx, sz = GetSpreadPos(unitID, ux, uz, 400, 1200)
            px, pz = sx, sz
        end
        px = mMax(80, mMin(px, mapX - 80))
        pz = mMax(80, mMin(pz, mapZ - 80))
        px, pz = NudgeOutOfLava(px, pz, ux, uz)
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
    end
end
-- Very important function
-- Handles all of the unit orders and commands
-- Nightmare to go thorugh
local function ProcessUnitOrders(unitID, frame)
    -- Lua 5.1 caps us to 60 upvalues :(
    -- So we have to redeclare them here
    local spGetUnitDefID       = Spring.GetUnitDefID
    local spGetUnitCommands    = Spring.GetUnitCommands
    local spGiveOrderToUnit    = Spring.GiveOrderToUnit
    local spGetFactoryCommands = Spring.GetFactoryCommands
    local spGetUnitPosition    = Spring.GetUnitPosition
    local spGetGroundHeight    = Spring.GetGroundHeight
    local spGetMyTeamID        = Spring.GetMyTeamID
    local spGetUnitHealth      = Spring.GetUnitHealth
    local spGetUnitTeam        = Spring.GetUnitTeam
    local spAreTeamsAllied     = Spring.AreTeamsAllied
    local spGetGaiaTeamID      = Spring.GetGaiaTeamID
    local spGetUnitVelocity    = Spring.GetUnitVelocity
    local mMax  = math.max
    local mMin  = math.min
    local mHuge = math.huge
    local mCos  = math.cos
    local mSin  = math.sin
    local mAbs  = math.abs
    local CMD_STOP       = cfg.CMD_STOP
    local CMD_WAIT       = cfg.CMD_WAIT
    local CMD_CLOAK      = cfg.CMD_CLOAK
    local CMD_DGUN       = cfg.CMD_DGUN
    local CMD_RESURRECT  = cfg.CMD_RESURRECT
    local CMD_FIRE_STATE = cfg.CMD_FIRE_STATE
    local CMD_MOVE_STATE = cfg.CMD_MOVE_STATE

    local uDefID = spGetUnitDefID(unitID)
    local uDef = uDefID and UnitDefs[uDefID]
    if not uDef then return end

    local name = uDef.name and sLower(uDef.name) or ""

    local puCmd = spGetUnitCommands(unitID, 1)
    local puC = puCmd and puCmd[1]
    if puC and puC.id == cfg.CMD_ATTACK and not uDef.canFly then
        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
        if st.attackDbg then
            st.attackDbg.groundCleared = st.attackDbg.groundCleared + 1
            st.attackDbg.lastGroundDef = uDef.name
        end
    end
    
    local hasWind = (Game.windMax or 0) > 0 -- windless maps fall back to solar

    local isTrapperUnit = cfg.IsTrapper(uDef)

    if uDef.isFactory then
        local isStalling = st.metalStalling or st.energyStalling
        -- we need cons to get out of a stall
        -- let's not make any if we have a healthy amount and we're stalling
        local wantConRecovery = isStalling and (
            st.conUnitCount < 2
            or (st.metalStalling and st.unclaimedMexCount > 0 and st.conUnitCount < 8)
            or (st.energyStalling and st.conUnitCount < 4)
        )
        if isStalling and not wantConRecovery then
            if not st.factoryWaitState[unitID] then
                spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
                st.factoryWaitState[unitID] = true
            end
            return
        end
        if st.factoryWaitState[unitID] then
            spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
            st.factoryWaitState[unitID] = nil
        end

        if spGetFactoryCommands then
            local factoryCmds = spGetFactoryCommands(unitID, -1)
            if factoryCmds and #factoryCmds > 0 then return end
        else
            local currentCmds = spGetUnitCommands(unitID, -1)
            if currentCmds and #currentCmds > 0 then return end
        end

        if (frame - (st.lastFactoryOrderFrame[unitID] or -30)) < 30 then return end

        if NeedsOrders(unitID, true, false, false) then
            local cache = GetBuildCache(uDefID)
            local choice = nil
            local realConBots = mMax(0, st.conUnitCount)

            -- while stalled the only unit worth queuing is a constructor
            if isStalling and #cache.cons > 0 then
                local conID = PickPreferAir(cache.cons, false)
                if conID then
                    spGiveOrderToUnit(unitID, -conID, {}, {})
                    st.conUnitCount = st.conUnitCount + 1
                    st.lastFactoryOrderFrame[unitID] = frame
                    return
                end
            end

            -- cap defenders so the factory doesn't only make fighters
            local targetDefenders = 4
            if st.raiderCount > 0 then targetDefenders = mMin(10, mMax(6, st.raiderCount * 2)) end

            -- get our scouts out fast, until we can find a better way to recognize enemy bases
            -- that doesn't force us to make a scout ASAP
            -- TODO: This
            if not choice and st.scoutUnitCount == 0 and #cache.scouts > 0 then
                local cheapestScout, cheapestCost = nil, mHuge
                for i = 1, #cache.scouts do
                    local sID = cache.scouts[i]
                    local sCost = UnitDefs[sID] and UnitDefs[sID].metalCost or 0
                    if CanAffordBuild(sID, true) and sCost < cheapestCost then
                        cheapestCost, cheapestScout = sCost, sID
                    end
                end
                if cheapestScout then
                    choice = cheapestScout
                    st.scoutUnitCount = st.scoutUnitCount + 1
                end
            end

            if not choice and st.combatUnitCount < targetDefenders then
                local cheapestDef = GetCheapestMobileDefense(cache)
                if cheapestDef and CanAffordBuild(cheapestDef, true) then
                    choice = cheapestDef
                    st.combatUnitCount = st.combatUnitCount + 1
                end
            end

            local dynamicLazLimit = math.floor(st.combatUnitCount / 80) + math.floor(st.metalIncome / 400)
            local dynamicRadarLimit = st.myFactoriesCount + math.floor(st.baseRadius / 600)

            local totalActiveProjects = st.incompleteFactoryCount + st.pendingFactoryBlueprints + st.unclaimedMexCount
            local maxCons = st.myFactoriesCount * cfg.CONS_PER_FACTORY + cfg.CONS_BASE
            local needMoreCons = false
            
            if realConBots < maxCons then
                if realConBots == 0 then needMoreCons = true
                elseif st.metalStalling and st.unclaimedMexCount > 0 and realConBots < (st.unclaimedMexCount + 1) then needMoreCons = true
                elseif st.energyStalling and realConBots < 3 then needMoreCons = true
                elseif totalActiveProjects > 0 and realConBots < (totalActiveProjects * 2) then needMoreCons = true
                elseif st.economySaturated then needMoreCons = true end
            end

            -- we need t2 cons, we don't care about if we have a bunch of t1 cons
            local advancedConID = nil
            for i = 1, #cache.cons do
                local cDef = UnitDefs[cache.cons[i]]
                if cDef and (cDef.metalCost or 0) >= 250 then advancedConID = cache.cons[i] break end
            end
            local needAdvancedCon = (advancedConID ~= nil)
                and (st.advConCount or 0) < 1
                and (st.metalIncome or 0) >= 40
                and not st.metalStalling

            if not choice and (needMoreCons or realConBots < 2 or needAdvancedCon) and #cache.cons > 0 then
                local useAdvanced = false
                if #cache.cons > 1 and st.metalIncome > 15 and realConBots >= 4 and not st.metalStalling and math.random() < 0.5 then
                    useAdvanced = true
                end
                
                if needAdvancedCon and advancedConID then
                    choice = advancedConID
                elseif useAdvanced then
                    choice = cache.cons[#cache.cons]
                else
                    choice = PickPreferAir(cache.cons, false)
                end
                if choice then
                    st.conUnitCount = st.conUnitCount + 1
                    local cDef = UnitDefs[choice]
                    if cDef and (cDef.metalCost or 0) >= 250 then st.advConCount = st.advConCount + 1 end
                end
            end

            if not choice and #cache.scouts > 0 then
                local targetScouts = mMin(4, mMax(2, cfg.SCOUTS_PER_FACTORY * st.myFactoriesCount))
                if st.scoutUnitCount < targetScouts then
                    local cheapestScout, cheapestCost = nil, mHuge
                    for i = 1, #cache.scouts do
                        local sID = cache.scouts[i]
                        local sCost = UnitDefs[sID] and UnitDefs[sID].metalCost or 0
                        if CanAffordBuild(sID, true) and sCost < cheapestCost then
                            cheapestCost, cheapestScout = sCost, sID
                        end
                    end
                    if cheapestScout then
                        choice = cheapestScout
                        st.scoutUnitCount = st.scoutUnitCount + 1
                    end
                end
            end

            if not choice and realConBots >= 3 then
                if #cache.jammers > 0 and not st.metalStalling and not st.energyStalling and math.random() < 0.05 then
                    choice = cache.jammers[1] st.jammerCount = st.jammerCount + 1
                elseif st.radarCount < dynamicRadarLimit and #cache.radars > 0 and not st.metalStalling and not st.energyStalling then
                    choice = cache.radars[1] st.radarCount = st.radarCount + 1
                elseif st.combatUnitCount >= 15 and st.lazCount < dynamicLazLimit and #cache.laz > 0 and math.random() < 0.15 then
                    choice = cache.laz[1] st.lazCount = st.lazCount + 1
                elseif #cache.trappers > 0 and st.combatUnitCount > 20 and math.random() < 0.05 then
                    choice = cache.trappers[1]
                end
            end

            if not choice and (#cache.mobile > 0 or #cache.artillery > 0) then
                local affordable = {}
                -- artillery bias
                if st.combatUnitCount < 10 and #cache.artillery > 0 and math.random() < 0.3 then
                    for i = 1, #cache.artillery do
                        local mID = cache.artillery[i]
                        if cfg.CanAffordCombatUnit(mID) then
                            tInsert(affordable, mID)
                        end
                    end
                end

                if #affordable == 0 then
                    local pool = cache.mobile
                    if #cache.artillery > 0 then
                        pool = {}
                        for i = 1, #cache.mobile do pool[#pool + 1] = cache.mobile[i] end
                        for i = 1, #cache.artillery do pool[#pool + 1] = cache.artillery[i] end
                    end
                    for i = 1, #pool do
                        local mID = pool[i]
                        if cfg.CanAffordCombatUnit(mID) then
                            tInsert(affordable, mID)
                        end
                    end
                end

                if #affordable > 0 then
                    -- cost-weighted random pick, capped at UNIT_PICK_COST_CAP_SECONDS
                    -- of income so the priciest unit doesn't dwarf all picks
                    local pickCostCap = (st.metalIncome or 0) * cfg.UNIT_PICK_COST_CAP_SECONDS
                    local totalWeight = 0
                    for i = 1, #affordable do
                        local ac = UnitDefs[affordable[i]] and UnitDefs[affordable[i]].metalCost or 0
                        totalWeight = totalWeight + math.sqrt(mMin(ac, pickCostCap) + 1)
                    end
                    local roll = math.random() * totalWeight
                    choice = affordable[#affordable]
                    for i = 1, #affordable do
                        local ac = UnitDefs[affordable[i]] and UnitDefs[affordable[i]].metalCost or 0
                        roll = roll - math.sqrt(mMin(ac, pickCostCap) + 1)
                        if roll <= 0 then choice = affordable[i] break end
                    end
                else
                    -- nothing affordable: keep the factory moving anyway
                    local pool = cache.mobile
                    if #cache.artillery > 0 then
                        pool = {}
                        for i = 1, #cache.mobile do pool[#pool + 1] = cache.mobile[i] end
                        for i = 1, #cache.artillery do pool[#pool + 1] = cache.artillery[i] end
                    end
                    choice = pool[math.random(#pool)]
                end
            end

            if not choice and #cache.cons > 0 then
                choice = PickPreferAir(cache.cons, true)
                st.conUnitCount = st.conUnitCount + 1
            end

            if choice then
                spGiveOrderToUnit(unitID, -choice, {}, {})
                st.lastFactoryOrderFrame[unitID] = frame
            end
        end

    elseif uDef.isBuilder and not uDef.isFactory then
        local ux, uy, uz = spGetUnitPosition(unitID)
        if not ux then return end

        if isTrapperUnit then
            local currentCmds = spGetUnitCommands(unitID, 1)
            local curCmd = currentCmds and currentCmds[1]
            local curCmdId = curCmd and curCmd.id
            if curCmdId and curCmdId < 0 then return end

            local mineDefID = nil
            local bestMineCost = -1
            if uDef.buildOptions then
                for i = 1, #uDef.buildOptions do
                    local optID = uDef.buildOptions[i]
                    local optDef = UnitDefs[optID]
                    if optDef then
                        local optsName = sLower(optDef.name or "")
                        if sFind(optsName, "mine") then
                            local cost = optDef.metalCost or 0
                            if cost > bestMineCost then bestMineCost = cost mineDefID = optID end
                        end
                    end
                end
            end

            if mineDefID then
                -- face the enemy: nearest known base, else map centre (inline for the upvalue cap)
                local fX, fZ = st.frontierX, st.frontierZ
                if not fX then
                    local bestD, bX, bZ = 1e18, nil, nil
                    local refX, refZ = st.baseCenterX or ux, st.baseCenterZ or uz
                    for _, b in pairs(st.enemyBases) do
                        if b.lastSeen then
                            local dx, dz = b.x - refX, b.z - refZ
                            local d = dx*dx + dz*dz
                            if d < bestD then bestD, bX, bZ = d, b.x, b.z end
                        end
                    end
                    if bX then fX, fZ = bX, bZ
                    else fX, fZ = (Game.mapSizeX or 8192) * 0.5, (Game.mapSizeZ or 8192) * 0.5 end
                end

                -- roll a new mine spot only when this unit has no cached one as
                -- re-rolling every poll would re-aim before it ever arrived
                local tgt = trapperTargets[unitID]
                if not tgt then
                    local targetX, targetZ = ux, uz
                    if st.baseCenterX and st.baseRadius > 100 then
                        local baseAngle = math.atan2(fZ - st.baseCenterZ, fX - st.baseCenterX)
                        local angle = baseAngle + (math.random() - 0.5) * math.pi
                        local minDist = 800 -- at least 800 out, up to ~1.5x base radius
                        local maxDist = mMax(minDist + 400, st.baseRadius * 1.5)
                        local dist = math.random(minDist, maxDist)

                        targetX = mMax(100, mMin(st.baseCenterX + mCos(angle) * dist, (Game.mapSizeX or 8192) - 100))
                        targetZ = mMax(100, mMin(st.baseCenterZ + mSin(angle) * dist, (Game.mapSizeZ or 8192) - 100))
                    elseif st.myFactoriesCount > 0 then
                        local facID = st.myFactories[math.random(st.myFactoriesCount)]
                        local fx, _, fz = spGetUnitPosition(facID)
                        if fx then
                            local baseAngle = math.atan2(fZ - fz, fX - fx)
                            local angle = baseAngle + (math.random() - 0.5) * math.pi
                            local dist = math.random(200, 500)
                            targetX = mMax(100, mMin(fx + mCos(angle) * dist, (Game.mapSizeX or 8192) - 100))
                            targetZ = mMax(100, mMin(fz + mSin(angle) * dist, (Game.mapSizeZ or 8192) - 100))
                        end
                    elseif st.myCommanderCount > 0 then
                        local comID = st.myCommanders[1]
                        local cx, _, cz = spGetUnitPosition(comID)
                        if cx then
                            targetX = mMax(100, mMin(cx + math.random(-300, 300), (Game.mapSizeX or 8192) - 100))
                            targetZ = mMax(100, mMin(cz + math.random(-300, 300), (Game.mapSizeZ or 8192) - 100))
                        end
                    end
                    tgt = { x = targetX, z = targetZ }
                    trapperTargets[unitID] = tgt
                end
                local targetX, targetZ = tgt.x, tgt.z

                local dx, dz = targetX - ux, targetZ - uz
                local distSq = dx * dx + dz * dz
                if distSq > 150 * 150 then
                    if curCmdId ~= cfg.CMD_MOVE then
                        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { targetX, spGetGroundHeight(targetX, targetZ), targetZ }, {})
                    end
                else
                    if CanAffordBuild(mineDefID, true) then
                        local tx, ty, tz, facing, key = FindBuildSpot(targetX, targetZ, mineDefID, 64, unitID)
                        if tx then
                            st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = 32*32, isFactory = false, isAirFactory = false, facing = facing, defID = mineDefID, isMex = false }
                            st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[mineDefID].metalCost or 0)
                            spGiveOrderToUnit(unitID, -mineDefID, { tx, ty, tz, facing }, {})
                            trapperTargets[unitID] = nil
                        else
                            -- no buildable tile near the committed spot: re-roll next poll
                            trapperTargets[unitID] = nil
                            if curCmdId ~= 0 and curCmdId ~= nil then spGiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
                        end
                    end
                end
            else
                PushFrontier(unitID, ux, uz)
            end
            return 
        end

        local isCommander = uDef.customParams and (uDef.customParams.iscommander ~= nil or uDef.customParams.is_commander ~= nil) or (uDef.name and sFind(sLower(uDef.name), "commander"))
        if isCommander then
            local myTeamID = spGetMyTeamID()

            -- any damage means that our commander is too far up or exposed
            -- this would also catch hidden attackers
            local hp, maxHp = spGetUnitHealth(unitID)
            local wounded = (hp and maxHp and maxHp > 0) and (hp < maxHp - 0.5)

            local csts = Spring.GetUnitStates(unitID)
            local isCloaked = csts and csts.cloak

            local dgunRange = 0
            local dgunEnergyCost = 0
            if uDef.weapons then
                for i = 1, #uDef.weapons do
                    local wDef = uDef.weapons[i].weaponDef and WeaponDefs[uDef.weapons[i].weaponDef]
                    if wDef and (wDef.manualFire or wDef.commandFire) then
                        dgunRange = wDef.range or 250
                        dgunEnergyCost = wDef.energyCost or wDef.energyPerShot or 0
                        break
                    end
                end
            end
            if dgunRange == 0 then dgunRange = 256 end
            local dgunRangeSq = (dgunRange * 0.8) * (dgunRange * 0.8)

            -- track nearby mobile enemies so the commander can flee efficiently
            local nearby = spGetUnitsInCylinder(ux, uz, cfg.COMMANDER_SCAN_RADIUS)
            local dgunTarget = nil
            local threatX, threatZ, threatCount = 0, 0, 0
            if nearby then
                for i = 1, #nearby do
                    local nID = nearby[i]
                    local nTeam = spGetUnitTeam(nID)
                    if nTeam and nTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, nTeam) then
                        local nDef = spGetUnitDefID(nID) and UnitDefs[spGetUnitDefID(nID)]
                        if nDef and not nDef.isBuilding then
                            local nx, _, nz = spGetUnitPosition(nID)
                            if nx then
                                local dist = (nx-ux)*(nx-ux) + (nz-uz)*(nz-uz)
                                threatX, threatZ, threatCount = threatX + nx, threatZ + nz, threatCount + 1
                                if dist < dgunRangeSq then dgunTarget = nID end
                            end
                        end
                    end
                end
            end

            -- The dgun only fires because an enemy is on top of us
            -- TODO: Work further on dgun logic
            local curEnergy = Spring.GetTeamResources(myTeamID, "energy")
            if dgunTarget and dgunEnergyCost > 0 and curEnergy and curEnergy >= dgunEnergyCost then
                if isCloaked then
                    Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {0}, {})
                end
                spGiveOrderToUnit(unitID, CMD_DGUN, { dgunTarget }, {})
                return
            end

            -- retreat when wounded or enemies are close, and
            -- fall back towards base so that it stops once home
            if wounded or threatCount > 0 then
                if threatCount > 0 then
                    if not isCloaked then
                        Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {1}, {})
                    end
                elseif isCloaked then
                    Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {0}, {})
                end
                local fx, fz = nil, nil
                if threatCount > 0 then
                    local avgEX, avgEZ = threatX / threatCount, threatZ / threatCount
                    local dx, dz = ux - avgEX, uz - avgEZ
                    local len = math.sqrt(dx*dx + dz*dz)
                    if len > 0.1 then
                        fx, fz = ux + (dx / len) * cfg.COMMANDER_RETREAT_DIST, uz + (dz / len) * cfg.COMMANDER_RETREAT_DIST
                    end
                end
                if not fx and st.baseCenterX then
                    local dx, dz = st.baseCenterX - ux, st.baseCenterZ - uz
                    local len = math.sqrt(dx*dx + dz*dz)
                    if len > 0.1 then
                        fx, fz = ux + (dx / len) * cfg.COMMANDER_RETREAT_DIST, uz + (dz / len) * cfg.COMMANDER_RETREAT_DIST
                    end
                end
                if fx then
                    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    fx = mMax(100, mMin(fx, mapX - 100))
                    fz = mMax(100, mMin(fz, mapZ - 100))
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { fx, spGetGroundHeight(fx, fz), fz }, {})
                end
                return
            end

            if isCloaked then
                Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {0}, {})
            end
        end
        local isGraverobber = uDef.canResurrect or (uDef.name and (sFind(sLower(uDef.name), "graverobber") or sFind(sLower(uDef.name), "lazarus") or sFind(sLower(uDef.name), "zagreus")))
        if isGraverobber then
            local gEnemyUnit = FindEnemyReclaimTarget(ux, uz, (cfg.ENEMY_RECLAIM_CHASE_RANGE * st.mapLinearScale) or 1000, nil, nil, true)
            if gEnemyUnit then
                local gcmds = spGetUnitCommands(unitID, 1)
                if not gcmds or #gcmds == 0 or gcmds[1].id ~= cfg.CMD_RECLAIM or gcmds[1].params[1] ~= gEnemyUnit then
                    spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { gEnemyUnit }, {})
                end
                return
            end

            if NeedsOrders(unitID, false, false, true) then
                local buildDist = uDef.buildDistance or 200
                local buildDistSq = buildDist * buildDist
                local myTeamID2 = spGetMyTeamID()

                local cmdrToHeal, cmdrDist = nil, mHuge
                for k = 1, st.myCommanderCount do
                    local cID = st.myCommanders[k]
                    local chp, cmax = spGetUnitHealth(cID)
                    if chp and cmax and chp < cmax then
                        local cx, _, cz = spGetUnitPosition(cID)
                        if cx then
                            local dist = (cx-ux)*(cx-ux) + (cz-uz)*(cz-uz)
                            if dist < cmdrDist then cmdrDist, cmdrToHeal = dist, cID end
                        end
                    end
                end
                if cmdrToHeal then
                    if cmdrDist < buildDistSq then spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { cmdrToHeal }, {})
                    else spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { spGetUnitPosition(cmdrToHeal) }, {}) end
                    return
                end

                local nearby = spGetUnitsInCylinder(ux, uz, 800)
                local unitToHeal, uDist, bestHealScore = nil, mHuge, -mHuge
                if nearby then
                    for k = 1, #nearby do
                        local nID = nearby[k]
                        if nID ~= unitID and spGetUnitTeam(nID) == myTeamID2 then
                            local nDef = spGetUnitDefID(nID) and UnitDefs[spGetUnitDefID(nID)]
                            local hp, maxHp = spGetUnitHealth(nID)
                            -- don't chase units faster than us
                            if hp and maxHp and hp < maxHp * 0.95 and not (nDef and nDef.speed and nDef.speed > uDef.speed) then
                                local nx, _, nz = spGetUnitPosition(nID)
                                if nx then
                                    local dx, dz = nx - ux, nz - uz
                                    local dist = math.sqrt(dx*dx + dz*dz)
                                    local cost = (nDef and nDef.metalCost) or 50
                                    local score = cost - dist
                                    if score > bestHealScore then bestHealScore, unitToHeal, uDist = score, nID, dist end
                                end
                            end
                        end
                    end
                end
                if unitToHeal then
                    if uDist < buildDist then spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { unitToHeal }, {})
                    else spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { spGetUnitPosition(unitToHeal) }, {}) end
                    return
                end

                -- resurrect high value wrecks
                -- We don't care about reclaiming, it's a metal map
                local rezID, rezX, rezZ, rezMetal = FindResurrectTarget(ux, uz, 1600)
                if rezID then
                    local dx, dz = rezX - ux, rezZ - uz
                    local d2 = dx*dx + dz*dz
                    if d2 < buildDistSq then
                        spGiveOrderToUnit(unitID, CMD_RESURRECT, { rezID + (Game and Game.maxUnits or 32768) }, {})
                        return
                    elseif (rezMetal or 0) >= 100 then
                        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { rezX, spGetGroundHeight(rezX, rezZ), rezZ }, {})
                        return
                    end
                end

                if (st.army.state == "attacking" or st.army.state == "searching") and st.army.targetX then
                    local dx, dz = st.army.targetX - ux, st.army.targetZ - uz
                    if dx*dx + dz*dz > (400 * 400) then
                        GiveSpreadMove(unitID, ux, uz, st.army.targetX, st.army.targetZ, cfg.ANTI_CLUMP_MIN, cfg.ANTI_CLUMP_MAX)
                        return
                    end
                end

                if st.myCombatUnitCount > 0 then
                    local closestCombat, cDist = nil, mHuge
                    for i = 1, st.myCombatUnitCount do
                        local cID = st.myCombatUnits[i]
                        local cx, _, cz = spGetUnitPosition(cID)
                        if cx then
                            local dist = (cx-ux)*(cx-ux) + (cz-uz)*(cz-uz)
                            if dist < cDist then cDist, closestCombat = dist, cID end
                        end
                    end
                    if closestCombat then
                        if not IsGuardingValidTarget(unitID, 500) then spGiveOrderToUnit(unitID, cfg.CMD_GUARD, { closestCombat }, {}) end
                        return
                    end
                end
            end
            PushFrontier(unitID, ux, uz)
            return
        end

        local isStationary = (not uDef.speed or uDef.speed == 0)
        if isStationary then
            if not st.moveStateSet[unitID] then
                spGiveOrderToUnit(unitID, CMD_MOVE_STATE, { 0 }, {})
                st.moveStateSet[unitID] = true
            end
            local myTeamID = spGetMyTeamID()
            local buildDist = uDef.buildDistance or 200
            local currentCmds = spGetUnitCommands(unitID, 1)
            local cmd1 = currentCmds and currentCmds[1]
            local curId = cmd1 and cmd1.id
            local curParam = cmd1 and cmd1.params and cmd1.params[1]

            local enemyUnit = FindEnemyReclaimTarget(ux, uz, buildDist, myTeamID)
            if enemyUnit then
                if curId ~= cfg.CMD_RECLAIM or curParam ~= enemyUnit then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { enemyUnit }, {})
                end
                return
            end

            local mStall = st.metalStalling
            local eStall = st.energyStalling
            if mStall or eStall then
                if not eStall then
                    local reclaimTarget = FindReclaimTarget(ux, uz, true, buildDist)
                    if reclaimTarget then
                        local fcmd = reclaimTarget + (Game and Game.maxUnits or 32768)
                        if curId ~= cfg.CMD_RECLAIM or curParam ~= fcmd then
                            spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { fcmd }, {})
                        end
                        return
                    end
                end

                local function WantsStallType(def)
                    if not def then return false end
                    if mStall and def.extractsMetal and def.extractsMetal > 0 then return true end
                    if eStall then
                        local n = def.name and sLower(def.name) or ""
                        if (def.energyMake and def.energyMake > 0)
                            or sFind(n, "wind") or sFind(n, "solar")
                            or sFind(n, "fusion") or sFind(n, "geo") then return true end
                    end
                    return false
                end

                if curId == cfg.CMD_REPAIR and curParam then
                    local cDefID = spGetUnitDefID(curParam)
                    if WantsStallType(cDefID and UnitDefs[cDefID]) then
                        local chp, cmax = spGetUnitHealth(curParam)
                        if chp and cmax and chp < cmax then return end
                    end
                end

                local targetFrame, bestProgress = nil, 0
                local stallScan = spGetUnitsInCylinder(ux, uz, buildDist)
                if stallScan then
                    for k = 1, #stallScan do
                        local nID = stallScan[k]
                        if nID ~= unitID and spGetUnitTeam(nID) == myTeamID then
                            local nDefID = spGetUnitDefID(nID)
                            local nDef = nDefID and UnitDefs[nDefID]
                            if nDef and WantsStallType(nDef) then
                                local hp, maxHp = spGetUnitHealth(nID)
                                if hp and maxHp and maxHp > 0 and hp < maxHp then
                                    local progress = maxHp - hp
                                    if progress > bestProgress then bestProgress, targetFrame = progress, nID end
                                end
                            end
                        end
                    end
                end
                if targetFrame then
                    if curId ~= cfg.CMD_REPAIR or curParam ~= targetFrame then
                        spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { targetFrame }, {})
                    end
                    return
                end

                if currentCmds and #currentCmds > 0 then
                    spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                end
                return
            end

            if curId == cfg.CMD_REPAIR then return end

            local nearby = spGetUnitsInCylinder(ux, uz, buildDist)
            if nearby then
                local targetToRepair, maxDamage = nil, 0
                for k = 1, #nearby do
                    local nID = nearby[k]
                    if nID ~= unitID and spGetUnitTeam(nID) == myTeamID then
                        local nDef = spGetUnitDefID(nID) and UnitDefs[spGetUnitDefID(nID)]
                        if nDef then
                            local hp, maxHp = spGetUnitHealth(nID)
                            if hp and maxHp and maxHp > 0 and hp < maxHp * cfg.CON_HEAL_THRESHOLD then
                                local nx, _, nz = spGetUnitPosition(nID)
                                if nx then
                                    local dx, dz = nx - ux, nz - uz
                                    if dx*dx + dz*dz <= buildDist * buildDist then
                                        local damage = maxHp - hp
                                        if damage > maxDamage then maxDamage, targetToRepair = damage, nID end
                                    end
                                end
                            end
                        end
                    end
                end
                if targetToRepair then
                    if curId ~= cfg.CMD_REPAIR or curParam ~= targetToRepair then
                        spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { targetToRepair }, {})
                    end
                    return
                end
            end

            local reclaimTarget = FindReclaimTarget(ux, uz, true, buildDist)
            if reclaimTarget then
                local fcmd = reclaimTarget + (Game and Game.maxUnits or 32768)
                if curId ~= cfg.CMD_RECLAIM or curParam ~= fcmd then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { fcmd }, {})
                end
                return
            end

            if currentCmds and #currentCmds > 0 then
                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
            end
            return
        end

        -- Mobile con
        local myTeamID = spGetMyTeamID()
        local conBuildDist = uDef.buildDistance or 200
        local reclaimScanRadius = (cfg.ENEMY_RECLAIM_CHASE_RANGE * st.mapLinearScale) or 1000
        local enemyUnit = FindEnemyReclaimTarget(ux, uz, reclaimScanRadius, myTeamID, nil, true)
        if enemyUnit then
            local cmds = spGetUnitCommands(unitID, 1)
            if not cmds or #cmds == 0 or cmds[1].id ~= cfg.CMD_RECLAIM or cmds[1].params[1] ~= enemyUnit then
                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { enemyUnit }, {})
            end
            return
        end

        local emergencyType = ((not IsUnitBuildingFactory(unitID))) and CheckEmergencyEconomy(unitID) or nil
        if emergencyType then
            local cache = GetBuildCache(uDefID)
            local emergencyDef, eSpacing = nil, cfg.MIN_SPACING

            if emergencyType == "energy" then
                if hasWind and #cache.energyWind > 0 then emergencyDef = cache.energyWind[1] eSpacing = 64
                elseif #cache.energySolar > 0 then emergencyDef = cache.energySolar[1] eSpacing = 64 end
            else
                if #cache.mex > 0 then
                    local cheapestMex, cheapestCost = nil, mHuge
                    for i = #cache.mex, 1, -1 do
                        local cost = UnitDefs[cache.mex[i]] and UnitDefs[cache.mex[i]].metalCost or mHuge
                        if cost < cheapestCost then cheapestCost, cheapestMex = cost, cache.mex[i] end
                    end
                    emergencyDef = cheapestMex
                    eSpacing = st.metalMapMexSpacing
                end
            end

            if emergencyDef and CanAffordBuild(emergencyDef, true) then
                local tx, ty, tz, facing, key
                tx, ty, tz, facing, key = FindBuildSpot(ux, uz, emergencyDef, eSpacing, unitID, conBuildDist, nil, nil, nil, true)

                if tx then
                    spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                    local claimRadius = eSpacing * 0.5
                    if emergencyType == "metal" then claimRadius = st.metalMapMexSpacing * 0.5 end
                    local isMex = UnitDefs[emergencyDef] and UnitDefs[emergencyDef].extractsMetal and UnitDefs[emergencyDef].extractsMetal > 0
                    st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = claimRadius * claimRadius, isFactory = false, isAirFactory = false, facing = facing, defID = emergencyDef, isMex = isMex }
                    st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[emergencyDef] and UnitDefs[emergencyDef].metalCost or 0)
                    spGiveOrderToUnit(unitID, -emergencyDef, { tx, ty, tz, facing }, {})
                    return
                end
            else
                local buildDist = uDef.buildDistance or 200
                local reclaimTarget = FindReclaimTarget(ux, uz, true, buildDist)
                if reclaimTarget then
                    local currentCmds = spGetUnitCommands(unitID, 1)
                    if not currentCmds or #currentCmds == 0 or currentCmds[1].id ~= cfg.CMD_RECLAIM then
                        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                        spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { reclaimTarget + (Game and Game.maxUnits or 32768) }, {})
                        return
                    end
                end
            end
        end

        if (not IsUnitBuildingFactory(unitID)) and NeedsOrders(unitID, false, false, false) then
            local cache = GetBuildCache(uDefID)
            local tx, ty, tz, facing, key, defID
            local claimRadius = cfg.MIN_SPACING
            local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
            local function clampAnchor(cx, cz) return mMax(300, mMin(cx, mapX - 300)), mMax(300, mMin(cz, mapZ - 300)) end

            local buildAnchorX, buildAnchorZ = ux, uz
            if st.myFactoriesCount > 0 then buildAnchorX, buildAnchorZ = GetNearestFactoryPos(ux, uz) end

            -- face factories toward the enemy
            local facDirX, facDirZ = nil, nil
            if st.enemyBases and next(st.enemyBases) ~= nil then
                local bestD = mHuge
                for _, b in pairs(st.enemyBases) do
                    if b.lastSeen then
                        local bdx, bdz = b.x - ux, b.z - uz
                        local bd = bdx * bdx + bdz * bdz
                        if bd < bestD then bestD, facDirX, facDirZ = bd, bdx, bdz end
                    end
                end
            end
            if not facDirX then
                facDirX, facDirZ = mapX * 0.5 - ux, mapZ * 0.5 - uz
            end
            local facFacing
            if mAbs(facDirX) >= mAbs(facDirZ) then
                facFacing = facDirX >= 0 and 1 or 3
            else
                facFacing = facDirZ >= 0 and 0 or 2
            end

            local isNearBase = false
            if st.myFactoriesCount > 0 then
                local dx, dz = buildAnchorX - ux, buildAnchorZ - uz
                if dx*dx + dz*dz < (1200 * 1200) then isNearBase = true end
            else isNearBase = true end

            if isNearBase then
                local reclaimTarget = FindReclaimTarget(ux, uz, true, conBuildDist)
                if reclaimTarget and (st.metalStalling or math.random() < 0.25) then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { reclaimTarget + (Game and Game.maxUnits or 32768) }, {}) return
                end
            end

            if st.myFactoriesCount == 0 and (not IsUnitBuildingFactory(unitID)) and #cache.factories > 0 then
                local starterFactory = GetCheapestVehicleFactory(cache) or cache.factories[#cache.factories]
                if CanAffordBuild(starterFactory, true) then
                    defID = starterFactory
                    -- We want to place the first lab within
                    -- 80 elmos of the commanders range
                    -- So it doesn't have to walk to build it
                    local labDef = UnitDefs[defID]
                    local labKeepR = (mMax(labDef.xsize or 8, labDef.zsize or 8) * 8) / 2 + 48
                    tx, ty, tz, facing, key = FindBuildSpot(ux, uz, defID, 80, unitID, conBuildDist, labKeepR * labKeepR, facFacing)
                    if tx then
                        claimRadius = IsAirFactory(defID) and 90 or select(2, FactoryTurretInfo(defID))
                        st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = claimRadius * claimRadius, isFactory = true, isAirFactory = IsAirFactory(defID), facing = facing, defID = defID, isMex = false }
                        st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[defID] and UnitDefs[defID].metalCost or 0)
                        st.pendingFactoryBlueprints = st.pendingFactoryBlueprints + 1
                        spGiveOrderToUnit(unitID, -defID, { tx, ty, tz, facing }, {})
                    end
                end
            end

            if not tx and (not IsUnitBuildingFactory(unitID)) and (st.myFactoriesCount > 0 or st.pendingFactoryBlueprints > 0) and not st.economySaturated then
                local overflowingEnergy = (st.currentEnergyStorage > 0) and (st.currentEnergy > st.currentEnergyStorage * 0.85)
                local targetEnergy = mMax(st.energyPull * 1.15, mMin(st.metalIncome * 20, mMax(st.energyPull * 2, 600)), 100)
                local overflowingMetal = (st.currentMetalStorage > 0) and (st.currentMetal > st.currentMetalStorage * 0.85)
                local metalDeficit = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
                local energyDeficit = mMax(0, (st.energyPull or 0) - (st.energyIncome or 0))
                local mexBudget = mMax(1, mMin(math.ceil(metalDeficit / cfg.GetMexGain()), mMax(1, st.unclaimedMexCount or 0)))
                local energyBudget = mMax(1, math.ceil(energyDeficit / cfg.GetEnergyGain()))

                local needMetal = (st.metalStalling or st.unclaimedMexCount > 0) and not overflowingMetal
                local needEnergy = st.energyStalling or ((st.energyIncome < targetEnergy) and not overflowingEnergy)
                if not needMetal and not overflowingMetal and (st.metalIncome or 0) < (cfg.METAL_MAP_MEX_INCOME_TARGET * st.mapAreaScale) then
                    needMetal = true
                    mexBudget = mMax(mexBudget, math.ceil(cfg.MEX_GROWTH_FLOOR * st.mapAreaScale))
                end

                if not needMetal and not overflowingMetal and #cache.mex > 0 and (UnitDefs[cache.mex[#cache.mex]].metalCost or 0) > 300 then needMetal = true end

                -- enough builders on the job: leave this con to its current work
                if st.activeMexBuilders >= mexBudget then needMetal = false end
                if st.activeEnergyBuilders >= energyBudget then needEnergy = false end

                if not needEnergy and not needMetal then
                    -- keep a con on eco rather than idling
                    local energyStillNeeded = (st.energyIncome < targetEnergy) and not overflowingEnergy
                    if st.activeMexBuilders < mexBudget and st.activeEnergyBuilders < energyBudget then
                        if math.random() < 0.5 then needMetal = true elseif energyStillNeeded then needEnergy = true end
                    elseif st.activeMexBuilders < mexBudget then needMetal = true
                    elseif st.activeEnergyBuilders < energyBudget then
                        if energyStillNeeded then needEnergy = true end
                    end
                end
                if needEnergy and needMetal then
                    if st.energyStalling then needMetal = false elseif st.metalStalling then needEnergy = false else if math.random() < 0.65 then needMetal = false else needEnergy = false end end
                elseif needEnergy then needMetal = false
                elseif needMetal then needEnergy = false end

                if not tx and needMetal and #cache.mex > 0 then
                    local chosenMex = nil
                    local cheapestMexCost, cheapestMex = mHuge, nil
                    for i = #cache.mex, 1, -1 do
                        local cost = UnitDefs[cache.mex[i]] and UnitDefs[cache.mex[i]].metalCost or mHuge
                        if cost < cheapestMexCost then cheapestMexCost, cheapestMex = cost, cache.mex[i] end
                    end

                    if (st.metalStalling or st.unclaimedMexCount > 0) and cheapestMex and CanAffordBuild(cheapestMex, true) then chosenMex = cheapestMex end
                    if not chosenMex and st.economySaturated and not st.metalStalling then
                        for i = 1, #cache.mex do if CanAffordBuild(cache.mex[i], false) then chosenMex = cache.mex[i] break end end
                    end
                    if not chosenMex and cheapestMex and CanAffordBuild(cheapestMex, true) then chosenMex = cheapestMex end

                    if chosenMex then
                        defID = chosenMex
                        local nearestMex, mexDistSq = GetNearestUnclaimedMetalSpot(ux, uz)

                        local skipMetal = false
                        if nearestMex and mexDistSq > (cfg.MEX_SKIP_DIST * st.mapLinearScale) * (cfg.MEX_SKIP_DIST * st.mapLinearScale) and st.conUnitCount > 1 then
                            if not st.metalStalling or (st.metalStalling and st.activeMexBuilders >= 2) then skipMetal = true end
                        end

                        if skipMetal then
                            defID = nil
                        else
                            tx, ty, tz, facing, key = FindBuildSpot(ux, uz, defID, st.metalMapMexSpacing, unitID, conBuildDist, nil, nil, nil, true)
                        end

                        if not tx and defID then
                        -- Important, We NEVER want to upgrade existing
                        -- mexes. Theres no "tax credit" we're going to get
                        -- for making our mexes more efficient
                        -- it's wasted money
                            if #st.metalSpots == 0 then
                                local sx, sz = GetFlankSpreadPos(unitID, ux, uz, st.metalMapMexSpacing * 2, st.metalMapMexSpacing * 6, nil)
                                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
                                return
                            end
                        end

                        if tx and defID then
                            claimRadius = st.metalMapMexSpacing * 0.5
                            st.activeMexBuilders = st.activeMexBuilders + 1
                        end
                    end
                end

                if not tx and needEnergy then
                    local eID = nil
                    if hasWind and st.energyStalling and #cache.energyWind > 0 then eID = cache.energyWind[1] end
                    if not eID and #cache.energyAdv > 0 then
                        for i = 1, #cache.energyAdv do
                            local candidateID = cache.energyAdv[i]
                            local cost = UnitDefs[candidateID].metalCost or 0
                            if st.currentMetal > cost or (not st.energyStalling and st.currentMetal > (cost * 0.5)) then eID = candidateID break end
                        end
                    end
                    if not eID then
                        if hasWind and #cache.energyWind > 0 then eID = cache.energyWind[1]
                        elseif #cache.energySolar > 0 then eID = cache.energySolar[1] end
                    end

                    if eID and CanAffordBuild(eID, true) then
                        defID = eID
                        local eCost = UnitDefs[eID].metalCost or 0
                        local eSpacing = (eCost > 800) and 128 or cfg.ENERGY_GRID_SPACING
                        local eAx, eAz = clampAnchor(ux, uz)
                        tx, ty, tz, facing, key = FindBuildSpot(eAx, eAz, defID, eSpacing, unitID, conBuildDist, nil, nil, nil, true)
                        if tx then
                            claimRadius = eSpacing * 0.5
                            st.activeEnergyBuilders = st.activeEnergyBuilders + 1
                        end
                    end
                end
            end

            if not tx and st.incompleteFactoryCount > 0 then
                -- send only a few cons to help build a lab
                for i = 1, st.incompleteFactoryCount do
                    local incFactID = st.incompleteFactories[i]
                    if incFactID and (st.factoryGuards[incFactID] or 0) < 3 then
                        spGiveOrderToUnit(unitID, cfg.CMD_GUARD, { incFactID }, {})
                        st.factoryGuards[incFactID] = (st.factoryGuards[incFactID] or 0) + 1
                        return
                    end
                end
            end

            if not tx and #cache.conTurrets > 0 then
                if st.factoriesNeedingTurretsCount > 0 then
                    st.turretDbg.fired = st.turretDbg.fired + 1
                    local targetFactory = st.factoriesNeedingTurrets[1]
                    local fewest = st.factoryTurrets[targetFactory] or 0
                    for tk = 2, st.factoriesNeedingTurretsCount do
                        local fid = st.factoriesNeedingTurrets[tk]
                        local have = st.factoryTurrets[fid] or 0
                        if have < fewest then fewest, targetFactory = have, fid end
                    end
                    local fx, _, fz = spGetUnitPosition(targetFactory)
                    if fx then
                        defID = cache.conTurrets[math.random(#cache.conTurrets)]
                        local spacing = cfg.TURRET_SPACING
                        if not CanAffordBuild(defID) then
                            st.turretDbg.noAfford = st.turretDbg.noAfford + 1
                            defID = nil
                        else
                            local tDef = UnitDefs[defID]
                            local turFoot = (mMax(tDef and tDef.xsize or 2, tDef and tDef.zsize or 2) * 8)
                            spacing = mMax(40, turFoot + 16)
                            local facDef = UnitDefs[spGetUnitDefID(targetFactory)]
                            local facHalf = (mMax(facDef and facDef.xsize or 8, facDef and facDef.zsize or 8) * 8) / 2
                            local ringOut = mMin(facHalf + spacing * 4, cfg.BUILD_RADIUS)
                            tx, ty, tz, facing, key = FindBuildSpot(fx, fz, defID, spacing, unitID, ringOut, nil, nil, true, nil, facHalf)
                        end
                        if tx then
                            st.turretDbg.placed = st.turretDbg.placed + 1
                            claimRadius = spacing
                            st.factoryTurrets[targetFactory] = (st.factoryTurrets[targetFactory] or 0) + 1
                            -- Remember WHICH lab this turret was ordered for, so the
                            -- scan counts it against that lab and never a
                            -- neighbouring one it sits next to.
                            st.conTurretHomes[key] = targetFactory
                            if st.factoryTurrets[targetFactory] >= (FactoryTurretInfo(spGetUnitDefID(targetFactory))) then
                                for k = 1, st.factoriesNeedingTurretsCount do
                                    if st.factoriesNeedingTurrets[k] == targetFactory then
                                        st.factoriesNeedingTurrets[k] = st.factoriesNeedingTurrets[st.factoriesNeedingTurretsCount]
                                        st.factoriesNeedingTurretsCount = st.factoriesNeedingTurretsCount - 1
                                        break
                                    end
                                end
                            end
                        else
                            st.turretDbg.noSpot = st.turretDbg.noSpot + 1
                            defID = nil
                        end
                    end
                else
                    st.turretDbg.noNeed = st.turretDbg.noNeed + 1
                end
            elseif not tx then
                st.turretDbg.noCon = st.turretDbg.noCon + 1
            end

            local activeFactoryBuilds = st.incompleteFactoryCount + st.pendingFactoryBlueprints
            if not tx and #cache.factories > 0 and activeFactoryBuilds < 6 and st.myFactoriesCount > 0 then

                -- Somehow we do 1 factory per 5 income, and yet we're still overflowing
                local availableMetal = mMax(0, st.currentMetal - st.pendingCommittedMetal)
                local supportableFactories = math.floor(st.metalIncome / 5)
                local canExpand = st.economySaturated
                    or (st.myFactoriesCount < supportableFactories and not st.metalStalling)
                    or (st.metalIncome >= 20 and not st.metalStalling)

                -- We don't need to open a new lab if one still needs con turrets
                -- But if we're overflowing, then holding this back is stunting our growth
                if not st.economySaturated and (st.factoriesNeedingTurretsCount or 0) > 0 then
                    canExpand = false
                end

                -- Make one of each factory type, cheapest lab first
                local missingFacID = nil
                local missingFacCost = mHuge
                for i = 1, #cache.factories do
                    local fID = cache.factories[i]
                    local fCost = UnitDefs[fID] and UnitDefs[fID].metalCost or 0
                    local haveIt = false
                    for j = 1, st.myFactoriesCount do if spGetUnitDefID(st.myFactories[j]) == fID then haveIt = true break end end
                    for _, claim in pairs(st.claimedSpots) do if claim.isFactory and claim.defID == fID then haveIt = true break end end
                    if not haveIt and fCost < missingFacCost then
                        missingFacID = fID
                        missingFacCost = fCost
                    end
                end

                if missingFacID and not st.metalStalling and cfg.CanTechUpToFactory(missingFacID)
                    and (canExpand or availableMetal >= missingFacCost) then
                    defID = missingFacID
                    local fAx, fAz = clampAnchor(ux, uz)
                    tx, ty, tz, facing, key = FindBuildSpot(fAx, fAz, defID, cfg.BUILD_SPACING, unitID, conBuildDist, nil, facFacing)
                    if tx then claimRadius = IsAirFactory(defID) and 90 or select(2, FactoryTurretInfo(defID)) end
                end
                if not tx and canExpand and #cache.factories > 0 then
                    local extraFacID = nil
                    local extraFacCost = mHuge
                    for i = 1, #cache.factories do
                        local fID = cache.factories[i]
                        local fCost = UnitDefs[fID] and UnitDefs[fID].metalCost or 0
                        if cfg.CanTechUpToFactory(fID) and fCost < extraFacCost then extraFacID, extraFacCost = fID, fCost end
                    end
                    if extraFacID then
                        defID = extraFacID
                        local fAx, fAz = clampAnchor(ux, uz)
                        tx, ty, tz, facing, key = FindBuildSpot(fAx, fAz, defID, cfg.BUILD_SPACING, unitID, conBuildDist, nil, facFacing)
                        if tx then claimRadius = IsAirFactory(defID) and 90 or select(2, FactoryTurretInfo(defID)) end
                    end
                end
            end

            if not tx and #cache.other > 0 and st.myFactoriesCount > 0 and st.metalIncome > 12 then
                if math.random() < 0.15 then
                    for i = 1, #cache.other do
                        local oID = cache.other[i]
                        if UnitDefs[oID] and CanAffordBuild(oID) then
                            defID = oID
                            local cAx, cAz = st.baseCenterX, st.baseCenterZ
                            if not cAx then cAx, cAz = buildAnchorX, buildAnchorZ end
                            tx, ty, tz, facing, key = FindBuildSpot(cAx, cAz, defID, cfg.TURRET_SPACING, unitID, conBuildDist)
                            if tx then claimRadius = cfg.TURRET_SPACING break end
                        end
                    end
                end
            end

            if not tx and #cache.shields > 0 and st.metalIncome > 20 and st.currentMetal > 300 and not st.metalStalling and not st.energyStalling then
                if math.random() < 0.1 and CanAffordBuild(cache.shields[1]) then
                    defID = cache.shields[1]
                    tx, ty, tz, facing, key = FindBuildSpot(buildAnchorX, buildAnchorZ, defID, cfg.SHIELD_GRID_SPACING, unitID, conBuildDist)
                    if tx then claimRadius = 150 end
                end
            end

            -- lol this doesn't do anything, the bot doesn't understand radar
            -- good for the future though, hopefully whenever that can be fixed
            if not tx and #cache.radarTowers > 0 and st.myFactoriesCount > 0 then
                local radarTowerBudget = mMin(4, 1 + math.floor((st.metalIncome or 0) / 100))
                if (st.radarTowerCount or 0) < radarTowerBudget and not st.metalStalling and not st.energyStalling then
                    local rID = cache.radarTowers[1]
                    if CanAffordBuild(rID) then
                        defID = rID
                        local rAx, rAz = st.baseCenterX, st.baseCenterZ
                        if not rAx then rAx, rAz = buildAnchorX, buildAnchorZ end
                        tx, ty, tz, facing, key = FindBuildSpot(rAx, rAz, defID, cfg.BUILD_SPACING, unitID, conBuildDist)
                        if tx then claimRadius = 160 end
                    end
                end
            end

            if not tx and st.myFactoriesCount > 0 then
                if #cache.defensesGround > 0 then
                    local dID = SelectBalancedDefense(cache.defensesGround, st.currentMetal)
                    local turretCost = (UnitDefs[dID] and UnitDefs[dID].metalCost) or 1
                    local targetGround = st.myFactoriesCount * cfg.DEFENSE_MIN_PER_FACTORY
                        + math.floor((st.unease or 0) / turretCost)
                        + math.floor((st.enemyArmyValue or 0) / (turretCost * cfg.DEFENSE_ARMY_TURRET_RATIO))
                    if (st.defenseGroundCount or 0) < targetGround and not st.metalStalling and not st.energyStalling then
                        if CanAffordBuild(dID, false) then
                            defID = dID
                        end
                    end
                end

                if not defID and #cache.defensesAA > 0 then
                    local dID = SelectBalancedDefense(cache.defensesAA, st.currentMetal)
                    local turretCost = (UnitDefs[dID] and UnitDefs[dID].metalCost) or 1
                    local targetAA = st.myFactoriesCount * cfg.DEFENSE_MIN_PER_FACTORY
                        + math.floor((st.enemyArmyValue or 0) / (turretCost * cfg.DEFENSE_ARMY_TURRET_RATIO * 2))
                    if (st.defenseAACount or 0) < targetAA and not st.metalStalling and not st.energyStalling then
                        if CanAffordBuild(dID, false) then
                            defID = dID
                        end
                    end
                end

                if defID then
                    local dAx, dAz = st.baseCenterX, st.baseCenterZ
                    if not dAx then dAx, dAz = buildAnchorX, buildAnchorZ end
                    local fdx, fdz = facDirX, facDirZ
                    local fl = math.sqrt(fdx * fdx + fdz * fdz)
                    if fl < 1 then fdx, fdz = 1, 0 else fdx, fdz = fdx / fl, fdz / fl end
                    local ang = math.atan2(fdz, fdx) + (math.random() - 0.5) * math.pi * 1.2
                    local ringR = mMax(250, (st.baseRadius or 0) + 120)
                    local tAx = dAx + mCos(ang) * ringR
                    local tAz = dAz + mSin(ang) * ringR
                    tx, ty, tz, facing, key = FindBuildSpot(tAx, tAz, defID, cfg.TURRET_SPACING, unitID, conBuildDist)
                    if tx then claimRadius = cfg.TURRET_SPACING end
                end
            end

            -- Build antinuke when we can, and try to optimally cover the base
            if not tx and #cache.antinukes > 0 then
                local anDefID = cache.antinukes[#cache.antinukes]
                local covR = cfg.GetAntiNukeCoverage(anDefID) or 0
                local baseR = st.baseRadius or 0
                local target = 1
                if covR > 0 and baseR > covR then
                    target = math.ceil((baseR / covR) * (baseR / covR))
                end
                local current = (st.antinukeCount or 0) + (st.pendingAntinukeBlueprints or 0)
                if current < target and not st.metalStalling and not st.energyStalling then
                    if CanAffordBuild(anDefID, false) then
                        defID = anDefID
                        local nAx, nAz = st.baseCenterX, st.baseCenterZ
                        if not nAx then nAx, nAz = buildAnchorX, buildAnchorZ end
                        local ax, az = nAx, nAz
                        if current > 0 then
                            ax, az = cfg.GetSpreadPos(current + 1, nAx, nAz, covR * 0.5, mMax(covR, baseR))
                        end
                        tx, ty, tz, facing, key = FindBuildSpot(ax, az, defID, cfg.BUILD_SPACING, unitID, conBuildDist)
                        if tx then claimRadius = cfg.ANTI_NUKE_KEEPOUT end
                    end
                end
            end

            if tx and defID then
                local isFac = UnitDefs[defID] and UnitDefs[defID].isFactory
                local isMex = UnitDefs[defID] and UnitDefs[defID].extractsMetal and UnitDefs[defID].extractsMetal > 0
                local isAntinuke = cfg.IsAntiNukeDef(defID)
                st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = claimRadius * claimRadius, isFactory = isFac, isAirFactory = isFac and IsAirFactory(defID), facing = facing, defID = defID, isMex = isMex, isAntinuke = isAntinuke }
                st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[defID] and UnitDefs[defID].metalCost or 0)
                if isFac then st.pendingFactoryBlueprints = st.pendingFactoryBlueprints + 1 end
                if isAntinuke then st.pendingAntinukeBlueprints = st.pendingAntinukeBlueprints + 1 end
                spGiveOrderToUnit(unitID, -defID, { tx, ty, tz, facing }, {})
            else
                if not tx and (st.unclaimedMexCount > 0 or #st.metalSpots == 0) then
                    local fDeficit = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
                    local fBudget = mMax(1, math.ceil(fDeficit / cfg.GetMexGain()))
                    if (st.metalIncome or 0) < (cfg.METAL_MAP_MEX_INCOME_TARGET * st.mapAreaScale) then fBudget = mMax(fBudget, math.ceil(cfg.MEX_GROWTH_FLOOR * st.mapAreaScale)) end
                    if st.activeMexBuilders < fBudget and #cache.mex > 0 then
                        local mexID = cache.mex[#cache.mex]
                        if CanAffordBuild(mexID, true) then
                            local mx, my, mz, mf, mkey = FindBuildSpot(ux, uz, mexID, st.metalMapMexSpacing, unitID, conBuildDist, nil, nil, nil, true)
                            if mx then
                                local mDef = UnitDefs[mexID]
                                st.claimedSpots[mkey] = { frame = frame, x = mx, z = mz, r2 = (st.metalMapMexSpacing * 0.5) * (st.metalMapMexSpacing * 0.5), isFactory = false, isAirFactory = false, facing = mf, defID = mexID, isMex = true }
                                st.pendingCommittedMetal = st.pendingCommittedMetal + (mDef and mDef.metalCost or 0)
                                spGiveOrderToUnit(unitID, -mexID, { mx, my, mz, mf }, {})
                                return
                            end
                        end
                    end
                end

                if not tx and st.unclaimedMexCount > 0 then
                    local spot = GetNearestUnclaimedMetalSpot(ux, uz)
                    if spot then
                        local dx, dz = spot.x - ux, spot.z - uz
                        if dx*dx + dz*dz > 200*200 and (not IsUnitBuildingFactory(unitID)) then
                            local sx, sz = GetFlankSpreadPos(unitID, spot.x, spot.z, cfg.ANTI_CLUMP_MIN, cfg.ANTI_CLUMP_MAX, nil)
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {}) return
                        end
                    end
                end

                local recT = FindReclaimTarget(ux, uz, true, uDef.buildDistance or 200)
                if recT then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { recT + (Game and Game.maxUnits or 32768) }, {})
                    return
                end

                if uDef.buildOptions then
                    local repairSet = {}
                    for i = 1, #uDef.buildOptions do repairSet[uDef.buildOptions[i]] = true end
                    local repairT, repairD = nil, mHuge
                    local scanUnits = spGetUnitsInCylinder(ux, uz, (uDef.buildDistance or 200) + 500)
                    if scanUnits then
                        for i = 1, #scanUnits do
                            local nID = scanUnits[i]
                            local nTeam = spGetUnitTeam(nID)
                            if nTeam == myTeamID and nID ~= unitID then
                                local nDefID = spGetUnitDefID(nID)
                                if nDefID and repairSet[nDefID] then
                                    local nhp, nmax = spGetUnitHealth(nID)
                                    if nhp and nmax and nmax > 0 and nhp < nmax then
                                        local nx, _, nz = spGetUnitPosition(nID)
                                        if nx then
                                            local d = (nx-ux)*(nx-ux) + (nz-uz)*(nz-uz)
                                            if d < repairD then repairD, repairT = d, nID end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if repairT then
                        spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { repairT }, {})
                        return
                    end
                end

                -- nothing to reclaim or repair
                local bx, bz = st.baseCenterX or ux, st.baseCenterZ or uz
                local dx, dz = bx - ux, bz - uz
                if dx*dx + dz*dz > 400*400 and (not IsUnitBuildingFactory(unitID)) then
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { bx, spGetGroundHeight(bx, bz), bz }, {})
                elseif (not IsUnitBuildingFactory(unitID)) then
                    local patAngle = ((unitID % 251) + 1) * 0.025
                    local patR = (st.baseRadius or 0) > 0 and st.baseRadius or 500
                    local pmx, pmz = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    local px = mMax(100, mMin(bx + mCos(patAngle) * patR, pmx - 100))
                    local pz = mMax(100, mMin(bz + mSin(patAngle) * patR, pmz - 100))
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
                end
            end
        end

    elseif not uDef.isFactory and uDef.speed and uDef.speed > 0 then
        local ux, uy, uz = spGetUnitPosition(unitID)
        if not ux then return end

        if uDef.weapons and #uDef.weapons > 0 and not st.fireStateSet[unitID] then
            spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {2}, {})
            st.fireStateSet[unitID] = true
        end

        if uDef.canFly and cfg.CMD_FLY and not st.flyStateSet[unitID] then
            spGiveOrderToUnit(unitID, cfg.CMD_FLY, { 0 }, 0)
            st.flyStateSet[unitID] = true
        end

        local isScout = false
        if not isTrapperUnit and not uDef.canResurrect and not uDef.isBuilder then
            isScout = IsScoutDef(uDef)
        end
        if isScout then
            local needs = NeedsOrders(unitID, false, true, false)
            if not needs then
                local cs = spGetUnitCommands(unitID, 1)
                local c1 = cs and cs[1]
                if c1 and c1.id == cfg.CMD_GUARD then needs = true end
            end
            -- new intel
            if not needs then
                if (st.scoutIntelVersion[unitID] or 0) ~= st.intelVersion then
                    needs = true
                end
            end
            if needs then
                local baseBX, baseBZ = st.baseCenterX, st.baseCenterZ
                -- Bring all the scouts back during a raid
                -- The proper solution is for the bot to just use radar,
                -- but that's easier said then done, which makes this a
                -- TODO: make the bot understand radar
                if baseBX and ((st.unease or 0) > 0 or (unitID % 3) == 0) then
                    local ringR = (st.baseRadius or 400) + (cfg.PERIMETER_PATROL_RING * st.mapLinearScale)
                    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    local allyTeam = Spring.GetMyAllyTeamID()
                    local baseAng = math.atan2(uz - baseBZ, ux - baseBX)
                    local step = (2 * math.pi) / cfg.PERIMETER_PATROL_PROBES
                    local px, pz = nil, nil
                    for pi = 1, cfg.PERIMETER_PATROL_PROBES do
                        local a = baseAng + pi * step
                        local qx = mMax(50, mMin(baseBX + mCos(a) * ringR, mapX - 50))
                        local qz = mMax(50, mMin(baseBZ + mSin(a) * ringR, mapZ - 50))
                        if not Spring.IsPosInLos(qx, spGetGroundHeight(qx, qz), qz, allyTeam) then
                            px, pz = qx, qz
                            break
                        end
                    end
                    if not px then
                        px = mMax(50, mMin(baseBX + mCos(baseAng + step) * ringR, mapX - 50))
                        pz = mMax(50, mMin(baseBZ + mSin(baseAng + step) * ringR, mapZ - 50))
                    end
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
                else
                    if not AssignScoutOrder(unitID, frame) then
                        -- push toward the enemy / unknown, don't be idle
                        PushFrontier(unitID, ux, uz)
                    end
                end
                st.scoutIntelVersion[unitID] = st.intelVersion
            end
            return
        end

        local curCmds = spGetUnitCommands(unitID, 1)
        local curCmd = curCmds and curCmds[1]
        local curCmdId = curCmd and curCmd.id
        
        if curCmdId == cfg.CMD_ATTACK then
            if uDef.canFly then
                local curParams = curCmd and curCmd.params
                local maxRange = cfg.GetGroundRange(uDefID)
                local shouldStop = false
                local myTeam = spGetMyTeamID()

                if curParams then
                    if #curParams == 1 and type(curParams[1]) == "number" then
                        -- is the unit still alive?
                        local tID = curParams[1]
                        local hp = spGetUnitHealth(tID)
                        if not hp or hp <= 0 then shouldStop = true end
                    elseif #curParams >= 3 then
                        local tX, tZ = curParams[1], curParams[3]
                        if not Spring.IsPosInLos(tX, 0, tZ, spGetMyAllyTeamID()) then return end
                        local targetRadius = mMax(maxRange * 0.6, cfg.AOE_DAMAGE_RADIUS * 1.5)
                        local enemiesAtPos = spGetUnitsInCylinder(tX, tZ, targetRadius)
                        local foundAlive = false
                        if enemiesAtPos then
                            for i = 1, #enemiesAtPos do
                                local tID = enemiesAtPos[i]
                                local tTeam = spGetUnitTeam(tID)
                                if tTeam and tTeam ~= myTeam and not spAreTeamsAllied(myTeam, tTeam) then
                                    local hp = spGetUnitHealth(tID)
                                    if hp and hp > 0 then foundAlive = true break end
                                end
                            end
                        end
                        if not foundAlive then shouldStop = true end
                    else
                        -- treat as stale
                        shouldStop = true
                    end
                else
                    shouldStop = true
                end

                if not shouldStop then return end

                -- target is gone, clear the stale order
                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
            end

            -- I really would love to not have to have this here
            -- But I can't diagnose why they're getting attack commands
            spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
        end
        if cfg.IsAntiNukeDef(uDefID) then
            local bx, bz = st.baseCenterX or ux, st.baseCenterZ or uz
            local baseR = st.baseRadius or 0
            local cov = cfg.GetAntiNukeCoverage(uDefID)
            if cov <= 0 then cov = 1600 end
            local ringR = mMax(250, mMin(baseR, cov * 0.6))
            local px, pz = GetFlankSpreadPos(unitID, bx, bz, ringR, ringR + 200, nil)
            local dx, dz = px - ux, pz - uz
            if dx * dx + dz * dz > 160 * 160 then
                local cs = spGetUnitCommands(unitID, 1)
                local c1 = cs and cs[1]
                local alreadyGoing = c1 and c1.id == cfg.CMD_MOVE and c1.params and c1.params[1] and c1.params[3]
                    and (c1.params[1] - px) * (c1.params[1] - px) + (c1.params[3] - pz) * (c1.params[3] - pz) < 160 * 160
                if not alreadyGoing then
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
                end
            end
            return
        end

        local hasWeapons = uDef.weapons and #uDef.weapons > 0
        -- Artillery shouldn't try moving in, fire from the range limit
        -- because it's very fragile.
        local isArty = hasWeapons and cfg.GetGroundRange(uDefID) > 850
        local isRadar = (uDef.radarDistance and uDef.radarDistance > 500 and not hasWeapons) or (uDef.sonarDistance and uDef.sonarDistance > 500 and not hasWeapons) or sFind(name, "radar")
        local isJammer = (uDef.radarDistanceJam and uDef.radarDistanceJam > 0) or (uDef.sonarDistanceJam and uDef.sonarDistanceJam > 0) or sFind(name, "jammer") or sFind(name, "jam")
        local unitGroup = uDef.customParams and uDef.customParams.unitgroup
        -- I had some issues with units like the sol invictus getting classified as
        -- support units because they have an AA gun and they're a ground unit.
        -- Let's deal with that over here.
        local isDedicatedAA = (unitGroup == "aa")
        local isSupport = false
        if sFind(name, "antinuke") or sFind(name, "nuke") or unitGroup == "antinuke" or isRadar or isJammer or isDedicatedAA then isSupport = true end
        -- Fallback for a lack of the `unitgroup` customParam
        if not isDedicatedAA and unitGroup == nil and hasWeapons then
            for wi = 1, #uDef.weapons do
                local wDef = SafeGetWeaponDef(uDef.weapons[wi].weaponDef)
                if wDef and (sFind(sLower(wDef.name or ""), "flak") or sFind(sLower(wDef.type or ""), "aa")) then isSupport = true break end
            end
        end

        -- scouts have already returned above, so only non-scouts reach here
        local myTeamID = spGetMyTeamID()
        local supportType = nil
        if isRadar and isJammer then supportType = "both"
        elseif isRadar then supportType = "radar"
        elseif isJammer then supportType = "jammer"
        elseif isDedicatedAA then supportType = "aa" end

        if isSupport then
            if NeedsOrders(unitID, false, true, false) then
                local locks = st.supportGuardOwners

                local fdx, fdz = nil, nil
                local refX, refZ = st.baseCenterX or ux, st.baseCenterZ or uz
                local bestD = mHuge
                for _, b in pairs(st.enemyBases) do
                    if b.lastSeen then
                        local dx, dz = b.x - refX, b.z - refZ
                        local d = dx*dx + dz*dz
                        if d < bestD then bestD, fdx, fdz = d, dx, dz end
                    end
                end
                if not fdx then
                    if st.frontierX then fdx, fdz = st.frontierX - refX, st.frontierZ - refZ
                    else fdx, fdz = (Game.mapSizeX or 8192) * 0.5 - refX, (Game.mapSizeZ or 8192) * 0.5 - refZ end
                end
                local fl = math.sqrt(fdx*fdx + fdz*fdz)
                if fl < 1 then fl = 1 end
                fdx, fdz = fdx / fl, fdz / fl

                -- Move to a point behind the guarded unit (away from the enemy),
                -- I can see issues if the unit we're guarding is faster than us
                -- TODO: Look into this?
                local function MoveBehind(tx, tz)
                    local bx = tx - fdx * cfg.SUPPORT_BEHIND_DIST
                    local bz = tz - fdz * cfg.SUPPORT_BEHIND_DIST
                    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    bx = mMax(50, mMin(bx, mapX - 50))
                    bz = mMax(50, mMin(bz, mapZ - 50))
                    local cs2 = spGetUnitCommands(unitID, 1)
                    local c2 = cs2 and cs2[1]
                    if c2 and c2.id == cfg.CMD_MOVE and c2.params and c2.params[1] and c2.params[3] then
                        local dx, dz = bx - c2.params[1], bz - c2.params[3]
                        if dx*dx + dz*dz < 80*80 then return end
                    end
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { bx, spGetGroundHeight(bx, bz), bz }, {})
                end

                local function isTargetLocked(t)
                    if not supportType or not t then return false end
                    if (supportType == "radar" or supportType == "both") and locks.radar[t] then return true end
                    if (supportType == "jammer" or supportType == "both") and locks.jammer[t] then return true end
                    if supportType == "aa" and locks.aa[t] then return true end
                    return false
                end
                local function pickTarget(preferred)
                    if preferred and not isTargetLocked(preferred) then return preferred end
                    for i = 1, st.myCombatUnitCount do
                        local c = st.myCombatUnits[i]
                        if not isTargetLocked(c) then return c end
                    end
                    for i = 1, st.myFactoriesCount do
                        local f = st.myFactories[i]
                        if not isTargetLocked(f) then
                            -- skip a waited lab, there is nothing to
                            -- support there. we're fine with under construction labs
                            local fwaited = st.factoryWaitState[f]
                            if fwaited then
                                local fhp, fmax = spGetUnitHealth(f)
                                if fhp and fmax and fhp < fmax then fwaited = false end
                            end
                            if not fwaited then return f end
                        end
                    end
                    return nil
                end

                local curTarget = st.supportTarget[unitID]

                -- keep following the current target if we still own its lock
                if curTarget and spGetUnitDefID(curTarget) then
                    local keep = true
                    -- drop a support parked behind a waited lab: nothing to support
                    if st.factoryWaitState[curTarget] then
                        local thp, tmax = spGetUnitHealth(curTarget)
                        if thp and tmax and thp >= tmax then keep = false end
                    end
                    if keep then
                        if supportType then
                            keep = false
                            if (supportType == "radar" or supportType == "both") and locks.radar[curTarget] == unitID then keep = true end
                            if (supportType == "jammer" or supportType == "both") and locks.jammer[curTarget] == unitID then keep = true end
                            if supportType == "aa" and locks.aa[curTarget] == unitID then keep = true end
                        end
                        if keep then
                            local tx, _, tz = spGetUnitPosition(curTarget)
                            if tx then MoveBehind(tx, tz) end
                            return
                        end
                    end
                    st.supportTarget[unitID] = nil
                end

                -- pick any unlocked combat unit / factory.
                local target = pickTarget(nil)

                if target then
                    st.supportTarget[unitID] = target
                    -- claim the exclusive lock
                    if supportType == "radar" or supportType == "both" then locks.radar[target] = unitID end
                    if supportType == "jammer" or supportType == "both" then locks.jammer[target] = unitID end
                    if supportType == "aa" then locks.aa[target] = unitID end
                    local tx, _, tz = spGetUnitPosition(target)
                    if tx then MoveBehind(tx, tz) end
                    return
                end
                -- If there's nothing for our support unit to do, just move
                -- forward with the rest of the army
                PushFrontier(unitID, ux, uz)
            end
            return
        end

        -- we don't care about microing against enemy raiders
        -- we need to kill them fast, and hopefully possibly distract them
        local nearRaid = st.currentDefenders[unitID] == true

        local hp, maxHp = spGetUnitHealth(unitID)

        -- we don't want to get caught in the blast
        if st.selfDingCount > 0 then
            local blastX, blastZ, blastR = nil, nil, 0
            for i = 1, st.selfDingCount do
                local b = st.selfDingUnits[i]
                if b.id ~= unitID then
                    local br = b.blastRadius or 0
                    local dx, dz = b.x - ux, b.z - uz
                    if dx * dx + dz * dz < br * br then
                        blastX, blastZ, blastR = b.x, b.z, br
                        break
                    end
                end
            end
            if blastX then
                local awayX, awayZ = ux - blastX, uz - blastZ
                local awayLen = math.sqrt(awayX * awayX + awayZ * awayZ)
                if awayLen < 1 then awayX, awayZ, awayLen = 1, 0, 1 end
                local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                local fx = mMax(50, mMin(ux + (awayX / awayLen) * blastR, mapX - 50))
                local fz = mMax(50, mMin(uz + (awayZ / awayLen) * blastR, mapZ - 50))
                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { fx, spGetGroundHeight(fx, fz), fz }, {})
                return
            end
        end

        local selfDBlastRadius = cfg.GetSelfDBlastRadius(uDefID)
        if not nearRaid and not uDef.canFly and selfDBlastRadius >= cfg.SELFD_MIN_BLAST_RADIUS then
            local selfdActive = Spring.GetUnitSelfDTime(unitID) > 0
            local lowHP = hp and maxHp and maxHp > 0 and (hp / maxHp) < cfg.SELFD_HP_RATIO
            if selfdActive or lowHP then
                -- weight the threat
                local enemyX, enemyZ, enemyDistSq, enemyMetal = nil, nil, mHuge, 0
                local scan = spGetUnitsInCylinder(ux, uz, selfDBlastRadius * 2)
                if scan then
                    for i = 1, #scan do
                        local tID = scan[i]
                        local tTeam = spGetUnitTeam(tID)
                        if tTeam and tTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, tTeam) then
                            local tDef = UnitDefs[spGetUnitDefID(tID)]
                            if tDef and tDef.speed and tDef.speed > 0 then
                                local ex, _, ez = spGetUnitPosition(tID)
                                if ex then
                                    enemyMetal = enemyMetal + (tDef.metalCost or 50)
                                    local d = (ex - ux) * (ex - ux) + (ez - uz) * (ez - uz)
                                    if d < enemyDistSq then enemyDistSq, enemyX, enemyZ = d, ex, ez end
                                end
                            end
                        end
                    end
                end

                if enemyX and enemyMetal >= (uDef.metalCost or 100) * cfg.SELFD_DOOM_RATIO then
                    -- start self d timer
                    if not selfdActive then
                        spGiveOrderToUnit(unitID, cfg.CMD_SELFD, {}, {})
                    end
                    -- let's go towards the enemies base, strong units like
                    -- the juggernaut have self d explosions similar to nukes
                    -- Niche, but to my knowledge, self d-ing a nuke silo has
                    -- a similar effect, lets add this as a TODO: look into this 
                    local marchX, marchZ, mDistSq = enemyX, enemyZ, mHuge
                    for _, b in pairs(st.enemyBases) do
                        if b.x and b.z then
                            local d = (b.x - ux) * (b.x - ux) + (b.z - uz) * (b.z - uz)
                            if d < mDistSq then mDistSq, marchX, marchZ = d, b.x, b.z end
                        end
                    end
                    local cs = spGetUnitCommands(unitID, 1)
                    local c1 = cs and cs[1]
                    local alreadyGoing = c1 and c1.id == cfg.CMD_MOVE and c1.params and c1.params[1] and c1.params[3]
                        and (c1.params[1] - marchX) * (c1.params[1] - marchX) + (c1.params[3] - marchZ) * (c1.params[3] - marchZ) < 160 * 160
                    if not alreadyGoing then
                        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { marchX, spGetGroundHeight(marchX, marchZ), marchZ }, {})
                    end
                    return
                elseif selfdActive then
                    -- Don't self d if the attackers are gone
                    spGiveOrderToUnit(unitID, cfg.CMD_SELFD, {}, {})
                end
            end
        end

        if not nearRaid and hp and maxHp and maxHp > 0 and (hp / maxHp) < cfg.RETREAT_HEALTH_RATIO then
            local threatX, threatZ, threatDistSq = nil, nil, mHuge
            local enemyDPS, enemyHP = 0, 0
            local nearby = spGetUnitsInCylinder(ux, uz, cfg.TANGENTIAL_RETREAT_DIST)
            if nearby then
                for i = 1, #nearby do
                    local tID = nearby[i]
                    local tTeam = spGetUnitTeam(tID)
                    if tTeam and tTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, tTeam) then
                        local tDefID = spGetUnitDefID(tID)
                        local tDPS = tDefID and cfg.GetUnitDPS(tDefID) or 0
                        if tDPS > 0 then
                            enemyDPS = enemyDPS + tDPS
                            local thp = spGetUnitHealth(tID)
                            if thp and thp > 0 then
                                enemyHP = enemyHP + thp
                            else
                                local tDef = UnitDefs[tDefID]
                                enemyHP = enemyHP + (tDef and tDef.maxHealth or 100)
                            end
                            local tx, _, tz = spGetUnitPosition(tID)
                            if tx then
                                local dx, dz = tx - ux, tz - uz
                                local d = dx*dx + dz*dz
                                if d < threatDistSq then threatDistSq, threatX, threatZ = d, tx, tz end
                            end
                        end
                    end
                end
            end

            local shouldRetreat = false
            if threatX and enemyDPS > 0 then
                local ourDPS = cfg.GetUnitDPS(uDefID)
                if ourDPS <= 0 then
                    shouldRetreat = true
                else
                    shouldRetreat = (hp / enemyDPS) < (enemyHP / ourDPS)
                end
            end
            if shouldRetreat
                and threatDistSq < (cfg.TANGENTIAL_RETREAT_DIST * cfg.TANGENTIAL_RETREAT_DIST) then
                local retreatDist = mMin(1200, mMax(450, (uDef.speed or 100) * 3.0))
                local tx, tz
                if CanStrafeByDefID(uDefID) then
                    local awayX, awayZ = ux - threatX, uz - threatZ
                    local awayLen = math.sqrt(threatDistSq)
                    if awayLen < 1 then awayX, awayZ, awayLen = 1, 0, 1 end
                    tx = ux + (awayX / awayLen) * retreatDist
                    tz = uz + (awayZ / awayLen) * retreatDist
                else
                    tx, tz = cfg.GetTangentialRetreat(unitID, ux, uz, threatX, threatZ, retreatDist)
                end
                local ty = spGetGroundHeight(tx, tz)
                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { tx, ty, tz }, {})
                return
            end

        end

        if hasWeapons then
            local maxRange = cfg.GetGroundRange(uDefID)
            local airRange = mMax(maxRange, cfg.GetAAWeaponRange(uDefID))
            if maxRange > 200 then
                local cmds = spGetUnitCommands(unitID, -1)
                local cmd1 = cmds and cmds[1]
                
                local searchRadius = airRange + 400
                local cx, cy, cz, bestID, clusterSize, bestMetal, isGround =
                    FindBestClusterTarget(ux, uz, searchRadius, cfg.AOE_DAMAGE_RADIUS, uDefID)

                if cfg.IsJunoBomberDef(uDefID) then
                    local myTeam = spGetMyTeamID()
                    local gaia = spGetGaiaTeamID()
                    local jID, jDistSq, jX, jZ = nil, mHuge, nil, nil
                    local nearby = spGetUnitsInCylinder(ux, uz, 2500)
                    if nearby then
                        for i = 1, #nearby do
                            local tID = nearby[i]
                            local tTeam = spGetUnitTeam(tID)
                            if tTeam and tTeam ~= myTeam and tTeam ~= gaia and not spAreTeamsAllied(myTeam, tTeam) then
                                local tDef = UnitDefs[spGetUnitDefID(tID)]
                                if tDef and (not tDef.speed or tDef.speed == 0) and cfg.IsJunoVulnerableDef(tDef) then
                                    local tx, _, tz = spGetUnitPosition(tID)
                                    if tx then
                                        local d = (tx - ux) * (tx - ux) + (tz - uz) * (tz - uz)
                                        if d < jDistSq then
                                            jDistSq, jID, jX, jZ = d, tID, tx, tz
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if jID then
                        bestID = jID
                        cx, cy, cz = jX, spGetGroundHeight(jX, jZ), jZ
                        clusterSize, bestMetal, isGround = 1, 0, false
                    else
                        -- Linger near the frontline or enemy base so the bomber is ready to go
                        local bx = st.army.targetX or st.baseCenterX or ux
                        local bz = st.army.targetZ or st.baseCenterZ or uz
                        local alreadyGoing = cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3]
                            and (cmd1.params[1] - bx) * (cmd1.params[1] - bx) + (cmd1.params[3] - bz) * (cmd1.params[3] - bz) < 200 * 200
                        if not alreadyGoing then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { bx, spGetGroundHeight(bx, bz), bz }, {})
                        end
                        return
                    end
                end

                if not bestID and cfg.IsBomberDef(uDefID) then
                    local bX, bY, bZ = cfg.FindBombTargetFromMemory(ux, uz)
                    if bX then
                        local alreadyBombing = cmd1 and cmd1.id == cfg.CMD_ATTACK and cmd1.params
                            and cmd1.params[1] and cmd1.params[3]
                            and (cmd1.params[1] - bX) * (cmd1.params[1] - bX) + (cmd1.params[3] - bZ) * (cmd1.params[3] - bZ) < 200 * 200
                        if not alreadyBombing then
                            if st.attackDbg then
                                st.attackDbg.issued = st.attackDbg.issued + 1
                                st.attackDbg.airIssued = st.attackDbg.airIssued + 1
                                st.attackDbg.lastIssuedDef = uDef.name
                            end
                            spGiveOrderToUnit(unitID, cfg.CMD_ATTACK, { bX, bY or 0, bZ }, {})
                        end
                        return
                    end
                end

            if bestID then
                    if nearRaid and not uDef.canFly then
                        local raiderX, _, raiderZ = spGetUnitPosition(bestID)
                        if not raiderX then raiderX, raiderZ = cx, cz end
                        local alreadyCharging = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local ddx, ddz = raiderX - cmd1.params[1], raiderZ - cmd1.params[3]
                            if ddx*ddx + ddz*ddz < 160*160 then alreadyCharging = true end
                        end
                        if not alreadyCharging then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { raiderX, spGetGroundHeight(raiderX, raiderZ), raiderZ }, {})
                        end
                        return
                    end

                    if uDef.canFly then
                        local alreadyAttacking = false
                        if cmd1 and cmd1.id == cfg.CMD_ATTACK and cmd1.params and cmd1.params[1] == bestID then
                            alreadyAttacking = true
                        end
                        if not alreadyAttacking then
                            if st.attackDbg then
                                st.attackDbg.issued = st.attackDbg.issued + 1
                                if uDef.canFly then st.attackDbg.airIssued = st.attackDbg.airIssued + 1
                                else st.attackDbg.groundIssued = st.attackDbg.groundIssued + 1 end
                                st.attackDbg.lastIssuedDef = uDef.name
                            end
                            spGiveOrderToUnit(unitID, cfg.CMD_ATTACK, { bestID }, {})
                        end
                        return
                    end

                    if isArty then
                        local ddx, ddz = cx - ux, cz - uz
                        if ddx*ddx + ddz*ddz <= maxRange * maxRange then
                            local hasMove = false
                            if cmds then
                                for ci = 1, #cmds do
                                    local cid = cmds[ci].id
                                    if cid == cfg.CMD_MOVE or cid == cfg.CMD_ATTACK or cid == cfg.CMD_PATROL then hasMove = true break end
                                end
                            end
                            if hasMove then spGiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
                            return
                        end
                        local sx, sz = GetFlankSpreadPos(unitID, cx, cz, maxRange * 0.85, maxRange * 0.95, nil)
                        local alreadyHeading = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local mdx, mdz = sx - cmd1.params[1], sz - cmd1.params[3]
                            if mdx*mdx + mdz*mdz < 160*160 then alreadyHeading = true end
                        end
                        if not alreadyHeading then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
                        end
                        return
                    end

                    local nEx, nEz, nDistSq, nVx, nVz = nil, nil, mHuge, 0, 0
                    local enemyDPS, enemyHP = 0, 0
                    local nAir = false
                    local kiteScan = spGetUnitsInCylinder(ux, uz, airRange)
                    if kiteScan then
                        for i = 1, #kiteScan do
                            local tID = kiteScan[i]
                            local tTeam = spGetUnitTeam(tID)
                            if tTeam and tTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, tTeam) then
                                local tDefID = spGetUnitDefID(tID)
                                local tDPS = tDefID and cfg.GetUnitDPS(tDefID) or 0
                                -- A threat is anything that can hurt us
                                if tDPS > 0 then
                                    enemyDPS = enemyDPS + tDPS
                                    local thp = spGetUnitHealth(tID)
                                    if thp and thp > 0 then
                                        enemyHP = enemyHP + thp
                                    else
                                        local tDef = UnitDefs[tDefID]
                                        enemyHP = enemyHP + (tDef and tDef.maxHealth or 100)
                                    end
                                    local ex, _, ez = spGetUnitPosition(tID)
                                    if ex then
                                        local dx, dz = ex - ux, ez - uz
                                        local d = dx*dx + dz*dz
                                        if d < nDistSq then
                                            nDistSq, nEx, nEz = d, ex, ez
                                            nAir = (UnitDefs[tDefID] and UnitDefs[tDefID].canFly) or false
                                            local vx, _, vz = spGetUnitVelocity(tID)
                                            if vx then nVx, nVz = vx, vz else nVx, nVz = 0, 0 end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    local engageRange = nAir and airRange or maxRange
                    local shouldKite = false
                    if nEx and enemyDPS > 0 and hp and hp > 0 then
                        local ourDPS = cfg.GetUnitDPS(uDefID)
                        if ourDPS <= 0 then
                            shouldKite = true
                        else
                            shouldKite = (hp / enemyDPS) < (enemyHP / ourDPS)
                        end
                    end
                    if shouldKite
                        and nDistSq < (engageRange * cfg.KITE_TRIGGER_RATIO) * (engageRange * cfg.KITE_TRIGGER_RATIO) then
                        local kx, kz
                        if CanStrafeByDefID(uDefID) then
                            local awayX, awayZ = ux - nEx, uz - nEz
                            local awayLen = math.sqrt(nDistSq)
                            if awayLen < 1 then awayX, awayZ, awayLen = 1, 0, 1 end
                            local awayNX, awayNZ = awayX / awayLen, awayZ / awayLen
                            local closing = nVx * awayNX + nVz * awayNZ
                            local leadDist = mMax(0, closing) * cfg.KITE_LEAD_FRAMES
                            local standoff = engageRange * cfg.KITE_STANDOFF_RATIO + leadDist
                            kx = nEx + awayNX * standoff
                            kz = nEz + awayNZ * standoff
                        else
                            kx, kz = cfg.GetTangentialRetreat(unitID, ux, uz, nEx, nEz, engageRange * cfg.KITE_TANK_HOP)
                        end
                        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                        kx = mMax(50, mMin(kx, mapX - 50))
                        kz = mMax(50, mMin(kz, mapZ - 50))
                        local kLvl = Spring.GetGameRulesParam("lavaLevel")
                        local kDanger = nil
                        if kLvl and kLvl > -9000 then
                            kDanger = kLvl
                        else
                            local geMin = Spring.GetGroundExtremes()
                            if geMin and geMin < -50 then kDanger = 0 end
                        end
                        if kDanger and spGetGroundHeight(kx, kz) < kDanger + cfg.LAVA_MARGIN then
                            local bdx, bdz = ux - kx, uz - kz
                            local bl = math.sqrt(bdx*bdx + bdz*bdz)
                            if bl < 1 then kx, kz = ux, uz
                            else
                                bdx, bdz = bdx / bl, bdz / bl
                                for si = 1, 16 do
                                    kx = kx + bdx * 32
                                    kz = kz + bdz * 32
                                    if spGetGroundHeight(kx, kz) >= kDanger + cfg.LAVA_MARGIN then break end
                                end
                            end
                        end
                        local alreadyKiting = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local mdx, mdz = kx - cmd1.params[1], kz - cmd1.params[3]
                            if mdx*mdx + mdz*mdz < cfg.KITE_DEADBAND * cfg.KITE_DEADBAND then alreadyKiting = true end
                        end
                        if not alreadyKiting then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { kx, spGetGroundHeight(kx, kz), kz }, {})
                        end
                        return
                    end
                    if st.enemyDefenses then
                        local dX, dZ, dR = nil, nil, 0
                        local dBest2 = 900 * 900
                        for dID, dEnt in pairs(st.enemyDefenses) do
                            local ddx, ddz = dEnt.x - cx, dEnt.z - cz
                            local dd2 = ddx*ddx + ddz*ddz
                            if dd2 < dBest2 then dBest2, dX, dZ, dR = dd2, dEnt.x, dEnt.z, dEnt.range or 0 end
                        end
                        if dX and dR > 0 and maxRange >= dR then
                            local holdR = mMin(maxRange, dR + 150)
                            local hx, hz = GetFlankSpreadPos(unitID, dX, dZ, mMax(60, holdR - 40), mMax(140, holdR + 40), nil)
                            local alreadyHeading = false
                            if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                                local hdx, hdz = hx - cmd1.params[1], hz - cmd1.params[3]
                                if hdx*hdx + hdz*hdz < 160*160 then alreadyHeading = true end
                            end
                            if not alreadyHeading then
                                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { hx, spGetGroundHeight(hx, hz), hz }, {})
                            end
                            return
                        end
                    end
                    local eMinR, eMaxR
                    if isGround and clusterSize >= cfg.CLUSTER_THRESHOLD then
                        eMinR = mMax(60, maxRange * 0.95)
                        eMaxR = mMax(140, maxRange * 0.98)
                    else
                        local tDefID = bestID and spGetUnitDefID(bestID)
                        local sRange = cfg.GetEngageRange(uDefID, tDefID and UnitDefs[tDefID])
                        eMinR = mMax(60, sRange * 0.95)
                        eMaxR = mMax(140, sRange * 0.98)
                    end
                    local sx, sz = nil, nil
                    if isGround and clusterSize >= cfg.CLUSTER_THRESHOLD then
                        sx, sz = GetFlankSpreadPos(unitID, cx, cz, eMinR, eMaxR, nil)
                    else
                        local ex, ey, ez = spGetUnitPosition(bestID)
                        if ex then
                            sx, sz = GetFlankSpreadPos(unitID, ex, ez, eMinR, eMaxR, bestID)
                        end
                    end
                    if sx then
                        local alreadyHeading = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local ddx, ddz = sx - cmd1.params[1], sz - cmd1.params[3]
                            if ddx*ddx + ddz*ddz < 160*160 then alreadyHeading = true end
                        end
                        if not alreadyHeading then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
                        end
                    end
                    return
                end
            end
        end

        local reAim = true
        local cReaim = spGetUnitCommands(unitID, 1)
        local c0 = cReaim and cReaim[1]
        if c0 and (c0.id == cfg.CMD_MOVE or c0.id == cfg.CMD_ATTACK or c0.id == cfg.CMD_PATROL or c0.id == cfg.CMD_GUARD) then
            local planeArrived = false
            if uDef.canFly and c0.id == cfg.CMD_MOVE and c0.params and c0.params[1] and c0.params[3] then
                local adx, adz = c0.params[1] - ux, c0.params[3] - uz
                if adx * adx + adz * adz < 200 * 200 then planeArrived = true end
            end
            if not planeArrived then
                local lastAim = st.combatReaimFrame[unitID] or -999999
                if frame - lastAim < cfg.COMBAT_REAIM_INTERVAL then reAim = false end
            end
        end
        if reAim then
            st.combatReaimFrame[unitID] = frame
            st.frameNum = frame

            local tgtX, tgtY, tgtZ = st.army.targetX, st.army.targetY, st.army.targetZ
            local cx, cy, cz, bestID, clusterSize, bestMetal, isGround =
                FindBestClusterTarget(ux, uz, 1600, cfg.AOE_DAMAGE_RADIUS, uDefID)
            if not cx and tgtX then
                cx, cy, cz, bestID, clusterSize, bestMetal, isGround =
                    FindBestClusterTarget(tgtX, tgtZ, 1500, cfg.AOE_DAMAGE_RADIUS, uDefID)
            end

            if cx then
                local tDefID = bestID and spGetUnitDefID(bestID)
                local uRange = cfg.GetEngageRange(uDefID, tDefID and UnitDefs[tDefID])
                if isArty then
                    -- Hold at range limit once in range
                    local ddx, ddz = cx - ux, cz - uz
                    if ddx*ddx + ddz*ddz <= uRange * uRange then
                        local cs = spGetUnitCommands(unitID, -1)
                        local hasMove = false
                        if cs then
                            for ci = 1, #cs do
                                local cid = cs[ci].id
                                if cid == cfg.CMD_MOVE or cid == cfg.CMD_ATTACK or cid == cfg.CMD_PATROL then hasMove = true break end
                            end
                        end
                        if hasMove then spGiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
                        return
                    end
                    GiveSpreadMove(unitID, ux, uz, cx, cz, uRange * 0.85, uRange * 0.95)
                    return
                end
                GiveSpreadMove(unitID, ux, uz, cx, cz, mMax(60, uRange * 0.95), mMax(140, uRange * 0.98), (clusterSize == 1 and bestID) or nil)
                return
            end

            if st.army.state == "attacking" and tgtX then
                local ddx, ddz = tgtX - ux, tgtZ - uz
                if ddx*ddx + ddz*ddz < 400 * 400 then
                    local myTeamID = spGetMyTeamID()
                    local gaiaTeam = spGetGaiaTeamID()
                    local nearbyEnemies = spGetUnitsInCylinder(tgtX, tgtZ, 500)
                    local targetEnemy = nil
                    if nearbyEnemies then
                        for ei = 1, #nearbyEnemies do
                            local eID = nearbyEnemies[ei]
                            if eID ~= unitID then
                                local eTeam = spGetUnitTeam(eID)
                                if eTeam and eTeam ~= gaiaTeam and not spAreTeamsAllied(eTeam, myTeamID) then
                                    targetEnemy = eID
                                    break
                                end
                            end
                        end
                    end
                    if targetEnemy then
                        spGiveOrderToUnit(unitID, cfg.CMD_ATTACK, { targetEnemy }, {})
                        return
                    else
                        PushFrontier(unitID, ux, uz)
                        return
                    end
                end
                GiveSpreadMove(unitID, ux, uz, tgtX, tgtZ, cfg.ANTI_CLUMP_MIN, 1100)
                return
            end

            if (uDef.speed or 0) > cfg.GetScoutSpeedThreshold() and not isTrapperUnit and CountActiveScouts(frame) < st.scoutMaxActive then
                if AssignScoutOrder(unitID, frame) then
                    return
                end
            end

            PushFrontier(unitID, ux, uz)
        end
    end
end






local loadGov = {
    cpuMs = 0,
    scale = 1,
    lastAdaptFrame = -cfg.LOAD_ADAPT_EVERY,
    effCheckInterval = cfg.CHECK_INTERVAL,
    effThreatInterval = cfg.THREAT_INTERVAL,
}

local function UpdateLoadGovernor(frame)
    if frame - loadGov.lastAdaptFrame < cfg.LOAD_ADAPT_EVERY then return end
    loadGov.lastAdaptFrame = frame

    local fps = (Spring.GetFPS and Spring.GetFPS()) or 0
    local cpuOver = loadGov.cpuMs > cfg.LOAD_CEILING_MS
    local cpuUnder = loadGov.cpuMs < cfg.LOAD_TARGET_MS
    local fpsLow = (fps > 0) and (fps < cfg.LOAD_MIN_FPS)
    local fpsOk = (fps == 0) or (fps > cfg.LOAD_MIN_FPS_RECOVER)

    if cpuOver or fpsLow then
        loadGov.scale = mMin(loadGov.scale + 0.5, cfg.LOAD_MAX_SCALE)
    elseif cpuUnder and fpsOk then
        loadGov.scale = mMax(loadGov.scale - 0.5, 1)
    end

    loadGov.effCheckInterval = mMax(cfg.CHECK_INTERVAL, mCeil(cfg.CHECK_INTERVAL * loadGov.scale))
    loadGov.effThreatInterval = mMax(cfg.THREAT_INTERVAL, mCeil(cfg.THREAT_INTERVAL * loadGov.scale))
end

function widget:GameFrame(frame)
    if not ui.active then return end

    -- spectators can't command units
    if IsSpectating() then return end

    local myTeam = spGetMyTeamID()
    if not myTeam then return end

    local units = spGetTeamUnits(myTeam)
    if not units then return end

    st.frameNum = frame

    StepVoidScan()

    UpdateLoadGovernor(frame)

    local t0 = Spring.GetTimer()

    local checkInterval       = loadGov.effCheckInterval
    local threatInterval      = loadGov.effThreatInterval
    local isCheckFrame        = (frame % checkInterval == 0)
    local isThreatFrame       = (frame % threatInterval == 0)

    if isCheckFrame then
        UpdateMacroState(myTeam, units)
        ComputeStrategicPlan(frame)
    end

    if isThreatFrame then
        UpdateThreat(myTeam, units, frame)
        UpdateArmyCoordination(frame)
        UpdateDefenseCoordination(frame)
        CleanupAAThreats(frame)

        -- we don't want to lose data on a widget reload
        -- so then let's do this
        if WG then
            WG.MetalAIBaseCache = {
                gameID = GetGameID(),
                bases = st.enemyBases,
                enemyDefenses = st.enemyDefenses,
                army = {
                    state = st.army.state,
                    targetX = st.army.targetX,
                    targetY = st.army.targetY,
                    targetZ = st.army.targetZ,
                    targetKey = st.army.targetKey,
                    stateFrame = st.army.stateFrame,
                },
                scoutSectors = st.scoutSectors,
                factoryWaitState = st.factoryWaitState,
            }
        end

        local cutoffFrame = frame - 900
        for key, claim in pairs(st.claimedSpots) do
            if claim.frame < cutoffFrame and not claim.isFactory then
                st.claimedSpots[key] = nil
            end
        end
    end

    local maxUnitsPerFrame = cfg.LOAD_MAX_UNITS_PER_FRAME
    local processed = 0
    for i = 1, #units do
        local unitID = units[i]
        if (frame + unitID) % checkInterval == 0 then
            ProcessUnitOrders(unitID, frame)
            processed = processed + 1
            if processed >= maxUnitsPerFrame then break end
        end
    end

    -- print for diagnostics
    if frame % 900 == 0 then
        local fmt = "[MetalAI] state=%s target=(%s,%s) base=(%s,%s) combat=%d scouts=%d cons=%d facs=%d enemyRaiders=%d enemyBases=%d pendingMex=%d metal=%d/s energy=%d/s(pull=%d stor=%d) stall=%s%s unease=%d load=%.2fms/%.1fx"
        local tx, tz = st.army.targetX or -1, st.army.targetZ or -1
        local bx, bz = st.baseCenterX or -1, st.baseCenterZ or -1
        Spring.Echo(string.format(fmt,
            tostring(st.army.state), tostring(tx), tostring(tz), tostring(bx), tostring(bz),
            st.combatUnitCount or 0, st.scoutUnitCount or 0, st.conUnitCount or 0,
            st.myFactoriesCount or 0, st.raiderCount or 0,
            st.enemyBases and next(st.enemyBases) ~= nil and 1 or 0,
            st.unclaimedMexCount or 0,
            mFloor(st.metalIncome or 0),
            mFloor(st.energyIncome or 0), mFloor(st.energyPull or 0), mFloor(st.currentEnergyStorage or 0),
            (st.metalStalling and "M" or ""), (st.energyStalling and "E" or ""),
            st.unease or 0, loadGov.cpuMs, loadGov.scale))

        local td = st.turretDbg
        local probe = ""
        if td.probeTiles and td.probeTiles > 0 then
            probe = string.format(" tiles=%d(blk=%d inacc=%d ovl=%d test=%d exit=%d bnd=%d) ringOut=%d step=%d def=%s",
                td.probeTiles, td.probeBlocked, td.probeInacc, td.probeOverlap, td.probeTest, td.probeExit, td.probeBounds,
                td.lastRingOut or 0, td.lastSpacing or 0, td.lastDef or "?")
        end
        Spring.Echo(string.format(
            "[MetalAI] turret: consCanBuild=%d needRing=%d fired=%d placed=%d (noCon=%d noNeed=%d noAfford=%d noSpot=%d)%s",
            td.consWithTurret or 0, td.needTurrets or 0,
            td.fired or 0, td.placed or 0,
            td.noCon or 0, td.noNeed or 0, td.noAfford or 0, td.noSpot or 0, probe))
        td.fired, td.placed = 0, 0
        td.noCon, td.noNeed, td.noAfford, td.noSpot = 0, 0, 0, 0

        local ad = st.attackDbg
        if ad and (ad.issued > 0 or ad.groundCleared > 0) then
            Spring.Echo(string.format(
                "[MetalAI] attack: issued=%d air=%d ground=%d groundCleared=%d lastIssued=%s lastCleared=%s",
                ad.issued, ad.airIssued, ad.groundIssued, ad.groundCleared,
                ad.lastIssuedDef or "?", ad.lastGroundDef or "?"))
            ad.issued, ad.airIssued, ad.groundIssued = 0, 0, 0
            ad.groundCleared = 0
            ad.lastIssuedDef, ad.lastGroundDef = nil, nil
        end

        local ub = st.uneaseDbg
        if ub and ub.detected > 0 then
            Spring.Echo(string.format(
                "[MetalAI] unease: detected=%d fired=%d noCands=%d recalled=%d lastU=%d",
                ub.detected, ub.fired, ub.noCands, ub.recalled,
                ub.lastUnease))
            ub.detected, ub.fired = 0, 0
            ub.noCands, ub.recalled = 0, 0
            ub.lastUnease = 0
        end
    end

    local elapsedMs = Spring.DiffTimers(Spring.GetTimer(), t0) * 1000
    loadGov.cpuMs = loadGov.cpuMs + cfg.LOAD_EMA * (elapsedMs - loadGov.cpuMs)
end

function widget:SetConfigData(data)
    if data and type(data.active) == "boolean" then
        ui.active = data.active
    end
end

function widget:GetConfigData()
    return { active = ui.active }
end
