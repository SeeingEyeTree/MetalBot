-- macro_controller.lua  ─  mex-grid scaling bot for Beyond All Reason
-- Commander builds com_starter; bot lab makes 2 con bots (nanos + bot_starter);
-- air lab expands mex_grids outward using blueprint_placer (one air con per grid).
-- COR only. Expansion blocked east of the bot_starter column.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetMyTeamID     = Spring.GetMyTeamID
local spGetGroundHeight = Spring.GetGroundHeight

local CMD_GUARD  = (CMD and CMD.GUARD)  or 25
local CMD_REPAIR = (CMD and CMD.REPAIR) or 40
local CMD_STOP   = 0

function widget:GetInfo()
    return {
        name    = "Macro Controller",
        desc    = "Mex-scaling bot using blueprint_placer (COR)",
        author  = "",
        date    = "2026",
        license = "GNU GPL, v3 or later",
        layer   = 0,
        enabled = true
    }
end

-- ── Blueprints and placer (loaded in Initialize) ──────────────────────────────
local BP_PLACER      = nil
local COM_STARTER    = nil
local BOT_STARTER    = nil
local MEX_GRID_BP    = nil
local EMPTY_GRID_BP  = nil
local VECH_BOT_T2_BP = nil

-- ── State ─────────────────────────────────────────────────────────────────────
local myTeamID    = nil
local commanderID = nil
local baseX, baseZ = nil, nil
local GRID_SPACING = nil   -- assigned from BP_PLACER after Initialize

local botLabID    = nil
local airLabID    = nil

local conBot1ID       = nil   -- first con bot (builds perimeter nanos)
local conBot2ID       = nil   -- second con bot (builds bot_starter)
local conBot3ID       = nil   -- third con bot (builds VechT1_and_BotT2 north of bot_starter)
local conBot4ID       = nil   -- fourth con bot (builds VechT1_and_BotT2 south of bot_starter)
local conBotsQueued   = false
local prodBotsQueued  = false
local conBot1Assigned = false
local conBot2Assigned = false
local conBot3Assigned = false
local conBot4Assigned = false

local emptyGridState  = nil   -- con bot 1 builds perimeter nanos
local botStarterState = nil
local prodStates      = {}    -- VechT1_and_BotT2 placer states
local gridStates      = {}    -- active mex_grid placer states

-- Grid expansion
local completedAnchors    = {}   -- {anchorX,anchorZ} list for FindAllValidPlacements
local completedAnchorKeys = {}   -- "ax,az" set for dedup (prevents double-add)
local assignedAnchors     = {}   -- "ax,az" keys for all assigned grids (prevents double-assign)
local pendingPlacements   = {}   -- {blueprint,anchorX,anchorZ,rotation,stateList,onComplete} for special blueprints (energy grids etc.)
local pendingMexPlacements = {}  -- internal: {anchorX,anchorZ,rotation} mex grid positions waiting for an air con
local freeAirCons         = {}   -- air con IDs that have exited the lab but need assignment
local airConsQueued       = false
local labBuilders         = {}   -- labID -> builderID, cleared after lab finishes
local pendingStops        = {}   -- {unitID, fireFrame} deferred CMD_STOP orders
local currentFrame        = 0

-- Energy grid state
local ENERGY_T1_GRID_BP   = nil
local eGridStates         = {}   -- active energy grid placer states
local eGridAssignedKeys   = {}   -- anchor keys already assigned (prevents duplicates)
local completedEGridCount = 0
local eGridsPlaced        = 0    -- total energy grid anchors generated (for position step)
local firstTwoMexDone     = false
local target_e_grid       = 1
local energyStallFrames   = 0    -- consecutive frames energy demand > production
local e_avg_demand        = 0    -- exponential moving average of energy demand
local e_avg_prod          = 0    -- exponential moving average of energy production


-- ── Helpers ───────────────────────────────────────────────────────────────────

local function DefID(name)
    local ud = UnitDefNames[name]
    return ud and ud.id
end

local function GiveBuild(unitID, defID, x, y, z, facing, shift)
    spGiveOrderToUnit(unitID, -defID, {x, y, z, facing}, shift and {} or {})
end

local function IsCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return d.customParams ~= nil
        and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
end

