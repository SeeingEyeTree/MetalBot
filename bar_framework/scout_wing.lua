-- bar_framework/scout_wing.lua
-- The scout wing (user 2026-10-30): "constant scouting of the map to find enemy units ... from 8 mins plus, it always needs to reinforce itself.
-- A focus at the start a little outside the enemy base and then around our base and then map.  Air scouts are better for scouting units, ground
-- scouts are better for posts."
--
-- One owner for every scout the scout labs make (line_transition/scout_lab.lua, WG.ScoutLabs); scout_net keeps the other labs' scouts.
--   * WANT: air = AIR_BASE + income / AIR_PER_INC (<= AIR_MAX), ground = GND_BASE + income / GND_PER_INC (<= GND_MAX), published as
--     WG.MetalBot.scoutWing; lab_rules' "scout-lab" want tops the two labs up whenever the wing is short, so a dead scout is replaced at once.
--   * AIR SCOUTS take three jobs, filled in this order (a loss is refilled from the job below it):
--       ringE  (RING_E_N) orbit the ENEMY FOOTPRINT: RING_POINTS waypoints, each RING_E_MARGIN outside the farthest enemy building we know of
--              in its direction (so the ring grows as they build out), pushed further out by recent scout losses and by known anti-air;
--       ringH  (RING_H_N) orbit our own eco footprint (map_model Base / BaseRadius) RING_H_MARGIN out: warning on the approaches;
--       rover  (the rest) sweep the map: CELL-sized cells, each with the frame it was last in our LOS; a rover flies to the best cell by
--              zone (enemy band 3, home band 2, map 1) x staleness x (1 + bonus where an enemy group was last seen) / (1 + danger) / distance.
--   * GROUND SCOUTS hold POSTS (hold fire, hold position): the middle of the base -> enemy axis and its flanks, the approaches to our base,
--     then 0.3 / 0.7 of the way.  A post where a scout died steps back POST_BACK toward home for POST_COOLDOWN_S.
--     (2026-10-31: the posts are on POST_BEARINGS round the base, POST_RADAR_MARGIN past where our radar towers' cover ends, and the
--     middle of the map where radar does not reach: a ground scout inside radar cover adds nothing.)
-- Orders go through army_broker at PRIO.SCOUT (role "WING").  Log rows: [SW].
--
-- USAGE (unit_runtime SCOUT_WING): SW.Init{ MM, ARMY, EI, WG, allyID, teamID, cfg }; SW.NoteCreated(uid, defID, builderID) in UnitCreated;
-- SW.Take(uid, defID) in UnitFinished (true = the wing owns it); SW.Lost(uid) in UnitDestroyed; SW.Step(frame) every 30 frames.

local M = {}

