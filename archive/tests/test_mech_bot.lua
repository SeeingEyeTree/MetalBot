-- tests/test_mech_bot.lua
-- Run from the repo root:  lua5.1 tests/test_mech_bot.lua [-v]
--
-- Two parts:
--   1. Unit checks on the MECH_BOT framework modules (enemy_intel, endgame, raid_group,
--      recon_plan, rez_crew, commander_guard) against a hand-built world.
--   2. A smoke run: MECH_BOT's three widgets loaded together against tests/spring_stub.lua
--      and driven through ~20 game-minutes (opening, hand-off, a raid, wounded units,
--      a won game).  The stub builds and moves everything instantly, so this checks
--      that the code RUNS and that each behaviour fires at all -- not that it plays well.
--      That can only be measured in real matches (see CLAUDE.md, ab_test.py).

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.verbose = arg and arg[1] == "-v"

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end

local function fresh(name) return VFS.Include("LuaUI/Widgets/bar_framework/" .. name .. ".lua") end
local function reset()
    W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
    W.frame = 0
    WG = {}
end

-- ── 1. Unit checks ────────────────────────────────────────────────────────────

local UQ = fresh("unit_query")
local function newMM()
    local MM = fresh("map_model")
    MM.Init(0, 0)
    MM.SetHome(W.start[0][1], W.start[0][2])
    return MM
end

do  -- unit_query.is_bomber
    check(UQ.is_bomber(UnitDefNames.corshad.id), "corshad is a bomber")
    check(UQ.is_bomber(UnitDefNames.corhurc.id), "corhurc is a bomber")
    check(not UQ.is_bomber(UnitDefNames.corbw.id), "corbw is not a bomber")
    check(not UQ.is_bomber(UnitDefNames.corgator.id), "ground units are not bombers")
end

do  -- enemy_intel
    reset()
    local MM = newMM()
    local EI = fresh("enemy_intel")
    EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
    local fx, fz = W.start[1][1], W.start[1][2]
    local com  = S.Spawn("corcom", 1, fx, fz, { silent = true })
    local lab  = S.Spawn("coraap", 1, fx + 200, fz, { silent = true })
    local aa   = S.Spawn("corrl", 1, fx - 1500, fz, { silent = true })
    local mex  = S.Spawn("cormex", 1, fx - 300, fz + 100, { silent = true })
    local bomb = S.Spawn("corshad", 1, fx, fz - 3000, { silent = true })
    EI.Scan(100)
    local air = EI.AirValue(100)
    check(math.abs(air - (150 + 4600 / 70)) < 1, "air value counts the bomber at metal + energy/70")
    local labs = EI.Labs()
    check(labs.air == 1 and labs.t2air == 1, "T2 air lab recognised")
    local cx, cz, cf, cuid = EI.Commander()
    check(cuid == com and cx == fx and cf == 100, "commander remembered")
    check(EI.ThreatAt(100, fx - 1500, fz, "air") > 0, "static AA threatens air at its spot")
    check(EI.ThreatAt(100, fx - 1500, fz, "ground") == 0, "pure AA does not threaten ground")
    check(EI.ThreatAt(100, fx + 100, fz, "ground") > 0, "their commander defends its base")
    check(EI.ThreatAt(100, 5000, 5000, "air") == 0, "nothing far away")
    local found = false
    for _, t in ipairs(EI.RaidTargets(100)) do if t.uid == mex then found = true end end
    check(found, "mex is a raid target")
    -- Mobile memory expires, buildings stay.
    W.units[bomb] = nil
    EI.Scan(100 + EI.MOBILE_MEMORY + 30)
    check(EI.AirValue(100 + EI.MOBILE_MEMORY + 30) == 0, "stale bomber forgotten")
    check(EI.Labs().air == 1, "lab still remembered")
    EI.OnDestroyed(com)
    check(EI.Commander() == nil, "dead commander forgotten")
    check(EI.First("t2airlab") == 100, "first T2 air lab frame recorded")
    local sm = EI.Summary(200)
    check(sm.t2AirLabs == 1 and sm.known >= 3, "summary")
end

