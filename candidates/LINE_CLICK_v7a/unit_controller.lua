-- LINE_CLICK: this is LINE_BOT's unit controller with the army replaced.  Scouting, intruder response,
-- home guard, retreat plumbing and the WG.MetalBot outputs are unchanged.  The contact line still exists
-- (scout pickets and the "past the line" intruder test use it) but no longer commands the army: the
-- ground blob, fighters and bombers are run by bar_framework/click_army.lua (stage -> dive on enemy
-- build power/eco -> fall back).  line_fight.lua (50-unit FIGHT push) and raid_group.lua are NOT loaded.
--
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
--   * Shurikens always stay home as defence (never raiders, never on the line) [7, 7.1]
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
local spIsPosInLos         = Spring.IsPosInLos

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
local ADVANCE_LOOKAHEAD = 150  -- the node must see this far past where it is about to stand
local NODE_ADVANCE_STEP = 120  -- world-units a clear node advances per tick (every 90 frames)
local NODE_MAX_BULGE    = 500  -- max world-units a node can lead its neighbours' average
local NODE_MAX_LAG      = 600  -- max world-units a non-engaged node can trail its neighbours
local THRUST_NODE_HALF  = 5    -- thrust window = thrustIdx ± this many nodes
local ARC_RADIUS        = 500  -- centre node forward distance at init (arc on top of map-entry advance)
local NODE_MIN_SPACING  = 100  -- lateral spacing between adjacent nodes (elmos)
local ROW_SPACING      = 70   -- units on one node stand in a row this far apart (elmos)
local ROW_SIZE         = 8    -- more than this on a node starts a second row behind
local PULL_RANGE       = 5    -- an engaged node pulls units from nodes this many away
local PULL_RATIO       = 1.5  -- ...until it holds this much value per unit of enemy value
local PULL_MAX         = 6    -- ...at most this many units per node per pass
local LINE_SCOUT_FRAME = 4 * 60 * 30   -- from here the line always has a scout on it
local LIVE_MIN_SPACING  = 250  -- a node closer than this to the previous live node is not used
-- The line used to be clipped to the map rectangle, which on this 12,288-elmo map
-- put its two ends on opposite map edges: halfWidth=7714, a 15,428-elmo front held
-- by ~20 units, one unit per ~375 elmos.  That is not a line, it is a cordon, and it
-- is why units appeared to be "sent nowhere".  A front is only as wide as the army
-- holding it can actually be.
local LINE_MAX_HALF_WIDTH = math.huge   -- edge to edge: the line is vision of every approach
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
local LF   = nil   -- bar_framework/line_fight.lua: NOT loaded in LINE_CLICK (every use is guarded)
local CA   = nil   -- bar_framework/click_army.lua (stage / dive / fall, hurt squads, bombers)
local SF   = nil   -- bar_framework/slow_front.lua (Lashers + Pounders + rez bots: fight over reclaim fields)

-- MECH_BOT tunables, one table so they cost one main-chunk local.
local MECH = {
    PICKET_SCOUTS      = 6,     -- scouts that stand on the contact line (picket ring)
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
    HOME_GROUND_SHARE  = 0.2,   -- share of ground units kept as the home garrison...
    HOME_GROUND_MIN    = 3,     -- ...at least this many...
    HOME_GROUND_MAX    = 8,     -- ...at most this many; the rest go to the line
    PUSH_RATIO         = 1.3,   -- an engaged node advances when we outvalue them by this
    PUSH_RADIUS        = 900,   -- ...counting units this close to the node
    RADAR_BACK         = 900,   -- radar plane holds this far behind the army
    RADAR_SPREAD       = 1500,
    INTEL_PERIOD       = 90,
    ENEMY_BASE_R       = 2500,
}
local RADAR_PLANE_NAMES = { corawac = true, armawac = true }
local CALL_RADAR_KEEP = 1      -- LINE_CLICK: this many Hawks stay on radar duty; the rest answer scout calls
local radarPlanes = {}   -- [unitID] = true
local bombers     = {}   -- [unitID] = true
local antiRaid    = {}   -- [unitID] = true: raider-type units kept home

