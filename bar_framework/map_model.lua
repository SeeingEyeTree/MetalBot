-- bar_framework/map_model.lua
-- Map geometry expressed relative to our base and the enemy's, for every widget
-- that needs to know "where is forward" or "is this our half".
--
-- WHY THIS EXISTS
-- ---------------
-- Three separate problems, all the same missing primitive:
--
--   1. `Game.mapSizeX or 8192` appears ~20 times across the repo.  This map is
--      ~12k, so every one of those fallbacks is wrong by 4000 elmos if it ever
--      fires.  Here it fires once, loudly, instead of silently everywhere.
--   2. macro_controller hardcodes west/south/north expansion, so from the
--      bottom-right spawn it expands into the contested middle.  Directions have
--      to be derived from where the enemy actually is, not from compass points.
--   3. Arrival times measured in one match are travel-time dependent.  The
--      recorded spawns are ~12,800 elmos apart (about as far as this map allows);
--      spawns in line with each other are ~10,560 apart, so the same attack lands
--      ~18% sooner.  A defence deadline copied from a run as a frame number is
--      therefore wrong on most spawns.  Store the spawn-independent part (how long
--      the attacker spends building) and add TravelFrames() for the rest.
--
-- USAGE
--   local MM = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
--   MM.Init(myTeamID, myAllyID)
--   MM.SetHome(x, z)                  -- commander spawn, once known
--   MM.SetFoe(x, z, "sighted")        -- upgrade the guess when scouts find them
--   local fx, fz = MM.Foe()
--   if MM.IsOurHalf(ex, ez) then ... end
--   local deadline = buildComplete + MM.TravelFrames(UnitDefs[d].speed)

local M = {}

local FRAMES_PER_SEC = 30

local myTeamID, myAllyID
local mapX, mapZ
local homeX, homeZ
local foeX, foeZ
local foeSource   = nil    -- "start_pos" | "mirror" | "sighted"
local axisX, axisZ = 0, 0  -- normalised home -> foe
local perpX, perpZ = 0, 0
local axisDist     = 0

-- ── Init ──────────────────────────────────────────────────────────────────────

function M.Init(teamID, allyID)
    myTeamID, myAllyID = teamID, allyID
    mapX, mapZ = Game.mapSizeX, Game.mapSizeZ
    if not mapX or not mapZ then
        -- Do not paper over this with 8192: on this map that is a 4000-elmo lie
        -- and every derived distance inherits it.
        Spring.Echo("[MM] WARN Game.mapSizeX/Z unavailable; geometry will be wrong")
        mapX, mapZ = mapX or 8192, mapZ or 8192
    end
end

function M.MapSize() return mapX, mapZ end

-- ── Anchors ───────────────────────────────────────────────────────────────────

-- Recompute the axis whenever either anchor moves.
local function Recompute()
    if not (homeX and foeX) then return end
    local dx, dz = foeX - homeX, foeZ - homeZ
    local d = math.sqrt(dx * dx + dz * dz)
    if d < 1 then return end
    axisDist = d
    axisX, axisZ = dx / d, dz / d
    perpX, perpZ = -axisZ, axisX
end

-- Resolve the enemy anchor.  Start positions are usually not readable for an
-- enemy team, so the symmetric-map mirror is the working assumption until a scout
-- corrects it.  On this map spawns sit anywhere along a strip, so the mirror can
-- be well off ALONG that strip -- which is the whole reason scouting mode A exists.
local function ResolveFoe()
    if Spring.GetTeamStartPosition and Spring.GetTeamList and Spring.GetTeamInfo then
        for _, t in ipairs(Spring.GetTeamList() or {}) do
            if t ~= myTeamID then
                local _, _, _, _, _, allyID = Spring.GetTeamInfo(t)
                if allyID ~= myAllyID then
                    local x, _, z = Spring.GetTeamStartPosition(t)
                    if x and x > 0 and z and z > 0 then return x, z, "start_pos" end
                end
            end
        end
    end
    if homeX then return mapX - homeX, mapZ - homeZ, "mirror" end
    return nil, nil, nil