local airFactoryCache = {}
local function IsAirFactory(uDefID)
    if not uDefID then return false end
    if airFactoryCache[uDefID] ~= nil then return airFactoryCache[uDefID] end
    local d = UnitDefs[uDefID]
    local result = false
    if d and d.isFactory and d.buildOptions and #d.buildOptions > 0 then
        local total, airCount = 0, 0
        for _, optID in ipairs(d.buildOptions) do
            local bd = UnitDefs[optID]
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

-- Mirrors blueprint_placer internal (not exported from that module).
local function RotateOffset(x, z, r)
    if     r == 0 then return  x,  z
    elseif r == 1 then return -z,  x
    elseif r == 2 then return -x, -z
    elseif r == 3 then return  z, -x
    end
    return x, z
end

-- Return the rotation (0–3) that places bp's corrl on the side facing the existing grid.
-- dx = new_anchor_x - existing_anchor_x, dz = new_anchor_z - existing_anchor_z.
-- (Matches the sign convention used in blueprint_placer.FindValidPlacement.)
local function FindCorrlRotation(bp, dx, dz)
    local corrX, corrZ
    for _, u in ipairs(bp.layout) do
        if u.n == "corrl" then corrX, corrZ = u.x, u.z; break end
    end
    if not corrX then return 0 end
    for r = 0, 3 do
        local rcx, rcz = RotateOffset(corrX, corrZ, r)
        -- corrl must be on the side facing the existing grid (opposite of dx/dz).
        local ok = (dx > 0 and rcx < 0)   -- new is east,  corrl faces west
                or (dx < 0 and rcx > 0)   -- new is west,  corrl faces east
                or (dz > 0 and rcz < 0)   -- new is south, corrl faces north
                or (dz < 0 and rcz > 0)   -- new is north, corrl faces south
        if ok then return r end
    end
    return 0
end

local function AnchorKey(ax, az)
    return tostring(ax) .. "," .. tostring(az)
end

