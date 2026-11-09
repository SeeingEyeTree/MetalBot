-- bar_framework/proxy/lrpc_block.lua  (the proxy's Basilisk / Calamity blocks: where they go -- user 2026-11-08)
-- User: "For building the lrpcs I want to do blocks of 64 nanos and then calamities after.  You would only start building calamities after the first ~15
-- Basilisk ... This is the nano block is the main thing that should be protected."  Then (same day, with a picture): "You have two blocks and you can
-- build the starting Basilisk on the edges but then fill in the squares between with Calamities."
-- A block is a 2 x 2 square of quadrants, each Q (384) wide (the picture): two 8 x 8 nano squares on one diagonal, two 3 x 3 Calamity squares on the
-- other; the Basilisks stand round the outside of the whole square, the sides away from the enemy first.  Every offset is on the 16-elmo build grid
-- for a centre that is (nanos and Basilisks at 8 mod 16, Calamities at 0 mod 16), so nothing snaps onto its neighbour.  Blocks go beside the proxy
-- lab, across the enemy axis (the guns keep their reach, 4950 / 6100), the next ones further along that side.
--
--   local LB = VFS.Include("LuaUI/Widgets/bar_framework/proxy/lrpc_block.lua")
--   LB.Nanos(cx, cz) -> { {x, z}, ... } (128)     LB.Calamities(cx, cz) -> { {x, z}, ... } (18)
--   LB.Basilisks(cx, cz, ax, az) -> { {x, z}, ... } (round the edge, away from the enemy (ax, az) first)
--   LB.Centre(S, i, ok) -> x, z | nil   the i-th block's centre (ok(x, z) -> bool: buildable and clear)

local M = {}

M.Q       = 384                                 -- a quadrant: 8 nanos of 48, or 3 Calamities of 128
M.EDGE    = 440                                 -- the Basilisk ring: this far from the centre lines (a Basilisk is 80 wide)
M.STEP    = 96                                  -- ... and this far apart along it
M.R       = 640                                 -- a block's whole footprint: keep other things out of it
M.BLOCK_D = 1150                                -- the first block's centre from the lab
M.NEXT_D  = 1400                                -- the next ones along the same line
M.HALF    = M.Q                                 -- (for callers: the nano squares reach this far from the centre)

-- the two nano squares: top-left (-Q..0, -Q..0) and bottom-right (0..Q, 0..Q)
function M.Nanos(cx, cz)
    local out = {}
    for _, q in ipairs({ { -1, -1 }, { 1, 1 } }) do
        for i = 0, 7 do
            for j = 0, 7 do
                local ox = (q[1] < 0) and (-M.Q + 24 + i * 48) or (24 + i * 48)
                local oz = (q[2] < 0) and (-M.Q + 24 + j * 48) or (24 + j * 48)
                out[#out + 1] = { x = cx + ox, z = cz + oz }
            end
        end
    end
    return out
end

-- the two Calamity squares: top-right (0..Q, -Q..0) and bottom-left (-Q..0, 0..Q), 3 x 3 each
function M.Calamities(cx, cz)
    local out = {}
    for _, q in ipairs({ { 1, -1 }, { -1, 1 } }) do
        for i = 0, 2 do
            for j = 0, 2 do
                out[#out + 1] = { x = cx + q[1] * (64 + i * 128), z = cz + q[2] * (64 + j * 128) }
            end
        end
    end
    return out
end

-- the Basilisk ring round the outside, the sides facing away from the enemy (ax, az) first
function M.Basilisks(cx, cz, ax, az)
    local sides = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    table.sort(sides, function(a, b) return a[1] * ax + a[2] * az < b[1] * ax + b[2] * az end)
    local out = {}
    for _, s in ipairs(sides) do
        local px, pz = -s[2], s[1]
        for t = -M.Q + 40, M.Q - 40, M.STEP do
            out[#out + 1] = { x = cx + s[1] * M.EDGE + px * t, z = cz + s[2] * M.EDGE + pz * t }
        end
    end
    return out
end

-- the i-th block's centre: BLOCK_D beside the lab across the enemy axis (the side that has room), then NEXT_D further along that line; behind the lab as
-- a last resort.  On the 16-elmo build grid.
function M.Centre(S, i, ok)
    local ax, az = S.ax or 1, S.az or 0
    local px, pz = -az, ax
    local cands = {}
    for _, side in ipairs({ 1, -1 }) do
        for _, back in ipairs({ 0.15, 0.5 }) do
            local d = M.BLOCK_D + (i - 1) * M.NEXT_D
            cands[#cands + 1] = { S.x + side * px * d - ax * M.BLOCK_D * back, S.z + side * pz * d - az * M.BLOCK_D * back }
        end
    end
    for k = 1, 3 do
        local d = M.BLOCK_D + (i - 1 + k - 1) * M.NEXT_D
        cands[#cands + 1] = { S.x - ax * d, S.z - az * d }
    end
    for _, c in ipairs(cands) do
        local x, z = math.floor(c[1] / 16 + 0.5) * 16, math.floor(c[2] / 16 + 0.5) * 16
        if x > M.R and z > M.R and x < Game.mapSizeX - M.R and z < Game.mapSizeZ - M.R and ok(x, z) then return x, z end
    end
    return nil
end

return M
