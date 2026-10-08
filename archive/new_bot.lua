-- new_bot.lua  ─  early-game opening for Beyond All Reason
-- Handles the first few minutes: starting blueprint, bot-lab con bot,
-- and three air cons building mex/energy grids.
-- Supports both ARM and COR; faction auto-detected from the commander.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID
local spGetTeamUnits    = Spring.GetTeamUnits
local spGetGroundHeight = Spring.GetGroundHeight
local spGetUnitTeam     = Spring.GetUnitTeam

local CMD_GUARD = (CMD and CMD.GUARD) or 25

function widget:GetInfo()
    return {
        name    = "Early Bot",
        desc    = "Automated early-game build order (first few minutes)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── Faction translation ───────────────────────────────────────────────────────
-- Blueprint data uses COR unit names. For ARM we do a simple cor→arm prefix
-- swap; every unit in the starting blueprint follows this pattern exactly.
local function Translate(corName, fac)
    if fac ~= "arm" then return corName end
    if corName:sub(1, 3) == "cor" then return "arm" .. corName:sub(4) end
    return corName
end

-- ── Unit-type helpers (ported from MetalBot bot.lua) ─────────────────────────

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

-- Commander: uses the same customParams check as MetalBot.
local function IsCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return (d.customParams and
            (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil))
        or (d.name and sFind(sLower(d.name), "commander") ~= nil)
end

-- Cheapest mobile non-flying builder in a factory's build options → con bot.
local function FindConBotDefID(labDefID)
    local d = UnitDefs[labDefID]
    if not d or not d.buildOptions then return nil end
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(d.buildOptions) do
        local od = UnitDefs[optID]
        if od and od.isBuilder and not od.canFly and not od.isFactory
                and od.speed and od.speed > 0 then
            local cost = od.metalCost or 999999
            if cost < bestCost then bestCost = cost; best = optID end
        end
    end
    return best
end

-- First flying builder in a factory's build options → air constructor.
local function FindAirConDefID(labDefID)
    local d = UnitDefs[labDefID]
    if not d or not d.buildOptions then return nil end
    for _, optID in ipairs(d.buildOptions) do
        local od = UnitDefs[optID]
        if od and od.isBuilder and od.canFly and not od.isFactory then
            return optID
        end
    end
    return nil
end

local function DefID(name)
    local ud = UnitDefNames[name]
    return ud and ud.id
end

local function UnitName(unitID)
    local defID = spGetUnitDefID(unitID)
    if not defID then return nil end
    return UnitDefs[defID] and UnitDefs[defID].name
end

-- ── Starting blueprint (blueprints.json entry 9, the last one) ───────────────
-- x/z are offsets from the commander's spawn position.
-- Entries with nano=true are skipped by the commander; the con bot builds them.
local START_BP = {
    -- Bot lab and air plant (commander queues these first)
    {n="corwin",    x= 144, z= 216, f=1},
    {n="corwin",    x=  96, z= 216, f=1},
    {n="cormex",    x=  72, z= 160, f=1},
    {n="cormex",    x= 136, z= 160, f=1},
    
    {n="corlab",    x= 216, z=  96, f=1},
    {n="corap",     x= 112, z=-128, f=0},
    -- Metal extractors

    {n="cormex",    x=  72, z=  96, f=1},
    {n="cormex",    x= 136, z=  96, f=1},
    {n="cormex",    x= 136, z= -32, f=1},
    {n="cormex",    x= 136, z=  32, f=1},
    {n="cormex",    x=  72, z=  32, f=1},
    {n="cormex",    x=  72, z= -32, f=1},
    {n="cormex",    x=-184, z= 112, f=1},
    {n="cormex",    x=-120, z= 112, f=1},
    {n="cormex",    x=-120, z= -80, f=1},
    {n="cormex",    x=-184, z=  48, f=1},
    {n="cormex",    x=-184, z= -80, f=1},
    {n="cormex",    x=-184, z=-144, f=1},
    {n="cormex",    x=-120, z= -16, f=1},
    {n="cormex",    x=-120, z=  48, f=1},
    {n="cormex",    x=-120, z=-144, f=1},
    {n="cormex",    x=-184, z= -16, f=1},
    -- Wind generators

    {n="corwin",    x=   0, z= 168, f=1},
    {n="corwin",    x=   0, z= 120, f=1},
    {n="corwin",    x= -48, z= 120, f=1},
    {n="corwin",    x= -48, z= 168, f=1},
    {n="corwin",    x= -48, z= -72, f=1},
    {n="corwin",    x=   0, z=  72, f=1},
    {n="corwin",    x= -48, z=  72, f=1},
    {n="corwin",    x=   0, z=  24, f=1},
    {n="corwin",    x= -48, z=  24, f=1},
    {n="corwin",    x=   0, z= -24, f=1},
    {n="corwin",    x= -48, z= -24, f=1},
    {n="corwin",    x=   0, z= -72, f=1},
    {n="corwin",    x=   0, z=-168, f=1},
    {n="corwin",    x= -48, z=-120, f=1},
    {n="corwin",    x=   0, z=-120, f=1},
    {n="corwin",    x= -48, z=-168, f=1},
    -- Energy storage
    {n="corestor",  x=-168, z= 176, f=1},
    -- Nano turrets: con bot builds these (commander cannot build nanotc)
    {n="cornanotc", x= 192, z= 216, f=1, nano=true},
    {n="cornanotc", x= -48, z= 216, f=1, nano=true},
    {n="cornanotc", x=   0, z= 216, f=1, nano=true},
    {n="cornanotc", x=-240, z= 216, f=1, nano=true},
    {n="cornanotc", x=-240, z=  24, f=1, nano=true},
    {n="cornanotc", x=-240, z= -24, f=1, nano=true},
    {n="cornanotc", x=-240, z=-216, f=1, nano=true},
    {n="cornanotc", x=   0, z=-216, f=1, nano=true},
    {n="cornanotc", x= -48, z=-216, f=1, nano=true},
    {n="cornanotc", x= 192, z=-216, f=1, nano=true},
    {n="cornanotc", x= 192, z= -24, f=1, nano=true},
    {n="cornanotc", x= 192, z=  24, f=1, nano=true},
}

-- ── Grid anchor offsets from commander spawn ──────────────────────────────────
-- Tune these per map. Each mexGrid tile is ~432×432 units wide.
-- Positive x = east, positive z = south in most BAR maps.
local MEX_GRID_1  = {x =  500, z =    0}
local MEX_GRID_2  = {x = -500, z =    0}
local ENERGY_GRID = {x =    0, z = -500}

-- ── State ─────────────────────────────────────────────────────────────────────
local myTeamID    = nil
local faction     = nil   -- "cor" or "arm"
local commanderID = nil
local baseX, baseZ = nil, nil

-- Translated unit names (set once faction is known)

local botLabID  = nil
local airLabID  = nil
local conBotID  = nil
local airCons   = {}   -- IDs of air constructors as they exit the air lab

local nanotcQueue    = {}   -- {defID, x, y, z, f} for each starting nano
local bpQueued       = false
local conBotQueued   = false
local airConQueued   = false
local conBotAssigned = false
local gridAssigned   = false

local BP = nil   -- grid blueprint data loaded from blueprints_data.lua

local function GiveBuild(unitID, defID, x, y, z, facing, shift)
    spGiveOrderToUnit(unitID, -defID, {x, y, z, facing}, shift and {"shift"} or {})
end

-- ── Starting blueprint ────────────────────────────────────────────────────────

local function QueueStartBlueprint()
    local cx, _, cz = spGetUnitPosition(commanderID)
    if not cx then return end
    baseX, baseZ = cx, cz
    nanotcQueue  = {}

    local first = true
    for _, e in ipairs(START_BP) do
        local name  = Translate(e.n, faction)
        local bx    = baseX + e.x
        local bz    = baseZ + e.z
        local by    = spGetGroundHeight(bx, bz)
        local defID = DefID(name)
        if defID then
            if e.nano then
                nanotcQueue[#nanotcQueue + 1] = {defID=defID, x=bx, y=by, z=bz, f=e.f}
            else
                GiveBuild(commanderID, defID, bx, by, bz, e.f, not first)
                first = false
            end
        end
    end
    bpQueued = true
end

-- ── Con bot nano build ────────────────────────────────────────────────────────

local function QueueConBotNanotcs()
    if #nanotcQueue == 0 then return end
    for i, nb in ipairs(nanotcQueue) do
        GiveBuild(conBotID, nb.defID, nb.x, nb.y, nb.z, nb.f, i > 1)
    end
    -- Commander guards the con bot so it assists each nano as it builds.
    -- The guard order is appended (shift) so the commander finishes its own
    -- build queue first, then follows and assists the con bot.
    if commanderID then
        spGiveOrderToUnit(commanderID, CMD_GUARD, {conBotID}, {"shift"})
    end
    conBotAssigned = true
end

-- ── Grid build ────────────────────────────────────────────────────────────────

-- Reorder a blueprint so all mexes are built first, then other buildings,
-- then nano turrets. The con bot handles the nanos last after getting metal flowing.
local function SortMexFirst(bp)
    local mexes, others, nanos = {}, {}, {}
    for _, e in ipairs(bp) do
        local n = e.n
        if n == "cormex" or n == "armmex" then
            mexes[#mexes+1] = e
        elseif n == "cornanotc" or n == "armnanotc" then
            nanos[#nanos+1] = e
        else
            others[#others+1] = e
        end
    end
    local result = {}
    for _, e in ipairs(mexes)  do result[#result+1] = e end
    for _, e in ipairs(others) do result[#result+1] = e end
    for _, e in ipairs(nanos)  do result[#result+1] = e end
    return result
end

local function QueueGridBuild(unitID, bp, ax, az)
    local sorted = SortMexFirst(bp)
    for i, e in ipairs(sorted) do
        local name  = Translate(e.n, faction)
        local bx    = ax + e.x
        local bz    = az + e.z
        local by    = spGetGroundHeight(bx, bz)
        local defID = DefID(name)
        if defID then
            GiveBuild(unitID, defID, bx, by, bz, e.f, i > 1)
        end
    end
end

local function AssignGrids()
    if gridAssigned or not BP or #airCons < 3 then return end
    QueueGridBuild(airCons[1], BP.mexGrid,    baseX + MEX_GRID_1.x,  baseZ + MEX_GRID_1.z)
    QueueGridBuild(airCons[2], BP.mexGrid,    baseX + MEX_GRID_2.x,  baseZ + MEX_GRID_2.z)
    QueueGridBuild(airCons[3], BP.energyGrid, baseX + ENERGY_GRID.x, baseZ + ENERGY_GRID.z)
    gridAssigned = true
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    BP = VFS.Include("LuaUI/Widgets/blueprints_data.lua")
end

function widget:GameStart()
    myTeamID = spGetMyTeamID()
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if not myTeamID then myTeamID = spGetMyTeamID() end
    if teamID ~= myTeamID then return end

    -- Commander detected using the same customParams check as MetalBot.
    -- Faction is read from the unit name prefix ("cor" or "arm").
    if IsCommander(unitDefID) and not bpQueued then
        commanderID = unitID
        local d = UnitDefs[unitDefID]
        faction = d and d.name and d.name:sub(1, 3) or "cor"
        QueueStartBlueprint()
        return
    end

    if not faction then return end

    -- Factories: detect bot lab (ground) and air lab (flying build options).
    local d = unitDefID and UnitDefs[unitDefID]
    if d and d.isFactory then
        if IsAirFactory(unitDefID) and not airLabID then
            airLabID = unitID
        elseif not IsAirFactory(unitDefID) and not botLabID then
            botLabID = unitID
        end
        return
    end

    -- Mobile builder exits bot lab → assign nano queue
    if builderID == botLabID and not conBotAssigned
            and d and d.isBuilder and not d.canFly and not d.isFactory then
        conBotID = unitID
        QueueConBotNanotcs()
        return
    end

    -- Flying builder exits air lab → collect; assign grids when we have 3
    if builderID == airLabID
            and d and d.isBuilder and d.canFly and not d.isFactory then
        airCons[#airCons + 1] = unitID
        if #airCons >= 3 then
            AssignGrids()
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID or not faction then return end

    -- Bot lab done → queue one con bot (cheapest mobile ground builder)
    if unitID == botLabID and not conBotQueued then
        local defID = FindConBotDefID(unitDefID)
        if defID then
            spGiveOrderToUnit(botLabID, -defID, {0}, {})
            conBotQueued = true
        end

    -- Air lab done → queue three air constructors (first flying builder)
    elseif unitID == airLabID and not airConQueued then
        local defID = FindAirConDefID(unitDefID)
        if defID then
            spGiveOrderToUnit(airLabID, -defID, {0}, {})
            spGiveOrderToUnit(airLabID, -defID, {0}, {"shift"})
            spGiveOrderToUnit(airLabID, -defID, {0}, {"shift"})
            airConQueued = true
        end
    end
end
