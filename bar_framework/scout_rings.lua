-- bar_framework/scout_rings.lua   (STANCE_BOT: replaces the depth grid behind the contact line)
-- Vision rings around our own territory, pushed outward as far as scouts survive.
--
-- WHY.  The map is dark: a base only sees what its own units and radars cover, so everything that
-- walks toward it is a surprise unless something is already out there.  Warning time is how far
-- from the base the first sighting happens, from EVERY direction, not just along the lane the army
-- stands on.  So scouts stand on rings around the whole footprint of our buildings (mex grids,
-- labs, wind...) and the rings are pushed outward until they start dying.
--
-- SHAPE.  The footprint is the support function of our structures: h(b) = the farthest any of our
-- structures reaches in bearing b (36 bins of 10 deg, measured from their centroid).  The outer
-- ring sits at h(b) + MARGIN + push(b); inner rings step in every RING_STEP down to h(b) + MARGIN.
-- Posts on a ring are spaced by what a scout can see (SIGHT_FACTOR x its sight radius), clamped to
-- the map, de-duplicated (a base on a map edge gets half rings), and kept out of the enemy base.
--
-- PUSH.  push(b) grows PUSH_STEP every PUSH_PERIOD frames while the bin is quiet.  A scout lost (or
-- hurt, or an armed enemy seen) at radius r in bin b sets a CAP of r - BACKOFF on that bin and its
-- neighbours; the ring never goes past the cap, and the cap creeps back out at RECOVER elmos per
-- second, so the ring settles just inside wherever the enemy actually is, and keeps testing it.
-- A ring that has to stand inside an enemy presence also retreats as the enemy advances: the
-- warning is the retreat itself.
--
-- RADAR UNITS (T2 lab) take posts on the second ring from the outside and are spaced by their
-- radar radius: they add the long view over the scouts' short one.
--
-- This module issues no orders.  Plan() returns {[unitID] = {x, z, ring}}; the caller claims them.

local M = {}

M.CFG = {
    BINS         = 36,
    MARGIN       = 450,     -- innermost ring stands this far outside our outermost structure
    RING_STEP    = 800,     -- elmos between rings
    MAX_RINGS    = 4,
    PUSH_MAX     = 5000,    -- never more than this beyond the footprint
    PUSH_STEP    = 200,     -- outward creep per PUSH_PERIOD while quiet
    PUSH_PERIOD  = 240,     -- frames (8 s)
    QUIET        = 900,     -- frames after a loss/hurt/enemy before a bin may push again
    BACKOFF      = 700,     -- the cap sits this far inside where a scout was lost
    ENEMY_STANDOFF = 1100,  -- ...and this far inside an armed enemy we can see
    RECOVER      = 15,      -- elmos per second a loss cap creeps back out (3000 elmos in ~3 min)
    ENEMY_TTL    = 300,     -- frames a contact counts as present
    SIGHT_FACTOR = 1.7,     -- post spacing = this x sight radius (sight circles overlap a little)
    MIN_SPACING  = 500,
    MAX_SPACING  = 1300,
    DEFAULT_SIGHT = 400,
    FOE_KEEPOUT  = 2600,    -- no post this close to the enemy's base
    MAP_MARGIN   = 150,
    FACING_BIAS  = 0.5,     -- posts facing the enemy fill first (0 = no preference)
    RADAR_RING   = 2,       -- radar units stand on this ring (counted from the outside; 1 if only one ring)
}

-- ── State ─────────────────────────────────────────────────────────────────────

local MM, UQ
local cx, cz = nil, nil          -- centre of our structures
local hull = {}                  -- [bin] = support radius of our structures in that bearing
local push, capR, lastBad, enemyCap = {}, {}, {}, {}
local lastPush = 0
local lastRecover = 0
local nStruct = 0
local posts, ringCount = {}, 0   -- last plan's posts (for logs and tests)
local held = {}                  -- [unitID] = {x, z}: the post a unit holds, so a plan change does not shuffle everyone

function M.Init(opts)
    MM, UQ = opts.MM, opts.UQ
    local n = M.CFG.BINS
    for b = 1, n do hull[b], push[b], capR[b], lastBad[b], enemyCap[b] = 0, 0, math.huge, -1e9, math.huge end
    cx, cz, nStruct, held = nil, nil, 0, {}
    posts, ringCount = {}, 0
end

