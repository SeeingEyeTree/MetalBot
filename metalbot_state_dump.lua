-- metalbot_state_dump.lua
-- Ground truth for the economy simulator (ecosim/, eco_sim.py). Installed by the harness next to the stats tracker,
-- one copy per team; each copy logs only its own team.
--
--   [UDEF] {json}                       once, team 0 only: one engine UnitDef (fields the bots read) per line
--   [UWDEF] {json}                      once, team 0 only: one WeaponDef the dumped units carry
--   [UMAP] {json}                       once: map size, wind min/max, start position, ground height, unit cap
--   [SNAP] res frame=F team=T m=.. ms=.. mi=.. mp=.. e=.. es=.. ei=.. ep=.. units=N
--   [SNAP] u frame=F team=T name,x,z,progress,cmd;name,x,z,progress,cmd;...   (UNITS_PER_LINE units per line)
--        progress 1 = finished; cmd = id of the first queued command (0 = idle; negative = build defID)
-- bot_testing.py parses these into result["snapshots"] / result["unit_defs"].

local SNAP_EVERY     = 1800    -- game frames between snapshots (1 game-minute)
local UNITS_PER_LINE = 60

function widget:GetInfo()
    return {
        name    = "State Dump",
        desc    = "Logs unit defs and per-minute own-unit snapshots for the economy simulator",
        author  = "MetalBot",
        layer   = 1001,
        enabled = true,
    }
end

local myTeam

-- minimal JSON encoder: tables with only 1..n keys become arrays
local function enc(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.6g", v)
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "table" then
        if depth > 4 then return "null" end
        local n = #v
        local isArr = true
        for k in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then isArr = false; break end
        end
        local parts = {}
        if isArr then
            for i = 1, n do parts[i] = enc(v[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, x in pairs(v) do
            local tx = type(x)
            if tx ~= "function" and tx ~= "userdata" then
                parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(x, depth + 1)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local DEF_FIELDS = {
    "name", "id", "humanName", "translatedHumanName", "metalCost", "energyCost", "buildTime", "buildSpeed",
    "buildDistance", "reclaimSpeed", "repairSpeed", "resurrectSpeed", "speed", "canFly", "canMove", "isFactory",
    "isBuilder", "isBuilding", "isImmobile", "isStaticBuilder", "isMobileBuilder", "canResurrect", "canAssist",
    "canReclaim", "canRepair", "canCloak", "canStockpile", "cloakCost", "cloakCostMoving", "xsize", "zsize",
    "ysize", "radius", "height", "extractsMetal", "extractRange", "energyMake", "metalMake", "energyUpkeep", "metalUpkeep",
    "windGenerator", "tidalGenerator", "energyStorage", "metalStorage", "health", "radarRadius", "radarDistance",
    "jammerRadius", "sightDistance", "losRadius", "transportCapacity", "maxWeaponRange", "modCategories",
    "category", "targetable", "buildOptions", "customParams", "makesMetal", "isExtractor", "maxThisUnit",
}

local function DumpDefs()
    local wanted = {}
    for id, d in pairs(UnitDefs) do
        local name = d.name or ""
        if not name:find("_scav") and (name:sub(1, 3) == "cor" or name:sub(1, 3) == "arm" or name:sub(1, 3) == "leg") then
            local o = {}
            for _, f in ipairs(DEF_FIELDS) do
                local ok, v = pcall(function() return d[f] end)
                if ok and v ~= nil and type(v) ~= "function" and type(v) ~= "userdata" then o[f] = v end
            end
            o.id = id
            local ws = {}
            for i, w in ipairs(d.weapons or {}) do
                ws[i] = { weaponDef = w.weaponDef, onlyTargets = w.onlyTargets, badTargets = w.badTargets }
                if w.weaponDef then wanted[w.weaponDef] = true end
            end
            o.weapons = ws
            Spring.Echo("[UDEF] " .. enc(o))
        end
    end
    for wid in pairs(wanted) do
        local wd = WeaponDefs and WeaponDefs[wid]
        if wd then
            local o = { id = wid }
            for _, f in ipairs({ "name", "range", "canAttackGround", "type", "reload", "salvoSize", "projectiles",
                                 "interceptor", "targetable", "stockpile", "coverageRange", "customParams" }) do
                local ok, v = pcall(function() return wd[f] end)
                if ok and v ~= nil and type(v) ~= "function" and type(v) ~= "userdata" then o[f] = v end
            end
            local ok, dm = pcall(function() return wd.damages and wd.damages[0] end)
            if ok and dm then o.damage0 = dm end
            Spring.Echo("[UWDEF] " .. enc(o))
        end
    end
end

local function DumpMap()
    local sx, sy, sz = Spring.GetTeamStartPosition(myTeam)
    local o = {
        team = myTeam, mapSizeX = Game.mapSizeX, mapSizeZ = Game.mapSizeZ, windMin = Game.windMin,
        windMax = Game.windMax, tidal = Game.tidal, startX = sx, startZ = sz,
        groundHeight = sx and Spring.GetGroundHeight(sx, sz) or nil, maxUnits = Spring.GetTeamMaxUnits(myTeam),
        mapName = Game.mapName, gameVersion = Game.gameVersion,
    }
    if sx then o.metalAtStart = Spring.GetMetalAmount(math.floor(sx / 16), math.floor(sz / 16)) end
    Spring.Echo("[UMAP] " .. enc(o))
end

local function Snapshot(frame)
    local m, ms, mp, mi = Spring.GetTeamResources(myTeam, "metal")
    local e, es, ep, ei = Spring.GetTeamResources(myTeam, "energy")
    local units = Spring.GetTeamUnits(myTeam) or {}
    Spring.Echo(string.format("[SNAP] res frame=%d team=%d m=%.0f ms=%.0f mi=%.1f mp=%.1f e=%.0f es=%.0f ei=%.1f ep=%.1f units=%d",
        frame, myTeam, m or 0, ms or 0, mi or 0, mp or 0, e or 0, es or 0, ei or 0, ep or 0, #units))
    local parts = {}
    local function flush()
        if #parts > 0 then
            Spring.Echo(string.format("[SNAP] u frame=%d team=%d %s", frame, myTeam, table.concat(parts, ";")))
            parts = {}
        end
    end
    for i = 1, #units do
        local uid = units[i]
        local defID = Spring.GetUnitDefID(uid)
        local d = defID and UnitDefs[defID]
        if d then
            local x, _, z = Spring.GetUnitPosition(uid)
            local bb, prog = Spring.GetUnitIsBeingBuilt(uid)
            local cmds = Spring.GetUnitCommands(uid, 1)
            local cmd = (cmds and cmds[1] and cmds[1].id) or 0
            if d.isFactory then
                local fc = Spring.GetFactoryCommands(uid, 1)
                if fc and fc[1] then cmd = fc[1].id end
            end
            parts[#parts + 1] = string.format("%s,%.0f,%.0f,%.2f,%d", d.name, x or 0, z or 0, bb and (prog or 0) or 1, cmd)
            if #parts >= UNITS_PER_LINE then flush() end
        end
    end
    flush()
end

function widget:Initialize()
    myTeam = Spring.GetMyTeamID()
end

function widget:GameFrame(frame)
    if frame == 5 then
        DumpMap()
        if myTeam == 0 then DumpDefs() end
    end
    if frame > 0 and frame % SNAP_EVERY == 0 then Snapshot(frame) end
end
