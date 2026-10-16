-- bar_framework/perimeter_guard.lua   (DRAGON_ECO, user 2026-10-14)
-- The defensive army stands on a LINE round the base and answers whatever comes inside it; it never attacks.  (The Dragons are not
-- here: they carry the dragon_raid / dragon_defend behaviours, assigned by the stance's `extras`; pg.clusters, the intruder groups
-- inside the ring, is what dragon_defend reads.)  Selected by the stance plan `army = "perimeter"`.
--
-- RING  C = the metal-weighted centre of our structures.  Along each of BEARINGS directions u from C the post is the far edge of
--       the union of R-circles around every structure: r(u) = max over structures s of t + sqrt(R^2 - d^2) (t = (s - C).u,
--       d = its distance from the ray; only structures with d <= R count).  Posts off the map are dropped (a corner base keeps
--       only the arc facing the map), and a post never goes past MAX_FRAC of the way to the enemy base along that direction.
--       R starts at R_MIN (700) and is pushed out in R_STEP steps while the defenders would stand denser than DENSITY_MAX per
--       elmo of line (user: "pull the ring to 700 and push it further when there is high unit density").
-- LINE  (user, from a screenshot: "you don't want large groups, you just want to put units on a line") the posts, joined in
--       bearing order, are a polyline (one arc per run of on-map posts).  N defenders get N slots evenly spaced along its whole
--       length; units are sorted by where they stand along the line and take the slots in that order, so nobody crosses the
--       base to reach a slot.  AA units (Lasher, Manticore) stand AA_BACK inside the line.
-- INTRUSION  armed enemy ground contacts within R of any of our structures are clustered (CLUSTER_R); the nearest defenders, until
--       RESPOND_MULT x the cluster's value is sent (at least RESPOND_MIN), FIGHT to it; they go back to the line RETURN_AFTER after
--       it is gone.  A cluster further than R + LEASH from every structure is never chased.
--
-- USAGE (unit_controller)
--   local PG = VFS.Include("LuaUI/Widgets/bar_framework/perimeter_guard.lua")
--   local pg = PG.New{ ARMY = ARMY, teamID =, mapX =, mapZ =, enemyBase = function() return x, z end,
--                      contacts = function() return TM.Contacts() end }
--   PG.Add(pg, uid, defID)   PG.Update(pg, frame)   (every 30 frames, after ARMY.Sweep)   pg.clusters = intruder groups
-- Pure helpers for tests: PG.Ring, PG.RingLength, PG.PickRadius, PG.Arcs, PG.LineSlots, PG.LineParam, PG.Clusters.
-- Log rows "[PG]".

local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
local M = {}

M.CFG = {
    R_MIN        = 700,
    R_MAX        = 3000,
    R_STEP       = 200,
    DENSITY_MAX  = 1 / 40,  -- defenders per elmo of line (one per 40 elmos) before the ring is pushed out
    BEARINGS     = 24,
    EDGE         = 150,     -- a post closer than this to the map edge counts as off the map
    MAX_FRAC     = 0.45,    -- a post goes at most this share of the way to the enemy base (along its bearing)
    REPLAN       = 90,      -- frames between line re-plans
    AA_BACK      = 200,
    LIVE_TTL     = 150,     -- frames a contact counts as live for the intrusion check
    CLUSTER_R    = 800,
    RESPOND_MULT = 1.5,
    RESPOND_MIN  = 3,
    RETURN_AFTER = 20 * 30,
    LEASH        = 800,
    LOG_EVERY    = 1800,
}

local AA_UNITS = { cormist = true, coraak = true }

local function Dist2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end
local function Clock(frame) return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

-- ── pure geometry ────────────────────────────────────────────────────────────

