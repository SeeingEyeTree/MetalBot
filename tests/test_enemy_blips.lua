-- tests/test_enemy_blips.lua: enemy_intel's radar dots (BLIPS): a radar-only contact is worth the seen enemy ground comp that can move
-- as fast as it does; a dot that never moved (a building, probably) and a flying one count 0; dots count in GroundValue.
-- Run: python tests/run_lua.py tests/test_enemy_blips.lua
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
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI = dofile("bar_framework/enemy_intel.lua")
EI.Init{ UQ = UQ, allyID = 0 }

-- radar-only units: the engine gives no unit type for them
local hidden = {}
local realDefID = Spring.GetUnitDefID
Spring.GetUnitDefID = function(uid) if hidden[uid] then return nil end return realDefID(uid) end

local function Value(name) local d = UnitDefNames[name]; return (d.metalCost or 0) + (d.energyCost or 0) / 70 end
local function Scan(f) W.frame = f; EI.Scan(f) end

-- seen up close: 2 Pounders (slow, 40) and 1 Gator (fast, 85)
S.Spawn("corlevlr", 1, 8000, 8000, { silent = true })
S.Spawn("corlevlr", 1, 8050, 8000, { silent = true })
S.Spawn("corgator", 1, 8100, 8000, { silent = true })
Scan(30)
local base = EI.GroundValue(30)
check(math.abs(base - (2 * Value("corlevlr") + Value("corgator"))) < 1e-6, "the seen army counts as before (" .. base .. ")")

-- a fast dot: moving 80 elmos/s -> only the Gator type can do that
local fast = S.Spawn("corgator", 1, 6000, 6000, { silent = true }); hidden[fast] = true
local slow = S.Spawn("corlevlr", 1, 5000, 5000, { silent = true }); hidden[slow] = true
local still = S.Spawn("corlevlr", 1, 4000, 4000, { silent = true }); hidden[still] = true
Scan(60)
check(EI.BlipValue(fast) == 0, "a dot seen once has not moved yet: 0")
W.units[fast].x = 6000 - 80          -- 80 elmos in 1 s
W.units[slow].x = 5000 - 30          -- 30 elmos in 1 s
Scan(90)
check(math.abs(EI.BlipValue(fast) - Value("corgator")) < 1e-6, "an 80 elmos/s dot: worth a Gator (" .. EI.BlipValue(fast) .. ")")
local mean = (2 * Value("corlevlr") + Value("corgator")) / 3
check(math.abs(EI.BlipValue(slow) - mean) < 1e-6, "a 30 elmos/s dot: worth the mean of the seen comp (" .. EI.BlipValue(slow) .. ")")
check(EI.BlipValue(still) == 0, "a dot that never moved: 0 (likely a building)")
local withDots = EI.GroundValue(90)
check(math.abs(withDots - (base + Value("corgator") + mean)) < 1e-6, "GroundValue counts the moving dots (" .. withDots .. ")")

-- seen up close later: the dot becomes a record, not a blip
hidden[fast] = nil
Scan(120)
check(EI.BlipValue(fast) == 0, "a dot seen up close is a unit, no longer a blip")
-- a dot that is no longer seen expires
for _, id in ipairs({ slow, still }) do W.units[id] = nil end
Scan(120 + EI.BLIP_MEMORY + 30)
check(EI.BlipGroundValue(120 + EI.BLIP_MEMORY + 30) == 0, "old dots expire")

-- nothing seen up close yet: BLIP_DEFAULT
W.units = {}                      -- an empty map: nothing seen up close
local EI2 = dofile("bar_framework/enemy_intel.lua")
EI2.Init{ UQ = UQ, allyID = 0 }
local lone = S.Spawn("corgator", 1, 3000, 3000, { silent = true }); hidden[lone] = true
W.frame = 200; EI2.Scan(200); W.units[lone].x = 3000 - 60; W.frame = 230; EI2.Scan(230)
check(EI2.BlipValue(lone) == EI2.BLIP_DEFAULT, "no comp seen yet: BLIP_DEFAULT")

Spring.GetUnitDefID = realDefID
check(#W.errors == 0, "no Lua errors")
print(string.format("test_enemy_blips: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
