-- tests/test_click_army.lua
-- Run from the repo root through lupa's Lua 5.1:  see tests/LUA_TESTING.md  (lupa.lua51.LuaRuntime)
--
--   1. bar_framework/click_army.lua against tests/spring_stub.lua:
--        * units stage with MOVE only; no group below the minimum army value;
--        * the launch rule: wait while stage av < 2.5 x the value still walking in, go when it holds;
--        * up to 3 groups at once, each on a different target (not the same nano);
--        * with 3 groups out, a new unit joins an attacking group instead of starting a 4th;
--        * ATTACK on the building by unit id, kills credited, no recall for a bad value ratio;
--        * a spent group falls back and its survivors stage again; a group with nothing left to hit ends;
--        * hurt squads retreat, bombers wait for BOMBER_MIN and then strike.
--      The stub teleports units on MOVE and kills on ATTACK, so this checks the logic, not how it plays.
--   2. A smoke run of candidates/LINE_CLICK's three widgets (no Lua errors, click_army live, a group
--      launches) and the lab controller's home-guard cap against LINE_BOT's.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.verbose = arg and arg[1] == "-v"

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function Reset()
    W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
    W.frame, WG = 0, {}
end

-- â”€â”€ 1. click_army â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Reset()
local MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local CA   = VFS.Include("LuaUI/Widgets/bar_framework/click_army.lua")

MM.Init(0, 0)
MM.SetHome(W.start[0][1], W.start[0][2])      -- the stub knows the enemy start: source "start_pos"
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
local combat, guards, muster, scouts, responding, bombers = {}, {}, {}, {}, {}, {}
CA.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, combat = combat, guards = guards, muster = muster,
         scouts = scouts, responding = responding, bombers = bombers }

-- the module learns of deaths the way the unit controller tells it
W.widgets[1] = { _file = "fake", UnitDestroyed = function(_, uid, defID, team)
    CA.OnDestroyed(uid, defID, team == 0, W.frame)
    if team ~= 0 then EI.OnDestroyed(uid) end
end }

