-- tests/test_raid_army.lua
-- RAID_BOT's click_army options (game review 2026-10-13), each against a fresh module on tests/spring_stub.lua:
--   * EARLY_LAUNCH / LAUNCH_RATIO_EARLY: small groups leave early, the minimum ramps up with time;
--   * MIN_GROUP_UNITS: no one-unit (lone Demon) groups;
--   * BLIND_LAUNCH: a group may leave while the foe is still the mirror guess;
--   * LAB_EXIT_R/W: fresh units at an enemy factory do not turn the legs away;
--   * ENGAGE: surrounded next to build power -> COMMIT (ATTACK it); surrounded with none -> ESCAPE to the line front;
--   * HOLE_FIND: the approach goes round the defended side of the target;
--   * SetMode("hold"): groups recalled, stage moves back, nothing launches; "raid" resumes;
--   * TradeSummary: kills near a group and group losses; a spent group with no kills is a bad end.
-- The stub teleports units on MOVE/FIGHT and kills on ATTACK, so this checks decisions, not play.
-- Run: python tests/run_lua.py tests/test_raid_army.lua

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.verbose = arg and arg[1] == "-v"

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local MM, UQ, EI, ARMY, CA
local combat, guards, muster, scouts, responding, bombers
local frame, seenOrders = 0, {}
local hx, hz = W.start[0][1], W.start[0][2]

local function Fresh(cfg, mirror)
    W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
    W.frame, WG = 0, {}
    MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
    UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
    EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
    ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
    CA   = VFS.Include("LuaUI/Widgets/bar_framework/click_army.lua")
    MM.Init(0, 0)
    MM.SetHome(hx, hz)
    if mirror then local fx, fz = MM.Foe(); MM.SetFoe(fx, fz, "mirror") end
    EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
    combat, guards, muster, scouts, responding, bombers = {}, {}, {}, {}, {}, {}
    CA.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, combat = combat, guards = guards, muster = muster,
             scouts = scouts, responding = responding, bombers = bombers, cfg = cfg }
    W.widgets[1] = { _file = "fake", UnitDestroyed = function(_, uid, defID, team)
        local u = { x = W.lastX, z = W.lastZ }
        CA.OnDestroyed(uid, defID, team == 0, W.frame, u.x, u.z)
        if team ~= 0 then EI.OnDestroyed(uid) end
    end }
    frame, seenOrders = 0, {}
end

-- S.Kill forgets the unit before the callin: remember where it was (the unit controller passes the position)
local stubKill = S.Kill
S.Kill = function(id, attacker)
    local u = W.units[id]
    if u then W.lastX, W.lastZ = u.x, u.z end
    return stubKill(id, attacker)
end
local function Kill(id) S.Kill(id) end

