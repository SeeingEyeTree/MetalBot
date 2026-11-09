-- bar_framework/proxy/t3_block.lua  (the proxy's T3 lab with its nanos: where they go -- user 2026-11-08)
-- User: "I also want to add in a t3 lab, with 104 nanos, it just builds Behemoth (corjugg) that move commands towards the enemy base.  The idea here is we
-- have the position to start spending and fortifying quickly by adding bp.  I added the lab blue print."  The layout is the user's blueprint
-- (blueprints/general/t3_lab.lua: the T3 lab with 96 nanos round it).  Its only open side is +x, so that is the lab's exit (facing 1); the block is
-- turned so the exit faces the enemy (the Behemoths walk out toward it).
--
--   local T3B = VFS.Include("LuaUI/Widgets/bar_framework/proxy/t3_block.lua")
--   T3B.Place(S, labDef, nanoDef, clear) -> { x, z, facing, nanos = { {x, z}, ... } } | nil   (clear(x, z, r) -> bool: nothing of ours planned there)

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = {}

M.R = 420            -- the block's footprint radius (lab + nanos, the blueprint reaches 264 on each axis)
M.D = 900            -- tried this far from the proxy lab

local layout
local function Layout()
    if layout then return layout end
    local ok, bp = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/t3_lab.lua")
    layout = { nanos = {} }
    if ok and bp and bp.layout then
        for _, e in ipairs(bp.layout) do
            if e.n == ROLES.Get("nano") then layout.nanos[#layout.nanos + 1] = { e.x, e.z } end
        end
    else
        Spring.Echo("[PROXY] t3 block: blueprints/general/t3_lab.lua not found: " .. tostring(bp))
    end
    return layout
end

-- one quarter turn: facing f -> f + 1 (south (0, 1) -> east (1, 0) -> north (0, -1) -> west (-1, 0))
local function Rot(x, z, k)
    for _ = 1, k % 4 do x, z = z, -x end
    return x, z
end

function M.Place(S, labDef, nanoDef, clear)
    local L = Layout()
    if not (labDef and nanoDef and #L.nanos > 0) then return nil end
    local ax, az = S.ax or 1, S.az or 0
    -- the exit (facing) that points most at the enemy
    local dirs = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }
    local facing, best = 1, -2
    for f = 0, 3 do local d = dirs[f][1] * ax + dirs[f][2] * az; if d > best then facing, best = f, d end end
    local k = (facing - 1) % 4
    local px, pz = -az, ax
    local cands = {}
    for _, c in ipairs({ { -1, 0 }, { -0.7, 0.7 }, { -0.7, -0.7 }, { 0, 1 }, { 0, -1 } }) do
        for _, d in ipairs({ M.D, M.D + 450, M.D + 900, M.D + 1350, M.D + 1800 }) do      -- (eco_sim 2026-11-08: out to 1900 there was no room for a second one)
            cands[#cands + 1] = { S.x + (ax * c[1] + px * c[2]) * d, S.z + (az * c[1] + pz * c[2]) * d }
        end
    end
    for _, c in ipairs(cands) do
        -- (on the 16-elmo build grid: the blueprint's offsets are 8 mod 16, so every nano then snaps where it is meant to -- eco_sim 2026-11-08, an
        -- unsnapped centre left 42 of 96 spots overlapping their neighbours)
        local cx, cz = math.floor(c[1] / 16 + 0.5) * 16, math.floor(c[2] / 16 + 0.5) * 16
        if cx > M.R and cz > M.R and cx < Game.mapSizeX - M.R and cz < Game.mapSizeZ - M.R and clear(cx, cz, M.R) then
            local y = Spring.GetGroundHeight(cx, cz) or 0
            if (Spring.TestBuildOrder(labDef.id, cx, y, cz, facing) or 0) > 0 then
                local nanos, good = {}, 0
                for _, n in ipairs(L.nanos) do
                    local dx, dz = Rot(n[1], n[2], k)
                    local x, z = cx + dx, cz + dz
                    if (Spring.TestBuildOrder(nanoDef.id, x, Spring.GetGroundHeight(x, z) or 0, z, 0) or 0) > 0 then good = good + 1 end
                    nanos[#nanos + 1] = { x = x, z = z }
                end
                if good >= 0.85 * #nanos then return { x = cx, z = cz, facing = facing, nanos = nanos } end
            end
        end
    end
    return nil
end

return M
