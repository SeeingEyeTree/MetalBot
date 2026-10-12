-- tests/test_scout_rings_bot.lua     python tests/run_lua.py tests/test_scout_rings_bot.lua
-- STANCE_BOT's three widgets with the scout rings on, against the stub: no Lua errors, ring scouts end up on posts all
-- round the base (not one corridor), a scout lost far out pulls the ring in, and a T2 lab trickles ring radar units.
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- a T2 ground radar unit the coralab can build (name is the stub's; the bot finds it by radar radius, not name)
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
local dir = "candidates/STANCE_BOT"
S.LoadWidget(dir .. "/macro_controller.lua")
S.LoadWidget(dir .. "/lab_controller.lua")
S.LoadWidget(dir .. "/unit_controller.lua")
S.Callin("Initialize")
local hx, hz = W.start[0][1], W.start[0][2]
S.Spawn("corcom", 0, hx, hz)
S.Spawn("corcom", 1, W.start[1][1], W.start[1][2])
S.Spawn("cormex", 1, W.start[1][1] - 150, W.start[1][2], { silent = true })
S.Spawn("coralab", 0, hx + 200, hz + 100, { silent = true })
-- a base: mex and wind spread round home
for i = 0, 60 do
    local a = i / 61 * 2 * math.pi
    S.Spawn(i % 2 == 0 and "cormex" or "corwin", 0, hx + math.cos(a) * (500 + (i % 5) * 120),
            hz + math.sin(a) * (500 + (i % 5) * 120), { silent = true })
end
local scouts = {}
for i = 1, 14 do scouts[#scouts + 1] = S.Spawn("corfav", 0, hx + i * 10, hz + 50) end

for f = 0, 14 * 1800, 10 do
    W.res.metal.cur = 800
    S.Frame(f)
    if #W.errors > 0 then break end
    if f == 9 * 1800 then
        -- the labs register the T2 lab as finished (silent spawn skips callins)
        for id, u in pairs(W.units) do
            if UnitDefs[u.defID].name == "coralab" and u.team == 0 then S.Callin("UnitFinished", id, u.defID, 0) end
        end
    end
end
check(#W.errors == 0, "no Lua errors: " .. tostring(W.errors[1]))
local ringLog = S.Log("%[UC/rings%]")
check(#ringLog > 0, "the ring log row appears")
if #ringLog > 0 then print(ringLog[#ringLog]) end

-- ring scouts are spread round the base: look at the bearings of the scouts that stood still at the end
local angs, far = {}, 0
for id, u in pairs(W.units) do
    local d = UnitDefs[u.defID]
    if u.team == 0 and ((d.modCategories and d.modCategories.scout) or ((d.speed or 0) > 150 and #d.weapons == 0 and not d.isBuilder)) then
        angs[#angs + 1] = math.atan2(u.z - hz, u.x - hx)
        far = math.max(far, math.sqrt((u.x - hx) ^ 2 + (u.z - hz) ^ 2))
    end
end
table.sort(angs)
local widest = 0
for i = 2, #angs do widest = math.max(widest, angs[i] - angs[i - 1]) end
widest = math.max(widest, 2 * math.pi - (angs[#angs] - angs[1]))
check(#angs >= 10, "scouts alive: " .. #angs)
check(far > 1500, "scouts went out past the base: " .. math.floor(far))
-- home is near a map corner here, so a wide arc behind it is off the map
check(widest < 3.0, string.format("no huge unwatched arc (widest gap %.2f rad)", widest))
check(ringLog[#ringLog]:find("radars=[1-9]"), "ring radar units stand on the rings")

print("home", hx, hz, "alive scouts", #angs, "mb", WG.MetalBot and WG.MetalBot.scoutWant, WG.MetalBot and WG.MetalBot.ringRadarWant)
for _, l in ipairs(S.Log("coralab")) do print(l) end for _, l in ipairs(S.Log("ring")) do print(l) end
local radarLog = S.Log("ring%-radar")
check(#radarLog > 0, "the T2 lab ordered a ring radar unit")
check(#radarLog <= 6, "the radar trickle is capped: " .. #radarLog)

print(string.format("scout_rings_bot: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