end

function M.SetHome(x, z)
    if not x then return end
    homeX, homeZ = x, z
    if not foeX then
        local fx, fz, src = ResolveFoe()
        if fx then foeX, foeZ, foeSource = fx, fz, src end
    end
    Recompute()
    Spring.Echo(string.format(
        "[MM] map %dx%d home %d,%d foe %d,%d (%s) dist %d",
        mapX, mapZ, homeX, homeZ, foeX or -1, foeZ or -1,
        foeSource or "unknown", axisDist))
end

-- A sighting beats a guess; a guess never overwrites a sighting.
function M.SetFoe(x, z, source)
    if not x then return end
    if foeSource == "sighted" and source ~= "sighted" then return end
    foeX, foeZ, foeSource = x, z, source or "sighted"
    Recompute()
    Spring.Echo(string.format("[MM] foe -> %d,%d (%s) dist %d",
        foeX, foeZ, foeSource, axisDist))
end

-- ── Base footprint (user 2026-10-28) ──────────────────────────────────────────
-- Home is the commander's spawn and never moves, so everything measured from it fires late once the eco grows away from the
-- spawn.  The BASE is where our eco / production structures actually stand: SetBase takes a flat {x1,z1,x2,z2,...} list (the
-- owner refreshes it every ~120 frames), BaseDist(x,z) is the distance to the nearest of them (0 inside the footprint).
-- Axis, Forward, IsOurHalf and Dist() still use the spawn.
local BASE_CELL = 256
local basePts, baseN = {}, 0
local baseCx, baseCz, baseR = nil, nil, 0
local baseCache = {}     -- [cell key] = distance from the cell centre to the nearest base structure (rebuilt with the points)