do  -- endgame.IsWon
    local EG = fresh("endgame")
    local F = EG.WON_MIN_FRAME + 10
    local won = EG.IsWon(F, 20000, 0.6, nil, F - EG.QUIET_FRAMES - 1, 0, 0)
    check(won, "won when quiet, big army, front forward")
    check(not EG.IsWon(F - 100 - EG.WON_MIN_FRAME, 20000, 0.6, nil, -1e9, 0, 0), "not won early")
    check(not EG.IsWon(F, 20000, 0.6, nil, F - 10, 0, 0), "not won: armed enemy just seen")
    check(not EG.IsWon(F, 20000, 0.6, nil, -1e9, 1, 0), "not won: under attack")
    check(not EG.IsWon(F, 2000, 0.6, nil, -1e9, 0, 0), "not won: army too small")
    check(not EG.IsWon(F, 20000, 0.6, nil, -1e9, 0, 9000), "not won: enemy army remembered")
    check(not EG.IsWon(F, 20000, 0.2, nil, -1e9, 0, 0), "not won: never looked")
    check(EG.IsWon(F, 20000, 0.2, F - 100, -1e9, 0, 0), "won: recon saw their base")
end

do  -- raid_group target choice and flank
    reset()
    local MM = newMM()
    local EI = fresh("enemy_intel")
    EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
    local RG = fresh("raid_group")
    RG.Init{ MM = MM, EI = EI, UQ = UQ, ARMY = fresh("army_broker") }
    -- Two mex fields: one under AA, one bare.
    for i = 0, 3 do S.Spawn("cormex", 1, 8000 + i * 60, 6000, { silent = true }) end
    for i = 0, 3 do S.Spawn("cormex", 1, 6000 + i * 60, 9000, { silent = true }) end
    for i = 0, 5 do S.Spawn("corrl", 1, 8000 + i * 40, 6100, { silent = true }) end
    EI.Scan(50)
    local t = RG.PickTarget(50, 2400, 848, 400, "air")
    check(t and math.abs(t.x - 6090) < 200 and math.abs(t.z - 9000) < 200,
          "raid picks the undefended mex field")
    check(RG.IsRaiderDef(UnitDefNames.corbw.id), "Shuriken is a raider")
    check(not RG.IsRaiderDef(UnitDefNames.corape.id), "Wasp is too slow to raid")
    check(not RG.IsRaiderDef(UnitDefNames.corveng.id), "fighters do not raid")
    check(not RG.IsRaiderDef(UnitDefNames.corshad.id), "bombers do not raid")
    -- Enemy army on the +perp side: the waypoint goes to the other side.
    local tx, tz = 7000, 7000
    local px, pz = MM.Perp()
    local wx, wz = RG.FlankPoint(tx, tz, tx + px * 2000, tz + pz * 2000)
    check(((wx - tx) * px + (wz - tz) * pz) < 0, "flank waypoint away from their army")
end

do  -- recon_plan scoring
    reset()
    local MM = newMM()
    local EI = fresh("enemy_intel")
    EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
    local RP = fresh("recon_plan")
    RP.Init{ MM = MM, EI = EI, UQ = UQ, allyID = 0 }
    local scout = S.Spawn("corfink", 0, 6000, 6000, { silent = true })
    RP.Observe(10, {})
    local plan = RP.Plan(4000, { scout }, false)
    local spec = plan[scout]
    check(spec ~= nil, "recon scout gets a target")
    if spec then
        check(not MM.IsOurHalf(spec.x, spec.z), "recon target is on their half")
        local fx, fz = MM.Foe()
        check((spec.x - fx) ^ 2 + (spec.z - fz) ^ 2 <= (RP.ENEMY_BASE_R + 1500) ^ 2,
              "recon prefers the enemy base area")
    end
    -- An AA nest on the enemy base makes it avoided while recently seen.
    local fx, fz = MM.Foe()
    for i = 0, 5 do S.Spawn("corrl", 1, fx + i * 30, fz, { silent = true }) end
    EI.Scan(4000)
    RP.Forget(scout)
    local plan2 = RP.Plan(4000, { scout }, false)
    local s2 = plan2[scout]
    check(s2 and EI.ThreatAt(4000, s2.x, s2.z, "air") <= RP.AA_AVOID,
          "recon avoids a sector covered by known AA")
    check(RP.LastSeenNear(fx, fz, 2500) == nil, "base never seen yet")
    local peek = S.Spawn("corfink", 0, fx, fz, { silent = true })
    RP.Observe(4100, { peek })
    check(RP.LastSeenNear(fx, fz, 2500) == 4100, "base seen by a unit standing in it")