-- Debug: draw the contact line on the map with map markers, redrawn every
-- DEBUG_DRAW_PERIOD frames.  Set DEBUG_DRAW_LINE = true to turn it on.  Markers are
-- visible to your own team only in a normal game; leave it off for headless tests.
local DEBUG_DRAW_LINE   = false
local DEBUG_DRAW_PERIOD = 450    -- 15 s of game time
local drawnMarks = {}            -- positions of markers to erase before the next draw

-- Frames a unit keeps its node before the line may move it to a different one.
local LINE_MIN_HOLD  = 300
-- Hysteresis so a repaired unit does not flicker between retreating and fighting.
local RETREAT_CLEAR  = 0.05
-- Reinforcements gather before joining the line: this many, or this long, whichever
-- comes first.
local MUSTER_SIZE        = 1   -- LINE_CLICK: click_army stages and masses the units itself
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

-- The slow group is Lashers + Pounders (+ rez bots).  slow_front.lua plays it (FIGHT orders, fields of wrecks,
-- rez crew).  Set HUMAN_SLOW = true to leave those units to a player instead: no Lua order reaches them, and
-- human_control_logger.lua records the player's orders ([HCL] cmd rows with comp=cormist/corlevlr/cornecro).
local HUMAN_SLOW = false
local SLOW_KIND  = { corlevlr = "front", cormist = "back" }     -- Pounder holds the front, Lasher shoots from behind

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
    -- The line stops at the enemy base: past it, nodes only run along the map edges.
    local maxAdv = diagDist
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
local function LocalValues(x, z)
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
    return ours, theirs
end

local function LocalBalance(x, z)
    local ours, theirs = LocalValues(x, z)
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
        -- The line is a perimeter we KNOW is safe, so it only moves into ground that we
        -- can see and that holds no enemy.  A node never pushes through a fight, and it
        -- never steps into the dark: a friendly unit has to give sight of the spot first.
        if canAdvance and not node.engaged then
            local ax = wx + advDir.x * (NODE_ADVANCE_STEP + ADVANCE_LOOKAHEAD)
            local az = wz + advDir.z * (NODE_ADVANCE_STEP + ADVANCE_LOOKAHEAD)
            local seen = true
            if spIsPosInLos then
                seen = spIsPosInLos(ax, spGetGroundHeight(ax, az) or 0, az, myAllyID) and true or false
            end
            if seen and spGetUnitsInCylinder
               and HasEnemy(spGetUnitsInCylinder(ax, az, NODE_ENEMY_RADIUS)) then
                seen = false
            end
            node.blocked = not seen
            if seen then node.adv = node.adv + NODE_ADVANCE_STEP end
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

-- Ring scouts that stand on the line instead of the scout_plan pickets.
local lineScouts = {}   -- [unitID] = true
-- Units on each node from the last assignment pass (for the debug drawing).
local lineLoad = {}
-- Units pulled onto an engaged node from nearby ones: [unitID] = node index.
local linePulled = {}

