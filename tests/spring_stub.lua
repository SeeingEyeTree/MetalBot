-- tests/spring_stub.lua
-- A crude stand-in for the Spring/BAR widget API, so bot widgets can be loaded and run
-- under plain Lua 5.1 without the engine.
--
-- It is NOT a simulation of the game.  Everything happens instantly: a build order
-- produces a finished building on the next step, a factory order a finished unit, a
-- move order teleports the unit.  Its only job is to drive the widgets through their
-- code paths -- loading, callins, every periodic branch -- so that Lua errors (a nil
-- index, a misspelt function, a bad upvalue) show up here instead of in a match.
--
-- Unit defs are a hand-made Cortex subset with the fields the bot code reads.  Any
-- name looked up in UnitDefNames that is not listed gets a plain 1x1 structure def,
-- so blueprint files that mention other buildings still load.

local S = {}

-- ── Weapons ───────────────────────────────────────────────────────────────────

WeaponDefs = {
    [1] = { name = "laser",    range = 300,   type = "BeamLaser" },
    [2] = { name = "aa",       range = 700,   type = "MissileLauncher" },
    [3] = { name = "bomb",     range = 1280,  type = "AircraftBomb" },
    [4] = { name = "nuke",     range = 30000, type = "StarburstLauncher", targetable = 1 },
    [5] = { name = "antinuke", range = 2000,  type = "StarburstLauncher", interceptor = 1,
            coverageRange = 2000 },
    [6] = { name = "llt",      range = 450,   type = "BeamLaser" },
}
local GUN   = { { weaponDef = 1, onlyTargets = {} } }
local AAGUN = { { weaponDef = 2, onlyTargets = { vtol = true } } }
local BOMB  = { { weaponDef = 3, onlyTargets = {} } }

-- ── Unit defs ─────────────────────────────────────────────────────────────────

UnitDefs, UnitDefNames = {}, {}
local nextDefID = 1

local function Def(name, t)
    local d = {
        id = nextDefID, name = name, humanName = name, translatedHumanName = name,
        speed = 0, canFly = false, isBuilder = false, isFactory = false,
        metalCost = 50, energyCost = 500, buildTime = 1000, buildSpeed = 0,
        buildDistance = 128, xsize = 4, zsize = 4, weapons = {}, buildOptions = {},
        customParams = {}, modCategories = {}, canMove = false,
    }
    for k, v in pairs(t or {}) do d[k] = v end
    if d.speed > 0 then d.canMove = true end
    UnitDefs[d.id], UnitDefNames[name] = d, d
    nextDefID = nextDefID + 1
    return d
end

-- structures
Def("corwin",   { energyMake = 0, windGenerator = 25, xsize = 6, zsize = 6, metalCost = 40 })
Def("cormex",   { extractsMetal = 0.001, metalCost = 50 })
Def("cormoho",  { extractsMetal = 0.004, metalCost = 600, customParams = { techlevel = "2" } })
Def("corfus",   { energyMake = 850, metalCost = 3500, xsize = 10, zsize = 10 })
Def("corrad",   { radarRadius = 2100, metalCost = 55 })
Def("corjamt",  { jammerRadius = 500, metalCost = 90 })
Def("corrl",    { weapons = AAGUN, metalCost = 80 })
Def("corllt",   { weapons = { { weaponDef = 6, onlyTargets = {} } }, metalCost = 85 })
Def("cornanotc",{ isBuilder = true, buildSpeed = 200, buildDistance = 380, metalCost = 230,
                  energyCost = 3200 })
Def("corsilo",  { canStockpile = true, weapons = { { weaponDef = 4, onlyTargets = {} } },
                  metalCost = 7700, xsize = 8, zsize = 8, customParams = { techlevel = "2" } })
Def("corfmd",   { canStockpile = true, weapons = { { weaponDef = 5, onlyTargets = {} } },
                  metalCost = 1500, customParams = { techlevel = "2" } })
-- mobile
Def("cornecro", { speed = 78, isBuilder = true, canResurrect = true, buildSpeed = 85,
                  metalCost = 130, energyCost = 1400 })
Def("corak",    { speed = 81, weapons = GUN, metalCost = 43 })
Def("corgator", { speed = 85, weapons = GUN, metalCost = 120 })
Def("corraid",  { speed = 72, weapons = GUN, metalCost = 235 })
Def("corfav",   { speed = 153, weapons = GUN, metalCost = 26, modCategories = { scout = true } })
Def("corcv",    { speed = 51, isBuilder = true, buildSpeed = 95, metalCost = 145 })
Def("corbw",    { speed = 280.5, canFly = true, weapons = GUN, metalCost = 58, energyCost = 1300 })
Def("corveng",  { speed = 297.6, canFly = true, weapons = AAGUN, metalCost = 73, energyCost = 2800 })
Def("corvamp",  { speed = 379, canFly = true, weapons = AAGUN, metalCost = 145, energyCost = 5100,
                  customParams = { techlevel = "2" } })
