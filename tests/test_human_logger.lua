-- tests/test_human_logger.lua
-- human_control_logger.lua's [HCL] loc rows against a tiny mock of Spring (no spring_stub needed).
-- Run from the repo root through lupa's Lua 5.1:  see tests/LUA_TESTING.md
--   * a MOVE order to Lashers with enemies near gets a cmd row AND a loc row (src=cmd) listing both sides;
--   * distances, ranges and the we_hit / they_hit counts are right for a hand-built position set;
--   * a selection near enemies gets a src=snap row every LOC_EVERY frames; far enemies produce no row;
--   * no "[HCL] error" row.

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local out = {}
Spring = {
    Echo = function(s) out[#out + 1] = s end,
    GetMyTeamID = function() return 0 end, GetMyAllyTeamID = function() return 0 end,
    GetGameFrame = function() return 0 end,
}
CMD = { STOP = 0, MOVE = 10, FIGHT = 16, ATTACK = 20, PATROL = 15 }
UnitDefs = {
    [1] = { name = "cormist", speed = 50, metalCost = 155, weapons = { {} }, maxWeaponRange = 700 },
    [2] = { name = "corlevlr", speed = 50, metalCost = 220, weapons = { {} }, maxWeaponRange = 350 },
    [3] = { name = "armstump", speed = 60, metalCost = 100, weapons = { {} }, maxWeaponRange = 400 },
    [4] = { name = "armart", speed = 40, metalCost = 120, weapons = { {} }, maxWeaponRange = 800 },
}
local units = {   -- id -> { def, team, x, z, hp }
    [10] = { 1, 0, 1000, 1000, 1.0 }, [11] = { 1, 0, 1000, 1100, 0.5 }, [12] = { 2, 0, 1000, 1200, 1.0 },
    [20] = { 3, 1, 1000, 1600, 1.0 },      -- 400 from the Pounder: a Stump (range 400) reaches it
    [21] = { 4, 1, 1000, 2500, 1.0 },      -- Art at 1300 from the Pounder: inside LOC_R, out of everyone's reach
    [22] = { 3, 1, 6000, 6000, 1.0 },      -- far away: never listed
}
local selected = { 10, 11, 12 }
Spring.GetTeamUnits = function() local t = {}; for id, u in pairs(units) do if u[2] == 0 then t[#t + 1] = id end end; return t end
Spring.GetAllUnits = function() local t = {}; for id in pairs(units) do t[#t + 1] = id end; return t end
Spring.GetUnitPosition = function(id) local u = units[id]; if u then return u[3], 0, u[4] end end
Spring.GetUnitDefID = function(id) local u = units[id]; return u and u[1] end
Spring.GetUnitHealth = function(id) local u = units[id]; if u then return u[5] * 100, 100 end end
Spring.GetUnitAllyTeam = function(id) return units[id][2] end
Spring.GetUnitTeam = function(id) return units[id][2] end
Spring.GetUnitLosState = function(id) return { los = true, typed = true } end
Spring.GetSelectedUnits = function() return selected end
Spring.GetResources = nil
Spring.GetTeamResources = function() return 0, 0, 0, 0 end
Spring.GetGroupList = function() return {} end
Spring.GetCameraState = function() return {} end
Spring.GetGroundHeight = function() return 0 end

local widget = {}
local chunk = assert(loadfile("human_control_logger.lua"))
-- the file starts with "local widget = widget": give it ours as a global
_G.widget = widget
chunk()
widget:Initialize()

local function Rows(tag) local r = {}; for _, l in ipairs(out) do if l:find("%[HCL%] " .. tag) then r[#r + 1] = l end end return r end

-- a MOVE order to the three, given at frame 100 (flushed at 101)
widget:GameFrame(100)
for _, id in ipairs({ 10, 11, 12 }) do
    widget:UnitCommand(id, units[id][1], 0, CMD.MOVE, { 1000, 0, 800 }, {}, 0, 0, false, false)
end
widget:GameFrame(101)

local cmds, locs = Rows("cmd"), Rows("loc")
check(#cmds == 1, "one cmd row for the batch (" .. #cmds .. ")")
check(#locs >= 1, "a loc row follows the MOVE order")
local row = locs[1] or ""
check(row:find("src=cmd", 1, true), "the loc row says it came with an order")
check(row:find(" n=3 ", 1, true), "three ordered units")
check(row:find("lead_d=400 ", 1, true), "the Pounder (lead) is 400 from the Stump: " .. row)
check(row:find("rng_min=350 rng_max=700", 1, true), "ranges of the ordered units")
check(row:find("foe_n=2 ", 1, true), "two enemies within LOC_R, the far one is not listed")
check(row:find("they_hit=1 ", 1, true), "only the Pounder is inside an enemy's range")
check(row:find("we_hit=1 ", 1, true), "only the Stump is inside an ordered unit's range (Pounder 350 < 400; Lasher 700 reaches it)")
check(row:find("armstump:1000:1600:400:400:1.00:1", 1, true), "the Stump is listed with position, distance, range, hp, los")
check(row:find("armart:1000:2500:1300:800", 1, true), "the Art is listed too (1300 from the Pounder, range 800)")
check(row:find("own=corlevlr:1000:1200:400:1.00,", 1, true), "own list starts with the lead unit and its distance to the nearest foe")

-- a snapshot of the selection, 60 frames later
widget:GameFrame(150)       -- 150 % 60 == 30: snap
local snaps = 0
for _, l in ipairs(Rows("loc")) do if l:find("src=snap", 1, true) then snaps = snaps + 1 end end
check(snaps == 1, "a snap row for the selection (" .. snaps .. ")")

-- enemies far away: no row
units[20], units[21] = nil, nil
local before = #Rows("loc")
widget:GameFrame(210)
check(#Rows("loc") == before, "no loc row when no enemy is within LOC_R")
check(#Rows("error") == 0, "no [HCL] error row")

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