local function Tick()
    frame = frame + 30
    W.frame = frame
    EI.Scan(frame)
    ARMY.Sweep(frame)
    CA.Update(frame)
    for _, o in ipairs(W.orders) do seenOrders[#seenOrders + 1] = o end
    S.Frame(frame)
end
local function Run(n) for _ = 1, n do Tick() end end
local function At(f) frame = f - 30 end           -- the next Tick runs at frame f

local function Units(name, n, x, z, team)
    local ids = {}
    for i = 1, n do
        local id = S.Spawn(name, team or 0, x + (i % 5) * 12, z + math.floor(i / 5) * 12, { silent = true })
        if (team or 0) == 0 then combat[id] = UnitDefNames[name].id end
        ids[#ids + 1] = id
    end
    return ids
end
local function Count(p) return #S.Log(p) end
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
local function Place(ids, x, z)
    for i, id in ipairs(ids) do
        local u = W.units[id]
        if u then u.x, u.z = x + (i % 5) * 12, z + math.floor(i / 5) * 12 end
    end
end

local EARLY = { f0 = 5400, av0 = 350, f1 = 18000, av1 = 1800 }

-- ── EARLY_LAUNCH + MIN_GROUP_UNITS ────────────────────────────────────────────
Fresh{ EARLY_LAUNCH = EARLY, LAUNCH_RATIO_EARLY = 1.0, MIN_GROUP_UNITS = 3 }
local fx, fz = MM.Foe()
S.Spawn("cornanotc", 1, fx, fz, { silent = true })
Run(1)
local sx, sz = CA.StagePoint()
Units("corgator", 2, sx, sz)
Run(3)
check(#CA.Groups() == 0, "early: 2 gators (av 254 < 350) do not launch")
Units("corgator", 1, sx, sz)
Run(2)
check(#CA.Groups() == 1, "early: 3 gators (av 381 >= 350 at 0:0x) launch")
check(Count("%[CK%] .*group #1 launch: 3 units") == 1, "early: the launch is logged with 3 units")

Fresh{ EARLY_LAUNCH = EARLY, LAUNCH_RATIO_EARLY = 1.0, MIN_GROUP_UNITS = 3 }
S.Spawn("cornanotc", 1, fx, fz, { silent = true })
At(11700); Run(1)
sx, sz = CA.StagePoint()
Units("corgator", 8, sx, sz)                     -- av 1017 < ramp at 6:30 (350 + 1450 * 6300/12600 = 1075)
Run(2)
check(#CA.Groups() == 0, "early ramp: 8 gators (av 1017) wait at 6:30 (min ~1075-1085)")
Units("corgator", 1, sx, sz)                     -- av 1144
Run(2)
check(#CA.Groups() == 1, "early ramp: 9 gators (av 1144) launch at 6:30")

Fresh{ EARLY_LAUNCH = EARLY, LAUNCH_RATIO_EARLY = 1.0, MIN_GROUP_UNITS = 3 }
S.Spawn("cornanotc", 1, fx, fz, { silent = true })
Run(1)
sx, sz = CA.StagePoint()
Units("corsumo", 1, sx, sz)                      -- av 2600, but one unit
Run(3)
check(#CA.Groups() == 0, "MIN_GROUP_UNITS: one big unit alone does not launch")
Units("corgator", 2, sx, sz)
Run(2)
check(#CA.Groups() == 1, "MIN_GROUP_UNITS: with 2 more units the group of 3 launches")

-- defaults unchanged: the same 3 gators at 0:0x do not launch without EARLY_LAUNCH
Fresh{}
S.Spawn("cornanotc", 1, fx, fz, { silent = true })
Run(1)
sx, sz = CA.StagePoint()
Units("corgator", 3, sx, sz)
Run(3)
check(#CA.Groups() == 0, "defaults: 3 gators stay at the stage (LAUNCH_MIN_AV 1800)")

-- ── BLIND_LAUNCH ──────────────────────────────────────────────────────────────
Fresh({ EARLY_LAUNCH = EARLY, MIN_GROUP_UNITS = 3 }, true)
check(MM.FoeSource() == "mirror", "blind: foe source is the mirror guess")
Run(1)
sx, sz = CA.StagePoint()
Units("corgator", 5, sx, sz)
Run(3)
check(#CA.Groups() == 0, "blind off: no launch on a mirror guess")
Fresh({ EARLY_LAUNCH = EARLY, MIN_GROUP_UNITS = 3, BLIND_LAUNCH = true }, true)
Run(1)
sx, sz = CA.StagePoint()
Units("corgator", 5, sx, sz)
Run(2)
check(#CA.Groups() == 1, "blind on: the group leaves on the mirror guess")

-- ── LAB_EXIT ──────────────────────────────────────────────────────────────────
local function FirstLegAngle(cfg)
    Fresh(cfg)
    local nfx, nfz = MM.Foe()
    S.Spawn("cornanotc", 1, nfx, nfz, { silent = true })
    Run(1)
    local stx, stz = CA.StagePoint()
    local ux, uz = (nfx - stx), (nfz - stz)
    local L = math.sqrt(ux * ux + uz * uz); ux, uz = ux / L, uz / L
    local lab = S.Spawn("corlab", 1, stx + ux * 900, stz + uz * 900, { silent = true })
    for i = 1, 4 do S.Spawn("corraid", 1, stx + ux * 900 + i * 30, stz + uz * 900 + 60, { silent = true }) end
    local ids = Units("corgator", 20, stx, stz)
    for _ = 1, 6 do if #CA.Groups() == 0 then Tick() end end
    if #CA.Groups() ~= 1 then return nil end
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    -- keep the group on the stage until the broker lets the first leg out (90-frame order floor), then read it
    for _ = 1, 6 do
        seenOrders = {}
        Place(ids, stx, stz)
        Tick()
        for _, o in ipairs(seenOrders) do
            if set[o.id] and o.cmd == 10 then
                local dx, dz = o.params[1] - stx, o.params[3] - stz
                local d = math.sqrt(dx * dx + dz * dz)
                if d > 300 then
                    return math.deg(math.acos(math.max(-1, math.min(1, (dx * ux + dz * uz) / d)))), lab
                end
            end
        end
    end
end
local angOff = FirstLegAngle{}
local angOn  = FirstLegAngle{ LAB_EXIT_R = 450, LAB_EXIT_W = 0.2 }
check(angOff and angOff > 30, "lab exit off: the first leg turns away from the units at the lab (" .. tostring(angOff) .. " deg)")
check(angOn and angOn < 5, "lab exit on: the first leg goes straight past the lab exit (" .. tostring(angOn) .. " deg)")

-- ── ENGAGE: commit / escape ───────────────────────────────────────────────────
local function Surround(px, pz, r)
    for k = 0, 2 do
        local a = k * 2 * math.pi / 3 + 0.3
        for i = 1, 4 do
            S.Spawn("corraid", 1, px + math.cos(a) * r + i * 15, pz + math.sin(a) * r, { silent = true })
        end
    end
end
local function Launched20(cfg)
    Fresh(cfg)
    local nfx, nfz = MM.Foe()
    local far = S.Spawn("cornanotc", 1, nfx, nfz, { silent = true })
    Run(1)
    local stx, stz = CA.StagePoint()
    local ids = Units("corgator", 20, stx, stz)
    for _ = 1, 6 do if #CA.Groups() == 0 then Tick() end end
    return ids, far
end

local ids, farNano = Launched20{ ENGAGE = true }
check(#CA.Groups() == 1, "engage: a group of 20 launched")
local px, pz = 6000, 9000
local nano = S.Spawn("cornanotc", 1, px + 300, pz, { silent = true })
Surround(px, pz, 600)
Place(ids, px, pz)
seenOrders = {}
Run(4)                                              -- the broker's 90-frame order floor delays the first ATTACK
check(Count("%[CK%] .*group #1 COMMIT on cornanotc") == 1, "engage: surrounded next to a nano -> COMMIT on it")
local attacked = 0
for _, o in ipairs(seenOrders) do if o.cmd == 20 and o.params[1] == nano then attacked = attacked + 1 end end
check(attacked >= 10, "engage: the group ATTACKs the nano (" .. attacked .. " orders)")
check(W.units[nano] == nil, "engage: (stub) the nano died")
local tr = CA.TradeSummary(frame)
check(tr.killed > 0, "trade: the nano kill near the group counts (" .. tostring(tr.killed) .. ")")

-- escape: surrounded, no build power within reach
ids = Launched20{ ENGAGE = true }
px, pz = 6000, 7000
Surround(px, pz, 600)
Place(ids, px, pz)
seenOrders = {}
for _ = 1, 4 do                                     -- hold them in the trap until the broker lets the MOVEs out
    local moved = false
    for _, o in ipairs(seenOrders) do if o.cmd == 10 then moved = true end end
    if moved then break end
    Place(ids, px, pz)
    Tick()
end
check(Count("%[CK%] .*group #1 ESCAPE to the line front") == 1, "engage: surrounded with no build power -> ESCAPE")
local ex, ez = MM.PointAt(0.25 * MM.Dist(), 0)
local nearLine, moves = 0, 0
for _, o in ipairs(seenOrders) do
    if o.cmd == 10 then
        moves = moves + 1
        if Dist(o.params[1], o.params[3], ex, ez) < 600 then nearLine = nearLine + 1 end
    end
end
check(moves >= 20 and nearLine == moves, "engage: every escaping unit MOVEs to the line front (" .. nearLine .. "/" .. moves .. ")")
Run(2)
check(Count("%[CK%] .*group #1 end %(escaped%)") == 1, "engage: on arrival the group ends (escaped)")

-- not surrounded, nothing near: no engage rows (advance as usual)
ids = Launched20{ ENGAGE = true }
Place(ids, 6000, 7000)
S.Spawn("corraid", 1, 6500, 7000, { silent = true })
Run(2)
check(Count("COMMIT") == 0 and Count("ESCAPE") == 0, "engage: one enemy raider is not a reason to commit or escape")

-- losing fast with no build power near -> escape
ids = Launched20{ ENGAGE = true }
Place(ids, 6000, 7000)
Run(1)
for i = 1, 6 do Kill(ids[i]) end                   -- 6 of 20 in one window: 30% of the value
Run(1)
check(Count("%[CK%] .*group #1 ESCAPE") == 1, "engage: losing 30% of the group in 10 s -> ESCAPE")

-- ── TradeSummary: a spent group that killed nothing is a bad end ──────────────
ids = Launched20{}
Place(ids, 6000, 7000)
Run(1)
for i = 1, 16 do Kill(ids[i]) end
Run(1)
tr = CA.TradeSummary(frame)
check(Count("group #1 end %(group spent%)") == 1, "trade: the group is spent")
check(tr.lost > 1900 and tr.killed == 0 and tr.badEnds == 1, string.format(
    "trade: lost %.0f, killed %.0f, bad ends %d", tr.lost, tr.killed, tr.badEnds))

-- ── HOLE_FIND ─────────────────────────────────────────────────────────────────
ids, farNano = Launched20{ HOLE_FIND = true }
local tx, tz = W.units[farNano].x, W.units[farNano].z
-- the group 3000 short of the target on the home side; 15 LLTs on the ring point facing it
local ax, az = MM.Axis()
local gx, gz = tx - ax * 3000, tz - az * 3000
local dx, dz = tx - ax * 1400, tz - az * 1400
for i = 1, 15 do S.Spawn("corllt", 1, dx + (i % 5) * 20, dz + math.floor(i / 5) * 20, { silent = true }) end
Place(ids, gx, gz)
seenOrders = {}
Tick()
local rows = S.Log("%[CK%] .*group #1 approach via %((%-?%d+),(%-?%d+)%)")
check(#rows == 1, "hole: the approach point is logged")
if rows[1] then
    local apx, apz = rows[1]:match("approach via %((%-?%d+),(%-?%d+)%)")
    apx, apz = tonumber(apx), tonumber(apz)
    check(Dist(apx, apz, dx, dz) > 1350, "hole: the approach point is clear of the defended side ("
        .. math.floor(Dist(apx, apz, dx, dz)) .. " from the LLTs)")
    check(math.abs(Dist(apx, apz, tx, tz) - 1400) < 5, "hole: the approach point is on the ring round the target")
end
check(#CA.ScoutRequests() >= 3, "hole: unseen ring points are added to the scout requests ("
    .. #CA.ScoutRequests() .. ")")
-- without HOLE_FIND the same setup walks the straight line (no approach row)
ids, farNano = Launched20{}
for i = 1, 15 do S.Spawn("corllt", 1, dx + (i % 5) * 20, dz + math.floor(i / 5) * 20, { silent = true }) end
Place(ids, gx, gz)
Tick()
check(Count("approach via") == 0, "hole off: no approach rows")

-- ── SetMode ───────────────────────────────────────────────────────────────────
ids = Launched20{ EARLY_LAUNCH = EARLY, MIN_GROUP_UNITS = 3 }
local s0x, s0z = CA.StagePoint()
check(CA.Mode() == "raid", "mode: raid by default")
check(CA.SetMode("hold", frame) == true and CA.SetMode("hold", frame) == false, "mode: SetMode reports a change once")
Run(1)
check(Count("group #1 end %(hold%)") == 1, "hold: the attacking group is recalled")
local s1x, s1z = CA.StagePoint()
check(MM.Forward(s1x, s1z) < MM.Forward(s0x, s0z) - 2000, "hold: the stage moves back toward home")
Run(60)
Units("corgator", 10, s1x, s1z)
Run(4)
local attacking = 0
for _, g in ipairs(CA.Groups()) do if g.state == "attack" then attacking = attacking + 1 end end
check(attacking == 0, "hold: nothing launches")
CA.SetMode("raid", frame)
Run(4)
attacking = 0
for _, g in ipairs(CA.Groups()) do if g.state == "attack" then attacking = attacking + 1 end end
check(attacking == 1, "raid again: the staged units launch")

-- ── FIGHTER_POST ──────────────────────────────────────────────────────────────
ids = Launched20{ FIGHTER_POST = true }
Place(ids, 6000, 7000)
Run(1)
local g1 = CA.Groups()[1]
local p1x, p1z = CA.FighterPost(frame)
check(p1x and math.abs(Dist(p1x, p1z, g1.cx, g1.cz) - 900) < 5, "fighter post: 900 behind the group")
check(p1x and Dist(p1x, p1z, hx, hz) < Dist(g1.cx, g1.cz, hx, hz), "fighter post: toward home")
for i = 1, 3 do S.Spawn("corrl", 1, p1x + i * 20, p1z, { silent = true }) end
Run(1)
local p2x, p2z = CA.FighterPost(frame)
check(Dist(p2x, p2z, g1.cx, g1.cz) > Dist(p1x, p1z, g1.cx, g1.cz) + 250 and EI.ThreatAt(frame, p2x, p2z, "air") <= 150,
    "fighter post: pulled back out of enemy AA")
local veng = S.Spawn("corveng", 0, hx, hz, { silent = true })
combat[veng] = UnitDefNames.corveng.id
seenOrders = {}
Run(4)
local toPost = false
for _, o in ipairs(seenOrders) do
    if o.id == veng and o.cmd == 16 and Dist(o.params[1], o.params[3], p2x, p2z) < 300 then toPost = true end
end
check(toPost, "fighter post: a fighter waits there (FIGHT), not over the group")
check(CA.SetMode("hold", frame), "hold for the post test")
Run(1)
local p3x, p3z = CA.FighterPost(frame)
local s3x, s3z = CA.StagePoint()
check(p3x and Dist(p3x, p3z, s3x, s3z) < 900 + 15 * 300 + 5, "fighter post in hold: behind the stage")

-- ── SCOUT_ROUTE ───────────────────────────────────────────────────────────────
ids, farNano = Launched20{ HOLE_FIND = true, SCOUT_ROUTE = true }
for i = 1, 15 do S.Spawn("corllt", 1, dx + (i % 5) * 20, dz + math.floor(i / 5) * 20, { silent = true }) end
Place(ids, gx, gz)
Run(1)
local req = CA.ScoutRequests()
local atTarget, onRoute = false, false
local ap = CA.Groups()[1].approach
for _, r in ipairs(req) do
    if Dist(r[1], r[2], tx, tz) < 5 then atTarget = true end
    if ap and Dist(r[1], r[2], gx, gz) > 1000 and Dist(r[1], r[2], ap.x, ap.z) < Dist(gx, gz, ap.x, ap.z) then onRoute = true end
end
check(atTarget, "scout route: a scout is asked to look at the target itself")
check(onRoute, "scout route: a scout is asked to look along the route to the hole (" .. #req .. " requests)")

for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
