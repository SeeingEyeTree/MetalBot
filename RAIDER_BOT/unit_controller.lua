-- unit_controller.lua  ─  Scout and combat unit manager for Beyond All Reason
-- Scouts explore the map by sector. Combat units hold a deformable "contact line"
-- made of NODE_COUNT independent nodes. Each node advances or holds based on its
-- own local combat state, allowing the front to curve around contested areas.
-- ~55% of army metal value clusters at whichever node group is most contested.
-- Compatible with macro_controller.lua: never touches builders, factories, or commanders.

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

local CMD_MOVE   = (CMD and CMD.MOVE)   or 10
local CMD_PATROL = (CMD and CMD.PATROL) or 15
local CMD_FIGHT  = (CMD and CMD.FIGHT)  or 16

-- ── Tunables ──────────────────────────────────────────────────────────────────

local RETREAT_HP         = 0.15  -- retreat when HP fraction drops below this
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

-- Lateral extent of the perpendicular line through the map centre, clipped to the
-- map rectangle. Its two ends land exactly on map edges, so nodes spread across
-- the full width of the map instead of a fixed-size window around the base.
local function LateralRange()
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local cx, cz = mapX * 0.5, mapZ * 0.5
    local lmin, lmax = -math.huge, math.huge
    if math.abs(perpDir.x) > 1e-6 then
        local a = (MAP_MARGIN - cx) / perpDir.x
        local b = (mapX - MAP_MARGIN - cx) / perpDir.x
        lmin = math.max(lmin, math.min(a, b))
        lmax = math.min(lmax, math.max(a, b))
    end
    if math.abs(perpDir.z) > 1e-6 then
        local a = (MAP_MARGIN - cz) / perpDir.z
        local b = (mapZ - MAP_MARGIN - cz) / perpDir.z
        lmin = math.max(lmin, math.min(a, b))
        lmax = math.min(lmax, math.max(a, b))
    end
    if lmin > lmax or lmin == -math.huge then
        return -NODE_MIN_SPACING * (NODE_COUNT - 1) / 2, NODE_MIN_SPACING * (NODE_COUNT - 1) / 2
    end
    return lmin, lmax
end

-- Spread node laterals evenly over the full map width (node.t in [-1,1] is fixed;
-- lateral follows the current advance direction so the ends stay on the map edges).
local function SpreadNodeLaterals()
    local lmin, lmax = LateralRange()
    local mid, half = (lmin + lmax) * 0.5, (lmax - lmin) * 0.5
    for i = 1, NODE_COUNT do
        nodes[i].lateral = mid + nodes[i].t * half
    end
end

local function InitNodes()
    nodes = {}
    thrustNodeIdx = math.floor(NODE_COUNT / 2)
    for i = 1, NODE_COUNT do
        nodes[i] = { t = (i - 1) / (NODE_COUNT - 1) * 2 - 1, lateral = 0, adv = 0,
                     engaged = false, atEdge = false }
    end
    SpreadNodeLaterals()
    for i = 1, NODE_COUNT do
        local node   = nodes[i]
        local minAdv = MinAdvForNode(node.lateral)
        -- Arc on top of the minimum advance needed to land on-map.
        -- Centre gets full ARC_RADIUS bump; ends get 0 and sit on the map edge.
        local arcBump = ARC_RADIUS * math.max(0, math.cos(math.pi * 0.5 * node.t))
        node.adv = math.min(minAdv + arcBump, MaxAdvForNode(node.lateral))
    end
end

local function InitContactLine()
    if lineInited or not baseX then return end
    lineInited = true
    local tx, tz = DefaultTarget()
    RecomputeLineDir(tx, tz)
    InitNodes()
    local lmin, lmax = LateralRange()
    lineHalfWidth = (lmax - lmin) * 0.5
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
    SpreadNodeLaterals()

    local count = 0
    for _ in pairs(combatUnits) do count = count + 1 end
    -- Advance toward the default target even before anything has been sighted.
    -- Requiring targetX (which is only set after seeing MIN_ENEMY_SAMPLE enemies)
    -- meant that a bot which never scouted never moved at all: no sighting, no
    -- target, no advance, army parked at home for the whole game.
    local canAdvance = count >= ADVANCE_MIN_UNITS

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
        node.adv     = math.max(node.adv, MinAdvForNode(node.lateral))
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

