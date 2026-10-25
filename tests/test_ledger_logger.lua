-- tests/test_ledger_logger.lua
-- ledger_logger.lua against a tiny mock of Spring (no spring_stub needed):
--   * spend row: the metal rate each builder puts into each kind of thing, idle labs, and the "why" when income is not spent;
--   * fight row: our loss to an enemy and our kill count in value_weights terms; self-destruct / reclaim (no attacker) is ignored;
--   * scout row: an enemy first seen far away, reaching ARRIVE_R later, gives lead_s and seen_d; one that is first seen inside is a surprise;
--   * no "[LED] error" row.
-- Run from the repo root:  python tests/run_tests.py -k ledger_logger

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local out = {}
Spring = { Echo = function(s) out[#out + 1] = s end }
UnitDefs = {
    [1] = { name = "corgator", metalCost = 90,  energyCost = 700,  buildTime = 1500, speed = 90, weapons = { {} } },
    [2] = { name = "cormoho",  metalCost = 640, energyCost = 8100, buildTime = 9000, extractsMetal = 0.004, speed = 0 },
    [3] = { name = "corvp",    metalCost = 570, energyCost = 1550, isBuilder = true, isFactory = true, buildSpeed = 150, speed = 0 },
    [4] = { name = "cornanotc", metalCost = 230, energyCost = 3200, isBuilder = true, buildSpeed = 200, speed = 0 },
    [5] = { name = "armflea",  metalCost = 20,  energyCost = 0, buildTime = 400, speed = 150, weapons = { {} } },
    [6] = { name = "armmex",   metalCost = 50,  energyCost = 500, extractsMetal = 0.001, speed = 0 },
}
VFS = { Include = function(p) return dofile((p:gsub("^LuaUI/Widgets/", ""))) end }
Game = { mapName = "test" }

local units = {   -- id -> { def, team, x, z }
    [10] = { 3, 0, 1000, 1000 },      -- our vehicle plant, idle with an empty queue
    [11] = { 4, 0, 1100, 1000 },      -- our nano, building a Gator
    [12] = { 1, 0, 1100, 1050 },      -- the Gator being built (the nano's target)
}
local building = { [11] = 12 }
local res = { metal = { 9000, 10000, 100, 1000, 100 }, energy = { 500, 1000, 100, 200, 100 } }

Spring.GetMyTeamID, Spring.GetMyAllyTeamID = function() return 0 end, function() return 0 end
Spring.AreTeamsAllied = function(a, b) return a == b end
Spring.GetTeamStartPosition = function() return 1000, 0, 1000 end
Spring.GetTeamResources = function(_, kind) local r = res[kind]; return r[1], r[2], r[3], r[4], r[5] end
Spring.GetTeamUnits = function(team) local t = {}; for id, u in pairs(units) do if u[2] == team then t[#t + 1] = id end end; return t end
Spring.GetAllUnits = function() local t = {}; for id in pairs(units) do t[#t + 1] = id end; return t end
Spring.GetUnitDefID = function(id) local u = units[id]; return u and u[1] end
Spring.GetUnitTeam = function(id) local u = units[id]; return u and u[2] end
Spring.GetUnitPosition = function(id) local u = units[id]; if u then return u[3], 0, u[4] end end
Spring.GetUnitIsBuilding = function(id) return building[id] end
Spring.GetUnitCurrentBuildPower = function(id) return building[id] and 1 or 0 end
Spring.GetUnitIsBeingBuilt = function(id) return id == 12, id == 12 and 0.5 or 1 end
Spring.GetUnitCommands = function() return 0 end
Spring.GetRealBuildQueue = function() return {} end
Spring.GetTeamUnitCount = function() return 50 end
Spring.GetTeamMaxUnits = function() return 3000 end
Spring.GetUnitLosState = function() return { los = true, radar = false } end

local widget = {}
_G.widget = widget
assert(loadfile("ledger_logger.lua"))()
widget:Initialize()

local function Rows(tag) local r = {}; for _, l in ipairs(out) do if l:find("%[LED%] " .. tag, 1) then r[#r + 1] = l end end return r end
local function Field(row, k) return tonumber(row:match(" " .. k .. "=([%-%d%.]+)")) end

-- ── spend ──
widget:GameFrame(900)
local sp = Rows("spend")[1] or ""
check(#Rows("spend") == 1, "one spend row at frame 900")
check(Field(sp, "to_army_ground") == 12, "the nano puts 200 BP x 90 metal / 1500 build time = 12 m/s into ground army (" .. tostring(Field(sp, "to_army_ground")) .. ")")
check(sp:find("labs_idle=1", 1, true) ~= nil, "the idle plant is counted")
check(sp:find("why=idle_labs", 1, true) ~= nil, "pull 100 of 1000 with the bank at 90% and an idle lab: why=idle_labs")
check(Field(sp, "unexplained") == 100 - 12, "unexplained = pull - explained")
res.metal = { 1000, 10000, 950, 1000, 950 }
widget:GameFrame(1800)
sp = Rows("spend")[2] or ""
check(sp:find("why=spending", 1, true) ~= nil, "pull near income and a low bank: why=spending")

-- ── fight ──
widget:GameFrame(2000)
units[20] = { 1, 1, 3000, 3000 }       -- an enemy Gator
units[21] = { 6, 1, 3100, 3000 }       -- an enemy mex
widget:UnitDestroyed(12, 1, 0, 20, 1, 1)      -- our (half-built) Gator killed by the enemy
widget:UnitDestroyed(21, 6, 1, 11, 4, 0)      -- their mex killed by us
widget:UnitDestroyed(11, 4, 0, nil, nil, nil)  -- our nano reclaimed / decayed: not a loss
widget:GameFrame(2000 + 160)
local fr = Rows("fight")
check(#fr == 1, "one fight row after the quiet gap (" .. #fr .. ")")
fr = fr[1] or ""
local gatorV = 90 + 700 / 70
local mexV = 50 + 500 / 70 + 60 * 2.37
check(math.abs((Field(fr, "lost_army") or 0) - gatorV * 0.5) < 1, "the half-built Gator counts half (" .. tostring(Field(fr, "lost_army")) .. ")")
check(math.abs((Field(fr, "killed_eco") or 0) - mexV) < 1, "their mex counts cost + 60 s of income (" .. tostring(Field(fr, "killed_eco")) .. ")")
check((Field(fr, "lost_bp") or 0) == 0, "a reclaim with no attacker is not a loss")
check(fr:find("top_killed=armmex:1", 1, true) ~= nil, "top_killed lists the mex")
check((Field(fr, "ratio") or 0) > 1, "killed value / lost value > 1")
widget:GameFrame(2000 + 1800 - 2000 % 1800)   -- the next minute mark: a value row
check(#Rows("value") >= 1, "a cumulative value row each minute")

-- ── scout ──
units[30] = { 5, 1, 6000, 1000 }       -- an enemy Flea 5000 from home, first seen at frame 3000
widget:GameFrame(3000)
units[30][3] = 2500
widget:GameFrame(3300)                 -- 10 s later, 1500 from home: arrived
units[30][3] = 1100
widget:GameFrame(3330)
units[31] = { 5, 1, 1200, 1000 }       -- another, first seen inside the radius
widget:GameFrame(3360)
widget:GameFrame(4020)                 -- the wave closes (a scan frame, 660 after the last arrival)
local sc = Rows("scout")
check(#sc == 1, "one scout row for the wave (" .. #sc .. ")")
sc = sc[1] or ""
check(Field(sc, "lead_s") == 10, "lead_s = 10 (" .. tostring(Field(sc, "lead_s")) .. ")")
check(Field(sc, "seen_d") == 5000, "seen_d = 5000 (" .. tostring(Field(sc, "seen_d")) .. ")")
check(Field(sc, "n") == 2 and Field(sc, "surprise") == 0, "two units in the wave, not a surprise")
-- a second wave: first seen already inside the radius
units[40] = { 5, 1, 1300, 1000 }
widget:GameFrame(5010)
widget:GameFrame(5640)
local sc2 = Rows("scout")[2] or ""
check(Field(sc2, "lead_s") == 0 and Field(sc2, "surprise") == 1, "an enemy first seen inside the radius is a surprise (lead 0)")

check(#Rows("error") == 0, "no [LED] error row")
widget:Shutdown()

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
