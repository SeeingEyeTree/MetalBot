-- tests/test_perimeter_guard.lua: bar_framework/perimeter_guard.lua (DRAGON_ECO's defensive ring).
-- Run from the repo root: python tests/run_lua.py tests/test_perimeter_guard.lua
--   * Ring: each post is the far edge of the union of R-circles around our structures along its bearing; off-map posts are
--     dropped; a post goes at most MAX_FRAC of the way to the enemy base;
--   * Arcs / LineSlots: the posts joined in bearing order, slots evenly spaced along them; Clusters groups intruders;
--   * runtime: every defender gets its own slot spread along the line; the nearest answer an intruder inside the ring and go back,
--     one outside the leash is ignored;
--     pg.clusters lists the intruder groups inside the ring (the Dragons' dragon_defend reads it).
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local PG = VFS.Include("LuaUI/Widgets/bar_framework/perimeter_guard.lua")
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local MAP = 12288
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1) end

-- ── Ring ──────────────────────────────────────────────────────────────────────
local c, posts = PG.Ring({ { x = 6000, z = 6000 } }, 2800, 24, MAP, MAP)
check(#posts == 24, "one structure mid-map: 24 posts (" .. #posts .. ")")
local allR = true
for _, p in ipairs(posts) do if not near(p.r, 2800) then allR = false end end
check(allR and near(c.x, 6000) and near(c.z, 6000), "one structure: every post 2800 from it")

c, posts = PG.Ring({ { x = 5000, z = 6000 }, { x = 7000, z = 6000 } }, 2800, 24, MAP, MAP)
local byK = {}
for _, p in ipairs(posts) do byK[p.k] = p end
check(near(byK[1].r, 3800), "east: furthest building (1000 out) + 2800 = 3800 (" .. byK[1].r .. ")")
check(near(byK[7].r, math.sqrt(2800 ^ 2 - 1000 ^ 2)), "south: the circles' union edge at d = 1000 (" .. byK[7].r .. ")")
-- the post is on the edge: exactly R from the nearest building, and no building is closer than R to it
local onEdge = true
for _, p in ipairs(posts) do
    local dmin = math.huge
    for _, s in ipairs({ { 5000, 6000 }, { 7000, 6000 } }) do dmin = math.min(dmin, math.sqrt((p.x - s[1]) ^ 2 + (p.z - s[2]) ^ 2)) end
    if not near(dmin, 2800, 2) then onEdge = false end
end
check(onEdge, "every post is R from its nearest building")

c, posts = PG.Ring({ { x = 1500, z = 1500 } }, 2800, 24, MAP, MAP, nil, nil, nil, 150)
local inMap = true
for _, p in ipairs(posts) do if p.x < 150 or p.z < 150 then inMap = false end end
check(#posts > 0 and #posts < 24 and inMap, "corner base: off-map posts are dropped (" .. #posts .. " left)")

c, posts = PG.Ring({ { x = 6000, z = 6000 } }, 2800, 24, MAP, MAP, 9000, 6000, 0.45)
byK = {}
for _, p in ipairs(posts) do byK[p.k] = p end
check(near(byK[1].r, 0.45 * 3000), "toward the enemy the post is capped at 45% of the way (" .. byK[1].r .. ")")
check(near(byK[7].r, 2800), "across the enemy direction no cap")
check(near(c.eAng, 0), "enemy bearing is east")

-- ── PickRadius: R_MIN, pushed out while the defenders would stand denser than DENSITY_MAX ──────────────────────────
do
    local K = PG.CFG
    local one = { { x = 6000, z = 6000 } }
    local R0 = PG.PickRadius(one, 10, K, MAP, MAP)
    check(R0 == K.R_MIN, "few defenders: R_MIN (" .. R0 .. ")")
    local Rbig, _, pBig = PG.PickRadius(one, 300, K, MAP, MAP)
    local L = PG.RingLength(pBig, K.BEARINGS)
    check(Rbig > K.R_MIN and (300 <= K.DENSITY_MAX * L or Rbig == K.R_MAX),
          "300 defenders: the ring is pushed out until they fit (R " .. Rbig .. ", ring " .. math.floor(L) .. ")")
    local Rmore = PG.PickRadius(one, 600, K, MAP, MAP)
    check(Rmore >= Rbig and Rmore <= K.R_MAX, "more defenders: as far or further, never past R_MAX (" .. Rmore .. ")")
    local _, p1 = PG.Ring(one, 1000, 24, MAP, MAP)
    check(math.abs(PG.RingLength(p1, 24) - 24 * 2 * 1000 * math.sin(math.pi / 24)) < 1, "ring length of a full circle of posts")
end

-- ── Arcs / LineSlots / LineParam / Clusters ──────────────────────────────────────
do
    local _, full = PG.Ring({ { x = 6000, z = 6000 } }, 1000, 24, MAP, MAP)
    local arcs, closed = PG.Arcs(full, 24)
    check(#arcs == 1 and closed and #arcs[1] == 25, "a full ring is one closed arc")
    local _, corner = PG.Ring({ { x = 1500, z = 1500 } }, 2800, 24, MAP, MAP, nil, nil, nil, 150)
    local carcs = PG.Arcs(corner, 24)
    local inOrder = true
    for _, a in ipairs(carcs) do for i = 2, #a do if a[i].k ~= a[i - 1].k % 24 + 1 then inOrder = false end end end
    check(#carcs >= 1 and inOrder, "a corner ring is arcs of consecutive bearings (" .. #carcs .. ")")
    local slots, L = PG.LineSlots(full, 24, 10)
    check(#slots == 10 and math.abs(L - PG.RingLength(full, 24)) < 1, "10 slots on the line, line length = ring length")
    local even = true
    for i = 2, #slots do if math.abs((slots[i].s - slots[i - 1].s) - L / 10) > 1e-6 then even = false end end
    check(even, "slots are evenly spaced along the line")
    local onRing = true
    for _, sl in ipairs(slots) do
        local d = math.sqrt((sl.x - 6000) ^ 2 + (sl.z - 6000) ^ 2)
        if d < 1000 * math.cos(math.pi / 24) - 1 or d > 1000 + 1 then onRing = false end
    end
    check(onRing, "every slot lies on the polyline of the posts")
    local segs = PG._Segments((PG.Arcs(full, 24)))
    check(math.abs(PG.LineParam(segs, slots[3].x, slots[3].z) - slots[3].s) < 1, "LineParam of a point on the line is its own parameter")
end
local cl = PG.Clusters({ { x = 0, z = 0, v = 100 }, { x = 300, z = 0, v = 100 }, { x = 5000, z = 0, v = 500 } }, 800)
check(#cl == 2 and cl[1].v == 500 and cl[2].v == 200 and cl[2].n == 2, "clusters: two groups, heaviest first")

-- ── runtime ───────────────────────────────────────────────────────────────────
local base = { S.Spawn("corwin", 0, 6000, 6000, { silent = true }), S.Spawn("corwin", 0, 6400, 6000, { silent = true }) }
local contacts = {}
local pg = PG.New{ ARMY = ARMY, teamID = 0, mapX = MAP, mapZ = MAP,
                   enemyBase = function() return 11500, 11500 end,
                   contacts = function() return contacts end }
local army = {}
for i = 1, 15 do
    local id = S.Spawn(i <= 13 and "corlevlr" or "cormist", 0, 6200, 6200 + i * 10, { silent = true })
    army[#army + 1] = id
    PG.Add(pg, id, UnitDefNames[i <= 13 and "corlevlr" or "cormist"].id)
end
local function LastOrder(id)
    for i = #W.orders, 1, -1 do if W.orders[i].id == id then return W.orders[i] end end
end
local frame = 30
local function Step(n) for _ = 1, n or 1 do frame = frame + 30; W.frame = frame; ARMY.Sweep(frame); PG.Update(pg, frame) end end
Step(1)
local o = LastOrder(army[1])
check(o and o.cmd == ARMY.CMD_FIGHT, "a defender gets a FIGHT order to its post")
local dmin = math.min(math.sqrt((o.params[1] - 6000) ^ 2 + (o.params[3] - 6000) ^ 2), math.sqrt((o.params[1] - 6400) ^ 2 + (o.params[3] - 6000) ^ 2))
check(dmin > 450 and dmin < 1100, "with few units the post is about R_MIN (700) from the nearest building (" .. math.floor(dmin) .. ")")
check(pg.R == PG.CFG.R_MIN, "15 units: the ring stays at R_MIN (" .. tostring(pg.R) .. ")")
-- every defender has its own slot: no two stand on the same spot, and they spread round the whole line
do
    local seen, dup, minGap = {}, 0, math.huge
    local pts = {}
    for _, id in ipairs(army) do
        local lo = LastOrder(id)
        local key = math.floor(lo.params[1]) .. "," .. math.floor(lo.params[3])
        if seen[key] then dup = dup + 1 end
        seen[key] = true
        if UnitDefs[Spring.GetUnitDefID(id)].name == "corlevlr" then pts[#pts + 1] = lo end
    end
    for i = 1, #pts do for j = i + 1, #pts do
        minGap = math.min(minGap, math.sqrt((pts[i].params[1] - pts[j].params[1]) ^ 2 + (pts[i].params[3] - pts[j].params[3]) ^ 2))
    end end
    check(dup == 0, "every defender gets its own spot on the line")
    check(minGap > 0.5 * pg.lineLen / #army, "the screen units are spread along the line, not in a group (closest pair " ..
          math.floor(minGap) .. ", line " .. math.floor(pg.lineLen) .. ")")
end

-- an intruder inside the ring
contacts[9001] = { x = 6900, z = 6400, defID = UnitDefNames.corlevlr.id, frame = frame + 30, v = 1, air = false }
Step(1)
local responded = 0
for _, id in ipairs(army) do
    local lo = LastOrder(id)
    if lo and lo.cmd == ARMY.CMD_FIGHT and near(lo.params[1], 6900, 1) and near(lo.params[3], 6400, 1) then responded = responded + 1 end
end
check(responded >= PG.CFG.RESPOND_MIN and responded < #army, "the nearest defenders answer the intruder, not all of them (" .. responded .. ")")
check(#S.Log("%[PG%].*intruders") >= 1, "the response is logged")
check(#pg.clusters == 1 and near(pg.clusters[1].x, 6900, 1) and near(pg.clusters[1].z, 6400, 1), "pg.clusters holds the intruder group")
-- it leaves; RETURN_AFTER later the defenders go back
contacts[9001] = nil
Step(math.ceil(PG.CFG.RETURN_AFTER / 30) + 2)
check(next(pg.responding) == nil, "after RETURN_AFTER the defenders are back on the line")
-- an enemy far outside the ring is not chased
contacts[9002] = { x = 6200, z = 11900, defID = UnitDefNames.corlevlr.id, frame = frame + 30, v = 1, air = false }
Step(1)
local chased = next(pg.responding) ~= nil
check(not chased and #pg.clusters == 0, "an enemy ~5900 out is not chased (and is no cluster)")
contacts[9002] = nil

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
