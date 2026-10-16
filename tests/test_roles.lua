-- tests/test_roles.lua -- bar_framework/roles.lua (C4): role -> unit per faction.
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

local R = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
check(R.Faction() == "cor", "the stub team is Cortex")
check(R.Get("decoy") == "cordecom" and R.Get("sink_unit") == "corcrwh" and R.Get("radar_plane") == "corawac", "Cortex names")
check(R.Get("nonexistent_role") == nil, "an unknown role is nil, not an error")

-- every Cortex role names a unit the stub knows (a typo in the table would fall through UnitDefNames' plain-structure fallback and look fine)
local STUBBED = { sink_unit = true, radar_plane = true, fighter_t1 = true, fighter_t2 = true, bomber_t1 = true, bomber_t2 = true,
                  stunner = true, raider = true, con_t1_bot = true, con_t1_veh = true, con_t1_air = true, con_t2_air = true,
                  lab_t1_bot = true, lab_t1_veh = true, lab_t1_air = true, lab_t2_bot = true, lab_t2_veh = true, lab_t2_air = true, nano = true,
                  mex = true, wind = true }
for role, name in pairs(R.TABLE.cor) do
    if STUBBED[role] then check(rawget(UnitDefNames, name) ~= nil, "role " .. role .. " -> " .. name .. " is a def in the stub") end
end
check(R.Def("lab_t2_air").id == UnitDefNames.coraap.id and R.Id("lab_t2_air") == UnitDefNames.coraap.id, "Def / Id")
check(R.Is(UnitDefNames.corbw.id, "stunner") and not R.Is(UnitDefNames.corape.id, "stunner"), "Is")
local n = R.Names("stunner", "raider")
check(n.corbw and n.corape and not n.corveng, "Names: a set of the named roles")

-- overrides and the Armada fallback
R.Set("decoy", "armdecom")
check(R.Get("decoy") == "armdecom", "a role can be overridden")
R.SetFaction("arm")
check(R.Faction() == "arm" and R.Get("sink_unit") == "corcrwh", "an unfilled Armada role falls back to the Cortex name")
R.TABLE.arm.sink_unit = "armsomething"
check(R.Get("sink_unit") == "armsomething", "...and an Armada table entry wins once filled in")
R.SetFaction("cor")

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