-- ── Fighter raid (RAIDER_BOT) ─────────────────────────────────────────────────
-- Fighters are pulled out of the contact line and sent across the map as one group
-- to hunt the enemy's air constructors.  This is a deliberate exploit, there to be
-- the "unit test" that an opponent's air defence is checked against: lab_controller
-- makes the fighters, this decides where they go.  Everything is echoed as [RAID]
-- lines so a run shows when the threat appeared, not just that it did.

local RAID_DEFS = { corveng = "fighter", corshad = "bomber", corfink = "spotter" }
local RAID_WAVE_BOMBERS = 3     -- launch once this many bombers wait at home: fewer is not
                                -- enough to matter, and bombers are one-way
local RAID_FORCE_FRAME = 11700  -- ...or at 6:30 with at least 2, so it cannot stall
local RAID_CLUSTER_R   = 160    -- bombs land within about this of the aim point
local RAID_RETARGET    = 1.25   -- a new aim point must be this much denser to switch
local RAID_STALE_FRAC  = 0.5    -- re-aim once what is left at the aim is under this share
                                -- of what was there when it was chosen
local RAID_MEMORY      = 900    -- frames an enemy stays in the bombers' picture after it was
                                -- last seen; vision flickers, so "not visible" is not "dead"
local RAID_SWITCH_GAP  = 60     -- min frames between denser-cluster switches (not for a depleted aim)
local RAID_DROP_LOOK   = 45     -- frames after a bomb drop to look again (bombs take a moment
                                -- to land, and the target may be gone by then)
local RAID_SEARCH_R    = 1600   -- how far from the group / enemy base to look for targets
local RAID_SWEEP_R     = 350    -- radius of the sweep around the enemy base
local RAID_ARRIVE_R    = 1200

local CMD_ATTACK = (CMD and CMD.ATTACK) or 20

local raidUnits    = {}    -- [unitID] = true once sent, false while waiting at home
local raidKind     = {}    -- [unitID] = "fighter" | "bomber"
local raidLaunched = false
local raidArrived  = false
local raidKills    = 0
local raidBaseX, raidBaseZ = nil, nil
local raidSweepIdx = 0

local function GameClock(frame)
    local sec = math.floor(frame / 30)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function RaidEnemyBase()
    if raidBaseX then return raidBaseX, raidBaseZ end
    local src = "mirror"
    if Spring.GetTeamStartPosition and Spring.GetTeamList and Spring.GetTeamInfo then
        for _, t in ipairs(Spring.GetTeamList()) do
            local _, _, _, _, _, allyID = Spring.GetTeamInfo(t)
            if t ~= myTeamID and allyID ~= myAllyID then
                local x, _, z = Spring.GetTeamStartPosition(t)
                if x and x > 0 and z and z > 0 then
                    raidBaseX, raidBaseZ, src = x, z, "start_pos"
                    break
                end
            end
        end
    end
    if not raidBaseX then
        -- Start positions are unknown: the maps are symmetric, so mirror ours.
        raidBaseX = (Game.mapSizeX or 8192) - baseX
        raidBaseZ = (Game.mapSizeZ or 8192) - baseZ
    end
    Spring.Echo(string.format("[RAID] enemy base (%s) at %d, %d", src, raidBaseX, raidBaseZ))
    return raidBaseX, raidBaseZ
end

-- Best visible enemy for a group: fighters can only hit aircraft, bombers only ground
-- targets.  Constructors first (the point of the raid), then anything else; ties go to
-- whichever is nearest the group.
local function RaidPickTarget(cx, cz, bx, bz, wantAir)
    local best, bestScore = nil, math.huge
    for _, centre in ipairs({ {cx, cz}, {bx, bz} }) do
        local list = spGetUnitsInCylinder(centre[1], centre[2], RAID_SEARCH_R)
        for _, uid in ipairs(list or {}) do
            local allyID = spGetUnitAllyTeam(uid)
            local defID  = spGetUnitDefID(uid)
            local d      = defID and UnitDefs[defID]
            if allyID and allyID ~= myAllyID and d and (d.canFly and true or false) == wantAir then
                local ux, _, uz = spGetUnitPosition(uid)
                if ux then
                    local dist = math.sqrt((ux - cx) ^ 2 + (uz - cz) ^ 2)
                    local tier = (d.isBuilder and not d.isFactory) and 0 or 1
                    local score = tier * 100000 + dist
                    if score < bestScore then bestScore = score; best = uid end
                end
            end
        end
    end
    return best