local function BinOf(x, z)
    local a = math.atan2(z - cz, x - cx)
    local n = M.CFG.BINS
    local b = math.floor((a + math.pi) / (2 * math.pi) * n) + 1
    if b > n then b = n end
    if b < 1 then b = 1 end
    return b
end

local function BinAngle(b)    -- the bearing at the centre of a bin
    return -math.pi + (b - 0.5) / M.CFG.BINS * 2 * math.pi
end

local function Wrap(b)
    local n = M.CFG.BINS
    return (b - 1) % n + 1
end

-- ── Footprint ─────────────────────────────────────────────────────────────────

-- pts = flat array {x1, z1, x2, z2, ...} of our structures.
function M.SetStructures(pts)
    local n = math.floor(#pts / 2)
    nStruct = n
    if n == 0 then return end
    local sx, sz = 0, 0
    for i = 1, n do sx, sz = sx + pts[2 * i - 1], sz + pts[2 * i] end
    cx, cz = sx / n, sz / n
    local bins = M.CFG.BINS
    local ux, uz = {}, {}
    for b = 1, bins do
        local a = BinAngle(b)
        ux[b], uz[b] = math.cos(a), math.sin(a)
        hull[b] = 0
    end
    for i = 1, n do
        local dx, dz = pts[2 * i - 1] - cx, pts[2 * i] - cz
        for b = 1, bins do
            local h = dx * ux[b] + dz * uz[b]
            if h > hull[b] then hull[b] = h end
        end
    end
end

function M.Centre() return cx, cz end
function M.Hull(b) return hull[b] end

-- Outer ring radius in bin b.
local function Outer(b)
    local floor = hull[b] + M.CFG.MARGIN
    local want = floor + push[b]
    local r = math.min(want, capR[b], enemyCap[b])
    return math.max(floor, r)
end
function M.OuterRadius(b) return Outer(b) end
function M.Push(b) return push[b] end
function M.Cap(b) return capR[b] end

-- ── Danger: losses, damage and enemies ───────────────────────────────────────

local function Cap(b, r, frame, wide)
    for k = -wide, wide do
        local bb = Wrap(b + k)
        local c = r + math.abs(k) * 250
        if c < capR[bb] then capR[bb] = c end
        lastBad[bb] = frame
        -- restart the push from the cap, not from wherever it had grown to
        local floor = hull[bb] + M.CFG.MARGIN
        if push[bb] > capR[bb] - floor then push[bb] = math.max(0, capR[bb] - floor) end
    end
end

-- A scout died (soft = it was only hurt) at (x, z).
function M.OnLost(x, z, frame, soft)
    if not cx then return end
    local r = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
    Cap(BinOf(x, z), r - M.CFG.BACKOFF * (soft and 0.5 or 1), frame, soft and 1 or 2)
end

-- enemies = array of {x, z}: armed things we can currently see (or saw within ENEMY_TTL).
-- An enemy only pulls the ring in WHILE it is there (recomputed on every call, nothing ratchets): a lone Rover seen once
-- used to cap its bearing for ~10 minutes.  Losses are what set the lasting caps.
function M.ObserveEnemies(frame, enemies)
    if not cx then return end
    for b = 1, M.CFG.BINS do enemyCap[b] = math.huge end
    for i = 1, #enemies do
        local e = enemies[i]
        local r = math.sqrt((e.x - cx) ^ 2 + (e.z - cz) ^ 2)
        local b = BinOf(e.x, e.z)
        for k = -1, 1 do
            local bb = Wrap(b + k)
            local c = r - M.CFG.ENEMY_STANDOFF + math.abs(k) * 250
            if c < enemyCap[bb] then enemyCap[bb] = c end
        end
    end
end

-- Advance the pushes and let the caps recover.  Call every second or so.
function M.Step(frame)
    if not cx then return end
    local c = M.CFG
    if frame - lastRecover >= 30 then
        local gain = c.RECOVER * (frame - lastRecover) / 30
        lastRecover = frame
        for b = 1, c.BINS do
            if capR[b] < math.huge then
                capR[b] = capR[b] + gain
                if capR[b] > hull[b] + c.MARGIN + c.PUSH_MAX then capR[b] = math.huge end
            end
        end
    end
    if frame - lastPush >= c.PUSH_PERIOD then
        lastPush = frame
        for b = 1, c.BINS do
            local floor = hull[b] + c.MARGIN
            if frame - lastBad[b] > c.QUIET and push[b] < c.PUSH_MAX and floor + push[b] < capR[b] then
                push[b] = math.min(c.PUSH_MAX, push[b] + c.PUSH_STEP)
            end
        end
    end
end

-- ── Posts ─────────────────────────────────────────────────────────────────────

-- Bit-reversal-ish order: any prefix of 1..n is spread around the ring.
local function SpreadOrder(n)
    local order, used = {}, {}
    local step = n
    while #order < n do
        for i = 0, n - 1, math.max(1, math.floor(step)) do
            if not used[i] then used[i] = true; order[#order + 1] = i end
        end
        if step <= 1 then break end
        step = step / 2
    end
    for i = 0, n - 1 do if not used[i] then order[#order + 1] = i end end
    return order
end

local function RadiusAt(ang, ring, rings)
    -- the outer radius at this bearing, interpolated between bin centres
    local n = M.CFG.BINS
    local f = (ang + math.pi) / (2 * math.pi) * n + 0.5
    local b0 = math.floor(f)
    local t = f - b0
    local ra, rb = Outer(Wrap(b0)), Outer(Wrap(b0 + 1))
    local out = ra + (rb - ra) * t
    local floor = math.max(hull[Wrap(b0)], hull[Wrap(b0 + 1)]) + M.CFG.MARGIN
    -- ring 1 = outermost; ring k stands (k-1) steps inside it, never inside the floor
    return math.max(floor, out - (ring - 1) * M.CFG.RING_STEP)
end

-- Build the post list.  sight = sight radius of the scouts (elmos).  Returns posts in fill order:
-- {x, z, ring, ang}.  Posts toward the enemy come first; each ring fills in proportion to its size.
function M.BuildPosts(sight)
    local c = M.CFG
    posts, ringCount = {}, 0
    if not cx then return posts end
    sight = sight or c.DEFAULT_SIGHT
    local spacing = math.max(c.MIN_SPACING, math.min(c.MAX_SPACING, sight * c.SIGHT_FACTOR))
    local mx, mz = MM.MapSize()
    local foeX, foeZ = MM.Foe()
    local axA = nil
    if foeX then axA = math.atan2(foeZ - cz, foeX - cx) end

    -- how many rings: as many steps as the push allows, 1..MAX_RINGS
    local maxOuter, minFloor = 0, math.huge
    for b = 1, c.BINS do
        maxOuter = math.max(maxOuter, Outer(b) - hull[b] - c.MARGIN)
        minFloor = math.min(minFloor, hull[b] + c.MARGIN)
    end
    local rings = math.max(1, math.min(c.MAX_RINGS, 1 + math.floor(maxOuter / c.RING_STEP)))
    ringCount = rings

    local all, placed = {}, {}
    for ring = 1, rings do
        -- walk the circle, stepping by spacing / radius, stagger odd rings
        local list = {}
        local ang = -math.pi + (ring % 2 == 0 and 0.5 or 0) * 0.15
        local guard = 0
        while ang < math.pi - 0.0001 and guard < 400 do
            guard = guard + 1
            local r = RadiusAt(ang, ring, rings)
            local x, z = cx + math.cos(ang) * r, cz + math.sin(ang) * r
            local px, pz = MM.Clamp(x, z, c.MAP_MARGIN)
            local keep = true
            -- inside the enemy base: not a post
            if foeX and (px - foeX) ^ 2 + (pz - foeZ) ^ 2 < c.FOE_KEEPOUT ^ 2 then keep = false end
            -- on top of an earlier post (map edge clamp, or an inner ring squeezed onto the floor): one is enough
            if keep then
                for j = 1, #placed do
                    if (placed[j].x - px) ^ 2 + (placed[j].z - pz) ^ 2 < (spacing * 0.7) ^ 2 then keep = false; break end
                end
            end
            if keep then
                local p = { x = px, z = pz, ring = ring, ang = ang }
                list[#list + 1] = p
                placed[#placed + 1] = p
            end
            ang = ang + spacing / math.max(spacing, r)
        end
        -- fill order inside the ring: spread, so a partial ring still watches every side
        -- (each ring's order is rotated by a golden-ratio fraction, so the first post of every ring is at a
        -- different bearing instead of all four stacking on the same one)
        local order = SpreadOrder(#list)
        local rot = math.floor(#list * 0.382 * (ring - 1))
        for rank, idx in ipairs(order) do
            local p = list[(idx + rot) % #list + 1]
            local facing = 0
            if axA then facing = (1 + math.cos(p.ang - axA)) / 2 end     -- 1 = toward the enemy
            -- sort key: fraction of the ring filled, pulled earlier for posts facing the enemy
            -- OUTER RING FIRST: the ring number dominates the key.  (Filling every ring in proportion left a few scouts
            -- spread over four rings, most of them near the base; warning time is the outer ring, so a few scouts are
            -- spread evenly round it and inner rings only get the overflow.)
            p.key = (ring - 1) * 10 + (rank - 0.5) / #list * (1 - c.FACING_BIAS * facing)
            all[#all + 1] = p
        end
    end
    table.sort(all, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        if a.ring ~= b.ring then return a.ring < b.ring end
        return a.ang < b.ang
    end)
    posts = all
    return posts
end

function M.Posts() return posts end
function M.RingCount() return ringCount end
function M.PostCount() return #posts end

-- ── Assignment ────────────────────────────────────────────────────────────────

local lastBuild, lastSight = -1e9, nil
local BuildPostsCached

local function Pair(units, spots, out, tag, maxKeep)
    -- stable first: a unit already holding a spot that still exists (within maxKeep) keeps it
    local taken, assigned = {}, {}
    for _, u in ipairs(units) do
        local h = held[u.id]
        if h then
            local bi, bd = nil, maxKeep * maxKeep
            for i, s in ipairs(spots) do
                if not taken[i] then
                    local d = (s.x - h.x) ^ 2 + (s.z - h.z) ^ 2
                    if d < bd then bi, bd = i, d end
                end
            end
            if bi then taken[bi] = true; assigned[u.id] = bi end
        end
    end
    -- the rest take the nearest free spot
    for _, u in ipairs(units) do
        if not assigned[u.id] then
            local bi, bd = nil, math.huge
            for i, s in ipairs(spots) do
                if not taken[i] then
                    local d = (s.x - u.x) ^ 2 + (s.z - u.z) ^ 2
                    if d < bd then bi, bd = i, d end
                end
            end
            if bi then taken[bi] = true; assigned[u.id] = bi end
        end
    end
    for _, u in ipairs(units) do
        local i = assigned[u.id]
        if i then
            local s = spots[i]
            out[u.id] = { x = s.x, z = s.z, ring = s.ring, kind = tag }
            held[u.id] = { x = s.x, z = s.z }
        else
            held[u.id] = nil
        end
    end
end

-- scouts / radars: arrays of {id, x, z}.  Returns {[unitID] = {x, z, ring, kind}}.
-- Radar units take every k-th post of one ring (k from their radar radius); scouts take the next
-- posts in fill order, so the rings fill evenly as scouts arrive.
function M.Plan(frame, scouts, radars, scoutSight, radarRadius)
    local out = {}
    if not cx then return out end
    local c = M.CFG
    BuildPostsCached(frame, scoutSight)
    local ps = posts
    local radarSpots, used = {}, {}
    if #radars > 0 and #ps > 0 then
        local want = math.min(c.RADAR_RING, ringCount)
        local ringPosts = {}
        for i, p in ipairs(ps) do if p.ring == want then ringPosts[#ringPosts + 1] = i end end
        table.sort(ringPosts, function(a, b) return ps[a].ang < ps[b].ang end)
        -- space them by radar radius: pick evenly through the ring by angle
        local n = math.min(#radars, #ringPosts)
        for k = 1, n do
            local i = ringPosts[math.floor((k - 0.5) / n * #ringPosts) + 1]
            if i and not used[i] then used[i] = true; radarSpots[#radarSpots + 1] = ps[i] end
        end
    end
    local scoutSpots = {}
    for i, p in ipairs(ps) do
        if not used[i] then scoutSpots[#scoutSpots + 1] = p end
        if #scoutSpots >= #scouts then break end
    end
    -- scouts: the first #scouts spots in fill order, matched to scouts by nearness
    Pair(scouts, scoutSpots, out, "scout", 450)
    Pair(radars, radarSpots, out, "radar", 600)
    return out
end

BuildPostsCached = function(frame, sight)
    if frame - lastBuild >= 120 or sight ~= lastSight or #posts == 0 then
        lastBuild, lastSight = frame, sight
        M.BuildPosts(sight)
    end
end

function M.Forget(uid) held[uid] = nil end

return M
