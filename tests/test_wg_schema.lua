-- tests/test_wg_schema.lua
-- bar_framework/wg_channels.lua: getters are nil-safe, Check/Publish enforce the schema, game_state passes the new
-- WG.MetalBot fields through.  Run from the repo root: python tests/run_lua.py tests/test_wg_schema.lua

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

local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")
local GS = VFS.Include("LuaUI/Widgets/bar_framework/game_state.lua")

-- nil-safe getters
check(next(CH.MetalBot(nil)) == nil, "MetalBot(nil) is an empty table")
check(CH.MetalBot({}).intel == nil, "MetalBot({}).intel is nil without erroring")
check(CH.Strategy(nil) == nil and CH.Spine(nil) == nil and CH.BombPlan(nil) == nil, "nil WG gives nil channels")
check(CH.TileLabHeld(nil, 5) == false and CH.TileLabHeld({}, 5) == false, "TileLabHeld false when nothing is published")
check(CH.TileLabHeld({ TileLabHold = function(id) return id == 7 end }, 7) == true, "TileLabHeld follows the hook")
check(CH.SaviorWant({}) == nil and CH.SaviorWant({ AntiNuke = { saviorWant = 3 } }) == 3, "SaviorWant")
check(next(CH.DragonLabs({})) == nil, "DragonLabs of nothing is empty")
check(CH.DragonLabs({ DragonLab = { id = 9, x = 1, z = 2 } })[9].x == 1, "DragonLabs falls back to the single DragonLab")
check(CH.DragonLabs({ DragonLabs = { [4] = { id = 4 } }, DragonLab = { id = 9 } })[4] ~= nil, "DragonLabs prefers the plural channel")
check(next(CH.Plan({})) == nil, "Plan of no strategy is empty")
check(CH.Plan({ Strategy = { Plan = function() return { army = "raid" } end } }).army == "raid", "Plan reads the strategy")
local ro = pcall(function() CH.MetalBot(nil).x = 1 end)
check(not ro, "the empty table is read-only")

-- schema
check(CH.Check("MetalBot", { armyValue = 10, intel = {} }) == nil, "a good MetalBot passes")
check(CH.Check("MetalBot", { armyValue = "ten" }) ~= nil, "a wrong field type is caught")
check(CH.Check("MetalBot", { armyVlaue = 10 }) ~= nil, "a misspelt MetalBot field is caught (closed channel)")
check(CH.Check("Strategy", { whatever = 1 }) == nil, "an open channel accepts extra fields")
check(CH.Check("Nope", {}) ~= nil, "an unknown channel is caught")
check(CH.Check("TileLabHold", 5) ~= nil and CH.Check("TileLabHold", function() end) == nil, "TileLabHold must be a function")
check(CH.Check("AntiNuke", { saviorWant = 2 }) == nil, "AntiNuke passes")

CH.STRICT = true
local okp = pcall(CH.Publish, {}, "MetalBot", { armyValue = "x" })
check(not okp, "STRICT Publish rejects a bad value")
local into = {}
CH.Publish(into, "Strategy", { Name = function() return "a" end })
check(into.Strategy ~= nil, "Publish stores a good value")
check(#CH.Validate({ MetalBot = { armyValue = 1 } }) == 0, "Validate passes a clean WG")
check(#CH.Validate({ MetalBot = { armyValue = 1 }, Bogus = {} }) == 1, "STRICT Validate flags an unknown channel")
CH.STRICT = false

-- game_state passes the new fields through
WG = { MetalBot = { airAlarm = { frame = 5, n = 2 }, scoutWant = 3, ringRadarWant = 1, callScouts = 2, hunt = true,
                    homeX = 100, homeZ = 200, foeX = 900, foeZ = 800, foeDist = 1000, raid = { n = 1 }, airLosses = 4 } }
local st = GS.Collect(30, {})
check(st.airAlarm and st.airAlarm.n == 2, "game_state: airAlarm")
check(st.scoutWant == 3 and st.ringRadarWant == 1 and st.callScouts == 2, "game_state: scout counts")
check(st.hunt == true and st.airLosses == 4 and st.raid.n == 1, "game_state: hunt / airLosses / raid")
check(st.home.x == 100 and st.foe.z == 800 and st.foeDist == 1000, "game_state: home / foe")
WG = {}
st = GS.Collect(30, {})
check(st.home == nil and st.airAlarm == nil, "game_state: empty WG leaves them nil")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then error("wg_schema failed") end
