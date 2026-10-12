-- tests/test_line_bomb.lua
-- Run from the repo root through lupa's Lua 5.1 (tests/LUA_TESTING.md):
--   python -c "import lupa.lua51 as L; L.LuaRuntime().execute(open('tests/test_line_bomb.lua',encoding='utf-8').read())"
--
--   1. bar_framework/stance_loader.lua: the real stances/*.lua load, shares sum to 1, the value-deficit pick converges on
--      the shares, restricted to what a lab can build, positiveOnly stops at the share.
--   2. bar_framework/phase_plan.lua: DEF1 -> BOMB -> DEF2 -> LATE and the dropped-raid path.
--   3. bar_framework/bomb_run.lua against tests/spring_stub.lua: waits for the wave, launches with enough bombers and a
--      target, spreads ~PER_TARGET bombers on each bombing point, fighters fight ahead, a spent wave returns.
--   4. bar_framework/lab_recycler.lua with a fake spine: clear -> reclaim -> place the swap -> done.
--   5. A smoke run of candidates/LINE_BOMB's three widgets (no Lua errors; the plan runs; the air cell opens; bombers are
--      ordered from the stance).
-- The stub builds instantly and teleports units: this checks the logic, not how it plays.

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
local function Any(log, p) for _, l in ipairs(log) do if l:find(p) then return true end end return false end

-- ── 1. stance_loader ──────────────────────────────────────────────────────────

Reset()
local SL = VFS.Include("LuaUI/Widgets/bar_framework/stance_loader.lua")
local names = { "T1_defense", "T1_bombing_run", "T2_defense", "Late_game", "T1_raid" }
for _, n in ipairs(names) do
    local st = SL.Load(n)
    check(st ~= nil, "stance " .. n .. " loads")
    if st then
        local sum = 0
        for _, u in ipairs(st.units) do sum = sum + u.share end
        check(math.abs(sum - 1) < 1e-6, "stance " .. n .. " shares sum to 1")
    end
end
check(SL.Load("no_such_stance") == nil, "a missing stance is nil, not an error")

local bomb = SL.Load("T1_bombing_run")
check(bomb.suggestedShare == 80, "suggestedShare parsed from the notes (last number: " .. tostring(bomb.suggestedShare) .. ")")
local ledger = SL.NewLedger()
local can = function(defID) return true end
local counts = {}
local first
for i = 1, 60 do
    local d = SL.Pick(bomb, ledger, can)
    if i == 1 then first = d end
    SL.Note(ledger, d)
    counts[d] = (counts[d] or 0) + 1
end
check(first == UnitDefNames.corshad.id, "first pick is the biggest share (bombers)")
local bv = (counts[UnitDefNames.corshad.id] or 0) * (150 + 4600 / 70)
local fv = (counts[UnitDefNames.corveng.id] or 0) * (73 + 2800 / 70)
local share = bv / (bv + fv)
check(math.abs(share - 0.775) < 0.05, string.format("value share of bombers converges on 77.5%% (%.3f)", share))

local only = SL.Pick(bomb, SL.NewLedger(), function(d) return d == UnitDefNames.corveng.id end)
check(only == UnitDefNames.corveng.id, "restricted to what the lab can build")
check(SL.Pick(bomb, SL.NewLedger(), function() return false end) == nil, "a lab that builds none of it gets nil")
local led2 = SL.NewLedger()
SL.Note(led2, UnitDefNames.corshad.id, 10)              -- bombers far over their share, fighters at zero
check(SL.Pick(bomb, led2, can, { [UnitDefNames.corveng.id] = true }, true) == nil,
      "positiveOnly: nothing when the only candidate is over its share")
check(SL.Pick(bomb, led2, can, nil, true) == UnitDefNames.corveng.id, "positiveOnly: the unit below its share")

-- ── 2. phase_plan ────────────────────────────────────────────────────────────

local PPM = VFS.Include("LuaUI/Widgets/bar_framework/phase_plan.lua")
local P = PPM.New()
local K = P.cfg
local changes = {}
PPM.OnChange = function(_, f, ph) changes[#changes + 1] = ph end
check(PPM.Update(P, 100, {}) == "DEF1", "starts in DEF1")
local v = PPM.View(P, 100)
check(not v.prep and v.stance == "T1_defense" and v.groundStance == "T1_defense", "DEF1: defence stance, no air cell yet")
v = PPM.View(P, K.PREP_FROM)
check(v.prep, "the bomber labs are wanted from PREP_FROM")
check(PPM.Update(P, K.BOMB_FROM + 1, { airLabs = 1 }) == "DEF1", "1 lab is not enough for BOMB")
check(PPM.Update(P, K.BOMB_FROM + 2, { airLabs = 3 }) == "BOMB", "labs at BOMB_FROM start the bombing run")
v = PPM.View(P, K.BOMB_FROM + 2)
check(v.bomb and v.stance == "T1_bombing_run" and v.groundStance == "T1_defense", "BOMB: bombers on the air labs, defence on the rest")
check(v.groundShare == K.GROUND_SHARE.BOMB, "BOMB leaves the ground share alone")
check(PPM.Update(P, K.BOMB_FROM + 900, { airLabs = 3, bombersBuilt = 30, bombersAlive = 25, launched = 1 }) == "BOMB", "a live wave keeps BOMB on")
check(PPM.Update(P, K.BOMB_FROM + 1800, { airLabs = 3, bombersBuilt = 34, bombersAlive = 3, launched = 1 }) == "DEF2", "a spent raid ends BOMB")
v = PPM.View(P, K.BOMB_FROM + 1800)
check(v.recycle and v.stance == "T2_defense", "DEF2: recycle the bomber labs, T2 defense")
check(PPM.Update(P, K.LATE_FROM, { income = 100 }) == "LATE", "LATE from LATE_FROM")
check(PPM.View(P, K.LATE_FROM).stance == "Late_game" and PPM.View(P, K.LATE_FROM).groundShare == 1.0, "LATE: late stance, full share")
local P2 = PPM.New()
check(PPM.Update(P2, P2.cfg.BOMB_LATEST, { airLabs = 0 }) == "DEF2" and P2.skipped, "no labs by BOMB_LATEST drops the raid")
check(not PPM.View(P2, P2.cfg.BOMB_LATEST).prep, "a dropped raid does not ask for the air cell")
local P3 = PPM.New()
PPM.Update(P3, P3.cfg.BOMB_FROM, { airLabs = 4 })
check(PPM.Update(P3, P3.cfg.BOMB_END, { airLabs = 4, bombersAlive = 20, launched = 1 }) == "DEF2", "BOMB_END ends the bombing stance")
local P4 = PPM.New()
PPM.Update(P4, P4.cfg.BOMB_FROM, { airLabs = 4 }); PPM.Update(P4, P4.cfg.BOMB_FROM + 10, {})
check(PPM.Update(P4, P4.cfg.BOMB_FROM + 20, { income = 900 }) ~= "LATE", "income does not skip DEF2 straight from BOMB")
PPM.OnChange = nil

-- ── 3. bomb_run ──────────────────────────────────────────────────────────────

Reset()
local MM   = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ   = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI   = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
local ARMY = VFS.Include("LuaUI/Widgets/bar_framework/army_broker.lua")
local BR   = VFS.Include("LuaUI/Widgets/bar_framework/bomb_run.lua")
MM.Init(0, 0)
MM.SetHome(W.start[0][1], W.start[0][2])
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }
local combat, guards, bombers = {}, {}, {}
BR.Init{ MM = MM, UQ = UQ, EI = EI, ARMY = ARMY, bombers = bombers, combat = combat, guards = guards }

local ex, ez = W.start[1][1], W.start[1][2]
-- three mex/wind fields, each a few buildings, well apart
local fields = { { ex - 300, ez - 200 }, { ex + 300, ez - 600 }, { ex - 900, ez + 100 } }
for _, f in ipairs(fields) do
    for i = 1, 4 do
        S.Spawn("cormex", 1, f[1] + i * 40, f[2], { silent = true })
        S.Spawn("corwin", 1, f[1] + i * 40, f[2] + 50, { silent = true })
    end
end
local hx, hz = W.start[0][1], W.start[0][2]
local function Planes(n, def, set)
    local ids = {}
    for i = 1, n do
        local id = S.Spawn(def, 0, hx + i * 10, hz + 200, { silent = true })
        set[id] = UnitDefNames[def].id
        ids[#ids + 1] = id
    end
    return ids
end
local attackOrders = {}
local giveOrder = Spring.GiveOrderToUnit
Spring.GiveOrderToUnit = function(id, cmd, params, opts)
    if cmd == 20 and params and params[1] and params[3] then attackOrders[id] = { params[1], params[3] } end
    return giveOrder(id, cmd, params, opts)
end
local function BRTick(frame, plan)
    EI.Scan(frame); ARMY.Sweep(frame)
    BR.Update(frame, plan)
    S.Frame(frame)
end
local planOn = { bomb = true, phase = "BOMB" }

-- (bombers are tracked by the unit controller in `bombers`; fighters in `combat`)
local bomberIds = Planes(8, "corshad", bombers)
local fighterIds = Planes(4, "corveng", combat)
local f = 9000
for _ = 1, 4 do f = f + 30; BRTick(f, planOn) end
check(BR.Waves() == 0 and BR.Mode() == "rally", "8 bombers is not a wave (LAUNCH_MIN)")
local more = Planes(14, "corshad", bombers)
for _, id in ipairs(more) do bomberIds[#bomberIds + 1] = id end
for _ = 1, 3 do f = f + 30; BRTick(f, planOn) end
check(BR.Waves() == 1 and BR.Mode() == "strike", "22 bombers and known targets launch wave 1")
check(Any(W.log, "%[BR%] .*LAUNCH wave 1"), "the launch is logged")
local perPoint, points = {}, 0
for _, id in ipairs(bomberIds) do
    local a = attackOrders[id]
    check(a ~= nil, "bomber " .. id .. " has an ATTACK order")
    if a then
        local k = math.floor(a[1] / 50) .. "," .. math.floor(a[2] / 50)
        if not perPoint[k] then perPoint[k] = 0; points = points + 1 end
        perPoint[k] = perPoint[k] + 1
    end
end
check(points >= 3, "bombers are spread over several bombing points (" .. points .. ")")
local minC, maxC = 1e9, 0
for _, c in pairs(perPoint) do minC = math.min(minC, c); maxC = math.max(maxC, c) end
check(minC >= 3, "every point has at least 3 bombers (min " .. minC .. ")")
check(maxC <= 8, "no point is overloaded (max " .. maxC .. ")")
check(ARMY.RoleOf(fighterIds[1]) == "BOMBRUN", "fighters are claimed as part of the wave")
check(W.errors[1] == nil, "no Lua errors in bomb_run" .. tostring(W.errors[1]))

-- the wave is spent: bombers die
for i = 1, 20 do S.Kill(bomberIds[i]); bombers[bomberIds[i]] = nil end
for _ = 1, 3 do f = f + 30; BRTick(f, planOn) end
check(BR.Mode() == "return", "a spent wave returns")
for _ = 1, 20 do f = f + 30; BRTick(f, planOn) end
check(BR.Mode() == "rally", "...and rallies again")
Spring.GiveOrderToUnit = giveOrder
check(#W.errors == 0, "no Lua errors across the bomb_run checks")

-- ── 4. lab_recycler ──────────────────────────────────────────────────────────

Reset()
local LR = VFS.Include("LuaUI/Widgets/bar_framework/lab_recycler.lua")
local labs, nanos, reclaimed, swaps = {}, {}, {}, 0
local fakeCell = { ax = 100, az = 200, done = false }
local SP = {
    AirCell = function() return fakeCell end,
    AirUnits = function()
        local l, n = {}, {}
        for _, x in ipairs(labs) do l[#l + 1] = x end
        for _, x in ipairs(nanos) do n[#n + 1] = x end
        return l, n
    end,
    OpenSwapCell = function(layout, ax, az) swaps = swaps + 1; return fakeCell end,
}
local NANO = { PRIO = { CLEAR = 3 }, Reclaim = function(prio, n, target) reclaimed[#reclaimed + 1] = { n, target }; return true end }
for i = 1, 3 do
    local id = S.Spawn("corap", 0, 1000, 1000 + i * 150, { silent = true })
    labs[#labs + 1] = { uid = id, defID = UnitDefNames.corap.id, x = 1000, z = 1000 + i * 150, name = "corap" }
end
for i = 1, 6 do
    local id = S.Spawn("cornanotc", 0, 940, 1000 + i * 70, { silent = true })
    nanos[#nanos + 1] = { uid = id, defID = UnitDefNames.cornanotc.id, x = 940, z = 1000 + i * 70 }
end
LR.Init{ SP = SP, NANO = NANO, swap = { { n = "coraap", x = 16, z = -96, f = 1 } } }
local plan = { recycle = false }
local t = 3000
for _ = 1, 5 do t = t + 30; LR.Update(t, plan, 500) end
check(LR.State() == "idle", "the recycler waits for the plan")
plan.recycle = true
for _ = 1, 4 do t = t + 30; LR.Update(t, plan, 500) end
check(LR.State() == "reclaiming", "recycle: queues cleared, reclaim started (" .. LR.State() .. ")")
t = t + 30; LR.Update(t, plan, 500)
check(#reclaimed >= 3, "nanos are put on the labs (" .. #reclaimed .. " reclaim orders)")
labs = {}      -- the labs are gone
t = t + 30; LR.Update(t, plan, 50)
check(LR.State() == "placing", "labs gone -> placing")
t = t + 30; LR.Update(t, plan, 50)
check(swaps == 0, "no T2 labs while the income is short")
t = t + 30; LR.Update(t, plan, 400)
check(swaps == 1, "the swap cell opens once the income is there")
fakeCell.done = true
t = t + 30; LR.Update(t, plan, 400)
check(LR.State() == "done", "swap cell built -> done")

-- ── 5. LINE_BOMB smoke run ───────────────────────────────────────────────────

local function Smoke(dir, minutes)
    Reset()
    W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 400, 1000, 40, 5
    S.LoadWidget(dir .. "/macro_controller.lua")
    S.LoadWidget(dir .. "/lab_controller.lua")
    S.LoadWidget(dir .. "/unit_controller.lua")
    S.Callin("Initialize")
    S.Spawn("corcom", 0, W.start[0][1], W.start[0][2])
    S.Spawn("corcom", 1, W.start[1][1], W.start[1][2])
    for i = 1, 4 do
        S.Spawn("cormex", 1, W.start[1][1] - 400 + i * 40, W.start[1][2] - 300, { silent = true })
        S.Spawn("corwin", 1, W.start[1][1] - 400 + i * 40, W.start[1][2] - 250, { silent = true })
    end
    -- The stub's cons never build the spine's cells (LINE_CLICK_v16 has 0 labs in cell 1 here too), so the test builds the
    -- air cell and the swap cell itself the moment they open, and lets the nanos' RECLAIM order remove a T1 air lab.
    local giveOrder = Spring.GiveOrderToUnit
    Spring.GiveOrderToUnit = function(id, cmd, params, opts)
        if cmd == 90 and params and params[1] then
            local u = W.units[params[1]]
            if u and UnitDefs[u.defID].name == "corap" then S.Kill(params[1]) end
        end
        return giveOrder(id, cmd, params, opts)
    end
    local populated = {}
    local labsSeen = { corap = 0, coraap = 0 }
    for f = 0, minutes * 1800, 10 do
        -- income grows through the game so the later phases are reached
        local m = f / 1800
        W.res.metal.income = 40 + 40 * m
        W.res.metal.cur = (f % 3000 < 300) and 600 or 300
        S.Frame(f)
        local sp = WG.Spine
        local st = sp and sp.State and sp.State()
        for _, cell in ipairs(st and st.cells or {}) do
            if cell.air and not populated[cell] then
                populated[cell] = true
                for _, it in ipairs(cell.state.queue) do
                    if it.act ~= "reclaim" then
                        S.Spawn(it.n, 0, it.wx, it.wz)
                        if labsSeen[it.n] then labsSeen[it.n] = labsSeen[it.n] + 1 end
                        it.status = "built"
                    end
                end
                cell.done = true
            end
        end
        if #W.errors > 0 then break end
    end
    Spring.GiveOrderToUnit = giveOrder
    return W.log, W.errors, labsSeen
end

local log, errs, labsSeen = Smoke("candidates/LINE_BOMB", 17)
for _, e in ipairs(errs) do print("LUA ERROR (LINE_BOMB): " .. e) end
check(#errs == 0, "LINE_BOMB widgets run 17 minutes without Lua errors")
check(Any(log, "%[PLAN%] game plan on"), "the game plan is on")
check(not Any(log, "ERROR loading"), "every module loaded")
check(Any(log, "%[PLAN%] .* %-> BOMB") or Any(log, "%[PLAN%] .* %-> DEF2"), "the plan leaves DEF1")
check(Any(log, "%[SPINE%] AIR cell"), "the spine opens the bomber lab cell")
check(Any(log, "%[LabCtrl%] stance T1_defense"), "the defence stance is loaded by the lab controller")
local bombOrders = 0
for _, l in ipairs(log) do if l:find("%[LabCtrl%] .* stance%s+corshad") then bombOrders = bombOrders + 1 end end
print(string.format("LINE_BOMB smoke: %d bomber orders; plan: %s", bombOrders, table.concat(S.Log("%[PLAN%]"), " | ")))
check(bombOrders > 0, "the bomber labs order bombers from the stance")
check(Any(log, "%[BR%] .*LAUNCH wave"), "a wave launches once enough bombers stand")
check(Any(log, "%[PLAN%] .* %-> BOMB"), "the plan reaches the bombing run")
check(Any(log, "%[PLAN%] .* %-> DEF2"), "...and moves on to T2 defense")
check(Any(log, "%[LR%] .*reclaiming"), "the recycler reclaims the bomber labs")
check(Any(log, "%[SPINE%] SWAP cell"), "...and opens the swap cell for the T2 air labs")
check(labsSeen.corap == 3, "the air cell holds three T1 air labs (" .. tostring(labsSeen.corap) .. ")")
check(labsSeen.coraap == 2, "the swap cell holds two T2 air labs (" .. tostring(labsSeen.coraap) .. ")")
check(Any(log, "%[LabCtrl%] stance T2_defense") and Any(log, "%[LabCtrl%] stance Late_game"), "later stances are loaded")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then error("tests failed") end
