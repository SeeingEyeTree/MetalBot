-- bar_framework/defence/areas.lua  (area_defence: the places we defend)
-- User 2026-11-08: "you declare groups of buildings to defend and a radius to protect and it tries to protect that.  For the main base it would just
-- be all the labs eco and nanos really.  With max radius 4k elmos.  It would not be buildings far out.  Just the nano cols, spine, line, and sink."
--
-- An area is a point set (its member buildings) with the queries cover_defence used on map_model's base footprint, plus an APPROACH MAP: BINS
-- angle bins round the area's centre holding the enemy ground value that came at it (decayed with TAU_S, seeded with PRIOR on the enemy axis).  The
-- front is the arc of bins that saw at least FRONT_SHARE of the busiest bin's traffic (the axis bin always), walls stand on it (defence/wall.lua).
--
--   local AR = VFS.Include("LuaUI/Widgets/bar_framework/defence/areas.lua")
--   local a = AR.New{ id = "main", R_MAX = 4000, members = fn() -> { uid, ... } | nil (nil: labs, eco, static builders), anchor = fn() -> x, z, MM, teamID,
--                     anchorPoint = bool (the anchor counts as a member: a proxy spot defended before anything stands there), axis = fn() -> ux, uz (the
--                     front's prior; default map_model's enemy axis), SIDE_R = n (threats this close count for it: defence/threats.lua), wall = { keep, tzars } }
--   a.Refresh(frame)  a.Dist(x, z)  a.NearestInCone(x, z, dx, dz, cosMin) -> x, z, d  a.Centre() -> x, z  a.Radius()  a.N()
--   a.Note(x, z, value, dt)  (a threat seen there, per second)   a.Front() -> { amin, amax, axis, bins }   a.EdgeAt(angle) -> x, z, r (outermost member that way)

local M = {}

M.CFG = { R_MAX = 4000, REFRESH = 150, BINS = 16, TAU_S = 300, PRIOR = 0.25, FRONT_SHARE = 0.15, CELL = 256 }   -- FRONT_SHARE 0.15 (game 4: at 0.5 the front shrank onto the busiest direction; raids came round the flanks)

local function IsAreaStructure(d)
    if not d or d.canFly or not (d.isBuilding or (d.speed or 0) == 0) then return false end
    if (d.extractsMetal or 0) > 0 or (d.energyMake or 0) >= 20 or (d.windGenerator or 0) > 0 or (d.tidalGenerator or 0) > 0 then return true end
    if d.isFactory or (d.buildSpeed or 0) > 0 or (d.metalStorage or 0) >= 500 or (d.energyStorage or 0) >= 1000 then return true end
    if (d.metalMake or 0) > 0 or (d.energyUpkeep or 0) < -20 then return true end
    return false
end
M.IsAreaStructure = IsAreaStructure

