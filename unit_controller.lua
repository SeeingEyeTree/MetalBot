-- unit_controller.lua  ─  Simple idle combat unit manager for Beyond All Reason
-- Gives idle combat units patrol orders toward known enemy positions,
-- or toward the opposite side of the map when no enemy is visible.
-- Retreats low-health units toward the base.
-- Compatible with wise_eclipse.lua: does not touch builders, factories, or commanders.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID    = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitHealth   = Spring.GetUnitHealth
local spGetUnitCommands = Spring.GetUnitCommands
local spGetUnitTeam     = Spring.GetUnitTeam
local spGetUnitAllyTeam = Spring.GetUnitAllyTeam
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID
local spGetGroundHeight = Spring.GetGroundHeight

local CMD_MOVE   = (CMD and CMD.MOVE)   or 10
local CMD_PATROL = (CMD and CMD.PATROL) or 15

local RETREAT_HP  = 0.15  -- retreat when HP falls below this fraction of max

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "Basic idle combat unit patrol/retreat (compatible with wise_eclipse)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID  = nil
local myAllyID  = nil
local combatUnits = {}  -- [unitID] = defID
local baseX, baseZ = nil, nil   -- fallback retreat position
local targetX, targetZ = nil, nil  -- latest known enemy position

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return d.customParams ~= nil
        and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
end

local function IsCombatUnit(uDefID)
    local d = UnitDefs[uDefID]
    return d
        and not d.isFactory
        and not d.isBuilder
        and d.speed  and d.speed  > 0
        and d.weapons and #d.weapons > 0
        and not IsCommander(uDefID)
end

local function IsIdle(unitID)
    local cmds = spGetUnitCommands(unitID, 1)
    return not cmds or #cmds == 0
end

-- Scan all visible units to find a fresh enemy position.
local function UpdateEnemyTarget()
    local allUnits = Spring.GetAllUnits and Spring.GetAllUnits()
    if not allUnits or not myAllyID then return end
    for _, uid in ipairs(allUnits) do
        local allyID = spGetUnitAllyTeam and spGetUnitAllyTeam(uid)
        if allyID and allyID ~= myAllyID then
            local ex, _, ez = spGetUnitPosition(uid)
            if ex then
                targetX, targetZ = ex, ez
                return
            end
        end
    end
end

-- Default march target: opposite side of map from our base.
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

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
    Spring.Echo("[UnitCtrl] Initialized team=" .. tostring(myTeamID))
end

function widget:UnitCreated(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    -- Record commander spawn position as the base reference on first contact.
    if IsCommander(unitDefID) and not baseX then
        local x, _, z = spGetUnitPosition(unitID)
        if x then baseX, baseZ = x, z end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if IsCombatUnit(unitDefID) then
        combatUnits[unitID] = unitDefID
    end
    -- Also capture base position from finished commander if UnitCreated was missed.
    if IsCommander(unitDefID) and not baseX then
        local x, _, z = spGetUnitPosition(unitID)
        if x then baseX, baseZ = x, z end
    end
end

function widget:UnitDestroyed(unitID)
    combatUnits[unitID] = nil
end

function widget:GameFrame(frame)
    -- Refresh enemy target every ~5 seconds.
    if frame % 150 == 0 then
        UpdateEnemyTarget()
    end

    -- Order idle units every ~1 second.
    if frame % 30 ~= 0 then return end
    if not myTeamID then return end

    local tx, tz
    if targetX then
        tx, tz = targetX, targetZ
    else
        tx, tz = DefaultTarget()
    end

    for unitID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) and IsIdle(unitID) then
            local ux, _, uz = spGetUnitPosition(unitID)
            if ux then
                local hp, maxHP = spGetUnitHealth(unitID)
                if hp and maxHP and (hp / maxHP) < RETREAT_HP and baseX then
                    -- Retreat toward base.
                    local wy = spGetGroundHeight(baseX, baseZ) or 0
                    spGiveOrderToUnit(unitID, CMD_MOVE, {baseX, wy, baseZ}, {})
                else
                    -- Patrol toward the march target.
                    local ty = spGetGroundHeight(tx, tz) or 0
                    spGiveOrderToUnit(unitID, CMD_PATROL, {tx, ty, tz}, {})
                end
            end
        end
    end
end