function M.SetBase(pts)
    basePts, baseN, baseCache = pts or {}, math.floor(#(pts or {}) / 2), {}
    if baseN == 0 then baseCx, baseCz, baseR = nil, nil, 0; return end
    local sx, sz = 0, 0
    for i = 1, baseN do sx, sz = sx + basePts[2 * i - 1], sz + basePts[2 * i] end
    baseCx, baseCz = sx / baseN, sz / baseN
    -- extent: the 90th percentile distance from the centre (a lone outlying mex does not stretch the base)
    local ds = {}
    for i = 1, baseN do
        local dx, dz = basePts[2 * i - 1] - baseCx, basePts[2 * i] - baseCz
        ds[i] = math.sqrt(dx * dx + dz * dz)
    end
    table.sort(ds)
    baseR = ds[math.max(1, math.ceil(baseN * 0.9))]
end

function M.BaseDist(x, z)
    if baseN == 0 then
        if not homeX then return 0 end
        local dx, dz = x - homeX, z - homeZ
        return math.sqrt(dx * dx + dz * dz)
    end
    local cx, cz = math.floor(x / BASE_CELL), math.floor(z / BASE_CELL)
    local key = cx * 100003 + cz
    local d = baseCache[key]
    if not d then
        local mx, mz = (cx + 0.5) * BASE_CELL, (cz + 0.5) * BASE_CELL
        local best = math.huge
        for i = 1, baseN do
            local dx, dz = basePts[2 * i - 1] - mx, basePts[2 * i] - mz
            local q = dx * dx + dz * dz
            if q < best then best = q end
        end
        d = math.sqrt(best)
        baseCache[key] = d
    end
    -- the cell value is from the centre: the real point is within half a cell, so take that off (never below 0)
    return math.max(0, d - BASE_CELL * 0.5)
end

function M.Base()
    if baseCx then return baseCx, baseCz end
    return homeX, homeZ
end
function M.BaseRadius() return baseR end

function M.Home()      return homeX, homeZ end
function M.Foe()       return foeX, foeZ end
function M.FoeSource() return foeSource end
function M.Axis()      return axisX, axisZ end
function M.Perp()      return perpX, perpZ end
function M.Dist()      return axisDist end
function M.Ready()     return homeX ~= nil and foeX ~= nil and axisDist > 0 end

function M.Mid()
    if not M.Ready() then return nil, nil end
    return (homeX + foeX) * 0.5, (homeZ + foeZ) * 0.5
end

-- ── Derived geometry ──────────────────────────────────────────────────────────

-- Distance along the home->foe axis.  0 at home, Dist() at the enemy.
function M.Forward(x, z)
    if not M.Ready() then return 0 end
    return (x - homeX) * axisX + (z - homeZ) * axisZ
end

-- Signed distance across the axis; sign follows Perp().
function M.Lateral(x, z)
    if not M.Ready() then return 0 end
    return (x - homeX) * perpX + (z - homeZ) * perpZ
end

-- The midline counts as ours.  The holding line sits exactly on it, so a strict
-- `<` puts our own front rank in "enemy territory" and makes every test that keys
-- off this flip with floating-point noise.
function M.IsOurHalf(x, z)
    if not M.Ready() then return true end
    return M.Forward(x, z) <= axisDist * 0.5 + 1
end

-- A point at (forward, lateral) in base-relative space.
function M.PointAt(forward, lateral)
    if not M.Ready() then return nil, nil end
    lateral = lateral or 0
    return homeX + axisX * forward + perpX * lateral,
           homeZ + axisZ * forward + perpZ * lateral
end

function M.Clamp(x, z, margin)
    margin = margin or 0
    return math.max(margin, math.min(mapX - margin, x)),
           math.max(margin, math.min(mapZ - margin, z))
end

function M.DistBetween(x1, z1, x2, z2)
    local dx, dz = x2 - x1, z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

-- ── Timing ────────────────────────────────────────────────────────────────────

-- Frames for a unit of `speed` (UnitDefs speed is elmos/second) to cross `dist`,
-- defaulting to the full home->foe distance.
--
-- This is the spawn-independent way to express "when does the attack land": pair
-- it with how long the attacker spent building, which does NOT vary with spawn
-- geometry.  Never hardcode an arrival frame taken from one match -- that match's
-- spawn distance is baked into it.
function M.TravelFrames(speed, dist)
    if not speed or speed <= 0 then return math.huge end
    return ((dist or axisDist) / speed) * FRAMES_PER_SEC
end

-- Given an arrival observed on a run whose spawns were `measuredDist` apart, what
-- is the build-time component -- the part that carries over to any spawn?
function M.BuildComponent(arrivalFrame, speed, measuredDist)
    return arrivalFrame - M.TravelFrames(speed, measuredDist)
end

-- ── Sector grid ───────────────────────────────────────────────────────────────

-- Sectors covering the map, each {x, z, lastScouted}.  `filter(x, z)` may reject
-- sectors so a caller can build an enemy-half-only grid.
--
-- Size defaults to a twelfth of the map diagonal rather than a fixed 1024: on a
-- 12k map a fixed 1024 is 144 sectors, which two scouts cannot service.
function M.BuildSectors(size, margin, filter)
    local diag = math.sqrt(mapX * mapX + mapZ * mapZ)
    size = size or math.max(768, diag / 12)
    margin = margin or 0
    local sectors, n = {}, 0
    for sx = 0, mapX - 1, size do
        for sz = 0, mapZ - 1, size do
            local cx, cz = sx + size * 0.5, sz + size * 0.5
            if cx >= margin and cx <= mapX - margin
               and cz >= margin and cz <= mapZ - margin
               and (not filter or filter(cx, cz)) then
                sectors[sx .. "_" .. sz] = { x = cx, z = cz, lastScouted = 0 }
                n = n + 1
            end
        end
    end
    return sectors, size, n
end

-- Which sector key contains this position, for a grid built at `size`.
function M.SectorKey(x, z, size)
    return (math.floor(x / size) * size) .. "_" .. (math.floor(z / size) * size)
end

return M
