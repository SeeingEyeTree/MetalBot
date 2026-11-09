-- bar_framework/edge_route.lua  (a flight path that hugs the map's edges -- user 2026-11-08: "Have the convoy and air con hug the side of the map so
-- there is less chance they get spotted or intercepted")
-- The path: from the start to the nearest point of the map's border rectangle (MARGIN in from the edges), round the border -- the way that stays farther
-- from `avoid` (the enemy's build power), the shorter way when both stay SAFE_D clear of it -- to the border point nearest the target, then the target.
--
--   local ER = VFS.Include("LuaUI/Widgets/bar_framework/edge_route.lua")
--   ER.Route(sx, sz, tx, tz, { margin, avoid = { x, z } }) -> { { x, z }, ... } (waypoints after the start, the target last)
--   ER.Back(route, sx, sz, d) -> x, z, before, after: the point d short of the route's end (measured back along it); `before` = the waypoints up to it,
--                                `after` = the waypoints from it to the end (the target last)

local M = {}

M.MARGIN = 300
M.SAFE_D = 3500
M.STEP   = 400

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end

-- the border rectangle as a loop: corners c[1..4] (top-left, top-right, bottom-right, bottom-left), side i runs c[i] -> c[i % 4 + 1]
local function Corners(m)
    local W, H = Game.mapSizeX, Game.mapSizeZ
    return { { m, m }, { W - m, m }, { W - m, H - m }, { m, H - m } }
end

-- the nearest border point to (x, z): side index, the point, the distance along the loop from c[1]
local function Project(c, x, z)
    local best
    local acc = 0
    for i = 1, 4 do
        local a, b = c[i], c[i % 4 + 1]
        local dx, dz = b[1] - a[1], b[2] - a[2]
        local L = math.sqrt(dx * dx + dz * dz)
        local t = L > 0 and math.max(0, math.min(1, ((x - a[1]) * dx + (z - a[2]) * dz) / (L * L))) or 0
        local px, pz = a[1] + dx * t, a[2] + dz * t
        local d = Dist(x, z, px, pz)
        if not best or d < best.d then best = { side = i, x = px, z = pz, d = d, s = acc + t * L } end
        acc = acc + L
    end
    best.perim = acc
    return best
end

-- the loop from a to b in direction dir (+1 = c1 -> c2 -> ..., -1 = back): the corner points passed, then b
local function Walk(c, a, b, dir)
    local pts = { { a.x, a.z } }
    local i = a.side
    if dir > 0 then
        while i ~= b.side or (a.s > b.s and i == a.side and #pts == 1) do
            local n = i % 4 + 1
            pts[#pts + 1] = { c[n][1], c[n][2] }
            i = n
            if #pts > 6 then break end
        end
    else
        while i ~= b.side or (a.s < b.s and i == a.side and #pts == 1) do
            pts[#pts + 1] = { c[i][1], c[i][2] }
            i = (i + 2) % 4 + 1
            if #pts > 6 then break end
        end
    end
    pts[#pts + 1] = { b.x, b.z }
    return pts
end

local function Length(pts)
    local L = 0
    for i = 2, #pts do L = L + Dist(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]) end
    return L
end

local function MinDist(pts, ax, az)
    local m = math.huge
    for i = 2, #pts do
        local x0, z0, x1, z1 = pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]
        local n = math.max(1, math.ceil(Dist(x0, z0, x1, z1) / M.STEP))
        for k = 0, n do
            local t = k / n
            m = math.min(m, Dist(x0 + (x1 - x0) * t, z0 + (z1 - z0) * t, ax, az))
        end
    end
    return m
end

function M.Route(sx, sz, tx, tz, opts)
    opts = opts or {}
    local c = Corners(opts.margin or M.MARGIN)
    local a, b = Project(c, sx, sz), Project(c, tx, tz)
    local cands = { Walk(c, a, b, 1), Walk(c, a, b, -1) }
    local best, bestL, bestM
    for _, pts in ipairs(cands) do
        local L = Length(pts)
        local m = opts.avoid and MinDist(pts, opts.avoid.x, opts.avoid.z) or math.huge
        local better
        if not best then better = true
        else
            local safeA, safeB = m >= M.SAFE_D, bestM >= M.SAFE_D
            if safeA ~= safeB then better = safeA
            elseif safeA then better = L < bestL
            else better = m > bestM end
        end
        if better then best, bestL, bestM = pts, L, m end
    end
    local out = {}
    for _, p in ipairs(best) do out[#out + 1] = { x = p[1], z = p[2] } end
    out[#out + 1] = { x = tx, z = tz }
    return out
end

-- the point d short of the end of (start, route...), measured back along it
function M.Back(route, sx, sz, d)
    local pts = { { x = sx, z = sz } }
    for _, p in ipairs(route) do pts[#pts + 1] = p end
    local left = d
    for i = #pts, 2, -1 do
        local a, b = pts[i - 1], pts[i]
        local L = Dist(a.x, a.z, b.x, b.z)
        if L >= left then
            local k = (L > 0) and left / L or 0
            local x, z = b.x + (a.x - b.x) * k, b.z + (a.z - b.z) * k
            local before, after = {}, {}
            for j = 2, i - 1 do before[#before + 1] = pts[j] end
            for j = i, #pts do after[#after + 1] = pts[j] end
            return x, z, before, after
        end
        left = left - L
    end
    return sx, sz, {}, route
end

return M
