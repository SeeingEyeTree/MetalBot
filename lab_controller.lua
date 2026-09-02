-- lab_controller.lua  ─  Factory queue manager with scout support
-- Queues scouts from air labs first to ensure map vision, then queues combat
-- units from all idle labs.
-- Compatible with macro_controller.lua: only acts when GetFactoryCommands is empty.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID       = Spring.GetUnitDefID
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spGetMyTeamID        = Spring.GetMyTeamID
local spGetFactoryCommands = Spring.GetFactoryCommands
local spGetUnitCommands    = Spring.GetUnitCommands
local spGetTeamResources   = Spring.GetTeamResources

local SCOUT_TARGET = 2   -- keep at least this many scouts alive

function widget:GetInfo()
    return {
        name    = "Lab Controller",
        desc    = "Queues scouts and combat units from idle labs (macro_controller compatible)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID   = nil
local labs       = {}   -- [labID] = labDefID
local scoutCount = 0    -- alive friendly scouts
local myScouts   = {}   -- [unitID] = true, scouts we counted

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Matches bot.lua's IsScoutDef: modCategory, category string, name keywords,
-- or fast unarmed unit.
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

local buildCache = {}   -- [labDefID] = { scouts={defID,...}, mobile={defID,...} }

local function GetBuildCache(labDefID)
    if buildCache[labDefID] then return buildCache[labDefID] end
    local d = UnitDefs[labDefID]
    local cache = { scouts = {}, mobile = {} }
    if d and d.buildOptions then
        for _, optID in ipairs(d.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.speed and od.speed > 0
               and not od.isBuilder and not od.isFactory then
                if IsScoutDef(od) then
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

-- Cost-weighted random pick; falls back to cheapest if nothing is affordable.
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

local function CheapestScout(scouts)
    local best, bestCost = nil, math.huge
    for _, optID in ipairs(scouts) do
        local cost = (UnitDefs[optID] and UnitDefs[optID].metalCost) or 0
        if cost < bestCost then bestCost = cost; best = optID end
    end
    return best
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    Spring.Echo("[LabCtrl] Initialized team=" .. tostring(myTeamID))
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d then return end
    if d.isFactory then
        labs[unitID] = unitDefID
        Spring.Echo("[LabCtrl] Lab registered id=" .. unitID .. " def=" .. (d.name or "?"))
        return
    end
    if IsScoutDef(d) and not myScouts[unitID] then
        myScouts[unitID] = true
        scoutCount = scoutCount + 1
    end
end

function widget:UnitDestroyed(unitID)
    labs[unitID] = nil
    if myScouts[unitID] then
        myScouts[unitID] = nil
        scoutCount = math.max(0, scoutCount - 1)
    end
end

function widget:GameFrame(frame)
    if frame % 60 ~= 0 then return end
    if not myTeamID then return end

    local ok,  metalCur, _, metalPull,  metalIncome  = pcall(spGetTeamResources, myTeamID, "metal")
    local okE, _,        _, energyPull, energyIncome = pcall(spGetTeamResources, myTeamID, "energy")

    metalCur     = (ok  and type(metalCur)     == "number") and metalCur     or 0
    metalPull    = (ok  and type(metalPull)    == "number") and metalPull    or 0
    metalIncome  = (ok  and type(metalIncome)  == "number") and metalIncome  or 0
    energyPull   = (okE and type(energyPull)   == "number") and energyPull   or 0
    energyIncome = (okE and type(energyIncome) == "number") and energyIncome or 0

    local metalStalling  = metalPull  > metalIncome  * 1.05
    local energyStalling = energyPull > energyIncome * 1.05
    if (metalStalling or energyStalling) and metalCur < 50 then return end

    local needScout = scoutCount < SCOUT_TARGET

    for labID, labDefID in pairs(labs) do
        if spGetUnitDefID(labID) and QueueEmpty(labID) then
            local cache = GetBuildCache(labDefID)
            local choice = nil

            -- Prioritise scouts when below target and this lab can make them.
            if needScout and #cache.scouts > 0 then
                choice = CheapestScout(cache.scouts)
            end

            -- Otherwise queue a combat unit.
            if not choice and #cache.mobile > 0 then
                choice = PickUnit(cache.mobile, metalCur)
            end

            -- Fallback: any scout if no mobile units exist (air lab only has scouts).
            if not choice and #cache.scouts > 0 then
                choice = CheapestScout(cache.scouts)
            end

            if choice then
                spGiveOrderToUnit(labID, -choice, {}, {})
                Spring.Echo("[LabCtrl] Queued "
                    .. (UnitDefs[choice] and UnitDefs[choice].name or "?")
                    .. " in lab " .. labID
                    .. (needScout and " (scout)" or ""))
            end
        end
    end
end