end

do  -- rez_crew heal points
    reset()
    local MM = newMM()
    local ARMY = fresh("army_broker")
    local RC = fresh("rez_crew")
    RC.Init{ MM = MM, UQ = UQ, ARMY = ARMY, teamID = 0, allyID = 0 }
    S.Spawn("cornanotc", 0, 3000, 3000, { silent = true })
    RC.Update(1000, nil, nil)   -- scans nanos
    local x, z, kind = RC.HealPoint(3200, 3200)
    check(kind == "nano" and x == 3000, "heal at the nearest nano when no rez bot")
    local rez = S.Spawn("cornecro", 0, 3500, 3500, { silent = true })
    RC.Add(rez)
    x, z, kind = RC.HealPoint(3200, 3200)
    check(kind == "rez" and x == 3500, "heal at a nearby rez bot first")
    -- A rez bot repairs a damaged friend next to it.
    local hurt = S.Spawn("corgator", 0, 3550, 3500, { silent = true })
    W.units[hurt].hp = 300
    W.orders = {}
    RC.Update(2000, 5000, 5000)
    local repaired = false
    for _, o in ipairs(W.orders) do
        if o.id == rez and o.cmd == 40 and o.params[1] == hurt then repaired = true end
    end
    check(repaired, "rez bot repairs the damaged unit")
    -- Resurrect beats reclaim for an armed wreck.
    W.units[hurt].hp = 1000
    S.AddFeature(3600, 3600, 80, "corraid")
    S.AddFeature(3450, 3450, 500, "")
    W.orders = {}
    RC.Update(2200, 5000, 5000)
    local cmd = nil
    for _, o in ipairs(W.orders) do if o.id == rez then cmd = o.cmd end end
    check(cmd == 125, "rez bot resurrects an armed wreck")
end

do  -- commander_guard safe spot
    reset()
    local CG = fresh("commander_guard")
    CG.Init{ UQ = UQ, teamID = 0, allyID = 0 }
    local hx, hz = 6000, 6000
    local x, z = CG.PickSafeSpot(hx, hz, 10000, 10000)
    check(x < hx and z < hz, "safe spot is behind home, away from the foe")
    -- Evades an armed enemy next to it.
    local com = S.Spawn("corcom", 0, 6000, 6000, { silent = true })
    S.Spawn("corgator", 1, 6300, 6000, { silent = true })
    W.orders = {}
    local st = CG.Update(100, com, { energy = 500, energyStorage = 1000, energyIncome = 50,
                                      energyPull = 0 }, { homeX = hx, homeZ = hz,
                                      foeX = 10000, foeZ = 10000 })
    check(st == "evading", "commander evades a nearby raider")
    local moved = W.orders[1] and W.orders[1].cmd == 10 and W.orders[1].params[1] < 6000
    check(moved, "evasion moves away from the threat")
end

-- ── 2. Smoke run ─────────────────────────────────────────────────────────────

reset()
local widgets = {
    S.LoadWidget("MECH_BOT/macro_controller.lua"),
    S.LoadWidget("MECH_BOT/lab_controller.lua"),
    S.LoadWidget("MECH_BOT/unit_controller.lua"),
}
S.Callin("Initialize")
local myCom = S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])

