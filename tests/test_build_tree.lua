-- tests/test_build_tree.lua -- bar_framework/build_tree.lua (C1): who can build what, cached per defID.
-- Run: python tests/run_lua.py tests/test_build_tree.lua   (or python tests/run_tests.py -k build_tree)

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

local BT = VFS.Include("LuaUI/Widgets/bar_framework/build_tree.lua")
local function Id(n) return UnitDefNames[n].id end

-- builders and options
check(BT.CanBuild(Id("corca"), Id("coraap")), "a T1 air con places the T2 air plant")
check(not BT.CanBuild(Id("corck"), Id("coraap")), "a T1 bot con does not")
check(BT.CanBuild("corck", "corvp"), "names work as well as ids")
check(next(BT.Options(-5)) == nil and not BT.CanBuild(nil, Id("corvp")), "an unknown builder builds nothing")

-- predicates
check(BT.IsGroundCon("corck") and BT.IsGroundCon("corcv"), "bot and vehicle cons are ground cons")
check(not BT.IsGroundCon("corca") and not BT.IsGroundCon("corlab") and not BT.IsGroundCon("cornanotc"), "an air con, a lab and a nano are not")
check(not BT.IsGroundCon("corcom") and BT.IsGroundCon("corcom", { commander = true }), "the commander is excluded unless asked for")
check(BT.IsAirCon("corca") and not BT.IsAirCon("corck"), "air con")
check(BT.IsLab("corvp") and not BT.IsLab("corck"), "lab")
check(BT.Tier("coraca") == 2 and BT.Tier("corca") == 1, "tier from the techlevel param (default 1)")

-- labs for a unit
check(BT.CheapestLab("corraid").name == "corvp", "a raider is made by the vehicle plant")
check(BT.CheapestLab("corvamp").name == "coraap", "a T2 fighter by the T2 air plant")
check(BT.CheapestLab("corcrwh").name == "coraap" and #BT.LabsFor("corcrwh") == 1, "the Dragon has one lab")
check(BT.CheapestLab("corraid", { corlab = true }) == nil, "an allow list restricts the labs")
check(BT.CheapestLab("corraid", { corvp = true }).name == "corvp", "...and keeps an allowed one")
check(BT.CheapestLab("nonexistentunit") == nil, "no lab for an unknown unit")

-- who places a lab
local p = BT.Placers("coraap")
local airNames = {}
for _, d in ipairs(p.air) do airNames[d.name] = true end
check(airNames.corca and airNames.coraca and #p.ground == 0, "the T2 air plant is placed by air cons only")
check(BT.NeedsAir("coraap"), "NeedsAir: the T2 air plant")
check(not BT.NeedsAir("corvp"), "NeedsAir: not the vehicle plant (a ground con places it)")
local g = BT.Placers("corvp").ground
local gn = {}
for _, d in ipairs(g) do gn[d.name] = true end
check(gn.corck and not gn.corcom, "ground placers of the vehicle plant: the bot con, not the commander")

-- what a lab makes
check(BT.ConMadeBy("corvp").name == "corcv", "the vehicle plant makes the vehicle con")
check(BT.ConMadeBy("corap", { air = true }).name == "corca" and BT.ConMadeBy("corap") == nil, "the air plant makes an air con, no ground con")
check(BT.ConMadeBy("corlab", { name = "corck" }) and not BT.ConMadeBy("corlab", { name = "corcv" }), "o.name picks one by name")
check(BT.ConMadeBy("corlab", { canPlace = Id("corvp") }).name == "corck", "o.canPlace: a con that places the vehicle plant")
check(BT.ConMadeBy("corvp", { canPlace = Id("coravp") }) == nil, "...none when the stub's vehicle con cannot place a T2 plant")

-- prerequisites: the stub's T1 bot con cannot place coralab (the real one can); patch it
check(BT.EnablerLab("coralab") == nil, "before the patch nothing makes a con that places the T2 bot lab")
table.insert(UnitDefs[Id("corck")].buildOptions, Id("coralab"))
check(BT.CanBuild("corck", "coralab"), "a patched buildOptions list is noticed (the cache entry knows how many options it came from)")
BT.Reset()
check(BT.CanBuild("corck", "coralab"), "...and after Reset too")
local e = BT.EnablerLab("coralab")
check(e and e.name == "corlab", "the enabler of the T2 bot lab is the T1 bot lab (it makes the con)")
check(BT.EnablerLab("coralab", { corvp = true }) == nil, "an allow list can exclude the enabler")
local chain = BT.Prereq("coralab")
check(#chain >= 1 and chain[1].name == "corlab", "Prereq: the chain starts at the T1 bot lab")

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
