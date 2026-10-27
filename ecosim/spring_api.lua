-- ecosim/spring_api.lua -- the widget-side engine API (Spring.*, CMD, Game, UnitDefs, VFS, WG ...) over ecosim/world.lua.
-- Anything the sim does not model answers nil and is logged once as "[SIM] missing API <name>", so a gap shows in the log.

local A = {}

function A.Install(W, P, defsById, defsByName, weaponDefs, root, simCfg)
    local floor = math.floor
    local units = W.units
    local myTeam = 0
    W.myTeam = myTeam
    local function U(id) return W.units[id] end

    local function CmdView(c)
        return { id = c.id, params = c.params, options = { shift = c.opts.shift, alt = c.opts.alt, ctrl = c.opts.ctrl,
                 meta = c.opts.meta, internal = c.opts.internal, right = c.opts.right, coded = c.opts.coded }, tag = c.tag }
    end

    local S = {}
    S.Echo = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        W.Log(table.concat(parts, ", "))
    end
    S.Log = function(section, level, ...) S.Echo(...) end
    S.GetMyTeamID = function() return myTeam end
    S.GetLocalTeamID = S.GetMyTeamID
    S.GetMyAllyTeamID = function() return myTeam end
    S.GetLocalAllyTeamID = S.GetMyAllyTeamID
    S.GetMyPlayerID = function() return 0 end
    S.GetGameFrame = function() return W.frame end
    S.GetGameSeconds = function() return W.frame / 30 end
    S.GetSpectatingState = function() return false, false end
    S.IsReplay = function() return false end
    S.IsCheatingEnabled = function() return false end
    S.GetTeamList = function(ally) if ally then return { ally } end return { 0, 1 } end
    S.GetAllyTeamList = function() return { 0, 1 } end
    S.GetTeamInfo = function(t) return t, 0, false, false, "cortex", t, 0, {} end
    S.GetTeamStartPosition = function(t) local s = P.START[t + 1]; if s then return s[1], P.GROUND_Y, s[2] end end
    S.GetTeamUnits = function(team)
        local l = W.TeamList(team)
        local out = {}
        for i = 1, #l do out[i] = l[i] end
        return out
    end
    S.DestroyUnit = function(id, attackerID) local u = W.units[id]; if u then W.Kill(u, "stress", attackerID) end end     -- stress_stances.py: kill a unit mid-game
    S.GetTeamUnitsByDefs = function(team, defs)
        local want = {}
        if type(defs) == "table" then for _, d in ipairs(defs) do want[d] = true end else want[defs] = true end
        local out = {}
        for _, id in ipairs(W.TeamList(team)) do
            local u = units[id]
            if u and want[u.defID] then out[#out + 1] = id end
        end
        return out
    end
    S.GetTeamUnitsCounts = function(team)
        local out = {}
        for _, id in ipairs(W.TeamList(team)) do local u = units[id]; if u then out[u.defID] = (out[u.defID] or 0) + 1 end end
        return out
    end
    S.GetTeamUnitDefCount = function(team, defID)
        local n = 0
        for _, id in ipairs(W.TeamList(team)) do local u = units[id]; if u and u.defID == defID then n = n + 1 end end
        return n
    end
    S.GetTeamUnitCount = function(team) return W.teams[team] and W.teams[team].count or 0 end
    S.GetTeamMaxUnits = function(team) return P.MAX_UNITS, W.teams[team] and W.teams[team].count or 0 end
    S.GetAllUnits = function()
        local out = {}
        for t = 0, 1 do for _, id in ipairs(W.TeamList(t)) do out[#out + 1] = id end end
        return out
    end
    S.GetVisibleUnits = function() return S.GetTeamUnits(myTeam) end
    S.GetTeamResources = function(team, kind)
        local T = W.teams[team]
        if not T then return nil end
        if kind == "metal" then
            return T.metal, T.mStor, T.mPull, T.mInc, T.mExp, 1, 0, 0
        else
            return T.energy, T.eStor, T.ePull, T.eInc, T.eExp, 1, 0, 0
        end
    end
    S.GetTeamRulesParam = function() return nil end
    S.GetUnitRulesParam = function() return nil end
    S.GetGameRulesParam = function() return nil end
    S.GetModOptions = function() return { maxunits = tostring(P.MAX_UNITS) } end
    S.GetConfigInt = function(_, d) return d end
    S.GetConfigFloat = function(_, d) return d end
    S.GetConfigString = function(_, d) return d end
    S.SetConfigInt = function() end
    S.GetTimer = function() return os.clock() end
    S.DiffTimers = function(a, b) return (a - b) end

    S.ValidUnitID = function(id) return units[id] ~= nil end
    S.GetUnitIsDead = function(id) local u = units[id]; if not u then return nil end return false end
    S.GetUnitDefID = function(id) local u = units[id]; return u and u.defID end
    S.GetUnitTeam = function(id) local u = units[id]; return u and u.team end
    S.GetUnitAllyTeam = function(id) local u = units[id]; return u and u.ally end
    S.GetUnitPosition = function(id) local u = units[id]; if u then return u.x, P.GROUND_Y, u.z end end
    S.GetUnitBasePosition = S.GetUnitPosition
    S.GetUnitVelocity = function(id)
        local u = units[id]
        if not u then return nil end
        if u.moving then local s = (u.d.speed or 0) / 30; return s, 0, 0, s end
        return 0, 0, 0, 0
    end
    S.GetUnitDirection = function(id) if units[id] then return 0, 0, 1 end end
    S.GetUnitHeading = function(id) if units[id] then return 0 end end
    S.GetUnitRadius = function(id) local u = units[id]; return u and (u.d.radius or 16) end
    S.GetUnitHealth = function(id)
        local u = units[id]
        if not u then return nil end
        local hp = u.d.health or 1000
        return hp * max0(u.progress), hp, 0, 0, u.progress
    end
    S.GetUnitIsBeingBuilt = function(id)
        local u = units[id]
        if not u then return nil end
        return not u.built, u.progress
    end
    S.GetUnitIsBuilding = function(id)
        local u = units[id]
        if not u or not u.built then return nil end
        if u.fq then return u.fbuild end
        if u.work and u.workKind == "build" and units[u.work] then return u.work end
        return nil
    end
    S.GetUnitWorkerTask = function(id)
        local u = units[id]
        if not u or not u.work then return nil end
        local t = units[u.work]
        if not t then return nil end
        if u.fq then return -t.defID, t.id end
        if u.workKind == "reclaim" then return 90, t.id end
        local c = u.cmds[1]
        return c and c.id or 40, t.id
    end
    S.GetUnitCurrentBuildPower = function(id) local u = units[id]; return u and (u.used or 0) end
    S.GetUnitCommands = function(id, n)
        local u = units[id]
        if not u then return nil end
        local q = u.cmds
        if n == 0 then return #q end
        local out = {}
        local lim = (n == nil or n < 0) and #q or math.min(n, #q)
        for i = 1, lim do out[i] = CmdView(q[i]) end
        return out
    end
    S.GetUnitCommandCount = function(id) local u = units[id]; return u and #u.cmds end
    S.GetUnitCurrentCommand = function(id, i)
        local u = units[id]
        if not u then return nil end
        local c = u.cmds[i or 1]
        if c then return c.id, c.opts.coded, c.tag, unpack(c.params) end
    end
    S.GetFactoryCommands = function(id, n)
        local u = units[id]
        if not u then return nil end
        local q = u.fq or {}
        if n == 0 then return #q end
        local out = {}
        local lim = (n == nil or n < 0) and #q or math.min(n, #q)
        for i = 1, lim do out[i] = CmdView(q[i]) end
        return out
    end
    S.GetFactoryCounts = function(id)
        local u = units[id]
        if not u or not u.fq then return nil end
        local out = {}
        for _, c in ipairs(u.fq) do out[-c.id] = (out[-c.id] or 0) + 1 end
        return out
    end
    S.GetUnitStates = function(id)
        local u = units[id]
        if not u then return nil end
        return { active = u.active, firestate = 2, movestate = 1, ["repeat"] = false, cloak = false, trajectory = false }
    end
    S.GetUnitStockpile = function(id)
        local u = units[id]
        if u then return u.stockHave or 0, u.stockQ or 0, u.stockProg or 0 end
    end
    S.GetUnitLastAttacker = function() return nil end
    S.GetUnitLosState = function(id) if units[id] then return { los = true, radar = true, typed = true } end end
    S.GetUnitNearestEnemy = function() return nil end
    S.GetUnitSeparation = function(a, b)
        local u, v = units[a], units[b]
        if not (u and v) then return nil end
        return math.sqrt((u.x - v.x) ^ 2 + (u.z - v.z) ^ 2)
    end
    S.GetUnitsInCylinder = function(x, z, r, team)
        if team and team < 0 then team = nil end
        return W.UnitsInCylinder(x, z, r, team)
    end
    S.GetUnitsInSphere = function(x, y, z, r, team) return W.UnitsInCylinder(x, z, r, team) end
    S.GetUnitsInRectangle = function(x0, z0, x1, z1, team)
        local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        local r = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2) / 2
        local out = {}
        for _, id in ipairs(W.UnitsInCylinder(cx, cz, r, team)) do
            local u = units[id]
            if u.x >= x0 and u.x <= x1 and u.z >= z0 and u.z <= z1 then out[#out + 1] = id end
        end
        return out
    end
    S.GetGroundHeight = function() return P.GROUND_Y end
    S.GetGroundNormal = function() return 0, 1, 0, 0 end
    S.GetMetalAmount = function() return P.METAL_PER_SQUARE end
    S.TestBuildOrder = function(defID, x, y, z, facing)
        local r = W.TestBuild(defID, x, z, facing or 0)
        if r ~= 0 and W.teams[myTeam].count >= P.MAX_UNITS then return 0 end
        return r
    end
    S.Pos2BuildPos = function(defID, x, y, z, facing)
        local bx, bz = W.Pos2BuildPos(defID, x, z, facing or 0)
        return bx, P.GROUND_Y, bz
    end
    S.ClosestBuildPos = function(team, defID, x, y, z, r, minDist, facing) return x, y, z end
    S.IsPosInLos = function(x, y, z)
        for _, id in ipairs(W.UnitsInCylinder(x, z, 900, myTeam)) do return true end
        return false
    end
    S.IsPosInRadar = S.IsPosInLos
    S.IsPosInAirLos = S.IsPosInLos
    S.GetPositionLosState = function(x, y, z) local v = S.IsPosInLos(x, y, z); return v, v, v, v end
    S.GetFeaturesInCylinder = function() return {} end
    S.GetFeaturesInRectangle = function() return {} end
    S.GetAllFeatures = function() return {} end
    S.ValidFeatureID = function() return false end
    S.GetFeaturePosition = function() return nil end
    S.GetFeatureResources = function() return nil end
    S.GetFeatureResurrect = function() return nil end
    S.GetProjectilesInRectangle = function() return {} end
    S.GetProjectilePosition = function() return nil end
    S.GetProjectileVelocity = function() return nil end
    S.MarkerAddPoint = function() end
    S.MarkerAddLine = function() end
    S.MarkerErasePosition = function() end
    S.SendCommands = function() end
    S.RequestPath = function() return nil end
    S.GetSelectedUnits = function() return {} end
    S.SelectUnitArray = function() end
    S.GiveOrderToUnit = function(id, cmd, params, opts) return W.GiveOrder(id, cmd, params, opts) end
    S.GiveOrderToUnitArray = function(ids, cmd, params, opts)
        for _, id in ipairs(ids or {}) do W.GiveOrder(id, cmd, params, opts) end
        return true
    end
    S.GiveOrderToUnitMap = function(map, cmd, params, opts)
        for id in pairs(map or {}) do W.GiveOrder(id, cmd, params, opts) end
        return true
    end
    S.GiveOrderArrayToUnitArray = function(ids, orders)
        for _, id in ipairs(ids or {}) do for _, o in ipairs(orders or {}) do W.GiveOrder(id, o[1], o[2], o[3]) end end
        return true
    end

    function max0(v) return v > 0 and v or 0 end

    -- unknown calls: nil, logged once
    setmetatable(S, { __index = function(t, k)
        if not W.missing[k] then
            W.missing[k] = true
            W.Log("[SIM] missing API Spring." .. tostring(k))
        end
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
    Spring = S

    CMD = {}
    for k, v in pairs(W.CMD) do CMD[k] = v end
    CMD.WAITCODE_TIME = 1; CMD.WAITCODE_DEATH = 2
    CMDTYPE = { ICON = 0, ICON_MODE = 5, ICON_MAP = 10, ICON_AREA = 11, ICON_UNIT = 12, ICON_UNIT_OR_MAP = 13 }
    GameCMD = setmetatable({}, { __index = function(_, k) return 30000 + (#tostring(k)) end })

    Game = { mapSizeX = P.MAP_X, mapSizeZ = P.MAP_Z, maxUnits = P.MAX_UNITS, gameSpeed = 30, windMin = P.WIND,
             windMax = P.WIND, mapName = "Full Metal Plate 1.7", squareSize = 8, CustomCommands = {} }
    UnitDefs = defsById
    UnitDefNames = defsByName
    WeaponDefs = weaponDefs
    WeaponDefNames = {}
    for _, wd in pairs(weaponDefs) do if wd.name then WeaponDefNames[wd.name] = wd end end
    FeatureDefs = {}
    WG = {}
    Script = { LuaUI = setmetatable({}, { __index = function() return function() end end }) }

    local includeHook = simCfg.includeHook
    VFS = {
        Include = function(path, env)
            local rel = path:gsub("^LuaUI/Widgets/", ""):gsub("^luaui/widgets/", "")
            local chunk, err = loadfile(root .. rel)
            if not chunk then error("VFS.Include: " .. tostring(err), 2) end
            if env then setfenv(chunk, env) end
            local r = chunk()
            if includeHook then r = includeHook(rel, r) end
            return r
        end,
        FileExists = function(path)
            local rel = path:gsub("^LuaUI/Widgets/", "")
            local f = io.open(root .. rel, "r")
            if f then f:close(); return true end
            return false
        end,
        LoadFile = function(path)
            local rel = path:gsub("^LuaUI/Widgets/", "")
            local f = io.open(root .. rel, "r")
            if not f then return nil end
            local s = f:read("*a"); f:close(); return s
        end,
        DirList = function() return {} end,
        RAW_FIRST = "r", ZIP_FIRST = "z", RAW = "r", ZIP = "z",
    }
    -- scan counters (C5): how often the bot walks the unit lists, and the total entries returned -- the number the shared snapshot brings down
    local scans = { GetTeamUnits = { 0, 0 }, GetAllUnits = { 0, 0 }, GetUnitsInCylinder = { 0, 0 } }
    S.__scans = scans
    for name, c in pairs(scans) do
        local f = S[name]
        if f then
            S[name] = function(...)
                local r = f(...)
                c[1] = c[1] + 1
                c[2] = c[2] + (type(r) == "table" and #r or 0)
                return r
            end
        end
    end
    return S
end

return A
