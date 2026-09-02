-- unit_controller.lua  ─  Scout and combat unit manager for Beyond All Reason
-- Scouts explore the map by sector; combat units form up and attack known enemies.
-- Compatible with macro_controller.lua: does not touch builders, factories, or commanders.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID    = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitHealth   = Spring.GetUnitHealth
local spGetUnitCommands = Spring.GetUnitCommands
local spGetUnitAllyTeam = Spring.GetUnitAllyTeam
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID
local spGetGroundHeight = Spring.GetGroundHeight

local CMD_MOVE   = (CMD and CMD.MOVE)   or 10
local CMD_PATROL = (CMD and CMD.PATROL) or 15
local CMD_FIGHT  = (CMD and CMD.FIGHT)  or 16

local RETREAT_HP    = 0.15  -- retreat fraction
local ARMY_TRIGGER  = 5     -- idle combat units needed before launching an attack
local SECTOR_SIZE   = 1024  -- map divided into sectors this wide

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "Scout-led map exploration and army attack logic (macro_controller compatible)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID    = nil
local myAllyID    = nil
local combatUnits = {}   -- [unitID] = defID  (armed non-scouts)
local scoutUnits  = {}   -- [unitID] = defID  (scout units)
local baseX, baseZ       = nil, nil
local targetX, targetZ   = nil, nil   -- latest confirmed enemy position

-- Sector scouting grid
local scoutSectors  = {}   -- [key] = {x, z, lastScouted}
local scoutAssigned = {}   -- [unitID] = sectorKey  (current sector assignment)
local sectorsInited = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return d.customParams ~= nil
        and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
end