local function AddCompletedAnchor(ax, az)
    local key = AnchorKey(ax, az)
    if not completedAnchorKeys[key] then
        completedAnchorKeys[key] = true
        completedAnchors[#completedAnchors + 1] = {anchorX = ax, anchorZ = az}
    end
end

local function GroundBotFilter(defID)
    local ud = UnitDefs[defID]
    return ud ~= nil and ud.isBuilder and not ud.canFly and not ud.isFactory
end

-- ── Grid expansion (forward-declared so TryAssign's closure can reference TryExpand) ──
local TryExpand

local function TryAssign()
    while #freeAirCons > 0 do
        local conID = freeAirCons[1]
        if not spGetUnitDefID(conID) then
            -- Dead con, discard it.
            table.remove(freeAirCons, 1)
        elseif #pendingPlacements > 0 then
            -- Special blueprint (energy grid etc.) takes priority over mex.
            table.remove(freeAirCons, 1)
            local p = table.remove(pendingPlacements, 1)
            local state = BP_PLACER.New(p.blueprint, conID, p.anchorX, p.anchorZ, p.rotation)
            if p.onComplete then state.onComplete = p.onComplete end
            p.stateList[#p.stateList + 1] = state
        elseif #pendingMexPlacements > 0 then
            -- Default: place the next mex grid.
            table.remove(freeAirCons, 1)
            local p = table.remove(pendingMexPlacements, 1)
            local state = BP_PLACER.New(MEX_GRID_BP, conID, p.anchorX, p.anchorZ, p.rotation)
            state.onNanoThreshold = function(s)
                AddCompletedAnchor(s.anchorX, s.anchorZ)
                TryExpand()
            end
            state.onComplete = function(s)
                AddCompletedAnchor(s.anchorX, s.anchorZ)
                TryExpand()
            end
            gridStates[#gridStates + 1] = state
        else
            break  -- no work available
        end
    end
end

TryExpand = function()
    local results = BP_PLACER.FindAllValidPlacements(MEX_GRID_BP, completedAnchors)
    for _, result in ipairs(results) do
        if result.anchorX <= baseX + GRID_SPACING then
            local key = AnchorKey(result.anchorX, result.anchorZ)
            if not assignedAnchors[key] then
                assignedAnchors[key] = true
                pendingMexPlacements[#pendingMexPlacements + 1] = result
                if airLabID and spGetUnitDefID(airLabID) then
                    local defID = FindAirConDefID(spGetUnitDefID(airLabID))
                    if defID then spGiveOrderToUnit(airLabID, -defID, {0}, {}) end
                end
            end
        end
    end
    TryAssign()
end

-- ── Energy grid placement ─────────────────────────────────────────────────────

-- energy_grid_t1 is 480×480 (30 cells × 16 units = GRID_SPACING).
-- First grid always goes north of base (the slot that was previously the north mex).
-- Subsequent grids go east of bot_starter where mex expansion is bounded out.
local function NextEGridPos()
    if eGridsPlaced == 0 then
        return baseX, baseZ - GRID_SPACING
    end
    local n   = eGridsPlaced - 1   -- 0-based index into the east column
    local col = math.floor(n / 3)
    local row = n % 3
    local rowOffsets = {0, -GRID_SPACING, GRID_SPACING}
    local ax = baseX + (2 + col) * GRID_SPACING
    local az = baseZ + rowOffsets[row + 1]
    return ax, az
end

-- Decide whether to queue one more energy grid.
-- Protection against queue flooding: only queue when no egrid is pending and
-- active count is below target; skip entirely when energy is being floated.
local function TryQueueEGrid()
    if not firstTwoMexDone then return end
    if not airLabID or not spGetUnitDefID(airLabID) then return end
    if not ENERGY_T1_GRID_BP then return end

    -- Count how many energy grids are currently pending in the unified queue.
    local pendingECount = 0
    for _, p in ipairs(pendingPlacements) do
        if p.blueprint == ENERGY_T1_GRID_BP then pendingECount = pendingECount + 1 end
    end
    if pendingECount > 0 then return end  -- one in flight is enough

    -- Don't build more when energy storage is >70% full (energy being floated).
    local okE, eCur, eStorage = pcall(Spring.GetTeamResources, myTeamID, "energy")
    local e_stor = (okE and eStorage and eStorage > 0) and (eCur / eStorage) or 0
    if e_stor > 0.7 then return end

    local active = #eGridStates + pendingECount
    if active < target_e_grid then
        local ax, az = NextEGridPos()
        local key = AnchorKey(ax, az)
        if not eGridAssignedKeys[key] then
            eGridAssignedKeys[key] = true
            eGridsPlaced = eGridsPlaced + 1
            pendingPlacements[#pendingPlacements + 1] = {
                blueprint  = ENERGY_T1_GRID_BP,
                anchorX    = ax,
                anchorZ    = az,
                rotation   = 0,
                stateList  = eGridStates,
                onComplete = function()
                    completedEGridCount = completedEGridCount + 1
                    Spring.Echo("[MC] Energy grid done, total=" .. completedEGridCount)
                end,
            }
            Spring.Echo("[MC] Queuing energy grid #" .. eGridsPlaced .. " at " .. math.floor(ax) .. "," .. math.floor(az))
            local airDefID = FindAirConDefID(spGetUnitDefID(airLabID))
            if airDefID then spGiveOrderToUnit(airLabID, -airDefID, {0}, {}) end
            TryAssign()
        end
    end
end

-- ── Commander → com_starter (direct queue, same as test_com_starter.lua) ─────

local function QueueComBlueprint(anchorX, anchorZ)
    local first = true
    local count = 0
    for _, u in ipairs(COM_STARTER.layout) do
        local ud = UnitDefNames and UnitDefNames[u.n]
        if ud then
            local wx = anchorX + u.x
            local wz = anchorZ + u.z
            local wy = spGetGroundHeight(wx, wz) or 0
            local opts = first and {} or {"shift"}
            spGiveOrderToUnit(commanderID, -ud.id, {wx, wy, wz, u.f}, opts)
            first = false
            count = count + 1
        end
    end
    Spring.Echo("[WE] QueueComBlueprint: queued " .. count .. " orders at "
        .. math.floor(anchorX) .. "," .. math.floor(anchorZ))
end

local function StartComBlueprint()
    local cx, _, cz = spGetUnitPosition(commanderID)
    if not cx then Spring.Echo("[WE] StartComBlueprint: no position"); return end
    baseX = math.floor(cx / 16 + 0.5) * 16
    baseZ = math.floor(cz / 16 + 0.5) * 16
    Spring.Echo("[WE] StartComBlueprint baseX=" .. baseX .. " baseZ=" .. baseZ)

    -- Block the commander cell so TryExpand never places a mex_grid here.
    -- Not added to completedAnchors: the mex_grid system seeds itself from
    -- the offset initial anchors in StartAirExpansion, so FindValidPlacement
    -- never generates natural GRID_SPACING positions adjacent to the commander.
    assignedAnchors[AnchorKey(baseX, baseZ)] = true

    QueueComBlueprint(baseX, baseZ)
end

-- ── Con bot 1 → perimeter nanos ───────────────────────────────────────────────

local function AssignConBot1()
    Spring.Echo("[WE] AssignConBot1")
    emptyGridState = BP_PLACER.New(EMPTY_GRID_BP, conBot1ID, baseX, baseZ, 0)
    conBot1Assigned = true
end

-- ── Con bot 2 → bot_starter (east of com) ────────────────────────────────────

local function AssignConBot2()
    Spring.Echo("[WE] AssignConBot2")
    local bsX = baseX + GRID_SPACING
    local bsZ = baseZ
    -- bot_starter is east of com; dx = new_x - existing_x = +GRID_SPACING.
    local rot = FindCorrlRotation(BOT_STARTER, GRID_SPACING, 0)

    -- Mark assigned so TryExpand doesn't place a mex_grid on top of bot_starter.
    local key = AnchorKey(bsX, bsZ)
    assignedAnchors[key] = true

    botStarterState = BP_PLACER.New(BOT_STARTER, conBot2ID, bsX, bsZ, rot, {})
    botStarterState.onComplete = function(s)
        -- Add bot_starter as a completed anchor so mex_grids can expand adjacent to it.
        AddCompletedAnchor(s.anchorX, s.anchorZ)
        TryExpand()
    end
    conBot2Assigned = true
end

-- ── Con bots 3 & 4 → VechT1_and_BotT2 north and south of bot_starter ────────

local function AssignConBot3()
    Spring.Echo("[WE] AssignConBot3 (VechT1_and_BotT2 north of bot_starter)")
    local bsX = baseX + GRID_SPACING
    local bsZ = baseZ - GRID_SPACING   -- north
    local rot  = FindCorrlRotation(VECH_BOT_T2_BP, GRID_SPACING, 0)
    assignedAnchors[AnchorKey(bsX, bsZ)] = true
    local s = BP_PLACER.New(VECH_BOT_T2_BP, conBot3ID, bsX, bsZ, rot)
    prodStates[#prodStates + 1] = s
    conBot3Assigned = true
end

local function AssignConBot4()
    Spring.Echo("[WE] AssignConBot4 (VechT1_and_BotT2 south of bot_starter)")
    local bsX = baseX + GRID_SPACING
    local bsZ = baseZ + GRID_SPACING   -- south
    local rot  = FindCorrlRotation(VECH_BOT_T2_BP, GRID_SPACING, 0)
    assignedAnchors[AnchorKey(bsX, bsZ)] = true
    local s = BP_PLACER.New(VECH_BOT_T2_BP, conBot4ID, bsX, bsZ, rot)
    prodStates[#prodStates + 1] = s
    conBot4Assigned = true
end

-- ── Air lab → initial 2 mex_grids + 1 energy grid ────────────────────────────

local function StartAirExpansion()
    Spring.Echo("[MC] StartAirExpansion airConsQueued=" .. tostring(airConsQueued) .. " baseX=" .. tostring(baseX))
    if airConsQueued then return end
    airConsQueued = true
    firstTwoMexDone = true  -- enable energy grid logic

    -- Block the north slot so mex expansion never places a grid there;
    -- the first energy grid will occupy that position instead.
    assignedAnchors[AnchorKey(baseX, baseZ - GRID_SPACING)] = true

    local initials = {
        {ax = baseX - GRID_SPACING, az = baseZ,                dx = -GRID_SPACING, dz = 0},            -- west
        {ax = baseX,                az = baseZ + GRID_SPACING, dx = 0,             dz =  GRID_SPACING}, -- south
    }
    for _, init in ipairs(initials) do
        local key = AnchorKey(init.ax, init.az)
        if not assignedAnchors[key] then
            assignedAnchors[key] = true
            local rot = FindCorrlRotation(MEX_GRID_BP, init.dx, init.dz)
            pendingMexPlacements[#pendingMexPlacements + 1] = {
                anchorX  = init.ax,
                anchorZ  = init.az,
                rotation = rot,
            }
        end
    end

    -- Queue one air con per mex placement.
    local airDefID = FindAirConDefID(spGetUnitDefID(airLabID))
    if airDefID then
        spGiveOrderToUnit(airLabID, -airDefID, {0}, {})
        spGiveOrderToUnit(airLabID, -airDefID, {0}, {})
    end

    -- Queue the first energy grid immediately.
    TryQueueEGrid()

    -- Queue 2 more con bots for VechT1_and_BotT2 north and south of bot_starter.
    if botLabID and spGetUnitDefID(botLabID) and not prodBotsQueued then
        local conDefID = FindConBotDefID(spGetUnitDefID(botLabID))
        if conDefID then
            spGiveOrderToUnit(botLabID, -conDefID, {0}, {})
            spGiveOrderToUnit(botLabID, -conDefID, {0}, {})
            prodBotsQueued = true
        end
    end
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    Spring.Echo("[WE] Initialize")
    local ok1, r1 = pcall(VFS.Include, "LuaUI/Widgets/blueprint_placer.lua")
    local ok2, r2 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/com_starter.lua")
    local ok3, r3 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/bot_starter.lua")
    local ok4, r4 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/mex_grid_aa_corner.lua")
    local ok5, r5 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/empty_grid.lua")
    local ok6, r6 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/VechT1_and_BotT2.lua")
    local ok7, r7 = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/energy_grid_t1.lua")
    if not ok1 then Spring.Echo("[MC] ERROR loading blueprint_placer: "       .. tostring(r1)); return end
    if not ok2 then Spring.Echo("[MC] ERROR loading com_starter: "            .. tostring(r2)); return end
    if not ok3 then Spring.Echo("[MC] ERROR loading bot_starter: "            .. tostring(r3)); return end
    if not ok4 then Spring.Echo("[MC] ERROR loading mex_grid_aa_corner: "     .. tostring(r4)); return end
    if not ok5 then Spring.Echo("[MC] ERROR loading empty_grid: "             .. tostring(r5)); return end
    if not ok6 then Spring.Echo("[MC] ERROR loading VechT1_and_BotT2: "       .. tostring(r6)); return end
    if not ok7 then Spring.Echo("[MC] ERROR loading energy_grid_t1: "         .. tostring(r7)); return end
    BP_PLACER         = r1
    COM_STARTER       = r2
    BOT_STARTER       = r3
    MEX_GRID_BP       = r4
    EMPTY_GRID_BP     = r5
    VECH_BOT_T2_BP    = r6
    ENERGY_T1_GRID_BP = r7
    GRID_SPACING = BP_PLACER.GRID_SPACING
    Spring.Echo("[WE] Loaded OK. GRID_SPACING=" .. tostring(GRID_SPACING))

    myTeamID = spGetMyTeamID()
    local units = Spring.GetTeamUnits(myTeamID) or {}
    for _, uid in ipairs(units) do
        if IsCommander(spGetUnitDefID(uid)) then
            commanderID = uid
            break
        end
    end
    if commanderID then
        Spring.Echo("[WE] Commander found in Initialize id=" .. commanderID)
        StartComBlueprint()
    end
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
    if not myTeamID then myTeamID = spGetMyTeamID() end
    if teamID ~= myTeamID then return end

    local dName = UnitDefs[unitDefID] and UnitDefs[unitDefID].name or "?"
    Spring.Echo("[WE] UnitCreated id=" .. unitID .. " def=" .. dName .. " builder=" .. tostring(builderID))

    if not baseX then return end

    local d = unitDefID and UnitDefs[unitDefID]
    if not d then return end

    -- Detect labs.
    if d.isFactory then
        local isAir = IsAirFactory(unitDefID)
        Spring.Echo("[WE]   factory isAir=" .. tostring(isAir))
        if isAir and not airLabID then
            airLabID = unitID
            Spring.Echo("[WE]   -> airLabID=" .. unitID)
        elseif not isAir and not botLabID then
            botLabID = unitID
            Spring.Echo("[WE]   -> botLabID=" .. unitID)
        end
        if builderID and builderID ~= commanderID then labBuilders[unitID] = builderID end
        return
    end

    -- Commander assists each nano turret built by con bot 1 as it starts construction.
    -- The goal of this is to have the commander assist first nano that is built but I it does not work right now 
    --if builderID == conBot1ID and d.name == "cornanotc" and commanderID then
    --    Spring.Echo("[WE] ConBot1 started nano " .. unitID .. " -> commander repair")
    --    spGiveOrderToUnit(commanderID, CMD_REPAIR, {unitID}, {"space"})
    --end

    -- Con bots from bot lab, assigned in order.
    if builderID == botLabID and d.isBuilder and not d.canFly and not d.isFactory then
        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})   -- clear factory guard order
        if not conBot1ID then
            Spring.Echo("[WE] ConBot1 detected id=" .. unitID)
            conBot1ID = unitID
            AssignConBot1()
        elseif not conBot2ID then
            Spring.Echo("[WE] ConBot2 detected id=" .. unitID)
            conBot2ID = unitID
            AssignConBot2()
        elseif not conBot3ID then
            Spring.Echo("[WE] ConBot3 detected id=" .. unitID)
            conBot3ID = unitID
            if baseX then AssignConBot3() end
        elseif not conBot4ID then
            Spring.Echo("[WE] ConBot4 detected id=" .. unitID)
            conBot4ID = unitID
            if baseX then AssignConBot4() end
        end
        return
    end

    -- Air constructors from air lab get pooled for grid assignment.
    if builderID == airLabID and d.isBuilder and d.canFly and not d.isFactory then
        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})   -- clear factory guard order
        Spring.Echo("[WE] AirCon detected id=" .. unitID .. " freeAirCons#=" .. (#freeAirCons+1))
        freeAirCons[#freeAirCons + 1] = unitID
        TryAssign()
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end

    local dName = UnitDefs[unitDefID] and UnitDefs[unitDefID].name or "?"
    Spring.Echo("[WE] UnitFinished id=" .. unitID .. " def=" .. dName)

    -- Commander detection (mirrors test_com_starter pattern).
    if IsCommander(unitDefID) and not commanderID then
        Spring.Echo("[WE] Commander detected in UnitFinished id=" .. unitID)
        commanderID = unitID
        StartComBlueprint()
    end

    if not baseX then return end

    -- Schedule a stop for the con that built this lab so it doesn't auto-guard it.
    -- Deferred 30 frames to let the engine apply the auto-guard order first.
    if labBuilders[unitID] then
        pendingStops[#pendingStops + 1] = {unitID = labBuilders[unitID], fireFrame = currentFrame + 30}
        labBuilders[unitID] = nil
    end

    -- Bot lab done → queue 2 con bots.
    if unitID == botLabID and not conBotsQueued then
        Spring.Echo("[WE] BotLab finished -> queueing 2 con bots")
        local defID = FindConBotDefID(unitDefID)
        Spring.Echo("[WE]   conBotDefID=" .. tostring(defID))
        if defID then
            spGiveOrderToUnit(botLabID, -defID, {0}, {})
            spGiveOrderToUnit(botLabID, -defID, {0}, {})
            conBotsQueued = true
        end
        -- fall through so comStarterState is notified the bot lab finished
    end

    -- Air lab done → seed initial mex_grids.
    if unitID == airLabID then
        Spring.Echo("[WE] AirLab finished -> StartAirExpansion")
        StartAirExpansion()
        -- fall through to also notify placer states below
    end

    -- Notify all active placer states so they can mark queue items as built.
    local x, _, z = spGetUnitPosition(unitID)
    if emptyGridState and not emptyGridState.done then
        BP_PLACER.OnUnitFinished(emptyGridState, unitID, unitDefID, x, z)
    end
    if botStarterState and not botStarterState.done then
        BP_PLACER.OnUnitFinished(botStarterState, unitID, unitDefID, x, z)
    end
    for _, ps in ipairs(prodStates) do
        if not ps.done then
            BP_PLACER.OnUnitFinished(ps, unitID, unitDefID, x, z)
        end
    end
    for _, gs in ipairs(gridStates) do
        if not gs.done then
            BP_PLACER.OnUnitFinished(gs, unitID, unitDefID, x, z)
        end
    end
    for _, es in ipairs(eGridStates) do
        if not es.done then
            BP_PLACER.OnUnitFinished(es, unitID, unitDefID, x, z)
        end
    end
end

function widget:GameFrame(frame)
    currentFrame = frame
    if not myTeamID or not baseX then return end

    -- Fire any deferred stops.
    local i = 1
    while i <= #pendingStops do
        local s = pendingStops[i]
        if frame >= s.fireFrame then
            spGiveOrderToUnit(s.unitID, CMD_STOP, {}, {})
            table.remove(pendingStops, i)
        else
            i = i + 1
        end
    end

    local _, m, ms  = pcall(Spring.GetTeamResources, myTeamID, "metal")
    local _, em, ems = pcall(Spring.GetTeamResources, myTeamID, "energy")
    local resources = {
        metal = m or 0, metalStorage = ms or 1000,
        energy = em or 0, energyStorage = ems or 1000,
    }

    if frame % 10 == 0 then
        if emptyGridState and not emptyGridState.done then
            BP_PLACER.Update(emptyGridState, frame, resources)
        end
        if botStarterState and not botStarterState.done then
            BP_PLACER.Update(botStarterState, frame, resources)
        end
        for _, ps in ipairs(prodStates) do
            if not ps.done then
                BP_PLACER.Update(ps, frame, resources)
            end
        end
        for _, gs in ipairs(gridStates) do
            if not gs.done then
                BP_PLACER.Update(gs, frame, resources)
            end
        end
        for _, es in ipairs(eGridStates) do
            if not es.done then
                BP_PLACER.Update(es, frame, resources)
            end
        end
    end

    if frame % 30 == 0 then
        local myAlly = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
        for _, gs in ipairs(gridStates) do
            if not gs.done then
                local units = Spring.GetUnitsInCylinder(gs.anchorX, gs.anchorZ, BP_PLACER.ENEMY_CLEAR_RADIUS)
                local clear = true
                if units then
                    for _, uid in ipairs(units) do
                        if Spring.GetUnitAllyTeam(uid) ~= myAlly then clear = false; break end
                    end
                end
                if clear then BP_PLACER.HandleEnemyClear(gs) end
            end
        end
        for _, es in ipairs(eGridStates) do
            if not es.done then
                local units = Spring.GetUnitsInCylinder(es.anchorX, es.anchorZ, BP_PLACER.ENEMY_CLEAR_RADIUS)
                local clear = true
                if units then
                    for _, uid in ipairs(units) do
                        if Spring.GetUnitAllyTeam(uid) ~= myAlly then clear = false; break end
                    end
                end
                if clear then BP_PLACER.HandleEnemyClear(es) end
            end
        end

        -- Update energy rolling averages (sampled every 30 frames ≈ 1s).
        local okE, eCur, eStorage, ePull, eIncome = pcall(Spring.GetTeamResources, myTeamID, "energy")
        if okE then
            local alpha = 0.1  -- EMA weight; ~10-sample window = ~10s
            e_avg_demand = e_avg_demand * (1 - alpha) + (ePull    or 0) * alpha
            e_avg_prod   = e_avg_prod   * (1 - alpha) + (eIncome  or 0) * alpha

            -- Track continuous energy stall (demand > production).
            if (ePull or 0) > (eIncome or 0) * 1.05 then
                energyStallFrames = energyStallFrames + 30
            else
                energyStallFrames = 0
            end

            -- After stalling for 30s with no egrid already pending, raise target.
            local pendingECount = 0
            for _, p in ipairs(pendingPlacements) do
                if p.blueprint == ENERGY_T1_GRID_BP then pendingECount = pendingECount + 1 end
            end
            if energyStallFrames >= 900 and pendingECount == 0 then
                target_e_grid = target_e_grid + 1
                energyStallFrames = 0
                Spring.Echo("[MC] Energy stall 30s -> target_e_grid=" .. target_e_grid)
            end
        end

        TryQueueEGrid()
    end
end
