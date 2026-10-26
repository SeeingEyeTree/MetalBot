-- bar_framework/scout_net.lua   (CORE: replaces the picket / line / depth / ring / recon scouting that followed FIND)
-- One system with one aim: the best picture of where the enemy's units are and how much they are worth, gathered cheaply.
--
-- Jobs, best first.  Every scout, ground radar unit and radar plane we hand it is matched to the nearest open job:
--   1. REQUESTS     anyone asks "look at (x, z)" through RequestScout / RequestSector / SacrificeScout (below).
--   2. SACRIFICE    every SACRIFICE_PERIOD one scout runs at the centre of the best group nobody has seen lately and is
--                   expected to die: going to the middle sees more of it than any post outside its guns.
--   3. GROUP WATCH  a scout (and a radar unit / plane) stands just outside the weapons of each valuable ground group,
--                   while that is survivable (the group's range is within what a scout can see; no AA under a plane).
--                   Groups that can't be watched are left to the sacrifice runs.
--   4. PERIMETER    one ring of scout posts around our structures, and a wider one of radar posts; a scout lost on a
--                   bearing pulls that part of the ring in, and the cap creeps back out.
--   5. SWEEP        scouts with nothing else keep stale sectors fresh (enemy half and known structures first).
-- While hunting (game won) the jobs are the commander's last sector and the sweep.
--
-- This module issues no orders: Step returns {[unitID] = claim spec} for the caller to give to ARMY.Claim.
-- API (also WG.ScoutNet): RequestScout, RequestSector, SacrificeScout, Repeat, CancelRequest, Picture, LastSeenNear,
-- Want, Step, Observe, SetStructures, OnLost, OnHurt, Stats.  The FIND phase stays in scout_lanes.lua.
-- CREEP (CFG.CREEP): standing vision that GROWS like zerg creep.  A grid of posts; the creep is the posts our units hold plus the ones
-- already in our sight (the base, the army, a radar's cover).  A new unit takes a post ADJACENT to the creep, preferring the ones toward the
-- enemy (and not too far out yet), so the net spreads outward one step at a time -- it never jumps ahead of itself or round the enemy.
-- Ground RADAR units grow their own wider net as they are built (spacing = CREEP_RADAR_SPACING x radar range); scouts (spacing =
-- CREEP_SPACING x sight) treat what a held radar post covers as creep already.
-- PULL BACK: a FRONT point is the enemy's groups (remembered CREEP_FRONT_MEMORY), the enemy base, and every place a creep unit died or met
-- an enemy; no post may stand on or behind a front (farther out along its bearing, CREEP_FRONT_WIDTH either side), so the creep contracts to
-- our side.  A loss also pulls that bearing's limit in (CREEP_BACKOFF, creeping back out at CREEP_RECOVER) and the post is skipped a while.
-- A creep unit with an armed enemy in its vision (+ margin) where it STANDS -- also while walking to a post -- gets an urgent RETREAT claim
-- (no post hold, no order rate limit) and is kept out of the jobs for CREEP_RETREAT_HOLD.
-- Posts under a known gun or beside the enemy base are never used.  Scouts left over after the posts still sweep.

local M = {}

M.CFG = {
    -- enemy groups
    GROUP_RADIUS      = 450,     -- units this close join a group
    GROUP_MAX_AGE     = 3600,    -- a group not seen for this long is forgotten (2 min); the runs revisit it before then
    GROUP_MATCH       = 900,     -- a group this close to last pass's group is the same group
    -- group watch
    WATCH_MAX         = 3,       -- groups watched at once
    WATCH_MIN_VALUE   = 400,     -- ignore groups worth less than this
    WATCH_FRESH       = 900,     -- ...and groups not seen for this long (a standoff post at an old position is pointless)
    WATCH_MARGIN      = 150,     -- a scout stands this far outside the group's longest weapon
    WATCH_SIGHT_SLACK = 250,     -- ...and that must be within its sight plus this (the group is wide)
    WATCH_RADAR_MARGIN = 350,
    -- sacrifice runs
    SACRIFICE_PERIOD  = 900,     -- frames between runs (30 s)
    SACRIFICE_STALE   = 600,     -- only a group not seen for this long is worth a run
    SACRIFICE_MIN_VALUE = 300,
    SACRIFICE_TTL     = 1500,    -- a run that has not arrived by now is dropped
    ARRIVE            = 150,     -- "arrived" distance for a run
    -- perimeter
    PERIM_MARGIN      = 450,     -- scout ring stands this far outside our outermost structure
    PERIM_MAX         = 16,
    PERIM_RADAR_EXTRA = 800,     -- radar ring is this much further out
    PERIM_RADAR_MAX   = 6,
    BINS              = 24,
    BACKOFF           = 700,     -- a loss caps its bearing this far inside where the scout died
    RECOVER           = 15,      -- elmos per second the cap creeps back out
    SIGHT_FACTOR      = 1.7,     -- post spacing = this x sight radius
    MIN_SPACING       = 500,
    MAX_SPACING       = 1300,
    DEFAULT_SIGHT     = 400,
    FOE_KEEPOUT       = 2600,    -- no perimeter post this close to the enemy base
    MAP_MARGIN        = 150,
    -- creep (zerg-style standing vision, see the header)
    CREEP             = false,
    CREEP_SPACING     = 1.7,     -- scout post spacing = this x sight radius (1.41 leaves no gap between four posts; more trades gaps for reach)
    CREEP_RADAR_SPACING = 1.6,   -- radar post spacing = this x radar range
    CREEP_RADAR_COVER = 0.8,     -- a held radar post covers scout posts within this x its range
    CREEP_MAX         = 40,      -- most scouts the creep may ask the labs for
    CREEP_START_INC   = 40,      -- metal/s before the first creep scout; one more per CREEP_INC_PER
    CREEP_INC_PER     = 8,
    CREEP_RADAR_MAX   = 8,       -- most radar units the creep may ask for
    CREEP_RADAR_START_INC = 150,
    CREEP_RADAR_INC_PER = 100,
    CREEP_SEED_MARGIN = 1000,    -- everything within this of our outermost structure is creep already (the net grows from there)
    CREEP_LAYER_W     = 0.6,     -- frontier order = this x distance from our base + distance to the nearest enemy (lower first): 0 = straight
                                 -- at the enemy, large = fill layer by layer
    CREEP_FRONT_MEMORY = 5400,   -- an enemy group stays a front point this long after it was last seen (3 min)
    CREEP_FRONT_MARGIN = 600,    -- no post this close to a front point's distance from our base, or beyond it ...
    CREEP_FRONT_WIDTH = 1800,    -- ... within this many elmos either side of its bearing
    CREEP_LOSS_FRONT  = 5400,    -- a creep unit lost here makes this a front point for this long (an enemy met: a third of it)
    CREEP_FOE_KEEPOUT = 2200,    -- no post this close to the enemy base
    CREEP_THREAT_PERIOD = 90,    -- frames between known-turret checks of the posts
    CREEP_BACKOFF     = 900,     -- a loss pulls the limit this far inside where the unit died (hurt: half)
    CREEP_RECOVER     = 4,       -- elmos per second the limit creeps back out
    CREEP_FLOOR_MARGIN = 700,    -- the ring never comes in closer than our outermost structure + this
    CREEP_RADAR_SIGHT = 700,     -- a radar unit's vision when none is built yet
    CREEP_RADAR_DANGER = 400,    -- an enemy armed unit within a held radar post's vision + this sends the radar unit back
    CREEP_SCOUT_DANGER = 150,    -- ... and within a held scout post's vision + this sends the scout back
    CREEP_RETREAT_STEP = 1000,   -- a creep unit with an enemy in its vision backs off this far (away from the enemy, toward home)
    CREEP_RETREAT_HOLD = 300,    -- ... and is kept out of the jobs this long (it is re-checked where it stands)
    CREEP_COOLDOWN    = 2700,    -- a post that cost a unit is skipped this long (90 s), doubled per repeated loss
    CREEP_COOLDOWN_MAX = 21600,
    -- sweep
    SWEEP_FRESH       = 1800,    -- a sector seen within this is not worth a trip
    SWEEP_STALE_CAP   = 5400,
    SWEEP_STRUCT_BOOST = 0.5,
    SWEEP_STRUCT_CAP  = 6,
    SWEEP_BASE_BOOST  = 4,
    SWEEP_BASE_R      = 2500,
    OUR_HALF_WEIGHT   = 0.1,
    COMMANDER_BOOST   = 10,
    DIST_SOFTEN       = 3000,
    SWEEP_TIMEOUT     = 1800,
    -- requests and orders
    REQUEST_TTL       = 1800,
    HOLD              = 300,     -- minHold on a post: a unit is not shuffled between posts more often than this
    -- how many units the labs should keep (the income curves are the old ring ones)
    BASE_SCOUTS       = 2,       -- the FIND pair stays as sweepers
    START_INC         = 60,      -- metal/s before the first extra scout; one more per INC_PER
    INC_PER           = 10,
    MAX_SCOUTS        = 30,
    HUNT_SCOUTS       = 5,
    RADAR_START_INC   = 200,
    RADAR_INC_PER     = 150,
    RADAR_MAX         = 6,
}

local CMD_MOVE = 10
local RANK_REQUEST, RANK_SACRIFICE, RANK_WATCH, RANK_PERIM, RANK_CREEP = 1, 2, 3, 4, 5

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, UQ, EI
local allyID
local sectors, sectorSize = nil, nil
local requests, nextId = {}, 1          -- [id] = request
local reqByKey = {}                     -- [key] = id
local repeats = {}                      -- list of {target, every, nextFrame, opts}
local tracked, nextGid = {}, 1          -- the groups seen last pass, with stable ids
local holder, heldBy = {}, {}           -- [jobKey] = unitID, [unitID] = jobKey
local sweepOf = {}                      -- [unitID] = {key, since}
local sacNext = 0
local want = { scouts = 2, radars = 0 }
local stats = { lost = 0, hurt = 0, sacLost = 0, sacSent = 0, served = 0, watchers = 0, groups = 0, posts = 0 }

-- footprint of our structures, in bearing bins
local cx, cz = nil, nil
local hull, capR = {}, {}
local lastRecover = 0
local lastPicture = nil
local creepSet = { scout = nil, radar = nil }   -- [kind] = { range, spacing, posts, at[i][j], plan = { frontier, held } }
local frontMem, lossFronts = {}, {}           -- enemy groups remembered for the front line / { x, z, untilFrame }: where creep units were lost
local retreat = {}                           -- [unitID] = { untilFrame, x, z }: creep units backing off an enemy
local creepCap = {}                          -- [bearing bin] = farthest distance from our centre creep posts may stand at
local creepDead = {}                         -- [postKey] = {untilFrame, n}: posts that cost a scout
local creepThreat, creepThreatAt = {}, -1e9  -- [postKey] = true: a known gun covers it (refreshed every CREEP_THREAT_PERIOD)

function M.Init(opts)
    MM, UQ, EI = opts.MM, opts.UQ, opts.EI
    allyID = opts.allyID
    if opts.cfg then for k, v in pairs(opts.cfg) do M.CFG[k] = v end end
    sectors, sectorSize = nil, nil
    requests, nextId, reqByKey, repeats = {}, 1, {}, {}
    tracked, nextGid, holder, heldBy, sweepOf = {}, 1, {}, {}, {}
    sacNext, lastRecover, lastPicture = 0, 0, nil
    creepSet, creepDead, creepThreat, creepThreatAt, retreat = { scout = nil, radar = nil }, {}, {}, -1e9, {}
    frontMem, lossFronts = {}, {}
    cx, cz = nil, nil
    for b = 1, M.CFG.BINS do hull[b], capR[b], creepCap[b] = 0, math.huge, math.huge end
    stats = { lost = 0, hurt = 0, sacLost = 0, sacSent = 0, served = 0, watchers = 0, groups = 0, posts = 0 }
    want = { scouts = M.CFG.BASE_SCOUTS, radars = 0 }
end

local function EnsureSectors()
    if sectors or not (MM and MM.Ready()) then return end
    sectors, sectorSize = MM.BuildSectors(nil, 200)
end

local function Dist2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end

-- ── Seen sectors ──────────────────────────────────────────────────────────────

-- Any unit standing in a sector has seen it, and so has anything whose centre is in line of sight.
function M.Observe(frame, unitIDs)
    EnsureSectors()
    if not sectors then return end
    for i = 1, #unitIDs do
        local x, _, z = Spring.GetUnitPosition(unitIDs[i])
        if x then
            local s = sectors[MM.SectorKey(x, z, sectorSize)]
            if s then s.lastScouted = frame end
        end
    end
    if Spring.IsPosInLos and allyID then
        for _, s in pairs(sectors) do
            if Spring.IsPosInLos(s.x, 0, s.z, allyID) then s.lastScouted = frame end
        end
    end
end

-- Most recent frame any sector within `radius` of (x, z) was seen; nil if unknown.
function M.LastSeenNear(x, z, radius)
    if not (sectors and x) then return nil end
    local best
    for _, s in pairs(sectors) do
        if Dist2(s.x, s.z, x, z) <= radius * radius and s.lastScouted > 0 and (not best or s.lastScouted > best) then
            best = s.lastScouted
        end
    end
    return best
end

-- ── Footprint and perimeter ───────────────────────────────────────────────────

local function BinAngle(b) return -math.pi + (b - 0.5) / M.CFG.BINS * 2 * math.pi end
local function BinOf(x, z)
    local n = M.CFG.BINS
    local b = math.floor((math.atan2(z - cz, x - cx) + math.pi) / (2 * math.pi) * n) + 1
    return math.max(1, math.min(n, b))
end

-- pts = flat {x1, z1, x2, z2, ...} of our structures.
function M.SetStructures(pts)
    local n = math.floor(#pts / 2)
    if n == 0 then return end
    local sx, sz = 0, 0
    for i = 1, n do sx, sz = sx + pts[2 * i - 1], sz + pts[2 * i] end
    cx, cz = sx / n, sz / n
    local bins = M.CFG.BINS
    for b = 1, bins do hull[b] = 0 end
    for i = 1, n do
        local dx, dz = pts[2 * i - 1] - cx, pts[2 * i] - cz
        for b = 1, bins do
            local a = BinAngle(b)
            local h = dx * math.cos(a) + dz * math.sin(a)
            if h > hull[b] then hull[b] = h end
        end
    end
end

function M.Centre() return cx, cz end

local function Recover(frame)
    local dt = math.max(0, frame - lastRecover)
    lastRecover = frame
    if dt == 0 then return end
    for b = 1, M.CFG.BINS do
        if capR[b] < math.huge then capR[b] = capR[b] + M.CFG.RECOVER * dt / 30 end
        if creepCap[b] < math.huge then creepCap[b] = creepCap[b] + M.CFG.CREEP_RECOVER * dt / 30 end
    end
end

-- A scout (or radar unit) died or was hurt at (x, z): the ring there stands inside that.  Runs and requests are
-- expected to die and say so with `expected`, which keeps them out of the caps.
local function Cap(x, z, frame)
    if not cx then return end
    local b = BinOf(x, z)
    local r = math.sqrt(Dist2(x, z, cx, cz)) - M.CFG.BACKOFF
    for d = -1, 1 do
        local k = (b - 1 + d) % M.CFG.BINS + 1
        local floor = hull[k] + 120
        capR[k] = math.min(capR[k], math.max(floor, r))
    end
end

-- A front point (a loss, an enemy met): no creep post may stand there or behind it for `ttl` frames.
local function AddFront(x, z, frame, ttl)
    if not x then return end
    for _, f in ipairs(lossFronts) do
        if Dist2(f.x, f.z, x, z) < 300 ^ 2 then f.untilFrame = math.max(f.untilFrame, frame + ttl); return end
    end
    lossFronts[#lossFronts + 1] = { x = x, z = z, untilFrame = frame + ttl }
end

-- The creep limit on this bearing comes in to (x, z)'s distance minus `back` (never inside the base's floor).
local function CreepCap(x, z, back)
    if not cx or not x then return end
    local b = BinOf(x, z)
    local r = math.sqrt(Dist2(x, z, cx, cz)) - back
    for d = -1, 1 do
        local k = (b - 1 + d) % M.CFG.BINS + 1
        local floor = hull[k] + M.CFG.CREEP_FLOOR_MARGIN
        creepCap[k] = math.min(creepCap[k], math.max(floor, r))
    end
end

-- A creep unit died or was hurt: skip that post for a while (longer each time) and pull the ring on that bearing back.
local function CreepHurt(key, frame, died, x, z)
    local d = creepDead[key]
    local n = (d and d.n or 0) + (died and 1 or 0)
    local cd = math.min(M.CFG.CREEP_COOLDOWN * 2 ^ math.max(0, n - 1), M.CFG.CREEP_COOLDOWN_MAX)
    creepDead[key] = { untilFrame = frame + (died and cd or cd / 3), n = n }
    stats.creepLost = (stats.creepLost or 0) + (died and 1 or 0)
    CreepCap(x, z, died and M.CFG.CREEP_BACKOFF or M.CFG.CREEP_BACKOFF / 2)
    AddFront(x, z, frame, died and M.CFG.CREEP_LOSS_FRONT or M.CFG.CREEP_LOSS_FRONT / 3)
end

function M.OnLost(uid, x, z, frame)
    local key = heldBy[uid]
    if key and key:sub(1, 2) == "cr" then
        CreepHurt(key, frame or 0, true, x, z)      -- creep posts are far out by design: they pull their own limit in, not the perimeter's
    elseif key and (key:sub(1, 1) == "q") then
        stats.sacLost = stats.sacLost + 1
    else
        stats.lost = stats.lost + 1
        if x then Cap(x, z, frame or 0) end
    end
    M.Forget(uid)
end

function M.OnHurt(uid, x, z, frame)
    local key = heldBy[uid]
    if key and key:sub(1, 1) == "q" then return end
    if key and key:sub(1, 2) == "cr" then CreepHurt(key, frame or 0, false, x, z); return end
    stats.hurt = stats.hurt + 1
    if x then Cap(x, z, frame or 0) end
end

function M.Forget(uid)
    retreat[uid] = nil
    local key = heldBy[uid]
    if key then holder[key] = nil end
    heldBy[uid] = nil
    sweepOf[uid] = nil
end

local function Clamp(x, z)
    if MM then return MM.Clamp(x, z, M.CFG.MAP_MARGIN) end
    return x, z
end

local function FoeBearing()
    if not (MM and MM.Ready() and cx) then return nil end
    local fx, fz = MM.Foe()
    return math.atan2(fz - cz, fx - cx)
end

local function AngDiff(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then d = 2 * math.pi - d end
    return d
end

-- Posts on a ring `extra` outside the footprint (+ the cap), spaced `spacing` apart, most enemy-facing first.
local function RingPosts(extra, spacing, maxN)
    local posts = {}
    if not cx then return posts end
    local c = M.CFG
    local rsum = 0
    for b = 1, c.BINS do rsum = rsum + hull[b] + extra end
    local n = math.max(3, math.min(maxN, math.ceil(2 * math.pi * (rsum / c.BINS) / spacing)))
    local fx, fz
    if MM and MM.Ready() then fx, fz = MM.Foe() end
    local bearing = FoeBearing()
    for i = 1, n do
        local a = -math.pi + (i - 0.5) / n * 2 * math.pi
        local b = BinOf(cx + math.cos(a), cz + math.sin(a))
        local r = hull[b] + extra
        if capR[b] < math.huge then r = math.max(hull[b] + 120, math.min(r, capR[b] + (extra - c.PERIM_MARGIN))) end
        local x, z = Clamp(cx + math.cos(a) * r, cz + math.sin(a) * r)
        if not (fx and Dist2(x, z, fx, fz) < c.FOE_KEEPOUT ^ 2) then
            local dup = false
            for _, p in ipairs(posts) do
                if Dist2(p.x, p.z, x, z) < (c.MIN_SPACING * 0.6) ^ 2 then dup = true; break end
            end
            if not dup then posts[#posts + 1] = { x = x, z = z, face = bearing and AngDiff(a, bearing) or 0 } end
        end
    end
    table.sort(posts, function(p, q) if p.face ~= q.face then return p.face < q.face end return p.x < q.x end)
    return posts
end

-- ── Creep ─────────────────────────────────────────────────────────────────────
-- Standing vision that GROWS like zerg creep: a grid of posts; the creep is the posts our units hold plus the ones already in our
-- sight (the base, the army, a radar's cover); a new unit takes a post ADJACENT to the creep, preferring the ones toward the enemy,
-- so the net spreads outward one step at a time and never jumps ahead or round the enemy.  Pull-back: a loss or an enemy in view
-- adds a FRONT point there; no post may stand on or behind a front (beyond it along its bearing), so the creep contracts to our side.

-- The armed enemy mobile units seen lately (the post check and the unit guard both use this list).
local function CreepFoes(frame)
    local foes = {}
    if EI then
        for _, rec in pairs(EI.Records()) do
            if rec.c.armed and rec.c.mobile and frame - rec.frame <= EI.POSITION_FRESH then foes[#foes + 1] = rec end
        end
    end
    return foes
end

local function CreepHull()
    local m = 0
    for b = 1, M.CFG.BINS do if hull[b] > m then m = hull[b] end end
    return m
end

-- The post grid for one kind of unit ("scout" | "radar") with this sight / radar range.
local function BuildGrid(kind, range, probeDef)
    local c = M.CFG
    local mx, mz = MM.MapSize()
    if not mx then return nil end
    local spacing = math.max(c.MIN_SPACING, (kind == "radar" and c.CREEP_RADAR_SPACING or c.CREEP_SPACING) * range)
    local nx, nz = math.max(1, math.ceil(mx / spacing)), math.max(1, math.ceil(mz / spacing))
    local tag = kind == "radar" and "r" or "s"
    local posts, at = {}, {}
    for i = 1, nx do
        at[i] = {}
        for j = 1, nz do
            local x, z = Clamp((i - 0.5) * mx / nx, (j - 0.5) * mz / nz)
            local pass = true
            if probeDef and Spring.TestMoveOrder then
                local okc, can = pcall(Spring.TestMoveOrder, probeDef, x, (Spring.GetGroundHeight and Spring.GetGroundHeight(x, z)) or 0, z)
                if okc and can == false then pass = false end
            end
            if pass then
                local p = { key = "cr" .. tag .. ":g" .. i .. "_" .. j, x = x, z = z, i = i, j = j }
                posts[#posts + 1] = p
                at[i][j] = p
            end
        end
    end
    return { kind = kind, range = range, spacing = spacing, posts = posts, at = at }
end

-- Where the enemy is, for the front line: the groups seen in the last CREEP_FRONT_MEMORY frames, the places units were lost or an
-- enemy was met, and the enemy base.
local function FrontPoints(frame, groups)
    local c = M.CFG
    for _, g in ipairs(groups or {}) do
        if g.id and not g.air and g.value >= c.WATCH_MIN_VALUE then frontMem[g.id] = { x = g.x, z = g.z, seen = g.lastSeen } end
    end
    local out = {}
    for id, f in pairs(frontMem) do
        if frame - f.seen > c.CREEP_FRONT_MEMORY then frontMem[id] = nil else out[#out + 1] = f end
    end
    for i = #lossFronts, 1, -1 do
        if frame >= lossFronts[i].untilFrame then table.remove(lossFronts, i) else out[#out + 1] = lossFronts[i] end
    end
    local fx, fz = MM.Foe()
    if fx then out[#out + 1] = { x = fx, z = fz } end
    return out
end

-- Is (x, z) on or behind a front point, as seen from our centre?  (Farther out than the point less `margin`, on its bearing within
-- `width` sideways.)
local function BehindFront(x, z, fronts, ox, oz, margin, width)
    local px, pz = x - ox, z - oz
    local rp = math.sqrt(px * px + pz * pz)
    for _, f in ipairs(fronts) do
        local fx, fz = f.x - ox, f.z - oz
        local rf = math.sqrt(fx * fx + fz * fz)
        if rf > 1 and rp > rf - margin then
            if (px * fx + pz * fz) / rf > 0 and math.abs(px * fz - pz * fx) / rf <= width then return true end
        end
    end
    return false
end

-- One kind's creep this pass.  Returns the jobs (posts held now, then the open frontier best first), the open frontier size and the
-- number of held posts.  covered = { list, r } (scouts: what a held radar post covers is creep already).
local function CreepPlan(kind, frame, range, perim, groups, probeDef, covered, vision, posOf, fronts)
    local c = M.CFG
    local set = creepSet[kind]
    if not set or math.abs(set.range - range) > 1 then
        set = BuildGrid(kind, range, probeDef)
        creepSet[kind] = set
        creepThreatAt = -1e9
    end
    if not set then return {}, 0, 0 end
    set.vision = vision or set.vision or 0
    if frame - creepThreatAt >= c.CREEP_THREAT_PERIOD then
        local prev = creepThreat
        creepThreatAt, creepThreat = frame, {}
        if EI then
            -- a post is unsafe when a known gun covers it or an armed enemy mobile unit seen lately is within its unit's vision + a margin
            local foes = CreepFoes(frame)
            for _, s2 in pairs(creepSet) do
                local dr = (s2.vision or 0) + (s2.kind == "radar" and c.CREEP_RADAR_DANGER or c.CREEP_SCOUT_DANGER)
                for _, p in ipairs(s2.posts) do
                    local bad = EI.ThreatAt(frame, p.x, p.z, "ground") > 0
                    if not bad then
                        for _, f in ipairs(foes) do
                            if Dist2(f.x, f.z, p.x, p.z) <= dr * dr then bad = true; break end
                        end
                    end
                    if bad then
                        creepThreat[p.key] = true
                        -- a held post that has just turned unsafe: the creep pulls back from there
                        if holder[p.key] and not prev[p.key] then
                            CreepCap(p.x, p.z, c.CREEP_BACKOFF / 2)
                            AddFront(p.x, p.z, frame, c.CREEP_LOSS_FRONT / 3)
                        end
                    end
                end
            end
        end
    end

    local hx, hz = MM.Home()
    local ox, oz = cx or hx, cz or hz
    local fx, fz = MM.Foe()
    local seedR = CreepHull() + c.CREEP_SEED_MARGIN + (kind == "radar" and 0.5 * set.spacing or 0)
    local arriveR = math.min(0.4 * set.spacing, 500)

    -- eligibility and occupancy: a post is OK to stand on when it is safe, ahead of nothing, inside the loss limit and not already
    -- covered; it is OCCUPIED (creep) when a unit stands on it, it is in our sight, in the base, or a radar post covers it
    for _, p in ipairs(set.posts) do
        local d = creepDead[p.key]
        local ok = not (d and frame < d.untilFrame) and not creepThreat[p.key]
        if ok and fx and Dist2(p.x, p.z, fx, fz) < c.CREEP_FOE_KEEPOUT ^ 2 then ok = false end
        if ok and cx then
            local cap = creepCap[BinOf(p.x, p.z)]
            if cap < math.huge and Dist2(p.x, p.z, cx, cz) > (cap + 0.3 * set.spacing) ^ 2 then ok = false end
        end
        if ok and BehindFront(p.x, p.z, fronts, ox, oz, c.CREEP_FRONT_MARGIN, c.CREEP_FRONT_WIDTH) then ok = false end
        local cov = false
        if covered then
            for _, q in ipairs(covered.list) do
                if Dist2(p.x, p.z, q.x, q.z) < covered.r ^ 2 then cov = true; break end
            end
        end
        if cov then ok = false end
        local who = holder[p.key]
        local occ = cov
        if ok and who then
            local pu = posOf[who]
            if pu and Dist2(pu[1], pu[2], p.x, p.z) <= arriveR ^ 2 then occ = true end      -- creep only counts once the unit is THERE
        end
        if not occ and not who then
            if Dist2(p.x, p.z, ox, oz) <= seedR ^ 2 then occ = true
            elseif Spring.IsPosInLos and allyID and Spring.IsPosInLos(p.x, 0, p.z, allyID) then occ = true
            else
                for _, q in ipairs(perim) do
                    if Dist2(p.x, p.z, q.x, q.z) < (c.MIN_SPACING * 0.6) ^ 2 then occ = true; break end
                end
            end
        end
        p.ok, p.occ = ok, occ
    end

    -- the frontier: open posts next to the creep; best = toward the enemy, and not too far out yet
    local targets = {}
    if fx then targets[1] = { fx, fz } end
    for _, g in ipairs(groups or {}) do
        if g.value >= c.WATCH_MIN_VALUE and not g.air then targets[#targets + 1] = { g.x, g.z } end
    end
    local held, frontier = {}, {}
    for _, p in ipairs(set.posts) do
        if p.ok then
            if holder[p.key] then
                held[#held + 1] = p
            elseif not p.occ then
                local adj = false
                for di = -1, 1 do
                    local col = set.at[p.i + di]
                    if col then
                        for dj = -1, 1 do
                            local q = (di ~= 0 or dj ~= 0) and col[p.j + dj] or nil
                            if q and q.occ then adj = true; break end
                        end
                    end
                    if adj then break end
                end
                if adj then
                    local best = math.huge
                    for _, t in ipairs(targets) do best = math.min(best, Dist2(p.x, p.z, t[1], t[2])) end
                    p.score = c.CREEP_LAYER_W * math.sqrt(Dist2(p.x, p.z, ox, oz)) + (best < math.huge and math.sqrt(best) or 0)
                    frontier[#frontier + 1] = p
                end
            end
        end
    end
    table.sort(frontier, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.key < b.key end)
    table.sort(held, function(a, b) return a.key < b.key end)
    local jobs = {}
    for _, p in ipairs(held) do jobs[#jobs + 1] = p end
    for _, p in ipairs(frontier) do jobs[#jobs + 1] = p end
    set.plan = { frontier = frontier, held = held, frame = frame }
    return jobs, #frontier, #held
end

-- ── Requests (the API) ────────────────────────────────────────────────────────

-- opts: kind "scout" (default) | "hawk" | "any" -- which units may answer
--       until "seen" (default: done once the spot is in our line of sight) | "arrive" | "expire"
--       ttl frames (default REQUEST_TTL), key (a repeated call with the same key refreshes one request), by (who asked, for logs)
-- Returns the request id.
function M.RequestScout(x, z, opts)
    opts = opts or {}
    local frame = Spring.GetGameFrame()
    local id = opts.key and reqByKey[opts.key]
    local r = id and requests[id]
    if not r then
        id = nextId; nextId = nextId + 1
        r = { id = id, since = frame, rank = opts.rank or RANK_REQUEST }
        requests[id] = r
        if opts.key then reqByKey[opts.key] = id end
    end
    r.x, r.z = x, z
    r.kind, r.untilMode, r.by = opts.kind or "scout", opts.untilMode or opts.finish or "seen", opts.by
    r.sacrifice = opts.sacrifice or false
    r.expires = frame + (opts.ttl or M.CFG.REQUEST_TTL)
    r.key = opts.key
    return id
end

function M.CancelRequest(id)
    local r = requests[id]
    if not r then return end
    if r.key then reqByKey[r.key] = nil end
    local jk = "q" .. id
    local u = holder[jk]
    if u then heldBy[u] = nil; holder[jk] = nil end
    requests[id] = nil
end

function M.RequestSector(key, opts)
    EnsureSectors()
    local s = sectors and sectors[key]
    if not s then return nil end
    return M.RequestScout(s.x, s.z, opts)
end

-- Send the nearest free scout straight at (x, z) and accept its loss.  opts.every re-sends it on that period.
function M.SacrificeScout(x, z, opts)
    opts = opts or {}
    stats.sacSent = stats.sacSent + 1
    local id = M.RequestScout(x, z, {
        kind = opts.kind or "scout", untilMode = "arrive", sacrifice = true, rank = opts.rank or RANK_SACRIFICE,
        ttl = opts.ttl or M.CFG.SACRIFICE_TTL, by = opts.by or "sacrifice",
    })
    if opts.every then M.Repeat({ x = x, z = z }, opts.every, opts) end
    return id
end

-- Re-issue a sacrifice run at `target` (a {x, z} table or a function returning x, z) every `every` frames.
function M.Repeat(target, every, opts)
    repeats[#repeats + 1] = { target = target, every = every, nextFrame = Spring.GetGameFrame() + every, opts = opts }
end

-- ── The picture ───────────────────────────────────────────────────────────────

local function GroupList(frame)
    if not EI then return {} end
    return EI.Groups(frame, M.CFG.GROUP_RADIUS, M.CFG.GROUP_MAX_AGE)
end

-- Give this pass's groups the ids of last pass's nearest ones.
local function MatchGroups(groups)
    local prev, used = tracked, {}
    for _, g in ipairs(groups) do
        local best, bestD = nil, M.CFG.GROUP_MATCH ^ 2
        for i, p in ipairs(prev) do
            if not used[i] then
                local d = Dist2(g.x, g.z, p.x, p.z)
                if d <= bestD then best, bestD = i, d end
            end
        end
        if best then used[best] = true; g.id = prev[best].id
        else g.id = nextGid; nextGid = nextGid + 1 end
    end
    tracked = groups
end

-- What we know of the enemy: groups (value order, with how old the last sighting is and whether one is watched),
-- the commander, and when we last saw the enemy base.
function M.Picture(frame)
    if lastPicture and lastPicture.frame == frame then return lastPicture end
    local groups = (tracked and #tracked > 0 and tracked[1].frame == frame) and tracked or GroupList(frame)
    local total = 0
    local out = {}
    for _, g in ipairs(groups) do
        total = total + g.value
        out[#out + 1] = { id = g.id, x = g.x, z = g.z, value = g.value, armedValue = g.armedValue, n = g.n, air = g.air,
                          range = g.range, tech = g.tech, lastSeen = g.lastSeen, age = frame - g.lastSeen,
                          watched = g.watched or false, scoutWatched = g.scoutWatched or false,
                          radarWatched = g.radarWatched or false }
    end
    local pic = { frame = frame, groups = out, totalValue = total }
    if EI then
        local x, z, f = EI.Commander()
        if x then pic.commander = { x = x, z = z, frame = f } end
    end
    if MM and MM.Ready() then
        local fx, fz = MM.Foe()
        pic.baseSeenFrame = M.LastSeenNear(fx, fz, M.CFG.SWEEP_BASE_R)
    end
    lastPicture = pic
    return pic
end

-- Debug / tests: this pass's creep of one kind ("scout" | "radar"): { frontier = {{key, x, z}, best first}, held = {...} }.
function M.CreepPlan(kind)
    local set = creepSet[kind]
    local out = { frontier = {}, held = {} }
    for _, p in ipairs(set and set.plan and set.plan.frontier or {}) do out.frontier[#out.frontier + 1] = { key = p.key, x = p.x, z = p.z } end
    for _, p in ipairs(set and set.plan and set.plan.held or {}) do out.held[#out.held + 1] = { key = p.key, x = p.x, z = p.z } end
    return out
end

-- Debug / tests: the creep limit (distance from our centre) on each bearing bin; math.huge = no loss there.
function M.CreepCaps() return creepCap end

function M.Want() return want end
function M.Stats() return stats end
function M.Tracked() return tracked end

-- ── Planning ──────────────────────────────────────────────────────────────────

local function SightOf(uid)
    local d = UnitDefs[Spring.GetUnitDefID(uid)]
    return d and (d.losRadius or d.sightDistance) or 0
end
local function RadarOf(uid)
    local d = UnitDefs[Spring.GetUnitDefID(uid)]
    return d and (d.radarRadius or d.radarDistance) or 0
end
local function Median(list)
    table.sort(list)
    return list[math.ceil(#list / 2)]
end

-- The point `d` from a group on the side toward home (the side our own units are on).
local function Standoff(g, d)
    local hx, hz = MM.Home()
    local dx, dz = hx - g.x, hz - g.z
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1 then dx, dz, l = 1, 0, 1 end
    d = math.min(d, l)
    return Clamp(g.x + dx / l * d, g.z + dz / l * d)
end

local function Job(list, key, rank, accepts, x, z, role, extra)
    local j = { key = key, rank = rank, accepts = accepts, x = x, z = z, role = role }
    if extra then for k, v in pairs(extra) do j[k] = v end end
    list[#list + 1] = j
end

-- Sweep score for a sector (nil = not worth the trip).
local function SweepScore(frame, s, key, counts, hunting, ccx, ccz, ux, uz)
    local stale = frame - s.lastScouted
    if s.lastScouted > 0 and stale < M.CFG.SWEEP_FRESH then return nil end
    stale = math.min(s.lastScouted == 0 and M.CFG.SWEEP_STALE_CAP or stale, M.CFG.SWEEP_STALE_CAP)
    local c = M.CFG
    local w = 1
    local fx, fz = MM.Foe()
    if not hunting then
        if MM.IsOurHalf(s.x, s.z) then w = w * c.OUR_HALF_WEIGHT end
        if fx and Dist2(s.x, s.z, fx, fz) <= c.SWEEP_BASE_R ^ 2 then w = w * c.SWEEP_BASE_BOOST end
    elseif ccx and MM.SectorKey(ccx, ccz, sectorSize) == key then
        w = w * c.COMMANDER_BOOST
    end
    local n = counts[key] or 0
    if n > 0 then w = w * (1 + c.SWEEP_STRUCT_BOOST * math.min(n, c.SWEEP_STRUCT_CAP)) end
    return stale * stale * w / (math.sqrt(Dist2(s.x, s.z, ux, uz)) + c.DIST_SOFTEN)
end

local function StructureCounts()
    local counts = {}
    if not EI then return counts end
    for _, rec in pairs(EI.Records()) do
        if not rec.c.mobile then
            local key = MM.SectorKey(rec.x, rec.z, sectorSize)
            counts[key] = (counts[key] or 0) + 1
        end
    end
    return counts
end

-- Creep units whose own position has an armed enemy within their vision (+ a margin), or a known gun over it, back off at once:
-- the post they hold is skipped for a while and its bearing pulled in, and they get a RETREAT claim toward home (away from the enemy).
-- Runs on the UNIT, so it works while the unit is still walking to its post.  Returns { [unitID] = claim spec }.
local function CreepGuard(frame, pool, sight, posOf)
    local c = M.CFG
    local out = {}
    for uid in pairs(retreat) do if not posOf[uid] then retreat[uid] = nil end end
    local foes
    local hx, hz = MM.Home()
    for _, kind in ipairs({ "scout", "radar" }) do
        for _, u in ipairs(pool[kind]) do
            local key = heldBy[u.id]
            local rt = retreat[u.id]
            if (key and key:sub(1, 2) == "cr") or rt then
                foes = foes or CreepFoes(frame)
                local vis = SightOf(u.id)
                if vis <= 0 then vis = (kind == "radar") and c.CREEP_RADAR_SIGHT or sight end
                local dr = vis + (kind == "radar" and c.CREEP_RADAR_DANGER or c.CREEP_SCOUT_DANGER)
                local near, nd = nil, dr * dr
                for _, f in ipairs(foes) do
                    local d = Dist2(f.x, f.z, u.x, u.z)
                    if d <= nd then near, nd = f, d end
                end
                local gun = EI and EI.ThreatAt(frame, u.x, u.z, "ground") > 0
                if near or gun then
                    -- away from the enemy, blended with the way home
                    local ax, az = 0, 0
                    if near then
                        ax, az = u.x - near.x, u.z - near.z
                        local l = math.sqrt(ax * ax + az * az)
                        if l > 1 then ax, az = ax / l, az / l else ax, az = 0, 0 end
                    end
                    local bx, bz = hx - u.x, hz - u.z
                    local bl = math.sqrt(bx * bx + bz * bz)
                    if bl > 1 then bx, bz = bx / bl, bz / bl else bx, bz = 0, 0 end
                    local vx, vz = 0.6 * ax + 0.4 * bx, 0.6 * az + 0.4 * bz
                    local vl = math.sqrt(vx * vx + vz * vz)
                    if vl < 0.01 then vx, vz, vl = bx, bz, 1 end
                    local tx, tz = Clamp(u.x + vx / vl * c.CREEP_RETREAT_STEP, u.z + vz / vl * c.CREEP_RETREAT_STEP)
                    if near then AddFront(near.x, near.z, frame, c.CREEP_LOSS_FRONT / 3) end
                    if key and key:sub(1, 2) == "cr" then
                        CreepHurt(key, frame, false, u.x, u.z)     -- skip that post for a while and pull the bearing in
                        M.Forget(u.id)
                        stats.creepRetreats = (stats.creepRetreats or 0) + 1
                    end
                    retreat[u.id] = { untilFrame = frame + c.CREEP_RETREAT_HOLD, x = tx, z = tz }
                    rt = retreat[u.id]
                end
                if rt and frame < rt.untilFrame then
                    out[u.id] = { role = "RETREAT", cmd = CMD_MOVE, x = rt.x, z = rt.z, urgent = true, slot = 3001 }
                elseif rt then
                    retreat[u.id] = nil
                end
            end
        end
    end
    return out
end

-- units = { scouts = {ids}, radars = {ids}, hawks = {ids} }; info = { income, hunting, commander = {x, z, frame} }
-- Returns { [unitID] = { role, cmd, x, z, slot, minHold } }.
function M.Step(frame, units, info)
    EnsureSectors()
    local c = M.CFG
    local claims = {}
    if not (sectors and MM and MM.Ready()) then return claims end
    info = info or {}
    Recover(frame)

    -- the pools: type -> list of {id, x, z}
    local pool, posOf = { scout = {}, radar = {}, hawk = {} }, {}
    local counts = { scout = 0, radar = 0, hawk = 0 }
    local sights = {}
    local radarR = 0
    for _, kind in ipairs({ "scout", "radar", "hawk" }) do
        for _, uid in ipairs(units[kind .. "s"] or {}) do
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                pool[kind][#pool[kind] + 1] = { id = uid, x = x, z = z }
                posOf[uid] = { x, z, kind }
                counts[kind] = counts[kind] + 1
                if kind == "scout" then sights[#sights + 1] = SightOf(uid) end
                if kind == "radar" then radarR = math.max(radarR, RadarOf(uid)) end
            end
        end
    end
    -- a unit that left the pool lets go of its job
    for uid in pairs(heldBy) do if not posOf[uid] then M.Forget(uid) end end
    local sight = #sights > 0 and Median(sights) or 0
    if sight <= 0 then sight = c.DEFAULT_SIGHT end
    if radarR <= 0 then radarR = 1500 end

    -- creep units that see an enemy back off first (and take no job this pass)
    local retreating = {}
    if c.CREEP then retreating = CreepGuard(frame, pool, sight, posOf) end

    -- groups
    local groups = GroupList(frame)
    MatchGroups(groups)
    for _, g in ipairs(groups) do g.frame, g.watched, g.scoutWatched, g.radarWatched = frame, false, false, false end
    stats.groups = #groups

    -- requests: expire / finish
    for id, r in pairs(requests) do
        local done = frame > r.expires
        if not done and r.untilMode == "seen" and Spring.IsPosInLos and allyID and Spring.IsPosInLos(r.x, 0, r.z, allyID) then
            done = true
            if holder["q" .. id] then stats.served = stats.served + 1 end
        end
        if not done and r.untilMode == "arrive" then
            local u = holder["q" .. id]
            local p = u and posOf[u]
            if p and Dist2(p[1], p[2], r.x, r.z) <= c.ARRIVE ^ 2 then done = true; stats.served = stats.served + 1 end
        end
        if done then M.CancelRequest(id) end
    end

    -- the sacrifice scheduler: one run per period at the best group nobody has seen lately
    for i = #repeats, 1, -1 do
        local rp = repeats[i]
        if frame >= rp.nextFrame then
            local x, z
            if type(rp.target) == "function" then x, z = rp.target() else x, z = rp.target.x, rp.target.z end
            if x then M.SacrificeScout(x, z, { by = "repeat" }) end
            rp.nextFrame = frame + rp.every
        end
    end
    if not info.hunting and frame >= sacNext and counts.scout > 0 then
        local pick
        for _, g in ipairs(groups) do
            if g.value >= c.SACRIFICE_MIN_VALUE and frame - g.lastSeen >= c.SACRIFICE_STALE then pick = g; break end
        end
        if pick then
            M.SacrificeScout(pick.x, pick.z, { by = "groups" })
            sacNext = frame + c.SACRIFICE_PERIOD
        else
            sacNext = frame + 150
        end
    end

    -- jobs, best first
    local jobs = {}
    local reqIds = {}
    for id in pairs(requests) do reqIds[#reqIds + 1] = id end
    table.sort(reqIds, function(a, b) if requests[a].rank ~= requests[b].rank then return requests[a].rank < requests[b].rank end return a < b end)
    for _, id in ipairs(reqIds) do
        local r = requests[id]
        local accepts = r.kind == "hawk" and { "hawk" } or r.kind == "any" and { "scout", "hawk", "radar" } or { "scout" }
        Job(jobs, "q" .. id, r.rank, accepts, r.x, r.z, r.kind == "hawk" and "SCOUT_CALL" or "SCOUT",
            { exact = true, rid = id, noHold = true })
    end

    local nWatchScout, nWatchRadar = 0, 0
    local commander = info.commander
    if not info.hunting then
        -- group watch
        local watched = 0
        for _, g in ipairs(groups) do
            if watched >= c.WATCH_MAX then break end
            if g.value >= c.WATCH_MIN_VALUE and not g.air and frame - g.lastSeen <= c.WATCH_FRESH then
                local d = g.range + c.WATCH_MARGIN
                local gotOne = false
                if counts.scout > 0 and d <= sight + c.WATCH_SIGHT_SLACK then
                    local x, z = Standoff(g, d)
                    Job(jobs, "ws" .. g.id, RANK_WATCH, { "scout" }, x, z, "SCOUT", { gid = g.id })
                    nWatchScout = nWatchScout + 1
                    g.scoutWatched = true
                    gotOne = true
                end
                local dr = math.max(g.range + c.WATCH_RADAR_MARGIN, 600)
                if (counts.radar > 0 or counts.hawk > 0) and dr <= radarR - 150 then
                    local x, z = Standoff(g, dr)
                    Job(jobs, "wr" .. g.id, RANK_WATCH, { "radar", "hawk" }, x, z, "RADAR", { gid = g.id, airSafe = true })
                    nWatchRadar = nWatchRadar + 1
                    g.radarWatched = true
                    gotOne = true
                end
                if gotOne then watched = watched + 1; g.watched = true end
            end
        end
        -- perimeter
        local sp = math.max(c.MIN_SPACING, math.min(c.MAX_SPACING, c.SIGHT_FACTOR * sight))
        local posts = RingPosts(c.PERIM_MARGIN, sp, c.PERIM_MAX)
        for i, p in ipairs(posts) do Job(jobs, "ps" .. i, RANK_PERIM, { "scout" }, p.x, p.z, "SCOUT") end
        stats.posts = #posts
        local rposts = RingPosts(c.PERIM_MARGIN + c.PERIM_RADAR_EXTRA, math.max(c.MIN_SPACING, 1.5 * radarR), c.PERIM_RADAR_MAX)
        for i, p in ipairs(rposts) do Job(jobs, "pr" .. i, RANK_PERIM, { "radar", "hawk" }, p.x, p.z, "RADAR", { airSafe = true }) end
        -- creep: radar units grow the net on the wide radar grid, scouts on the fine grid (skipping what a held radar post covers);
        -- both take posts ADJACENT to the creep, toward the enemy, never on or behind a front point; only as many units as the income
        -- allows are asked for
        if c.CREEP then
            local inc = info.income or 0
            local fronts = FrontPoints(frame, groups)
            local probe = pool.scout[1] and Spring.GetUnitDefID(pool.scout[1].id) or nil
            local rprobe = pool.radar[1] and Spring.GetUnitDefID(pool.radar[1].id) or nil
            local rsight = pool.radar[1] and SightOf(pool.radar[1].id) or 0
            if rsight <= 0 then rsight = c.CREEP_RADAR_SIGHT end
            local rp, rFront, rHeld = CreepPlan("radar", frame, radarR, posts, groups, rprobe, nil, rsight, posOf, fronts)
            for _, p in ipairs(rp) do Job(jobs, p.key, RANK_CREEP, { "radar" }, p.x, p.z, "RADAR") end
            local cover = { list = {}, r = radarR * c.CREEP_RADAR_COVER }
            for _, p in ipairs(creepSet.radar and creepSet.radar.posts or {}) do
                if p.ok and p.occ and holder[p.key] then cover.list[#cover.list + 1] = p end
            end
            local cp, sFront, sHeld = CreepPlan("scout", frame, sight, posts, groups, probe, cover, sight, posOf, fronts)
            for _, p in ipairs(cp) do Job(jobs, p.key, RANK_CREEP, { "scout" }, p.x, p.z, "SCOUT") end
            local gate = math.max(0, math.min(c.CREEP_MAX, math.floor((inc - c.CREEP_START_INC) / c.CREEP_INC_PER) + 1))
            want.nCreep = math.min(sHeld + sFront, gate)
            local rgate = math.max(0, math.min(c.CREEP_RADAR_MAX, math.floor((inc - c.CREEP_RADAR_START_INC) / c.CREEP_RADAR_INC_PER) + 1))
            want.nCreepRadar = math.min(rHeld + rFront, rgate)
            stats.creepPosts, stats.creepRadarPosts = sFront, rFront
            stats.fronts = #fronts
        end
        stats.watchers = nWatchScout + nWatchRadar
        want.nWatchScout, want.nPostScout, want.nPostRadar, want.nWatchRadar = nWatchScout, #posts, #rposts, nWatchRadar
    end

    -- unit eligibility for a job (a plane does not park under remembered anti-air)
    local function Eligible(kind, job)
        if kind == "hawk" and job.airSafe and EI and EI.ThreatAt(frame, job.x, job.z, "air") > 0 then return false end
        return true
    end

    -- 1) holders keep their jobs
    local used = {}
    for uid in pairs(retreating) do used[uid] = true end
    local jobByKey = {}
    for _, j in ipairs(jobs) do jobByKey[j.key] = j end
    for key, uid in pairs(holder) do
        local j = jobByKey[key]
        local p = posOf[uid]
        local ok = false
        if j and p and not used[uid] then
            for _, k in ipairs(j.accepts) do if k == p[3] then ok = Eligible(k, j) end end
        end
        if ok then used[uid] = true else holder[key] = nil; if heldBy[uid] == key then heldBy[uid] = nil end end
    end
    -- 2) open jobs, best first, take the nearest free unit of an accepted type (the job's own order of preference)
    local function Nearest(kind, x, z, job)
        local best, bestD
        for _, u in ipairs(pool[kind]) do
            if not used[u.id] and Eligible(kind, job) then
                local d = Dist2(u.x, u.z, x, z)
                if not bestD or d < bestD then best, bestD = u.id, d end
            end
        end
        return best
    end
    for _, j in ipairs(jobs) do
        if not holder[j.key] then
            local pick
            for _, kind in ipairs(j.accepts) do
                pick = Nearest(kind, j.x, j.z, j)
                if pick then break end
            end
            -- a request or a run may take a unit off a lower job
            if not pick and j.rank <= RANK_SACRIFICE then
                local bestD
                for key, uid in pairs(holder) do
                    local other = jobByKey[key]
                    if other and other.rank > j.rank then
                        local p = posOf[uid]
                        for _, kind in ipairs(j.accepts) do
                            if p and p[3] == kind and Eligible(kind, j) then
                                local d = Dist2(p[1], p[2], j.x, j.z)
                                if not bestD or d < bestD then pick, bestD = uid, d end
                            end
                        end
                    end
                end
                if pick then
                    local from = heldBy[pick]
                    if from then holder[from] = nil end
                    used[pick] = nil
                end
            end
            if pick then holder[j.key] = pick; heldBy[pick] = j.key; used[pick] = true end
        end
    end

    for uid, spec in pairs(retreating) do claims[uid] = spec end

    -- claims for held jobs
    local slotN = 0
    for _, j in ipairs(jobs) do
        local uid = holder[j.key]
        if uid then
            slotN = slotN + 1
            claims[uid] = { role = j.role, cmd = CMD_MOVE, x = j.x, z = j.z, slot = 3000 + j.rank * 100 + slotN,
                            minHold = (not j.noHold) and c.HOLD or nil }
        end
    end

    -- 3) sweep: scouts with nothing else keep stale sectors fresh
    local counts2 = StructureCounts()
    local cmx, cmz
    if info.hunting and commander then cmx, cmz = commander.x, commander.z end
    local taken = {}
    for uid, t in pairs(sweepOf) do
        local s = sectors[t.key]
        if not posOf[uid] or used[uid] or not s or (s.lastScouted > 0 and frame - s.lastScouted < c.SWEEP_FRESH)
           or frame - t.since > c.SWEEP_TIMEOUT then
            sweepOf[uid] = nil
        else
            taken[t.key] = true
        end
    end
    for _, u in ipairs(pool.scout) do
        if not used[u.id] then
            local t = sweepOf[u.id]
            if not t then
                local bestKey, bestScore = nil, 0
                for key, s in pairs(sectors) do
                    if not taken[key] then
                        local sc = SweepScore(frame, s, key, counts2, info.hunting, cmx, cmz, u.x, u.z)
                        if sc and sc > bestScore then bestKey, bestScore = key, sc end
                    end
                end
                if bestKey then t = { key = bestKey, since = frame }; sweepOf[u.id] = t; taken[bestKey] = true end
            end
            if t then
                local s = sectors[t.key]
                claims[u.id] = { role = "SCOUT", cmd = CMD_MOVE, x = s.x, z = s.z }
            end
        end
    end

    -- how many units the labs should keep
    local inc = info.income or 0
    if info.hunting then
        want.scouts, want.radars = c.HUNT_SCOUTS, 0
    else
        local gate = math.max(0, math.min(c.MAX_SCOUTS, math.floor((inc - c.START_INC) / c.INC_PER) + 1))
        local nReq = 0
        for _, r in pairs(requests) do if r.kind == "scout" or r.kind == "any" then nReq = nReq + 1 end end
        local demand = nWatchScout + (#groups > 0 and 1 or 0) + (stats.posts or 0) + nReq
        want.scouts = math.max(c.BASE_SCOUTS, math.min(demand, c.BASE_SCOUTS + gate))
        if c.CREEP and want.nCreep then want.scouts = want.scouts + want.nCreep end
        local rgate = math.max(0, math.min(c.RADAR_MAX, math.floor((inc - c.RADAR_START_INC) / c.RADAR_INC_PER) + 1))
        want.radars = math.min(rgate, nWatchRadar + (want.nPostRadar or 0))
        if c.CREEP and want.nCreepRadar then want.radars = want.radars + want.nCreepRadar end
    end
    lastPicture = nil
    return claims
end

return M
