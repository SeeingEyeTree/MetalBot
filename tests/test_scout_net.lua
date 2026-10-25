-- tests/test_scout_net.lua      python tests/run_lua.py tests/test_scout_net.lua
-- bar_framework/scout_net.lua (CORE's scouting after FIND) and enemy_intel.Groups:
--   * Groups: clusters incl. air, value, longest weapon range, last sighting;
--   * group watch: a watchable ground group gets a scout at standoff (just outside its weapon range); a group whose weapons
--     out-reach a scout does not, and is left to the sacrifice runs;
--   * sacrifice: one run per period at the best stale group, straight at its centre, not repeated early;
--   * API: RequestScout (served by the nearest scout, refreshed by key, cancelled), RequestSector, hawk requests;
--   * perimeter: scout posts around the footprint, a loss pulls its bearing in; sweep for spare scouts;
--   * hunting: no perimeter, the commander's sector is swept, the labs are asked for the hunt count;
--   * Want(): the income curves.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
local homeX, homeZ = W.start[0][1], W.start[0][2]
local foeX, foeZ = W.start[1][1], W.start[1][2]

local MM = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
local SN = VFS.Include("LuaUI/Widgets/bar_framework/scout_net.lua")
MM.Init(0, 0); MM.SetHome(homeX, homeZ); MM.SetFoe(foeX, foeZ, "test")
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
SN.Init{ MM = MM, UQ = UQ, EI = EI, allyID = 0 }

-- a ground radar unit for the stub (no such def in it)
local rd = UnitDefNames["testradarbot"]
rd.speed, rd.canMove, rd.radarRadius, rd.metalCost = 60, true, 2000, 90

-- our base: a blob of structures round home
local pts = {}
for i = 0, 30 do pts[#pts + 1] = homeX + (i % 6) * 100 - 250; pts[#pts + 1] = homeZ + math.floor(i / 6) * 100 - 200 end
SN.SetStructures(pts)

-- ── enemy: a ground group (gators + tigers), a long-range group (lashers), an air group, a stray ──
local gp = { x = 6000, z = 6000 }
for i = 1, 5 do S.Spawn("corgator", 1, gp.x + i * 30, gp.z, { silent = true }) end
for i = 1, 3 do S.Spawn("correap", 1, gp.x + 200, gp.z + 100 + i * 30, { silent = true }) end
for i = 1, 3 do S.Spawn("cormist", 1, 8000 + i * 30, 2000, { silent = true }) end
for i = 1, 3 do S.Spawn("corbw", 1, 4000 + i * 30, 4000, { silent = true }) end
S.Spawn("corgator", 1, 9500, 3000, { silent = true })
EI.Scan(10)

-- 1. Groups ------------------------------------------------------------------
local gs = EI.Groups(10)
check(#gs >= 3, "the gators + tigers, the lashers and the air group are separate groups (" .. #gs .. ")")
check(gs[1].n == 8 and gs[1].range >= 300, "the biggest group is the 8 ground units, with their weapon range")
check(gs[1].lastSeen == 10, "last sighting is the scan frame")
local airG, mistG
for _, g in ipairs(gs) do
    if g.air then airG = g end
    if g.range >= 700 then mistG = g end
end
check(airG ~= nil and airG.n == 3, "the bombers form an air group (air is included, unlike Blobs)")
check(mistG ~= nil and mistG.n == 3, "the lashers form a long-range group")
check(#EI.Groups(10 + 5000) == 0, "groups older than maxAge are dropped")

-- ── our units ──
local scouts = {}
for i = 1, 4 do scouts[i] = S.Spawn("corfav", 0, homeX + i * 40, homeZ + 300, { silent = true }) end
local hawk = S.Spawn("corawac", 0, homeX, homeZ + 600, { silent = true })
local radarU = S.Spawn("testradarbot", 0, homeX + 100, homeZ + 600, { silent = true })
local function Units(extra)
    local u = { scouts = scouts, radars = { radarU }, hawks = { hawk } }
    for k, v in pairs(extra or {}) do u[k] = v end
    return u
end
local function Teleport(claims) for uid, c in pairs(claims) do if W.units[uid] then W.units[uid].x, W.units[uid].z = c.x, c.z end end end

-- 2. First pass: sacrifice run + group watch + perimeter --------------------------------
local frame = 1000
W.frame = frame
EI.Scan(350)       -- last seen 650 frames ago: stale enough for a run, fresh enough to watch
SN.Observe(frame, {})
local claims = SN.Step(frame, Units(), { income = 0 })
local gx, gz = gs[1].x, gs[1].z
local sacUid, watchUid
for uid, c in pairs(claims) do
    if Dist(c.x, c.z, gx, gz) < 5 then sacUid = uid end
    if Dist(c.x, c.z, gx, gz) > 380 and Dist(c.x, c.z, gx, gz) < 520 and c.role == "SCOUT" then watchUid = uid end
end
check(sacUid ~= nil, "a scout runs at the centre of the best stale group")
check(SN.Stats().sacSent == 1, "one sacrifice run sent")
check(watchUid ~= nil and watchUid ~= sacUid, "another scout holds a post just outside the group's guns (~" .. 300 + 150 .. " elmos)")
local pic = SN.Picture(frame)
local watchedBig, watchedMist
for _, g in ipairs(pic.groups) do
    if g.n == 8 then watchedBig = g.scoutWatched end
    if g.range >= 700 then watchedMist = g.scoutWatched end
end
check(watchedBig == true, "the ground group has a scout watching it")
check(watchedMist == false, "the long-range group out-reaches a scout: no scout watches it (left to the runs)")
check(pic.totalValue > 0 and #pic.groups >= 3, "the picture lists the groups and their total value")
local hawkClaim = claims[hawk]
local radarClaim = claims[radarU]
check(radarClaim ~= nil and radarClaim.role == "RADAR", "the ground radar unit gets a radar post")
check(hawkClaim ~= nil and hawkClaim.role == "RADAR", "the radar plane gets a radar post too")
check(radarClaim == nil or hawkClaim == nil or Dist(radarClaim.x, radarClaim.z, hawkClaim.x, hawkClaim.z) > 200,
      "...not the same one")

-- 3. The run is not repeated early; the next one fires a period later ----------------------
Teleport(claims)
frame = frame + 300; W.frame = frame
SN.Step(frame, Units(), { income = 0 })
check(SN.Stats().sacSent == 1, "no second run within the period")
EI.Scan(1400)                                   -- seen at 1400: 600 frames old by the time of the next run
frame = frame + 700; W.frame = frame
SN.Step(frame, Units(), { income = 0 })
check(SN.Stats().sacSent == 2, "a second run after the period (" .. SN.Stats().sacSent .. ")")

-- 4. API: requests ------------------------------------------------------------------
local rx, rz = 3000, 9000
local id1 = SN.RequestScout(rx, rz, { ttl = 600, by = "test" })
local id2 = SN.RequestScout(rx + 10, rz, { key = "k1", ttl = 600 })
local id3 = SN.RequestScout(rx + 20, rz, { key = "k1", ttl = 600 })
check(id2 == id3 and id1 ~= id2, "a repeated key refreshes one request instead of adding another")
SN.CancelRequest(id1)
frame = frame + 60; W.frame = frame
claims = SN.Step(frame, Units(), { income = 0 })
local served
for uid, c in pairs(claims) do if Dist(c.x, c.z, rx + 20, rz) < 5 then served = uid end end
check(served ~= nil and W.units[served].defID == UnitDefNames["corfav"].id, "a scout answers the request at its latest position")
local anyAtCancelled = false
for _, c in pairs(claims) do if Dist(c.x, c.z, rx, rz) < 5 then anyAtCancelled = true end end
check(not anyAtCancelled, "a cancelled request is not served")
local hid = SN.RequestScout(5000, 5000, { kind = "hawk", untilMode = "expire", ttl = 300 })
frame = frame + 60; W.frame = frame
claims = SN.Step(frame, Units(), { income = 0 })
check(claims[hawk] and claims[hawk].role == "SCOUT_CALL" and Dist(claims[hawk].x, claims[hawk].z, 5000, 5000) < 5,
      "a hawk request is answered by the radar plane (SCOUT_CALL)")
SN.CancelRequest(hid)
local sectors = MM.BuildSectors(nil, 200)
local anyKey = next(sectors)
check(SN.RequestSector(anyKey, { ttl = 100 }) ~= nil, "RequestSector takes a sector key")
check(SN.RequestSector("nope", {}) == nil, "...and refuses an unknown one")
frame = frame + 200; W.frame = frame
SN.Step(frame, Units(), { income = 0 })          -- expiry drops the requests above
frame = frame + 2000; W.frame = frame
SN.Step(frame, Units(), { income = 0 })

-- 5. Perimeter, loss cap, sweep ---------------------------------------------------------
-- (no enemies for these: the picture is empty, so only the perimeter and the sweep use the scouts)
for id in pairs(W.units) do if W.units[id].team == 1 then W.units[id] = nil end end
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
local many = {}
for i = 1, 14 do many[i] = S.Spawn("corfav", 0, homeX + i * 30, homeZ + 200, { silent = true }) end
frame = frame + 100; W.frame = frame
local cx, cz = SN.Centre()
claims = SN.Step(frame, { scouts = many, radars = {}, hawks = {} }, { income = 0 })
local n, minR, maxR, enemyHalf = 0, math.huge, 0, 0
local east, eastR
for uid, c in pairs(claims) do
    n = n + 1
    local r = Dist(c.x, c.z, cx, cz)
    if MM.IsOurHalf(c.x, c.z) and r < 2500 then
        minR, maxR = math.min(minR, r), math.max(maxR, r)
        local ang = math.abs(math.atan2(c.z - cz, c.x - cx))
        if not east or ang < east then east, eastR = ang, r end
    end
    if not MM.IsOurHalf(c.x, c.z) then enemyHalf = enemyHalf + 1 end
    check(Dist(c.x, c.z, foeX, foeZ) >= 2600 or not MM.IsOurHalf(c.x, c.z), "no post inside the enemy keep-out")
end
check(n == 14, "every scout has a job (" .. n .. ")")
check(minR >= 400 and maxR <= 1500, string.format("perimeter posts ring the base (%.0f..%.0f from its centre)", minR, maxR))
check(enemyHalf >= 3, "spare scouts sweep the enemy half (" .. enemyHalf .. ")")
-- a scout dies at the east post: the ring there stands closer in afterwards
local ex, ez = cx + eastR, cz
SN.OnLost(99999, ex, ez, frame)
Teleport(claims)
frame = frame + 60; W.frame = frame
claims = SN.Step(frame, { scouts = many, radars = {}, hawks = {} }, { income = 0 })
local east2, eastR2
for uid, c in pairs(claims) do
    if MM.IsOurHalf(c.x, c.z) and Dist(c.x, c.z, cx, cz) < 2500 then
        local ang = math.abs(math.atan2(c.z - cz, c.x - cx))
        if not east2 or ang < east2 then east2, eastR2 = ang, Dist(c.x, c.z, cx, cz) end
    end
end
check(eastR2 and eastR2 < eastR - 150, string.format("a loss pulls its bearing in (%.0f -> %.0f)", eastR, eastR2 or -1))

-- 6. LastSeenNear / Picture.baseSeenFrame --------------------------------------------------
check(SN.LastSeenNear(foeX, foeZ, 2500) == nil or SN.LastSeenNear(foeX, foeZ, 2500) <= frame, "base not seen yet")
local spy = S.Spawn("corfav", 0, foeX, foeZ, { silent = true })
SN.Observe(frame + 30, { spy })
check(SN.LastSeenNear(foeX, foeZ, 2500) == frame + 30, "a unit at the enemy base marks it seen")
check(SN.Picture(frame + 30).baseSeenFrame == frame + 30, "the picture reports when the base was last seen")

-- 7. Hunting ----------------------------------------------------------------------------
frame = frame + 100; W.frame = frame
claims = SN.Step(frame, { scouts = many, radars = {}, hawks = {} },
                 { income = 0, hunting = true, commander = { x = 9000, z = 11000, frame = 0 } })
local nearCmdr = 0
for uid, c in pairs(claims) do
    if Dist(c.x, c.z, 9000, 11000) < 1200 then nearCmdr = nearCmdr + 1 end
end
check(nearCmdr >= 1, "hunting sends a scout at the commander's sector")
check(SN.Want().scouts == SN.CFG.HUNT_SCOUTS, "hunting asks the labs for the hunt count")

-- 8. Want follows income ------------------------------------------------------------------
frame = frame + 100; W.frame = frame
SN.Step(frame, { scouts = many, radars = {}, hawks = {} }, { income = 0 })
local w0 = { scouts = SN.Want().scouts, radars = SN.Want().radars }
check(w0.scouts == SN.CFG.BASE_SCOUTS and w0.radars == 0, "no income: the FIND pair, no radar units")
SN.Step(frame + 60, { scouts = many, radars = {}, hawks = {} }, { income = 300 })
local w1 = SN.Want()
check(w1.scouts > w0.scouts, "income raises the scout count (" .. w0.scouts .. " -> " .. w1.scouts .. ")")
check(w1.radars > 0, "...and the radar count (" .. w1.radars .. ")")

check(#W.errors == 0, "no Lua errors: " .. (W.errors[1] or ""))
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
