-- bar_framework/click_army.lua
-- LINE_CLICK's army: a human-style "BP hunter".  The goal of these units is to kill the enemy's
-- build power (nanos, constructors, labs) and eco, while the home guard keeps the same from
-- happening to us.  An attack is judged on what it destroyed, NOT on the trade ratio: a 600-800 m
-- group that kills a 220 m nano still pays, because the enemy loses the rebuild cost plus
-- everything the nano would have built until it is back.
--
-- Derived from two human games on Full Metal Plate (human_control_logger.lua / human_control_report.py)
-- and the user's notes: several attacks AT ONCE on different parts of the enemy base, so that an
-- enemy who answers one has to pull units away from defending another.
--
-- GROUPS  up to MAX_GROUPS attack groups run at the same time.  Each has its own target.
--   stage      ground units that belong to no group gather on a tight ring at STAGE (MOVE).
--   launch     a new group leaves when the army value at the stage (stage av) is at least
--              LAUNCH_MIN_AV AND at least LAUNCH_RATIO x the value still walking to the stage
--              (reinforce av): with a lot on its way, wait and send one bigger group; with 2.5x
--              as much standing there as arriving, go.  (LAUNCH_FORCE_AV launches regardless, so a
--              steady trickle of reinforcements cannot hold the army back for ever.)
--   attack     the group goes for TARGETS, best damage value first (build power and constructors,
--              then eco; labs far down, they are tough and not what starves the enemy).  The enemy
--              COMMANDER outranks all of them when it is out in the open (few guards around it): every
--              group goes for it, since killing it wins.  A target close to another group's target is heavily
--              discounted, so the groups hit different points of the base.  Short MOVE legs steer
--              round enemy armed value; within ATTACK_SWITCH the order becomes ATTACK on the
--              building.  Not recalled for a bad value ratio -- only when the group is spent
--              (FALL_FRAC of its peak) or nothing is left in reach.
--   reinforce  once all MAX_GROUPS exist, a new unit goes straight to the weakest attacking group.
--   fall       survivors of a spent group MOVE back to the stage and become stage units again.
-- Hurt squads (<= SQUAD_MAX units, in no group, enemies near and outvaluing them) retreat.
-- Fighters escort the biggest group; bombers (>= BOMBER_MIN) strike the best target together.
--
-- The caller owns the unit tables; this module only reads them and claims units through
-- army_broker with role "BLOB" at the lowest priority, so retreat/respond/home guard still win.
--
-- Log rows, all "[CK]": launches, target picks, KILLs of build power / eco, group ends, the
-- stage/reinforce values while waiting, bomber runs, and a once-a-minute total.

local M = {}

