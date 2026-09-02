-- lab_controller.lua  ─  Simple factory queue manager for Beyond All Reason
-- Queues combat units from any idle friendly lab.
-- Compatible with wise_eclipse.lua: only acts when the factory queue is empty,
-- so wise_eclipse's explicit con-bot and air-con orders always take priority.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID        = Spring.GetUnitDefID
local spGiveOrderToUnit     = Spring.GiveOrderToUnit
local spGetMyTeamID         = Spring.GetMyTeamID
local spGetFactoryCommands  = Spring.GetFactoryCommands
local spGetUnitCommands     = Spring.GetUnitCommands
local spGetTeamResources    = Spring.GetTeamResources
local spGetGroundHeight     = Spring.GetGroundHeight

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "Queues combat units from idle labs (compatible with wise_eclipse)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID = nil
local labs     = {}  -- [labID] = labDefID

-- ── Helpers ───────────────────────────────────────────────────────────────────

local combatCache = {}  -- [labDefID] = {optID, ...}

local function GetCombatOptions(labDefID)
    if combatCache[labDefID] then return combatCache[labDefID] end
    local d = UnitDefs[labDefID]
    local result = {}
    if d and d.buildOptions then
        for _, optID in ipairs(d.buildOptions) do
            local od = UnitDefs[optID]
            if od
               and od.speed  and od.speed  > 0
               and od.weapons and #od.weapons > 0
               and not od.isBuilder
               and not od.isFactory then
                result[#result + 1] = optID
            end
        end
    end
    combatCache[labDefID] = result
    return result
end

local function QueueEmpty(labID)
    if spGetFactoryCommands then
        local cmds = spGetFactoryCommands(labID, -1)
        return not cmds or #cmds == 0
    end
    local cmds = spGetUnitCommands(labID, -1)
    return not cmds or #cmds == 0
end

-- Cost-weighted random pick, capped so the priciest unit doesn't always win.
local function PickUnit(options, metalCur)
    local CAP = 500  -- metal cap for weighting
    local totalWeight = 0
    local affordable  = {}
    for _, optID in ipairs(options) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        if cost <= metalCur then
            affordable[#affordable + 1] = optID
            totalWeight = totalWeight + math.sqrt(math.min(cost, CAP) + 1)
        end
    end
    if #affordable == 0 then
        -- Can't afford anything yet; queue the cheapest and let the factory wait.
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

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    Spring.Echo("[LabCtrl] Initialized team=" .. tostring(myTeamID))
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if d and d.isFactory then
        labs[unitID] = unitDefID
        Spring.Echo("[LabCtrl] Lab registered id=" .. unitID
            .. " def=" .. (d.name or "?"))
    end
end

function widget:UnitDestroyed(unitID)
    labs[unitID] = nil
end

function widget:GameFrame(frame)
    if frame % 60 ~= 0 then return end
    if not myTeamID then return end

    local ok, metalCur, _, metalPull, metalIncome =
        pcall(spGetTeamResources, myTeamID, "metal")
    local okE, _, _, energyPull, energyIncome =
        pcall(spGetTeamResources, myTeamID, "energy")

    metalCur    = (ok  and type(metalCur)    == "number") and metalCur    or 0
    metalPull   = (ok  and type(metalPull)   == "number") and metalPull   or 0
    metalIncome = (ok  and type(metalIncome) == "number") and metalIncome or 0
    energyPull  = (okE and type(energyPull)  == "number") and energyPull  or 0
    energyIncome= (okE and type(energyIncome)== "number") and energyIncome or 0

    local metalStalling  = metalPull  > metalIncome  * 1.05
    local energyStalling = energyPull > energyIncome * 1.05

    -- Skip queuing while heavily stalling (but allow 1 unit if economy is totally dead).
    if (metalStalling or energyStalling) and metalCur < 50 then return end

    for labID, labDefID in pairs(labs) do
        if spGetUnitDefID(labID) and QueueEmpty(labID) then
            local options = GetCombatOptions(labDefID)
            if #options > 0 then
                local choice = PickUnit(options, metalCur)
                if choice then
                    spGiveOrderToUnit(labID, -choice, {}, {})
                    Spring.Echo("[LabCtrl] Queued "
                        .. (UnitDefs[choice] and UnitDefs[choice].name or "?")
                        .. " in lab " .. labID)
                end
            end
        end
    end
end
