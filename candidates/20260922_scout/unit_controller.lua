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
-- No GetUnitCommands on purpose: reading command queues back lags asymmetrically
-- between host and client.  Order state is tracked widget-side by army_broker.
local spGetUnitAllyTeam    = Spring.GetUnitAllyTeam
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spGetMyTeamID        = Spring.GetMyTeamID
local spGetGroundHeight    = Spring.GetGroundHeight
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder

local CMD_MOVE   = (CMD and CMD.MOVE)   or 10
local CMD_FIGHT  = (CMD and CMD.FIGHT)  or 16

-- ── Tunables ──────────────────────────────────────────────────────────────────

-- 0.15 was measured as too late: the unit died on the way home.  See
-- knowledge/lessons_learned.md -- this and the two below were measured wins that
-- were never actually present in any bot in the repo.
local RETREAT_HP         = 0.30  -- retreat when HP fraction drops below this
local MAP_MARGIN         = 200   -- keep units at least this far from map edges
local ADVANCE_MIN_UNITS  = 10    -- don't advance until this many combat units exist
local THRUST_FRAC        = 0.55  -- fraction of total army metal value in thrust zone
-- Must match NODE_ENEMY_RADIUS.  These are the same question asked twice -- "are
-- there enemies at this node" -- and having them disagree meant a node could be
-- engaged while the units standing on it were still ordered to MOVE, not FIGHT.
local LOCAL_ENEMY_RADIUS = 600   -- radius for per-unit FIGHT vs MOVE decision

local NODE_COUNT        = 32   -- nodes forming the contact curve
local NODE_ENEMY_RADIUS = 600  -- per-node enemy detection radius (world units)
local NODE_ADVANCE_STEP = 120  -- world-units a clear node advances per tick (every 90 frames)
local NODE_MAX_BULGE    = 500  -- max world-units a node can lead its neighbours' average
local NODE_MAX_LAG      = 600  -- max world-units a non-engaged node can trail its neighbours
local THRUST_NODE_HALF  = 5    -- thrust window = thrustIdx ± this many nodes
local ARC_RADIUS        = 1500 -- centre node forward distance at init (arc on top of map-entry advance)
local NODE_MIN_SPACING  = 100  -- lateral spacing between adjacent nodes (elmos)
-- The line used to be clipped to the map rectangle, which on this 12,288-elmo map
-- put its two ends on opposite map edges: halfWidth=7714, a 15,428-elmo front held
-- by ~20 units, one unit per ~375 elmos.  That is not a line, it is a cordon, and it
-- is why units appeared to be "sent nowhere".  A front is only as wide as the army
-- holding it can actually be.
local LINE_MAX_HALF_WIDTH = 2400
-- Units per node, used to size the ACTIVE span: a 32-node line with 12 units should
-- occupy 3 nodes, not 32.
local UNITS_PER_NODE      = 4
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

-- ── Shared framework modules ──────────────────────────────────────────────────
-- Loaded in Initialize so a missing file is a loud error, not a silent no-op.
local MM   = nil   -- bar_framework/map_model.lua
local UQ   = nil   -- bar_framework/unit_query.lua
local TM   = nil   -- bar_framework/threat_map.lua
local ARMY = nil   -- bar_framework/army_broker.lua
local SP   = nil   -- bar_framework/scout_plan.lua

-- Frames a unit keeps its node before the line may move it to a different one.
local LINE_MIN_HOLD  = 300
-- Hysteresis so a repaired unit does not flicker between retreating and fighting.
local RETREAT_CLEAR  = 0.05
-- Reinforcements gather before joining the line: this many, or this long, whichever
-- comes first.
local MUSTER_SIZE        = 4
local MUSTER_MAX_WAIT    = 900
local MUSTER_RALLY_DIST  = 700

local musterPool = {}   -- [unitID] = frame it finished

-- ── State ─────────────────────────────────────────────────────────────────────

local myTeamID    = nil
local myAllyID    = nil
local combatUnits = {}   -- [unitID] = defID
local scoutUnits  = {}   -- [unitID] = defID
local baseX, baseZ     = nil, nil
local targetX, targetZ = nil, nil

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