end

-- Where to bomb: the densest cluster of visible enemy ground units/structures near the
-- enemy base, by metal value, so one pass lands on a whole mex/wind field instead of on
-- the single nano a nearest-target rule picks.
local raidSeen = {}   -- [enemyUnitID] = { x, z, v, frame }: what the bombers know is out there

local function RaidGather(bx, bz, frame)
    for _, uid in ipairs(spGetUnitsInCylinder(bx, bz, RAID_SEARCH_R) or {}) do
        local allyID = spGetUnitAllyTeam(uid)
        local defID  = spGetUnitDefID(uid)
        local d      = defID and UnitDefs[defID]
        if allyID and allyID ~= myAllyID and d and not d.canFly then
            local x, _, z = spGetUnitPosition(uid)
            if x then
                raidSeen[uid] = { x = x, z = z, v = math.max(d.metalCost or 0, 10), frame = frame }
            end
        end
    end
    -- Forget what has not been seen for a while.  Things that are destroyed are removed
    -- at once in UnitDestroyed; this only ages out the ones that went unseen.
    local pts = {}
    for uid, e in pairs(raidSeen) do
        if frame - e.frame > RAID_MEMORY then
            raidSeen[uid] = nil
        elseif #pts < 220 then
            pts[#pts + 1] = e
        end
    end
    return pts
end

-- Best cluster among the visible points: x, z (value-weighted centre), score; or nil when
-- nothing is visible yet (the spotter has not arrived).
local function RaidBestCluster(pts)
    if #pts == 0 then return nil end
    local r2 = RAID_CLUSTER_R * RAID_CLUSTER_R
    local bestScore, bestI = -1, 1
    for i, a in ipairs(pts) do
        local sum = 0
        for _, b in ipairs(pts) do
            if (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= r2 then sum = sum + b.v end
        end
        if sum > bestScore then bestScore, bestI = sum, i end
    end
    -- Aim at the value-weighted centre of that cluster, not at one unit in it.
    local c, wx, wz, wsum = pts[bestI], 0, 0, 0
    for _, b in ipairs(pts) do
        if (c.x - b.x) ^ 2 + (c.z - b.z) ^ 2 <= r2 then
            wx, wz, wsum = wx + b.x * b.v, wz + b.z * b.v, wsum + b.v
        end
    end
    return wx / wsum, wz / wsum, bestScore
end

-- What is still standing (and visible) at a point.  This is what tells the bombers that
-- the spot they were sent to has already been flattened.
local function RaidValueAt(pts, x, z)
    local r2, sum = RAID_CLUSTER_R * RAID_CLUSTER_R, 0
    for _, b in ipairs(pts) do
        if (x - b.x) ^ 2 + (z - b.z) ^ 2 <= r2 then sum = sum + b.v end
    end
    return sum
end

-- True on the tick a bomber has just dropped its load (its bomb weapon went from ready
-- to reloading).  Bombers are one-way, so the drop is the moment that matters.
local raidReloading = {}
local function RaidBomberDropped(uid, frame)
    local ok, ready = pcall(Spring.GetUnitWeaponState, uid, 1, "reloadState")
    if not ok or type(ready) ~= "number" then
        ok, ready = pcall(Spring.GetUnitWeaponState, uid, 1, "reloadFrame")
    end
    if not ok or type(ready) ~= "number" then return false end
    local reloading = ready > frame
    local was = raidReloading[uid]
    raidReloading[uid] = reloading
    return reloading and not was
end

local raidAim = nil   -- { x, z, score } the bombers are committed to

local function UpdateRaid(frame)
    if not baseX then return end
    -- Two groups: raiders still at home waiting for a wave, and raiders in the field.
    -- Reinforcements are held until they are a wave of their own, so they do not fly
    -- one at a time into whatever killed the last group.
    local home, field, sx, sz, homeBombers = {}, {}, 0, 0, 0
    for uid, sent in pairs(raidUnits) do
        local x, _, z = spGetUnitPosition(uid)
        if x then
            if sent then
                field[#field + 1] = uid
                sx, sz = sx + x, sz + z
            else
                home[#home + 1] = uid
                if raidKind[uid] == "bomber" then homeBombers = homeBombers + 1 end
            end
        else
            raidUnits[uid] = nil
        end
    end

    local bx, bz = RaidEnemyBase()
    local firstWave = not raidLaunched
    if homeBombers >= RAID_WAVE_BOMBERS
       or (firstWave and frame >= RAID_FORCE_FRAME and homeBombers >= 2) then
        raidLaunched = true
        local nf, nb = 0, 0
        for _, uid in ipairs(home) do
            raidUnits[uid] = true
            field[#field + 1] = uid
            if raidKind[uid] == "bomber" then nb = nb + 1 else nf = nf + 1 end
            local x, _, z = spGetUnitPosition(uid)
            sx, sz = sx + x, sz + z
        end
        Spring.Echo(string.format("[RAID] %s frame=%d (%s) fighters=%d bombers=%d",
            firstWave and "launch" or "reinforce", frame, GameClock(frame), nf, nb))
    end

    local n = #field
    if n == 0 then return end
    local cx, cz = sx / n, sz / n

    if not raidArrived then
        for _, uid in ipairs(field) do
            local x, _, z = spGetUnitPosition(uid)
            if x and (x - bx) ^ 2 + (z - bz) ^ 2 < RAID_ARRIVE_R ^ 2 then
                raidArrived = true
                Spring.Echo(string.format("[RAID] arrived frame=%d (%s) in field=%d",
                    frame, GameClock(frame), n))
                break
            end
        end
    end

    -- Nothing to shoot: sweep the enemy base.  Raiders on FIGHT engage anything in
    -- range on the way, and idle ones are simply handed the next waypoint.
    local waypoints = {
        { bx, bz },
        { bx + RAID_SWEEP_R, bz }, { bx, bz + RAID_SWEEP_R },
        { bx - RAID_SWEEP_R, bz }, { bx, bz - RAID_SWEEP_R },
    }
    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
    -- Bombers: one shared aim point, chosen by density and CHECKED AGAINST WHAT IS LEFT
    -- there.  The old rule compared a new cluster with the value the aim had when it was
    -- chosen, so once the bombs had flattened it every bomber kept flying at empty ground.
    -- Re-aim when: nothing dense is chosen yet; the aim has lost over half its value; a
    -- clearly denser spot exists; or a bomber has just dropped and, a moment later, a
    -- better spot exists than what remains at the aim.
    local pts = RaidGather(bx, bz, frame)
    local bx2, bz2, bscore = RaidBestCluster(pts)
    local dropped = false
    for _, uid in ipairs(field) do
        if raidKind[uid] == "bomber" and RaidBomberDropped(uid, frame) then dropped = true end
    end
    if dropped and raidAim and not raidAim.lookAt then
        raidAim.lookAt = frame + RAID_DROP_LOOK
        Spring.Echo(string.format("[RAID] bomb dropped frame=%d; looking again at %d",
            frame, raidAim.lookAt))
    end
    local retarget = false
    if bx2 then
        local live = raidAim and RaidValueAt(pts, raidAim.x, raidAim.z) or 0
        local why
        if not raidAim or not raidAim.dense then
            why = "first sighting"
        elseif live < raidAim.score * RAID_STALE_FRAC then
            why = string.format("aim depleted (%d of %d left)", live, raidAim.score)
        elseif bscore > live * RAID_RETARGET and frame - (raidAim.since or 0) >= RAID_SWITCH_GAP then
            why = "denser cluster"
        elseif raidAim.lookAt and frame >= raidAim.lookAt then
            if bscore > live and (bx2 - raidAim.x) ^ 2 + (bz2 - raidAim.z) ^ 2 > 60 ^ 2 then
                why = "post-drop look"
            end
            raidAim.lookAt = nil
        end
        if why then
            raidAim = { x = bx2, z = bz2, score = bscore, dense = true, since = frame }
            retarget = true
            Spring.Echo(string.format("[RAID] bomb aim (%d, %d) cluster value=%d frame=%d: %s",
                bx2, bz2, bscore, frame, why))
        end
    elseif not raidAim then
        -- Nothing visible yet: head for the enemy start position; the spotter is ahead.
        raidAim = { x = bx, z = bz, score = 0, dense = false }
        retarget = true
    end

    for _, kind in ipairs({ "spotter", "fighter", "bomber" }) do
        local group = {}
        for _, uid in ipairs(field) do
            if raidKind[uid] == kind then group[#group + 1] = uid end
        end
        if #group > 0 then
            if kind == "bomber" then
                local ay = spGetGroundHeight(raidAim.x, raidAim.z) or 0
                for _, uid in ipairs(group) do
                    -- Ground-attack the aim point (bombers on FIGHT only bomb what they
                    -- can see); re-issue to idle ones so a second pass is made too.
                    if retarget or IsIdle(uid) then
                        spGiveOrderToUnit(uid, CMD_ATTACK, {raidAim.x, ay, raidAim.z}, {})
                    end
                end
            else
                local target = (kind == "fighter") and RaidPickTarget(cx, cz, bx, bz, true) or nil
                for _, uid in ipairs(group) do
                    if target then
                        spGiveOrderToUnit(uid, CMD_ATTACK, {target}, {})
                    elseif IsIdle(uid) then
                        raidSweepIdx = raidSweepIdx % #waypoints + 1
                        local wp = waypoints[raidSweepIdx]
                        local wx = math.max(MAP_MARGIN, math.min(mapX - MAP_MARGIN, wp[1]))
                        local wz = math.max(MAP_MARGIN, math.min(mapZ - MAP_MARGIN, wp[2]))
                        -- The spotter only needs to be over the base and stay alive long
                        -- enough to show the bombers where the value is.
                        local cmd = (kind == "spotter") and CMD_MOVE or CMD_FIGHT
                        spGiveOrderToUnit(uid, cmd, {wx, spGetGroundHeight(wx, wz) or 0, wz}, {})
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
    if not d or d.isFactory or d.isBuilder then return end
    if not d.speed or d.speed <= 0 then return end

    if IsCommander(unitDefID) then
        if not baseX then
            local x, _, z = spGetUnitPosition(unitID)
            if x then baseX, baseZ = x, z; InitContactLine() end
        end
        return
    end

    if RAID_DEFS[d.name] then
        -- Bombers and fighters wait at home for a wave; the spotter goes at once, so
        -- it is over the enemy base before they are.
        raidUnits[unitID] = (RAID_DEFS[d.name] == "spotter")
        raidKind[unitID]  = RAID_DEFS[d.name]
    elseif IsScoutDef(unitDefID) then
        scoutUnits[unitID] = unitDefID
    elseif d.weapons and #d.weapons > 0 then
        combatUnits[unitID] = unitDefID
    end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID)
    if attackerID and raidUnits[attackerID] and teamID ~= myTeamID then
        local d = unitDefID and UnitDefs[unitDefID]
        raidKills = raidKills + 1
        Spring.Echo(string.format("[RAID] kill #%d %s%s frame=%d", raidKills,
            d and d.name or "?",
            (d and d.isBuilder and d.canFly and not d.isFactory) and " (air con)" or "",
            Spring.GetGameFrame and Spring.GetGameFrame() or 0))
    end
    raidSeen[unitID]      = nil
    raidUnits[unitID]     = nil
    raidKind[unitID]      = nil
    raidReloading[unitID] = nil
    combatUnits[unitID]   = nil
    scoutUnits[unitID]    = nil
    scoutAssigned[unitID] = nil
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
    end

    -- Fighters are fast, so re-aim them every second.
    if frame % 30 == 0 then UpdateRaid(frame) end

    -- Retreat check every ~1s: override active commands for critical HP units.
    if frame % 30 == 0 and baseX then
        for unitID in pairs(combatUnits) do
            if spGetUnitDefID(unitID) then
                local hp, maxHP = spGetUnitHealth(unitID)
                if hp and maxHP and (hp / maxHP) < RETREAT_HP then
                    local wy = spGetGroundHeight(baseX, baseZ) or 0
                    spGiveOrderToUnit(unitID, CMD_MOVE, {baseX, wy, baseZ}, {})
                end
            end
        end
    end
end
