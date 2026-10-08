-- tests/test_slot_tile.lua
-- Run from the repo root:  lua5.1 tests/test_slot_tile.lua        (or through lupa, see LUA_TESTING.md)
--
-- Geometry of the slot block (bar_framework/slot_crew.lua) with the blueprint editor's footprints
-- (buildings.json), for several spawns on two map sizes:
--   * the commander tile + every slot filled with a mex (the worst case) + every nano spot: no two
--     buildings overlap, all of it inside BlockBounds and inside the map;
--   * every slot also holds a wind (3x3) without touching its neighbours;
--   * the con lanes (3 cells wide) are open end to end, the bot lab's exit corridor is clear, and
--     the nano row keeps a 3-cell crossing between lane A and lane B;
--   * every slot and nano spot is inside build range (128 + the margin the crew uses) of a lane stop
--     of its own strip;
--   * GridCells cover the block, EndCells lie outside it, strips grow away from the commander tile.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end

local SC  = VFS.Include("LuaUI/Widgets/bar_framework/slot_crew.lua")
local COM = VFS.Include("LuaUI/Widgets/blueprints/general/bad_com_start.lua")

local SIZE = { cormex = {4, 4}, corwin = {3, 3}, cornanotc = {3, 3}, corlab = {6, 6}, corrad = {2, 2} }

local function Box(name, x, z, f)
    local s = assert(SIZE[name], "no size for " .. name)
    local w, h = s[1] * 16, s[2] * 16
    if f == 1 or f == 3 then w, h = h, w end
    return { n = name, x0 = x - w / 2, x1 = x + w / 2, z0 = z - h / 2, z1 = z + h / 2 }
end
local function Overlap(a, b) return a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1 end

