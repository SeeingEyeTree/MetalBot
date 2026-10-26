-- tests/test_home_defence.lua     python tests/run_lua.py tests/test_home_defence.lua
-- bar_framework/home_defence.lua with the real nano_broker: nanos / cons reclaim enemy units in reach (highest priority, no flip-flop at
-- the range edge), drop the order when the enemy leaves reach, cons keep their queue (INSERT / REMOVE), nanos repair a con that was hit.

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

CMD = { STOP = 0, INSERT = 1, REMOVE = 2, RECLAIM = 90, REPAIR = 40, GUARD = 25, ONOFF = 85 }
UnitDefs = {
    [1] = { name = "nano", isBuilder = true, buildSpeed = 200, buildDistance = 400, speed = 0, customParams = {} },
    [2] = { name = "con",  isBuilder = true, buildSpeed = 100, buildDistance = 300, speed = 50, customParams = {} },
    [3] = { name = "scout", metalCost = 30, speed = 100, customParams = {} },
    [4] = { name = "tank", metalCost = 900, speed = 40, customParams = {} },
}
local units, orders, frame = {}, {}, 0
Spring = {
    Echo = function() end,
    GetGameFrame = function() return frame end,
    GetUnitDefID = function(id) return units[id] and units[id].def or nil end,
    GetUnitPosition = function(id) local u = units[id]; if u then return u.x, 0, u.z end end,
    GetUnitAllyTeam = function(id) return units[id] and units[id].ally end,
    GetUnitHealth = function(id) local u = units[id]; if u then return u.hp, u.maxhp end end,
    GetUnitIsBeingBuilt = function(id) return units[id] and units[id].built or false end,
    GetTeamUnits = function(team) local t = {}; for id, u in pairs(units) do if u.team == team then t[#t + 1] = id end end; table.sort(t); return t end,
    GetTeamUnitCount = function(team) local n = 0; for _, u in pairs(units) do if u.team == team then n = n + 1 end end; return n end,
    GetUnitsInCylinder = function(x, z, r)
        local t = {}
        for id, u in pairs(units) do if (u.x - x) ^ 2 + (u.z - z) ^ 2 <= r * r then t[#t + 1] = id end end
        table.sort(t); return t
    end,
    GetUnitCommands = function(id, n) return units[id] and units[id].queue or nil end,
    GiveOrderToUnit = function(id, cmd, params, opts)
        orders[#orders + 1] = { id = id, cmd = cmd, params = params }
        local u = units[id]
        if u and cmd == CMD.INSERT then table.insert(u.queue, 1, { id = params[2], params = { params[4] }, tag = 100 + #orders }) end
        return true
    end,
}
local NANO = dofile("bar_framework/nano_broker.lua")
local UQ = dofile("bar_framework/unit_query.lua")
local HD = dofile("bar_framework/home_defence.lua")
HD.Init{ teamID = 0, allyID = 0, NANO = NANO, UQ = UQ }

local function add(id, def, team, x, z) units[id] = { def = def, team = team, ally = team, x = x, z = z, hp = 100, maxhp = 100, queue = {} } end
local function lastOrder(id) for i = #orders, 1, -1 do if orders[i].id == id then return orders[i] end end end
local function tick(n) for _ = 1, n or 1 do frame = frame + 10; NANO.Sweep(); HD.Update(frame) end end

add(1, 1, 0, 0, 0)          -- nano, range 400
add(2, 2, 0, 1000, 0)       -- con, range 300
add(10, 3, 1, 380, 0)       -- enemy scout at 380 (inside 0.95 x 400 = 380: edge)
tick(3)
local o = lastOrder(1)
check(o and o.cmd == CMD.RECLAIM and o.params[1] == 10, "nano reclaims the scout in reach")
check(NANO.Assignment(1) and NANO.Assignment(1).prio == NANO.PRIO.DEFEND, "at DEFEND priority")
check(not NANO.Guard(NANO.PRIO.SPINE, 1, 2), "a spine / balance order cannot displace it")

-- edge: drifts to 1.05 x range: still held (hysteresis); beyond 1.1 x: dropped with a STOP
units[10].x = 420; tick(3)
check(NANO.Assignment(1) ~= nil, "kept at 1.05 x range")
local n0 = #orders; tick(3)
check(#orders == n0, "no re-issued orders while the job holds")
units[10].x = 445; tick(2)
check(NANO.Assignment(1) == nil, "dropped once the enemy is past 1.1 x range")
check(lastOrder(1).cmd == CMD.STOP, "the nano is stopped, not left on the order")
tick(3)
check(NANO.Assignment(1) == nil, "not re-taken while the enemy is out of reach (needs 0.95 x range)")
units[10].x = 300; tick(3)
check(NANO.Assignment(1) ~= nil, "taken again when it comes back in")
units[10] = nil; tick(2)
check(NANO.Assignment(1) == nil, "freed when the enemy dies")

-- expensive units are left alone
add(11, 4, 1, 100, 0); tick(3)
check(NANO.Assignment(1) == nil, "a 900-metal tank is not reclaimed")
units[11] = nil

-- cons: the reclaim is inserted at the front, then removed
units[2].queue = { { id = -5, params = {}, tag = 7 } }
add(12, 3, 1, 1100, 0); tick(3)
local ins; for _, od in ipairs(orders) do if od.id == 2 and od.cmd == CMD.INSERT then ins = od end end
check(ins and ins.params[1] == 0 and ins.params[2] == CMD.RECLAIM and ins.params[4] == 12, "the con gets an INSERTed reclaim at the front")
local nIns = 0; for _, od in ipairs(orders) do if od.id == 2 and od.cmd == CMD.INSERT then nIns = nIns + 1 end end
tick(4)
local nIns2 = 0; for _, od in ipairs(orders) do if od.id == 2 and od.cmd == CMD.INSERT then nIns2 = nIns2 + 1 end end
check(nIns2 == nIns, "not inserted again every tick")
units[12].x = 1400; tick(2)
local rem; for _, od in ipairs(orders) do if od.id == 2 and od.cmd == CMD.REMOVE then rem = od end end
check(rem and rem.params[1] > 100, "the reclaim is removed when the enemy leaves reach")
units[12] = nil

-- repair: the con is hit, a nano in reach repairs it, then stops when healed
units[2].x, units[2].z = 100, 0; units[2].queue = {}
tick(2)
units[2].hp = 70; tick(2)
local a = NANO.Assignment(1)
check(a and a.cmd == CMD.REPAIR and a.target == 2, "a nano repairs the con that was hit")
units[2].hp = 100; tick(2)
check(NANO.Assignment(1) == nil and lastOrder(1).cmd == CMD.STOP, "repair ends once the con is healed")

-- a hit con with no further damage: repair lapses after REPAIR_S
units[2].hp = 60; tick(2); check(NANO.Assignment(1) ~= nil, "repair again")
tick(40)
check(NANO.Assignment(1) == nil, "repair lapses once the con has not been hit for REPAIR_S seconds")

print(string.format("test_home_defence: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