local function HasEnemy(units)
    if not units then return false end
    for _, uid in ipairs(units) do
        local allyID = spGetUnitAllyTeam and spGetUnitAllyTeam(uid)
        if allyID and allyID ~= myAllyID then return true end
    end
    return false
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
    -- Clip to a width an army can actually hold, centred on where the map clip put
    -- it.  Without this the front is as wide as the map regardless of army size.
    local mid = (lmin + lmax) * 0.5
    if (lmax - lmin) * 0.5 > LINE_MAX_HALF_WIDTH then
        lmin, lmax = mid - LINE_MAX_HALF_WIDTH, mid + LINE_MAX_HALF_WIDTH
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

    -- Units still mustering are not on the line, so they must not widen it: sizing
    -- the front off units that are standing at the rally point spreads the ones who
    -- actually got there.
    local unitList = {}
    for unitID, defID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) and not musterPool[unitID] then
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

    -- Only occupy as many nodes as we have units to fill: 12 units hold 3 nodes, not
    -- all 32.  Previously every node was always in play, so the army was dealt out
    -- across the whole front however few of them there were, and each arrived alone.
    local activeCount = math.max(1, math.ceil(#unitList / UNITS_PER_NODE))
    local activeLo    = math.max(1, thrustNodeIdx - math.floor(activeCount / 2))
    local activeHi    = math.min(NODE_COUNT, activeLo + activeCount - 1)
    activeLo          = math.max(1, activeHi - activeCount + 1)

    -- Thrust window, clipped to the active span.
    local thrustLo = math.max(activeLo, thrustNodeIdx - THRUST_NODE_HALF)
    local thrustHi = math.min(activeHi, thrustNodeIdx + THRUST_NODE_HALF)

    -- Wings are the rest of the ACTIVE span, nearest the thrust first, skipping nodes
    -- stuck at the map edge -- those have no room to advance, so units sent there are
    -- wasted.
    local wingNodes = {}
    for i = activeLo, activeHi do
        if (i < thrustLo or i > thrustHi) and not nodes[i].atEdge then
            wingNodes[#wingNodes + 1] = i
        end
    end
    table.sort(wingNodes, function(a, b)
        return math.abs(a - thrustNodeIdx) < math.abs(b - thrustNodeIdx)
    end)

    local positions = {}
    local load      = {}

    -- Keep a unit on the node it already holds while that node is still valid, and
    -- otherwise put it on the emptiest one.  The old round-robin re-dealt every unit
    -- from scratch on each pass, so building or losing a single unit shifted the
    -- whole army one node sideways and nobody ever reached their position.
    local function Place(units, validNodes)
        if #validNodes == 0 then return end
        local valid = {}
        for _, n in ipairs(validNodes) do valid[n] = true end

        local unplaced = {}
        for _, uid in ipairs(units) do
            local cur = ARMY and ARMY.Slot(uid)
            if cur and valid[cur] then
                positions[uid] = cur
                load[cur] = (load[cur] or 0) + 1
            else
                unplaced[#unplaced + 1] = uid
            end
        end

        for _, uid in ipairs(unplaced) do
            local best, bestLoad = validNodes[1], math.huge
            for _, n in ipairs(validNodes) do
                local l = load[n] or 0
                if l < bestLoad then best, bestLoad = n, l end
            end
            positions[uid] = best
            load[best] = (load[best] or 0) + 1
        end
    end

    local thrustNodes = {}
    for i = thrustLo, thrustHi do thrustNodes[#thrustNodes + 1] = i end

    Place(thrustUnits, thrustNodes)
    Place(wingUnits, #wingNodes > 0 and wingNodes or thrustNodes)

    return positions
end

-- ── Scout assignment ──────────────────────────────────────────────────────────

-- Scouts now go through the same broker as everything else, so a scout can be
-- re-tasked the moment its sector is seen instead of wandering until it goes idle.
-- The plan itself (find the spawn, then picket the approach) lives in scout_plan.
local function AssignScouts(frame)
    if not SP or not ARMY then return end

    local scouts, mobile = {}, {}
    for unitID in pairs(scoutUnits) do
        if spGetUnitDefID(unitID) then
            scouts[#scouts + 1] = unitID
            mobile[#mobile + 1] = unitID
        end
    end
    -- Every mobile unit clears the sectors it stands in, so the army keeps the map
    -- fresh as it moves and scouts are spent only on what nobody else is looking at.
    for unitID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) then mobile[#mobile + 1] = unitID end
    end
    SP.Observe(frame, mobile)

    local _, _, _, income = Spring.GetTeamResources(myTeamID, "metal")
    for unitID, spec in pairs(SP.Plan(frame, scouts, income or 0)) do
        ARMY.Claim(ARMY.PRIO.SCOUT, unitID, spec, frame)
    end
end

-- ── Line orders ───────────────────────────────────────────────────────────────

-- The line is now the lowest-priority duty: it gets whatever no other job claimed.
-- Claims are restated every pass; the broker decides whether an order is actually
-- worth sending, so this no longer waits for a unit to go idle before it can react
-- to the front moving.
local function IssueLineOrders(frame)
    if not lineInited or not baseX or not nodes or not ARMY then return end

    local positions = AssignUnitPositions()

    for unitID, nodeIdx in pairs(positions) do
        local node = nodes[nodeIdx]
        if node then
            local wx, wz = NodeWorldPos(node)
            local cmd = node.engaged and CMD_FIGHT or CMD_MOVE
            if cmd == CMD_MOVE and spGetUnitsInCylinder then
                if HasEnemy(spGetUnitsInCylinder(wx, wz, LOCAL_ENEMY_RADIUS)) then
                    cmd = CMD_FIGHT
                end
            end
            ARMY.Claim(ARMY.PRIO.LINE, unitID, {
                role = "LINE", cmd = cmd, x = wx, z = wz,
                slot = nodeIdx, minHold = LINE_MIN_HOLD,
            }, frame)
        end
    end
end

-- Hold newly built units at a rally point until enough have gathered to be worth
-- sending.  A unit that walks to the front the moment it finishes arrives alone and
-- dies alone; this is the piecemeal-engagement problem the pm_* tracker fields
-- measure.  The timeout matters as much as the count: with a slow factory, waiting
-- for a full group forever is its own failure.
local function UpdateMuster(frame)
    if not ARMY or not baseX then return end

    local n, oldest = 0, nil
    for unitID, joined in pairs(musterPool) do
        if spGetUnitDefID(unitID) then
            n = n + 1
            if not oldest or joined < oldest then oldest = joined end
        else
            musterPool[unitID] = nil
        end
    end
    if n == 0 then return end

    if n >= MUSTER_SIZE or (oldest and (frame - oldest) >= MUSTER_MAX_WAIT) then
        for unitID in pairs(musterPool) do
            if ARMY.RoleOf(unitID) == "MUSTER" then ARMY.Release(unitID) end
            musterPool[unitID] = nil
        end
        return
    end

    -- Rally ahead of the base so the group does not sit in the factory's exit.
    local rx = baseX + advDir.x * MUSTER_RALLY_DIST
    local rz = baseZ + advDir.z * MUSTER_RALLY_DIST
    if MM then rx, rz = MM.Clamp(rx, rz, MAP_MARGIN) end
    for unitID in pairs(musterPool) do
        ARMY.Claim(ARMY.PRIO.MUSTER, unitID, {
            role = "MUSTER", cmd = CMD_MOVE, x = rx, z = rz,
        }, frame)
    end
end

-- Pull badly damaged units home, and hand them back to the line once repaired.
-- Without the release a retreated unit would keep its priority-1 duty forever and
-- never rejoin, because nothing lower may claim it.
local function UpdateRetreats(frame)
    if not ARMY or not baseX then return end
    for unitID in pairs(combatUnits) do
        if spGetUnitDefID(unitID) then
            local hp, maxHP = spGetUnitHealth(unitID)
            if hp and maxHP and maxHP > 0 then
                local frac = hp / maxHP
                if frac < RETREAT_HP then
                    ARMY.Claim(ARMY.PRIO.RETREAT, unitID, {
                        role = "RETREAT", cmd = CMD_MOVE, x = baseX, z = baseZ,
                    }, frame)
                elseif ARMY.RoleOf(unitID) == "RETREAT"
                       and frac >= RETREAT_HP + RETREAT_CLEAR then
                    ARMY.Release(unitID)
                end
            end
        end
    end
end

-- ── Widget callbacks ──────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID()
    myAllyID = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()

    local okM, rM = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/map_model.lua")
    local okU, rU = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/unit_query.lua")
    local okT, rT = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/threat_map.lua")
    local okA, rA = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/army_broker.lua")
    if not okA then Spring.Echo("[UnitCtrl] ERROR loading army_broker: " .. tostring(rA)); return end
    ARMY = rA
    local okS, rS = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/scout_plan.lua")
    if not okS then Spring.Echo("[UnitCtrl] ERROR loading scout_plan: " .. tostring(rS)); return end
    SP = rS
    if not okM then Spring.Echo("[UnitCtrl] ERROR loading map_model: "  .. tostring(rM)); return end
    if not okU then Spring.Echo("[UnitCtrl] ERROR loading unit_query: " .. tostring(rU)); return end
    if not okT then Spring.Echo("[UnitCtrl] ERROR loading threat_map: " .. tostring(rT)); return end
    MM, UQ, TM = rM, rU, rT
    MM.Init(myTeamID, myAllyID)
    TM.Init{ MM = MM, UQ = UQ, teamID = myTeamID, allyID = myAllyID }
    SP.Init{ MM = MM, UQ = UQ, TM = TM, allyID = myAllyID }
end

function widget:UnitCreated(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if IsCommander(unitDefID) and not baseX then
        local x, _, z = spGetUnitPosition(unitID)
        if x then
            baseX, baseZ = x, z
            if MM then MM.SetHome(x, z) end
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
            if x then
                baseX, baseZ = x, z
                if MM then MM.SetHome(x, z) end
                InitContactLine()
            end
        end
        return
    end

    if IsScoutDef(unitDefID) then
        scoutUnits[unitID] = unitDefID
    elseif d.weapons and #d.weapons > 0 then
        combatUnits[unitID] = unitDefID
        musterPool[unitID]  = Spring.GetGameFrame()
    end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer,
                            weaponDefID, projectileID, attackerID, attackerDefID)
    if not TM or unitTeam ~= myTeamID then return end
    TM.OnDamaged(unitID, unitDefID, damage, weaponDefID, projectileID,
                 attackerID, attackerDefID, Spring.GetGameFrame())
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID)
    if TM then
        TM.OnUnitDestroyed(unitID, unitDefID, teamID == myTeamID,
                           Spring.GetGameFrame(), attackerID)
    end
    combatUnits[unitID]   = nil
    scoutUnits[unitID]    = nil
    musterPool[unitID]    = nil
    if SP then SP.Forget(unitID) end
end

-- One-shot check that the shared geometry and unit-stat helpers agree with the
-- game.  Travel frames are printed for the units that actually kill this bot, at
-- THIS match's spawn distance -- arrival times differ by ~18% between cross and
-- in-line spawns, so a deadline copied from one run as a frame number is wrong on
-- most others.
local geomEchoed = false
local function EchoGeometry()
    if geomEchoed or not MM or not UQ or not MM.Ready() then return end
    geomEchoed = true

    local mx, mz = MM.MapSize()
    local hx, hz = MM.Home()
    local fx, fz = MM.Foe()
    local ax, az = MM.Axis()
    Spring.Echo(string.format(
        "[UC/geom] map %dx%d home %d,%d foe %d,%d (%s) dist %d axis %.2f,%.2f",
        mx, mz, hx, hz, fx, fz, MM.FoeSource(), MM.Dist(), ax, az))
    Spring.Echo(string.format(
        "[UC/geom] halfplane home=%s foe=%s mid=%s (expect true/false/true)",
        tostring(MM.IsOurHalf(hx, hz)), tostring(MM.IsOurHalf(fx, fz)),
        tostring(MM.IsOurHalf(select(1, MM.Mid()), select(2, MM.Mid())))))

    -- Everything corvp can build, plus the units that actually kill this bot.
    local probe = {"corbw", "corveng", "corshad", "corape"}
    local vp = UnitDefNames and UnitDefNames["corvp"]
    if vp and vp.buildOptions then
        for _, optID in ipairs(vp.buildOptions) do
            local od = UnitDefs[optID]
            if od and (od.speed or 0) > 0 and not od.isBuilder then
                probe[#probe + 1] = od.name
            end
        end
    end

    for _, n in ipairs(probe) do
        local ud = UnitDefNames and UnitDefNames[n]
        if ud then
            local d = ud.id
            Spring.Echo(string.format(
                "[UC/def] %-9s spd=%-6.1f cost=%-5.0f gnd=%-5s aaOnly=%-5s scout=%-5s rng=%-6.0f travel=%-6.0ff intrinsic=%.0f",
                n, UQ.max_speed(d), UQ.metal_cost(d),
                tostring(UQ.can_hit_ground(d)), tostring(UQ.is_dedicated_aa(d)),
                tostring(UQ.is_scout(d)), UQ.max_weapon_range(d),
                MM.TravelFrames(UQ.max_speed(d)), TM and TM.Intrinsic(d) or 0))
        end
    end
end

-- Report each attack once when it first crosses a band, and again if it escalates.
-- Echo-only for now: nothing acts on this yet, so the numbers can be checked against
-- the exploiter bots' known arrival times before any unit is moved because of them.
local incidentSeen = {}
local function EchoThreat(frame)
    if not TM then return end
    local air = TM.ChannelScore("air")
    local gnd = TM.ChannelScore("ground")

    for _, inc in ipairs(TM.Incidents()) do
        local score = TM.IncidentScore(inc)
        local band  = TM.IncidentBand(inc, score)
        if band ~= "ignore" and incidentSeen[inc] ~= band then
            incidentSeen[inc] = band
            local sec = math.floor(frame / 30)
            local urgency, worst = TM.ProductionUrgency()
            local ch = inc.channel == "unknown" and "ground" or inc.channel
            Spring.Echo(string.format(
                "[UC/threat] %d:%02d %-7s %-7s score=%-6.0f at %d,%d leaving=%-5s | reach=%-6.0f total=%-6.0f | deficit=%.2f %s",
                math.floor(sec / 60), sec % 60, band, inc.channel, score,
                inc.x, inc.z, tostring(TM.IsLeaving(inc)),
                TM.AvailableStrength(ch, inc.x, inc.z), TM.OwnStrength(ch),
                worst, urgency))
        end
    end
end

function widget:GameFrame(frame)
    if frame % 30 == 0 then EchoGeometry() end

    if TM then
        if frame % TM.SCAN_PERIOD == 0 then TM.ScanContacts(frame) end
        if frame % 30 == 0 then TM.Update(frame); EchoThreat(frame) end
    end

    -- Scan for enemies every ~5s.  Sector freshness is now tracked by scout_plan.
    if frame % 150 == 0 then
        UpdateEnemyTarget()
    end

    -- Update nodes (advance/hold/smooth) every ~3s.
    if frame % 90 == 0 then
        UpdateNodes()
    end

    -- Retreat is checked more often than the line is replanned, and claimed first
    -- so a damaged unit is off the line before the line tries to re-task it.
    if frame % 30 == 0 then
        if ARMY then ARMY.Sweep(frame) end
        UpdateRetreats(frame)
        UpdateMuster(frame)
    end

    -- Issue guidance and scout orders every ~2s.
    if frame % 60 == 0 then
        AssignScouts(frame)
        IssueLineOrders(frame)
    end

    if ARMY and frame % 1800 == 0 then
        local n, byRole = ARMY.Stats()
        local parts = {}
        for role, c in pairs(byRole) do parts[#parts + 1] = role .. "=" .. c end
        Spring.Echo(string.format("[UC/army] %d:%02d units=%d orders=%d %s",
            math.floor(frame / 1800), math.floor(frame / 30) % 60,
            n, ARMY.OrdersIssued(), table.concat(parts, " ")))
    end
end
