-- tests/test_unit_max.lua: a stance unit with `max = n` stops being picked / listed once n are alive (strategy.lua).
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}

local failures, checks = 0, 0
local function check(cond, what) checks = checks + 1; if not cond then failures = failures + 1; print("FAIL: " .. what) end end

local ST = VFS.Include("LuaUI/Widgets/bar_framework/strategy.lua")
local flak = UnitDefNames["corsent"].id
local gator = UnitDefNames["corgator"].id
local alive = 0
Spring.GetTeamUnitDefCount = function(team, defID) return defID == flak and alive or 0 end
Spring.GetMyTeamID = function() return 0 end

local strat = ST.New{ stances = { s = { name = "s", units = { { n = "corgator", share = 0.5 }, { n = "corsent", share = 0.5, max = 40 } } } }, initial = "s" }
local function Has(list, id) for _, u in ipairs(list) do if u.defID == id then return true end end return false end
check(Has(strat:UnitList(), flak), "flak is listed under its max")
alive = 39
check(Has(strat:UnitList(), flak), "39 of 40: still listed")
alive = 40
local ul = strat:UnitList()
check(not Has(ul, flak) and Has(ul, gator) and math.abs(ul[1].share - 1) < 1e-9, "40 of 40: dropped, the rest renormalised")
local picks = {}
for _ = 1, 10 do
    local d = strat:Pick(function() return true end)
    picks[d] = (picks[d] or 0) + 1
    strat:Note(d, 100)
end
check(not picks[flak] and picks[gator] == 10, "at max the picks are all Incisors")
alive = 10
local got = false
for _ = 1, 10 do local d = strat:Pick(function() return true end); if d == flak then got = true end; strat:Note(d, 100) end
check(got, "under max flak is picked again")

print(string.format("test_unit_max: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