M.CFG = {
    AIR_BASE = 6, AIR_PER_INC = 100, AIR_MAX = 16,      -- air scouts wanted: base + 1 per AIR_PER_INC m/s of income, at most AIR_MAX
    GND_BASE = 4, GND_PER_INC = 150, GND_MAX = 10,      -- ground scouts (posts) wanted, the same way
    RING_E_N = 3,              -- air scouts orbiting the enemy footprint (filled first)
    RING_H_N = 2,              -- air scouts orbiting ours (filled second); the rest rove
    RING_POINTS = 8,           -- waypoints per ring (one per sector)
    RING_E_MARGIN = 1300,      -- the enemy ring: this far outside the farthest enemy building in each sector ...
    RING_E_MIN = 1800,         -- ... and never closer than this to the enemy centre
    FOOTPRINT_MAX = 4500,      -- enemy buildings farther than this from their centre are outlying eco (the rovers find those), not the base
    LOSS_PUSH = 300,           -- each ring scout lost in the last LOSS_MEMORY pushes the enemy ring this much further out ...
    PUSH_MAX = 1500,           -- ... up to this
    LOSS_MEMORY = 120 * 30,    -- frames a scout loss counts (ring push, cell danger)
    AA_AVOID = 250,            -- enemy_intel ThreatAt(air) value at which a ring point is pushed out (and a cell counts as dangerous)
    AA_STEP = 300, AA_STEPS = 4,   -- push steps for a ring point inside known anti-air
    RING_H_MARGIN = 1500,      -- our ring: this far outside our eco footprint's radius
    ARRIVE = 350,              -- elmos: a waypoint / cell counts as reached
    CELL = 1024,               -- rover cells (elmos)
    AGE_CAP = 180 * 30,        -- staleness counts up to this (a cell unseen 3 min is as stale as one never seen)
    ENEMY_MEMORY = 150 * 30,   -- an enemy group seen in the last this many frames, and not in LOS now, pulls rovers to where it was
    ENEMY_BONUS = 3,           -- ... by this much (x the group's value / 1000, at most 1)
    STRUCT_BONUS = 0.5,        -- a cell with a known enemy building is worth this much more (eco moves, mexes get rebuilt)
    W_ENEMY_BAND = 3, W_ENEMY_CORE = 0.5, W_HOME = 2, W_MAP = 1,   -- zone weights: the band round the enemy footprint, inside it, round ours, the rest
    HOME_BAND = 2500,          -- a cell this close to our footprint is in the home band
    DIST_SCALE = 4000,         -- score / (1 + distance / DIST_SCALE)
    REPICK = 300,              -- frames before a rover re-picks its cell anyway
    DANGER_PERIOD = 150,       -- frames between danger refreshes (enemy_intel ThreatAt per cell)
    POST_COOLDOWN_S = 90,      -- a post where a ground scout died is held back this long ...
    POST_BACK = 500,           -- ... this many elmos toward home
    HOME_POST_MARGIN = 1200,   -- (unused since 2026-10-31: the posts are placed past our radar instead)
    POST_BEARINGS = { 0, -25, 25, -50, 50, -75, 75, -100, 100 },   -- degrees from the base -> enemy axis, in priority order
    POST_RADAR_MARGIN = 400,   -- a post stands this far past our radar towers' cover (user 2026-10-31: "if they are in radar range they are
                               -- not doing anything")
    POST_STEP = 200,           -- elmos per step when walking out from the base to find the edge of our radar
    POST_MAX_FWD = 0.55,       -- ... never past this share of the way to the enemy
    RADAR_MIN = 1500,          -- a static unit with at least this radar radius counts as radar cover
    LOG_PERIOD = 900,
}

local spGetUnitDefID, spGetUnitPosition = Spring.GetUnitDefID, Spring.GetUnitPosition
local D = {}           -- deps (Init)
local C = M.CFG
local units = {}       -- [uid] = { kind = "air"|"ground", job = "ringE"|"ringH"|"rover"|"post", ... }
local born = {}        -- [uid] = "air"|"ground": started in a scout lab, not finished
local losses = {}      -- { x, z, f, job }
local cells = nil      -- { nx, nz, [i] = { x, z, seen, danger, enemy, struct } }
local posts = {}       -- { x, z, prio, cool, owner }
local state = { lastLog = -1e9, lastDanger = -1e9, lastPosts = -1e9, made = { air = 0, ground = 0 }, lost = { air = 0, ground = 0 },
                ringE = nil, ringH = nil, push = 0, enemyCx = nil, enemyCz = nil }

local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end

function M.Init(deps)
    for k, v in pairs(deps or {}) do D[k] = v end
    for k, v in pairs(deps and deps.cfg or {}) do
        if C[k] == nil then Spring.Echo("[SW] option '" .. tostring(k) .. "' is not a scout_wing option (typo?)") end
        C[k] = v
    end
end

local function LabKind(builderID)
    local L = D.WG and D.WG.ScoutLabs
    if not (L and builderID) then return nil end
    if builderID == L.air then return "air" end
    if builderID == L.ground then return "ground" end
    return nil
end

function M.NoteCreated(uid, defID, builderID)
    local k = LabKind(builderID)
    if k then born[uid] = k end
end

function M.Take(uid, defID)
    local k = born[uid]
    if not k then return false end
    born[uid] = nil
    units[uid] = { kind = k, job = (k == "ground") and "post" or nil }
    state.made[k] = state.made[k] + 1
    if k == "ground" and CMD then        -- a post watches; an armed scout that chases gives the post away
        Spring.GiveOrderToUnit(uid, CMD.FIRE_STATE, { 0 }, {})
        Spring.GiveOrderToUnit(uid, CMD.MOVE_STATE, { 0 }, {})
    end
    return true
end

function M.Lost(uid)
    born[uid] = nil
    local u = units[uid]
    if not u then return end
    units[uid] = nil
    local x, _, z = spGetUnitPosition(uid)
    local f = Spring.GetGameFrame()
    if x then losses[#losses + 1] = { x = x, z = z, f = f, job = u.job } end
    state.lost[u.kind] = state.lost[u.kind] + 1
    if u.post then
        u.post.owner = nil
        u.post.cool = f + C.POST_COOLDOWN_S * 30
    end
end

function M.Owns(uid) return units[uid] ~= nil end

-- ── want ───────────────────────────────────────────────────────────────────────

local function Want()
    local income = 0
    if D.teamID then
        local _, _, _, inc = Spring.GetTeamResources(D.teamID, "metal")
        income = inc or 0
    end
    local air = math.min(C.AIR_MAX, C.AIR_BASE + math.floor(income / C.AIR_PER_INC))
    local gnd = math.min(C.GND_MAX, C.GND_BASE + math.floor(income / C.GND_PER_INC))
    return air, gnd
end

-- ── rings ──────────────────────────────────────────────────────────────────────

-- The enemy footprint: the centre of their known buildings (labs weigh 3x), else their spawn; per sector, the farthest building in it
-- (FOOTPRINT_MAX at most).
local function EnemyFootprint(frame)
    local EI, MM = D.EI, D.MM
    local sx, sz, sw = 0, 0, 0
    local bs = {}
    if EI and EI.Records then
        for _, rec in pairs(EI.Records()) do
            local c = rec.c
            if c and not c.mobile and rec.x then
                local w = c.factory and 3 or 1
                sx, sz, sw = sx + rec.x * w, sz + rec.z * w, sw + w
                bs[#bs + 1] = rec
            end
        end
    end
    local cx, cz
    if sw > 0 then cx, cz = sx / sw, sz / sw else cx, cz = MM.Foe() end
    if not cx then return nil end
    local P = C.RING_POINTS
    local far = {}
    for i = 1, P do far[i] = 0 end
    for _, rec in ipairs(bs) do
        local d = Dist(rec.x, rec.z, cx, cz)
        if d <= C.FOOTPRINT_MAX then
            local a = math.atan2(rec.z - cz, rec.x - cx)
            local i = (math.floor((a / (2 * math.pi)) * P + 0.5) % P) + 1
            if d > far[i] then far[i] = d end
        end
    end
    return cx, cz, far, #bs
end

local function RingPoints(cx, cz, radiusOf, frame, avoidAA)
    local MM, EI = D.MM, D.EI
    local P = C.RING_POINTS
    local pts = {}
    for i = 1, P do
        local a = (i - 1) / P * 2 * math.pi
        local ca, sa = math.cos(a), math.sin(a)
        local r = radiusOf(i)
        local x, z = cx + ca * r, cz + sa * r
        if avoidAA and EI and EI.ThreatAt then
            for _ = 1, C.AA_STEPS do
                if EI.ThreatAt(frame, x, z, "air") < C.AA_AVOID then break end
                r = r + C.AA_STEP
                x, z = cx + ca * r, cz + sa * r
            end
        end
        x, z = MM.Clamp(x, z, 200)
        pts[i] = { x = x, z = z }
    end
    return pts
end

local function UpdateRings(frame)
    local MM = D.MM
    local cx, cz, far, nb = EnemyFootprint(frame)
    if cx then
        local n = 0
        for _, l in ipairs(losses) do
            if l.job == "ringE" and frame - l.f <= C.LOSS_MEMORY then n = n + 1 end
        end
        state.push = math.min(C.PUSH_MAX, n * C.LOSS_PUSH)
        local P = C.RING_POINTS
        state.ringE = RingPoints(cx, cz, function(i)
            -- the sector and its two neighbours: a building just across a sector edge still keeps the ring off it
            local f = math.max(far[i], far[(i % P) + 1], far[((i - 2) % P) + 1])
            return math.max(C.RING_E_MIN, f + C.RING_E_MARGIN) + state.push
        end, frame, true)
        state.enemyCx, state.enemyCz, state.enemyR, state.enemyBuildings = cx, cz, 0, nb
        for i = 1, P do state.enemyR = math.max(state.enemyR, far[i]) end
    end
    local bx, bz = MM.Base()
    if bx then
        local r = (MM.BaseRadius() or 0) + C.RING_H_MARGIN
        state.ringH = RingPoints(bx, bz, function() return r end, frame, false)
    end
end

-- ── cells ──────────────────────────────────────────────────────────────────────

local function InitCells()
    local mx, mz = D.MM.MapSize()
    if not mx then return end
    local nx, nz = math.max(1, math.ceil(mx / C.CELL)), math.max(1, math.ceil(mz / C.CELL))
    cells = { nx = nx, nz = nz }
    for j = 0, nz - 1 do
        for i = 0, nx - 1 do
            cells[#cells + 1] = { x = math.min(mx - 64, (i + 0.5) * C.CELL), z = math.min(mz - 64, (j + 0.5) * C.CELL),
                                  seen = -1e9, danger = 0, enemy = 0, struct = false }
        end
    end
end

local function CellAt(x, z)
    local i = math.max(0, math.min(cells.nx - 1, math.floor(x / C.CELL)))
    local j = math.max(0, math.min(cells.nz - 1, math.floor(z / C.CELL)))
    return cells[j * cells.nx + i + 1]
end

local function UpdateCells(frame)
    local los, gh = Spring.IsPosInLos, Spring.GetGroundHeight
    for _, c in ipairs(cells) do
        c.enemy, c.struct = 0, false
        if los and los(c.x, gh(c.x, c.z) or 0, c.z, D.allyID) then c.seen = frame end
    end
    local EI = D.EI
    if EI and EI.Groups then
        for _, g in ipairs(EI.Groups(frame, 600, C.ENEMY_MEMORY)) do
            local c = CellAt(g.x, g.z)
            if c and frame - c.seen > 300 then c.enemy = math.max(c.enemy, math.min(1, (g.value or 0) / 1000)) end
        end
    end
    if EI and EI.Records then
        for _, rec in pairs(EI.Records()) do
            if rec.c and not rec.c.mobile and rec.x then local c = CellAt(rec.x, rec.z); if c then c.struct = true end end
        end
    end
    if frame - state.lastDanger >= C.DANGER_PERIOD then
        state.lastDanger = frame
        for _, c in ipairs(cells) do
            local d = 0
            if EI and EI.ThreatAt then d = EI.ThreatAt(frame, c.x, c.z, "air") / C.AA_AVOID end
            for _, l in ipairs(losses) do
                local age = frame - l.f
                if age <= C.LOSS_MEMORY and math.abs(l.x - c.x) <= C.CELL * 0.75 and math.abs(l.z - c.z) <= C.CELL * 0.75 then
                    d = d + (1 - age / C.LOSS_MEMORY)
                end
            end
            c.danger = d
        end
    end
end

local function ZoneW(c)
    local MM = D.MM
    if state.enemyCx then
        local de = Dist(c.x, c.z, state.enemyCx, state.enemyCz)
        local core = math.max(C.RING_E_MIN - C.RING_E_MARGIN, state.enemyR or 0)
        if de <= core then return C.W_ENEMY_CORE end
        if de <= core + 2 * C.RING_E_MARGIN + state.push then return C.W_ENEMY_BAND end
    end
    if MM.BaseDist and MM.BaseDist(c.x, c.z) <= C.HOME_BAND then return C.W_HOME end
    return C.W_MAP
end

local function PickCell(frame, ux, uz, taken)
    local best, bestS
    for idx, c in ipairs(cells) do
        if not taken[idx] then
            local age = math.min(C.AGE_CAP, frame - c.seen) / C.AGE_CAP
            if age > 0.05 then
                local s = ZoneW(c) * age * (1 + C.ENEMY_BONUS * c.enemy + (c.struct and C.STRUCT_BONUS or 0)) / (1 + c.danger)
                s = s / (1 + Dist(ux, uz, c.x, c.z) / C.DIST_SCALE)
                if not bestS or s > bestS then best, bestS = idx, s end
            end
        end
    end
    return best
end

-- ── posts ──────────────────────────────────────────────────────────────────────

local function BuildPosts(frame)
    local MM = D.MM
    local Dd = MM.Dist()
    if not (Dd and Dd > 0) then return end
    local old = {}
    for _, p in ipairs(posts) do old[p.key] = p end
    local list = {}
    local function add(key, x, z)
        if not x then return end
        x, z = MM.Clamp(x, z, 200)
        local p = old[key] or { key = key }
        p.x, p.z = x, z
        list[#list + 1] = p
    end
    -- our radar towers: a post inside their cover sees nothing radar does not (user 2026-10-31)
    local radars = {}
    for _, uid in ipairs(Spring.GetTeamUnits(D.teamID) or {}) do
        local d = UnitDefs[spGetUnitDefID(uid) or -1]
        local rr = d and (d.radarRadius or d.radarDistance or 0) or 0
        if d and not d.canMove and rr >= C.RADAR_MIN then
            local x, _, z = spGetUnitPosition(uid)
            if x then radars[#radars + 1] = { x = x, z = z, r = rr } end
        end
    end
    local function Covered(x, z)
        for _, r in ipairs(radars) do if Dist(x, z, r.x, r.z) <= r.r then return true end end
        return false
    end
    -- on each bearing round the base, walk out from the base's edge to where our radar ends, then POST_RADAR_MARGIN further
    local bx, bz = MM.Base()
    local ax, az = MM.Axis()
    local mx, mz = MM.MapSize()
    if bx and ax then
        local r0 = (MM.BaseRadius() or 0) + 300
        for _, deg in ipairs(C.POST_BEARINGS) do
            local a = math.rad(deg)
            local dx, dz = ax * math.cos(a) - az * math.sin(a), ax * math.sin(a) + az * math.cos(a)
            local r, ok = r0, false
            while true do
                local x, z = bx + dx * r, bz + dz * r
                if x < 100 or z < 100 or x > mx - 100 or z > mz - 100 or MM.Forward(x, z) > C.POST_MAX_FWD * Dd then break end
                if not Covered(x, z) then ok = true; break end
                r = r + C.POST_STEP
            end
            if ok then
                local x, z = bx + dx * (r + C.POST_RADAR_MARGIN), bz + dz * (r + C.POST_RADAR_MARGIN)
                if x >= 100 and z >= 100 and x <= mx - 100 and z <= mz - 100 then add("b" .. deg, x, z) end
            end
        end
    end
    -- the middle of the map, where it is outside our radar too
    local W = 0.35 * Dd
    for _, k in ipairs({ { "mid", 0 }, { "midL", -W }, { "midR", W } }) do
        local x, z = MM.PointAt(0.5 * Dd, k[2])
        if x and not Covered(x, z) then add(k[1], x, z) end
    end
    for key, p in pairs(old) do                     -- a post that is gone frees its scout
        local keep = false
        for _, q in ipairs(list) do if q == p then keep = true; break end end
        if not keep and p.owner and units[p.owner] then units[p.owner].post = nil end
    end
    posts = list
end

-- where a post's scout stands now (stepped back toward home while the post is cooling down)
local function PostSpot(p, frame)
    if not (p.cool and frame < p.cool) then return p.x, p.z end
    local hx, hz = D.MM.Base()
    local d = Dist(p.x, p.z, hx, hz)
    if d <= C.POST_BACK then return hx, hz end
    return p.x + (hx - p.x) / d * C.POST_BACK, p.z + (hz - p.z) / d * C.POST_BACK
end

-- ── step ───────────────────────────────────────────────────────────────────────

local function Claim(uid, x, z, frame)
    local A = D.ARMY
    A.Claim(A.PRIO.SCOUT, uid, { role = "WING", cmd = A.CMD_MOVE, x = x, z = z }, frame)
end

local function Orbit(uid, u, pts, frame, x, z)
    if not pts then return end
    local P = #pts
    if not u.wp then                      -- start at the nearest point
        local best, bd = 1, math.huge
        for i, p in ipairs(pts) do local d = Dist(x, z, p.x, p.z); if d < bd then best, bd = i, d end end
        u.wp = best
    end
    local p = pts[u.wp]
    if Dist(x, z, p.x, p.z) <= C.ARRIVE then
        u.wp = (u.wp % P) + 1
        p = pts[u.wp]
    end
    Claim(uid, p.x, p.z, frame)
end

local function AssignAir(frame)
    local list, n = {}, { ringE = 0, ringH = 0, rover = 0 }
    for uid, u in pairs(units) do
        if u.kind == "air" then
            if not spGetUnitDefID(uid) then units[uid] = nil
            else list[#list + 1] = uid; if u.job then n[u.job] = n[u.job] + 1 end end
        end
    end
    table.sort(list)
    -- fill the jobs in order: unassigned scouts first, then take from the job below (rover -> ringH -> ringE)
    local function Fill(job, want, from)
        for _, uid in ipairs(list) do
            if n[job] >= want then return end
            local u = units[uid]
            if u.job == nil or (from[u.job]) then
                if u.job then n[u.job] = n[u.job] - 1 end
                u.job, u.wp, u.cell = job, nil, nil
                n[job] = n[job] + 1
            end
        end
    end
    Fill("ringE", C.RING_E_N, { rover = true })
    Fill("ringE", C.RING_E_N, { ringH = true })
    Fill("ringH", C.RING_H_N, { rover = true })
    for _, uid in ipairs(list) do
        local u = units[uid]
        if not u.job then u.job = "rover"; n.rover = n.rover + 1 end
    end
    -- orders
    local taken = {}
    for _, uid in ipairs(list) do local u = units[uid]; if u.job == "rover" and u.cell then taken[u.cell] = true end end
    for _, uid in ipairs(list) do
        local u = units[uid]
        local x, _, z = spGetUnitPosition(uid)
        if x then
            if u.job == "ringE" then Orbit(uid, u, state.ringE, frame, x, z)
            elseif u.job == "ringH" then Orbit(uid, u, state.ringH, frame, x, z)
            else
                local c = u.cell and cells[u.cell]
                if not c or Dist(x, z, c.x, c.z) <= C.ARRIVE or frame - (u.cellF or 0) >= C.REPICK or frame - c.seen < 150 then
                    if u.cell then taken[u.cell] = nil end
                    u.cell, u.cellF = PickCell(frame, x, z, taken), frame
                    if u.cell then taken[u.cell] = true end
                    c = u.cell and cells[u.cell]
                end
                if c then Claim(uid, c.x, c.z, frame) end
            end
        end
    end
    return #list, n
end

local function AssignGround(frame)
    local free, have = {}, 0
    for uid, u in pairs(units) do
        if u.kind == "ground" then
            if not spGetUnitDefID(uid) then units[uid] = nil
            else
                have = have + 1
                if not u.post then free[#free + 1] = uid end
            end
        end
    end
    table.sort(free)
    local manned = 0
    for _, p in ipairs(posts) do
        if p.owner and not units[p.owner] then p.owner = nil end
        if not p.owner and #free > 0 then           -- the closest free scout takes the post (posts are in priority order)
            local bi, bd = nil, math.huge
            for i, uid in ipairs(free) do
                local x, _, z = spGetUnitPosition(uid)
                if x then local d = Dist(x, z, p.x, p.z); if d < bd then bi, bd = i, d end end
            end
            if bi then
                local uid = table.remove(free, bi)
                p.owner = uid
                units[uid].post = p
            end
        end
        if p.owner then
            manned = manned + 1
            local x, z = PostSpot(p, frame)
            Claim(p.owner, x, z, frame)
        end
    end
    -- more scouts than posts: the spares wait at the first post
    for _, uid in ipairs(free) do
        local p = posts[1]
        if p then Claim(uid, p.x, p.z, frame) end
    end
    return have, manned
end

function M.Step(frame)
    local MM, ARMY = D.MM, D.ARMY
    if not (MM and ARMY and MM.Ready and MM.Ready()) then return end
    if not cells then InitCells(); if not cells then return end end
    for i = #losses, 1, -1 do if frame - losses[i].f > C.LOSS_MEMORY then table.remove(losses, i) end end
    UpdateCells(frame)
    UpdateRings(frame)
    if frame - state.lastPosts >= 1800 or #posts == 0 then state.lastPosts = frame; BuildPosts(frame) end
    local airHave, jobs = AssignAir(frame)
    local gndHave, manned = AssignGround(frame)
    local airWant, gndWant = Want()
    local airB, gndB = 0, 0
    for uid, k in pairs(born) do
        if not spGetUnitDefID(uid) then born[uid] = nil
        elseif k == "air" then airB = airB + 1 else gndB = gndB + 1 end
    end
    local mb = D.WG and D.WG.MetalBot
    if mb then
        mb.scoutWing = { air = airWant, ground = gndWant, airHave = airHave, groundHave = gndHave, airBuilding = airB, groundBuilding = gndB,
                         airShort = airWant - airHave - airB, groundShort = gndWant - gndHave - gndB }
    end
    if frame - state.lastLog >= C.LOG_PERIOD and (airHave + gndHave + airB + gndB > 0 or (D.WG and D.WG.ScoutLabs)) then
        state.lastLog = frame
        local fresh, total = 0, #cells
        for _, c in ipairs(cells) do if frame - c.seen <= 60 * 30 then fresh = fresh + 1 end end
        local vis = 0
        if D.EI and D.EI.Records then
            for _, rec in pairs(D.EI.Records()) do if rec.c and rec.c.mobile and frame - rec.frame <= 120 then vis = vis + 1 end end
        end
        Spring.Echo(string.format("[SW] %s air %d/%d (+%d building; ringE %d ringH %d rover %d) ground %d/%d (+%d) posts %d/%d"
            .. " | cov60 %.0f%% enemy mobile in view %d | made %d/%d lost %d/%d | enemy ring %.0f outside %d buildings (r %.0f, push %.0f)",
            Clock(frame), airHave, airWant, airB, jobs.ringE, jobs.ringH, jobs.rover, gndHave, gndWant, gndB, manned, #posts,
            100 * fresh / math.max(1, total), vis, state.made.air, state.made.ground, state.lost.air, state.lost.ground,
            C.RING_E_MARGIN, state.enemyBuildings or 0, state.enemyR or 0, state.push))
    end
end

return M
