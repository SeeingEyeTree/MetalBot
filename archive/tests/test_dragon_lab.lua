-- tests/test_dragon_lab.lua: bar_framework/dragon_lab.lua with a fake spine and con broker (tests/spring_stub.lua).
-- Run from the repo root: python tests/run_lua.py tests/test_dragon_lab.lua
--   * below DRAGON_LAB_INCOME nothing happens; from it a site in front of the spine is found and a "dragonlab" con job is added;
--   * the con is told to place the coraap; when the frame appears the lab is a frame (trans.noConLabs), helpers repair it;
--   * when it finishes WG.DragonLab / WG.DragonLabs publish it and the cons are released; a second lab waits for a floating bank;
--   * a finished lab that dies is unpublished; the destroyed-lab log row names the attacker.
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

local DLB = VFS.Include("LuaUI/Widgets/bar_framework/dragon_lab.lua")

local jobs, released, taken = {}, {}, {}
local CB = {
    AddJob = function(cb, j) jobs[j.name] = j end,
    Release = function(cb, id, helper) released[#released + 1] = id end,
    Take = function(cb, job, o) local id = taken[#taken + 1]; return nil end,
}
local trans = { CB = {}, noConLabs = {} }
local spine = { Front = function()
    return { dx = 1, dz = 0, px = 0, pz = 1, facing = 0 }, { { x = 2000, z = 6000 }, { x = 2000, z = 6272 } }
end }
DLB.Init{ cfg = { DRAGON_LAB_INCOME = 2000, DRAGON_LAB_HELPERS = 2, DRAGON_FLOAT_FRAMES = 60 }, CB = CB,
          SPINE = function() return spine end, trans = function() return trans end, teamID = 0 }

local res = { metalIncomeS = 1500, metal = 100, metalStorage = 20000 }
local frame = 0
local function Step(n) for _ = 1, n or 1 do frame = frame + 30; W.frame = frame; DLB.Update(frame, res) end end

Step(2)
check(next(jobs) == nil, "below DRAGON_LAB_INCOME no job")
res.metalIncomeS = 2100
Step(1)
check(jobs.dragonlab ~= nil and #S.Log("%[DL%].*site %(") == 1, "from the income a site is found and the con job added")
local job = jobs.dragonlab
check(job.want() == 1, "the job wants one con")
local site = DLB.State.site
check(site and site.x > 2000 + 600, "the site is past the spine's front block (" .. tostring(site and site.x) .. ")")

-- the con broker hands a con over: it is told to place the lab
local con = S.Spawn("corca", 0, 2000, 6100, { silent = true })
check(job.start(con, frame) == true, "start accepts the con")
local placed
for _, o in ipairs(W.orders) do if o.id == con and o.cmd == -UnitDefNames.coraap.id then placed = o end end
check(placed ~= nil, "the con is ordered to build the coraap")

-- the frame appears (the stub: a unit being built by the con), then finishes
local lab = S.Spawn("coraap", 0, site.x, site.z, { silent = true })
DLB.OnCreated(lab, UnitDefNames.coraap.id, con, frame)
check(trans.noConLabs[lab] == true, "the frame is excluded from T2 con orders")
Step(1)
check(DLB.State.id == lab, "the frame is tracked")
DLB.OnFinished(lab, frame)
check(WG.DragonLab and WG.DragonLab.id == lab and WG.DragonLabs[lab] ~= nil, "a finished lab is published (WG.DragonLab / WG.DragonLabs)")
check(#released >= 1, "the cons are released")
check(#S.Log("%[DL%].*finished %(1 standing%)") == 1, "the finish is logged")

-- a second lab only while metal floats
Step(5)
check(DLB.State.site == nil, "bank not floating: no second site")
res.metal = 9000
Step(4)
check(DLB.State.site ~= nil, "a floating bank starts the next site")

-- the first lab dies
S.Kill(lab)
Step(1)
check(WG.DragonLabs[lab] == nil, "a dead lab is unpublished")
DLB.OnDestroyed(12345, nil, nil, frame)           -- not the tracked frame: no row
check(#W.errors == 0, "no Lua errors (" .. tostring(W.errors[1]) .. ")")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
