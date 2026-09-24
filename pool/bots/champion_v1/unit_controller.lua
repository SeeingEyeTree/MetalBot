-- unit_controller.lua  ─  Scout and combat unit manager for Beyond All Reason
-- Scouts explore the map by sector. Combat units hold a deformable "contact line"
-- made of NODE_COUNT independent nodes. Each node advances or holds based on its
-- own local combat state, allowing the front to curve around contested areas.
-- ~55% of army metal value clusters at whichever node group is most contested.
-- Compatible with macro_controller.lua: never touches builders, factories, or commanders.
--
-- 2026-09-18 change (run 20260918_024045, new_algorithm): added retreat-to-heal and
-- rez-bot (Graverobber, e.g. cornecro) support. game_mechanics.md §1.4/§7 calls
-- Graverobbers "mandatory" and retreating low-HP main-army units a "hard requirement",
-- but the old retreat block just MOVE-ordered a critical-HP unit to the commander's
-- exact spawn point with no repair order ever issued to anything -- nothing there
-- actually heals it (BAR builders don't auto-repair units that merely wander nearby).
-- Fixes: (1) rez bots (detected via UnitDefs[].canResurrect, not name-matching, since
-- that's the real engine flag) are tracked separately and given their own priority
-- loop -- heal the most valuable nearby damaged ally, else resurrect the nearest
-- rezzable wreck, else hang back just behind the thrust node so they're near the
-- front without leading it; (2) a critically wounded combat unit now retreats toward
-- the nearest living rez bot (if one is within REZ_TO_RETREAT_RADIUS) instead of
-- always making the long trip to the commander, so retreat and healing are actually
-- connected. lab_controller.lua was also touched (see its header) since rez bots
-- were never queued by any lab before this -- without that, this file would have
-- nothing to track.

local widget = widget
local Spring = Spring
local CMD    = CMD

local spGetUnitDefID       = Spring.GetUnitDefID
local spGetUnitPosition    = Spring.GetUnitPosition
local spGetUnitHealth      = Spring.GetUnitHealth
local spGetUnitCommands    = Spring.GetUnitCommands
local spGetUnitAllyTeam    = Spring.GetUnitAllyTeam
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spGetMyTeamID        = Spring.GetMyTeamID
local spGetGroundHeight    = Spring.GetGroundHeight
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetFeaturesInCylinder = Spring.GetFeaturesInCylinder
local spGetFeaturePosition   = Spring.GetFeaturePosition
local spGetFeatureResurrect  = Spring.GetFeatureResurrect

local CMD_MOVE      = (CMD and CMD.MOVE)      or 10
local CMD_PATROL    = (CMD and CMD.PATROL)    or 15
local CMD_FIGHT     = (CMD and CMD.FIGHT)     or 16
local CMD_REPAIR    = (CMD and CMD.REPAIR)    or 40
local CMD_RESURRECT = (CMD and CMD.RESURRECT) or 125

-- ── Tunables ──────────────────────────────────────────────────────────────────

local RETREAT_HP         = 0.15  -- retreat when HP fraction drops below this
local REZ_TO_RETREAT_RADIUS = 2500 -- retreat toward a rez bot instead of base if one is this close
local HEAL_HP_FRAC        = 0.95  -- rez bots consider an ally "damaged" below this HP fraction
local REZ_HEAL_RADIUS     = 700   -- rez bot search radius for damaged allies to repair
local REZ_RESURRECT_RADIUS = 1000 -- rez bot search radius for resurrectable wrecks
local REZ_SUPPORT_OFFSET  = 350   -- idle rez bots hang back this far behind the thrust node
local SECTOR_SIZE        = 1024  -- map divided into sectors this wide
local MAP_MARGIN         = 200   -- keep units at least this far from map edges
local ADVANCE_MIN_UNITS  = 5     -- don't advance until this many combat units exist
local THRUST_FRAC        = 0.55  -- fraction of total army metal value in thrust zone
local LOCAL_ENEMY_RADIUS = 500   -- radius for per-unit FIGHT vs MOVE decision

local NODE_COUNT        = 32   -- nodes forming the contact curve
local NODE_ENEMY_RADIUS = 600  -- per-node enemy detection radius (world units)
local NODE_ADVANCE_STEP = 120  -- world-units a clear node advances per tick (every 90 frames)
local NODE_MAX_BULGE    = 500  -- max world-units a node can lead its neighbours' average
local NODE_MAX_LAG      = 600  -- max world-units a non-engaged node can trail its neighbours
local THRUST_NODE_HALF  = 5    -- thrust window = thrustIdx ± this many nodes
local ARC_RADIUS        = 1500 -- centre node forward distance at init (arc on top of map-entry advance)
local NODE_MIN_SPACING  = 100  -- lateral spacing between adjacent nodes (elmos)
local EDGE_STUCK_MARGIN = 150  -- node is "at edge" when this close to its map limit
local MIN_ENEMY_SAMPLE  = 3    -- minimum visible enemies needed to update target
local TARGET_EMA_ALPHA  = 0.25 -- EMA weight for new enemy centroid (0=frozen, 1=instant)

function widget:GetInfo()
    return {
        name    = "Unit Controller",
        desc    = "Node-curve contact line with sector scouting (macro_controller compatible)",
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
local combatUnits = {}   -- [unitID] = defID
local scoutUnits  = {}   -- [unitID] = defID
local rezUnits    = {}   -- [unitID] = defID (Graverobber-type: canResurrect)
local baseX, baseZ     = nil, nil
local targetX, targetZ = nil, nil

-- Sector scouting grid
local scoutSectors  = {}
local scoutAssigned = {}
local sectorsInited = false

-- Contact line (node-based)
local nodes         = nil   -- array[1..NODE_COUNT] of {lateral, adv, engaged}
local thrustNodeIdx = 0     -- index of most-contested node cluster
local lineHalfWidth = 0     -- world-units from centre to wing tip (used at init only)
local lineInited    = false

-- Advance direction (shared; recomputed each UpdateNodes tick)
local advDir  = { x = 0, z = 0 }  -- normalized base→target
local perpDir = { x = 0, z = 0 }  -- perpendicular (left/right along line)
local diagDist = 0                  -- distance base→current target

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function IsCommander(uDefID)
    local d = uDefID and UnitDefs[uDefID]
    if not d then return false end
    return d.customParams ~= nil
        and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
end

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

local function HasEnemy(units)
    if not units then return false end
    for _, uid in ipairs(units) do
        local allyID = spGetUnitAllyTeam and spGetUnitAllyTeam(uid)
        if allyID and allyID ~= myAllyID then return true end
    end
    return false
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

local function PickScoutSector(unitID, frame)
    local ux, _, uz = spGetUnitPosition(unitID)
    if not ux then return nil, nil end

    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local mapCX, mapCZ = mapX * 0.5, mapZ * 0.5

    local axisX, axisZ = 0, 0
    if baseX and baseZ then
        local dx, dz = mapCX - baseX, mapCZ - baseZ
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 1 then axisX, axisZ = dx / len, dz / len end
    end

    local assigned = {}
    for uid, key in pairs(scoutAssigned) do
        if uid ~= unitID then assigned[key] = true end
    end

    local bestScore, bestSector, bestKey = -math.huge, nil, nil
    for key, sector in pairs(scoutSectors) do
        if not assigned[key] then
            local dx, dz    = sector.x - ux, sector.z - uz
            local dist      = math.sqrt(dx * dx + dz * dz) + 1
            local staleness = frame - sector.lastScouted
            local sdx, sdz  = sector.x - mapCX, sector.z - mapCZ
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

    local exArr, ezArr = {}, {}
    for _, uid in ipairs(allUnits) do
        local allyID = spGetUnitAllyTeam and spGetUnitAllyTeam(uid)
        if allyID and allyID ~= myAllyID then
            local ex, _, ez = spGetUnitPosition(uid)
            if ex then
                exArr[#exArr + 1] = ex
                ezArr[#ezArr + 1] = ez
            end
        end
    end

    -- Require a minimum sample to ignore lone scouts swinging the target.
    if #exArr < MIN_ENEMY_SAMPLE then return end

    table.sort(exArr)
    table.sort(ezArr)
    local mid  = math.floor(#exArr * 0.5) + 1
    local medX = exArr[mid]
    local medZ = ezArr[mid]

    -- EMA smoothing; first reading sets directly to avoid startup lag.
    if targetX then
        targetX = targetX * (1 - TARGET_EMA_ALPHA) + medX * TARGET_EMA_ALPHA
        targetZ = targetZ * (1 - TARGET_EMA_ALPHA) + medZ * TARGET_EMA_ALPHA
    else
        targetX, targetZ = medX, medZ
    end
end

-- ── Contact line (node-based) ─────────────────────────────────────────────────

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

local function RecomputeLineDir(tx, tz)
    if not baseX then return end
    local dx   = tx - baseX
    local dz   = tz - baseZ
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 1 then return end
    advDir.x  = dx / dist
    advDir.z  = dz / dist
    perpDir.x = -advDir.z
    perpDir.z =  advDir.x
    diagDist  = dist
end

-- Maximum adv value before node's world position exits map bounds.
local function MaxAdvForNode(lateral)
    local mapX   = Game.mapSizeX or 8192
    local mapZ   = Game.mapSizeZ or 8192
    local maxAdv = diagDist * 2
    local perpX  = perpDir.x * lateral
    local perpZ  = perpDir.z * lateral
    if advDir.x > 1e-6 then
        maxAdv = math.min(maxAdv, (mapX - MAP_MARGIN - baseX - perpX) / advDir.x)
    elseif advDir.x < -1e-6 then
        maxAdv = math.min(maxAdv, (MAP_MARGIN - baseX - perpX) / advDir.x)
    end
    if advDir.z > 1e-6 then
        maxAdv = math.min(maxAdv, (mapZ - MAP_MARGIN - baseZ - perpZ) / advDir.z)
    elseif advDir.z < -1e-6 then
        maxAdv = math.min(maxAdv, (MAP_MARGIN - baseZ - perpZ) / advDir.z)
    end
    return math.max(0, maxAdv)
end

-- Minimum adv needed so the world position is within map bounds.
-- Necessary when the base is near a map edge and the lateral offset pushes the node off-map.
local function MinAdvForNode(lateral)
    local mapX   = Game.mapSizeX or 8192
    local mapZ   = Game.mapSizeZ or 8192
    local minAdv = 0
    local perpX  = perpDir.x * lateral
    local perpZ  = perpDir.z * lateral
    if advDir.x > 1e-6 then
        local req = (MAP_MARGIN - baseX - perpX) / advDir.x
        if req > minAdv then minAdv = req end
    elseif advDir.x < -1e-6 then
        local req = (mapX - MAP_MARGIN - baseX - perpX) / advDir.x
        if req > minAdv then minAdv = req end
    end
    if advDir.z > 1e-6 then
        local req = (MAP_MARGIN - baseZ - perpZ) / advDir.z
        if req > minAdv then minAdv = req end
    elseif advDir.z < -1e-6 then
        local req = (mapZ - MAP_MARGIN - baseZ - perpZ) / advDir.z
        if req > minAdv then minAdv = req end
    end
    return math.max(0, minAdv)
end

-- World position of a node from its (lateral, adv) parameterization.
-- Recomputed on-the-fly using current advDir/perpDir so direction changes apply instantly.
local function NodeWorldPos(node)
    return baseX + advDir.x * node.adv + perpDir.x * node.lateral,
           baseZ + advDir.z * node.adv + perpDir.z * node.lateral
end

local function InitNodes()
    nodes = {}
    thrustNodeIdx = math.floor(NODE_COUNT / 2)
    for i = 1, NODE_COUNT do
        local t       = (i - 1) / (NODE_COUNT - 1) * 2 - 1   -- -1 to 1
        local lateral = t * lineHalfWidth
        local minAdv  = MinAdvForNode(lateral)
        -- Arc on top of the minimum advance needed to land on-map.
        -- Centre gets full ARC_RADIUS bump; edges get 0, so the arc is always visible.
        local arcBump = ARC_RADIUS * math.max(0, math.cos(math.pi * 0.5 * t))
        local adv     = math.min(minAdv + arcBump, MaxAdvForNode(lateral))
        nodes[i] = { lateral = lateral, adv = adv, engaged = false, atEdge = false }
    end
end

local function InitContactLine()
    if lineInited or not baseX then return end
    lineInited = true
    local tx, tz = DefaultTarget()
    RecomputeLineDir(tx, tz)
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local perpMapDim = (math.abs(advDir.x) >= math.abs(advDir.z)) and mapZ or mapX
    lineHalfWidth = NODE_MIN_SPACING * (NODE_COUNT - 1) / 2
    InitNodes()
    Spring.Echo("[UnitCtrl] Contact line init: " .. NODE_COUNT
        .. " nodes, halfWidth=" .. math.floor(lineHalfWidth))
end

-- Returns the node index whose neighbourhood has the most engaged nodes.
local function FindThrustNode()
    local bestScore = -1
    local bestIdx   = math.floor(NODE_COUNT / 2)
    for i = 1, NODE_COUNT do
        local score = 0
        local lo = math.max(1, i - THRUST_NODE_HALF)
        local hi = math.min(NODE_COUNT, i + THRUST_NODE_HALF)
        for j = lo, hi do
            if nodes[j].engaged then score = score + 1 end
        end
        -- Tie-break: prefer centre
        local centreDist = math.abs(i - NODE_COUNT / 2)
        if score > bestScore or (score == bestScore and centreDist < math.abs(bestIdx - NODE_COUNT / 2)) then
            bestScore = score
            bestIdx   = i
        end
    end
    return bestIdx
end

local function UpdateNodes()
    if not lineInited or not nodes then return end

    local tx, tz
    if targetX then tx, tz = targetX, targetZ
    else            tx, tz = DefaultTarget() end
    RecomputeLineDir(tx, tz)

    local count = 0
    for _ in pairs(combatUnits) do count = count + 1 end
    local canAdvance = targetX ~= nil and count >= ADVANCE_MIN_UNITS

    -- Update each node independently. World pos is computed from (lateral, adv)
    -- using the current advDir, so a direction change reorients all nodes instantly.
    for i = 1, NODE_COUNT do
        local node   = nodes[i]
        local wx, wz = NodeWorldPos(node)
        if spGetUnitsInCylinder then
            node.engaged = HasEnemy(spGetUnitsInCylinder(wx, wz, NODE_ENEMY_RADIUS))
        end
        if canAdvance and not node.engaged then
            node.adv = node.adv + NODE_ADVANCE_STEP
        end
        local maxAdv = MaxAdvForNode(node.lateral)
        node.adv     = math.min(node.adv, maxAdv)
        node.adv     = math.max(0, node.adv)
        -- Flag nodes that have run out of forward room so unit assignment skips them.
        node.atEdge  = (maxAdv - node.adv) <= EDGE_STUCK_MARGIN
    end

    -- Two-pass smoothing for stability
    for _ = 1, 2 do
        -- Anti-bulge: cap how far a node can lead its neighbours
        for i = 2, NODE_COUNT - 1 do
            local cur    = nodes[i]
            local avgAdv = (nodes[i - 1].adv + nodes[i + 1].adv) * 0.5
            if cur.adv > avgAdv + NODE_MAX_BULGE then
                cur.adv = avgAdv + NODE_MAX_BULGE
            end
        end
        -- Anti-lag: push non-engaged nodes that trail too far back toward the line
        for i = 2, NODE_COUNT - 1 do
            local cur    = nodes[i]
            local avgAdv = (nodes[i - 1].adv + nodes[i + 1].adv) * 0.5
            if not cur.engaged and cur.adv < avgAdv - NODE_MAX_LAG then
                cur.adv = cur.adv + (avgAdv - NODE_MAX_LAG - cur.adv) * 0.4
            end
        end
    end

    thrustNodeIdx = FindThrustNode()
end

-- Returns {[unitID] = nodeIdx}. High-value units cluster at the thrust window.
local function AssignUnitPositions()
    if not nodes then return {} end

    local unitList = {}
    for unitID, defID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) then
            local cost = (UnitDefs[defID] and UnitDefs[defID].metalCost) or 0
            unitList[#unitList + 1] = { id = unitID, value = cost }
        end
    end
    if #unitList == 0 then return {} end

    table.sort(unitList, function(a, b) return a.value > b.value end)

    local total = 0
    for _, u in ipairs(unitList) do total = total + u.value end

    local thrustUnits, wingUnits = {}, {}
    local accumulated = 0
    local cutoff = total * THRUST_FRAC
    for _, u in ipairs(unitList) do
        accumulated = accumulated + u.value
        if accumulated <= cutoff or #thrustUnits == 0 then
            thrustUnits[#thrustUnits + 1] = u.id
        else
            wingUnits[#wingUnits + 1] = u.id
        end
    end

    -- Thrust window node indices
    local thrustLo = math.max(1,          thrustNodeIdx - THRUST_NODE_HALF)
    local thrustHi = math.min(NODE_COUNT, thrustNodeIdx + THRUST_NODE_HALF)
    local thrustSpan = thrustHi - thrustLo + 1

    -- Wing node indices (outside thrust window), skipping nodes stuck at the map edge.
    -- Edge-stuck nodes have no room to advance; sending units there wastes them.
    local wingNodes = {}
    for i = 1, thrustLo - 1          do
        if not nodes[i].atEdge then wingNodes[#wingNodes + 1] = i end
    end
    for i = thrustHi + 1, NODE_COUNT do
        if not nodes[i].atEdge then wingNodes[#wingNodes + 1] = i end
    end

    local positions = {}

    for i, uid in ipairs(thrustUnits) do
        positions[uid] = thrustLo + (i - 1) % thrustSpan
    end

    if #wingNodes > 0 then
        for i, uid in ipairs(wingUnits) do
            positions[uid] = wingNodes[(i - 1) % #wingNodes + 1]
        end
    else
        for i, uid in ipairs(wingUnits) do
            positions[uid] = thrustLo + (i - 1) % thrustSpan
        end
    end

    return positions
end

-- ── Scout assignment ──────────────────────────────────────────────────────────

local function AssignScouts(frame)
    for unitID in pairs(scoutUnits) do
        if spGetUnitDefID(unitID) then
            local assignedKey = scoutAssigned[unitID]

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
                    sector.lastScouted = frame - (SECTOR_SIZE * 2)
                end
            end
        end
    end
end

-- ── Line orders ───────────────────────────────────────────────────────────────

local function IssueLineOrders()
    if not lineInited or not baseX or not nodes then return end

    local positions = AssignUnitPositions()

    for unitID, nodeIdx in pairs(positions) do
        if IsIdle(unitID) then
            local hp, maxHP = spGetUnitHealth(unitID)
            if not (hp and maxHP and (hp / maxHP) < RETREAT_HP) then
                local node = nodes[nodeIdx]
                if node then
                    local wx, wz = NodeWorldPos(node)
                    local py  = spGetGroundHeight(wx, wz) or 0
                    local cmd = node.engaged and CMD_FIGHT or CMD_MOVE
                    if cmd == CMD_MOVE and spGetUnitsInCylinder then
                        if HasEnemy(spGetUnitsInCylinder(wx, wz, LOCAL_ENEMY_RADIUS)) then
                            cmd = CMD_FIGHT
                        end
                    end
                    spGiveOrderToUnit(unitID, cmd, {wx, py, wz}, {})
                end
            end
        end
    end
end

-- ── Rez bots (Graverobber-type: heal / resurrect) ────────────────────────────

-- Best damaged ally within range: prefers higher metal value, then closer.
local function FindHealTarget(ux, uz, myID)
    local nearby = spGetUnitsInCylinder(ux, uz, REZ_HEAL_RADIUS)
    if not nearby then return nil end

    local bestID, bestScore, bestDist = nil, -math.huge, nil
    for _, uid in ipairs(nearby) do
        if uid ~= myID then
            local allyID = spGetUnitAllyTeam and spGetUnitAllyTeam(uid)
            if allyID and allyID == myAllyID then
                local hp, maxHP = spGetUnitHealth(uid)
                if hp and maxHP and maxHP > 0 and (hp / maxHP) < HEAL_HP_FRAC then
                    local ex, _, ez = spGetUnitPosition(uid)
                    if ex then
                        local dx, dz = ex - ux, ez - uz
                        local dist   = math.sqrt(dx * dx + dz * dz)
                        local defID  = spGetUnitDefID(uid)
                        local cost   = (defID and UnitDefs[defID] and UnitDefs[defID].metalCost) or 20
                        local score  = cost - dist * 0.1
                        if score > bestScore then
                            bestScore, bestID, bestDist = score, uid, dist
                        end
                    end
                end
            end
        end
    end
    return bestID, bestDist
end

-- Nearest rezzable wreck within range (closest first; this is a metal-plate map
-- with no reclaim priority modeling elsewhere, so distance alone is a fine proxy).
local function FindRezTarget(ux, uz)
    local feats = spGetFeaturesInCylinder(ux, uz, REZ_RESURRECT_RADIUS)
    if not feats then return nil end

    local bestID, bestDist, bestX, bestZ = nil, math.huge, nil, nil
    for _, fID in ipairs(feats) do
        local rezName = spGetFeatureResurrect(fID)
        if rezName and rezName ~= "" then
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx then
                local dx, dz = fx - ux, fz - uz
                local dist   = dx * dx + dz * dz
                if dist < bestDist then
                    bestDist, bestID, bestX, bestZ = dist, fID, fx, fz
                end
            end
        end
    end
    return bestID, bestX, bestZ
end

-- Nearest living rez bot to a world point (used to pick a retreat destination).
local function FindNearestRezBot(ux, uz)
    local bestID, bestDist = nil, math.huge
    for unitID in pairs(rezUnits) do
        if spGetUnitDefID(unitID) then
            local rx, _, rz = spGetUnitPosition(unitID)
            if rx then
                local dx, dz = rx - ux, rz - uz
                local dist = dx * dx + dz * dz
                if dist < bestDist then bestDist, bestID = dist, unitID end
            end
        end
    end
    if not bestID then return nil end
    return bestID, math.sqrt(bestDist)
end

-- Priority per rez bot: heal a nearby damaged ally > resurrect a nearby wreck >
-- hang back just behind the thrust node so it's near the action without leading it.
local function UpdateRezBots()
    for unitID, defID in pairs(rezUnits) do
        if spGetUnitDefID(unitID) then
            local ux, _, uz = spGetUnitPosition(unitID)
            if ux then
                local buildDist = (UnitDefs[defID] and UnitDefs[defID].buildDistance) or 200

                local healID, healDist = FindHealTarget(ux, uz, unitID)
                if healID then
                    if healDist <= buildDist then
                        spGiveOrderToUnit(unitID, CMD_REPAIR, {healID}, {})
                    else
                        local hx, _, hz = spGetUnitPosition(healID)
                        if hx then
                            local hy = spGetGroundHeight(hx, hz) or 0
                            spGiveOrderToUnit(unitID, CMD_MOVE, {hx, hy, hz}, {})
                        end
                    end
                else
                    local rezID, rx, rz = FindRezTarget(ux, uz)
                    if rezID then
                        local dx, dz = rx - ux, rz - uz
                        if (dx * dx + dz * dz) <= buildDist * buildDist then
                            spGiveOrderToUnit(unitID, CMD_RESURRECT, {rezID + (Game and Game.maxUnits or 32768)}, {})
                        else
                            local ry = spGetGroundHeight(rx, rz) or 0
                            spGiveOrderToUnit(unitID, CMD_MOVE, {rx, ry, rz}, {})
                        end
                    elseif IsIdle(unitID) and lineInited and nodes then
                        local node = nodes[thrustNodeIdx]
                        if node then
                            local wx, wz = NodeWorldPos(node)
                            local sx = wx - advDir.x * REZ_SUPPORT_OFFSET
                            local sz = wz - advDir.z * REZ_SUPPORT_OFFSET
                            local sy = spGetGroundHeight(sx, sz) or 0
                            spGiveOrderToUnit(unitID, CMD_MOVE, {sx, sy, sz}, {})
                        end
                    end
                end
            end
        end
    end
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
end

function widget:UnitCreated(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if IsCommander(unitDefID) and not baseX then
        local x, _, z = spGetUnitPosition(unitID)
        if x then
            baseX, baseZ = x, z
            InitContactLine()
        end
    end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d then return end

    if d.canResurrect then
        rezUnits[unitID] = unitDefID
        return
    end

    if d.isFactory or d.isBuilder then return end
    if not d.speed or d.speed <= 0 then return end

    if IsCommander(unitDefID) then
        if not baseX then
            local x, _, z = spGetUnitPosition(unitID)
            if x then baseX, baseZ = x, z; InitContactLine() end
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
    rezUnits[unitID]      = nil
end

function widget:GameFrame(frame)
    InitSectors()

    -- Scan for enemies and update scouted sectors every ~5s.
    if frame % 150 == 0 then
        UpdateEnemyTarget()
        UpdateScoutedSectors(frame)
    end

    -- Update nodes (advance/hold/smooth) every ~3s.
    if frame % 90 == 0 then
        UpdateNodes()
    end

    -- Issue guidance and scout orders every ~2s.
    if frame % 60 == 0 then
        AssignScouts(frame)
        IssueLineOrders()
        UpdateRezBots()
    end

    -- Retreat check every ~1s: override active commands for critical HP units.
    -- Retreats toward the nearest rez bot when one is close enough to reach it
    -- quickly; otherwise falls back to the base, same as before.
    if frame % 30 == 0 and baseX then
        for unitID in pairs(combatUnits) do
            if spGetUnitDefID(unitID) then
                local hp, maxHP = spGetUnitHealth(unitID)
                if hp and maxHP and (hp / maxHP) < RETREAT_HP then
                    local tx, tz = baseX, baseZ
                    local ux, _, uz = spGetUnitPosition(unitID)
                    if ux then
                        local rezID, rezDist = FindNearestRezBot(ux, uz)
                        if rezID and rezDist <= REZ_TO_RETREAT_RADIUS then
                            local rx, _, rz = spGetUnitPosition(rezID)
                            if rx then tx, tz = rx, rz end
                        end
                    end
                    local wy = spGetGroundHeight(tx, tz) or 0
                    spGiveOrderToUnit(unitID, CMD_MOVE, {tx, wy, tz}, {})
                end
            end
        end
    end
end