Def("corape",   { speed = 159, canFly = true, weapons = GUN, metalCost = 370, energyCost = 6800,
                  customParams = { techlevel = "2" } })
Def("corcrwh",  { speed = 114.9, canFly = true, weapons = GUN, metalCost = 5100,
                  energyCost = 72000, customParams = { techlevel = "2" } })
Def("corshad",  { speed = 234, canFly = true, weapons = BOMB, metalCost = 150, energyCost = 4600 })
Def("corhurc",  { speed = 248, canFly = true, weapons = BOMB, metalCost = 310, energyCost = 18500,
                  customParams = { techlevel = "2" } })
Def("corawac",  { speed = 321, canFly = true, radarRadius = 2500, metalCost = 180,
                  energyCost = 8300, customParams = { techlevel = "2" } })
Def("corfink",  { speed = 360, canFly = true, metalCost = 51, energyCost = 1450 })
Def("corca",    { speed = 131, canFly = true, isBuilder = true, buildSpeed = 65,
                  buildDistance = 136, metalCost = 115, energyCost = 2200 })
Def("coraca",   { speed = 181, canFly = true, isBuilder = true, buildSpeed = 100,
                  buildDistance = 136, metalCost = 360, energyCost = 11000,
                  customParams = { techlevel = "2" } })
Def("corck",    { speed = 34.5, isBuilder = true, buildSpeed = 85, buildDistance = 136,
                  metalCost = 120, energyCost = 1750 })
Def("corcom",   { speed = 37.5, isBuilder = true, buildSpeed = 300, buildDistance = 145,
                  weapons = GUN, metalCost = 1500, canCloak = true, cloakCost = 100,
                  customParams = { iscommander = "1" } })
-- factories
Def("corlab",   { isFactory = true, isBuilder = true, buildSpeed = 100, xsize = 12, zsize = 12,
                  metalCost = 470 })
Def("corvp",    { isFactory = true, isBuilder = true, buildSpeed = 100, xsize = 12, zsize = 12,
                  metalCost = 600 })
Def("corap",    { isFactory = true, isBuilder = true, buildSpeed = 100, xsize = 12, zsize = 12,
                  metalCost = 650 })
Def("coraap",   { isFactory = true, isBuilder = true, buildSpeed = 200, xsize = 14, zsize = 14,
                  metalCost = 2900, customParams = { techlevel = "2" } })

