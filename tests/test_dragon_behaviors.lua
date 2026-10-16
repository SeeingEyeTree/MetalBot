-- tests/test_dragon_behaviors.lua: behaviors/dragon_raid.lua + behaviors/dragon_defend.lua (DRAGON_ECO's Dragons), stance
-- `extras`, and Strategy:Assign for a unit the stance does not build.  Run from the repo root:
--   python tests/run_lua.py tests/test_dragon_behaviors.lua
--   * stance extras: loaded, never part of the comp, and Strategy:Assign attaches their behaviours;
--   * dragon_raid.Pick: commander first, else build power, else anti-air, else the closest eco, else a structure, else the base;
--   * waves: fewer than `wave` Dragons wait, `wave` launch together; the wave MOVEs until it is near, then ATTACKs the
--     target; a dead target is replaced at once; a wave under `min_left` is released back to waiting;
--   * dragon_defend: waiting Dragons FIGHT an intruder group inside the perimeter (the nearest ones, not all), go back to the
--     gather point after `return_after`, and a Dragon in a wave is not touched.
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
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1) end

local BH = VFS.Include("LuaUI/Widgets/bar_framework/behavior_host.lua")
local ST = VFS.Include("LuaUI/Widgets/bar_framework/strategy.lua")
local SL = VFS.Include("LuaUI/Widgets/bar_framework/stance_loader.lua")
local RAID = VFS.Include("LuaUI/Widgets/bar_framework/behaviors/dragon_raid.lua")

-- ── stance extras ─────────────────────────────────────────────────────────────
local stance = SL.Prepare{ name = "t", units = { { n = "corlevlr", share = 1 } },
                           extras = { { n = "corcrwh", behaviors = { "dragon_raid", "dragon_defend" },
                                        cfg = { dragon_raid = { wave = 3, min_left = 2 } } } } }