-- Returns {[unitID] = nodeIdx}.  The whole line is occupied, edge to edge: k units
-- take k evenly spaced nodes, so the army gives vision of every route to the base
-- instead of piling onto one spot.  Scouts are placed first so they hold the spread
-- even when the army is small.
local function AssignUnitPositions()
    if not nodes then return {} end

    local scouts, units = {}, {}
    for unitID in pairs(lineScouts) do
        if spGetUnitDefID(unitID) then scouts[#scouts + 1] = unitID else lineScouts[unitID] = nil end
    end
    for unitID in pairs(combatUnits) do
        local role = ARMY and ARMY.RoleOf(unitID)
        if spGetUnitDefID(unitID) and not musterPool[unitID] and not homeGuards[unitID]
           and not lineScouts[unitID] and (role == nil or role == "LINE") then
            units[#units + 1] = unitID
        end
    end
    local k = #scouts + #units
    if k == 0 then lineLoad = {}; return {} end
    table.sort(scouts); table.sort(units)

    -- Live nodes: walking along the line, a node closer than LIVE_MIN_SPACING to the
    -- last live one is redundant (nodes pinned at a map edge or corner stack on top of
    -- each other near the enemy base and would only hold units where nothing happens).
    local live, lx, lz = {}, nil, nil
    for pass = 1, 2 do
        for i = 1, NODE_COUNT do
            -- Pass 1 skips nodes pinned against the map edge: they cannot advance, and
            -- only collect units along the border.  Pass 2 (nothing else left) takes all.
            if pass == 2 or not nodes[i].atEdge then
                local x, z = NodeWorldPos(nodes[i])
                if not lx or (x - lx) ^ 2 + (z - lz) ^ 2 >= LIVE_MIN_SPACING ^ 2 then
                    live[#live + 1] = i
                    lx, lz = x, z
                end
            end
        end
        if #live > 0 then break end
    end

    -- k evenly spaced live nodes (centred in k equal bands of the line).
    local slots = math.min(k, #live)
    local spread, seen = {}, {}
    for j = 1, slots do
        local n = live[math.max(1, math.min(#live, math.floor((j - 0.5) / slots * #live + 0.5)))]
        if not seen[n] then seen[n] = true; spread[#spread + 1] = n end
    end

    -- Response may borrow from the wings but never the contested window.
    lineThrustLo = math.max(1, thrustNodeIdx - THRUST_NODE_HALF)
    lineThrustHi = math.min(NODE_COUNT, thrustNodeIdx + THRUST_NODE_HALF)

    local positions, load = {}, {}
    local valid = {}
    for _, n in ipairs(spread) do valid[n] = true end

    -- Keep a unit on the node it already holds while that node is still in the
    -- spread; otherwise the emptiest node.  Re-dealing from scratch shifted the whole
    -- army sideways whenever one unit was built or lost.
    local function Place(list)
        local unplaced = {}
        for _, uid in ipairs(list) do
            local cur = ARMY and ARMY.Slot(uid)
            if cur and valid[cur] and (load[cur] or 0) == 0 then
                positions[uid] = cur
                load[cur] = 1
            else
                unplaced[#unplaced + 1] = uid
            end
        end
        for _, uid in ipairs(unplaced) do
            local best, bestLoad = spread[1], math.huge
            for _, n in ipairs(spread) do
                local l = load[n] or 0
                if l < bestLoad then best, bestLoad = n, l end
            end
            positions[uid] = best
            load[best] = (load[best] or 0) + 1
        end
    end

    Place(scouts)
    Place(units)

    -- An engaged node pulls units from nearby nodes (up to PULL_RANGE away) until it holds
    -- PULL_RATIO x the enemy value near it: the fighting is where the units should be, the
    -- rest of the line is vision.  A pull lasts while its node stays engaged.
    for uid, n in pairs(linePulled) do
        if not (nodes[n] and nodes[n].engaged) or not positions[uid] or lineScouts[uid] then
            linePulled[uid] = nil
        else
            positions[uid] = n
        end
    end
    local unitsAt, scoutAt = {}, {}
    for uid, n in pairs(positions) do
        if lineScouts[uid] then scoutAt[n] = true
        elseif not linePulled[uid] then
            local t = unitsAt[n]
            if not t then t = {}; unitsAt[n] = t end
            t[#t + 1] = uid
        end
    end
    for e = 1, NODE_COUNT do
        if nodes[e].engaged then
            local wx, wz = NodeWorldPos(nodes[e])
            local ours, theirs = LocalValues(wx, wz)
            local pulls = 0
            for dist = 1, PULL_RANGE do
                for side = -1, 1, 2 do
                    local d = e + side * dist
                    local list = unitsAt[d]
                    if list and not nodes[d].engaged then
                        table.sort(list)
                        local give = #list - (scoutAt[d] and 0 or 1)   -- keep eyes on the donor
                        while give > 0 and pulls < PULL_MAX and ours < theirs * PULL_RATIO do
                            local uid = table.remove(list)
                            positions[uid], linePulled[uid] = e, e
                            ours = ours + ((UnitDefs[combatUnits[uid]] or {}).metalCost or 0)
                            pulls, give = pulls + 1, give - 1
                        end
                    end
                end
            end
        end
    end

    load = {}
    for _, n in pairs(positions) do load[n] = (load[n] or 0) + 1 end
    lineLoad = load
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

    -- Once the spawn is known the ring scouts stand on the contact line (IssueLineOrders)
    -- rather than on scout_plan's pickets; before that scout_plan is still finding it.
    for uid in pairs(lineScouts) do lineScouts[uid] = nil end
    if SP.Mode() == "picket" then
        for _, uid in ipairs(ringIDs) do lineScouts[uid] = true end
    else
        local _, _, _, income = Spring.GetTeamResources(myTeamID, "metal")
        for unitID, spec in pairs(SP.Plan(frame, ringIDs, income or 0)) do
            ARMY.Claim(ARMY.PRIO.SCOUT, unitID, spec, frame)
        end
    end
    if RP and #reconIDs > 0 then
        for unitID, spec in pairs(RP.Plan(frame, reconIDs, hunting)) do
            ARMY.Claim(ARMY.PRIO.SCOUT, unitID, spec, frame)
        end
    end

    -- From LINE_SCOUT_FRAME the line always has something watching it: if no scout is
    -- alive to stand on it, the cheapest armed line unit takes the job until one is built.
    if frame >= LINE_SCOUT_FRAME and next(lineScouts) == nil and #reconIDs == 0 then
        local best, bestCost
        for uid, defID in pairs(combatUnits) do
            local role = ARMY.RoleOf(uid)
            if spGetUnitDefID(uid) and not musterPool[uid] and not homeGuards[uid]
               and (role == nil or role == "LINE" or role == "SCOUT") then
                local c = (UnitDefs[defID] and UnitDefs[defID].metalCost) or math.huge
                if not best or c < bestCost then best, bestCost = uid, c end
            end
        end
        if best then lineScouts[best] = true end
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

    -- Units sharing a node stand in a row across the front (perpendicular to the advance,
    -- facing the enemy), a second row behind when it is crowded.  Close enough that many
    -- can hit one target and nobody is flanked alone, but each has its own spot.
    local byNode = {}
    for unitID, nodeIdx in pairs(positions) do
        if not lineScouts[unitID] then
            local t = byNode[nodeIdx]
            if not t then t = {}; byNode[nodeIdx] = t end
            t[#t + 1] = unitID
        end
    end
    local offset = {}   -- [unitID] = {lateral, back}
    for _, t in pairs(byNode) do
        table.sort(t)
        for i, uid in ipairs(t) do
            local row = math.floor((i - 1) / ROW_SIZE)
            local inRow = math.min(ROW_SIZE, #t - row * ROW_SIZE)
            local col = (i - 1) % ROW_SIZE
            offset[uid] = { (col - (inRow - 1) / 2) * ROW_SPACING, row * ROW_SPACING }
        end
    end

    for unitID, nodeIdx in pairs(positions) do
        local node = nodes[nodeIdx]
        if node then
            local wx, wz = NodeWorldPos(node)
            if lineScouts[unitID] then
                ARMY.Claim(ARMY.PRIO.SCOUT, unitID, {
                    role = "SCOUT", cmd = CMD_MOVE, x = wx, z = wz,
                    slot = nodeIdx, minHold = LINE_MIN_HOLD,
                }, frame)
            end
            -- LINE_CLICK: combat units on the line are click_army's, not the line's.
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

local function CanAnswer(defID, channel)
    if channel == "air" then return UQ.can_hit_air(defID) end
    return UQ.can_hit_ground(defID)
end

-- ── Response to enemies behind the line ───────────────────────────────────────
-- Driven by what we SEE, not by damage: damage means we were already too late.  Any
-- remembered enemy mobile unit that is on our side of the line is an intruder.  Nearby
-- intruders form a group, and the nearest able units are sent at it until they are
-- worth up to RESPOND_NEED_MULT x what we saw there.  No bands, no thresholds.

local INTRUDER_TTL    = 900   -- frames a sighting is acted on once out of sight
local PAST_MARGIN     = 200   -- elmos behind the line before an enemy counts as past it
local CLUSTER_RADIUS  = 700   -- intruders this close are one group
local RESPOND_KEEP    = 1500  -- a responder stays with the group that is this close to its last

local respondClusters = {}    -- last pass's intruder groups (published to the labs)

-- Advance of the line itself at a given lateral offset (interpolated between nodes).
local function LineAdvAt(lat)
    local first, last = nodes[1], nodes[NODE_COUNT]
    if lat <= first.lateral then return first.adv end
    if lat >= last.lateral then return last.adv end
    for i = 1, NODE_COUNT - 1 do
        local a, b = nodes[i], nodes[i + 1]
        if lat <= b.lateral then
            local span = b.lateral - a.lateral
            local f = span > 0 and (lat - a.lateral) / span or 0
            return a.adv + (b.adv - a.adv) * f
        end
    end
    return last.adv
end

local function IntruderGroups(frame)
    local groups = {}
    if not (nodes and baseX and TM and UQ) then return groups end
    for _, c in pairs(TM.Contacts()) do
        local age = frame - c.frame
        if age <= INTRUDER_TTL and c.defID and UQ.is_mobile(c.defID) then
            -- We can see the spot but nothing has been seen there since: it moved on.
            local gone = age > TM.SCAN_PERIOD * 1.5 and spIsPosInLos
                and spIsPosInLos(c.x, spGetGroundHeight(c.x, c.z) or 0, c.z, myAllyID)
            if not gone then
                local dx, dz = c.x - baseX, c.z - baseZ
                local adv = dx * advDir.x + dz * advDir.z
                local lat = dx * perpDir.x + dz * perpDir.z
                if adv < LineAdvAt(lat) - PAST_MARGIN then
                    local cost = UQ.metal_cost(c.defID) or c.v or 0
                    local g
                    for _, o in ipairs(groups) do
                        if (o.x - c.x) ^ 2 + (o.z - c.z) ^ 2 <= CLUSTER_RADIUS ^ 2 then g = o; break end
                    end
                    if not g then
                        g = { x = c.x, z = c.z, n = 0, cost = 0, air = 0, gnd = 0 }
                        groups[#groups + 1] = g
                    end
                    local n = g.n + 1
                    g.x, g.z = (g.x * g.n + c.x) / n, (g.z * g.n + c.z) / n
                    g.n, g.cost = n, g.cost + cost
                    if c.air then g.air = g.air + cost else g.gnd = g.gnd + cost end
                end
            end
        end
    end
    for _, g in ipairs(groups) do g.channel = (g.air > g.gnd) and "air" or "ground" end
    table.sort(groups, function(a, b) return a.cost > b.cost end)
    return groups
end

local function DispatchResponses(frame)
    if not ARMY or not UQ then return end

    local groups = IntruderGroups(frame)
    respondClusters = groups

    -- Each responder stays with the group nearest its last one; no group near, stand down.
    local have = {}   -- [group] = value committed
    for uid, last in pairs(responding) do
        local role = ARMY.RoleOf(uid)
        local best, bestD = nil, RESPOND_KEEP ^ 2
        for _, g in ipairs(groups) do
            local d = (g.x - last.x) ^ 2 + (g.z - last.z) ^ 2
            if d < bestD then best, bestD = g, d end
        end
        if not best or not spGetUnitDefID(uid) or role == "RETREAT" then
            if role == "RESPOND" then ARMY.Release(uid) end
            responding[uid] = nil
        else
            responding[uid] = best
            have[best] = (have[best] or 0) + (UQ.metal_cost(combatUnits[uid]) or 0)
        end
    end

    for _, g in ipairs(groups) do
        local need = g.cost * RESPOND_NEED_MULT
        local got  = have[g] or 0
        if got < need then
            local cands = {}
            for uid, defID in pairs(combatUnits) do
                if spGetUnitDefID(uid) and not responding[uid] and not musterPool[uid]
                   and CanAnswer(defID, g.channel) then
                    local role = ARMY.RoleOf(uid)
                    local ok = role == nil or role == "HOME_GUARD"
                    -- LINE_CLICK: only reinforcements (new units and the ones waiting at the stage), home
                    -- guards and air defend the base.  A unit in an attack group never does -- the groups
                    -- stay on the other side of the map.
                    if role == "BLOB" and CA and not CA.InGroup(uid) then ok = true end
                    if role == "LINE" then
                        -- A unit holding a node that is fighting stays and fights.
                        local node = nodes and nodes[ARMY.Slot(uid) or 0]
                        ok = not (node and node.engaged)
                    end
                    if ok then
                        local ux, _, uz = spGetUnitPosition(uid)
                        if ux then
                            cands[#cands + 1] = {
                                uid = uid, cost = UQ.metal_cost(defID) or 0,
                                eta = math.sqrt((ux - g.x) ^ 2 + (uz - g.z) ^ 2)
                                      / math.max(1, UQ.max_speed(defID)),
                            }
                        end
                    end
                end
            end
            table.sort(cands, function(a, b) return a.eta < b.eta end)

            local added = 0
            for _, c in ipairs(cands) do
                -- Up to 2x what was seen, but never zero units for a real intruder.
                if got >= need or (added > 0 and got + c.cost > need) then break end
                responding[c.uid] = g
                got, added = got + c.cost, added + 1
            end
            have[g] = got
            if added > 0 then
                local sec = math.floor(frame / 30)
                Spring.Echo(string.format(
                    "[UC/respond] %d:%02d %s intruders at %d,%d: seen %d units cost %.0f, +%d units (committed %.0f / %.0f)",
                    math.floor(sec / 60), sec % 60, g.channel, g.x, g.z, g.n, g.cost,
                    added, got, need))
            end
        end
    end

    for uid, g in pairs(responding) do
        ARMY.Claim(ARMY.PRIO.RESPOND, uid, {
            role = "RESPOND", cmd = CMD_FIGHT, x = g.x, z = g.z,
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
        if spGetUnitDefID(unitID) and not (RG and RG.IsRaider(unitID))
           and not (LF and LF.IsRaider(unitID))
           and not (CA and (CA.IsRaiding(unitID) or CA.IsSquadRetreating(unitID))) then
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
    if CA then
        local cx, cz = CA.Centroid()
        if cx then return cx, cz end
        local sx, sz = CA.StagePoint()
        if sx then return sx, sz end
    end
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

    -- LINE_CLICK scout calls: every Hawk beyond the first RADAR_KEEP flies to a point an attacking
    -- group asked about (ahead of where it wants to go), the nearest Hawk to each point.  They are
    -- allowed to die; the sight and radar they give the group is the point.  Hawks with no call
    -- left stay on radar duty behind the army.
    local calls = CA and CA.ScoutRequests() or {}
    if #calls > 0 and #ids > CALL_RADAR_KEEP then
        local pool = {}
        for i = CALL_RADAR_KEEP + 1, #ids do pool[#pool + 1] = ids[i] end
        local keep = {}
        for i = 1, CALL_RADAR_KEEP do keep[i] = ids[i] end
        local used = {}
        for _, req in ipairs(calls) do
            local best, bestD
            for _, uid in ipairs(pool) do
                if not used[uid] then
                    local ux, _, uz = spGetUnitPosition(uid)
                    if ux then
                        local d = (ux - req[1]) ^ 2 + (uz - req[2]) ^ 2
                        if not bestD or d < bestD then best, bestD = uid, d end
                    end
                end
            end
            if best then
                used[best] = true
                local x, z = req[1], req[2]
                -- do not fly straight into remembered anti-air: step back a little, not all the way
                for _ = 1, 3 do
                    if not EI or EI.ThreatAt(frame, x, z, "air") <= 0 then break end
                    x, z = x - ax * 300, z - az * 300
                end
                x, z = MM.Clamp(x, z, MAP_MARGIN)
                ARMY.Claim(ARMY.PRIO.SCOUT, best, { role = "SCOUT_CALL", cmd = CMD_MOVE, x = x, z = z }, frame)
            end
        end
        ids = keep
        for _, uid in ipairs(pool) do if not used[uid] then ids[#ids + 1] = uid end end
        if #ids == 0 then return end
    end
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

-- Redraw the line: a polyline over the nodes the army occupies, a point per engaged
-- node, and a label at the thrust node.  Everything drawn last time is erased first.
local function DrawLine()
    if not (Spring.MarkerAddLine and Spring.MarkerAddPoint and Spring.MarkerErasePosition) then return end
    for _, m in ipairs(drawnMarks) do Spring.MarkerErasePosition(m[1], m[2], m[3]) end
    drawnMarks = {}
    if not (lineInited and nodes and baseX) then return end

    local function Pos(node)
        local x, z = NodeWorldPos(node)
        return x, (spGetGroundHeight(x, z) or 0) + 10, z
    end
    local px, py, pz
    for i = 1, NODE_COUNT do
        local x, y, z = Pos(nodes[i])
        if px then Spring.MarkerAddLine(px, py, pz, x, y, z) end
        drawnMarks[#drawnMarks + 1] = { x, y, z }
        px, py, pz = x, y, z
        local n = lineLoad[i] or 0
        if n > 0 or nodes[i].engaged then
            Spring.MarkerAddPoint(x, y, z, string.format("%d:%d%s", i, n,
                nodes[i].engaged and " ENGAGED" or (nodes[i].blocked and " HOLD" or "")))
        end
    end
    local tx, ty, tz = Pos(nodes[math.min(NODE_COUNT, math.max(1, thrustNodeIdx))])
    Spring.MarkerAddPoint(tx, ty, tz, "THRUST node " .. thrustNodeIdx)
    drawnMarks[#drawnMarks + 1] = { tx, ty, tz }
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
    for _, g in ipairs(respondClusters) do
        threats[#threats + 1] = { x = g.x, z = g.z, channel = g.channel }
    end
    mb.threats = threats
    if EI then mb.intel = EI.Summary(frame) end
    mb.scoutWant = ScoutWant(frame)
    mb.callScouts = CA and CA.ScoutDemand() or 0    -- LINE_CLICK: Hawks the labs should keep for the groups
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
    -- LINE_CLICK: scout_lanes.lua is scout_plan.lua with a lane sweep of the enemy half in FIND mode
    local okS, rS = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/scout_lanes.lua")
    if not okS then Spring.Echo("[UnitCtrl] ERROR loading scout_lanes: " .. tostring(rS)); return end
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
    -- LINE_CLICK: raid_group's capped raiders are replaced by click_army's dives (same job, one owner).
    RG = nil
    RC = Load("rez_crew")
    if RC then RC.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY,
                        teamID = myTeamID, allyID = myAllyID } end
    EG = EI and Load("endgame")
    if EG then EG.Init{ EI = EI, MM = MM, UQ = UQ, ARMY = ARMY, TM = TM, teamID = myTeamID } end
    LF = nil
    CA = EI and Load("click_army")
    if CA then
        CA.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, combat = combatUnits, guards = homeGuards,
                 muster = musterPool, scouts = lineScouts, responding = responding, bombers = bombers,
                 isHunting = function() return EG and EG.Hunting() or false end,
                 cfg = { SLOW_SPEED = 0,       -- click_army has no slow group: slow_front.lua runs Lashers/Pounders
                         -- LINE_CLICK_v2 (2026-10-08): the core is the forward cluster, the commander chase sticks
                         FORWARD_CORE = true, CMDR_KEEP_FRAC = 0.8, CORE_WAIT_FRAC = 0.35 } }
    end
    SF = EI and Load("slow_front")
    if SF then SF.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY } end
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

local function CountHome(pred)
    local home, all = 0, 0
    for uid, defID in pairs(combatUnits) do
        if spGetUnitDefID(uid) and pred(defID) then
            all = all + 1
            if homeGuards[uid] then home = home + 1 end
        end
    end
    return home, all
end

local function IsGroundDef(defID) return not UQ.is_air(defID) end

-- Size of the ground garrison for a given number of ground units.
local function GroundGarrison(all)
    return math.min(MECH.HOME_GROUND_MAX,
        math.max(MECH.HOME_GROUND_MIN, math.ceil(all * MECH.HOME_GROUND_SHARE)))
end

-- Free ground guards beyond the garrison so they muster and join the line.  Covers
-- units that were guards before the garrison grew a cap, and a garrison the army
-- has outgrown.
local function ReleaseSurplusGuards(frame)
    if not (UQ and ARMY) then return end
    local home, all = CountHome(IsGroundDef)
    local surplus = home - GroundGarrison(all)
    if surplus <= 0 then return end
    local ids = {}
    for uid, defID in pairs(combatUnits) do
        if homeGuards[uid] and spGetUnitDefID(uid) and IsGroundDef(defID) then
            ids[#ids + 1] = uid
        end
    end
    table.sort(ids, function(a, b) return a > b end)   -- newest first; keep the old guards
    for i = 1, math.min(surplus, #ids) do
        local uid = ids[i]
        homeGuards[uid] = nil
        if ARMY.RoleOf(uid) == "HOME_GUARD" then ARMY.Release(uid) end
        musterPool[uid] = frame
    end
end

-- Where a new armed unit goes: home cover or the line.  Ground units fill a bounded
-- garrison and the rest go to the line; before, every ground unit stayed home forever
-- and nothing ever reached the line.  Fighters split between home cover and the line,
-- so the main army has air cover too (7.3).  Of the fast raider-type units a few stay
-- home as the anti-raid reserve (7: "fast units held back to intercept raids").
local function StaysHome(unitDefID)
    if not UQ then return true end
    if IsGroundDef(unitDefID) then
        -- The new unit is not in combatUnits yet, hence the +1.
        local home, all = CountHome(IsGroundDef)
        return home < GroundGarrison(all + 1)
    end
    local count = CountHome
    if UQ.is_dedicated_aa(unitDefID) then
        local home, all = count(UQ.is_dedicated_aa)
        return home < math.max(MECH.HOME_FIGHTER_MIN, math.ceil(all * MECH.HOME_FIGHTER_SHARE))
    end
    -- Shurikens are home defence: never raiders, never sent to the line.
    local ud = UnitDefs[unitDefID]
    if RG and ud and RG.NEVER_RAID[ud.name] then return true, true end
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
        -- Rez bots belong to the slow group (slow_front.lua), not to rez_crew; with HUMAN_SLOW nothing orders them.
        if RC and RC.IsRezDef(unitDefID) then
            if SF and not HUMAN_SLOW then SF.Add(unitID, "rez") end
            return
        end
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

    -- Lashers and Pounders are never registered with the army/guard/retreat/respond/muster controllers:
    -- they are the slow group, played by slow_front.lua (or by a player when HUMAN_SLOW).
    if SLOW_KIND[d.name] then
        if SF and not HUMAN_SLOW then SF.Add(unitID, SLOW_KIND[d.name]) end
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
    if LF and unitTeam ~= myTeamID then LF.OnEnemyDamaged(attackerID, unitDefID) end
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
    if SF then SF.Remove(unitID) end
    if LF then LF.OnDestroyed(unitID) end
    linePulled[unitID] = nil
    lineScouts[unitID] = nil
    if CA then
        local ux, _, uz = spGetUnitPosition(unitID)
        CA.OnDestroyed(unitID, unitDefID, teamID == myTeamID, Spring.GetGameFrame(), ux, uz)
    end
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
        ReleaseSurplusGuards(frame)
        DispatchResponses(frame)
        UpdateHomeGuard(frame)
        UpdateMuster(frame)
        if CA then CA.Update(frame) end
        if SF and not HUMAN_SLOW then SF.Update(frame) end
    end

    -- Issue guidance and scout orders every ~2s.  The raid, rez and radar claims go
    -- after the line's, which they outrank anyway.
    if frame % 60 == 0 then
        AssignScouts(frame)
        IssueLineOrders(frame)
        UpdateMechRoles(frame)
        if LF then LF.Update(frame) end
    end
    if LF and frame % 30 == 15 and nodes then
        local hot = {}
        for i = 1, NODE_COUNT do
            if nodes[i].engaged then
                local x, z = NodeWorldPos(nodes[i])
                hot[#hot + 1] = { x = x, z = z }
            end
        end
        LF.UpdateFocus(frame, hot)
    end
    if DEBUG_DRAW_LINE and frame % DEBUG_DRAW_PERIOD == 0 then DrawLine() end
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