local CFG = {
    STAGE_FRAC      = 0.45,   -- stage this far along home->foe (human: ~(6000-6400, 2400-3100) of ~8000)
    STAGE_SPACING   = 55,     -- elmos between units on the staging ring (tight blob)
    STAGE_JOIN_R    = 1200,   -- a unit is "at the stage" this close to it; farther = still reinforcing
    BLIND_DIVE_FRAME = 12 * 60 * 30,  -- attack on the mirror guess only after this long without a sighting
    MAX_GROUPS      = 3,      -- user: "you want 3 different attacks in general"
    LAUNCH_MIN_AV   = 1800,   -- smallest group worth sending (~15 gators; human's first push had 25)
    LAUNCH_RATIO    = 2.5,    -- stage av must be this x the av still walking to the stage (user: 2.5)
    LAUNCH_FORCE_AV = 5400,   -- ...or this much, whatever is walking in
    FALL_FRAC       = 0.30,   -- a group is spent when this share of its peak size is left
    FALL_MAX_FRAMES = 1200,   -- ...and survivors give up waiting for the return after this long
    FALL_ARRIVE     = 700,    -- back at stage when the centroid is this close
    LEG             = 1000,   -- steering leg length (human legs: median 900-1900)
    ATTACK_SWITCH   = 800,    -- closer than this to the target: ATTACK it
    NO_TARGET_R     = 1500,   -- at the enemy start with nothing to hit this close: give up
    LOOK_FRAMES     = 180,    -- ...after looking this long (intel scans every 90 frames)
    TARGET_REPICK   = 450,    -- frames before a target is re-evaluated even if alive
    MOBILE_FACTOR   = 0.5,    -- a mobile target (a con) is worth half: its remembered spot goes stale
    KILL_R          = 1800,   -- an enemy death counts toward an attack only this close to a group
    BP_WEIGHT       = 4,      -- damage value of 1 build power (a 200 BP nano -> +800)
    ECO_BONUS       = 150,    -- damage value of an income building
    LAB_FACTOR      = 0.15,   -- a factory is worth this share of cost + build power: tough, and not what
                              -- starves the enemy (nanos, cons and eco are).  A T2 vehicle plant at
                              -- ~5,200 dropped to ~780, under one nano (~1,075), so labs go last.
    -- The enemy commander: killing it wins, so when it is out in the open every group goes for it.
    CMDR_OPEN_FRAC  = 0.3,    -- "open" = armed enemy value around it (not counting itself) <= this x the group
    CMDR_MIN_AV     = 1200,   -- ...and the group is at least this big (~10 gators), no suicide runs
    CMDR_FRESH      = 900,    -- ...and it was seen this recently (it walks)
    DIST_SCALE      = 4000,   -- a target this far away is worth half
    DIFF_R          = 1200,   -- targets this close to another group's target are "the same point"...
    DIFF_PENALTY    = 0.2,    -- ...and score this share (groups hit different points of the base)
    LANE_SPACING    = 900,    -- with no target known, groups approach the enemy start this far apart
    TARGET_DEF_MAX  = 1.5,    -- armed value at a target above this x the group: deprioritised
    DEF_PENALTY     = 0.25,   -- ...to this share of its score
    FLANK_PENALTY   = 0.15,   -- cost of a turned leg, in shares of the group's value
    STRAGGLER_R     = 2500,   -- a unit this far from its group's core walks to the core instead
    SQUAD_MAX       = 6,      -- human pulled back squads of 3-5 at 40-60% hp
    SQUAD_HP        = 0.60,
    SQUAD_RELEASE   = 0.85,
    SQUAD_R         = 600,    -- units this close are one squad
    ENEMY_NEAR_R    = 900,
    BOMBER_MIN      = 8,
    BOMB_COOLDOWN   = 2700,   -- frames between bomber runs
    BOMB_AIR_MAX    = 0.5,    -- skip targets with more than this x the group's value in AA
    WAIT_LOG_EVERY  = 450,
    MARGIN          = 200,
    -- The slow group: Mammoths (speed 23) next to gators (85) made every group crawl, so the slow
    -- units get a group of their own and the fast groups keep probing.  Tigers (69) stay fast.
    SLOW_SPEED      = 55,     -- a unit slower than this belongs to the slow group (Init{cfg={SLOW_SPEED=0}} turns it off)
    SLOW_MIN_AV     = 2000,   -- the slow group leaves once this much slow value is at the stage
    SLOW_ESCORT_SHARE = 0.35, -- fast units in the slow group: this share of the slow value, no more
    SLOW_ESCORT_WAIT  = 0.5,  -- launch once this share of the wanted escorts is there...
    SLOW_FORCE_MULT   = 2.0,  -- ...or the slow value is this x SLOW_MIN_AV
    SLOW_DIST_SCALE   = 2500, -- the slow group prefers nearer targets (it cannot cross the map twice)
    SLOW_DEF_MAX      = 3.0,  -- ...and takes on defended targets (TARGET_DEF_MAX x this)
    -- The slow group TRADES: it fights the enemy army cost-effectively instead of hunting build power.
    --   T1: Lashers (cormist, long-range support) behind Pounders (corlevlr, the screen);
    --   T2: Sheldons (cormort, long-range support) behind Mammoths (corsumo, the screen).
    -- Fast units that escort it count as screen (mass).  Everything is a plain FIGHT order; the
    -- support kites by staying behind the screen and letting its range do the work.
    SLOW_SUPPORT      = { cormist = true, cormort = true },
    SLOW_SUPPORT_RANGE = 650,   -- a slow unit not listed above with at least this range is support too
    SLOW_SCREEN_AHEAD = 250,    -- the screen stands this far in front of the support's spot
    SLOW_SUPPORT_BACK = 250,    -- ...and the support holds this far behind the screen's centre
    SLOW_THREAT_R     = 450,    -- an enemy armed unit this close to a support is on top of it: the screen steps out
                                -- (no further: stray units further off are not chased)
    SLOW_LEG          = 600,    -- advance this far at a time (the screen must keep up)
    SLOW_ENGAGE_R     = 1600,   -- enemy armed value within this of the screen counts toward "a fight"
    -- The slow group ATTACKS THE OTHER SIDE: it always marches on the enemy's eco / main base and only
    -- stops for a real fight (enemy value near >= SLOW_FIGHT_FRAC x its own).  A few stray units are not a
    -- fight: it does not chase them (its FIGHT orders still shoot whatever is in range on the way).
    SLOW_FIGHT_FRAC   = 0.5,
    SLOW_BASE_R       = 1500,   -- structures this close together are one base; the densest cluster is the target
    SLOW_OBJ_EVERY    = 300,    -- frames between re-picking the base (keeps it from flip-flopping)
    SLOW_ARRIVE       = 250,    -- marches to within this of the base's centre
    SLOW_PULL_RATIO   = 1.5,    -- enemy value near / ours above this: pull back (trade well, don't die)
    SLOW_RESUME_RATIO = 1.0,    -- ...and go back in once it is under this
    -- The slow group moves as LINES, not one ball.  The support stands SLOW_SPOT_DEPTH deep in each spot and
    -- the line widens one spot at a time only once a spot is full (4 Lashers deep, then a second spot, ...);
    -- the screen is a thinner line in front spanning the same width.
    SLOW_SPOT_DEPTH   = 4,      -- support units per spot, deep
    SLOW_SCREEN_DEPTH = 2,      -- screen units per spot (the screen is a thin front line)
    SLOW_SPOT_SPACING = 110,    -- elmos between spots across the line
    SLOW_DEPTH_SPACING = 55,    -- elmos between units standing deep in a spot
    -- The support's default is a FIGHT order toward the base: it fires as much as it can.  It gives ground
    -- only when it is at risk of dying:
    SLOW_DANGER_FRAC  = 0.6,    -- ...outvalued AND the nearest enemy is inside this share of its range
    SLOW_RISK_HP      = 0.4,    -- ...or a single unit is under this health with the enemy within 1.3 x range
    -- Range kiting.  The support is only worth anything while it fires, so it keeps the enemy IN range:
    SLOW_IN_RANGE     = 0.95,   -- the enemy is "in range" inside this share of the support's range
    SLOW_ADVANCE_TO   = 0.8,    -- out of range: close in to this share of range, then stand and shoot
    SLOW_RANGE_KEEP   = 0.9,    -- outvalued: back off only while the enemy is nearer than this share
    SLOW_PULL_STEP    = 300,    -- ...and by at most this much per pass (it fires while it moves)
    SLOW_STAND_OFF    = 2.0,    -- hold at the edge of STATIC defences worth more than this x the group (it was 1.0
                                -- and counted mobile units too, which stopped it short of the base)
    -- Scout calls: each attacking group asks for scouts to look ahead of where it wants to go.
    SCOUT_AHEAD     = 2200,   -- elmos ahead of the group, along its path to the target
    SCOUT_SIDE      = 900,    -- the second scout looks this far to the side
    CALL_SCOUTS_PER_GROUP = 2,
    CALL_SCOUT_MAX  = 6,
    -- FORWARD_CORE (2026-10-08, off by default = the old behaviour): a group's core is its FORWARD cluster --
    -- the unit nearest its target (or furthest along home->foe) that has company, and everyone within
    -- CORE_R of it -- not the units around the centroid of everyone.  With 3 groups out every new unit joins
    -- the weakest group from the factory, so the centroid slid back toward home (a group "attacking" a nano
    -- at the enemy base had its centre 11,000 elmos away) and the units at the front were sent back to it:
    -- vs BARb at 20:00, 112k of army stood at mid-map with the enemy commander in sight and 633 value guarding it.
    -- The core's value (not the whole group's, half of which is still walking) decides fights and targets.
    FORWARD_CORE    = false,
    CORE_R          = 1500,
    CORE_CLUSTER_R  = 500,    -- the forward unit needs CORE_COMPANY others this close
    CORE_COMPANY    = 2,
    -- Once a group is on the commander it keeps going while the guard is under this share of the core
    -- (CMDR_OPEN_FRAC only decides when it starts).  The guard estimate swings, and every drop-out sent three
    -- groups back across the map (flip-flopped 14:59-15:28 in that game).
    CMDR_KEEP_FRAC  = nil,    -- nil = CMDR_OPEN_FRAC (old behaviour)
    -- FORWARD_CORE: a core holding less than this share of the group's value waits (FIGHT where it stands) for
    -- the rest to catch up, unless it is already at its target.  nil = never waits.
    CORE_WAIT_FRAC  = nil,
    CORE_WAIT_R     = 4000,   -- ...counting only the units this close to the core
    -- FLANK (2026-10-08, off by default): go round the enemy's main army instead of through it.  In the mirror
    -- both stages sit ~45% of the way across, ~1300 elmos apart, and every group walked into the other side's staged
    -- army: 70-80% of a group lost in ~2 min for 450-2100 value killed by 16:30.  User: "gators are fast: group
    -- quickly, flank the enemy army, reach eco".  When the path to the target passes within FLANK_CLEAR of the
    -- biggest recently seen enemy army cluster (worth >= FLANK_MIN_FRAC of the core), the group heads for a waypoint
    -- FLANK_OFFSET to one side of it (the side is kept per group) until it is past the cluster.
    FLANK           = false,
    FLANK_CLEAR     = 1800,
    FLANK_OFFSET    = 2800,
    FLANK_MIN_FRAC  = 0.5,
    FLANK_CLUSTER_R = 1200,
    FLANK_MAX_AGE   = 600,    -- frames: a cluster seen longer ago than this is not steered round
}
M.CFG = CFG

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20

local MM, UQ, EI, ARMY
local combat, guards, muster, scouts, responding, bombers
local isHunting = function() return false end

local groups      = {}      -- array of attack groups
local byId        = {}      -- [id] = group
local unitGroup   = {}      -- [uid] = group id
local nextId      = 1
local squad       = {}      -- [uid] = frame it began a squad retreat
local stageX, stageZ
local foeSeenX, foeSeenZ, foeSeenSrc = 0, 0, nil
local lastBombF   = -99999
local lastWaitLog = -99999
local stageAV, reinforceAV = 0, 0
local totals      = { launches = 0, kills = 0, killBP = 0, killValue = 0, lostUnits = 0, lostValue = 0 }

local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end

local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end

local slowCache = {}
local function IsSlow(defID)
    local v = slowCache[defID]
    if v == nil then
        v = (UQ.max_speed(defID) or 0) < CFG.SLOW_SPEED
        slowCache[defID] = v
    end
    return v
end

local function Log(frame, fmtStr, ...)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[CK] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
end

function M.Init(o)
    MM, UQ, EI, ARMY = o.MM, o.UQ, o.EI, o.ARMY
    for k, v in pairs(o.cfg or {}) do CFG[k] = v end    -- caller overrides (LINE_CLICK: no automatic slow group)
    combat, guards, muster = o.combat, o.guards, o.muster
    scouts, responding, bombers = o.scouts, o.responding, o.bombers
    if o.isHunting then isHunting = o.isHunting end
    groups, byId, unitGroup, squad, slowCache = {}, {}, {}, {}, {}
    nextId, lastBombF, lastWaitLog = 1, -99999, -99999
    stageX, stageZ, foeSeenSrc = nil, nil, nil
    stageAV, reinforceAV = 0, 0
    totals = { launches = 0, kills = 0, killBP = 0, killValue = 0, lostUnits = 0, lostValue = 0 }
end

-- ── Queries other widgets use ─────────────────────────────────────────────────

-- On an attack: no per-unit retreat (the attack is a commitment, like a raider).
function M.IsRaiding(uid)
    local g = byId[unitGroup[uid]]
    return g ~= nil and g.state == "attack"
end
function M.IsSquadRetreating(uid) return squad[uid] ~= nil end
function M.StagePoint() return stageX, stageZ end
function M.Totals() return totals end
function M.Groups() return groups end
function M.StageValues() return stageAV, reinforceAV end
function M.GroupOf(uid) return byId[unitGroup[uid]] end
-- Is this unit committed to an attack group?  Units that are not (new units, reinforcements waiting at the
-- stage, fighters) may be pulled off to defend the base; units that are never are.
function M.InGroup(uid) return byId[unitGroup[uid]] ~= nil end

-- Points where the attacking groups want a scout, as {x, z, gid}: ahead of each group along its
-- path (and a second one to the side), refreshed every tick the group is attacking.  The unit
-- controller sends scout aircraft there so the group moves on fresh information.
function M.ScoutRequests()
    local out = {}
    for _, g in ipairs(groups) do
        if g.state == "attack" and g.scoutPts then
            for _, p in ipairs(g.scoutPts) do
                if #out < CFG.CALL_SCOUT_MAX then out[#out + 1] = { p[1], p[2], g.id } end
            end
        end
    end
    return out
end

-- How many scouts the labs should keep for the groups out now.
function M.ScoutDemand()
    local n = 0
    for _, g in ipairs(groups) do if g.state == "attack" then n = n + CFG.CALL_SCOUTS_PER_GROUP end end
    return math.min(n, CFG.CALL_SCOUT_MAX)
end

-- "attack" while any group attacks, "fall" while only retreating groups remain, else "stage".
function M.State()
    local fall = false
    for _, g in ipairs(groups) do
        if g.state == "attack" then return "attack" end
        fall = true
    end
    return fall and "fall" or "stage"
end

-- Centre of the biggest attacking group (the army's "front").
function M.Centroid()
    local best
    for _, g in ipairs(groups) do
        if g.state == "attack" and g.cx and (not best or g.value > best.value) then best = g end
    end
    if best then return best.cx, best.cz end
    return nil, nil
end

-- ── Enemy knowledge ───────────────────────────────────────────────────────────

-- Armed enemy value near a point: static defences within their reach, mobile units only if seen
-- recently.
local function ArmedValueNear(frame, x, z, r, mobileMaxAge, skipUid)
    local v = 0
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and rec.uid ~= skipUid then
            local reach = r + (c.mobile and 0 or (c.range or 0))
            if (not c.mobile or frame - rec.frame <= (mobileMaxAge or 300))
               and Dist(rec.x, rec.z, x, z) <= reach then
                v = v + c.value
            end
        end
    end
    return v
end

-- Damage value of killing a target: what it cost, the build power it carries, the income it makes.
local function DamageValue(t)
    local v = (t.value or 0) + CFG.BP_WEIGHT * (t.bp or 0) + (t.eco and CFG.ECO_BONUS or 0)
    if t.factory then v = v * CFG.LAB_FACTOR end
    return v
end

-- The enemy commander as a target, but only when it is open: seen recently, and little armed enemy
-- value around it besides itself (EI.ThreatAt counts the commander too, so its own value is taken
-- off).  Returns a target record like EI.RaidTargets' entries, or nil.
local function CommanderTarget(frame, groupValue, keeping)
    if groupValue < CFG.CMDR_MIN_AV then return nil end
    local x, z, seen, uid = EI.Commander()
    if not x or frame - seen > CFG.CMDR_FRESH then return nil end
    local rec = EI.Records()[uid]
    local c = rec and rec.c
    local own = (c and c.armed and c.hitsGnd) and c.value or 0
    local guard = math.max(0, EI.ThreatAt(frame, x, z, "ground") - own)
    local frac = (keeping and CFG.CMDR_KEEP_FRAC) or CFG.CMDR_OPEN_FRAC
    if guard > frac * groupValue then return nil end
    return { uid = uid, x = x, z = z, defID = rec and rec.defID, value = c and c.value or 0,
             bp = c and c.bp or 0, commander = true, guard = guard }
end

-- Best target for group g.  A target near another group's target is discounted so the groups
-- spread over the base instead of piling onto the same nano.
local function PickTarget(frame, g, groupValue)
    local best, bestScore
    local scale = g.slow and CFG.SLOW_DIST_SCALE or CFG.DIST_SCALE
    local defMax = CFG.TARGET_DEF_MAX * (g.slow and CFG.SLOW_DEF_MAX or 1)
    for _, t in ipairs(EI.RaidTargets(frame)) do
        local score = DamageValue(t) / (1 + Dist(g.cx, g.cz, t.x, t.z) / scale)
        if t.mobile then score = score * CFG.MOBILE_FACTOR end
        if EI.ThreatAt(frame, t.x, t.z, "ground") > defMax * groupValue then
            score = score * CFG.DEF_PENALTY
        end
        for _, o in ipairs(groups) do
            if o ~= g and o.state == "attack" and o.target
               and Dist(t.x, t.z, o.target.x, o.target.z) < CFG.DIFF_R then
                score = score * CFG.DIFF_PENALTY
                break
            end
        end
        if not bestScore or score > bestScore then best, bestScore = t, score end
    end
    return best, bestScore
end

-- ── Orders ────────────────────────────────────────────────────────────────────

local function Claim(frame, uid, cmd, x, z, targetID)
    ARMY.Claim(ARMY.PRIO.LINE, uid, {
        role = "BLOB", cmd = cmd, x = x, z = z, targetID = targetID,
    }, frame)
end

local GOLDEN = 2.399963
local function RingPos(i, cx, cz)
    local a, r = i * GOLDEN, CFG.STAGE_SPACING * math.sqrt(i)
    local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
    return MM.Clamp(x, z, CFG.MARGIN)
end

local function SendToStage(frame, list, base)
    table.sort(list, function(a, b) return a.uid < b.uid end)
    for i, u in ipairs(list) do
        local x, z = RingPos((base or 0) + i - 1, stageX, stageZ)
        Claim(frame, u.uid, CMD_MOVE, x, z)
    end
end

-- ── Members ───────────────────────────────────────────────────────────────────

-- Units this module commands: armed combat units nobody else has claimed.
local function Members()
    local ground, air = {}, {}
    for uid, defID in pairs(combat) do
        if Alive(uid) and not guards[uid] and not muster[uid] and not scouts[uid]
           and not responding[uid] and not squad[uid] then
            local role = ARMY.RoleOf(uid)
            if role == nil or role == "BLOB" or role == "LINE" then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then
                    local hp, mhp = Spring.GetUnitHealth(uid)
                    local u = { uid = uid, defID = defID, x = x, z = z,
                                hp = (hp and mhp and mhp > 0) and hp / mhp or 1, v = Value(defID) }
                    if UQ.is_air(defID) then air[#air + 1] = u
                    else
                        u.slow = IsSlow(defID)
                        ground[#ground + 1] = u
                    end
                end
            end
        end
    end
    return ground, air
end

local function Centroid(list)
    local sx, sz, sv = 0, 0, 0
    for _, u in ipairs(list) do sx, sz, sv = sx + u.x * u.v, sz + u.z * u.v, sv + u.v end
    if sv <= 0 then return nil end
    return sx / sv, sz / sv, sv
end

local function SumValue(list)
    local v = 0
    for _, u in ipairs(list) do v = v + u.v end
    return v
end

local function NearValue(list, x, z, r)
    local v = 0
    for _, u in ipairs(list) do
        if Dist(u.x, u.z, x, z) <= r then v = v + u.v end
    end
    return v
end

-- ── Hurt squads ───────────────────────────────────────────────────────────────

local function UpdateSquads(frame, ground)
    -- release finished retreats
    for uid, since in pairs(squad) do
        if not Alive(uid) then squad[uid] = nil
        else
            local hp, mhp = Spring.GetUnitHealth(uid)
            local ux, _, uz = Spring.GetUnitPosition(uid)
            local calm = ux and ArmedValueNear(frame, ux, uz, CFG.ENEMY_NEAR_R) <= 0
            if (hp and mhp and mhp > 0 and hp / mhp >= CFG.SQUAD_RELEASE)
               or (calm and frame - since > 450) then
                if ARMY.RoleOf(uid) == "RETREAT" then ARMY.Release(uid) end
                squad[uid] = nil
            else
                local hx, hz = MM.PointAt(0.10 * MM.Dist(), 0)
                ARMY.Claim(ARMY.PRIO.RETREAT, uid, { role = "RETREAT", cmd = CMD_MOVE, x = hx, z = hz }, frame)
            end
        end
    end
    -- find new ones among units that are in no group
    local free, taken = {}, {}
    for _, u in ipairs(ground) do if not unitGroup[u.uid] then free[#free + 1] = u end end
    for _, a in ipairs(free) do
        if not taken[a.uid] then
            local group, sumHp, val = {}, 0, 0
            for _, b in ipairs(free) do
                if not taken[b.uid] and Dist(a.x, a.z, b.x, b.z) <= CFG.SQUAD_R then
                    group[#group + 1] = b; sumHp = sumHp + b.hp; val = val + b.v
                end
            end
            for _, b in ipairs(group) do taken[b.uid] = true end
            if #group <= CFG.SQUAD_MAX and sumHp / #group < CFG.SQUAD_HP
               and ArmedValueNear(frame, a.x, a.z, CFG.ENEMY_NEAR_R) > val then
                for _, b in ipairs(group) do squad[b.uid] = frame end
                Log(frame, "squad retreat n=%d hp=%.2f", #group, sumHp / #group)
            end
        end
    end
end

-- ── Attack groups ─────────────────────────────────────────────────────────────

-- Fast groups are the MAX_GROUPS; the slow group is the one more, so at most MAX_GROUPS + 1 are out.
local function FastCount()
    local n = 0
    for _, g in ipairs(groups) do if not g.slow then n = n + 1 end end
    return n
end

local function SlowGroup()
    for _, g in ipairs(groups) do if g.slow and g.state == "attack" then return g end end
    return nil
end

local function HasSlowGroup()
    for _, g in ipairs(groups) do if g.slow then return true end end
    return false
end

local function FreeLane()
    local used = {}
    for _, g in ipairs(groups) do if not g.slow then used[g.lane] = true end end
    for l = 1, CFG.MAX_GROUPS do if not used[l] then return l end end
    return 1
end

local function Launch(frame, staged, slow)
    local g = { id = nextId, lane = slow and 2 or FreeLane(), state = "attack", peakN = #staged,
                startN = #staged, startF = frame, target = nil, arrivedF = nil, value = SumValue(staged),
                slow = slow or nil }
    nextId = nextId + 1
    for _, u in ipairs(staged) do unitGroup[u.uid] = g.id end
    groups[#groups + 1] = g
    byId[g.id] = g
    totals.launches = totals.launches + 1
    if slow then
        local heavy, escort, nh = 0, 0, 0
        for _, u in ipairs(staged) do
            if u.slow then heavy = heavy + u.v; nh = nh + 1 else escort = escort + u.v end
        end
        Log(frame, "SLOW group #%d launch: %d slow units av=%d + %d fast escorts av=%d (%.0f%% of the slow value) | %d groups out",
            g.id, nh, heavy, #staged - nh, escort, heavy > 0 and 100 * escort / heavy or 0, #groups)
    else
        Log(frame, "group #%d launch: %d units av=%d | stage av=%d vs reinforcing av=%d (%s) | %d groups out",
            g.id, #staged, g.value, stageAV, reinforceAV,
            reinforceAV > 0 and string.format("%.1fx", stageAV / reinforceAV) or "none walking", #groups)
    end
    return g
end

local function RemoveGroup(g)
    for uid, id in pairs(unitGroup) do if id == g.id then unitGroup[uid] = nil end end
    byId[g.id] = nil
    for i, o in ipairs(groups) do if o == g then table.remove(groups, i); break end end
end

local function EndGroup(frame, g, reason, n)
    Log(frame, "group #%d end (%s): %d of peak %d left after %ds | totals kills=%d bp=%d value=%d lost=%d units/%d",
        g.id, reason, n, g.peakN, math.floor((frame - g.startF) / 30),
        totals.kills, totals.killBP, totals.killValue, totals.lostUnits, totals.lostValue)
    g.state, g.fallFrame, g.target = "fall", frame, nil
end

-- FLANK: the biggest cluster of enemy ground army seen in the last FLANK_MAX_AGE frames (value within
-- FLANK_CLUSTER_R of its densest unit), as x, z, value.  Computed once per frame for all groups.
local clusterF, clusterX, clusterZ, clusterV = -1, nil, nil, 0
local function EnemyArmyCluster(frame)
    if clusterF == frame then return clusterX, clusterZ, clusterV end
    clusterF, clusterX, clusterZ, clusterV = frame, nil, nil, 0
    local pts = {}
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and c.mobile and not c.scout and not c.commander and not c.air
           and frame - rec.frame <= CFG.FLANK_MAX_AGE then
            pts[#pts + 1] = rec
        end
    end
    local R2 = CFG.FLANK_CLUSTER_R * CFG.FLANK_CLUSTER_R
    local best, bestV
    for _, a in ipairs(pts) do
        local v = 0
        for _, b in ipairs(pts) do
            local dx, dz = a.x - b.x, a.z - b.z
            if dx * dx + dz * dz <= R2 then v = v + b.c.value end
        end
        if not bestV or v > bestV then best, bestV = a, v end
    end
    if not best then return nil, nil, 0 end
    local sx, sz, sv = 0, 0, 0
    for _, b in ipairs(pts) do
        local dx, dz = best.x - b.x, best.z - b.z
        if dx * dx + dz * dz <= R2 then sx, sz, sv = sx + b.x * b.c.value, sz + b.z * b.c.value, sv + b.c.value end
    end
    clusterX, clusterZ, clusterV = sx / sv, sz / sv, sv
    return clusterX, clusterZ, clusterV
end

-- FLANK: a waypoint beside the enemy army when the straight path to (tx,tz) runs into it, else nil.  The side is
-- the far side from where the cluster sits relative to the path, and is kept for the group (g.flankSide).
local function FlankPoint(frame, g, cx, cz, tx, tz, groupValue)
    local ax, az, av = EnemyArmyCluster(frame)
    if not ax or av < CFG.FLANK_MIN_FRAC * groupValue then g.flankSide = nil; return nil end
    if Dist(ax, az, tx, tz) < CFG.FLANK_CLEAR then return nil end     -- it guards the target itself: no way round
    local dx, dz = tx - cx, tz - cz
    local L = math.sqrt(dx * dx + dz * dz)
    if L < 1 then return nil end
    local ux, uz = dx / L, dz / L
    local px, pz = ax - cx, az - cz
    local along = px * ux + pz * uz
    if along <= 0 or along >= L then g.flankSide = nil; return nil end  -- behind us, or beyond the target
    local lat = -px * uz + pz * ux                                     -- its offset across our path
    if math.abs(lat) >= CFG.FLANK_CLEAR then return nil end            -- the path already clears it
    local side = g.flankSide or ((lat >= 0) and -1 or 1)
    local wx, wz = ax - uz * side * CFG.FLANK_OFFSET, az + ux * side * CFG.FLANK_OFFSET
    local cwx, cwz = MM.Clamp(wx, wz, CFG.MARGIN)
    if not g.flankSide and Dist(cwx, cwz, wx, wz) > CFG.FLANK_OFFSET * 0.5 then
        side = -side                                                   -- that side is off the map: the other one
        wx, wz = ax - uz * side * CFG.FLANK_OFFSET, az + ux * side * CFG.FLANK_OFFSET
        cwx, cwz = MM.Clamp(wx, wz, CFG.MARGIN)
    end
    g.flankSide = side
    return cwx, cwz, av
end

-- Next leg: toward (tx,tz), turned up to ~70 degrees if that avoids enemy armed value.
-- The unit being attacked (skipUid) is not something to steer round: an armed target such as the
-- enemy commander would otherwise push every leg sideways and the group would circle it.
local function LegPoint(frame, cx, cz, tx, tz, groupValue, skipUid)
    local dx, dz = tx - cx, tz - cz
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 1 then return tx, tz end
    local step = math.min(CFG.LEG, d)
    dx, dz = dx / d, dz / d
    local bx, bz, bestCost
    for _, ang in ipairs({ 0, 0.6, -0.6, 1.2, -1.2 }) do
        local c, s = math.cos(ang), math.sin(ang)
        local rx, rz = dx * c - dz * s, dx * s + dz * c
        local px, pz = MM.Clamp(cx + rx * step, cz + rz * step, CFG.MARGIN)
        local cost = ArmedValueNear(frame, px, pz, CFG.ENEMY_NEAR_R, nil, skipUid)
                     + math.abs(ang) * CFG.FLANK_PENALTY * groupValue
        if not bestCost or cost < bestCost then bx, bz, bestCost = px, pz, cost end
    end
    return bx, bz
end

local supportCache = {}
local function IsSupport(defID)
    local v = supportCache[defID]
    if v == nil then
        local d = UnitDefs[defID]
        v = (d ~= nil and CFG.SLOW_SUPPORT[d.name] == true)
            or (IsSlow(defID) and (UQ.max_weapon_range(defID) or 0) >= CFG.SLOW_SUPPORT_RANGE)
        supportCache[defID] = v
    end
    return v
end

-- Enemy armed MOBILE units seen recently within r of the support units: the nearest one's position.
local function NearestThreat(frame, support, r)
    local best, bestD
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and c.mobile and not c.scout and frame - rec.frame <= 300 then
            for _, s in ipairs(support) do
                local d = Dist(rec.x, rec.z, s.x, s.z)
                if d <= r and (not bestD or d < bestD) then best, bestD = rec, d end
            end
        end
    end
    return best
end

-- The shortest weapon range among the support units: every one of them must be able to fire.
local rangeCache = {}
local function SupportRange(support)
    local r
    for _, u in ipairs(support) do
        local x = rangeCache[u.defID]
        if x == nil then x = UQ.max_weapon_range(u.defID) or 0; rangeCache[u.defID] = x end
        if x > 0 and (not r or x < r) then r = x end
    end
    return r or CFG.SLOW_SUPPORT_RANGE
end

-- The nearest enemy armed unit (a mobile one seen lately, or a standing defence) within r of a point.
local function NearestEnemy(frame, x, z, r)
    local best, bestD
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and (not c.mobile or frame - rec.frame <= 300) then
            local d = Dist(rec.x, rec.z, x, z)
            if d <= r and (not bestD or d < bestD) then best, bestD = rec, d end
        end
    end
    return best, bestD
end

-- The enemy's eco / main base: the densest cluster of standing enemy structures we know of (weighted by
-- how much it hurts to lose them), as its centre.  Before any structure is known, the enemy's start.
local function MainBase(frame)
    local pts = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile then pts[#pts + 1] = { t.x, t.z, math.max(1, DamageValue(t)) } end
    end
    local bestI, bestDens = nil, 0
    for i, p in ipairs(pts) do
        local dens = 0
        for _, q in ipairs(pts) do
            if Dist(p[1], p[2], q[1], q[2]) <= CFG.SLOW_BASE_R then dens = dens + q[3] end
        end
        if dens > bestDens then bestI, bestDens = i, dens end
    end
    if not bestI then
        local fx, fz = MM.Foe()
        return fx, fz, "foe"
    end
    local sx, sz, sv = 0, 0, 0
    for _, q in ipairs(pts) do
        if Dist(pts[bestI][1], pts[bestI][2], q[1], q[2]) <= CFG.SLOW_BASE_R then
            sx, sz, sv = sx + q[1] * q[3], sz + q[2] * q[3], sv + q[3]
        end
    end
    return sx / sv, sz / sv, "base"
end

-- Positions for a LINE of units.  `perSpot` units stand deep in each spot, and the line gets one more spot
-- across for every `perSpot` units, so it only widens once every spot is full (4 Lashers deep, then a
-- second spot, ...).  The line faces (ux,uz) and is centred on (cx,cz); the front rank of each spot is on
-- the line, the rest stand behind it.  Units are sorted by where they already stand across the line, so
-- neighbours stay neighbours and the group does not reshuffle every pass.  `width` (optional) makes the
-- line at least that wide (the screen spans the support's width).  Returns {[uid] = {x, z}}.
local function FormationSlots(units, perSpot, ux, uz, cx, cz, width)
    local out = {}
    local n = #units
    if n == 0 then return out end
    local px, pz = -uz, ux
    local spots = math.ceil(n / perSpot)
    width = math.max(width or 0, (spots - 1) * CFG.SLOW_SPOT_SPACING)
    -- (c is the CENTRE of the formation, not its front rank: shift the front forward by half the depth so the
    -- units' average stays on c.  Otherwise a group told to hold slides back half a depth every pass.)
    local frontShift = (math.min(perSpot, n) - 1) * 0.5 * CFG.SLOW_DEPTH_SPACING
    cx, cz = cx + ux * frontShift, cz + uz * frontShift
    for _, u in ipairs(units) do
        u.lat = (u.x - cx) * px + (u.z - cz) * pz
        u.fwd = (u.x - cx) * ux + (u.z - cz) * uz
    end
    table.sort(units, function(a, b)
        if a.lat ~= b.lat then return a.lat < b.lat end
        return a.uid < b.uid
    end)
    for s = 0, spots - 1 do
        local chunk = {}
        for i = s * perSpot + 1, math.min(n, (s + 1) * perSpot) do chunk[#chunk + 1] = units[i] end
        table.sort(chunk, function(a, b)
            if a.fwd ~= b.fwd then return a.fwd > b.fwd end
            return a.uid < b.uid
        end)
        local lat = (spots == 1) and 0 or ((s / (spots - 1)) - 0.5) * width
        for k, u in ipairs(chunk) do
            local back = (k - 1) * CFG.SLOW_DEPTH_SPACING
            local x, z = MM.Clamp(cx + px * lat - ux * back, cz + pz * lat - uz * back, CFG.MARGIN)
            out[u.uid] = { x, z }
        end
    end
    return out
end

local function Away(fromX, fromZ, x, z, fallbackX, fallbackZ)
    local ax, az = x - fromX, z - fromZ
    local al = math.sqrt(ax * ax + az * az)
    if al > 1 then return ax / al, az / al end
    return fallbackX, fallbackZ
end

-- The slow group: a line of Pounders (screen) in front of a line of Lashers/Sheldons (support), marching on
-- the enemy's main base.  The support is only worth anything while it FIRES, so its default is a FIGHT
-- order toward the base, and it gives ground only when it is at risk of dying (outvalued with the enemy
-- on top of it, or low on health with the enemy near) -- in short steps that keep the enemy in range.
local function UpdateSlow(frame, g, list)
    local screen, support = {}, {}
    for _, u in ipairs(list) do
        if IsSupport(u.defID) then support[#support + 1] = u else screen[#screen + 1] = u end
    end
    local lead = (#screen > 0) and screen or support
    local cx, cz = Centroid(lead)
    g.cx, g.cz, g.value, g.n = cx, cz, SumValue(list), #list
    g.heavy, g.escort = 0, 0
    for _, u in ipairs(list) do
        if u.slow then g.heavy = g.heavy + u.v else g.escort = g.escort + u.v end
    end

    local near = ArmedValueNear(frame, cx, cz, CFG.SLOW_ENGAGE_R)
    local ratio = near / math.max(1, g.value)

    -- where to: always the enemy's eco / main base, never a unit
    if not g.objX or frame - (g.objF or -99999) >= CFG.SLOW_OBJ_EVERY then
        g.objX, g.objZ, g.objKind = MainBase(frame)
        g.objF = frame
    end
    local ox, oz, objective = g.objX, g.objZ, g.objKind
    local dx, dz = ox - cx, oz - cz
    local d = math.sqrt(dx * dx + dz * dz)
    local ux, uz = 1, 0
    if d > 1 then ux, uz = dx / d, dz / d end

    -- scouts look ahead of the group, along its way and to one side
    do
        local k = math.min(CFG.SCOUT_AHEAD, d + 400)
        local ax, az = cx + ux * k, cz + uz * k
        local side = (g.id % 2 == 0) and 1 or -1
        local p1x, p1z = MM.Clamp(ax, az, CFG.MARGIN)
        local p2x, p2z = MM.Clamp(ax - uz * CFG.SCOUT_SIDE * side, az + ux * CFG.SCOUT_SIDE * side, CFG.MARGIN)
        g.scoutPts = { { p1x, p1z }, { p2x, p2z } }
    end

    -- Where the support is, how far it shoots, and the nearest enemy (the direction of a real fight).
    local spx, spz = cx, cz
    if #support > 0 then spx, spz = Centroid(support) end
    local R = SupportRange(support)
    local foe, dn = NearestEnemy(frame, spx, spz, CFG.SLOW_ENGAGE_R)
    local eux, euz = ux, uz
    if foe then
        local ex, ez = foe.x - cx, foe.z - cz
        local el = math.sqrt(ex * ex + ez * ez)
        if el > 1 then eux, euz = ex / el, ez / el end
    end
    local fight = foe ~= nil and near >= CFG.SLOW_FIGHT_FRAC * g.value     -- strays are not a fight
    local threat = NearestThreat(frame, support, CFG.SLOW_THREAT_R)

    -- AT RISK OF DYING is the only reason to give ground: outvalued AND the enemy right on top of the
    -- support (inside SLOW_DANGER_FRAC of its range).  Short of that the support keeps firing.
    local close = foe ~= nil and dn < R * CFG.SLOW_DANGER_FRAC
    if not g.pulled and ratio > CFG.SLOW_PULL_RATIO and close then
        g.pulled = true
        Log(frame, "SLOW group #%d pulls back (at risk): enemy av=%d vs ours %d (%.1fx), nearest %dm", g.id, near, g.value, ratio, dn)
    elseif g.pulled and (ratio < CFG.SLOW_RESUME_RATIO or not foe or dn > R * CFG.SLOW_RANGE_KEEP) then
        g.pulled = false
        Log(frame, "SLOW group #%d goes back in: enemy av=%d vs ours %d (%.1fx)", g.id, near, g.value, ratio)
    end

    -- Individual supports low on health with the enemy near back off on their own, a short step.
    local depthExtent = (math.min(CFG.SLOW_SPOT_DEPTH, #support) - 1) * CFG.SLOW_DEPTH_SPACING
    local keep = math.max(R * 0.4, R * CFG.SLOW_RANGE_KEEP - depthExtent)   -- the whole depth stays in range
    local fragile, sturdy = {}, {}
    for _, u in ipairs(support) do
        if foe and u.hp < CFG.SLOW_RISK_HP and Dist(u.x, u.z, foe.x, foe.z) < R * 1.3 then
            fragile[#fragile + 1] = u
        else
            sturdy[#sturdy + 1] = u
        end
    end

    if g.pulled and foe then
        -- the screen holds the line in front while the whole support line gives ground, still in range
        local sc = FormationSlots(screen, CFG.SLOW_SCREEN_DEPTH, eux, euz, cx, cz)     -- hold exactly where it stands
        for _, u in ipairs(screen) do
            local p = sc[u.uid]
            if threat then Claim(frame, u.uid, CMD_FIGHT, threat.x, threat.z)
            else Claim(frame, u.uid, CMD_FIGHT, p[1], p[2]) end
        end
        local back = (dn >= keep) and 0 or math.min(CFG.SLOW_PULL_STEP, keep - dn)     -- short, still in range
        local ax, az = Away(foe.x, foe.z, spx, spz, -eux, -euz)
        local sp = FormationSlots(support, CFG.SLOW_SPOT_DEPTH, eux, euz, spx + ax * back, spz + az * back)
        for _, u in ipairs(support) do
            local p = sp[u.uid]
            Claim(frame, u.uid, back > 0 and CMD_MOVE or CMD_FIGHT, p[1], p[2])      -- it fires while it moves
        end
        return
    end

    -- How far to advance this pass.  In a REAL fight (enemy value near >= half ours): close in until the
    -- enemy is in the support's range, then stand and shoot.  Otherwise -- nothing in sight, or just a few
    -- strays -- march on the main base; the FIGHT orders shoot whatever is in range on the way, and the
    -- strays are not chased.  Never into STATIC defences worth far more than the group.
    local step = 0
    if fight then
        ux, uz = eux, euz
        if dn > R * CFG.SLOW_IN_RANGE then
            step = math.min(CFG.SLOW_LEG, dn - R * CFG.SLOW_ADVANCE_TO)
        end
    elseif d > CFG.SLOW_ARRIVE then
        step = math.min(CFG.SLOW_LEG, d - CFG.SLOW_ARRIVE)
    end
    if step > 0 then
        local px, pz = cx + ux * (step + CFG.SLOW_SCREEN_AHEAD), cz + uz * (step + CFG.SLOW_SCREEN_AHEAD)
        if ArmedValueNear(frame, px, pz, CFG.SLOW_ENGAGE_R / 2, -1) > CFG.SLOW_STAND_OFF * g.value then
            step = 0                                   -- defences ahead worth far more than us: hold at their edge
        end
    end

    -- The lines.  Supports: spots of SLOW_SPOT_DEPTH units deep, widening only when a spot is full.  The
    -- screen spans the same width, a thin line in front.
    -- Where each line is centred.  Moving every unit relative to where the line already stands (never
    -- "centre + a fixed lead" while holding) is what stops a holding line creeping forward or sliding back:
    --   marching          : the screen leads by SCREEN_AHEAD, the support follows SUPPORT_BACK behind it;
    --   closing in (fight): both lines move up by `step`, the support staying at least SUPPORT_BACK behind the screen;
    --   in range (fight)  : both hold exactly where they are, the support FIRING from the spot it is in.
    local fCx, fCz, sCx, sCz
    if not fight then
        local leadDist = (step > 0) and (step + CFG.SLOW_SCREEN_AHEAD) or 0
        fCx, fCz = cx + ux * leadDist, cz + uz * leadDist
        sCx, sCz = cx + ux * (step - CFG.SLOW_SUPPORT_BACK), cz + uz * (step - CFG.SLOW_SUPPORT_BACK)
    elseif step > 0 then
        fCx, fCz = cx + ux * step, cz + uz * step
        sCx, sCz = spx + ux * step, spz + uz * step
        local over = (sCx - fCx) * ux + (sCz - fCz) * uz + CFG.SLOW_SUPPORT_BACK     -- > 0: nearer than BACK behind
        if over > 0 then sCx, sCz = sCx - ux * over, sCz - uz * over end
    else
        fCx, fCz = cx, cz
        sCx, sCz = spx, spz
    end
    local supportWidth = (math.ceil(#sturdy / CFG.SLOW_SPOT_DEPTH) - 1) * CFG.SLOW_SPOT_SPACING
    local sp = FormationSlots(sturdy, CFG.SLOW_SPOT_DEPTH, ux, uz, sCx, sCz)
    local sc = FormationSlots(screen, CFG.SLOW_SCREEN_DEPTH, ux, uz, fCx, fCz, supportWidth)

    -- the screen steps out only for something right on top of the support, otherwise it leads the march
    for _, u in ipairs(screen) do
        if threat then Claim(frame, u.uid, CMD_FIGHT, threat.x, threat.z)
        else Claim(frame, u.uid, CMD_FIGHT, sc[u.uid][1], sc[u.uid][2]) end
    end
    for _, u in ipairs(sturdy) do Claim(frame, u.uid, CMD_FIGHT, sp[u.uid][1], sp[u.uid][2]) end
    for _, u in ipairs(fragile) do
        local dd = Dist(u.x, u.z, foe.x, foe.z)
        if dd < keep then
            local ax, az = Away(foe.x, foe.z, u.x, u.z, -eux, -euz)
            local back = math.min(CFG.SLOW_PULL_STEP, keep - dd)
            local bx, bz = MM.Clamp(u.x + ax * back, u.z + az * back, CFG.MARGIN)
            Claim(frame, u.uid, CMD_MOVE, bx, bz)               -- still in range, still firing
        else
            Claim(frame, u.uid, CMD_FIGHT, u.x, u.z)
        end
    end

    if frame - (g.logF or -9999) >= 900 then
        g.logF = frame
        Log(frame, "SLOW group #%d (%s): %d screen + %d support (range %d, %d spots wide), enemy av near=%d (%.1fx ours), nearest %s%s",
            g.id, objective, #screen, #support, R, math.ceil(#sturdy / CFG.SLOW_SPOT_DEPTH), near, ratio,
            dn and string.format("%dm", dn) or "none",
            threat and ", screen answers a threat to the support" or "")
    end
end

-- FORWARD_CORE: the forward cluster of a group.  "Forward" is nearness to the group's target when it has one,
-- else distance along home->foe.  The forward unit must have CORE_COMPANY others within CORE_CLUSTER_R, so one
-- unit that ran ahead is not the core.  Returns core, far, cx, cz.
local function ForwardCore(list, g)
    local tx, tz = nil, nil
    if g.target then tx, tz = g.target.x, g.target.z end
    local need = math.min(CFG.CORE_COMPANY, #list - 1)
    local best, bestF
    for _, a in ipairs(list) do
        local n = 0
        for _, b in ipairs(list) do
            if a ~= b and Dist(a.x, a.z, b.x, b.z) <= CFG.CORE_CLUSTER_R then
                n = n + 1
                if n >= need then break end
            end
        end
        if n >= need then
            local f = tx and -Dist(a.x, a.z, tx, tz) or MM.Forward(a.x, a.z)
            if not bestF or f > bestF then best, bestF = a, f end
        end
    end
    local core, far = {}, {}
    if best then
        for _, u in ipairs(list) do
            if Dist(u.x, u.z, best.x, best.z) <= CFG.CORE_R then core[#core + 1] = u else far[#far + 1] = u end
        end
    end
    if #core == 0 then core, far = list, {} end
    local cx, cz = Centroid(core)
    return core, far, cx, cz
end

local function UpdateAttack(frame, g, list)
    local n = #list
    if n > g.peakN then g.peakN = n end
    if n == 0 or n < math.max(1, math.floor(g.peakN * CFG.FALL_FRAC)) then
        return EndGroup(frame, g, "group spent", n)
    end
    if g.slow then return UpdateSlow(frame, g, list) end

    -- the core: units near the group's centre.  Units far behind (reinforcements, stragglers) walk
    -- to the core instead of running ahead on their own.
    local cx, cz, core, far
    if CFG.FORWARD_CORE then
        core, far, cx, cz = ForwardCore(list, g)
    else
        cx, cz = Centroid(list)
        core, far = {}, {}
        for _, u in ipairs(list) do
            if Dist(u.x, u.z, cx, cz) <= CFG.STRAGGLER_R then core[#core + 1] = u else far[#far + 1] = u end
        end
        if #core > 0 and #far > 0 then cx, cz = Centroid(core) end
        if #core == 0 then core, far = list, {} end
    end
    g.cx, g.cz, g.value, g.n = cx, cz, SumValue(list), n
    -- what the group can fight with right now (FORWARD_CORE: the core, not units still walking in)
    local fightV = CFG.FORWARD_CORE and SumValue(core) or g.value
    g.coreValue = fightV
    if g.slow then
        g.heavy, g.escort = 0, 0
        for _, u in ipairs(list) do
            if u.slow then g.heavy = g.heavy + u.v else g.escort = g.escort + u.v end
        end
    end
    for _, u in ipairs(far) do Claim(frame, u.uid, CMD_MOVE, cx, cz) end

    -- the enemy commander, when it is out in the open, beats everything and pulls every group
    local cmdr = CommanderTarget(frame, fightV, g.target and g.target.commander)
    if cmdr then
        if g.target and g.target.commander then
            g.target.x, g.target.z, g.target.picked = cmdr.x, cmdr.z, frame     -- it walks: follow it
        else
            g.target = cmdr; cmdr.picked = frame
            Log(frame, "group #%d: enemy COMMANDER is open (guard av=%d vs group av=%d) at (%d,%d), %dm away",
                g.id, cmdr.guard, g.value, cmdr.x, cmdr.z, Dist(cx, cz, cmdr.x, cmdr.z))
        end
    elseif g.target and g.target.commander then
        g.target = nil
        Log(frame, "group #%d: the commander is no longer open, picking another target", g.id)
    end

    -- keep or pick a target
    local recs = EI.Records()
    if g.target and (not recs[g.target.uid] or frame - g.target.picked > CFG.TARGET_REPICK) then
        g.target = nil
    end
    if not g.target then
        local t, score = PickTarget(frame, g, fightV)
        if t then
            g.target = t; t.picked = frame
            local d = t.defID and UnitDefs[t.defID]
            Log(frame, "group #%d target %s bp=%d value=%d at (%d,%d) %dm away, score=%d", g.id,
                d and d.name or "?", t.bp or 0, t.value or 0, t.x, t.z, Dist(cx, cz, t.x, t.z), score or 0)
        end
    end

    local tx, tz
    if g.target then
        tx, tz = g.target.x, g.target.z
        g.arrivedF = nil
    else
        -- nothing known: head for where the enemy started (each group along its own lane) and
        -- look.  Give the intel scan (every 90 frames) time to show what is there.
        local fx, fz = MM.Foe()
        local px, pz = MM.Perp()
        local off = (g.lane - 2) * CFG.LANE_SPACING
        tx, tz = MM.Clamp(fx + px * off, fz + pz * off, CFG.MARGIN)
        if Dist(cx, cz, tx, tz) < CFG.NO_TARGET_R then
            g.arrivedF = g.arrivedF or frame
            if frame - g.arrivedF >= CFG.LOOK_FRAMES then return EndGroup(frame, g, "nothing to hit", n) end
        end
    end

    -- where scouts should look: ahead along the path (not past the target), and to one side
    do
        local dx, dz = tx - cx, tz - cz
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1 then
            local k = math.min(CFG.SCOUT_AHEAD, d + 400)
            local ax, az = cx + dx / d * k, cz + dz / d * k
            local side = (g.id % 2 == 0) and 1 or -1
            local bx, bz = ax - dz / d * CFG.SCOUT_SIDE * side, az + dx / d * CFG.SCOUT_SIDE * side
            local p1x, p1z = MM.Clamp(ax, az, CFG.MARGIN)
            local p2x, p2z = MM.Clamp(bx, bz, CFG.MARGIN)
            g.scoutPts = { { p1x, p1z }, { p2x, p2z } }
        end
    end

    if g.target and Dist(cx, cz, tx, tz) <= CFG.ATTACK_SWITCH then
        local visible = Alive(g.target.uid)
        for _, u in ipairs(core) do
            if visible then Claim(frame, u.uid, CMD_ATTACK, tx, tz, g.target.uid)
            else Claim(frame, u.uid, CMD_FIGHT, tx, tz) end
        end
    elseif CFG.FORWARD_CORE and CFG.CORE_WAIT_FRAC and #far > 0
           and fightV < CFG.CORE_WAIT_FRAC * (fightV + NearValue(far, cx, cz, CFG.CORE_WAIT_R)) then
        -- the front is a small part of what is about to arrive: hold and let it catch up.  Units further
        -- than CORE_WAIT_R (fresh from the factory) do not hold the front back.
        for _, u in ipairs(core) do Claim(frame, u.uid, CMD_FIGHT, cx, cz) end
        if frame - (g.waitLogF or -99999) >= 450 then
            g.waitLogF = frame
            Log(frame, "group #%d core waits for the rest: core av=%d of %d (%d far)", g.id, fightV, g.value, #far)
        end
    else
        local ltx, ltz = tx, tz
        if CFG.FLANK then
            local wx, wz, av = FlankPoint(frame, g, cx, cz, tx, tz, fightV)
            if wx then
                ltx, ltz = wx, wz
                if frame - (g.flankLogF or -99999) >= 450 then
                    g.flankLogF = frame
                    Log(frame, "group #%d flanks the enemy army (av=%d vs core %d): via (%d,%d), side %d", g.id, av,
                        fightV, wx, wz, g.flankSide or 0)
                end
            end
        end
        local lx, lz = LegPoint(frame, cx, cz, ltx, ltz, fightV, g.target and g.target.uid)
        for _, u in ipairs(core) do Claim(frame, u.uid, CMD_MOVE, lx, lz) end
    end
end

local function UpdateFall(frame, g, list)
    for i, u in ipairs(list) do
        local x, z = RingPos(40 * g.id + i - 1, stageX, stageZ)
        Claim(frame, u.uid, CMD_MOVE, x, z)
    end
    local cx, cz = Centroid(list)
    if not cx or Dist(cx, cz, stageX, stageZ) <= CFG.FALL_ARRIVE or frame - g.fallFrame > CFG.FALL_MAX_FRAMES then
        RemoveGroup(g)    -- the survivors are stage units again
    end
end

-- The attacking FAST group with the least value: where a new fast unit is most useful.
local function WeakestAttacker()
    local best
    for _, g in ipairs(groups) do
        if not g.slow and g.state == "attack" and g.cx and (not best or g.value < best.value) then best = g end
    end
    return best
end

-- Put a free unit straight into a group (it walks to the group's centre).
local function JoinGroup(frame, g, u)
    unitGroup[u.uid] = g.id
    g.value = g.value + u.v
    if g.slow then
        if u.slow then g.heavy = (g.heavy or 0) + u.v else g.escort = (g.escort or 0) + u.v end
    end
    if g.cx then Claim(frame, u.uid, CMD_MOVE, g.cx, g.cz) end
end

-- ── Bombers ───────────────────────────────────────────────────────────────────

local function UpdateBombers(frame)
    if not bombers or isHunting() then return end
    local list, value = {}, 0
    for uid, _ in pairs(bombers) do
        if Alive(uid) then
            list[#list + 1] = uid; value = value + Value(Spring.GetUnitDefID(uid))
        end
    end
    -- let go of a finished run so the bombers return to their pads
    if frame - lastBombF == 150 then
        for _, uid in ipairs(list) do if ARMY.RoleOf(uid) == "BLOB" then ARMY.Release(uid) end end
    end
    if #list < CFG.BOMBER_MIN or frame - lastBombF < CFG.BOMB_COOLDOWN then return end
    local hx, hz = MM.Home()
    local best, bestScore
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile and EI.ThreatAt(frame, t.x, t.z, "air") <= CFG.BOMB_AIR_MAX * value then
            local score = DamageValue(t) / (1 + Dist(hx, hz, t.x, t.z) / CFG.DIST_SCALE)
            if not bestScore or score > bestScore then best, bestScore = t, score end
        end
    end
    if not best then return end
    for _, uid in ipairs(list) do
        Claim(frame, uid, CMD_ATTACK, best.x, best.z, Alive(best.uid) and best.uid or nil)
    end
    lastBombF = frame
    local d = best.defID and UnitDefs[best.defID]
    Log(frame, "bomber run: %d bombers -> %s at (%d,%d)", #list, d and d.name or "?", best.x, best.z)
end

-- ── Entry points ──────────────────────────────────────────────────────────────

-- Call every 30 frames, after the planners that outrank this one.
function M.Update(frame)
    if not (MM and ARMY and EI and MM.Ready()) then return end

    -- The enemy's start is usually unreadable, so the foe is a mirror guess until a scout sights it
    -- (map_model.lua), and on this map the guess is thousands of elmos off.  The stage follows the
    -- foe, and no group leaves on a guess.
    local fx, fz = MM.Foe()
    local src = MM.FoeSource()
    if not stageX or Dist(fx, fz, foeSeenX, foeSeenZ) > 300 or src ~= foeSeenSrc then
        foeSeenX, foeSeenZ, foeSeenSrc = fx, fz, src
        stageX, stageZ = MM.PointAt(CFG.STAGE_FRAC * MM.Dist(), 0)
        stageX, stageZ = MM.Clamp(stageX, stageZ, CFG.MARGIN)
        Log(frame, "stage point (%d,%d), foe (%d,%d) via %s", stageX, stageZ, fx, fz, tostring(src))
    end
    local foeKnown = src ~= "mirror" or frame >= CFG.BLIND_DIVE_FRAME

    local ground, air = Members()
    UpdateSquads(frame, ground)

    -- who belongs where
    local byGroup, free = {}, {}
    for _, u in ipairs(ground) do
        if not squad[u.uid] then
            local gid = unitGroup[u.uid]
            if gid and byId[gid] then
                local l = byGroup[gid]
                if not l then l = {}; byGroup[gid] = l end
                l[#l + 1] = u
            else
                unitGroup[u.uid] = nil
                free[#free + 1] = u
            end
        end
    end

    local snapshot = {}      -- groups can be removed while updating
    for i, g in ipairs(groups) do snapshot[i] = g end
    for _, g in ipairs(snapshot) do
        local list = byGroup[g.id] or {}
        if g.state == "attack" then UpdateAttack(frame, g, list) else UpdateFall(frame, g, list) end
    end

    -- Units in no group.
    --  1. The slow group (if out) takes every free slow unit, and tops itself up with fast units
    --     only until they are SLOW_ESCORT_SHARE of its slow value -- enough mass, no more.
    local rest = {}
    local slowG = SlowGroup()
    if slowG then
        local fast = {}
        for _, u in ipairs(free) do
            if u.slow then JoinGroup(frame, slowG, u) else fast[#fast + 1] = u end
        end
        local want = CFG.SLOW_ESCORT_SHARE * (slowG.heavy or 0)
        table.sort(fast, function(a, b)
            return Dist(a.x, a.z, slowG.cx or stageX, slowG.cz or stageZ)
                 < Dist(b.x, b.z, slowG.cx or stageX, slowG.cz or stageZ)
        end)
        for _, u in ipairs(fast) do
            if (slowG.escort or 0) + u.v <= want + 0.5 * u.v then JoinGroup(frame, slowG, u)
            else rest[#rest + 1] = u end
        end
    else
        rest = free
    end

    --  2. With all MAX_GROUPS fast groups out, a fast unit goes straight to the weakest of them.
    local toStage = rest
    if FastCount() >= CFG.MAX_GROUPS and WeakestAttacker() then
        toStage = {}
        for _, u in ipairs(rest) do
            local g = (not u.slow) and WeakestAttacker() or nil
            if not g then toStage[#toStage + 1] = u else JoinGroup(frame, g, u) end
        end
    end
    SendToStage(frame, toStage)

    --  3. The rest wait at the stage.  Slow units there start the slow group; fast ones start fast
    --     groups by the stage-av / reinforce-av rule.  Slow units still walking in do not hold the
    --     fast groups back (they crawl; the fast groups would never leave).
    local stagedFast, stagedSlow, slowAV = {}, {}, 0
    stageAV, reinforceAV = 0, 0
    for _, u in ipairs(toStage) do
        local atStage = Dist(u.x, u.z, stageX, stageZ) <= CFG.STAGE_JOIN_R
        if u.slow then
            if atStage then stagedSlow[#stagedSlow + 1] = u; slowAV = slowAV + u.v end
        elseif atStage then
            stagedFast[#stagedFast + 1] = u; stageAV = stageAV + u.v
        else
            reinforceAV = reinforceAV + u.v
        end
    end
    if not HasSlowGroup() and foeKnown and slowAV >= CFG.SLOW_MIN_AV then
        -- the escorts: the fast units nearest the stage, up to the share of the slow value
        local want = CFG.SLOW_ESCORT_SHARE * slowAV
        local picked, have = {}, 0
        table.sort(stagedFast, function(a, b)
            return Dist(a.x, a.z, stageX, stageZ) < Dist(b.x, b.z, stageX, stageZ)
        end)
        for _, u in ipairs(stagedFast) do
            if have + u.v > want + 0.5 * u.v then break end
            picked[#picked + 1] = u; have = have + u.v
        end
        if have >= CFG.SLOW_ESCORT_WAIT * want or slowAV >= CFG.SLOW_FORCE_MULT * CFG.SLOW_MIN_AV then
            local members = {}
            for _, u in ipairs(stagedSlow) do members[#members + 1] = u end
            local taken = {}
            for _, u in ipairs(picked) do members[#members + 1] = u; taken[u.uid] = true end
            local remain = {}
            for _, u in ipairs(stagedFast) do
                if not taken[u.uid] then remain[#remain + 1] = u else stageAV = stageAV - u.v end
            end
            stagedFast = remain
            Launch(frame, members, true)
        elseif frame - lastWaitLog >= CFG.WAIT_LOG_EVERY then
            lastWaitLog = frame
            Log(frame, "slow group waiting for escorts: slow av=%d, fast escorts av=%d of %d wanted", slowAV, have, want)
        end
    end
    if FastCount() < CFG.MAX_GROUPS and foeKnown and stageAV >= CFG.LAUNCH_MIN_AV then
        if stageAV >= CFG.LAUNCH_RATIO * reinforceAV or stageAV >= CFG.LAUNCH_FORCE_AV then
            Launch(frame, stagedFast, false)
        elseif frame - lastWaitLog >= CFG.WAIT_LOG_EVERY then
            lastWaitLog = frame
            Log(frame, "waiting for reinforcements: stage av=%d, reinforcing av=%d (needs %.1fx)",
                stageAV, reinforceAV, CFG.LAUNCH_RATIO)
        end
    end

    -- fighters escort the biggest attacking group, else wait at the stage
    local escort
    for _, g in ipairs(groups) do
        if g.state == "attack" and g.cx and (not escort or g.value > escort.value) then escort = g end
    end
    for _, u in ipairs(air) do
        if UQ.is_dedicated_aa(u.defID) then
            if escort then Claim(frame, u.uid, CMD_MOVE, escort.cx, escort.cz)
            else Claim(frame, u.uid, CMD_MOVE, stageX, stageZ) end
        end
    end

    UpdateBombers(frame)

    if frame % 1800 == 900 and (totals.launches > 0 or stageAV > 0) then
        Log(frame, "totals: launches=%d kills=%d bp=%d value=%d | lost %d units/%d value | groups=%d stage av=%d reinforcing av=%d",
            totals.launches, totals.kills, totals.killBP, totals.killValue, totals.lostUnits,
            totals.lostValue, #groups, stageAV, reinforceAV)
    end
end

-- A unit died.  Ours in a group are the cost; an enemy build-power / eco / factory kill near an
-- attacking group is the result.
function M.OnDestroyed(uid, defID, isMine, frame, x, z)
    if isMine then
        local g = byId[unitGroup[uid]]
        if g and g.state == "attack" then
            totals.lostUnits = totals.lostUnits + 1
            totals.lostValue = totals.lostValue + math.floor(Value(defID))
        end
        unitGroup[uid], squad[uid] = nil, nil
        return
    end
    -- Only what a group (or a bomber run) was actually near counts: the end-of-match commander
    -- self-destruct chain-kills a whole base and is not a result of the attack.
    local bombing = (frame - lastBombF) <= 600
    if not bombing then
        local near = false
        for _, g in ipairs(groups) do
            if g.state == "attack" and g.cx and (not x or Dist(x, z, g.cx, g.cz) <= CFG.KILL_R) then
                near = true; break
            end
        end
        if not near then return end
    end
    local c = EI and EI.Class and defID and EI.Class(defID)
    if c and (c.bp > 0 or c.factory or c.builder or c.eco) then
        totals.kills = totals.kills + 1
        totals.killBP = totals.killBP + math.floor(c.bp)
        totals.killValue = totals.killValue + math.floor(c.value)
        Log(frame, "KILL %s bp=%d value=%d (running: %d kills, %d bp)", UnitDefs[defID].name,
            c.bp, c.value, totals.kills, totals.killBP)
    end
end

return M
