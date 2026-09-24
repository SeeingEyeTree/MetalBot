-- lab_controller.lua  ─  Factory queue manager with scout support
-- Labs with a defined LAB_QUEUES entry use a proportional build order that
-- loops forever. All other labs fall back to scout-first then generic combat
-- unit selection. BLACKLIST units are never built by any lab.
--
-- Changes from baseline:
--   SCOUT_TARGET 2→4: 8192×8192 map needs more scouts for timely threat detection.
--   Lab poll 60→30 frames: halves factory idle time between productions.
--   Stall guard softened: only skip when BOTH resources are critically stalled AND
--     metal < 20. Engine handles per-job resource pacing; skipping the queue push
--     entirely leaves the factory idle until the next poll cycle.
--   Vehicle plant: cormist 2→5 (AA), corraid 15→10. Baseline AA is mandatory
--     (game_mechanics §7.3); pure raider spam gets shut down by enemy air.
--   T2 bot lab: coraak 1→3 (AA), corsumo 2→1, cormort 10→9. Keeps 13 total
--     slots, raises AA fraction 8%→23%.

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

local SCOUT_TARGET = 4   -- was 2; 8192x8192 map needs more coverage

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

local LAB_QUEUES = {
    corvp = {        -- Vehicle Plant (T1)
        { name = "corraid",  count = 10 },   -- was 15; fewer pure raiders
        { name = "corgator", count = 10 },
        { name = "corlevlr", count =  5 },
        { name = "cormist",  count =  5 },   -- was 2; more AA/missiles
    },
    coralab = {      -- Advanced Bot Lab (T2)
        { name = "cormort",  count =  9 },   -- was 10
        { name = "corsumo",  count =  1 },   -- was 2; fewer expensive heavies
        { name = "coraak",   count =  3 },   -- was 1; more AA
    },
}

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID     = nil
local labs         = {}
local scoutCount   = 0
local myScouts     = {}
local labQueueData = {}

-- ── Queue generation ──────────────────────────────────────────────────────────

local function GenerateFlatQueue(spec, labDefID)
    local total = 0
    for _, entry in ipairs(spec) do total = total + entry.count end
    if total == 0 then return {} end

    local resolved = {}
    for _, entry in ipairs(spec) do
        local ud    = UnitDefNames and UnitDefNames[entry.name]
        local defID = ud and ud.id
        if defID then
            resolved[#resolved + 1] = { defID = defID, count = entry.count }
        else
            Spring.Echo("[LabCtrl] WARNING: unknown unit '" .. entry.name
                .. "' in queue for lab "
                .. (UnitDefs[labDefID] and UnitDefs[labDefID].name or tostring(labDefID)))
        end
    end
    if #resolved == 0 then return {} end

    total = 0
    for _, r in ipairs(resolved) do total = total + r.count end

    local accum    = {}
    local sequence = {}
    for i = 1, #resolved do accum[i] = 0 end

    for slot = 1, total do
        local bestIdx, bestVal = 1, -math.huge
        for i, r in ipairs(resolved) do
            accum[i] = accum[i] + r.count
            if accum[i] > bestVal then bestVal = accum[i]; bestIdx = i end
        end
        accum[bestIdx] = accum[bestIdx] - total
        sequence[slot] = resolved[bestIdx].defID
    end
    return sequence
end

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

local buildCache = {}

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

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    if DEBUG then Spring.Echo("[LabCtrl] Initialized team=" .. tostring(myTeamID)) end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d then return end

    if d.isFactory then
        labs[unitID] = unitDefID
        local labName = d.name or "?"
        if DEBUG then Spring.Echo("[LabCtrl] Lab registered id=" .. unitID .. " def=" .. labName) end

        local spec = LAB_QUEUES[labName]
        if spec then
            local seq = GenerateFlatQueue(spec, unitDefID)
            if #seq > 0 then
                labQueueData[unitID] = { sequence = seq, idx = 1 }
                if DEBUG then Spring.Echo("[LabCtrl] Using defined queue (" .. #seq .. " slots) for " .. labName) end
            end
        end
        return
    end

    if IsScoutDef(d) and not myScouts[unitID] then
        myScouts[unitID] = true
        scoutCount = scoutCount + 1
    end
end

function widget:UnitDestroyed(unitID)
    labs[unitID]        = nil
    labQueueData[unitID] = nil
    if myScouts[unitID] then
        myScouts[unitID] = nil
        scoutCount = math.max(0, scoutCount - 1)
    end
end

function widget:GameFrame(frame)
    if frame % 30 ~= 0 then return end   -- was 60; halves factory idle time
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

    -- Only skip when BOTH resources are critically stalled with nearly no metal.
    -- Previously skipped on either-stall + metal<50, leaving factories idle mid-stall.
    if metalStalling and energyStalling and metalCur < 20 then return end

    local needScout = scoutCount < SCOUT_TARGET

    for labID, labDefID in pairs(labs) do
        if spGetUnitDefID(labID) and QueueEmpty(labID) then
            local qdata  = labQueueData[labID]
            local choice = nil

            if qdata then
                choice    = qdata.sequence[qdata.idx]
                qdata.idx = (qdata.idx % #qdata.sequence) + 1
            else
                local cache = GetBuildCache(labDefID)

                if needScout and #cache.scouts > 0 then
                    choice = CheapestScout(cache.scouts)
                end
                if not choice and #cache.mobile > 0 then
                    choice = PickUnit(cache.mobile, metalCur)
                end
                if not choice and #cache.scouts > 0 then
                    choice = CheapestScout(cache.scouts)
                end
            end

            if choice then
                spGiveOrderToUnit(labID, -choice, {}, {})
                if DEBUG then
                    Spring.Echo("[LabCtrl] Queued "
                        .. (UnitDefs[choice] and UnitDefs[choice].name or "?")
                        .. " in lab " .. labID)
                end
            end
        end
    end
end