local function Opts(name, list)
    local d = UnitDefNames[name]
    for _, n in ipairs(list) do d.buildOptions[#d.buildOptions + 1] = UnitDefNames[n].id end
end
local T1 = { "corwin", "cormex", "corrad", "corjamt", "corrl", "corllt", "corlab", "corvp", "corap" }
Opts("corcom", T1)
Opts("corck",  { "corwin", "cormex", "corrad", "corjamt", "corrl", "corllt", "cornanotc",
                 "corlab", "corvp", "corap" })
Opts("corca",  { "corwin", "cormex", "corrad", "corrl", "corllt", "cornanotc", "corlab", "corvp",
                 "corap", "coraap" })
Opts("coraca", { "cormoho", "corfus", "corsilo", "corfmd", "coraap", "cornanotc" })
Opts("corcv",  { "corwin", "cormex", "corrl", "corllt", "cornanotc" })
Opts("corlab", { "corck", "cornecro", "corak" })
Opts("corvp",  { "corcv", "corgator", "corraid", "corfav" })
Opts("corap",  { "corca", "corfink", "corveng", "corbw", "corshad" })
Opts("coraap", { "coraca", "corape", "corvamp", "corcrwh", "corhurc", "corawac" })

-- Anything else a blueprint names: a small plain structure.
setmetatable(UnitDefNames, { __index = function(t, name)
    if type(name) ~= "string" then return nil end
    return Def(name, {})
end })

-- ── The world ─────────────────────────────────────────────────────────────────

S.MAP = 12288
Game = { mapSizeX = S.MAP, mapSizeZ = S.MAP, maxUnits = 32000, gameSpeed = 30 }
CMD = {
    STOP = 0, MOVE = 10, PATROL = 15, FIGHT = 16, ATTACK = 20, GUARD = 25, REPAIR = 40,
    RECLAIM = 90, RESURRECT = 125, STOCKPILE = 100, INSERT = 1, CLOAK = 37382,
    OPT_ALT = 128, OPT_CTRL = 64, OPT_SHIFT = 32, OPT_INTERNAL = 8,
}

local W = {
    frame = 0, units = {}, nextUnit = 100, features = {}, nextFeature = 1,
    orders = {}, pending = {}, errors = {}, log = {}, widgets = {},
    res = {
        metal  = { cur = 1000, storage = 1000, pull = 0,   income = 0 },
        energy = { cur = 1000, storage = 1000, pull = 0,   income = 30 },
    },
    cap = 2000, start = { [0] = { 2400, 848 }, [1] = { 9648, 11408 } },
    verbose = false,
}
S.W = W

function S.Echo(msg)
    msg = tostring(msg)
    W.log[#W.log + 1] = msg
    if W.verbose then print(msg) end
end

local function Callin(name, ...)
    for _, w in ipairs(W.widgets) do
        local f = w[name]
        if f then
            local ok, err = pcall(f, w, ...)
            if not ok then
                W.errors[#W.errors + 1] = string.format("%s:%s f=%d: %s", w._file, name, W.frame, tostring(err))
            end
        end
    end
end
S.Callin = Callin

function S.Spawn(defName, team, x, z, opts)
    local d = type(defName) == "number" and UnitDefs[defName] or UnitDefNames[defName]
    local id = W.nextUnit
    W.nextUnit = W.nextUnit + 1
    W.units[id] = { id = id, defID = d.id, team = team, ally = team, x = x, z = z,
                    hp = 1000, maxhp = 1000, beingBuilt = false, stock = 0, cmds = {} }
    if not (opts and opts.silent) then
        Callin("UnitCreated", id, d.id, team, opts and opts.builder)
        Callin("UnitFinished", id, d.id, team)
        if opts and opts.factory then Callin("UnitFromFactory", id, d.id, team, opts.factory) end
    end
    return id
end

function S.Kill(id, attacker)
    local u = W.units[id]
    if not u then return end
    W.units[id] = nil
    Callin("UnitDestroyed", id, u.defID, u.team, attacker)
end

function S.AddFeature(x, z, metal, rezName)
    local id = W.nextFeature
    W.nextFeature = W.nextFeature + 1
    W.features[id] = { x = x, z = z, metal = metal, rez = rezName or "" }
    return id
end

local function Count(team)
    local n = 0
    for _, u in pairs(W.units) do if u.team == team then n = n + 1 end end
    return n
end

-- Apply the orders given during the last frame.  Instant, see the header.
function S.Step()
    local orders = W.orders
    W.orders = {}
    for _, o in ipairs(orders) do
        local u = W.units[o.id]
        if u then
            local d = UnitDefs[u.defID]
            local cmd, p = o.cmd, o.params or {}
            if cmd == CMD.INSERT then cmd, p = p[2], {} end
            if cmd < 0 and Count(u.team) < W.cap then
                local def = UnitDefs[-cmd]
                if d.isFactory then
                    S.Spawn(def.id, u.team, u.x + 60, u.z + 60, { builder = u.id, factory = u.id })
                elseif p[1] then
                    S.Spawn(def.id, u.team, p[1], p[3], { builder = u.id })
                end
                table.remove(u.cmds, 1)
            elseif (cmd == CMD.MOVE or cmd == CMD.FIGHT) and d.speed > 0 and p[1] then
                u.x, u.z = p[1], p[3]
            elseif cmd == CMD.RECLAIM and p[1] then
                if p[1] >= Game.maxUnits then W.features[p[1] - Game.maxUnits] = nil
                elseif W.units[p[1]] then S.Kill(p[1], u.id) end
            elseif cmd == CMD.RESURRECT and p[1] then
                local f = W.features[p[1] - Game.maxUnits]
                if f and f.rez ~= "" then
                    W.features[p[1] - Game.maxUnits] = nil
                    S.Spawn(f.rez, u.team, f.x, f.z, { builder = u.id })
                end
            elseif cmd == CMD.REPAIR and p[1] and W.units[p[1]] then
                W.units[p[1]].hp = W.units[p[1]].maxhp
            elseif cmd == CMD.ATTACK and #p == 1 and W.units[p[1]]
                   and W.units[p[1]].team ~= u.team then
                S.Kill(p[1], u.id)
            elseif cmd == CMD.STOCKPILE then
                u.stock = u.stock + 1
            elseif cmd == CMD.CLOAK then
                u.cloaked = p[1] == 1
            end
        end
    end
end

-- ── Spring ────────────────────────────────────────────────────────────────────

local function Pos(id) local u = W.units[id]; if u then return u.x, 0, u.z end end

Spring = setmetatable({
    Echo = S.Echo,
    GetMyTeamID = function() return 0 end,
    GetMyAllyTeamID = function() return 0 end,
    GetGameFrame = function() return W.frame end,
    GetTeamList = function() return { 0, 1 } end,
    GetTeamInfo = function(t) return t, 0, false, true, "cortex", t end,
    GetTeamStartPosition = function(t)
        local s = W.start[t]; if s then return s[1], 0, s[2] end
    end,
    GetTeamUnits = function(team)
        local out = {}
        for id, u in pairs(W.units) do if u.team == team then out[#out + 1] = id end end
        table.sort(out)
        return out
    end,
    GetTeamUnitsByDefs = function(team, defID)
        local out = {}
        for id, u in pairs(W.units) do
            if u.team == team and u.defID == defID then out[#out + 1] = id end
        end
        return out
    end,
    GetTeamUnitCount = function(team) return Count(team) end,
    GetTeamMaxUnits = function() return W.cap end,
    GetAllUnits = function()
        local out = {}
        for id in pairs(W.units) do out[#out + 1] = id end
        table.sort(out)
        return out
    end,
    GetUnitDefID = function(id) local u = W.units[id]; return u and u.defID end,
    GetUnitPosition = Pos,
    GetUnitAllyTeam = function(id) local u = W.units[id]; return u and u.ally end,
    GetUnitTeam = function(id) local u = W.units[id]; return u and u.team end,
    GetUnitHealth = function(id) local u = W.units[id]; if u then return u.hp, u.maxhp end end,
    GetUnitIsBeingBuilt = function(id) local u = W.units[id]; return u and u.beingBuilt or false end,
    GetUnitIsBuilding = function() return nil end,
    GetUnitWorkerTask = function() return nil end,
    GetUnitStockpile = function(id) local u = W.units[id]; return u and u.stock end,
    GetUnitLastAttacker = function() return nil end,
    GetUnitCommands = function(id, n)
        local u = W.units[id]
        if not u then return nil end
        if n == 0 then return #u.cmds end
        return u.cmds
    end,
    GetFactoryCommands = function(id, n) if n == 0 then return 0 end return {} end,
    GetUnitsInCylinder = function(x, z, r, team)
        local out = {}
        for id, u in pairs(W.units) do
            if (team == nil or u.team == team) and (u.x - x) ^ 2 + (u.z - z) ^ 2 <= r * r then
                out[#out + 1] = id
            end
        end
        table.sort(out)
        return out
    end,
    GiveOrderToUnit = function(id, cmd, params, opts)
        W.orders[#W.orders + 1] = { id = id, cmd = cmd, params = params, opts = opts }
        local u = W.units[id]
        if u and cmd ~= 0 then u.cmds = { { id = cmd, params = params } } end
        if u and cmd == 0 then u.cmds = {} end
        return true
    end,
    GetTeamResources = function(team, kind)
        local r = W.res[kind]
        return r.cur, r.storage, r.pull, r.income, r.pull
    end,
    GetGroundHeight = function() return 0 end,
    TestBuildOrder = function(defID, x, y, z)
        if x < 0 or z < 0 or x > S.MAP or z > S.MAP then return 0 end
        return 2
    end,
    Pos2BuildPos = function(defID, x, y, z)
        return math.floor(x / 16 + 0.5) * 16, y, math.floor(z / 16 + 0.5) * 16
    end,
    IsPosInLos = function() return false end,
    GetFeaturesInCylinder = function(x, z, r)
        local out = {}
        for id, f in pairs(W.features) do
            if (f.x - x) ^ 2 + (f.z - z) ^ 2 <= r * r then out[#out + 1] = id end
        end
        table.sort(out)
        return out
    end,
    GetFeaturePosition = function(id) local f = W.features[id]; if f then return f.x, 0, f.z end end,
    GetFeatureResources = function(id) local f = W.features[id]; return f and f.metal end,
    GetFeatureResurrect = function(id) local f = W.features[id]; return f and f.rez or "" end,
    ValidFeatureID = function(id) return W.features[id] ~= nil end,
    RequestPath = function() return nil end,
}, { __index = function(_, k)
    -- Anything not modelled answers nil, like an engine call with nothing to report.
    return function() return nil end
end })

WG = {}

-- VFS.Include maps "LuaUI/Widgets/<path>" to the repo and runs the file fresh each
-- time, as the engine does.
VFS = {
    Include = function(path)
        local rel = path:gsub("^LuaUI/Widgets/", "")
        local chunk = assert(loadfile(S.ROOT .. rel))
        return chunk()
    end,
}

function S.LoadWidget(file)
    local chunk = assert(loadfile(file))
    local env = setmetatable({}, { __index = _G })
    env.widget = { _file = file }
    setfenv(chunk, env)
    chunk()
    local w = env.widget
    W.widgets[#W.widgets + 1] = w
    return w
end

function S.Frame(frame)
    W.frame = frame
    Callin("GameFrame", frame)
    S.Step()
end

function S.Log(pattern)
    local out = {}
    for _, l in ipairs(W.log) do if l:find(pattern) then out[#out + 1] = l end end
    return out
end

return S