local function Angle(dx, dz) return math.atan2(dz, dx) end
local function Wrap(a) while a > math.pi do a = a - 2 * math.pi end; while a < -math.pi do a = a + 2 * math.pi end; return a end

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    if o.R_MAX then C.R_MAX = o.R_MAX end
    if o.SIDE_R then C.SIDE_R = o.SIDE_R end
    local MM = o.MM
    local a = { id = o.id or "main", cfg = C, wall = o.wall }
    local pts, n, cx, cz, r = {}, 0, nil, nil, 0
    local cache = {}
    local refreshF = -1e9
    local bins = {}
    for i = 1, C.BINS do bins[i] = 0 end
    local isStruct = {}

    local function Anchor()
        if o.anchor then return o.anchor() end
        if MM and MM.Home then return MM.Home() end
        return nil
    end

    function a.Refresh(frame, force)
        if not force and frame - refreshF < C.REFRESH then return end
        refreshF = frame
        local ax, az = Anchor()
        if not ax then return end
        local ids = o.members and o.members() or nil
        local out = {}
        if o.anchorPoint then out[1], out[2] = ax, az end
        local r2 = C.R_MAX * C.R_MAX
        for _, uid in ipairs(ids or Spring.GetTeamUnits(o.teamID) or {}) do
            local defID = Spring.GetUnitDefID(uid)
            local ok = isStruct[defID or -1]
            if ok == nil and defID then ok = ids ~= nil or IsAreaStructure(UnitDefs[defID]); if not ids then isStruct[defID] = ok end end
            if ok then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x and (x - ax) ^ 2 + (z - az) ^ 2 <= r2 then out[#out + 1] = x; out[#out + 1] = z end
            end
        end
        pts, n, cache = out, math.floor(#out / 2), {}
        if n == 0 then cx, cz, r = ax, az, 0; return end
        local sx, sz = 0, 0
        for i = 1, n do sx, sz = sx + pts[2 * i - 1], sz + pts[2 * i] end
        cx, cz = sx / n, sz / n
        local ds = {}
        for i = 1, n do ds[i] = math.sqrt((pts[2 * i - 1] - cx) ^ 2 + (pts[2 * i] - cz) ^ 2) end
        table.sort(ds)
        r = ds[math.max(1, math.ceil(n * 0.9))]
    end

    function a.N() return n end
    a.Anchor = Anchor            -- the point R_MAX is measured from (the spawn for the main area, the spot for a proxy)
    function a.Centre() if cx then return cx, cz end; return Anchor() end
    function a.Radius() return r end

    -- distance to the nearest member (0 inside the footprint), cached per CELL like map_model's BaseDist
    function a.Dist(x, z)
        if n == 0 then
            local ax, az = Anchor()
            if not ax then return 0 end
            return math.sqrt((x - ax) ^ 2 + (z - az) ^ 2)
        end
        local kx, kz = math.floor(x / C.CELL), math.floor(z / C.CELL)
        local key = kx * 100003 + kz
        local d = cache[key]
        if not d then
            local mx, mz = (kx + 0.5) * C.CELL, (kz + 0.5) * C.CELL
            local best = math.huge
            for i = 1, n do
                local q = (pts[2 * i - 1] - mx) ^ 2 + (pts[2 * i] - mz) ^ 2
                if q < best then best = q end
            end
            d = math.sqrt(best)
            cache[key] = d
        end
        return math.max(0, d - C.CELL * 0.5)
    end

    -- the member nearest (x, z) inside the cone round the heading (dx, dz) (cos >= cosMin), else the nearest of all (map_model BaseNearestInCone)
    function a.NearestInCone(x, z, dx, dz, cosMin)
        if n == 0 then
            local ax, az = Anchor()
            if not ax then return nil end
            return ax, az, math.sqrt((x - ax) ^ 2 + (z - az) ^ 2)
        end
        local hd = math.sqrt((dx or 0) ^ 2 + (dz or 0) ^ 2)
        local ux, uz = 0, 0
        if hd > 1e-6 then ux, uz = dx / hd, dz / hd end
        local bx, bz, bd, qx, qz, qd
        for i = 1, n do
            local px, pz = pts[2 * i - 1], pts[2 * i]
            local ex, ez = px - x, pz - z
            local d = math.sqrt(ex * ex + ez * ez)
            if not bd or d < bd then bx, bz, bd = px, pz, d end
            if hd > 1e-6 and d > 1e-6 and (ex * ux + ez * uz) / d >= cosMin and (not qd or d < qd) then qx, qz, qd = px, pz, d end
        end
        if qx then return qx, qz, qd end
        return bx, bz, bd
    end

    -- the outermost member in the direction `ang` from the centre (largest projection among members within 1.5 bins of it; any member otherwise)
    function a.EdgeAt(ang)
        local ox, oz = a.Centre()
        if not ox then return nil end
        local ux, uz = math.cos(ang), math.sin(ang)
        local half = 1.5 * math.pi / C.BINS
        local best, bestAny
        for i = 1, n do
            local dx, dz = pts[2 * i - 1] - ox, pts[2 * i] - oz
            local p = dx * ux + dz * uz
            if not bestAny or p > bestAny then bestAny = p end
            local d = math.sqrt(dx * dx + dz * dz)
            if d < 1 or math.abs(Wrap(Angle(dx, dz) - ang)) <= half then
                if not best or p > best then best = p end
            end
        end
        local p = math.max(0, best or bestAny or 0)
        return ox + ux * p, oz + uz * p, p
    end

    local function Bin(ang) return math.floor(((ang + math.pi) / (2 * math.pi)) * C.BINS) % C.BINS + 1 end
    local function BinAngle(i) return (i - 0.5) / C.BINS * 2 * math.pi - math.pi end
    a.BinAngle = BinAngle

    -- a threat worth `value` seen at (x, z) for dt seconds; every bin decays by dt / TAU_S
    function a.Note(x, z, value, dt)
        local ox, oz = a.Centre()
        if not ox then return end
        local i = Bin(Angle(x - ox, z - oz))
        bins[i] = bins[i] + (value or 0) * (dt or 1)
    end
    function a.Decay(dt)
        local k = math.exp(-(dt or 1) / C.TAU_S)
        for i = 1, C.BINS do bins[i] = bins[i] * k end
    end

    -- the front: the arc (relative to the enemy axis) covering every bin with >= FRONT_SHARE of the busiest one's traffic, the axis bin always
    function a.Front()
        local ax, az
        if o.axis then ax, az = o.axis() end                       -- (a proxy: spot -> the enemy's build power)
        if not ax and MM and MM.Ready and MM.Ready() then ax, az = MM.Axis() end
        ax, az = ax or 1, az or 0
        local axis = Angle(ax, az)
        local w, top = {}, 0
        for i = 1, C.BINS do top = math.max(top, bins[i]) end
        -- the axis prior: the front faces the enemy until traffic says otherwise
        for i = 1, C.BINS do w[i] = bins[i] + C.PRIOR * math.max(1, top) * math.max(0, math.cos(Wrap(BinAngle(i) - axis))) end
        local wmax = 0
        for i = 1, C.BINS do wmax = math.max(wmax, w[i]) end
        local amin, amax = 0, 0
        for i = 1, C.BINS do
            if w[i] >= C.FRONT_SHARE * wmax then
                local rel = Wrap(BinAngle(i) - axis)
                amin, amax = math.min(amin, rel - math.pi / C.BINS), math.max(amax, rel + math.pi / C.BINS)
            end
        end
        return { amin = axis + amin, amax = axis + amax, axis = axis, w = w }
    end

    -- traffic of the bin at angle ang (walls: which posts come first)
    function a.Traffic(ang) return bins[Bin(ang)] end

    return a
end

return M