-- structs = { {x, z, w}, ... } -> centre, posts = { {k, ang, x, z, r}, ... } (k = bearing index 1..n).  ex/ez: enemy base (or nil).
function M.Ring(structs, R, n, mapX, mapZ, ex, ez, maxFrac, edge)
    if #structs == 0 then return nil, {} end
    local sx, sz, sw = 0, 0, 0
    for _, s in ipairs(structs) do
        local w = s.w or 1
        sx, sz, sw = sx + s.x * w, sz + s.z * w, sw + w
    end
    local cx, cz = sx / sw, sz / sw
    local eAng, eDist
    if ex then eAng, eDist = math.atan2(ez - cz, ex - cx), math.sqrt(Dist2(ex, ez, cx, cz)) end
    edge = edge or 0
    local posts = {}
    for k = 1, n do
        local a = 2 * math.pi * (k - 1) / n
        local ux, uz = math.cos(a), math.sin(a)
        local best
        for _, s in ipairs(structs) do
            local dx, dz = s.x - cx, s.z - cz
            local t = dx * ux + dz * uz
            local d = math.abs(dx * uz - dz * ux)
            if d <= R then
                local r = t + math.sqrt(R * R - d * d)
                if not best or r > best then best = r end
            end
        end
        if best and best > 0 then
            if eAng and maxFrac then
                local c = math.cos(a - eAng)
                if c > 0.05 then best = math.min(best, maxFrac * eDist / c) end
            end
            local x, z = cx + ux * best, cz + uz * best
            if x >= edge and z >= edge and x <= mapX - edge and z <= mapZ - edge then
                posts[#posts + 1] = { k = k, ang = a, x = x, z = z, r = best }
            end
        end
    end
    return { x = cx, z = cz, eAng = eAng }, posts
end

-- Length of the ring through the posts: the sum of the gaps between posts on neighbouring bearings (a gap the map cut is not
-- counted, so a corner base's ring is its on-map arc).
function M.RingLength(posts, n)
    local byK = {}
    for _, p in ipairs(posts) do byK[p.k] = p end
    local L = 0
    for k = 1, n do
        local a, b = byK[k], byK[k % n + 1]
        if a and b then L = L + math.sqrt(Dist2(a.x, a.z, b.x, b.z)) end
    end
    return L
end

-- The ring radius: R_MIN, pushed out in R_STEP steps while n defenders would stand denser than DENSITY_MAX per elmo of ring.
-- Returns R, centre, posts.
function M.PickRadius(structs, nUnits, K, mapX, mapZ, ex, ez)
    local R = K.R_MIN
    local centre, posts = M.Ring(structs, R, K.BEARINGS, mapX, mapZ, ex, ez, K.MAX_FRAC, K.EDGE)
    while R < K.R_MAX and nUnits > K.DENSITY_MAX * M.RingLength(posts, K.BEARINGS) do
        R = math.min(K.R_MAX, R + K.R_STEP)
        centre, posts = M.Ring(structs, R, K.BEARINGS, mapX, mapZ, ex, ez, K.MAX_FRAC, K.EDGE)
    end
    return R, centre, posts
end

-- The posts joined in bearing order: a list of arcs, each a list of posts (consecutive bearings).  closed = the full circle.
function M.Arcs(posts, n)
    local byK = {}
    for _, p in ipairs(posts) do byK[p.k] = p end
    local start
    for k = 1, n do
        if byK[k] and not byK[(k - 2) % n + 1] then start = k; break end
    end
    local arcs = {}
    if not start then
        if not byK[1] then return arcs, false end
        local a = {}
        for k = 1, n do a[#a + 1] = byK[k] end
        a[#a + 1] = byK[1]
        return { a }, true
    end
    local cur
    for i = 0, n - 1 do
        local k = (start - 1 + i) % n + 1
        if byK[k] then
            if not cur then cur = {}; arcs[#arcs + 1] = cur end
            cur[#cur + 1] = byK[k]
        else
            cur = nil
        end
    end
    return arcs, false
end

-- Segments of the arcs with their start parameter along the whole line: { {ax, az, bx, bz, len, s0}, ... }, total length.
-- A one-post arc is a zero-length segment (it still holds a slot).
local function Segments(arcs)
    local segs, s = {}, 0
    for _, a in ipairs(arcs) do
        if #a == 1 then
            segs[#segs + 1] = { ax = a[1].x, az = a[1].z, bx = a[1].x, bz = a[1].z, len = 0, s0 = s }
        end
        for i = 1, #a - 1 do
            local len = math.sqrt(Dist2(a[i].x, a[i].z, a[i + 1].x, a[i + 1].z))
            segs[#segs + 1] = { ax = a[i].x, az = a[i].z, bx = a[i + 1].x, bz = a[i + 1].z, len = len, s0 = s }
            s = s + len
        end
    end
    return segs, s
end

-- count slots evenly spaced along the line: { {x, z, s}, ... } in line order.
function M.LineSlots(posts, n, count)
    local segs, L = Segments((M.Arcs(posts, n)))
    local out = {}
    if #segs == 0 or count <= 0 then return out, L end
    local j = 1
    for i = 1, count do
        local s = (L > 0) and (i - 0.5) * L / count or 0
        while j < #segs and segs[j].s0 + segs[j].len < s do j = j + 1 end
        local g = segs[j]
        local f = g.len > 0 and math.max(0, math.min(1, (s - g.s0) / g.len)) or 0
        out[i] = { x = g.ax + (g.bx - g.ax) * f, z = g.az + (g.bz - g.az) * f, s = s }
    end
    return out, L
end

-- Where a point stands along the line: the parameter of the nearest point on it.
function M.LineParam(segs, x, z)
    local best, bestS
    for _, g in ipairs(segs) do
        local f = 0
        if g.len > 0 then
            f = ((x - g.ax) * (g.bx - g.ax) + (z - g.az) * (g.bz - g.az)) / (g.len * g.len)
            f = math.max(0, math.min(1, f))
        end
        local px, pz = g.ax + (g.bx - g.ax) * f, g.az + (g.bz - g.az) * f
        local d = Dist2(px, pz, x, z)
        if not best or d < best then best, bestS = d, g.s0 + f * g.len end
    end
    return bestS or 0
end
M._Segments = Segments

-- items = { {x, z, v}, ... } -> clusters { {x, z, v, n}, ... } (single link within r), heaviest first
function M.Clusters(items, r)
    local out, r2 = {}, r * r
    for _, it in ipairs(items) do
        local home
        for _, c in ipairs(out) do
            if Dist2(it.x, it.z, c.x, c.z) <= r2 then home = c; break end
        end
        if home then
            local n = home.n + 1
            home.x, home.z = home.x + (it.x - home.x) / n, home.z + (it.z - home.z) / n
            home.v, home.n = home.v + it.v, n
        else
            out[#out + 1] = { x = it.x, z = it.z, v = it.v, n = 1 }
        end
    end
    table.sort(out, function(a, b) return a.v > b.v end)
    return out
end

-- ── runtime ──────────────────────────────────────────────────────────────────

local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function Value(defID) local d = UnitDefs[defID or -1]; return d and (d.metalCost or 0) or 0 end

function M.New(o)
    return { o = o, K = M.CFG, units = {}, slotOf = {}, clusters = {},
             lastPlan = -1e9, posts = {}, centre = nil, intrusions = 0, responding = {} }
end

function M.Add(pg, uid, defID)
    pg.units[uid] = { defID = defID, aa = AA_UNITS[(UnitDefs[defID] or {}).name or ""] == true }
end

local function Structures(pg) return UQ.structures(pg.o.teamID) end      -- shared per frame with every other scan (C5)

local function NearestStructD2(structs, x, z)
    local best
    for _, s in ipairs(structs) do
        local d = Dist2(s.x, s.z, x, z)
        if not best or d < best then best = d end
    end
    return best or 1e18
end

-- the line for the current army, and every defender's slot on it (units sorted by where they stand along the line)
local function Replan(pg, frame)
    local K, o = pg.K, pg.o
    local structs = Structures(pg)
    local ex, ez = nil, nil
    if o.enemyBase then ex, ez = o.enemyBase() end
    local value, ids = 0, {}
    for uid, u in pairs(pg.units) do
        if Alive(uid) then value = value + Value(u.defID); ids[#ids + 1] = uid else pg.units[uid] = nil end
    end
    pg.value = value
    local R, centre, posts = M.PickRadius(structs, #ids, K, o.mapX, o.mapZ, ex, ez)
    pg.R, pg.centre, pg.posts, pg.structs = R, centre, posts, structs
    local slots, L = M.LineSlots(posts, K.BEARINGS, #ids)
    pg.lineLen = L
    pg.slotOf = {}
    if #slots == 0 then return end
    local segs = Segments((M.Arcs(posts, K.BEARINGS)))
    local at = {}
    for _, uid in ipairs(ids) do
        local x, _, z = Spring.GetUnitPosition(uid)
        at[uid] = x and M.LineParam(segs, x, z) or 0
    end
    table.sort(ids, function(a, b) if at[a] ~= at[b] then return at[a] < at[b] end return a < b end)
    for i, uid in ipairs(ids) do pg.slotOf[uid] = slots[i] end
end

-- armed live enemy ground contacts
local function LiveContacts(pg, frame)
    local out = {}
    local contacts = pg.o.contacts and pg.o.contacts() or {}
    for _, c in pairs(contacts) do
        if (c.v or 0) > 0 and not c.air and frame - (c.frame or -1e9) <= pg.K.LIVE_TTL then
            out[#out + 1] = { x = c.x, z = c.z, v = math.max(Value(c.defID), 50) }
        end
    end
    return out
end

-- intruder groups inside the ring: the nearest defenders go, until RESPOND_MULT x the group's value (at least RESPOND_MIN)
local function Respond(pg, frame)
    local K = pg.K
    local structs = pg.structs or {}
    local R = pg.R or K.R_MIN
    local inside = {}
    for _, c in ipairs(LiveContacts(pg, frame)) do
        if NearestStructD2(structs, c.x, c.z) <= R * R then inside[#inside + 1] = c end
    end
    local taken = {}
    local leash = R + K.LEASH
    pg.clusters = {}
    for _, cl in ipairs(M.Clusters(inside, K.CLUSTER_R)) do
        if NearestStructD2(structs, cl.x, cl.z) <= leash * leash then
            pg.clusters[#pg.clusters + 1] = cl
            local cand = {}
            for uid, u in pairs(pg.units) do
                if not taken[uid] then
                    local x, _, z = Spring.GetUnitPosition(uid)
                    if x then cand[#cand + 1] = { uid = uid, d = Dist2(x, z, cl.x, cl.z), v = Value(u.defID) } end
                end
            end
            table.sort(cand, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.uid < b.uid end)
            local sent, n = 0, 0
            for _, c in ipairs(cand) do
                if n >= K.RESPOND_MIN and sent >= K.RESPOND_MULT * cl.v then break end
                taken[c.uid] = true
                local r = pg.responding[c.uid]
                if not r then pg.intrusions = pg.intrusions + 1 end
                pg.responding[c.uid] = { x = cl.x, z = cl.z, last = frame }
                sent, n = sent + c.v, n + 1
            end
            if n > 0 and frame - (pg.lastRespLog or -1e9) >= 150 then
                pg.lastRespLog = frame
                Spring.Echo(string.format("[PG] %s %d defenders -> intruders at (%d, %d), value %.0f (%d units)",
                    Clock(frame), n, cl.x, cl.z, cl.v, cl.n))
            end
        end
    end
    for uid, r in pairs(pg.responding) do
        if not pg.units[uid] or (not taken[uid] and frame - r.last > K.RETURN_AFTER) then pg.responding[uid] = nil end
    end
end

local function OrderLine(pg, frame)
    local K, ARMY, C = pg.K, pg.o.ARMY, pg.centre
    if not ARMY or not C then return end
    for uid, u in pairs(pg.units) do
        local r = pg.responding[uid]
        if r then
            ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "PERIM_RESPOND", cmd = ARMY.CMD_FIGHT, x = r.x, z = r.z }, frame)
        else
            local s = pg.slotOf[uid]
            if s then
                local x, z = s.x, s.z
                if u.aa then
                    local dx, dz = C.x - x, C.z - z
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1 then x, z = x + dx / l * K.AA_BACK, z + dz / l * K.AA_BACK end
                end
                x = math.max(K.EDGE, math.min(pg.o.mapX - K.EDGE, x))
                z = math.max(K.EDGE, math.min(pg.o.mapZ - K.EDGE, z))
                ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, { role = "PERIM", cmd = ARMY.CMD_FIGHT, x = x, z = z }, frame)
            end
        end
    end
end

function M.Update(pg, frame)
    local K = pg.K
    if frame - pg.lastPlan >= K.REPLAN then
        pg.lastPlan = frame
        Replan(pg, frame)
    end
    Respond(pg, frame)
    OrderLine(pg, frame)
    if frame % K.LOG_EVERY == 0 then
        local nU, nR = 0, 0
        for _ in pairs(pg.units) do nU = nU + 1 end
        for _ in pairs(pg.responding) do nR = nR + 1 end
        Spring.Echo(string.format("[PG] %s ring R %d, line %d elmos over %d posts, %d defenders (%.0f per 1000 elmos, %d responding), army value %.0f, intrusions %d",
            Clock(frame), pg.R or 0, pg.lineLen or 0, #pg.posts, nU, 1000 * nU / math.max(1, pg.lineLen or 0), nR,
            pg.value or 0, pg.intrusions))
    end
end

return M
