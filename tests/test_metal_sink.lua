-- tests/test_metal_sink.lua: bar_framework/metal_sink.lua with a fake spine and con broker (tests/spring_stub.lua).
-- Run from the repo root: python tests/run_lua.py tests/test_metal_sink.lua
--   * the lab and the energy ratio come from the sink unit (a Dragon: coraap, 14.1 E per metal);
--   * nothing starts below SINK_SPEND_FRAC (85%) of the spine's spend capacity (nor below SINK_MIN_INCOME); at 85% a spot in front of
--     the spine is found and a "sinklab" con job (section "sink") is added; without a capacity figure SINK_INCOME decides;
--   * sink spots lie SINK_PITCH apart: the middle one first, then alternating sides, then the next row;
--   * the con places the lab, the frame is a frame (trans.noConLabs), helpers repair it, it finishes: WG.SinkLabs publishes it with
--     decoyMax 32 (WG.DragonLab / WG.DragonLabs carry the same record); a second lab waits for a floating bank and takes spot 2;
--   * a finished lab that dies is unpublished and its spot is free again; a sink for another unit finds another lab.
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

local MS = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")

local jobs, released = {}, {}
local CB = {
    AddJob = function(cb, j) jobs[j.name] = j end,
    Release = function(cb, id, helper) released[#released + 1] = id end,
    Take = function(cb, job, o) return nil end,
}
local trans = { CB = {}, noConLabs = {} }
local spine = { Front = function()
    return { dx = 1, dz = 0, px = 0, pz = 1, facing = 0 }, { { x = 2000, z = 6000 }, { x = 2000, z = 6272 } }
end }
local capacity = 3000
MS.Init{ cfg = { SINK_HELPERS = 2, SINK_FLOAT_FRAMES = 60 }, CB = CB,
         SPINE = function() return spine end, trans = function() return trans end, teamID = 0,
         Capacity = function() return capacity end }

-- the lab and the ratio come from the unit
local lab = MS.LabDef()
check(lab and lab.name == "coraap", "the Dragon's lab is the T2 air plant (" .. tostring(lab and lab.name) .. ")")
local dragon = UnitDefNames.corcrwh
check(dragon and math.abs(MS.UnitEnergyPerMetal() - dragon.energyCost / dragon.metalCost) < 1e-9, "the unit's energy per metal")
check(MS.EnergyRatio() == nil, "no energy ratio before a sink lab is wanted")

local res = { metalIncomeS = 2000, metal = 100, metalStorage = 20000 }
local frame = 0
local function Step(n) for _ = 1, n or 1 do frame = frame + 30; W.frame = frame; MS.Update(frame, res) end end

Step(2)
check(next(jobs) == nil, "2000 of 3000 (67%): below 85%, no job")
check(WG.EcoLedger and WG.EcoLedger.consumers.sink and WG.EcoLedger.consumers.sink.energyPerMetal == MS.EnergyRatio, "the sink registers its energy per metal with the ledger (line_transition's energy push reads it)")
res.metalIncomeS = 2600
Step(1)
check(jobs.sinklab ~= nil and #S.Log("%[SINK%].*spot 1 %(") == 1, "2600 of 3000 (87%): a spot is found and the con job added")
local job = jobs.sinklab
check(job.section == "sink", "the job is in the sink section")
check(job.want() == 1, "the job wants one con")
local site = MS.State.jobs[1]
check(site and site.x > 2000 + 600, "the first spot is past the spine's front block (" .. tostring(site and site.x) .. ")")
check(site and math.abs(site.z - 6136) <= 16, "...and in the middle of the stack (z " .. tostring(site and site.z) .. ")")
check(MS.EnergyRatio() ~= nil, "the energy ratio applies once a lab is being placed")

-- no capacity figure: SINK_INCOME decides
do
    local MS2 = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")
    MS2.Init{ cfg = { SINK_INCOME = 2000 }, CB = CB, SPINE = function() return spine end, trans = function() return trans end, teamID = 0 }
    check(MS2.SpineSaturated({ metalIncomeS = 1900 }) == false and MS2.SpineSaturated({ metalIncomeS = 2100 }) == true,
          "without a capacity figure SINK_INCOME decides")
    local MS3 = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")
    MS3.Init{ cfg = {}, CB = CB, SPINE = function() return spine end, trans = function() return trans end, teamID = 0, Capacity = function() return 100 end }
    check(MS3.SpineSaturated({ metalIncomeS = 400 }) == false, "a tiny capacity does not start the sink under SINK_MIN_INCOME")
end

-- spots
local x1, z1 = MS.SpotPos(1)
local x2, z2 = MS.SpotPos(2)
local x3, z3 = MS.SpotPos(3)
local x6, z6 = MS.SpotPos(6)
check(x2 == x1 and math.abs((z2 - z1) - 384) <= 16, "spot 2 is one pitch to the side (" .. tostring(z2 - z1) .. ")")
check(x3 == x1 and math.abs((z3 - z1) + 384) <= 16, "spot 3 is one pitch to the other side")
check(math.abs((x6 - x1) - 384) <= 16 and math.abs(z6 - z1) <= 16, "spot 6 starts the next row, toward the enemy")

-- the con broker hands a con over: it is told to place the lab
local con = S.Spawn("corca", 0, 2000, 6100, { silent = true })
check(job.canTake(con) == true, "a T1 air con can place the lab")
local gnd = S.Spawn("corck", 0, 2000, 6100, { silent = true })
check(job.canTake(gnd) == false, "a ground con that cannot build the lab is refused")
check(job.start(con, frame) == true, "start accepts the con")
local placed
for _, o in ipairs(W.orders) do if o.id == con and o.cmd == -lab.id then placed = o end end
check(placed ~= nil, "the con is ordered to build the lab")

-- the frame appears (the stub: a unit being built by the con), then finishes
local labU = S.Spawn("coraap", 0, site.x, site.z, { silent = true })
MS.OnCreated(labU, lab.id, con, frame)
check(trans.noConLabs[labU] == true, "the frame is excluded from T2 con orders")
Step(1)
check(MS.State.jobs[1] and MS.State.jobs[1].id == labU, "the frame is tracked")
MS.OnFinished(labU, frame)
local rec = WG.SinkLabs and WG.SinkLabs[labU]
check(rec ~= nil and rec.decoyMax == 32 and rec.unit == "corcrwh" and rec.spot == 1, "a finished lab is published in WG.SinkLabs with decoyMax 32")
check(WG.DragonLab and WG.DragonLab.id == labU and WG.DragonLabs[labU] == rec, "WG.DragonLab / WG.DragonLabs carry the same record")
check(#released >= 1, "the cons are released")
check(#S.Log("%[SINK%].*finished at spot 1 %(1 standing") == 1, "the finish is logged")

-- a second lab only while metal floats, on the next spot
Step(5)
check(#MS.State.jobs == 0, "bank not floating: no second site")
res.metal = 9000
Step(4)
check(MS.State.jobs[1] ~= nil and MS.State.jobs[1].spot == 2, "a floating bank starts the next site, on spot 2")

-- the first lab dies
S.Kill(labU)
Step(1)
check(WG.SinkLabs[labU] == nil and WG.DragonLabs[labU] == nil, "a dead lab is unpublished")
MS.OnDestroyed(12345, nil, nil, frame)           -- not the tracked frame: no row

-- a big surplus opens several labs at once (up to SINK_PARALLEL), not one at a time
do
    local MS6 = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")
    local jobs6 = {}
    local CB6 = { AddJob = function(cb, j) jobs6[j.name] = j end, Release = function() end, Take = function() return nil end }
    MS6.Init{ cfg = { SINK_PARALLEL = 3, SINK_MAX = 10 }, CB = CB6, SPINE = function() return spine end, trans = function() return { CB = {}, noConLabs = {} } end,
              teamID = 0, Capacity = function() return 1000 end }
    local absorb = MS6.LabAbsorb()
    check(absorb and absorb > 0, "a lab's absorb (m/s) is computed from the unit and the decoys (" .. tostring(absorb) .. ")")
    local res6 = { metalIncomeS = 1000 + 5 * absorb, metal = 100, metalStorage = 20000 }
    local f6 = frame
    for _ = 1, 3 do f6 = f6 + 30; W.frame = f6; MS6.Update(f6, res6) end
    check(#MS6.State.jobs == 3, "surplus income of ~5 labs opens SINK_PARALLEL (3) labs at once (" .. #MS6.State.jobs .. ")")
    check(MS6.DesiredLabs(f6, res6) >= 5, "...and asks for about five in all (" .. tostring(MS6.DesiredLabs(f6, res6)) .. ")")
    local spots = {}
    for _, J in ipairs(MS6.State.jobs) do spots[J.spot] = true end
    check(spots[1] and spots[2] and spots[3], "...on spots 1, 2 and 3")
end

-- a sink for another unit finds its own lab
do
    local MS4 = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")
    MS4.Init{ cfg = { SINK_UNIT = "corkarg" }, CB = CB, SPINE = function() return spine end, trans = function() return trans end, teamID = 0 }
    local l4 = MS4.LabDef()
    check(l4 == nil or (l4.isFactory and l4.name ~= "coraap"), "another unit gets its own lab (" .. tostring(l4 and l4.name) .. ")")
end
-- a ground lab (e.g. the Skuttle's coralab, built by bot cons): no con broker job, one of the spine's own cons is borrowed and given back
do
    -- a made-up unit and a ground lab for it that only a T1 bot con (corck) can place
    local U = { id = 9501, name = "xsink", metalCost = 700, energyCost = 20000, buildTime = 20000, speed = 50, buildOptions = {} }
    local LAB = { id = 9502, name = "xlab", isFactory = true, isBuilder = true, speed = 0, metalCost = 2000, energyCost = 20000,
                  buildTime = 30000, xsize = 8, zsize = 8, buildOptions = { 9501 }, weapons = {}, customParams = {}, modCategories = {} }
    UnitDefs[9501], UnitDefNames.xsink, UnitDefs[9502], UnitDefNames.xlab = U, U, LAB, LAB
    local ck = UnitDefNames.corck
    ck.buildOptions = ck.buildOptions or {}
    ck.buildOptions[#ck.buildOptions + 1] = 9502
    local MS5 = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")
    local borrowed, given = {}, {}
    local gcon = S.Spawn("corck", 0, 2000, 6100, { silent = true })
    local free = nil
    local jobs5 = {}
    local CB5 = { AddJob = function(cb, j) jobs5[j.name] = j end, Release = function() end, Take = function() return nil end }
    MS5.Init{ cfg = { SINK_UNIT = "xsink" }, CB = CB5, SPINE = function() return spine end, trans = function() return trans end, teamID = 0,
              Capacity = function() return 1000 end,
              BorrowCon = function(defID) borrowed[#borrowed + 1] = defID; return free end,
              GiveBackCon = function(uid) given[#given + 1] = uid end }
    local l5 = MS5.LabDef()
    check(l5 and l5.name == "xlab", "the unit's lab is looked up (" .. tostring(l5 and l5.name) .. ")")
    local res5 = { metalIncomeS = 900, metal = 100, metalStorage = 20000 }
    local f5 = frame
    local function Step5() f5 = f5 + 30; W.frame = f5; MS5.Update(f5, res5) end
    Step5(); Step5()      -- the first tick opens the job, the next one asks the spine for a con
    check(jobs5.sinklab == nil, "a ground lab registers no con broker job")
    check(#borrowed >= 1 and borrowed[1] == l5.id, "the spine is asked for a con that can build the lab")
    check(#S.Log("%[SINK%].*no spine con") >= 1, "no free con: the wait is logged")
    free = gcon
    Step5()
    local placed5
    for _, o in ipairs(W.orders) do if o.id == gcon and o.cmd == -l5.id then placed5 = o end end
    check(placed5 ~= nil, "the borrowed con is ordered to build the lab")
    local frameU = S.Spawn("corlab", 0, MS5.State.jobs[1].x, MS5.State.jobs[1].z, { silent = true })
    MS5.OnCreated(frameU, l5.id, gcon, f5)
    MS5.OnFinished(frameU, f5)
    check(given[1] == gcon, "the con is given back to the spine when the lab stands")
end
check(#W.errors == 0, "no Lua errors (" .. tostring(W.errors[1]) .. ")")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
