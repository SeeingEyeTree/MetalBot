-- tests/test_dragon_eco_bot.lua     python tests/run_lua.py tests/test_dragon_eco_bot.lua
-- candidates/DRAGON_ECO's three widgets against the stub: a wiring check (the stub teleports units and builds instantly).
--   * no Lua errors and no widget removed, through 20 game-minutes;
--   * the stance switches from pounder_hold to mammoth_hold once income holds 1.1k;
--   * once income reaches 85% of what the full spine can spend (the stub spine reports 54k, so the test pushes income to 60k) the sink picks a spot ([SINK] row);
--   * the line's con bots are handed to the spine at the switch;
--   * the perimeter guard plans posts and squads ([PG] row) and launches 50 Dragons as a wave ([DW] row).

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local nextId = 9300
local function MobileDef(name, cost, speed, opts)
    local d = { id = nextId, name = name, humanName = name, translatedHumanName = name, speed = speed,
                canFly = false, isBuilder = false, isFactory = false, metalCost = cost, energyCost = cost * 10,
                buildTime = cost * 10, buildSpeed = 0, buildDistance = 0, xsize = 4, zsize = 4,
                weapons = { { weaponDef = 1, onlyTargets = {} } }, buildOptions = {}, customParams = {},
                modCategories = {}, canMove = true }
    for k, v in pairs(opts or {}) do d[k] = v end
    UnitDefs[d.id], UnitDefNames[name] = d, d
    nextId = nextId + 1
    return d
end
MobileDef("coraak", 650, 35)
MobileDef("cordecom", 750, 37.5, { isBuilder = true, buildSpeed = 300, customParams = { isdecoycommander = "1" } })
table.insert(UnitDefNames.coralab.buildOptions, UnitDefNames.coraak.id)
table.insert(UnitDefNames.coralab.buildOptions, UnitDefNames.cordecom.id)

W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
W.res.metal.cur, W.res.metal.storage, W.res.metal.income, W.res.metal.pull = 800, 2000, 300, 100
local dir = "candidates/DRAGON_ECO"
S.LoadWidget(dir .. "/macro_controller.lua")
S.LoadWidget(dir .. "/lab_controller.lua")
S.LoadWidget(dir .. "/unit_controller.lua")
S.Callin("Initialize")
local hx, hz = W.start[0][1], W.start[0][2]
local ex, ez = W.start[1][1], W.start[1][2]
S.Spawn("corcom", 0, hx, hz)
S.Spawn("corcom", 1, ex, ez)
S.Spawn("corlab", 1, ex - 200, ez, { silent = true })

for f = 0, 20 * 1800, 10 do
    W.res.metal.cur = (f < 13 * 1800) and 800 or 40000      -- the 60k income floats the bank (the sink's first lab needs a float)
    W.res.metal.income = (f < 9 * 1800 and 300) or (f < 13 * 1800 and 1500) or 60000
    if f == 5 * 1800 then
        for i = 1, 12 do S.Spawn("corlevlr", 0, hx + 400 + i * 15, hz + 400) end
        for i = 1, 3 do S.Spawn("cormist", 0, hx + 400 + i * 15, hz + 450) end
    end
    if f == 15 * 1800 then
        for i = 1, 50 do S.Spawn("corcrwh", 0, hx + 600 + i * 5, hz + 600) end
    end
    S.Frame(f)
end

check(#W.errors == 0, "no Lua errors (" .. tostring(W.errors[1]) .. ")")
check(#S.Log("Removed widget") == 0, "no widget removed")
check(#S.Log("%[STRAT%].*switching to stance mammoth_hold") == 1, "the stance switches to mammoth_hold once")
local hand = S.Log("%[LN%].*T2 switch: %d+ line con bot")
check(#hand == 1, "at the T2 switch the line's con bots are handed to the spine (" .. tostring(hand[1]) .. ")")
check(#S.Log("%[SINK%]") >= 1, "the Dragon lab job runs once the spine is saturated (" .. tostring(S.Log("%[SINK%]")[1]) .. ")")
print("DL rows: " .. #S.Log("%[SINK%]") .. " first: " .. tostring(S.Log("%[SINK%]")[1]) .. " last: " .. tostring(S.Log("%[SINK%]")[#S.Log("%[SINK%]")]))
check(#S.Log("%[PG%] .*posts") >= 1, "the perimeter guard logs its ring")
check(#S.Log("%[DW%].*wave 1 launched %(50 Dragons%)") == 1, "50 Dragons launch as a wave (dragon_raid, from the stance's extras)")
check(#S.Log("%[DW%].*wave 1 %(50 Dragons%) %-> ") >= 1, "the wave picks a target")
do  -- every WG channel the bot published fits bar_framework/wg_channels.lua SCHEMA
    local CHK = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")
    local bad = CHK.Validate(WG)
    check(#bad == 0, "WG channels match the schema" .. (bad[1] and (": " .. bad[1]) or ""))
end
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
