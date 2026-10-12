-- tests/test_behavior_host.lua
-- bar_framework/behavior_host.lua + behaviors/kite.lua against tests/spring_stub.lua.  Run from the repo root through
-- lupa's Lua 5.1 (tests/LUA_TESTING.md).  The enemy list is a fake ctx.EnemiesNear, so no enemy units are spawned.
--   * host: assign / remove, cohorts by identical overrides, stack fall-through, one owner per tick, de-duplicated
--     orders, a behaviour that errors is contained;
--   * kite: ANY approaching enemy (slow tank, fast raider, group) makes the Lashers MOVE away; a lone scout, a
--     stationary or retreating enemy does not; the step grows with the threat; the hold ends and hands units on.

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

local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")

local given = {}
local function NewHost()
    given = {}
    return BH.New{ give = function(uid, cmd, p) given[#given + 1] = { uid = uid, cmd = cmd, p = p } end }
end
local function Cmds(cmd)
    local n = 0
    for _, g in ipairs(given) do if cmd == nil or g.cmd == cmd then n = n + 1 end end
    return n
end

-- ── host ──────────────────────────────────────────────────────────────────────
local a = S.Spawn("cormist", 0, 1000, 1000, { silent = true })
local b = S.Spawn("cormist", 0, 1050, 1000, { silent = true })
local c = S.Spawn("corlevlr", 0, 1100, 1000, { silent = true })

local h = NewHost()
local calls = {}
h:Register{ name = "probe", cfg = { k = 1 }, Update = function(st, group, ctx, frame)
    calls[#calls + 1] = { n = #group.list, k = group.cfg.k }
end }
h:Register{ name = "grab", cfg = {}, Update = function(st, group) return true end }
h:Register{ name = "boom", cfg = {}, Update = function() error("boom") end }

h:Assign(a, "probe"); h:Assign(b, "probe"); h:Assign(c, "probe", { k = 9 })
h:Update(30, {})
table.sort(calls, function(p, q) return p.k < q.k end)
check(#calls == 2 and calls[1].n == 2 and calls[1].k == 1 and calls[2].n == 1 and calls[2].k == 9,
      "same overrides share a cohort, different overrides are separate")

calls = {}
h:Assign(a, { "grab", "probe" })
h:Update(60, {})
local probed = 0
for _, cl in ipairs(calls) do probed = probed + cl.n end
check(probed == 2, "a unit claimed by 'grab' is skipped by the next behaviour in its stack (" .. probed .. " probed)")
local acted = h:Update(90, {})
check(acted[a] == "grab" and acted[b] == nil, "Update reports who acted")

h:Assign(b, { "boom", "probe" })
calls = {}
h:Update(120, {})
check((h.stats.errors or 0) >= 1, "a failing behaviour is contained and counted")
check(#calls >= 1, "units of a failing behaviour fall through to the next one")

h:Remove(a)
check(not h:Has(a), "Remove drops the unit")
W.units[b] = nil
h:Update(150, {})
check(not h:Has(b), "a dead unit is dropped on the next Update")
check(not h:Assign(c, "no_such_behaviour_xyz"), "an unknown behaviour is refused")

h = NewHost()
check(h:Order(0, 5, 10, 100, 100) and not h:Order(10, 5, 10, 110, 100), "a repeat order to the same spot is dropped")
check(h:Order(60, 5, 10, 500, 100), "a new target goes out")
check(h:Order(1000, 5, 10, 500, 100), "the heartbeat repeats an order")
check(Cmds(10) == 3, "three orders were given")

-- ── kite ──────────────────────────────────────────────────────────────────────
local lashers = {}
for i = 1, 8 do lashers[i] = S.Spawn("cormist", 0, 2000, 2000 + (i - 4.5) * 60, { silent = true }) end
local pounder = S.Spawn("corlevlr", 0, 2100, 2000, { silent = true })

-- an enemy `dist` elmos east of the line, walking west at `speed`
local enemies = {}
local function Foe(dist, speed, val, range, mobile)
    return { uid = 900 + #enemies, x = 2000 + dist, z = 2000, vx = -speed, vz = 0, value = val or 200,
             range = range or 300, mobile = mobile ~= false }
end
local ctx = { EnemiesNear = function() return enemies end, Axis = function() return 1, 0 end }

local function KiteHost(over)
    local k = NewHost()
    for _, id in ipairs(lashers) do k:Assign(id, "kite", over) end
    return k
end
local function Run(k, f) given = {}; k:Update(f, ctx) end
local function MeanX(cmd)
    local s, n = 0, 0
    for _, g in ipairs(given) do if g.cmd == cmd then s, n = s + g.p[1], n + 1 end end
    return n > 0 and s / n or nil
end

local lv = 155 + 2400 / 70                      -- one Lasher's value; the group is ~8x
local kite = KiteHost()

enemies = { Foe(700, 40, 5 * lv) }              -- 400 from its range at 40/s: 10 s -> no
Run(kite, 30)
check(Cmds(10) == 0, "an enemy that is still 10 s from range is ignored")

enemies = { Foe(450, 40, 5 * lv) }              -- 150 from its range at 40/s: 3.75 s -> yes
Run(kite, 60)
check(Cmds(10) == 8, "a SLOW approaching tank makes every Lasher MOVE away (" .. Cmds(10) .. ")")
check(Cmds(16) == 0, "the back-off is MOVE only, no FIGHT")
check(MeanX(10) and MeanX(10) < 2000, "they move away from the enemy (target x " .. tostring(MeanX(10)) .. ")")

enemies = { Foe(450, 200, 5 * lv) }
local kf = KiteHost()
Run(kf, 30)
check(Cmds(10) == 8, "a fast raider also triggers it")

enemies = { Foe(450, 40, 0.3 * lv) }            -- a lone scout-sized unit
local ks = KiteHost()
Run(ks, 30)
check(Cmds(10) == 0, "a lone cheap unit is not worth backing off from")

enemies = { Foe(450, 0, 5 * lv) }               -- standing still
local k0 = KiteHost()
Run(k0, 30)
check(Cmds(10) == 0, "a stationary enemy does not trigger it")

enemies = { Foe(450, -40, 5 * lv) }             -- walking away
local kr = KiteHost()
Run(kr, 30)
check(Cmds(10) == 0, "a retreating enemy does not trigger it")

enemies = { Foe(450, 40, 5 * lv, 300, false) }  -- a static defence
local kd = KiteHost()
Run(kd, 30)
check(Cmds(10) == 0, "static defences are ignored")

enemies = {}
for i = 1, 8 do enemies[i] = Foe(420 + i * 3, 40, 0.6 * lv) end
local kg = KiteHost()
Run(kg, 30)
check(Cmds(10) == 8, "a group of cheap units that add up to a real threat triggers it")

-- the step grows with the threat ratio
local function StepFor(val)
    enemies = { Foe(450, 40, val) }
    local kk = KiteHost()
    local x0 = {}
    for _, id in ipairs(lashers) do x0[id] = W.units[id].x end
    Run(kk, 30)
    local s, n = 0, 0
    for _, g in ipairs(given) do s, n = s + (x0[g.uid] - g.p[1]), n + 1 end
    return n > 0 and s / n or 0
end
local sSmall, sBig = StepFor(1.2 * lv), StepFor(20 * lv)
check(sBig > sSmall + 100, string.format("a bigger threat backs off further (%d vs %d)", sSmall, sBig))
check(sBig > 350 and sBig < 450, "the full step is used at a large ratio (" .. math.floor(sBig) .. ")")

-- hold, then hand over to the next behaviour
enemies = { Foe(450, 40, 5 * lv) }
local stack = NewHost()
stack:Register{ name = "advance", cfg = {}, Update = function(st, group, _, frame)
    for _, u in ipairs(group.list) do stack:Order(frame, u.uid, 16, u.x + 100, u.z) end
    return true
end }
for _, id in ipairs(lashers) do stack:Assign(id, { "kite", "advance" }) end
given = {}; stack:Update(30, ctx)
check(Cmds(10) == 8 and Cmds(16) == 0, "stack: kite acts, advance does not")
enemies = {}
given = {}; stack:Update(60, ctx)
check(Cmds(10) == 0 and Cmds(16) == 0, "stack: within the hold nothing else acts (units finish the back step)")
given = {}; stack:Update(600, ctx)
check(Cmds(16) == 8, "stack: after the hold the units are handed to 'advance' (" .. Cmds(16) .. ")")

-- per-unit overrides: a Pounder with a short step is its own cohort
enemies = { Foe(450, 40, 40 * lv) }
local km = NewHost()
for _, id in ipairs(lashers) do km:Assign(id, "kite", { step = 400 }) end
km:Assign(pounder, "kite", { step = 150, step_min = 100 })
local x0l, x0p = W.units[lashers[1]].x, W.units[pounder].x
given = {}; km:Update(30, ctx)
local dl, dp
for _, g in ipairs(given) do
    if g.uid == lashers[1] then dl = x0l - g.p[1] end
    if g.uid == pounder then dp = x0p - g.p[1] end
end
check(dl and dp and dl > 300 and dp < 250, "one behaviour, different tunables per unit (" .. tostring(dl) .. " vs " .. tostring(dp) .. ")")

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
