-- bar_framework/maneuver_defence.lua   (user, 2026-10-16)
-- Maneuver defence.  The army stands in BLOBS on a perimeter round the base, each blob SPACING_S seconds of move speed from the
-- next, so any blob can reach its neighbour's post in that time.  When an enemy group is seen coming (the shadow units
-- (behaviors/shadow.lua) keep the groups in view; this module reads the threat map's contacts, which they feed), it sends about
-- NEED_MULT x the group's value, taken from the units that can get there first, to MEET it -- ahead of it on its way to the
-- structure it heads for (behaviors/intercept.lua's meeting point) -- and not the whole army.  When the group is dead or gone the
-- units go back to their posts.  Interception is always a MOVE to a point in front of the group (never FIGHT: the units do not chase
-- it, they block it and fire as they stand); a released unit MOVEs to its post, and a unit that drifts
-- more than LEASH from its post is pulled back the same way.  Selected by the stance plan `army = "maneuver"`; the plan's
-- `maneuver = { ... }` table overrides M.CFG.
--
-- Slow units (speed < BACKSTOP_SPEED: Pounders) are the backstop: they hold the line with the blobs (just behind their posts) and
-- only fight what reaches them.  They never intercept.
-- SUPPORT_ROLE (2026-10-25, opt-in; unit_runtime turns it on for the plan army "defend"): long-range support (SUPPORT_NAMES, or range >=
-- SUPPORT_MIN_RANGE and slower than SUPPORT_SPEED, minus SCREEN_NAMES) never intercepts either -- a Sheldon used to be sent to stand IN
-- FRONT of raiders.  It posts SUPPORT_BACK behind its blob; when a live group comes within SUPPORT_REACT_R of its post it FIGHTs from
-- SUPPORT_RANGE_FRAC of its own range from the group, on our side, and goes back to the post when the group is gone.
--
-- USAGE (unit_controller), the same shape as perimeter_guard:
--   local MD = VFS.Include("LuaUI/Widgets/bar_framework/maneuver_defence.lua")
--   local md = MD.New{ ARMY = ARMY, teamID =, mapX =, mapZ =, enemyBase = function() return x, z end,
--                      contacts = function() return TM.Contacts() end, cfg = plan.maneuver }
--   MD.Add(md, uid, defID)   MD.Remove(md, uid)   MD.Update(md, frame)   (every 30 frames, after ARMY.Sweep)
-- State for tests / other modules: md.blobs, md.clusters, md.responding[uid] = {state = "out"|"return", cid}, md.homeOf(uid).
-- md.blobs is [ {x, z, n} ] -- the unit controller publishes it as WG.MetalBot.blobs (radar posts are built beside them).
-- Radar dots (contacts without a unit type) count BLIP_VALUE each, so a bot with radar reacts to groups before they are in sight.
-- Pure helper: MD.BlobCount.  Log rows "[MD]".

local PG   = VFS.Include("LuaUI/Widgets/bar_framework/perimeter_guard.lua")
local ICPT = VFS.Include("LuaUI/Widgets/bar_framework/behaviors/intercept.lua")

local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
local M = {}

M.CFG = {
    SPACING_S      = 10,       -- seconds of the slowest mover's speed between neighbouring blobs
    MIN_BLOB       = 4,        -- units per blob at the least: a small army makes fewer, fatter blobs
    BACKSTOP_SPEED = 50,       -- slower units are the backstop (Pounder 40)
    NEED_MULT      = 2.0,      -- send this x the group's value
    WATCH          = 1500,     -- groups within R + WATCH of a structure are intercepted
    CLUSTER_R      = 800,
    LIVE_TTL       = 150,      -- frames a contact counts as live
    TRACK_R        = 700,      -- a group within this of last tick's is the same group
    STILL_SPEED    = 14,       -- elmos/s under which a group counts as stopped
    BLIP_VALUE     = 60,       -- a radar dot (no unit type known) counts as this much: two dots make a group, one does not
    MIN_UNIT_V     = 50,       -- a contact (or radar dot) worth less than this is not counted at all (typed contacts under 80 are dropped first: scouts)
    MIN_THREAT     = 100,      -- a group worth less than this is ignored
    STAY_S         = 30,       -- a group standing still this long OUTSIDE the ring is no raid: its responders go home (and it is ignored until it moves)
    OUT_EXTRA      = 800,      -- a responder further than R + WATCH + this from every structure is released
    CLOSE          = 500,      -- within this of the group the responders stand in front of it (MOVE, not FIGHT)
    GONE_S         = 5,        -- seconds without the group before its responders are released
    LEASH          = 600,      -- a unit this far from its post (and not responding) is pulled back
    HOME_EPS       = 150,      -- back "at post" within this
    BACKSTOP_BACK  = 150,      -- the backstop stands this far behind its blob's post, toward the base
    BLOB_SPREAD    = 45,       -- elmos between units of a blob (golden-angle disc)
    SPREAD         = 110,      -- responders spread across the path by this
    REPLAN         = 90,
    LOG_EVERY      = 1800,
    MAX_GROUP_SPEED    = nil,      -- (unit_runtime "defend": 150) a group faster than this is not chased: the blobs cannot catch it
                                   -- (a 2026-10-25 game sent 30 Tigers at a 266 elmos/s group, again and again: 434 walks back)
    SUPPORT_ROLE       = false,
    SUPPORT_NAMES      = { cormort = true, cormist = true, corban = true, corhrk = true },
    SCREEN_NAMES       = { corsumo = true, corshiva = true, corjugg = true, corlevlr = true },
    SUPPORT_MIN_RANGE  = 700,
    SUPPORT_SPEED      = 60,
    SUPPORT_BACK       = 320,      -- the support posts this far behind its blob (the backstop stands BACKSTOP_BACK behind)
    SUPPORT_REACT_R    = 1600,     -- a live group this close to a support's post: it moves up to fire
    SUPPORT_RANGE_FRAC = 0.85,     -- ...to this share of its range from the group
}

local function Dist2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end
local SupportSpot          -- below (OrderPosts)
local function Clock(frame) return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end
local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function Value(defID) local d = UnitDefs[defID or -1]; return d and (d.metalCost or 0) or 0 end
local GOLDEN = 2.39996

-- ── pure ─────────────────────────────────────────────────────────────────────

-- How many blobs: as many as the line needs for SPACING_S seconds between neighbours (ceil(len / spacing)), but no more than
-- movers / MIN_BLOB (at least one).  Returns blobs, slots needed for the full spacing.
function M.BlobCount(lineLen, minSpeed, nMovers, K)
    if not minSpeed or minSpeed <= 0 or nMovers <= 0 then return 0, 0 end
    local full = math.max(1, math.ceil(lineLen / (K.SPACING_S * minSpeed)))
    return math.min(full, math.max(1, math.floor(nMovers / K.MIN_BLOB))), full
end

local function AngDiff(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then d = 2 * math.pi - d end
    return d
end

-- ── runtime ──────────────────────────────────────────────────────────────────

function M.New(o)
    local K = {}
    for k, v in pairs(M.CFG) do K[k] = v end
    for k, v in pairs(o.cfg or {}) do K[k] = v end
    local PK = {}                                          -- perimeter_guard's ring settings (R_MIN, BEARINGS, ...)
    for k, v in pairs(PG.CFG) do PK[k] = v end
    local md = { o = o, K = K, PK = PK, units = {}, blobs = {}, clusters = {}, responding = {}, prev = {}, nextCid = 1,
                 lastPlan = -1e9, posts = {}, ignore = {}, warned = {}, intercepts = 0, released = 0, returned = 0, sig = "" }
    md.homeOf = function(uid) local u = md.units[uid]; return u and u.home end
    return md
end

-- Long-range support (SUPPORT_ROLE): its weapon range, or nil when the unit is not support.
local function SupportRange(K, d)
    if not K.SUPPORT_ROLE or not d or not d.name or K.SCREEN_NAMES[d.name] then return nil end
    local range = d.maxWeaponRange or 0
    if K.SUPPORT_NAMES[d.name] or (range >= K.SUPPORT_MIN_RANGE and (d.speed or 0) < K.SUPPORT_SPEED) then return math.max(range, 300) end
    return nil
end
M.SupportRange = SupportRange

function M.Add(md, uid, defID)
    local d = UnitDefs[defID] or {}
    local sr = SupportRange(md.K, d)
    md.units[uid] = { defID = defID, speed = d.speed or 0, v = Value(defID), back = sr ~= nil or (d.speed or 0) < md.K.BACKSTOP_SPEED,
                      support = sr }
end

function M.Remove(md, uid) md.units[uid], md.responding[uid] = nil, nil end

local function Structures(md) return UQ.structures(md.o.teamID) end      -- shared per frame with every other scan (C5)

local function NearestStructD2(structs, x, z)
    local best
    for _, s in ipairs(structs) do
        local d = Dist2(s.x, s.z, x, z)
        if not best or d < best then best = d end
    end
    return best or 1e18
end

-- the perimeter, its blobs, and every unit's post
local function Replan(md, frame)
    local K, o = md.K, md.o
    local structs = Structures(md)
    local ex, ez
    if o.enemyBase then ex, ez = o.enemyBase() end
    local movers, backs, minSpeed = {}, {}, nil
    for uid, u in pairs(md.units) do
        if Alive(uid) then
            if u.back then backs[#backs + 1] = uid
            else
                movers[#movers + 1] = uid
                if not minSpeed or u.speed < minSpeed then minSpeed = u.speed end
            end
        else
            md.units[uid], md.responding[uid] = nil, nil
        end
    end
    table.sort(movers); table.sort(backs)
    local R, centre, posts = PG.PickRadius(structs, 0, md.PK, o.mapX, o.mapZ, ex, ez)
    md.R, md.centre, md.posts, md.structs, md.enemy = R, centre, posts, structs, ex and { x = ex, z = ez } or nil
    local _, L = PG.LineSlots(posts, md.PK.BEARINGS, 1)
    md.lineLen = L
    local B, full = M.BlobCount(L, minSpeed, #movers, K)
    md.spacing = minSpeed and K.SPACING_S * minSpeed or 0
    local blobs = {}
    if B > 0 and L > 0 then
        local slots = PG.LineSlots(posts, md.PK.BEARINGS, full)
        if B < full and centre and centre.eAng then
            -- fewer blobs than the whole line needs: keep the 10 s spacing and cover the enemy-facing stretch (a run of B
            -- neighbouring slots centred on the one facing the enemy); the far side of the ring is left to the backstop
            local c, cf = 1, 1e9
            for i, sl in ipairs(slots) do
                local f = AngDiff(math.atan2(sl.z - centre.z, sl.x - centre.x), centre.eAng)
                if f < cf then c, cf = i, f end
            end
            local first = c - math.floor((B - 1) / 2)
            local _, closed = PG.Arcs(posts, md.PK.BEARINGS)
            local keep = {}
            if closed then
                for i = 0, B - 1 do keep[#keep + 1] = slots[(first - 1 + i) % full + 1] end
            else
                first = math.max(1, math.min(full - B + 1, first))
                for i = 0, B - 1 do keep[#keep + 1] = slots[first + i] end
            end
            slots = keep
        end
        for i = 1, B do blobs[i] = { x = slots[i].x, z = slots[i].z, units = {}, n = 0 } end
    end
    -- hysteresis: units keep their blob while the layout is the same
    local sig = B .. ":" .. full .. ":" .. math.floor(R or 0)
    if sig ~= md.sig then
        md.sig = sig
        for _, u in pairs(md.units) do u.blob = nil end
    end
    md.blobs = blobs
    if #blobs > 0 then
        local cap = math.ceil(#movers / #blobs)
        for _, uid in ipairs(movers) do                         -- the ones that keep their blob fill it first
            local b = blobs[md.units[uid].blob or 0]
            if b then b.n = b.n + 1 end
        end
        for _, uid in ipairs(movers) do
            local u = md.units[uid]
            if not blobs[u.blob or 0] then
                local x, _, z = Spring.GetUnitPosition(uid)
                local best, bd
                for i, b in ipairs(blobs) do
                    local d = x and Dist2(x, z, b.x, b.z) or 0
                    if b.n < cap then d = d else d = d + 1e12 end
                    if not bd or d < bd then best, bd = i, d end
                end
                u.blob = best
                blobs[best].n = blobs[best].n + 1
            end
        end
        for _, uid in ipairs(movers) do
            local u = md.units[uid]
            local b = blobs[u.blob]
            b.units[#b.units + 1] = uid
        end
        for _, b in ipairs(blobs) do
            for k, uid in ipairs(b.units) do
                local a, r = k * GOLDEN, K.BLOB_SPREAD * math.sqrt(k - 1)
                md.units[uid].home = { x = b.x + math.cos(a) * r, z = b.z + math.sin(a) * r }
            end
        end
    else
        for _, uid in ipairs(movers) do md.units[uid].home = nil end
    end
    -- the backstop holds the LINE too: spread over the blobs' posts (a little behind them), or evenly along the line when
    -- there are no blobs.  They never intercept (OrderFor is only asked for movers), they fight what reaches their post.
    if centre and #backs > 0 then
        local slots
        if #blobs == 0 and L > 0 then slots = PG.LineSlots(posts, md.PK.BEARINGS, #backs) end
        local per = {}
        for k, uid in ipairs(backs) do
            local bx, bz
            if #blobs > 0 then
                local i = (k - 1) % #blobs + 1
                local b = blobs[i]
                per[i] = (per[i] or 0) + 1
                bx, bz = b.x, b.z
                local dx, dz = centre.x - bx, centre.z - bz               -- a little behind the blob, toward the base
                local l = math.max(math.sqrt(dx * dx + dz * dz), 1)
                local back = md.units[uid].support and K.SUPPORT_BACK or K.BACKSTOP_BACK     -- support further back than the screen
                bx, bz = bx + dx / l * back, bz + dz / l * back
                local a, r = per[i] * GOLDEN, K.BLOB_SPREAD * math.sqrt(per[i])
                bx, bz = bx + math.cos(a) * r, bz + math.sin(a) * r
            elseif slots and slots[k] then
                bx, bz = slots[k].x, slots[k].z
            else
                bx, bz = centre.x, centre.z
            end
            md.units[uid].home = { x = bx, z = bz }
        end
    end
end

-- Enemy groups near the base, with a velocity (EMA of the group's centre between ticks) and how long they have been still.
local function Threats(md, frame)
    local K, o = md.K, md.o
    local items = {}
    for id, c in pairs(o.contacts and o.contacts() or {}) do
        if not c.air and frame - (c.frame or -1e9) <= K.LIVE_TTL then
            local v
            if c.defID then
                if (c.v or 0) > 0 then v = Value(c.defID) end
                if v and v < 80 then v = nil end                  -- scouts and other cheap units are no threat
            elseif K.BLIP_VALUE > 0 then                          -- a radar dot: no unit type, so a flat value; flying ones are not ours to meet
                local _, by = Spring.GetUnitPosition(id)
                local flying = by and Spring.GetGroundHeight and by > (Spring.GetGroundHeight(c.x, c.z) or 0) + 60
                if not flying then v = K.BLIP_VALUE end
            end
            if v and v >= K.MIN_UNIT_V then items[#items + 1] = { x = c.x, z = c.z, v = v } end
        end
    end
    local structs = md.structs or {}
    local reach = ((md.R or md.PK.R_MIN) + K.WATCH) ^ 2
    local out, used = {}, {}
    local dt = math.max(1, (frame - (md.prevFrame or frame - 30)) / 30)
    for _, cl in ipairs(PG.Clusters(items, K.CLUSTER_R)) do
        if cl.v >= K.MIN_THREAT and NearestStructD2(structs, cl.x, cl.z) <= reach then
            local best, bd
            for i, p in ipairs(md.prev) do
                if not used[i] then
                    local d = Dist2(p.x, p.z, cl.x, cl.z)
                    if d <= K.TRACK_R ^ 2 and (not bd or d < bd) then best, bd = i, d end
                end
            end
            if best then
                local p = md.prev[best]
                used[best] = true
                cl.id = p.id
                cl.vx = 0.5 * (p.vx or 0) + 0.5 * (cl.x - p.x) / dt
                cl.vz = 0.5 * (p.vz or 0) + 0.5 * (cl.z - p.z) / dt
                cl.first = p.first
            else
                cl.id, cl.vx, cl.vz, cl.first = md.nextCid, 0, 0, frame
                md.nextCid = md.nextCid + 1
            end
            cl.speed = math.sqrt(cl.vx ^ 2 + cl.vz ^ 2)
            cl.stillS = (cl.speed >= K.STILL_SPEED) and 0 or ((best and md.prev[best].stillS or 0) + dt)
            cl.inside = NearestStructD2(structs, cl.x, cl.z) <= (md.R or md.PK.R_MIN) ^ 2
            if not cl.inside and cl.stillS >= K.STAY_S then md.ignore[cl.id] = true      -- camping outside the ring: not a raid
            elseif cl.speed >= K.STILL_SPEED or cl.inside then md.ignore[cl.id] = nil end
            out[#out + 1] = cl
        end
    end
    md.prev, md.prevFrame, md.clusters = out, frame, out
end

local function Assets(md)
    local out = {}
    for _, s in ipairs(md.structs or {}) do out[#out + 1] = { x = s.x, z = s.z, w = s.w } end
    return out
end

-- The order for one responder against its group: { cmd, x, z } and the time it needs to get there.
local function OrderFor(md, uid, u, cl, assets, k)
    local K = md.K
    local x, _, z = Spring.GetUnitPosition(uid)
    if not x then return nil end
    local sp = math.max(u.speed, 1)
    local d = math.sqrt(Dist2(x, z, cl.x, cl.z))
    local moving = (cl.speed or 0) >= K.STILL_SPEED or (cl.stillS or 0) < 2
    local CMD = md.o.ARMY.CMD_MOVE                             -- interception is always a MOVE in front of the group (never FIGHT)
    local asset = ICPT.PickAsset(cl, assets) or (md.centre and { x = md.centre.x, z = md.centre.z, w = 1 })
    if not asset then return { cmd = CMD, x = cl.x, z = cl.z }, d / sp end
    local ux, uz = asset.x - cl.x, asset.z - cl.z
    local l = math.sqrt(ux * ux + uz * uz)
    local px, pz = 0, 0
    if l > 1 then px, pz = -uz / l, ux / l end
    local off = ((k % 7) - 3) * K.SPREAD / 3                   -- responders spread across the path
    if moving and d > K.CLOSE then
        local mx, mz, t = ICPT.MeetingPoint(ICPT.cfg, cl, asset, x, z, sp)
        if mx then return { cmd = CMD, x = mx + px * off, z = mz + pz * off }, t end
        local sx, sz = ICPT.Station(ICPT.cfg, cl, asset)       -- cannot get ahead of it: block between it and the asset
        return { cmd = CMD, x = sx, z = sz }, math.sqrt(Dist2(x, z, sx, sz)) / sp
    end
    -- stopped, or already close: stand just in front of the group, on its side toward the asset
    local lead = math.max(0, math.min(ICPT.cfg.lead, l - ICPT.cfg.stand_off))
    local fx, fz = cl.x, cl.z
    if l > 1 then fx, fz = cl.x + ux / l * lead + px * off, cl.z + uz / l * lead + pz * off end
    return { cmd = CMD, x = fx, z = fz }, math.sqrt(Dist2(x, z, fx, fz)) / sp
end

local function Dispatch(md, frame)
    local K = md.K
    local assets = Assets(md)
    local byId = {}
    for _, cl in ipairs(md.clusters) do byId[cl.id] = cl end
    -- who is already out on which group, and responders whose group is gone
    local sentOn = {}
    for uid, r in pairs(md.responding) do
        local u = md.units[uid]
        if not u then md.responding[uid] = nil
        elseif r.state == "out" then
            local cl = byId[r.cid]
            local ux, _, uz = Spring.GetUnitPosition(uid)
            local far = ux and NearestStructD2(md.structs or {}, ux, uz) > (((md.R or md.PK.R_MIN) + K.WATCH + K.OUT_EXTRA) ^ 2)
            if cl and not md.ignore[cl.id] and not far then
                r.lx, r.lz, r.lastSeen = cl.x, cl.z, frame
                sentOn[cl.id] = (sentOn[cl.id] or 0) + u.v
            elseif far or (cl and md.ignore[cl.id]) or frame - (r.lastSeen or frame) > K.GONE_S * 30 then
                r.state, r.cid, r.released = "return", nil, true   -- the group is dead, gone, camping or too far out: back to the post
                md.released = md.released + 1
                if md.o.ARMY and md.o.ARMY.Release then md.o.ARMY.Release(uid) end   -- the RESPOND duty ends: HOME_GUARD can take the unit
            end
        end
    end
    for _, cl in ipairs(md.clusters) do
        local need = K.NEED_MULT * cl.v
        local sent = sentOn[cl.id] or 0
        local tooFast = K.MAX_GROUP_SPEED and (cl.speed or 0) > K.MAX_GROUP_SPEED
        if sent < need and not md.ignore[cl.id] and not tooFast then
            local cand = {}
            local floor = math.min(60, 0.7 * (cl.speed or 0))
            for uid, u in pairs(md.units) do
                local r = md.responding[uid]
                if not u.back and Alive(uid) and (not r or r.state == "return") and u.speed >= floor then
                    local ord, t = OrderFor(md, uid, u, cl, assets, 0)
                    if ord then cand[#cand + 1] = { uid = uid, u = u, t = t } end
                end
            end
            table.sort(cand, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.uid < b.uid end)
            local avail = 0
            for _, c in ipairs(cand) do avail = avail + c.u.v end
            local allIn = false
            if sent + avail < need then
                if cl.inside then allIn = true                 -- in the base and outmatched: everyone goes
                else
                    if not md.warned[cl.id] then
                        md.warned[cl.id] = true
                        Spring.Echo(string.format("[MD] %s group of %.0f at (%d, %d) outmatches the %.0f we can send: hold", Clock(frame),
                            cl.v, cl.x, cl.z, sent + avail))
                    end
                    cand = {}
                end
            end
            local n, got = 0, 0
            for _, c in ipairs(cand) do
                if not allIn and sent + got >= need then break end
                md.responding[c.uid] = { state = "out", cid = cl.id, lastSeen = frame, lx = cl.x, lz = cl.z }
                got, n = got + c.u.v, n + 1
            end
            if n > 0 then
                md.intercepts = md.intercepts + 1
                sentOn[cl.id] = sent + got
                Spring.Echo(string.format("[MD] %s %d units (%.0f) -> group of %.0f (%d units) at (%d, %d), moving %.0f elmos/s%s",
                    Clock(frame), n, got + sent, cl.v, cl.n, cl.x, cl.z, cl.speed or 0, allIn and " [all in]" or ""))
            end
        end
    end
    return byId
end

-- Where a support unit fires from: the nearest live, non-ignored group within SUPPORT_REACT_R of its post, approached to
-- SUPPORT_RANGE_FRAC of its range on the side of the asset the group heads for (else its post).  nil = no group near: stay posted.
SupportSpot = function(md, u, byId, assets)
    local K, h = md.K, u.home
    local best, bd
    for id, cl in pairs(byId) do
        if not md.ignore[id] then
            local d = Dist2(cl.x, cl.z, h.x, h.z)
            if d <= K.SUPPORT_REACT_R ^ 2 and (not bd or d < bd) then best, bd = cl, d end
        end
    end
    if not best then return nil end
    local asset = ICPT.PickAsset(best, assets) or h
    local ux, uz = asset.x - best.x, asset.z - best.z
    local l = math.sqrt(ux * ux + uz * uz)
    if l < 1 then ux, uz, l = h.x - best.x, h.z - best.z, math.max(1, math.sqrt((h.x - best.x) ^ 2 + (h.z - best.z) ^ 2)) end
    local r = (u.support or 600) * K.SUPPORT_RANGE_FRAC
    local x, z = best.x + ux / l * r, best.z + uz / l * r
    return math.max(150, math.min(md.o.mapX - 150, x)), math.max(150, math.min(md.o.mapZ - 150, z))
end

local function OrderPosts(md, frame, byId)
    local ARMY, K = md.o.ARMY, md.K
    if not ARMY then return end
    local assets, idx = Assets(md), {}
    for uid, u in pairs(md.units) do
        local r = md.responding[uid]
        if r and r.state == "out" then
            local cl = byId[r.cid]
            idx[r.cid] = (idx[r.cid] or 0) + 1
            if cl then
                local ord = OrderFor(md, uid, u, cl, assets, idx[r.cid])
                if ord then ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "MD_RESPOND", cmd = ord.cmd, x = ord.x, z = ord.z }, frame) end
            elseif r.lx then                                    -- just out of sight: hold the last known spot until released
                ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "MD_RESPOND", cmd = ARMY.CMD_MOVE, x = r.lx, z = r.lz }, frame)
            end
        elseif u.support and u.home and SupportSpot(md, u, byId, assets) then
            local sx, sz = SupportSpot(md, u, byId, assets)
            ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = "MD_SUPPORT", cmd = ARMY.CMD_FIGHT, x = sx, z = sz }, frame)
        else
            local h = u.home
            if h then
                local x, _, z = Spring.GetUnitPosition(uid)
                local d = x and math.sqrt(Dist2(x, z, h.x, h.z)) or 0
                if not r and d > K.LEASH then
                    r = { state = "return" }                    -- drifted (chased something): pulled back
                    md.responding[uid] = r
                end
                if r and d <= K.HOME_EPS then
                    if r.released then md.returned = md.returned + 1 end     -- (a new unit walking out to its post is not a return)
                    md.responding[uid], r = nil, nil
                end
                local hx = math.max(K.EDGE or 150, math.min(md.o.mapX - 150, h.x))
                local hz = math.max(150, math.min(md.o.mapZ - 150, h.z))
                if r then
                    ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, { role = "MD_RETURN", cmd = ARMY.CMD_MOVE, x = hx, z = hz }, frame)
                else
                    ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, { role = "MD_POST", cmd = ARMY.CMD_FIGHT, x = hx, z = hz }, frame)
                end
            end
        end
    end
end

function M.Update(md, frame)
    local K = md.K
    if frame - md.lastPlan >= K.REPLAN then
        md.lastPlan = frame
        Replan(md, frame)
    end
    Threats(md, frame)
    local byId = Dispatch(md, frame)
    OrderPosts(md, frame, byId)
    if frame % K.LOG_EVERY == 0 then
        local nU, nO, nR = 0, 0, 0
        for _ in pairs(md.units) do nU = nU + 1 end
        for _, r in pairs(md.responding) do if r.state == "out" then nO = nO + 1 elseif r.released then nR = nR + 1 end end
        Spring.Echo(string.format("[MD] %s ring R %d, line %d elmos, %d blobs %d elmos apart (%ds), %d units (%d out, %d returning), intercepts %d, returned %d",
            Clock(frame), md.R or 0, md.lineLen or 0, #md.blobs, md.spacing or 0, K.SPACING_S, nU, nO, nR, md.intercepts, md.returned))
    end
end

return M