-- Mirrors lab_controller.lua / bot.lua IsScoutDef.
local function IsScoutDef(uDefID)
    local d = UnitDefs[uDefID]
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
    if string.find(name,  "scout")  or string.find(hName, "scout")
    or string.find(name,  "peep")   or string.find(name,  "flea")
    or string.find(name,  "fink")   or string.find(name,  "phantom")
    or string.find(name,  "weasel") or string.find(name,  "wheelie") then
        return true
    end
    return d.speed and d.speed > 150 and (not d.weapons or #d.weapons == 0)
end

local function IsIdle(unitID)
    local cmds = spGetUnitCommands(unitID, 1)
    return not cmds or #cmds == 0
end

-- ── Sector grid ───────────────────────────────────────────────────────────────

local function InitSectors()
    if sectorsInited then return end
    sectorsInited = true
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    for sx = 0, mapX - 1, SECTOR_SIZE do
        for sz = 0, mapZ - 1, SECTOR_SIZE do
            local key = sx .. "_" .. sz
            scoutSectors[key] = {
                x           = sx + SECTOR_SIZE * 0.5,
                z           = sz + SECTOR_SIZE * 0.5,
                lastScouted = 0,
            }
        end
    end
end

-- Mark sectors containing a scout as recently scouted.
local function UpdateScoutedSectors(frame)
    for unitID in pairs(scoutUnits) do
        if spGetUnitDefID(unitID) then
            local ux, _, uz = spGetUnitPosition(unitID)
            if ux then
                local sx  = math.floor(ux / SECTOR_SIZE) * SECTOR_SIZE
                local sz  = math.floor(uz / SECTOR_SIZE) * SECTOR_SIZE
                local key = sx .. "_" .. sz
                if scoutSectors[key] then
                    scoutSectors[key].lastScouted = frame
                end
            end
        end
    end
end

-- Score-based sector picker: prioritises stale sectors on the enemy half of map.
local function PickScoutSector(unitID, frame)
    local ux, _, uz = spGetUnitPosition(unitID)
    if not ux then return nil, nil end

    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local mapCX, mapCZ = mapX * 0.5, mapZ * 0.5

    -- Axis from our base toward map center (proxy for "toward the enemy").
    local axisX, axisZ = 0, 0
    if baseX and baseZ then
        local dx, dz = mapCX - baseX, mapCZ - baseZ
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 1 then axisX, axisZ = dx / len, dz / len end
    end

    -- Collect sectors already assigned to other scouts.
    local assigned = {}
    for uid, key in pairs(scoutAssigned) do
        if uid ~= unitID then assigned[key] = true end
    end

    local bestScore, bestSector, bestKey = -math.huge, nil, nil
    for key, sector in pairs(scoutSectors) do
        if not assigned[key] then
            local dx, dz = sector.x - ux, sector.z - uz
            local dist    = math.sqrt(dx * dx + dz * dz) + 1
            local staleness = frame - sector.lastScouted

            -- Boost sectors on the enemy side of the map.
            local sdx, sdz   = sector.x - mapCX, sector.z - mapCZ
            local frontBoost = 1 + math.max(0, sdx * axisX + sdz * axisZ) * 0.001

            local score = staleness * staleness * frontBoost / dist
            if score > bestScore then
                bestScore  = score
                bestSector = sector
                bestKey    = key
            end
        end
    end
    return bestSector, bestKey
end

-- ── Enemy scanning ────────────────────────────────────────────────────────────

local function UpdateEnemyTarget()
    local allUnits = Spring.GetAllUnits and Spring.GetAllUnits()
    if not allUnits or not myAllyID then return end
    for _, uid in ipairs(allUnits) do
        local allyID = spGetUnitAllyTeam and spGetUnitAllyTeam(uid)
        if allyID and allyID ~= myAllyID then
            local ex, _, ez = spGetUnitPosition(uid)
            if ex then
                if not targetX then
                    Spring.Echo("[UnitCtrl] Enemy spotted at "
                        .. math.floor(ex) .. "," .. math.floor(ez))
                end
                targetX, targetZ = ex, ez
                return
            end
        end
    end
end

-- ── Default march direction ───────────────────────────────────────────────────

local function DefaultTarget()
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    if baseX and baseZ then
        local tx = baseX < mapX * 0.5 and mapX * 0.8 or mapX * 0.2
        local tz = baseZ < mapZ * 0.5 and mapZ * 0.8 or mapZ * 0.2
        return tx, tz
    end
    return mapX * 0.5, mapZ * 0.5
end

-- ── Scout assignment ──────────────────────────────────────────────────────────

local function AssignScouts(frame)
    for unitID in pairs(scoutUnits) do
        if spGetUnitDefID(unitID) then
            local assignedKey = scoutAssigned[unitID]

            -- Clear assignment if the sector was recently scouted (scout arrived).
            if assignedKey and scoutSectors[assignedKey] then
                if frame - scoutSectors[assignedKey].lastScouted < 300 then
                    scoutAssigned[unitID] = nil
                    assignedKey = nil
                end
            end

            if IsIdle(unitID) or not assignedKey then
                local sector, key = PickScoutSector(unitID, frame)
                if sector then
                    local ty = spGetGroundHeight(sector.x, sector.z) or 0
                    spGiveOrderToUnit(unitID, CMD_PATROL, {sector.x, ty, sector.z}, {})
                    scoutAssigned[unitID] = key
                    -- Tentatively mark so other scouts don't pile into the same sector.
                    sector.lastScouted = frame - (SECTOR_SIZE * 2)
                end
            end
        end
    end
end

-- ── Army attack ───────────────────────────────────────────────────────────────

local function IssueArmyOrders(frame)
    if not targetX then return end

    local idleUnits = {}
    for unitID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) and IsIdle(unitID) then
            idleUnits[#idleUnits + 1] = unitID
        end
    end
    if #idleUnits < ARMY_TRIGGER then return end

    local ty = spGetGroundHeight(targetX, targetZ) or 0
    for _, unitID in ipairs(idleUnits) do
        spGiveOrderToUnit(unitID, CMD_FIGHT, {targetX, ty, targetZ}, {})
    end
    Spring.Echo("[UnitCtrl] Army attack: " .. #idleUnits .. " units -> "
        .. math.floor(targetX) .. "," .. math.floor(targetZ))
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    Spring.Echo("[UnitCtrl] Initialized team=" .. tostring(myTeamID))
end

function widget:UnitCreated(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if IsCommander(unitDefID) and not baseX then
        local x, _, z = spGetUnitPosition(unitID)
        if x then baseX, baseZ = x, z end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d or d.isFactory or d.isBuilder then return end
    if not d.speed or d.speed <= 0 then return end

    if IsCommander(unitDefID) then
        if not baseX then
            local x, _, z = spGetUnitPosition(unitID)
            if x then baseX, baseZ = x, z end
        end
        return
    end

    if IsScoutDef(unitDefID) then
        scoutUnits[unitID] = unitDefID
    elseif d.weapons and #d.weapons > 0 then
        combatUnits[unitID] = unitDefID
    end
end

function widget:UnitDestroyed(unitID)
    combatUnits[unitID]   = nil
    scoutUnits[unitID]    = nil
    scoutAssigned[unitID] = nil
end

function widget:GameFrame(frame)
    InitSectors()

    -- Scan visible units for enemies and update scouted sectors (~every 5s).
    if frame % 150 == 0 then
        UpdateEnemyTarget()
        UpdateScoutedSectors(frame)
    end

    -- Assign scouts to unexplored sectors (~every 2s).
    if frame % 60 == 0 then
        AssignScouts(frame)
    end

    -- Combat unit orders (~every 1s).
    if frame % 30 ~= 0 then return end
    if not myTeamID then return end

    -- Try to send the army if we have enough units and a target.
    IssueArmyOrders(frame)

    -- Any remaining idle combat units patrol toward the best known target.
    local tx, tz
    if targetX then tx, tz = targetX, targetZ
    else            tx, tz = DefaultTarget() end

    for unitID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) and IsIdle(unitID) then
            local ux, _, uz = spGetUnitPosition(unitID)
            if ux then
                local hp, maxHP = spGetUnitHealth(unitID)
                if hp and maxHP and (hp / maxHP) < RETREAT_HP and baseX then
                    local wy = spGetGroundHeight(baseX, baseZ) or 0
                    spGiveOrderToUnit(unitID, CMD_MOVE, {baseX, wy, baseZ}, {})
                else
                    local ty = spGetGroundHeight(tx, tz) or 0
                    spGiveOrderToUnit(unitID, CMD_PATROL, {tx, ty, tz}, {})
                end
            end
        end
    end
end
