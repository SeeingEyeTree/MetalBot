-- unit_controller.lua  ─  Scout and combat unit manager for Beyond All Reason
-- Scouts explore the map by sector. Combat units hold a deformable "contact line"
-- made of NODE_COUNT independent nodes. Each node advances or holds based on its
-- own local combat state, allowing the front to curve around contested areas.
-- ~55% of army metal value clusters at whichever node group is most contested.
-- Compatible with macro_controller.lua: never touches builders, factories, or commanders.
--
-- MECH_BOT additions, all from game_mechanics.md (sections in brackets):
--   * enemy_intel: a long memory of what the enemy has, feeding everything below [6.2]
--   * recon_plan: once pickets are up, the fastest scout(s) keep re-scouting the enemy
--     base and production; a map-wide sweep in the endgame [6.2, 9]
--   * raid_group: a capped slice of fast units raids weakly defended enemy eco and never
--     retreats [7, 7.2]
--   * anti-raid reserve: a few Shurikens stay home to intercept raids [7, 7.1]
--   * fighters split between home cover and the line [7.3]
--   * rez_crew: Graverobbers repair, resurrect and reclaim behind the army; wounded
--     units retreat to the nearest rez bot or nano instead of the base centre [1.4, 7.2]
--   * radar plane (corawac) over the army [7 utility]
--   * the line keeps pushing through a fight it is winning instead of freezing on
--     contact [7 "main army ... always trying to engage"]
--   * endgame: detect the won state, hunt the commander with scouts and bombers [9]

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
local TL   = nil   -- bar_framework/threat_log.lua (optional: [TML] rows for threat_map_viz)
local EI   = nil   -- bar_framework/enemy_intel.lua
local RP   = nil   -- bar_framework/recon_plan.lua
local RG   = nil   -- bar_framework/raid_group.lua
local RC   = nil   -- bar_framework/rez_crew.lua
local EG   = nil   -- bar_framework/endgame.lua

-- MECH_BOT tunables, one table so they cost one main-chunk local.
local MECH = {
    PICKET_SCOUTS      = 2,     -- scouts scout_plan keeps on the picket ring
    RECON_SCOUTS       = 1,     -- ...plus this many on recon of the enemy half
    RECON_SCOUTS_LATE  = 2,     -- ...and this many after RECON_LATE_FRAME
    RECON_LATE_FRAME   = 15 * 60 * 30,
    HUNT_SCOUTS        = 5,     -- endgame sweep
    FIND_SCOUTS        = 2,
    ANTI_RAID_SHARE    = 0.25,  -- share of raider-type units kept home...
    ANTI_RAID_MIN      = 2,     -- ...at least this many...
    ANTI_RAID_MAX      = 6,     -- ...at most this many
    HOME_FIGHTER_SHARE = 0.5,   -- share of fighters kept as home cover...
    HOME_FIGHTER_MIN   = 4,     -- ...at least this many
    PUSH_RATIO         = 1.3,   -- an engaged node advances when we outvalue them by this
    PUSH_RADIUS        = 900,   -- ...counting units this close to the node
    RADAR_BACK         = 900,   -- radar plane holds this far behind the army
    RADAR_SPREAD       = 1500,
    INTEL_PERIOD       = 90,
    ENEMY_BASE_R       = 2500,
}
local RADAR_PLANE_NAMES = { corawac = true, armawac = true }
local radarPlanes = {}   -- [unitID] = true
local bombers     = {}   -- [unitID] = true
local antiRaid    = {}   -- [unitID] = true: raider-type units kept home

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

-- Threat response.  Dispatch is absolute (see threat_map): if an attack crosses the
-- respond band, units go, whatever our production state.  These only size it.
local RESPOND_NEED_MULT   = 2.0   -- commit this multiple of the enemy value present
local RESPOND_MIN_UNITS   = 3     -- never send a lone unit to die
local RESPOND_ARMY_CAP    = 0.35  -- never commit more than this share of the army
local RESPOND_CHASE_RATIO = 1.10  -- an attacker this much faster, leaving, is not chased

local responding = {}   -- [unitID] = incident it was sent to

-- Home guard: the vehicle plant exists to defend the base, so its output stays there
-- instead of walking to the front; fighters fly cover over the commander, because
-- losing it ends the game.  Both remain eligible to RESPOND and return afterwards.
local HOME_GUARD_RADIUS = 1000   -- posts this far out from the base
local HOME_GUARD_ARC    = 1.05   -- spread across +-60 degrees of the enemy-facing side
local homeGuards  = {}           -- [unitID] = true
local commanderID = nil