local seenOrders = {}     -- every order issued: {id, cmd, params}
local function Tick(frame)
    EI.Scan(frame)
    ARMY.Sweep(frame)
    CA.Update(frame)
    for _, o in ipairs(W.orders) do seenOrders[#seenOrders + 1] = o end
    S.Frame(frame)
end
local frame = 0
local function Run(n) for _ = 1, n do frame = frame + 30; Tick(frame) end end

local function Gators(n, x, z)
    local ids = {}
    for i = 1, n do
        local id = S.Spawn("corgator", 0, x + i * 5, z, { silent = true })
        combat[id] = UnitDefNames.corgator.id
        ids[#ids + 1] = id
    end
    return ids
end
local function GroupN()
    local n = 0
    for _, g in ipairs(CA.Groups()) do n = n + (g.n or 0) end
    return n
end
local function Count(p) return #S.Log(p) end

local hx, hz = W.start[0][1], W.start[0][2]
local fx, fz = MM.Foe()
-- three build-power targets in different parts of the enemy base
local nanoA = S.Spawn("cornanotc", 1, fx,        fz,        { silent = true })
local nanoB = S.Spawn("cornanotc", 1, fx - 1550, fz - 400,  { silent = true })
local nanoC = S.Spawn("cornanotc", 1, fx,        fz - 1600, { silent = true })
local mexA  = S.Spawn("cormex",    1, fx + 300,  fz,        { silent = true })

-- (a) under the minimum value: stage, no group
Gators(14, hx + 200, hz + 100)
Run(8)
local sx, sz = CA.StagePoint()
check(sx ~= nil, "stage point computed")
check(CA.State() == "stage" and #CA.Groups() == 0, "14 gators (av ~1780, under the 1800 minimum): no group")
local moves, others = 0, 0
for _, o in ipairs(seenOrders) do if o.cmd == 10 then moves = moves + 1 else others = others + 1 end end
check(moves > 0 and others == 0, "staging uses MOVE only")

-- (b) the launch rule: 16 at the stage and 10 still walking in -> 2.0x, under 2.5x, so wait
Gators(2, sx, sz)
Gators(10, hx, hz)
Tick(frame + 30); frame = frame + 30
check(#CA.Groups() == 0, "stage av < 2.5 x reinforcing av: the group waits")
check(Count("%[CK%] .*waiting for reinforcements") == 1, "the wait is logged with both values")
Run(1)
check(#CA.Groups() == 1, "once the reinforcements have arrived the group launches")
check(Count("%[CK%] .*group #1 launch: 26 units") == 1, "launched with everyone who was at the stage (26)")

-- (c) a second and third group, each on its own target
Run(2)
Gators(15, hx, hz)
Run(2)
check(#CA.Groups() == 2, "a second group launches from the next 15 gators")
Gators(15, hx, hz)
Run(2)
check(#CA.Groups() == 3, "a third group launches")
Run(1)
local targets, distinct = {}, {}
for _, g in ipairs(CA.Groups()) do
    if g.target then targets[#targets + 1] = g.target.uid; distinct[g.target.uid] = true end
end
local nd = 0
for _ in pairs(distinct) do nd = nd + 1 end
check(#targets == 3 and nd == 3, "the three groups are on three different targets")

-- (d) all three out: a new unit reinforces a group, no fourth group
local before = GroupN()
Gators(4, hx, hz)
Run(2)
check(#CA.Groups() == 3, "no fourth group while three are out")
check(GroupN() >= before + 4, "four new units joined the attacking groups")
local sa, ra = CA.StageValues()
check(sa == 0, "nothing is left waiting at the stage")

-- an enemy force worth more than the groups must NOT recall them (no value-ratio retreat)
for i = 1, 60 do S.Spawn("corak", 1, fx - 300 - i * 5, fz + 100, { silent = true }) end
Run(2)
check(CA.State() == "attack", "a bad value ratio alone does not end the attacks")

-- (e) ATTACK by unit id, kills credited
local attacked = {}
for _ = 1, 50 do
    Run(1)
    for _, o in ipairs(seenOrders) do
        if o.cmd == 20 and o.params and o.params[1] then attacked[o.params[1]] = true end
    end
    if not (W.units[nanoA] or W.units[nanoB] or W.units[nanoC]) then break end
end
check(attacked[nanoA] or attacked[nanoB] or attacked[nanoC], "groups ATTACK a nano by unit id")
local gone = 0
for _, id in ipairs({ nanoA, nanoB, nanoC }) do if not W.units[id] then gone = gone + 1 end end
check(gone >= 2, "at least two of the three nanos died")
check(CA.Totals().kills >= 2 and CA.Totals().killBP >= 400, "kills and build power are credited")
check(Count("%[CK%] .*KILL cornanotc") >= 2, "the nano kills are logged")

-- (f) with nothing left to hit, every group ends ("nothing to hit"), falls back, and the survivors
-- stage again -- and, being a big enough army, go back out to look (that relaunch is by design)
for _ = 1, 120 do Run(1); if Count("%[CK%].*end %(nothing to hit%)") >= 3 then break end end
check(Count("%[CK%].*end %(nothing to hit%)") >= 3, "each group with nothing left to hit ends")
check(Count("%[CK%] .*group #[4-9] launch") >= 1, "the survivors, staged again, launch a new group")

-- clear the army: groups with no units are gone at once
local function KillGators()
    for id, u in pairs(W.units) do
        if u.team == 0 and UnitDefs[u.defID].name == "corgator" then S.Kill(id) end
    end
end
KillGators()
Run(3)
check(#CA.Groups() == 0, "with every gator dead no group remains")

-- (g) a spent group: kill all but 3 of it -> it falls back
local nanoD = S.Spawn("cornanotc", 1, fx - 600, fz - 900, { silent = true })
for id, u in pairs(W.units) do
    if u.team == 1 and UnitDefs[u.defID].name == "corak" then S.Kill(id) end   -- clear the armed decoys
end
Gators(15, hx, hz)
Run(3)
check(#CA.Groups() == 1, "a new group launches from the next 15 gators")
local spentBefore = Count("%[CK%].*end %(group spent%)")
local alive = {}
for id, u in pairs(W.units) do if u.team == 0 and UnitDefs[u.defID].name == "corgator" then alive[#alive + 1] = id end end
table.sort(alive)
for i = 1, #alive - 3 do S.Kill(alive[i]) end
Run(2)
check(Count("%[CK%].*end %(group spent%)") == spentBefore + 1, "a spent group falls back")
check(CA.Totals().lostUnits >= 10, "attack losses counted")
Run(40)
check(#CA.Groups() == 0, "the spent group's survivors are stage units again")

-- (h) an enemy death far from every group is not credited (e.g. the end-of-match chain)
Gators(15, hx, hz); Run(3)
local killsBefore = CA.Totals().kills
CA.OnDestroyed(99999, UnitDefNames.cornanotc.id, false, frame, 100, 100)
check(CA.Totals().kills == killsBefore, "an enemy death far from the groups is not credited")

-- (i) the slow group: Mammoths (speed 23) get a group of their own with just enough fast escorts,
-- and it is the one extra on top of the 3 fast groups (4 at most)
KillGators(); Run(3)
for id, u in pairs(W.units) do if u.team == 0 and UnitDefs[u.defID].name == "corsumo" then S.Kill(id) end end
S.Spawn("cornanotc", 1, fx - 300, fz - 300, { silent = true })
local function Mammoths(n, x, z)
    local ids = {}
    for i = 1, n do
        local id = S.Spawn("corsumo", 0, x + i * 7, z, { silent = true })
        combat[id] = UnitDefNames.corsumo.id
        ids[#ids + 1] = id
    end
    return ids
end
local function CountGroups()
    local slow, fast = 0, 0
    for _, g in ipairs(CA.Groups()) do if g.slow then slow = slow + 1 else fast = fast + 1 end end
    return slow, fast
end
local mams = Mammoths(2, hx, hz)
local gs = Gators(30, hx, hz)
Run(3)
local ns, nf = CountGroups()
check(ns == 1, "the Mammoths launch as one slow group")
check(nf == 1, "the remaining gators launch as a fast group")
local sg = CA.GroupOf(mams[1])
check(sg and sg.slow and CA.GroupOf(mams[2]) == sg, "both Mammoths are in the slow group")
local inSlow = 0
for _, id in ipairs(gs) do if CA.GroupOf(id) == sg then inSlow = inSlow + 1 end end
check(inSlow >= 8 and sg.escort <= 0.35 * sg.heavy * 1.15 and sg.escort >= 0.35 * sg.heavy * 0.5,
      string.format("the slow group has only enough fast escorts for mass (%d gators, escort %.0f of slow %.0f)",
                    inSlow, sg.escort or 0, sg.heavy or 0))
check(Count("%[CK%] .*SLOW group #%d+ launch: 2 slow units") == 1, "the slow launch is logged with its escorts")
for _, id in ipairs(mams) do
    local g = CA.GroupOf(id)
    check(g and g.slow, "a Mammoth is never in a fast group")
end

-- a new Mammoth walks straight into the slow group; new gators do not pile onto it
local mam3 = Mammoths(1, hx, hz)[1]
local escortBefore = sg.escort
Gators(20, hx, hz)
Run(3)
check(CA.GroupOf(mam3) == sg, "a new Mammoth joins the slow group directly")
check(sg.escort <= 0.35 * (sg.heavy or 0) * 1.15, "new gators do not inflate the slow group's escort share")

-- 3 fast groups + the slow group = 4, never more
Gators(30, hx, hz); Run(3)
Gators(30, hx, hz); Run(3)
ns, nf = CountGroups()
check(ns == 1 and nf <= 3 and ns + nf <= 4, string.format("at most 4 groups: %d slow + %d fast", ns, nf))
Gators(40, hx, hz); Run(3)
ns, nf = CountGroups()
check(ns == 1 and nf == 3, "three fast groups plus the slow group are out")
Gators(6, hx, hz); Run(3)
ns, nf = CountGroups()
check(ns + nf == 4, "a fifth group never starts")

-- (j) scout calls: two points per attacking group, ahead of it along its path
local attacking = 0
for _, g in ipairs(CA.Groups()) do if g.state == "attack" then attacking = attacking + 1 end end
local reqs = CA.ScoutRequests()
check(CA.ScoutDemand() == math.min(6, 2 * attacking), "scout demand is 2 per attacking group, capped at 6")
check(#reqs == math.min(6, 2 * attacking) and #reqs > 0, "a scout request per demanded scout")
local okAhead = true
for _, r in ipairs(reqs) do
    local g
    for _, gg in ipairs(CA.Groups()) do if gg.id == r[3] then g = gg end end
    if not (g and g.cx) then okAhead = false
    else
        local d = math.sqrt((r[1] - g.cx) ^ 2 + (r[2] - g.cz) ^ 2)
        if d < 600 or d > 2600 then okAhead = false end
    end
end
check(okAhead, "each scout point is 0.6-2.6 km ahead of its group")

KillGators()
for id, u in pairs(W.units) do if u.team == 0 and UnitDefs[u.defID].name == "corsumo" then S.Kill(id) end end
Run(4)
check(#CA.Groups() == 0 and CA.ScoutDemand() == 0, "no groups, no scout demand")

-- (k) a lab is worth little: at equal distance a nano comes first, but a lab is still hit when
-- it is all that is left
local function ClearEnemy()
    for id, u in pairs(W.units) do if u.team == 1 then S.Kill(id) end end
end
local function TargetName(g) return g and g.target and UnitDefs[g.target.defID].name or nil end
local px, pz = MM.Perp()
ClearEnemy()
local labT  = S.Spawn("coraap",    1, fx + px * 1200, fz + pz * 1200, { silent = true })   -- T2 air lab, 3,700 undiscounted
local nanoT = S.Spawn("cornanotc", 1, fx - px * 1200, fz - pz * 1200, { silent = true })   -- 1,075
Gators(15, hx, hz)
Run(3)
local g1 = CA.Groups()[1]
check(g1 ~= nil, "a group launches for the lab test")
check(TargetName(g1) == "cornanotc", "a nano is picked before a (much dearer) lab at equal distance: got " .. tostring(TargetName(g1)))
S.Kill(nanoT)
Run(2)
g1 = CA.Groups()[1]
check(TargetName(g1) == "coraap", "with the nano gone the lab is still a target: got " .. tostring(TargetName(g1)))
KillGators(); ClearEnemy(); Run(3)

-- (l) the commander: when it is open every group goes for it; when it is guarded none does
local cmdr = S.Spawn("corcom", 1, fx, fz, { silent = true })
local nanoK = S.Spawn("cornanotc", 1, fx + px * 1200, fz + pz * 1200, { silent = true })
for _ = 1, 3 do Gators(15, hx, hz); Run(3) end
local cg = CA.Groups()
local allCmdr = #cg == 3
for _, g in ipairs(cg) do if not (g.target and g.target.commander) then allCmdr = false end end
check(allCmdr, "an open commander is every group's target (no spreading out)")
check(Count("%[CK%] .*enemy COMMANDER is open") == 3, "each group logs the open commander")

local guards = {}
for i = 1, 40 do guards[#guards + 1] = S.Spawn("corak", 1, fx + 200 + i * 6, fz + 100, { silent = true }) end
Run(2)
local anyCmdr = false
for _, g in ipairs(CA.Groups()) do if g.target and g.target.commander then anyCmdr = true end end
check(not anyCmdr, "a guarded commander is not targeted")
check(Count("%[CK%] .*commander is no longer open") >= 1, "dropping the commander is logged")
for _, id in ipairs(guards) do S.Kill(id) end
Run(2)
local backOn = 0
for _, g in ipairs(CA.Groups()) do if g.target and g.target.commander then backOn = backOn + 1 end end
check(backOn >= 1, "the groups return to the commander once the guard is gone")
for _ = 1, 200 do     -- ~7 km of legs at one per ~3 s, then the attack
    Run(1)
    if not W.units[cmdr] then break end
end
check(not W.units[cmdr], "the groups ATTACK the commander and kill it")
check(Count("%[CK%] .*KILL corcom") >= 1, "the commander kill is credited")
KillGators(); ClearEnemy(); Run(3)

-- (m) the slow group TRADES: Pounders (screen) in front, Lashers (support) behind, FIGHT only, no
-- building targets, the screen answers a threat to the support, and it pulls back when outvalued
KillGators(); ClearEnemy()
for id, u in pairs(W.units) do
    local n = u.team == 0 and UnitDefs[u.defID].name
    if n == "corsumo" or n == "cormist" or n == "corlevlr" then S.Kill(id) end
end
Run(3)
local function SlowUnits(name, n, x, z)
    local ids = {}
    for i = 1, n do
        local id = S.Spawn(name, 0, x + i * 7, z, { silent = true })
        combat[id] = UnitDefNames[name].id
        ids[#ids + 1] = id
    end
    return ids
end
local function SlowG() for _, g in ipairs(CA.Groups()) do if g.slow then return g end end end
S.Spawn("cornanotc", 1, fx, fz, { silent = true })        -- a building the fast groups would hunt
local lashers  = SlowUnits("cormist", 8, hx, hz)          -- 8 x ~189
local pounders = SlowUnits("corlevlr", 4, hx, hz)         -- 4 x ~257
Gators(10, hx, hz)
for _ = 1, 6 do Run(1); if SlowG() then break end end
local slowGroup = SlowG()
check(slowGroup ~= nil, "Lashers and Pounders launch as the slow group")
local lashSet, pounSet = {}, {}
for _, id in ipairs(lashers) do lashSet[id] = true end
for _, id in ipairs(pounders) do pounSet[id] = true end
local function Mean(set)
    local s, n = 0, 0
    for _, o in ipairs(seenOrders) do
        if set[o.id] and o.cmd == 16 and o.params then
            s = s + math.sqrt((o.params[1] - fx) ^ 2 + (o.params[3] - fz) ^ 2); n = n + 1
        end
    end
    return n > 0 and s / n or nil, n
end
-- the units were just sent to the stage, so the broker holds the next order back for ~3 ticks;
-- look tick by tick until both kinds are ordered in the same tick (they share the same centre then)
local dL, nL, dP, nP
local badCmd = 0
for _ = 1, 14 do
    seenOrders = {}
    Run(1)
    for _, o in ipairs(seenOrders) do
        if (lashSet[o.id] or pounSet[o.id]) and o.cmd ~= 16 and o.cmd ~= 10 then badCmd = badCmd + 1 end
    end
    dL, nL = Mean(lashSet)
    dP, nP = Mean(pounSet)
    if nL and nL > 0 and nP and nP > 0 then break end
end
check(nL == 8 and nP == 4, string.format("every Lasher and Pounder got a FIGHT order in one tick (%s, %s)", tostring(nL), tostring(nP)))
check(dL and dP and dL > dP + 300, string.format("the Lashers' spot is behind the Pounders' (%.0f vs %.0f from the enemy)", dL or 0, dP or 0))
check(badCmd == 0, "the slow group is never given an ATTACK order (it trades, it does not hunt buildings)")
check(Count("%[CK%] .*group #" .. slowGroup.id .. " target") == 0, "the slow group does not hunt buildings")

-- The slow group moves as LINES, not one ball: 4 Lashers deep per spot, widening only once a spot is
-- full (8 Lashers = 2 spots wide).  `seenOrders` still holds the one tick in which all 8 were ordered.
local function Spots(points, tx, tz, cxp, czp)
    -- cluster the points by where they stand ACROSS the line (the line faces from (cxp,czp) toward (tx,tz))
    local dxx, dzz = tx - cxp, tz - czp
    local l = math.sqrt(dxx * dxx + dzz * dzz)
    local ux, uz = dxx / l, dzz / l
    local pxx, pzz = -uz, ux
    local vals = {}
    for _, p in ipairs(points) do vals[#vals + 1] = { lat = p[1] * pxx + p[2] * pzz, fwd = p[1] * ux + p[2] * uz } end
    table.sort(vals, function(a, b) return a.lat < b.lat end)
    local out = {}
    for _, v in ipairs(vals) do
        local c = out[#out]
        if c and math.abs(v.lat - c.last) < 40 then
            c.n, c.last = c.n + 1, v.lat
            c.fmin, c.fmax = math.min(c.fmin, v.fwd), math.max(c.fmax, v.fwd)
        else
            out[#out + 1] = { n = 1, first = v.lat, last = v.lat, fmin = v.fwd, fmax = v.fwd }
        end
    end
    return out
end
local function SlotPoints(set)        -- the FIGHT targets in `seenOrders` for the units in `set`
    local pts = {}
    for _, o in ipairs(seenOrders) do
        if set[o.id] and o.cmd == 16 and o.params then pts[#pts + 1] = { o.params[1], o.params[3] } end
    end
    return pts
end
do
    local lpts = SlotPoints(lashSet)
    local lcx, lcz = 0, 0
    for _, id in ipairs(lashers) do lcx, lcz = lcx + W.units[id].x, lcz + W.units[id].z end
    lcx, lcz = lcx / #lashers, lcz / #lashers
    local spots = Spots(lpts, sgb and sgb.objX or fx, sgb and sgb.objZ or fz, lcx, lcz)
    check(#lpts == 8, "all 8 Lashers have their own spot in the line (" .. #lpts .. ")")
    check(#spots == 2, string.format("8 Lashers form 2 spots across, not one ball (%d)", #spots))
    local fullSpots = 0
    for _, s in ipairs(spots) do if s.n == 4 then fullSpots = fullSpots + 1 end end
    check(fullSpots == 2, "...each 4 deep")
    local spans = true
    for _, s in ipairs(spots) do
        if not (s.fmax - s.fmin > 120 and s.fmax - s.fmin < 210) then spans = false end
    end
    check(spans, "...with the 4 spaced out front to back (about 3 x 55 elmos)")
    check(#spots == 2 and math.abs((spots[2].first - spots[1].first) - 110) < 40, "...and the spots 110 elmos apart across the line")
    local ppts = SlotPoints(pounSet)
    local pspots = Spots(ppts, sgb and sgb.objX or fx, sgb and sgb.objZ or fz, lcx, lcz)
    -- (the screen also holds the Gator escorts, so there are more than 4 screen units: judge the WIDTH)
    local lo, hi = math.huge, -math.huge
    local sdx, sdz = (sgb and sgb.objX or fx) - lcx, (sgb and sgb.objZ or fz) - lcz
    local sl = math.sqrt(sdx * sdx + sdz * sdz)
    for _, p in ipairs(ppts) do
        local lat = p[1] * (-sdz / sl) + p[2] * (sdx / sl)
        lo, hi = math.min(lo, lat), math.max(hi, lat)
    end
    check(#ppts == 4 and hi - lo >= 100, string.format("the Pounders spread across the line, at least as wide as the Lashers' 2 spots (%.0f elmos)", hi - lo))
end

-- Range kiting.  Every weapon in the stub has range 300 except the Lashers' missile (700), so R = 700.
-- The Lashers are only worth anything while they FIRE: out of range they close in, in range they
-- stand and shoot, and when they are at risk of dying they back off only as far as keeps the enemy in range.
local R = 700
local function Dist2D(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end
local function Positions(set)
    local p = {}
    for id in pairs(set) do local u = W.units[id]; if u then p[id] = { u.x, u.z } end end
    return p
end
local function LasherCentre()
    local sx, sz, n = 0, 0, 0
    for _, id in ipairs(lashers) do
        local u = W.units[id]
        if u then sx, sz, n = sx + u.x, sz + u.z, n + 1 end
    end
    return sx / n, sz / n
end
local function Cluster(cx, cz, n)         -- n enemy AKs packed around a point; returns their ids
    local ids = {}
    for i = 1, n do
        ids[#ids + 1] = S.Spawn("corak", 1, cx + (i % 12) * 5, cz + math.floor(i / 12) * 5, { silent = true })
    end
    return ids
end
local function NearestTo(x, z, ids)
    local best
    for _, id in ipairs(ids) do
        local u = W.units[id]
        if u then
            local d = Dist2D(u.x, u.z, x, z)
            if not best or d < best then best = d end
        end
    end
    return best
end
-- run `n` ticks one at a time; for every order to a Lasher return {cmd, target x, z, start x, z}
local function LasherOrders(n)
    local out = {}
    for _ = 1, n do
        local pre = Positions(lashSet)
        seenOrders = {}
        Run(1)
        for _, o in ipairs(seenOrders) do
            if lashSet[o.id] and pre[o.id] and o.params then
                out[#out + 1] = { cmd = o.cmd, x = o.params[1], z = o.params[3], sx = pre[o.id][1], sz = pre[o.id][2] }
            end
        end
    end
    return out
end

-- The slow group ATTACKS THE OTHER SIDE.  Its objective is the enemy's main base (the densest cluster of
-- structures), not a stray mex, and not units.
local baseX, baseZ = 0, 0
for _, id in ipairs({ S.Spawn("cornanotc", 1, fx + 80, fz + 80, { silent = true }),
                      S.Spawn("cornanotc", 1, fx - 80, fz + 40, { silent = true }),
                      S.Spawn("cormex",    1, fx + 200, fz - 100, { silent = true }) }) do
    baseX = baseX + W.units[id].x; baseZ = baseZ + W.units[id].z
end
S.Spawn("cormex", 1, 900, 11400, { silent = true })          -- a lone mex far across the map
Run(12)                                                       -- the base is re-picked every 300 frames
local sgb = SlowG()
check(sgb and sgb.objKind == "base", "the slow group's objective is the enemy base")
check(sgb and Dist2D(sgb.objX, sgb.objZ, fx, fz) < 1500, string.format("...the dense cluster at the enemy start, not the lone mex (%.0f off)",
      sgb and Dist2D(sgb.objX, sgb.objZ, fx, fz) or -1))

-- a stray enemy unit 700 away (out of the Lashers' 300 range, worth nothing next to the group): NOT chased.
-- The group keeps marching on the base: every Lasher order makes progress toward it and none toward the stray.
local lx, lz = LasherCentre()
local ex, ez = lx + px * 700, lz + pz * 700
local lone = S.Spawn("corak", 1, ex, ez, { silent = true })
local ords = LasherOrders(8)
local toward, chase, orders = 0, 0, 0
for _, o in ipairs(ords) do
    if o.cmd == 16 then
        orders = orders + 1
        if Dist2D(o.x, o.z, sgb.objX, sgb.objZ) < Dist2D(o.sx, o.sz, sgb.objX, sgb.objZ) - 50 then toward = toward + 1 end
        if Dist2D(o.x, o.z, ex, ez) < Dist2D(o.sx, o.sz, ex, ez) - 100 then chase = chase + 1 end
    end
end
check(orders >= 8 and toward >= orders - 2, string.format("a stray does not stop the march: orders keep going toward the base (%d of %d)", toward, orders))
check(chase == 0, string.format("...and the Lashers are not sent after the stray (%d orders move toward it)", chase))
S.Kill(lone)

-- but an enemy right on top of a Lasher (inside 450) is answered by the Pounders stepping out to it
lx, lz = LasherCentre()
local cx2, cz2 = lx + px * 350, lz + pz * 350
local close = S.Spawn("corak", 1, cx2, cz2, { silent = true })
seenOrders = {}
Run(5)
local goes = false
for _, o in ipairs(seenOrders) do
    if pounSet[o.id] and o.cmd == 16 and o.params and Dist2D(o.params[1], o.params[3], cx2, cz2) < 80 then goes = true end
end
check(goes, "the Pounders step out to an enemy on top of the Lashers")
check(SlowG() and not SlowG().pulled, "a lone raider does not make the group pull back")
S.Kill(close)

-- a REAL fight (enemy value about 0.8 of ours: not enough to pull back, plenty to stop for) 700 away: the
-- Lashers close in until the enemy is in range, so they are firing
ClearEnemy(); Run(2)
lx, lz = LasherCentre()
local fightN = math.floor(0.8 * SlowG().value / 50)
local army = Cluster(lx + px * 1000, lz + pz * 1000, fightN)    -- 1,000 away: out of the 700 range
local ords2 = LasherOrders(8)
local closer = 0
for _, o in ipairs(ords2) do
    if o.cmd == 16 and NearestTo(o.x, o.z, army) < NearestTo(o.sx, o.sz, army) - 100 then closer = closer + 1 end
end
check(SlowG() and not SlowG().pulled, "0.8x is a fight, not a reason to pull back")
check(closer >= 4, string.format("in a real fight the Lashers close in until the enemy is in range (%d orders)", closer))
for _, id in ipairs(army) do S.Kill(id) end

-- who may defend the base: a unit in an attack group never; one that is in no group (a fighter, a
-- reinforcement waiting at the stage) may
local fighter = S.Spawn("corveng", 0, hx, hz, { silent = true })
combat[fighter] = UnitDefNames.corveng.id
Run(2)
check(CA.InGroup(lashers[1]) and CA.InGroup(pounders[1]), "Lashers and Pounders in the slow group are committed (never pulled home)")
check(not CA.InGroup(fighter), "a fighter in no attack group is free to defend")
S.Kill(fighter)

-- AT RISK OF DYING: outvalued (130 AKs, about 6,500 against ~3,400) with the enemy right on top of the
-- Lashers (250 away, inside 0.6 x their 700 range).  They back off, but only as far as keeps the enemy in range.
ClearEnemy(); Run(2)
lx, lz = LasherCentre()
-- (enemies are placed straight ahead along the march, so the line does not have to turn to face them)
local function Ahead(len)
    local g = SlowG()
    local dx, dz = (g and g.objX or fx) - lx, (g and g.objZ or fz) - lz
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1 then return 1, 0 end
    return dx / l, dz / l
end
local ax1, az1 = Ahead(1)
local crowd = Cluster(lx + ax1 * 250, lz + az1 * 250, 130)
local moved, stayedIn, farther, shortStep, pounMoves = 0, 0, 0, 0, 0
for _ = 1, 10 do
    local pre = Positions(lashSet)
    seenOrders = {}
    Run(1)
    for _, o in ipairs(seenOrders) do
        if pounSet[o.id] and o.cmd == 10 then pounMoves = pounMoves + 1 end
        if lashSet[o.id] and o.cmd == 10 and pre[o.id] and o.params then
            moved = moved + 1
            local before = NearestTo(pre[o.id][1], pre[o.id][2], crowd)
            local after  = NearestTo(o.params[1], o.params[3], crowd)
            if after <= R then stayedIn = stayedIn + 1 end
            if after > before then farther = farther + 1 end
            if Dist2D(o.params[1], o.params[3], pre[o.id][1], pre[o.id][2]) <= 520 then shortStep = shortStep + 1 end
        end
    end
    if moved >= 8 then break end
end
check(SlowG() and SlowG().pulled, "at risk (outvalued, enemy on top of them): the support pulls back")
check(Count("%[CK%] .*SLOW group #%d+ pulls back") == 1, "the pull-back is logged")
check(moved >= 8, "the Lashers back off (MOVE)")
check(farther == moved, "...each one further from the enemy than it was")
check(stayedIn == moved, "...but every step ends with the enemy still inside their range, so they keep firing")
check(shortStep == moved, "...in a short step (a few hundred elmos, re-slotting included), not a long retreat")
check(pounMoves == 0, "the Pounders hold the line while the Lashers give ground")

-- NOT at risk, though outvalued: the enemy is at the edge of their range, so they just keep firing
for _, id in ipairs(crowd) do S.Kill(id) end
lx, lz = LasherCentre()
-- 660 away is the edge of the 700 range (inside 0.95 x range, so they hold and shoot), well beyond 0.6 x
-- range, so the enemy is not "on top of them"
local ax2, az2 = Ahead(1)
local crowd2 = Cluster(lx + ax2 * 660, lz + az2 * 660, 130)         -- 660 straight ahead: the cluster's nearest unit
local lm, lf = 0, 0
local nearestBefore = NearestTo(lx, lz, crowd2)
for _, o in ipairs(LasherOrders(10)) do
    if o.cmd == 10 then lm = lm + 1 elseif o.cmd == 16 then lf = lf + 1 end
end
lx, lz = LasherCentre()
-- holding means HOLDING: they used to slide back half a depth each pass (out of range) and the Pounders crept
-- 250 forward each pass (into the enemy).  The one deliberate move is closing from 0.95 to 0.8 x range when the
-- enemy slips just out of range.  So after 10 passes they are still IN range and not in danger.
local nearestAfter = NearestTo(lx, lz, crowd2)
check(nearestAfter <= R and nearestAfter >= 0.6 * R,
      string.format("...and they stay in range without walking into the enemy (%.0f -> %.0f from it; range %d)", nearestBefore, nearestAfter, R))
local screenAfter = NearestTo(SlowG().cx, SlowG().cz, crowd2)
check(screenAfter > 0.3 * R, string.format("...and the screen has not crept into the enemy (%.0f from it)", screenAfter))
check(SlowG() and not SlowG().pulled, "outvalued but the enemy is at the edge of range: not at risk, no pull-back")
check(Count("%[CK%] .*SLOW group #%d+ goes back in") == 1, "going back in is logged")
check(lm == 0 and lf >= 8, string.format("at the edge of its range the support keeps firing (FIGHT), it does not back off (%d MOVE, %d FIGHT)", lm, lf))
for _, id in ipairs(crowd2) do S.Kill(id) end
Run(4)
check(SlowG() and not SlowG().pulled, "with the enemy gone the slow group stays on the march")

-- a single Lasher low on health with the enemy near backs off on its own; the rest of the line keeps firing
ClearEnemy(); Run(2)
lx, lz = LasherCentre()
local ax3, az3 = Ahead(1)
local few = Cluster(lx + ax3 * 400, lz + az3 * 400, 3)          -- 3 AKs: not a fight, not a threat to the group
W.units[lashers[1]].hp = 100                                    -- 10% health
local fragileMoves, otherMoves, fragileFarther = 0, 0, 0
for _ = 1, 10 do
    local pre = Positions(lashSet)
    seenOrders = {}
    Run(1)
    for _, o in ipairs(seenOrders) do
        if lashSet[o.id] and o.cmd == 10 and pre[o.id] and o.params then
            if o.id == lashers[1] then
                fragileMoves = fragileMoves + 1
                if NearestTo(o.params[1], o.params[3], few) > NearestTo(pre[o.id][1], pre[o.id][2], few) then fragileFarther = fragileFarther + 1 end
            else
                otherMoves = otherMoves + 1
            end
        end
    end
    if fragileMoves > 0 then break end
end
check(fragileMoves >= 1 and fragileFarther == fragileMoves, "a Lasher at 10% health with the enemy near steps back from it")
check(otherMoves == 0, "...while the healthy Lashers keep firing (no MOVE)")
W.units[lashers[1]].hp = 1000
for _, id in ipairs(few) do S.Kill(id) end
Run(3)

KillGators(); ClearEnemy()
for id, u in pairs(W.units) do
    local n = u.team == 0 and UnitDefs[u.defID].name
    if n == "corsumo" or n == "cormist" or n == "corlevlr" then S.Kill(id) end
end
Run(4)

-- 20 Lashers = a line 5 spots wide, 4 deep (the line grows with the army): a fresh launch, so every unit
-- is slotted in the same pass
do
    local L20 = SlowUnits("cormist", 20, hx, hz)
    SlowUnits("corlevlr", 8, hx, hz)
    local set20 = {}
    for _, id in ipairs(L20) do set20[id] = true end
    local pts20
    for _ = 1, 24 do
        seenOrders = {}
        Run(1)
        local pts = {}
        for _, o in ipairs(seenOrders) do
            if set20[o.id] and o.cmd == 16 and o.params then pts[#pts + 1] = { o.params[1], o.params[3] } end
        end
        if #pts == 20 then pts20 = pts; break end
    end
    check(pts20 ~= nil, "all 20 Lashers get their spot in the same pass")
    if pts20 then
        local g20 = SlowG()
        local mx_, mz_ = 0, 0
        for _, id in ipairs(L20) do mx_, mz_ = mx_ + W.units[id].x, mz_ + W.units[id].z end
        mx_, mz_ = mx_ / 20, mz_ / 20
        local spots20 = Spots(pts20, g20.objX, g20.objZ, mx_, mz_)
        local full20 = 0
        for _, s in ipairs(spots20) do if s.n == 4 then full20 = full20 + 1 end end
        check(#spots20 == 5 and full20 == 5, string.format("20 Lashers form a line 5 spots wide, each 4 deep (%d spots, %d full)", #spots20, full20))
    end
    KillGators(); ClearEnemy()
    for id, u in pairs(W.units) do
        local n = u.team == 0 and UnitDefs[u.defID].name
        if n == "corsumo" or n == "cormist" or n == "corlevlr" then S.Kill(id) end
    end
    Run(4)
end

-- a hurt squad with enemies near (outvaluing it) retreats
local qx, qz = sx - 1800, sz - 1800          -- apart from the staged units, as a separate small group
local sq = Gators(4, qx, qz)
for _, id in ipairs(sq) do W.units[id].hp = 400 end
for i = 1, 14 do S.Spawn("corak", 1, qx + 300 + i * 10, qz, { silent = true }); end
EI.Scan(frame)
Run(3)
local retreating = 0
for _, id in ipairs(sq) do if CA.IsSquadRetreating(id) then retreating = retreating + 1 end end
check(retreating == 4, "a hurt squad of 4 with enemies near retreats")
check(Count("%[CK%].*squad retreat") >= 1, "squad retreat is logged")

-- bombers wait for BOMBER_MIN, then strike together
for i = 1, 7 do
    local id = S.Spawn("corbw", 0, hx, hz, { silent = true }); bombers[id] = true
end
seenOrders = {}
S.Spawn("cornanotc", 1, fx + 600, fz + 600, { silent = true })
Run(4)
check(Count("%[CK%].*bomber run") == 0, "7 bombers wait")
local id8 = S.Spawn("corbw", 0, hx, hz, { silent = true }); bombers[id8] = true
Run(4)
check(Count("%[CK%].*bomber run: 8 bombers") == 1, "8 bombers strike")
local bombOrders = 0
for _, o in ipairs(seenOrders) do if o.cmd == 20 then bombOrders = bombOrders + 1 end end
check(bombOrders >= 8, "every bomber got an ATTACK order")

local fights = 0
for _, o in ipairs(seenOrders) do if o.cmd == 16 then fights = fights + 1 end end
check(fights == 0, "click_army never attack-moves")
for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "no Lua errors in the click_army run")

-- â”€â”€ 1b. Scout calls: the lab controller keeps Hawks for the groups, in ONE T2 air lab â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function HawkCount(callScouts)
    Reset()
    W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 800, 1000, 60, 5
    S.LoadWidget("candidates/LINE_CLICK/lab_controller.lua")
    S.Callin("Initialize")
    S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
    local labA = S.Spawn("coraap", 0, W.start[0][1] + 300, W.start[0][2])
    local labB = S.Spawn("coraap", 0, W.start[0][1] + 600, W.start[0][2])
    local byLab = {}
    W.widgets[#W.widgets + 1] = { _file = "count", UnitFromFactory = function(_, id, defID, team, lab)
        if UnitDefs[defID].name == "corawac" then byLab[lab] = (byLab[lab] or 0) + 1 end
    end }
    WG.MetalBot = { scoutWant = 0, callScouts = callScouts }
    for f = 0, 6000, 10 do S.Frame(f) end
    local n = 0
    for _, c in pairs(byLab) do n = n + c end
    return n, byLab, labA, labB
end
for _, e in ipairs(W.errors) do print("LUA ERROR (lab): " .. e) end
local n0 = HawkCount(0)
local n4, by4, la, lb = HawkCount(4)
check(n0 == 1, string.format("no scout calls: only the radar plane (%d Hawks)", n0))
check(n4 == 5, string.format("4 scout calls: the radar plane + 4 Hawks (%d)", n4))
local labsUsed = 0
for _ in pairs(by4) do labsUsed = labsUsed + 1 end
check(labsUsed == 1, "all the Hawks come from one T2 air lab")
check(#W.errors == 0, "no Lua errors in the lab test")

-- â”€â”€ 1c. What the labs build for the slow group â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

-- Run one lab for a while against a fake spine and count what it made, in order.
local function LabRun(kind)
    Reset()
    W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 5000, 10000, 200, 5
    S.LoadWidget("candidates/LINE_CLICK/lab_controller.lua")
    S.Callin("Initialize")
    S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
    local lab = S.Spawn(kind == "t1" and "corvp" or "coralab", 0, W.start[0][1] + 300, W.start[0][2])
    local made, order = {}, {}
    W.widgets[#W.widgets + 1] = { _file = "count", UnitFromFactory = function(_, id, defID)
        local n = UnitDefs[defID].name
        made[n] = (made[n] or 0) + 1; order[#order + 1] = n
    end }
    WG.MetalBot = { scoutWant = 0 }
    WG.Spine = {
        IsLab = function(id) return id == lab end,
        IsT1Lab = function() return kind == "t1" end,
        Share = function() return 1 end,
        CFG = { QUEUE_DEPTH = 3 },
        NextOrder = function() if kind == "t2" then return UnitDefNames.corsumo.id end return nil end,
    }
    for f = 0, 12000, 10 do S.Frame(f) end
    return made, order
end
local function Val(n) local d = UnitDefNames[n]; return d.metalCost + d.energyCost / 70 end

local t1, t1order = LabRun("t1")
local slowV = (t1.cormist or 0) * Val("cormist") + (t1.corlevlr or 0) * Val("corlevlr")
local fastV = (t1.corgator or 0) * Val("corgator") + (t1.corraid or 0) * Val("corraid")
local share = slowV / math.max(1, slowV + fastV)
check((t1.cormist or 0) > 3 and (t1.corlevlr or 0) > 1, "the vehicle plant builds Lashers and Pounders")
check(share > 0.25 and share < 0.45, string.format("slow units are about a third of the plant's value (%.2f)", share))
local ratio = (t1.cormist or 0) / math.max(1, t1.corlevlr or 0)
check(ratio > 1.4 and ratio < 2.6, string.format("about two Lashers per Pounder (%.2f)", ratio))
check((t1.corgator or 0) + (t1.corraid or 0) > 0, "the fast groups still get their Gators/Raiders")
check(t1order[1] == "corgator", "the first unit is a fast one (defence before the support)")

local t2, t2order = LabRun("t2")
local mamV, shelV = (t2.corsumo or 0) * Val("corsumo"), (t2.cormort or 0) * Val("cormort")
local share2 = shelV / math.max(1, mamV + shelV)
-- T2_SLOW_SHARE = 0 while the slow group is played by hand: Mammoths only, no Sheldons
check((t2.corsumo or 0) >= 2 and (t2.cormort or 0) == 0, "the T2 bot lab builds Mammoths and no Sheldons")
check(t2order[1] == "corsumo", "the first T2 unit is a Mammoth (the screen before the support)")
check(#W.errors == 0, "no Lua errors in the lab mix runs")

-- â”€â”€ 2. Smoke run + guard cap â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

-- Run one bot's three widgets for `minutes` of game time with healthy metal income; returns
-- how many Shuriken/Wasp guards the labs ordered, the guard value, the log, errors.
handIds, handOrders, handCmds = {}, 0, {}
local function Smoke(dir, minutes)
    Reset()
    W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 400, 1000, 40, 5
    S.LoadWidget(dir .. "/macro_controller.lua")
    S.LoadWidget(dir .. "/lab_controller.lua")
    S.LoadWidget(dir .. "/unit_controller.lua")
    local made, value = 0, 0
    W.widgets[#W.widgets + 1] = { _file = "count", UnitCreated = function(_, id, defID, team)
        local n = UnitDefs[defID].name
        if team == 0 and (n == "corbw" or n == "corape") then
            made = made + 1; value = value + UnitDefs[defID].metalCost + UnitDefs[defID].energyCost / 70
        end
    end }
    S.Callin("Initialize")
    S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
    S.Spawn("corcom", 1, W.start[1][1], W.start[1][2])
    S.Spawn("cornanotc", 1, W.start[1][1] + 150, W.start[1][2], { silent = true })
    S.Spawn("cormex",    1, W.start[1][1] - 150, W.start[1][2], { silent = true })
    local hawkIds, hawkTargets = {}, {}
    handIds, handOrders, handCmds = {}, 0, {}
    local giveOrder = Spring.GiveOrderToUnit
    Spring.GiveOrderToUnit = function(id, cmd, params, opts)
        if handIds[id] then
            handOrders = handOrders + 1
            handCmds[cmd] = (handCmds[cmd] or 0) + 1
        end
        if hawkIds[id] and cmd == 10 and params and params[1] then
            hawkTargets[#hawkTargets + 1] = { id, params[1], params[3] }
        end
        return giveOrder(id, cmd, params, opts)
    end
    for f = 0, minutes * 1800, 10 do
        W.res.metal.cur = (f % 3000 < 300) and 600 or 300
        if f == 11 * 1800 then       -- a raid on the main base
            -- behind our contact line (the dispatch only counts enemies that got past it), by the base
            for i = 1, 6 do S.Spawn("corak", 1, W.start[0][1] - 300 + i * 15, W.start[0][2] - 100) end
        end
        if f == 12 * 1800 then       -- ...and it is over (the stub does not kill on FIGHT)
            for id, u in pairs(W.units) do
                if u.team == 1 and UnitDefs[u.defID].name == "corak" then S.Kill(id) end
            end
        end
        if f == 7 * 1800 then
            for i = 1, 40 do S.Spawn("corgator", 0, W.start[0][1] + i * 6, W.start[0][2] + 300) end
            for i = 1, 3 do S.Spawn("corsumo", 0, W.start[0][1] + i * 9, W.start[0][2] + 350) end
            for i = 1, 4 do hawkIds[S.Spawn("corawac", 0, W.start[0][1] + i * 9, W.start[0][2] + 380)] = true end
            -- a reclaim field about halfway to the enemy: armed wrecks (to raise) and a heap of scrap
            local fx = W.start[0][1] + (W.start[1][1] - W.start[0][1]) * 0.45
            local fz = W.start[0][2] + (W.start[1][2] - W.start[0][2]) * 0.45
            for i = 1, 6 do S.AddFeature(fx + i * 30, fz, 150, "corgator") end
            for i = 1, 4 do S.AddFeature(fx, fz + i * 30, 120, "") end
            for i = 1, 4 do      -- Lashers and Pounders: the slow group (slow_front.lua)
                handIds[S.Spawn("cormist", 0, W.start[0][1] + i * 9, W.start[0][2] + 400)] = true
                handIds[S.Spawn("corlevlr", 0, W.start[0][1] + i * 9, W.start[0][2] + 420)] = true
            end
            for i = 1, 2 do handIds[S.Spawn("cornecro", 0, W.start[0][1] + i * 9, W.start[0][2] + 440)] = true end   -- rez bots
        end
        S.Frame(f)
        if #W.errors > 0 then break end
    end
    Spring.GiveOrderToUnit = giveOrder
    local distinct, seen = 0, {}
    for _, t in ipairs(hawkTargets) do
        local k = math.floor(t[2] / 500) .. "," .. math.floor(t[3] / 500)
        if not seen[k] then seen[k] = true; distinct = distinct + 1 end
    end
    return made, value, W.log, W.errors, distinct
end

local madeC, valueC, logC, errC, hawkSpots = Smoke("candidates/LINE_CLICK", 14)
for _, e in ipairs(errC) do print("LUA ERROR (LINE_CLICK): " .. e) end
check(#errC == 0, "LINE_CLICK widgets run 14 minutes without Lua errors")
local function Any(log, p) for _, l in ipairs(log) do if l:find(p) then return true end end return false end
check(Any(logC, "%[CK%] .*stage point"), "click_army is live inside the unit controller")
check(not Any(logC, "ERROR loading click_army"), "click_army loaded")
check(Any(logC, "%[CK%] .*group #%d+ launch"), "a group launches inside the unit controller")
check(not Any(logC, "%[CK%] .*SLOW group #%d+ launch"), "click_army has no slow group of its own")
check(not Any(logC, "ERROR loading slow_front"), "slow_front loaded")
check(Any(logC, "%[SF%] .*slow group launches"), "the slow group (Lashers/Pounders) launches")
check(Any(logC, "%[SF%] .*objective: field"), "the slow group goes for the wreck field")
check((handCmds[16] or 0) >= 8, string.format("the slow group is given FIGHT orders (%d)", handCmds[16] or 0))
check((handCmds[125] or 0) >= 1, string.format("the rez bots resurrect wrecks (%d RESURRECT orders)", handCmds[125] or 0))
check((handCmds[90] or 0) >= 1, string.format("the rez bots reclaim scrap (%d RECLAIM orders)", handCmds[90] or 0))
check(hawkSpots >= 3, string.format("the Hawks were sent to several different spots (%d)", hawkSpots))
check(Any(logC, "%[UC/respond%]"), "a raid on the main base is answered (by the units that are allowed to)")
check(valueC <= 3500 + 400, string.format("guard value stays within GUARD_MAX (%.0f)", valueC))

-- LINE_CLICK_v3 (2026-10-08): click_army FORWARD_CORE + commander safety (commander_guard: evade, cloak)
do
    local _, _, logV, errV = Smoke("candidates/LINE_CLICK_v3", 14)
    for _, e in ipairs(errV) do print("LUA ERROR (LINE_CLICK_v3): " .. e) end
    check(#errV == 0, "LINE_CLICK_v3 widgets run 14 minutes without Lua errors")
    check(not Any(logV, "ERROR loading commander_guard"), "v3: commander_guard loaded")
    check(Any(logV, "%[CK%] .*group #%d+ launch"), "v3: a group launches")
    check(Any(logV, "%[CG%] .*commander evading"), "v3: the commander walks away from the raid on the base")
    -- (the stub builds instantly, so the commander's lane is done long before the 11:00 raid: it has retired by then)
    check(Any(logV, "%[LN%] .*commander leaves the line for its safe spot"), "v3: the commander retires from the line")
    check(Any(logV, "%[CG%] .*commander builds %d+ defences at its safe spot"), "v3: and builds its defences at the safe spot")
end

-- LINE_CLICK_v3b: the commander stays in its lane and evades only a real dive (value >= 1500): the stub's raid is
do
    -- 6 Ak (~300), so it must NOT leave
    local _, _, logB3, errB3 = Smoke("candidates/LINE_CLICK_v3b", 14)
    for _, e in ipairs(errB3) do print("LUA ERROR (LINE_CLICK_v3b): " .. e) end
    check(#errB3 == 0, "LINE_CLICK_v3b widgets run 14 minutes without Lua errors")
    check(not Any(logB3, "%[CG%] .*commander evading"), "v3b: the commander does not run from 6 Ak (under DANGER_VALUE)")
    check(not Any(logB3, "%[LN%] .*commander leaves the line"), "v3b: the commander does not retire")
end

-- LINE_CLICK_v4e: line_transition ENERGY_PUSH on (the stub rarely meets its trigger: this checks the code runs)
do
    local _, _, logE, errE = Smoke("candidates/LINE_CLICK_v4e", 14)
    for _, e in ipairs(errE) do print("LUA ERROR (LINE_CLICK_v4e): " .. e) end
    check(#errE == 0, "LINE_CLICK_v4e widgets run 14 minutes without Lua errors")
end

-- LINE_CLICK_v5e: the commander helps the outer-lane cons with their jobs (the stub builds instantly, so this
do
    -- checks the code runs, not that the help happens)
    local _, _, logH, errH = Smoke("candidates/LINE_CLICK_v5e", 14)
    for _, e in ipairs(errH) do print("LUA ERROR (LINE_CLICK_v5e): " .. e) end
    check(#errH == 0, "LINE_CLICK_v5e widgets run 14 minutes without Lua errors")
    check(Any(logH, "%[CK%] .*group #%d+ launch"), "v5e: a group launches")
end

-- LINE_CLICK_v12: the overnight combination (FORWARD_CORE + FLANK + ENERGY_PUSH + commander evades real dives)
do
    local _, _, log12, err12 = Smoke("candidates/LINE_CLICK_v12", 14)
    for _, e in ipairs(err12) do print("LUA ERROR (LINE_CLICK_v12): " .. e) end
    check(#err12 == 0, "LINE_CLICK_v12 widgets run 14 minutes without Lua errors")
    check(Any(log12, "%[CK%] .*group #%d+ launch"), "v12: a group launches")
    check(not Any(log12, "%[LN%] .*commander leaves the line"), "v12: the commander does not retire")
end

-- LINE_CLICK_v13: grid expansion switches, 10% army floor, Mammoths/Sheldons in the slow group, 30+ rez bots
-- (brave), Shuriken stun allocation
do
    local _, _, log13, err13 = Smoke("candidates/LINE_CLICK_v13", 14)
    for _, e in ipairs(err13) do print("LUA ERROR (LINE_CLICK_v13): " .. e) end
    check(#err13 == 0, "LINE_CLICK_v13 widgets run 14 minutes without Lua errors")
    check(Any(log13, "%[CK%] .*group #%d+ launch"), "v13: a group launches")
    local rez = 0
    for _, l in ipairs(log13) do if l:find("%[LabCtrl%] .* rez%s+cornecro") then rez = rez + 1 end end
    -- (informational: in the stub the only lab that can make cornecro is the starter bot lab, which is reclaimed;
    -- in a real game the spine's T1 cell has its own bot lab)
    print(string.format("v13: %d rez bot orders in 14 min (stub)", rez))
end

local madeB, valueB = Smoke("LINE_BOT", 14)
print(string.format("guards built in 14 min at 40 m/s: LINE_BOT %d (value %.0f), LINE_CLICK %d (value %.0f)",
    madeB, valueB, madeC, valueC))
check(madeC <= madeB, "LINE_CLICK builds no more guards than LINE_BOT")

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)