-- A local-frame rectangle (u0..u1, v0..v1) as a world axis-aligned box.
local function LocalBox(L, u0, u1, v0, v1)
    local xs, zs = {}, {}
    for _, c in ipairs({ { u0, v0 }, { u0, v1 }, { u1, v0 }, { u1, v1 } }) do
        local x, z = SC.World(L, c[1], c[2])
        xs[#xs + 1], zs[#zs + 1] = x, z
    end
    return { x0 = math.min(unpack(xs)), x1 = math.max(unpack(xs)),
             z0 = math.min(unpack(zs)), z1 = math.max(unpack(zs)) }
end

local function ComBoxes(L)
    local boxes = {}
    for _, u in ipairs(COM.layout) do
        local rx, rz = SC.Rotate(u.x, u.z, L.rot)
        boxes[#boxes + 1] = Box(u.n, L.anchorX + rx, L.anchorZ + rz, (u.f - L.rot) % 4)
    end
    return boxes
end

local function ClashList(boxes)
    for i = 1, #boxes do
        for j = i + 1, #boxes do
            if Overlap(boxes[i], boxes[j]) then return boxes[i].n .. " / " .. boxes[j].n end
        end
    end
    return nil
end

local REACH = 128 + SC.FOOT_HALF - 8     -- what slot_crew's ReachOf gives a con bot (buildDistance 128)

local maps = {
    { 8192,  { {1500, 1500}, {6700, 1500}, {1500, 6700}, {6700, 6700}, {4096, 600}, {600, 4096} } },
    { 12288, { {3069, 5908}, {9219, 6380}, {3000, 2000}, {9000, 10000}, {6000, 900} } },
}
for _, m in ipairs(maps) do
    local size = m[1]
    for _, sp in ipairs(m[2]) do
        local L = SC.Layout(sp[1], sp[2], size, size)
        local tag = string.format(" (map %d spawn %d,%d)", size, sp[1], sp[2])
        check(#L.slots == 16 * SC.STRIPS_X * SC.STRIPS_Z, "slot count" .. tag)
        check(#L.nanos == 4 * SC.STRIPS_X * SC.STRIPS_Z, "nano spot count" .. tag)

        -- 1. nothing overlaps, with every slot a mex.
        local fixed = ComBoxes(L)
        local boxes = {}
        for _, b in ipairs(fixed) do boxes[#boxes + 1] = b end
        for _, s in ipairs(L.slots) do boxes[#boxes + 1] = Box("cormex", s.wx, s.wz, 0) end
        for _, s in ipairs(L.nanos) do boxes[#boxes + 1] = Box("cornanotc", s.wx, s.wz, 0) end
        local clash = ClashList(boxes)
        check(clash == nil, "no overlapping buildings (all slots mex)" .. tag .. (clash and (": " .. clash) or ""))

        -- 2. every slot as a wind: inside its slot cell (64 x 64), so it cannot reach a neighbour.
        local winds = {}
        for _, s in ipairs(L.slots) do winds[#winds + 1] = Box("corwin", s.wx, s.wz, 0) end
        check(ClashList(winds) == nil, "winds in every slot do not overlap" .. tag)

        -- 3. inside the block bounds and the map.
        local minX, maxX, minZ, maxZ = SC.BlockBounds(L)
        local inside = true
        for _, b in ipairs(boxes) do
            if b.x0 < minX - 0.5 or b.x1 > maxX + 0.5 or b.z0 < minZ - 0.5 or b.z1 > maxZ + 0.5 then inside = false end
        end
        check(inside, "every building inside BlockBounds" .. tag)
        check(minX > 0 and minZ > 0 and maxX < size and maxZ < size, "block inside the map" .. tag)

        -- 4. lanes open end to end; lab exit corridor; crossing in the nano row.
        local obstacles = boxes
        for _, strip in ipairs(L.strips) do
            for lane = 1, 2 do
                local vc = strip.stops[(lane == 1) and 1 or 3].v
                local lb = LocalBox(L, strip.u0, strip.u0 + SC.STRIP_W, vc - 24, vc + 24)
                local blocked
                for _, b in ipairs(obstacles) do if Overlap(lb, b) then blocked = b.n end end
                check(blocked == nil, string.format("strip %d lane %d is open end to end%s%s", strip.idx, lane, tag,
                      blocked and (" (hits " .. blocked .. ")") or ""))
            end
            local nv = strip.nanos[1].v
            local cross = LocalBox(L, strip.u0 + 96, strip.u0 + 144, nv - 24, nv + 24)
            local hit
            for _, b in ipairs(obstacles) do if Overlap(cross, b) then hit = b.n end end
            check(hit == nil, "nano row keeps a 3-cell crossing, strip " .. strip.idx .. tag)
        end
        local lab = LocalBox(L, 96, SC.U0 + SC.STRIP_W * SC.STRIPS_X, SC.LAB_LANE_V - 24, SC.LAB_LANE_V + 24)
        local labHit
        for _, b in ipairs(obstacles) do if Overlap(lab, b) then labHit = b.n end end
        check(labHit == nil, "bot lab's exit corridor (local z 80) is clear to the far end" .. tag
              .. (labHit and (": " .. labHit) or ""))

        -- 5. reach: every slot and nano spot inside build range of a stop of its own strip.
        local worst = 0
        for _, s in ipairs(L.all) do
            local strip = L.strips[s.strip]
            local best = math.huge
            for _, st in ipairs(strip.stops) do
                local d = math.sqrt((s.wx - st.wx) ^ 2 + (s.wz - st.wz) ^ 2)
                if d < best then best = d end
            end
            worst = math.max(worst, best)
            if best > REACH then
                check(false, string.format("%s at (%.0f, %.0f) is %.0f from the nearest stop (reach %d)%s",
                      s.kind, s.wx, s.wz, best, REACH, tag))
                break
            end
        end
        check(worst <= REACH, string.format("all slots in reach, worst %.0f <= %d%s", worst, REACH, tag))

        -- 6. lattice: cells cover the block (2 x 2 for two strips each way), end cells are outside it.
        local cells = SC.GridCells(L)
        check(#cells == 4, "block fills 2 x 2 lattice cells" .. tag)
        for _, e in ipairs(SC.EndCells(L)) do
            check(not SC.InBlock(L, e.anchorX, e.anchorZ, 200), "end cell outside the block" .. tag)
        end

        -- 7. strips grow away from the commander tile, along the rows' direction.
        local s1, s2 = L.strips[1], L.strips[#L.strips]
        local ax, az = SC.World(L, s1.u0, s1.vStart)
        local bx, bz = SC.World(L, s2.u0, s2.vStart)
        local rowDot = (bx - ax) * L.rowVec.x + (bz - az) * L.rowVec.z
        check(SC.STRIPS_Z == 1 or rowDot > 0, "second strip row lies further along the rows" .. tag)

        -- 8. the lines extend a row at a time until the map edge; nothing overlaps, everything stays on the map.
        local L2 = SC.Layout(sp[1], sp[2], size, size)
        local added = 0
        while added < 40 and SC.AddStripRow(L2, L2.nextJ) do added = added + 1 end
        check(added < 40, "the lines stop before running off the map" .. tag)
        local boxes2 = ComBoxes(L2)
        for _, s in ipairs(L2.slots) do boxes2[#boxes2 + 1] = Box("cormex", s.wx, s.wz, 0) end
        for _, s in ipairs(L2.nanos) do boxes2[#boxes2 + 1] = Box("cornanotc", s.wx, s.wz, 0) end
        local clash2 = ClashList(boxes2)
        check(clash2 == nil, string.format("extended lines (%d extra rows) do not overlap%s%s", added, tag,
              clash2 and (": " .. clash2) or ""))
        local onMap = true
        for _, b in ipairs(boxes2) do
            if b.x0 < 0 or b.z0 < 0 or b.x1 > size or b.z1 > size then onMap = false end
        end
        check(onMap, "extended lines stay on the map" .. tag)
        local openL2 = true
        for _, strip in ipairs(L2.strips) do
            for lane = 1, 2 do
                local vc = strip.stops[(lane == 1) and 1 or 3].v
                local lb = LocalBox(L2, strip.u0, strip.u0 + SC.STRIP_W, vc - 24, vc + 24)
                for _, b in ipairs(boxes2) do if Overlap(lb, b) then openL2 = false end end
            end
        end
        check(openL2, "every lane of the extended lines is open" .. tag)

        -- 9. the air lab fits on its 6 reserved big slots without touching anything else.
        local crew = SC.NewCrew{ BP = {}, layout = L, expand = false }
        local lx, lz = SC.ReserveLab(crew, L.anchorX, L.anchorZ)
        check(lx ~= nil and #crew.labSlots == 6, "air lab reserves 6 slots" .. tag)
        if lx then
            local su, sv = 0, 0
            for _, s in ipairs(crew.labSlots) do su, sv = su + s.u, sv + s.v end
            local uc, vc = su / 6, sv / 6
            local labBox = LocalBox(L, uc - 72, uc + 72, vc - 48, vc + 48)   -- corap 9 x 6 cells, long side along u
            local reserved = {}
            for _, s in ipairs(crew.labSlots) do reserved[s] = true end
            local others = ComBoxes(L)
            for _, s in ipairs(L.slots) do
                if not reserved[s] then others[#others + 1] = Box("cormex", s.wx, s.wz, 0) end
            end
            for _, s in ipairs(L.nanos) do others[#others + 1] = Box("cornanotc", s.wx, s.wz, 0) end
            local hit
            for _, b in ipairs(others) do if Overlap(labBox, b) then hit = b.n end end
            check(hit == nil, "air lab clears everything outside its slots" .. tag .. (hit and (": " .. hit) or ""))
            local lane = LocalBox(L, L.strips[1].u0, L.strips[1].u0 + SC.STRIP_W,
                                  L.strips[crew.labSlots[1].strip].stops[1].v - 24,
                                  L.strips[crew.labSlots[1].strip].stops[1].v + 24)
            check(not Overlap(labBox, lane), "air lab leaves lane A free" .. tag)
        end

        -- 10. lanes: one builder each, the commander on the other side of the first con's strip, and the lab bay
        --     kept free from the moment the commander joins; the lab then goes in that bay.
        local L3 = SC.Layout(sp[1], sp[2], size, size)
        local crew3 = SC.NewCrew{ BP = {}, layout = L3, expand = false, expectCommander = true, labBay = true }
        SC.AddCon(crew3, 1001); SC.AddCommander(crew3, 1002); SC.AddCon(crew3, 1003); SC.AddCon(crew3, 1004)
        local seen, distinct = {}, true
        for _, c in pairs(crew3.cons) do
            if seen[c.lane] then distinct = false end
            seen[c.lane] = true
        end
        check(distinct, "no two builders share a lane" .. tag)
        local a, b = crew3.cons[1001].lane, crew3.cons[1002].lane
        check(a.strip.idx == 1 and b.strip.idx == 1 and a.side ~= b.side,
              "the commander takes the other side of the first con's strip" .. tag)
        check(crew3.cons[1003].lane.strip.idx ~= 1 and crew3.cons[1004].lane.strip.idx ~= 1,
              "later cons take the lanes of the next strips" .. tag)
        check(crew3.bay ~= nil and #crew3.bay == 6, "lab bay reserved when the commander joined" .. tag)
        local bx, bz = SC.ReserveLab(crew3, L3.anchorX, L3.anchorZ)
        check(bx ~= nil and crew3.labSlots == crew3.bay, "the lab uses the reserved bay" .. tag)
        if bx then
            local su, sv = 0, 0
            for _, s in ipairs(crew3.bay) do su, sv = su + s.u, sv + s.v end
            local uc, vc = su / 6, sv / 6
            local labBox = LocalBox(L3, uc - 72, uc + 72, vc - 48, vc + 48)
            local inBay = {}
            for _, s in ipairs(crew3.bay) do inBay[s] = true end
            local others = ComBoxes(L3)
            for _, s in ipairs(L3.slots) do
                if not inBay[s] then others[#others + 1] = Box("cormex", s.wx, s.wz, 0) end
            end
            for _, s in ipairs(L3.nanos) do others[#others + 1] = Box("cornanotc", s.wx, s.wz, 0) end
            local hit
            for _, bb in ipairs(others) do if Overlap(labBox, bb) then hit = bb.n end end
            check(hit == nil, "the lab fits its bay" .. tag .. (hit and (": " .. hit) or ""))
            -- the bay is on the commander's own side of the strip (rows next to its lane)
            check(crew3.bay[1].lane == b.side and crew3.bay[1].strip == b.strip.idx,
                  "the bay is on the commander's side" .. tag)
        end
    end
end

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then error("test_slot_tile: " .. failures .. " failure(s)") end