-- The line's thrust window from the last assignment pass.  Response may borrow from
-- the wings but never the thrust: game_mechanics 7.1, "local/reserve reinforcements,
-- not main-army pulls".
local lineThrustLo, lineThrustHi = 1, 0

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
    -- The enemy's actual (or mirrored) spawn beats a guess at the far corner.
    if MM and MM.Ready() then return MM.Foe() end
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

-- Our combat value against their armed value around a point: >1 means we are ahead.
-- Unarmed enemies (eco, cons) do not hold a node back.
local function LocalBalance(x, z)
    local ours, theirs = 0, 0
    for _, uid in ipairs(spGetUnitsInCylinder(x, z, MECH.PUSH_RADIUS) or {}) do
        local defID = spGetUnitDefID(uid)
        if defID then
            if combatUnits[uid] then
                ours = ours + ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
            elseif spGetUnitAllyTeam(uid) ~= myAllyID and UQ and UQ.has_weapons(defID) then
                theirs = theirs + ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
            end
        end
    end
    if theirs <= 0 then return math.huge end
    return ours / theirs
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
            node.winning = node.engaged and LocalBalance(wx, wz) >= MECH.PUSH_RATIO
        end
        -- A node used to freeze whenever any enemy was within 600 elmos, which held
        -- the whole army near home (lessons 2026-09-24).  Now it keeps pushing, at half
        -- speed, through a fight it is clearly winning.
        if canAdvance and (not node.engaged or node.winning) then
            node.adv = node.adv + (node.engaged and NODE_ADVANCE_STEP * 0.5 or NODE_ADVANCE_STEP)
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
    -- Likewise units off responding, retreating or scouting are not on the line: only
    -- count what the line can actually command.
    local unitList = {}
    for unitID, defID in pairs(combatUnits) do
        local role = ARMY and ARMY.RoleOf(unitID)
        if spGetUnitDefID(unitID) and not musterPool[unitID] and not homeGuards[unitID]
           and (role == nil or role == "LINE") then
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
    lineThrustLo, lineThrustHi = thrustLo, thrustHi

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
    if RP then RP.Observe(frame, mobile) end

    -- Once the pickets are up (or the game is won), the fastest scouts go on recon of
    -- the enemy half instead: game_mechanics 6.2, scouting is tracking their army and
    -- production, and a picket ring never looks at their base again.
    local hunting = EG and EG.Hunting()
    local ringIDs, reconIDs = scouts, {}
    if RP and (hunting or SP.Mode() == "picket") then
        local nRecon = hunting and #scouts or math.max(0, #scouts - MECH.PICKET_SCOUTS)
        table.sort(scouts, function(a, b)
            local sa = UQ.max_speed(spGetUnitDefID(a))
            local sb = UQ.max_speed(spGetUnitDefID(b))
            if sa ~= sb then return sa > sb end
            return a < b
        end)
        ringIDs = {}
        for i, uid in ipairs(scouts) do
            if i <= nRecon then reconIDs[#reconIDs + 1] = uid
            else
                ringIDs[#ringIDs + 1] = uid
                RP.Forget(uid)
            end
        end
    end

    local _, _, _, income = Spring.GetTeamResources(myTeamID, "metal")
    for unitID, spec in pairs(SP.Plan(frame, ringIDs, income or 0)) do
        ARMY.Claim(ARMY.PRIO.SCOUT, unitID, spec, frame)
    end
    if RP and #reconIDs > 0 then
        for unitID, spec in pairs(RP.Plan(frame, reconIDs, hunting)) do
            ARMY.Claim(ARMY.PRIO.SCOUT, unitID, spec, frame)
        end
    end
end

-- How many scouts the lab controller should keep: FIND needs two, then the picket
-- ring plus recon, and the endgame sweep more.
local function ScoutWant(frame)
    if EG and EG.Hunting() then return MECH.HUNT_SCOUTS end
    if SP and SP.Mode() == "picket" then
        return MECH.PICKET_SCOUTS + (frame >= MECH.RECON_LATE_FRAME
            and MECH.RECON_SCOUTS_LATE or MECH.RECON_SCOUTS)
    end
    return MECH.FIND_SCOUTS
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

-- An unattributed attack still has to go to someone.  If only one channel has live
-- threat, it is almost certainly that one: the log showed `unknown` incidents
-- sitting beside `air=1211 gnd=0`, and sending vehicles at a bomber is useless.
local function ResolveChannel(inc)
    if inc.channel ~= "unknown" then return inc.channel end
    -- ApproachScore, not ChannelScore: scouted enemy buildings are all "ground" and
    -- would otherwise bias every unattributed hit away from air.
    return (TM.ApproachScore("air") > TM.ApproachScore("ground")) and "air" or "ground"
end

local function CanAnswer(defID, channel)
    if channel == "air" then return UQ.can_hit_air(defID) end
    return UQ.can_hit_ground(defID)
end

-- Send the nearest able units to each live attack.  Ported from bot.lua's
-- UpdateDefenseCoordination (:4286): candidates ranked by ETA, committed until a
-- value budget sized to the attack is met.  Changes from that version: channel
-- matching, the thrust-window exclusion, the army-share cap, and the no-chase rule.
local function DispatchResponses(frame)
    if not TM or not ARMY or not UQ then return end

    local live = {}
    for _, inc in ipairs(TM.Incidents()) do live[inc] = true end

    -- Stand down anyone whose attack is over, or who has been pulled off to retreat.
    for uid, inc in pairs(responding) do
        local role = ARMY.RoleOf(uid)
        if not live[inc] or not spGetUnitDefID(uid) or role == "RETREAT" then
            if role == "RESPOND" then ARMY.Release(uid) end
            responding[uid] = nil
        end
    end

    local armyValue = 0
    for uid, defID in pairs(combatUnits) do
        if spGetUnitDefID(uid) then armyValue = armyValue + TM.Intrinsic(defID) end
    end
    local capLeft = armyValue * RESPOND_ARMY_CAP
    for uid in pairs(responding) do capLeft = capLeft - TM.Intrinsic(combatUnits[uid]) end

    local incs = {}
    for _, inc in ipairs(TM.Incidents()) do
        local s = TM.IncidentScore(inc)
        local band = TM.IncidentBand(inc, s)
        if band == "respond" or band == "alarm" then incs[#incs + 1] = { inc = inc, s = s } end
    end
    table.sort(incs, function(a, b) return a.s > b.s end)

    for _, e in ipairs(incs) do
        local inc     = e.inc
        local channel = ResolveChannel(inc)

        local enemyV, fastest = 0, 0
        for _, c in pairs(TM.Contacts()) do
            if (c.x - inc.x) ^ 2 + (c.z - inc.z) ^ 2 <= TM.INCIDENT_MERGE ^ 2 then
                enemyV = enemyV + c.v
                local sp = UQ.max_speed(c.defID)
                if sp > fastest then fastest = sp end
            end
        end
        -- An unseen attacker (bomber run) leaves enemyV at zero; the incident's own
        -- score, which counts what it has already destroyed, stands in for it.
        local need    = math.max(enemyV * RESPOND_NEED_MULT, e.s)
        local leaving = TM.IsLeaving(inc)
        local ourHalf = MM and MM.IsOurHalf(inc.x, inc.z)

        local have, count = 0, 0
        for uid, i2 in pairs(responding) do
            if i2 == inc then
                have, count = have + TM.Intrinsic(combatUnits[uid]), count + 1
            end
        end

        local cands = {}
        for uid, defID in pairs(combatUnits) do
            if spGetUnitDefID(uid) and not responding[uid] and CanAnswer(defID, channel) then
                local role = ARMY.RoleOf(uid)
                local ok = role == nil or role == "MUSTER" or role == "HOME_GUARD"
                if role == "LINE" then
                    local slot = ARMY.Slot(uid)
                    ok = ourHalf and not (slot and slot >= lineThrustLo and slot <= lineThrustHi)
                end
                local spd = UQ.max_speed(defID)
                -- Game doctrine 7.1: a faster raider that is already leaving cannot
                -- be caught, and chasing it just strips the base.
                if ok and not (leaving and fastest > spd * RESPOND_CHASE_RATIO) then
                    local ux, _, uz = spGetUnitPosition(uid)
                    if ux then
                        cands[#cands + 1] = {
                            uid = uid, v = TM.Intrinsic(defID),
                            eta = math.sqrt((ux - inc.x) ^ 2 + (uz - inc.z) ^ 2) / math.max(1, spd),
                        }
                    end
                end
            end
        end
        table.sort(cands, function(a, b) return a.eta < b.eta end)

        local added = 0
        for _, c in ipairs(cands) do
            if (have >= need and count >= RESPOND_MIN_UNITS) or capLeft <= 0 then break end
            responding[c.uid] = inc
            musterPool[c.uid] = nil
            have, count, capLeft = have + c.v, count + 1, capLeft - c.v
            added = added + 1
        end
        if added > 0 then
            local sec = math.floor(frame / 30)
            Spring.Echo(string.format(
                "[UC/respond] %d:%02d %s at %d,%d: +%d units (now %d, value %.0f / need %.0f)%s",
                math.floor(sec / 60), sec % 60, channel, inc.x, inc.z, added, count,
                have, need, leaving and " leaving" or ""))
        end
    end

    for uid, inc in pairs(responding) do
        ARMY.Claim(ARMY.PRIO.RESPOND, uid, {
            role = "RESPOND", cmd = CMD_FIGHT, x = inc.x, z = inc.z,
        }, frame)
    end
end

-- Ground guards hold posts on the enemy-facing side of the base; air guards orbit
-- the commander.  Directions come from the real home->foe axis, so the posts face
-- wherever the enemy actually spawned.
local function UpdateHomeGuard(frame)
    if not ARMY or not baseX then return end

    local ground, air = {}, {}
    for uid in pairs(homeGuards) do
        local defID = spGetUnitDefID(uid)
        if defID then
            if UQ.is_air(defID) then air[#air + 1] = uid else ground[#ground + 1] = uid end
        else
            homeGuards[uid] = nil
        end
    end

    local ax, az = 1, 0
    if MM and MM.Ready() then ax, az = MM.Axis() end
    local centre = math.atan2(az, ax)
    table.sort(ground)   -- stable post assignment
    local posts = math.max(1, math.min(3, #ground))
    for i, uid in ipairs(ground) do
        local k = (i - 1) % posts
        local t = (posts == 1) and 0 or (k / (posts - 1)) * 2 - 1
        local a = centre + t * HOME_GUARD_ARC
        local x, z = baseX + math.cos(a) * HOME_GUARD_RADIUS, baseZ + math.sin(a) * HOME_GUARD_RADIUS
        if MM then x, z = MM.Clamp(x, z, MAP_MARGIN) end
        ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, {
            role = "HOME_GUARD", cmd = CMD_FIGHT, x = x, z = z, minHold = LINE_MIN_HOLD,
        }, frame)
    end

    local cx, cz = baseX, baseZ
    if commanderID then
        local x, _, z = spGetUnitPosition(commanderID)
        if x then cx, cz = x, z end
    end
    for _, uid in ipairs(air) do
        ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, {
            role = "HOME_GUARD", cmd = CMD_FIGHT, x = cx, z = cz,
        }, frame)
    end
end

-- Pull badly damaged units home, and hand them back to the line once repaired.
-- Without the release a retreated unit would keep its priority-1 duty forever and
-- never rejoin, because nothing lower may claim it.
local function UpdateRetreats(frame)
    if not ARMY or not baseX then return end
    for unitID in pairs(combatUnits) do
        -- Raiders are committed and do not retreat (game_mechanics 7.2).
        if spGetUnitDefID(unitID) and not (RG and RG.IsRaider(unitID)) then
            local hp, maxHP = spGetUnitHealth(unitID)
            if hp and maxHP and maxHP > 0 then
                local frac = hp / maxHP
                if frac < RETREAT_HP then
                    -- Healing costs only time (1.4): go to the nearest rez bot or nano
                    -- turret rather than all the way to the base centre.
                    local rx, rz = baseX, baseZ
                    local ux, _, uz = spGetUnitPosition(unitID)
                    if RC and ux then
                        local hx, hz = RC.HealPoint(ux, uz)
                        if hx then rx, rz = hx, hz end
                    end
                    ARMY.Claim(ARMY.PRIO.RETREAT, unitID, {
                        role = "RETREAT", cmd = CMD_MOVE, x = rx, z = rz,
                    }, frame)
                elseif ARMY.RoleOf(unitID) == "RETREAT"
                       and frac >= RETREAT_HP + RETREAT_CLEAR then
                    ARMY.Release(unitID)
                end
            end
        end
    end
end

-- ── MECH_BOT planners ─────────────────────────────────────────────────────────

-- game_mechanics 2.3's one-number cost, the same scale enemy_intel values things on.
local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end

-- Where the army actually is: value-weighted centre of the units holding the line.
local function LineCentroid()
    if not ARMY then return nil end
    local sx, sz, v = 0, 0, 0
    for _, uid in ipairs(ARMY.Roster("LINE")) do
        local defID = combatUnits[uid]
        local x, _, z = spGetUnitPosition(uid)
        if defID and x then
            local c = Value(defID)
            sx, sz, v = sx + x * c, sz + z * c, v + c
        end
    end
    if v <= 0 then return nil end
    return sx / v, sz / v
end

-- The radar plane holds behind the army, spread across it, stepping back while its
-- spot is covered by remembered anti-air.
local function UpdateRadarPlanes(frame, fx, fz)
    if not (ARMY and MM and MM.Ready()) then return end
    local ids = {}
    for uid in pairs(radarPlanes) do
        if spGetUnitDefID(uid) then ids[#ids + 1] = uid else radarPlanes[uid] = nil end
    end
    if #ids == 0 then return end
    table.sort(ids)
    local ax, az = MM.Axis()
    local px, pz = MM.Perp()
    local hx, hz = MM.Home()
    local cx, cz = (fx or hx) - ax * MECH.RADAR_BACK, (fz or hz) - az * MECH.RADAR_BACK
    for i, uid in ipairs(ids) do
        local k = (i - 1) - (#ids - 1) / 2
        local x, z = cx + px * k * MECH.RADAR_SPREAD, cz + pz * k * MECH.RADAR_SPREAD
        for _ = 1, 6 do
            if not EI or EI.ThreatAt(frame, x, z, "air") <= 0 then break end
            x, z = x - ax * 400, z - az * 400
        end
        x, z = MM.Clamp(x, z, MAP_MARGIN)
        ARMY.Claim(ARMY.PRIO.SCOUT, uid, { role = "RADAR", cmd = CMD_MOVE, x = x, z = z }, frame)
    end
end

local function UpdateMechRoles(frame)
    local fx, fz = LineCentroid()
    if RG then
        local recruited = RG.Update(frame, combatUnits)
        for uid in pairs(recruited or {}) do musterPool[uid] = nil end
    end
    if RC then RC.Update(frame, fx, fz) end
    UpdateRadarPlanes(frame, fx, fz)
end

local function UpdateEndgame(frame)
    if not (EG and MM and MM.Ready()) then return end
    if frame % 150 == 0 then
        local armyValue = 0
        for uid, defID in pairs(combatUnits) do
            if spGetUnitDefID(uid) then armyValue = armyValue + Value(defID) end
        end
        local fx, fz = LineCentroid()
        local frontFrac = fx and (MM.Forward(fx, fz) / math.max(1, MM.Dist())) or 0
        local foeX, foeZ = MM.Foe()
        EG.Update(frame, armyValue, frontFrac,
                  RP and RP.LastSeenNear(foeX, foeZ, MECH.ENEMY_BASE_R))
    end
    local ids = {}
    for uid in pairs(bombers) do
        if spGetUnitDefID(uid) then ids[#ids + 1] = uid else bombers[uid] = nil end
    end
    table.sort(ids)
    if #ids > 0 then EG.Strike(frame, ids) end
end

-- Published for the other widgets.  Read-only for them; only this widget writes it.
-- The lab controller decides what to build from it, the macro whether to pull the
-- vehicle plant forward and where the commander is safe.
local function PublishState(frame)
    if not WG then return end
    local mb = WG.MetalBot or {}
    WG.MetalBot = mb
    local urgency, worst, ch = TM.ProductionUrgency()
    mb.urgency, mb.urgencyDeficit, mb.urgencyChannel = urgency, worst, ch
    mb.foeDist = MM and MM.Ready() and MM.Dist() or nil
    mb.frame = frame
    if MM and MM.Ready() then
        mb.homeX, mb.homeZ = MM.Home()
        mb.foeX, mb.foeZ = MM.Foe()
        mb.axisX, mb.axisZ = MM.Axis()
    end
    local threats = {}
    for _, inc in ipairs(TM.Incidents()) do
        local band = TM.IncidentBand(inc)
        if band == "respond" or band == "alarm" then
            threats[#threats + 1] = { x = inc.x, z = inc.z, channel = inc.channel }
        end
    end
    mb.threats = threats
    if EI then mb.intel = EI.Summary(frame) end
    mb.scoutWant = ScoutWant(frame)
    local n = 0
    for uid in pairs(combatUnits) do if spGetUnitDefID(uid) then n = n + 1 end end
    mb.armyCount = n
    mb.hunt = (EG and EG.Hunting()) or false
end

-- Once a minute: what we know and what the new roles are doing, for the logs.
local function EchoMech(frame)
    if not EI then return end
    local sm = EI.Summary(frame)
    local anti = 0
    for uid in pairs(antiRaid) do if spGetUnitDefID(uid) then anti = anti + 1 end end
    local radar = 0
    for uid in pairs(radarPlanes) do if spGetUnitDefID(uid) then radar = radar + 1 end end
    Spring.Echo(string.format(
        "[UC/intel] %d:%02d known=%d air=%.0f gnd=%.0f labs=%d(air %d, t2 %d) last_armed=%ds "
        .. "cmdr=%s | scouts want=%d raid=%s/%d anti_raid=%d rez=%d radar=%d hunt=%s",
        math.floor(frame / 1800), math.floor(frame / 30) % 60, sm.known, sm.airValue,
        sm.groundValue, sm.labs, sm.airLabs, sm.t2Labs,
        math.max(-1, math.floor((frame - sm.lastArmed) / 30)),
        sm.commanderFrame and string.format("%d,%d@%ds", sm.commanderX, sm.commanderZ,
            math.floor((frame - sm.commanderFrame) / 30)) or "-",
        ScoutWant(frame), RG and RG.Stage() or "-", RG and RG.Count() or 0, anti,
        RC and RC.Count() or 0, radar, tostring(EG and EG.Hunting() or false)))
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
    local okL, rL = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/threat_log.lua")
    if okL and rL then
        TL = rL
        TL.Init{ TM = TM, UQ = UQ, MM = MM, teamID = myTeamID, allyID = myAllyID }
    end

    -- MECH_BOT modules.  Each is optional: a load failure is loud but only switches off
    -- that behaviour, never the whole controller.
    local function Load(name)
        local ok, r = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/" .. name .. ".lua")
        if ok and r then return r end
        Spring.Echo("[UnitCtrl] ERROR loading " .. name .. ": " .. tostring(r))
        return nil
    end
    EI = Load("enemy_intel")
    if EI then EI.Init{ UQ = UQ, MM = MM, allyID = myAllyID } end
    RP = EI and Load("recon_plan")
    if RP then RP.Init{ MM = MM, EI = EI, UQ = UQ, allyID = myAllyID } end
    RG = EI and Load("raid_group")
    if RG then RG.Init{ MM = MM, EI = EI, UQ = UQ, ARMY = ARMY } end
    RC = Load("rez_crew")
    if RC then RC.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY,
                        teamID = myTeamID, allyID = myAllyID } end
    EG = EI and Load("endgame")
    if EG then EG.Init{ EI = EI, MM = MM, UQ = UQ, ARMY = ARMY, TM = TM, teamID = myTeamID } end
end

-- The commander is seen here rather than in UnitFinished: commanders are builders,
-- and UnitFinished returns early for builders before its commander branch.
function widget:UnitCreated(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    if IsCommander(unitDefID) then commanderID = unitID end
    if IsCommander(unitDefID) and not baseX then
        local x, _, z = spGetUnitPosition(unitID)
        if x then
            baseX, baseZ = x, z
            if MM then MM.SetHome(x, z) end
            InitContactLine()
        end
    end
end

-- Where a new armed unit goes: home cover or the line.  Ground units (the vehicle
-- plant's output) always guard.  Fighters split between home cover and the line, so
-- the main army has air cover too (7.3).  Of the fast raider-type units a few stay home
-- as the anti-raid reserve (7: "fast units held back to intercept raids").
local function StaysHome(unitDefID)
    if not UQ then return true end
    if not UQ.is_air(unitDefID) then return true end
    local function count(pred)
        local home, all = 0, 0
        for uid, defID in pairs(combatUnits) do
            if spGetUnitDefID(uid) and pred(defID) then
                all = all + 1
                if homeGuards[uid] then home = home + 1 end
            end
        end
        return home, all
    end
    if UQ.is_dedicated_aa(unitDefID) then
        local home, all = count(UQ.is_dedicated_aa)
        return home < math.max(MECH.HOME_FIGHTER_MIN, math.ceil(all * MECH.HOME_FIGHTER_SHARE))
    end
    if RG and RG.IsRaiderDef(unitDefID) then
        local home, all = count(RG.IsRaiderDef)
        local want = math.min(MECH.ANTI_RAID_MAX,
            math.max(MECH.ANTI_RAID_MIN, math.ceil(all * MECH.ANTI_RAID_SHARE)))
        return home < want, true
    end
    return false
end

function widget:UnitFinished(unitID, unitDefID, teamID)
    if teamID ~= myTeamID then return end
    local d = UnitDefs[unitDefID]
    if not d or d.isFactory then return end
    -- Rez bots are builders, so this has to come before the builder early-out.
    if d.isBuilder then
        if RC and RC.IsRezDef(unitDefID) then RC.Add(unitID) end
        return
    end
    if not d.speed or d.speed <= 0 then return end
    if RADAR_PLANE_NAMES[d.name] then radarPlanes[unitID] = true; return end
    if UQ and UQ.is_bomber(unitDefID) then bombers[unitID] = true; return end

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
        local home, isRaider = StaysHome(unitDefID)
        combatUnits[unitID] = unitDefID
        if home then
            homeGuards[unitID] = true
            if isRaider then antiRaid[unitID] = true end
        else
            musterPool[unitID] = Spring.GetGameFrame()
        end
    end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer,
                            weaponDefID, projectileID, attackerID, attackerDefID)
    if not TM or unitTeam ~= myTeamID then return end
    if TL then TL.OnDamaged(unitID, unitDefID, damage, weaponDefID, projectileID,
                            attackerID, attackerDefID, Spring.GetGameFrame()) end
    TM.OnDamaged(unitID, unitDefID, damage, weaponDefID, projectileID,
                 attackerID, attackerDefID, Spring.GetGameFrame())
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID)
    if TM then
        if TL then TL.OnUnitDestroyed(unitID, unitDefID, teamID == myTeamID,
                                      Spring.GetGameFrame(), attackerID) end
        TM.OnUnitDestroyed(unitID, unitDefID, teamID == myTeamID,
                           Spring.GetGameFrame(), attackerID)
    end
    combatUnits[unitID]   = nil
    scoutUnits[unitID]    = nil
    musterPool[unitID]    = nil
    responding[unitID]    = nil
    homeGuards[unitID]    = nil
    radarPlanes[unitID]   = nil
    bombers[unitID]       = nil
    antiRaid[unitID]      = nil
    if unitID == commanderID then commanderID = nil end
    if SP then SP.Forget(unitID) end
    if RP then RP.Forget(unitID) end
    if RG then RG.OnDestroyed(unitID) end
    if RC then RC.Remove(unitID) end
    if EI and teamID ~= myTeamID then EI.OnDestroyed(unitID) end
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
        if frame % 30 == 0 then
            TM.Update(frame)
            EchoThreat(frame)
            if TL then TL.Frame(frame) end
            PublishState(frame)
        end
    end
    if EI and frame % MECH.INTEL_PERIOD == 0 then EI.Scan(frame) end

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
        DispatchResponses(frame)
        UpdateHomeGuard(frame)
        UpdateMuster(frame)
    end

    -- Issue guidance and scout orders every ~2s.  The raid, rez and radar claims go
    -- after the line's, which they outrank anyway.
    if frame % 60 == 0 then
        AssignScouts(frame)
        IssueLineOrders(frame)
        UpdateMechRoles(frame)
    end
    if frame % 30 == 0 then UpdateEndgame(frame) end
    if frame % 1800 == 900 then EchoMech(frame) end

    if ARMY and frame % 1800 == 0 then
        local n, byRole = ARMY.Stats()
        local parts = {}
        for role, c in pairs(byRole) do parts[#parts + 1] = role .. "=" .. c end
        Spring.Echo(string.format("[UC/army] %d:%02d units=%d orders=%d %s",
            math.floor(frame / 1800), math.floor(frame / 30) % 60,
            n, ARMY.OrdersIssued(), table.concat(parts, " ")))
    end
end
