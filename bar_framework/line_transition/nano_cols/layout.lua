-- bar_framework/line_transition/nano_cols/layout.lua
-- Geometry of the nano-column block (user 2026-10-30): building columns B and nano columns N side by side, B N B N B N B
-- (NC nano columns, NC + 1 building columns; a nano column is shared by the building columns on both sides of it).
-- Pure geometry: no Spring calls.  Two local axes:
--   a  along the columns (the fronts grow in +a and -a from the origin row), world = u * a
--   c  across the columns, 0 at the edge next to the line and growing away from it, world = v * c
-- Sizes (elmos, from the unit defs): building column 320 wide = 5 mexes (64) = 4 fusions (80); 6 winds (288) or 3 AFUS (288) sit
-- centred in it.  Nano column 144 = 3 nanos (48).  A BLOCK is one 192-tall cell of a building column: 6x4 winds, 5x3 mexes / mohos,
-- 4x2 fusions (160 tall), 3x2 AFUS, or one T2 air lab (144x144).  Block row r spans a = 192 r +- 96; nano row q (48 tall) sits at
-- a = 48 q - 72, so block row r holds nano rows 4r .. 4r + 3.  Every nano of a nano column reaches the whole width of both building
-- columns beside it (the far mex centre is 360 from the column centre, reach 400 + 32).
-- Offsets keep every centre on the engine's build grid (16 elmos; +8 for 48 / 80 / 144-wide footprints) when the origin is a multiple of 16.

local M = {}

M.BW, M.NW, M.ROW_H, M.NANO_H = 320, 144, 192, 48
M.PITCH = M.BW + M.NW            -- 464: one building column + one nano column

-- item offsets inside a block (dc from the building column's near edge, da from the block row's centre); n = roles.lua role
local SPEC = {}
do
    local function grid(role, dcs, das)
        local out = {}
        for _, da in ipairs(das) do for _, dc in ipairs(dcs) do out[#out + 1] = { role = role, dc = dc, da = da } end end
        return out
    end
    SPEC.mex  = grid("mex",    { 32, 96, 160, 224, 288 }, { -64, 0, 64 })
    SPEC.moho = grid("moho",   { 32, 96, 160, 224, 288 }, { -64, 0, 64 })
    SPEC.wind = grid("wind",   { 40, 88, 136, 184, 232, 280 }, { -72, -24, 24, 72 })
    SPEC.fusion = grid("fusion", { 40, 120, 200, 280 }, { -40, 40 })
    SPEC.afus = grid("afus",   { 64, 160, 256 }, { -48, 48 })
    SPEC.lab  = { { role = "lab_t2_air", dc = 168, da = 8 } }
    SPEC.airlab = { { role = "lab_t1_air", dc = 160, da = 0 } }     -- a T1 air lab (144 x 96) when the line's is lost (nano_cols/recovery.lua)
end
M.SPEC = SPEC
M.UNITS = { mex = 15, moho = 15, wind = 24, fusion = 8, afus = 6, lab = 1, airlab = 1 }

-- o = { ox, oz (world point of a = 0, c = 0), ux, uz (unit vector of +a), vx, vz (unit vector of +c), nc, mapX, mapZ, margin }
function M.New(o)
    local L = { ox = o.ox, oz = o.oz, ux = o.ux, uz = o.uz, vx = o.vx, vz = o.vz, nc = o.nc, nb = o.nc + 1,
                mapX = o.mapX, mapZ = o.mapZ, margin = o.margin or 96 }
    L.width = L.nb * M.BW + L.nc * M.NW
    function L.World(a, c) return L.ox + L.ux * a + L.vx * c, L.oz + L.uz * a + L.vz * c end
    function L.BC0(j) return j * M.PITCH end                  -- building column j (0 .. nb-1): near edge
    function L.NC0(i) return i * M.PITCH + M.BW end           -- nano column i (0 .. nc-1): near edge
    function L.RowA(r) return M.ROW_H * r end                 -- block row centre
    function L.NanoA(q) return M.NANO_H * q - 72 end          -- nano row centre
    function L.RowOfNano(q) return math.floor(q / 4) end
    -- a world rectangle given in local terms is inside the map (with the margin)
    function L.InMap(a0, a1, c0, c1)
        for _, a in ipairs({ a0, a1 }) do
            for _, c in ipairs({ c0, c1 }) do
                local x, z = L.World(a, c)
                if x < L.margin or z < L.margin or x > L.mapX - L.margin or z > L.mapZ - L.margin then return false end
            end
        end
        return true
    end
    function L.RowFits(r) local a = L.RowA(r); return L.InMap(a - 96, a + 96, 0, L.width) end
    -- the items of a block (world positions), kind = mex | moho | wind | fusion | afus | lab
    function L.BlockItems(kind, j, r)
        local out, c0, a0 = {}, L.BC0(j), L.RowA(r)
        for _, s in ipairs(SPEC[kind] or {}) do
            local x, z = L.World(a0 + s.da, c0 + s.dc)
            out[#out + 1] = { role = s.role, x = x, z = z, a = a0 + s.da, c = c0 + s.dc }
        end
        return out
    end
    function L.BlockCenter(j, r) return L.World(L.RowA(r), L.BC0(j) + M.BW / 2) end
    -- the 3 nanos of nano row q in nano column i
    function L.NanoItems(i, q)
        local out, c0, a = {}, L.NC0(i), L.NanoA(q)
        for k = 0, 2 do
            local x, z = L.World(a, c0 + 24 + 48 * k)
            out[#out + 1] = { role = "nano", x = x, z = z, a = a, c = c0 + 24 + 48 * k }
        end
        return out
    end
    -- which blocks a nano at local (a, c) reaches at all (any item centre of the block within reach): list of { j, r }
    function L.BlocksInReach(a, c, reach)
        local out = {}
        for j = 0, L.nb - 1 do
            local c0, c1 = L.BC0(j) + 32, L.BC0(j) + 288
            local dc = (c < c0) and (c0 - c) or ((c > c1) and (c - c1) or 0)
            if dc <= reach then
                local r0 = L.RowOfNano(math.floor((a + 72) / M.NANO_H))
                for r = r0 - 3, r0 + 3 do
                    local a0, a1 = L.RowA(r) - 72, L.RowA(r) + 72
                    local da = (a < a0) and (a0 - a) or ((a > a1) and (a - a1) or 0)
                    if da * da + dc * dc <= reach * reach then out[#out + 1] = { j = j, r = r } end
                end
            end
        end
        return out
    end
    -- local coordinates of a world point (inverse of World; the axes are +-1 / 0)
    function L.Local(x, z)
        local dx, dz = x - L.ox, z - L.oz
        return dx * L.ux + dz * L.uz, dx * L.vx + dz * L.vz
    end
    -- the column a local c falls in: "B", j  /  "N", i  /  nil (outside)
    function L.ColumnAt(c)
        if c < 0 or c > L.width then return nil end
        local k = math.floor(c / M.PITCH)
        local rem = c - k * M.PITCH
        if rem < M.BW then return "B", k end
        return "N", k
    end
    return L
end

return M