check(stance and #stance.units == 1 and #stance.extras == 1, "extras are loaded and are not part of the comp")
check(stance.byDef[UnitDefNames.corcrwh.id] == nil and stance.extraByDef[UnitDefNames.corcrwh.id] ~= nil, "an extra is not a comp unit")
local strat = ST.New{ stances = { t = stance }, initial = "t", log = false, loader = SL }
local given = {}
local host = BH.New{ give = function(uid, cmd, p) given[#given + 1] = { uid = uid, cmd = cmd, p = p } end }
local d1 = S.Spawn("corcrwh", 0, 1000, 1000, { silent = true })
check(strat:Assign(host, d1, UnitDefNames.corcrwh.id) and host:Has(d1), "Strategy:Assign attaches an extra's behaviours")
host:Remove(d1)
check(#strat.stances.t.units == 1 and strat:Pick(function() return true end) == UnitDefNames.corlevlr.id, "the lab pick never offers an extra")

-- ── ctx ───────────────────────────────────────────────────────────────────────
local recs, cmdr, intr = {}, nil, {}
local function C(o) -- an enemy_intel class table
    local c = { mobile = false, air = false, armed = false, commander = false, bp = 0, eco = false, hitsAir = false }
    for k, v in pairs(o or {}) do c[k] = v end
    return c
end
local ctx = {
    EnemyBase = function() return 9000, 9000 end,
    EnemyRecords = function() return recs end,
    EnemyCommander = function() if cmdr then return cmdr.x, cmdr.z, cmdr.f, cmdr.uid end end,
    Intruders = function() return intr end,
    Gather = function() return 3000, 3000 end,
}
local function Rec(uid, x, z, c, frame) recs[uid] = { x = x, z = z, c = c, frame = frame or 0 } end

-- ── Pick ──────────────────────────────────────────────────────────────────────
local cfg = RAID.cfg
local function Kind(frame, cx, cz) return RAID.Pick(cfg, ctx, frame or 100, cx or 3000, cz or 3000, 3) end
check(Kind().kind == "base", "nothing known: the enemy base")
Rec(501, 8000, 8000, C{ })                                   -- an unarmed structure that is nothing special
check(Kind().kind == "structure" and Kind().list[1].uid == 501, "a structure of no class: the nearest structure")
Rec(502, 7000, 7000, C{ eco = true })
Rec(503, 8800, 8800, C{ eco = true })
local p = Kind()
check(p.kind == "eco" and p.list[1].uid == 502 and p.list[2].uid == 503, "eco: the closest first (" .. tostring(p.kind) .. ")")
Rec(504, 8500, 8500, C{ armed = true, hitsAir = true })       -- AA beats eco even though it is further
check(Kind().kind == "aa" and Kind().list[1].uid == 504, "anti-air before eco")
Rec(505, 8700, 8700, C{ bp = 300 })                           -- a factory
Rec(506, 7600, 7600, C{ bp = 100, mobile = true }, 10)       -- a constructor seen long ago: stale
check(Kind(100000).kind == "bp" and Kind(100000).list[1].uid == 505, "build power before AA; a stale mobile constructor is skipped")
check(Kind(100).list[1].uid == 506, "a fresh constructor counts as build power, the nearest first")
cmdr = { x = 8900, z = 8900, f = 90, uid = 700 }
p = Kind(100)
check(p.kind == "commander" and p.list[1].uid == 700 and #p.list == 1, "the commander before everything")
cmdr.f = 0
check(Kind(100000).kind ~= "commander", "a commander sighting older than commander_age is not chased")
cmdr = nil

-- ── waves + defend ────────────────────────────────────────────────────────────
recs = {}
local over = { dragon_raid = { wave = 3, min_left = 2, arrive = 500, retarget = 60, split = 2 } }
local dr = {}
local function Dragon(x, z)
    local id = S.Spawn("corcrwh", 0, x, z, { silent = true })
    host:Assign(id, { "dragon_raid", "dragon_defend" }, over)
    dr[#dr + 1] = id
    return id
end
local function Orders(id, cmd)
    local out = {}
    for _, g in ipairs(given) do if g.uid == id and (not cmd or g.cmd == cmd) then out[#out + 1] = g end end
    return out
end
local function Last(id) local t = Orders(id); return t[#t] end
local frame = 0
local function Step(n) for _ = 1, n or 1 do frame = frame + 30; host:Update(frame, ctx) end end

Dragon(3000, 3000); Dragon(3010, 3000)
Step(1)
local g = Last(dr[1])
check(g and g.cmd == 10 and near(g.p[1], 3000, 200), "waiting Dragons MOVE to the gather point")
check(#S.Log("%[DW%].*launched") == 0, "no wave below `wave`")
-- an intrusion: the nearest waiting Dragons fight it
intr = { { x = 3300, z = 3000, v = 700, n = 2 } }
Step(1)
g = Last(dr[1])
check(g and g.cmd == 16 and near(g.p[1], 3300, 1), "waiting Dragons FIGHT an intruder group inside the perimeter")
check(#S.Log("%[DW%].*defend") >= 1, "the defence is logged")
intr = {}
for _ = 1, 22 do Step(1) end                          -- dragon_defend's return_after is 600 frames
g = Last(dr[1])
check(g and g.cmd == 10, "after return_after the Dragons go back to the gather point")

-- the third Dragon launches the wave
Dragon(3020, 3000)
Rec(801, 6000, 6000, C{ eco = true })
Step(1)
check(#S.Log("%[DW%].*wave 1 launched %(3 Dragons%)") == 1, "`wave` Dragons launch together")
g = Last(dr[1])
check(g and g.cmd == 10 and near(g.p[1], 6000, 1), "the wave MOVEs toward its target while far")
-- a Dragon made later waits (not in the wave) and is not sent
local late = Dragon(3030, 3000)
Step(1)
g = Last(late)
check(g and g.cmd == 10 and near(g.p[1], 3000, 200), "a Dragon made after the launch gathers for the next wave")
-- near the target: ATTACK the unit when it is in view (stub: a spawned enemy), FIGHT its place otherwise
for _, id in ipairs({ dr[1], dr[2], dr[3] }) do W.units[id].x, W.units[id].z = 5900, 5900 end
Step(1)
g = Last(dr[1])
check(g and g.cmd == 16 and near(g.p[1], 6000, 1) or (g and g.cmd == 20), "near the target the wave FIGHTs / ATTACKs it")
-- the target dies: the next pick at once; a commander appears: the wave goes for it
recs[801] = nil
Rec(802, 6500, 6500, C{ bp = 200 })
Step(1)
check(#S.Log("%[DW%].*wave 1.*bp") >= 1, "a dead target is replaced at once, build power now first")
cmdr = { x = 7000, z = 7000, f = frame, uid = 900 }
Step(3)
check(#S.Log("%[DW%].*wave 1.*commander") >= 1, "a commander in view pulls the wave")
-- the wave is shot down to fewer than min_left: the rest go back to waiting
S.Kill(dr[1]); S.Kill(dr[2])
Step(1)
check(#S.Log("%[DW%].*wave 1 over") == 1, "a wave under min_left is released")
g = Last(dr[3])
check(g and g.cmd == 10 and near(g.p[1], 3000, 200), "its survivors gather for the next wave")

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