local fx, fz = W.start[1][1], W.start[1][2]
local enemy = {}
local function enemyAt(name, dx, dz) local id = S.Spawn(name, 1, fx + dx, fz + dz); enemy[#enemy + 1] = id; return id end
local enemyCom = enemyAt("corcom", 0, 0)
enemyAt("corap", 300, 0); enemyAt("coraap", -300, 0); enemyAt("corrl", 0, 400)
for i = 0, 5 do enemyAt("cormex", -600 + i * 60, -600) end
local enemyArmy = {}
for i = 0, 3 do enemyArmy[#enemyArmy + 1] = enemyAt("corshad", 200 * i, 900) end
for i = 0, 3 do enemyArmy[#enemyArmy + 1] = enemyAt("corgator", 200 * i, 1200) end

local raiders = {}
local END = 20 * 60 * 30 + 16 * 60 * 30   -- long enough for the won-state checks
for frame = 0, END, 10 do
    -- Economy: the stocked start, then a running economy that banks metal.
    if frame == 3000 then W.res.metal.income, W.res.metal.cur = 80, 600 end
    if frame == 3000 then W.res.energy.income, W.res.energy.cur, W.res.energy.storage = 2000, 5000, 6000 end
    -- A ground raid lands next to the commander, and hits something.
    if frame == 9000 then
        local cx, _, cz = Spring.GetUnitPosition(myCom)
        if cx then
            for i = 0, 3 do raiders[#raiders + 1] = S.Spawn("corgator", 1, cx + 400 + i * 40, cz) end
            S.Callin("UnitDamaged", myCom, UnitDefNames.corcom.id, 0, 50, false, 1, nil,
                     raiders[1], UnitDefNames.corgator.id)
        end
    end
    if frame == 10500 then for _, id in ipairs(raiders) do S.Kill(id, myCom) end end
    -- Wounded units and a wreck near the army.
    if frame == 14000 then
        local n = 0
        for id, u in pairs(W.units) do
            if u.team == 0 and UnitDefs[u.defID].speed > 0 and UnitDefs[u.defID].weapons[1]
               and id ~= myCom and n < 5 then
                u.hp, n = 200, n + 1
                if n == 1 then S.AddFeature(u.x + 100, u.z, 90, "corgator") end
            end
        end
    end
    -- A T2 air lab of our own (the stub's grids never get as far as building one), so
    -- the radar-plane and T2-fighter paths run.
    if frame == 12000 then S.Spawn("coraap", 0, W.start[0][1] + 600, W.start[0][2] + 600) end
    -- The enemy army is wiped out; their commander and base remain.
    if frame == 16000 then
        for _, id in ipairs(enemyArmy) do S.Kill(id, myCom) end
        -- The instant-build stub fills the unit cap with nano turrets, which would stop
        -- every factory.  Free some room so the hunt has bombers to send.
        local freed = 0
        for _, id in ipairs(Spring.GetTeamUnits(0)) do
            if freed < 400 and UnitDefs[W.units[id].defID].name == "cornanotc" then
                S.Kill(id); freed = freed + 1
            end
        end
    end
    S.Frame(frame)
    if #W.errors > 0 then break end
end

for _, e in ipairs(W.errors) do print("LUA ERROR: " .. e) end
check(#W.errors == 0, "no Lua errors in the smoke run")

local function any(pattern) return #S.Log(pattern) > 0 end
local function countDef(team, name)
    local n = 0
    for _, u in pairs(W.units) do
        if u.team == team and UnitDefs[u.defID].name == name then n = n + 1 end
    end
    return n
end
check(any("HAND%-OFF"), "macro hand-off happened")
check(any("%[CG%].*evading"), "commander evaded the raid")
check(any("%[CG%].*retired"), "commander retired after the opening")
check(any("%[CG%].*builds"), "commander built defences at its safe spot")
check(any("REZ LAB"), "rez lab ordered")
check(countDef(0, "cornecro") > 0, "rez bots built")
check(countDef(0, "corawac") > 0, "radar plane built")
check(any("fighter target"), "reactive fighter target reported")
check(any("%[RAID%].*raiders"), "a raid group launched")
check(any("switching to picket"), "scouting reached picket mode")
check(any("%[UC/intel%]"), "intel summary logged")
check(any("WON%-STATE"), "won state detected")
check(any("hunt%-bomber"), "bombers ordered for the hunt")
check(W.units[enemyCom] == nil, "enemy commander killed by the strike")

if W.verbose then
    for _, l in ipairs(S.Log("%[CG%]")) do print(l) end
    for _, l in ipairs(S.Log("%[RAID%]")) do print(l) end
    for _, l in ipairs(S.Log("%[END%]")) do print(l) end
end
print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
