-- tests/test_intel_facts.lua: enemy_intel.Facts / Blobs / EcoTargets / RadarCovers (what game_state hands to hooks).
local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}
local failures, checks = 0, 0
local function check(cond, what) checks = checks + 1; if not cond then failures = failures + 1; print("FAIL: " .. what) end end

local MM = VFS.Include("LuaUI/Widgets/bar_framework/map_model.lua")
local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
local EI = VFS.Include("LuaUI/Widgets/bar_framework/enemy_intel.lua")
MM.Init(0, 0); MM.SetHome(W.start[0][1], W.start[0][2])
EI.Init{ UQ = UQ, MM = MM, allyID = 0 }

for i = 1, 5 do S.Spawn("corgator", 1, 6000 + i * 30, 6000, { silent = true }) end      -- a blob
S.Spawn("corgator", 1, 9000, 3000, { silent = true })                                  -- a lone unit
S.Spawn("corrl", 1, 7000, 7000, { silent = true })                                     -- AA tower
S.Spawn("corfmd", 1, 7200, 7000, { silent = true })                                    -- anti-nuke (interceptor)
S.Spawn("corrad", 1, 8000, 8000, { silent = true })                                    -- radar
S.Spawn("corwin", 1, 8100, 8100, { silent = true })                                    -- eco
for i = 1, 3 do S.Spawn("cormex", 1, 8200 + i * 40, 8200, { silent = true }) end
EI.Scan(10)
check(EI.Count() > 0, "the stub shows enemies to the intel (" .. EI.Count() .. ")")

local blobs = EI.Blobs(10)
check(#blobs >= 1 and blobs[1].n == 5, "the blob of five is one cluster (" .. (blobs[1] and blobs[1].n or 0) .. ")")
check(#blobs == 2 and blobs[2].n == 1, "the lone unit is its own cluster")
check(blobs[1].density > blobs[2].density, "the blob is denser")

local f = EI.Facts(10)
check(f.aaStatic > 0 and f.aaValue >= f.aaStatic, "AA value is counted")
check(f.radars == 1 and EI.RadarCovers(8000, 8000) and not EI.RadarCovers(500, 500), "radar structures and coverage")
check(f.staticDef > 0, "static defence is counted")
local eco = EI.EcoTargets(2)
check(#eco == 2 and eco[1].value >= eco[2].value, "eco targets, best first, capped (" .. #eco .. ")")
check(EI.Summary(10).facts ~= nil, "Summary carries the facts")

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
