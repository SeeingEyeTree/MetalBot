-- tests/test_scout_net_bot.lua     python tests/run_lua.py tests/test_scout_net_bot.lua
-- CORE's three widgets with scout_net, against the stub: no Lua errors, FIND hands over to scout_net once the foe is seen,
-- the [SN] row appears, a sacrifice run goes out at an enemy group, scouts end up round the base, WG.ScoutNet is published,
-- click_army-style requests work through the controller, and the labs are told how many scouts / radar units to keep.
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- a T2 ground radar unit the coralab can build (found by radar radius, not name)
local rad = { id = 9000, name = "corvrad_t", humanName = "radar", translatedHumanName = "radar", speed = 60,
              canFly = false, isBuilder = false, isFactory = false, metalCost = 90, energyCost = 1200, buildTime = 1000,
              buildSpeed = 0, buildDistance = 0, xsize = 3, zsize = 3, weapons = {}, buildOptions = {}, customParams = {},
              modCategories = {}, canMove = true, radarRadius = 2200 }
UnitDefs[rad.id], UnitDefNames[rad.name] = rad, rad
local lab = UnitDefNames.coralab
lab.buildOptions[#lab.buildOptions + 1] = rad.id

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 800, 2000, 600, 100
local dir = "candidates/CORE"
S.LoadWidget(dir .. "/macro_controller.lua")
S.LoadWidget(dir .. "/lab_controller.lua")
S.LoadWidget(dir .. "/unit_controller.lua")
S.Callin("Initialize")
local hx, hz = W.start[0][1], W.start[0][2]
local ex, ez = W.start[1][1], W.start[1][2]
S.Spawn("corcom", 0, hx, hz)
S.Spawn("corcom", 1, ex, ez)
S.Spawn("cormex", 1, ex - 150, ez, { silent = true })
S.Spawn("coralab", 0, hx + 200, hz + 100, { silent = true })
for i = 0, 60 do
    local a = i / 61 * 2 * math.pi
    S.Spawn(i % 2 == 0 and "cormex" or "corwin", 0, hx + math.cos(a) * (500 + (i % 5) * 120),
            hz + math.sin(a) * (500 + (i % 5) * 120), { silent = true })
end
-- an enemy group in the middle of the map, in sight of the stub's omniscient intel
for i = 1, 6 do S.Spawn("corgator", 1, 6000 + i * 30, 6000, { silent = true }) end
local scouts = {}
for i = 1, 8 do scouts[#scouts + 1] = S.Spawn("corfav", 0, hx + i * 10, hz + 50) end
local hawk = S.Spawn("corawac", 0, hx, hz + 200)

for f = 0, 12 * 1800, 10 do
    W.res.metal.cur = 800
    S.Frame(f)
    if #W.errors > 0 then break end
    if f == 9 * 1800 then
        for id, u in pairs(W.units) do
            if UnitDefs[u.defID].name == "coralab" and u.team == 0 then S.Callin("UnitFinished", id, u.defID, 0) end
        end
    end
end
check(#W.errors == 0, "no Lua errors: " .. tostring(W.errors[1]))
local snLog = S.Log("%[SN%]")
check(#snLog > 0, "the [SN] row appears (FIND handed over to scout_net)")
if #snLog > 0 then print(snLog[#snLog]) end
check(WG.ScoutNet ~= nil and WG.ScoutNet.RequestScout ~= nil, "WG.ScoutNet is published")
if WG.ScoutNet then
    local st = WG.ScoutNet.Stats()
    check(st.groups >= 1, "the enemy group is tracked")
    local pic = WG.ScoutNet.Picture(12 * 1800)
    check(pic.totalValue > 0, "the picture has a total enemy value")
end
local mb = WG.MetalBot or {}
check((mb.scoutWant or 0) >= 2, "the labs are told to keep scouts: " .. tostring(mb.scoutWant))

-- scouts are not all on one spot
local far, n = 0, 0
for id, u in pairs(W.units) do
    local d = UnitDefs[u.defID]
    if u.team == 0 and d.modCategories and d.modCategories.scout then
        n = n + 1
        far = math.max(far, math.sqrt((u.x - hx) ^ 2 + (u.z - hz) ^ 2))
    end
end
check(n >= 4, "scouts alive: " .. n)
check(far > 800, "scouts went out past the base: " .. math.floor(far))

-- (the stub's intel sees the enemy group all the time, so the scheduler never finds it stale: no run on its own)
-- a run and a request through the API reach the units as orders
local f0 = 12 * 1800
local seenOrders = {}
local giveOrder = Spring.GiveOrderToUnit
Spring.GiveOrderToUnit = function(id, cmd, params, opts)       -- the stub clears W.orders every step: keep our own copy
    seenOrders[#seenOrders + 1] = { cmd = cmd, params = params }
    return giveOrder(id, cmd, params, opts)
end
local function OrderedTo(x, z)
    for _, o in ipairs(seenOrders) do
        local p = o.params
        if o.cmd == 10 and p and p[1] and math.abs(p[1] - x) < 10 and math.abs(p[3] - z) < 10 then return true end
    end
    return false
end
local id = WG.ScoutNet.RequestScout(3000, 9000, { ttl = 600, by = "test" })
check(id ~= nil, "RequestScout returns an id")
WG.ScoutNet.SacrificeScout(7000, 3000, { by = "test" })
for f = f0 + 10, f0 + 400, 10 do W.res.metal.cur = 800; S.Frame(f) end
check(OrderedTo(3000, 9000), "a scout was ordered to the requested spot")
check(OrderedTo(7000, 3000), "a scout was sent on the sacrifice run")
check(#W.errors == 0, "no Lua errors after the API calls: " .. tostring(W.errors[1]))

print(string.format("scout_net_bot: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
