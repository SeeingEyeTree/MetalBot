-- ecosim/runner.lua -- run a bot folder's real widgets against the simulated engine.  Driven by eco_sim.py:
--   result_json = dofile("ecosim/runner.lua")(args)
-- args: root (repo path with trailing slash), bot (folder, repo-relative), widgets (file names), vacuum (bool),
--       end_frame, seed, phys {KEY=value}, set {module={KEY=value}}, presets {module={add={..}, remove={..}}},
--       patch (Lua file run after the widgets load), snap_every (frames between unit-position snapshots)

return function(args)
    local root = args.root
    local P = dofile(root .. "ecosim/physics.lua")
    for k, v in pairs(args.phys or {}) do
        local sub = type(k) == "string" and k:match("^SINK%.(.+)$")      -- --phys SINK.hold=10 sets one field
        if sub then P.SINK[sub] = v else P[k] = v end
    end
    if args.sink then P.SINK.on = true end
    P.SEED = args.seed or 1
    math.randomseed(args.seed or 1)
    if os.getenv and os.getenv("ECOSIM_ORDER_DUMP") then
        -- order dumps are diffed between two runs: make `pairs` visit keys in a fixed order (LuaJIT randomises string-hash
        -- order per process, which otherwise changes tie-breaks between runs).  Slower; only for refactor checks.
        local rawpairs, rank = pairs, { number = 1, string = 2, boolean = 3 }
        local function less(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return (rank[ta] or 9) < (rank[tb] or 9) end
            if ta == "number" or ta == "string" then return a < b end
            return false
        end
        pairs = function(t)
            local mt = getmetatable(t)
            if mt and mt.__pairs then return rawpairs(t) end
            local keys, n, sortable = {}, 0, true
            for k in rawpairs(t) do
                n = n + 1; keys[n] = k
                if type(k) ~= "number" and type(k) ~= "string" then sortable = false end
            end
            if not sortable then return rawpairs(t) end
            table.sort(keys, less)
            local i = 0
            return function()
                i = i + 1
                local k = keys[i]
                if k == nil then return nil end
                return k, t[k]
            end, t, nil
        end
    end

    local W = dofile(root .. "ecosim/world.lua")
    local D = dofile(root .. "ecosim/unitdefs.lua")
    local defsById, defsByName = {}, {}
    for _, d in pairs(D.units) do defsById[d.id] = d; defsByName[d.name] = d end
    W.Init(P, defsById)
    W.defsByName = defsByName
    if args.trace then W.trace = {}; for _, id in ipairs(args.trace) do W.trace[id] = true end end
    local CMD_FIGHT = W.CMD.FIGHT

    -- ── config overrides: wrap every bot_config instance ────────────────────
    local setOv = args.set or {}
    local presetOv = args.presets or {}
    SIM_MACRO_OVERRIDES = setOv.macro        -- macro_runtime.Install merges these over the bot's own options (--set macro.KEY=value)
    local applied = {}
    local function Wrap(BC)
        if type(BC) ~= "table" or BC._simWrapped then return BC end
        BC._simWrapped = true
        local origApply, origPreset = BC.Apply, BC.Preset
        BC.Preset = function(module, ...)
            local po = presetOv[module]
            if not po then return origPreset(module, ...) end
            local list = {}
            local drop = {}
            for _, n in ipairs(po.remove or {}) do drop[n] = true end
            for i = 1, select("#", ...) do
                local a = select(i, ...)
                if not (type(a) == "string" and drop[a]) then list[#list + 1] = a end
            end
            -- added groups go before the bot's own table (last arg) so the bot's closures stay
            local last = list[#list]
            if type(last) == "table" then list[#list] = nil end
            for _, n in ipairs(po.add or {}) do list[#list + 1] = n end
            if type(last) == "table" then list[#list + 1] = last end
            Spring.Echo(string.format("[SIM] preset %s: +%s -%s", module, table.concat(po.add or {}, ","),
                table.concat(po.remove or {}, ",")))
            return origPreset(module, unpack(list))
        end
        BC.Apply = function(module, defaults, overrides, label, nilOptions)
            local ov = setOv[module]
            if ov then
                local m = {}
                for k, v in pairs(overrides or {}) do m[k] = v end
                for k, v in pairs(ov) do m[k] = v end
                overrides = m
                applied[module] = true
                local parts = {}
                for k, v in pairs(ov) do parts[#parts + 1] = k .. "=" .. tostring(v) end
                table.sort(parts)
                Spring.Echo(string.format("[SIM] override %s: %s", module, table.concat(parts, " ")))
            end
            return origApply(module, defaults, overrides, label, nilOptions)
        end
        return BC
    end
    local modules = {}       -- rel path -> module tables (for overrides never passed through BC.Apply)
    local function IncludeHook(rel, r)
        if rel:find("bar_framework/bot_config%.lua$") then return Wrap(r) end
        local name = rel:match("bar_framework/([%w_]+)%.lua$")
        if name and type(r) == "table" and type(r.CFG) == "table" then
            modules[name] = modules[name] or {}
            table.insert(modules[name], r)
        end
        return r
    end

    local API = dofile(root .. "ecosim/spring_api.lua")
    API.Install(W, P, defsById, defsByName, D.weapons or {}, root, { includeHook = IncludeHook })

    -- ── widgets ─────────────────────────────────────────────────────────────
    local widgets = {}
    local errors = {}
    local prof = { callin = 0, step = 0, orders = 0 }
    widgetHandler = {
        RemoveWidget = function(self, w) end, RemoveCallIn = function() end, UpdateCallIn = function() end,
        RegisterGlobal = function() end, DeregisterGlobal = function() end, IsWidgetKnown = function() return false end,
    }
    local function ReadFile(p)
        local f = assert(io.open(p, "r"))
        local s = f:read("*a")
        f:close()
        return s
    end
    local snippet = args.vacuum and ReadFile(root .. "runs_stance/vac_snippet.lua") or nil
    for _, name in ipairs(args.widgets) do
        local path = root .. args.bot .. "/" .. name
        local src = ReadFile(path)
        if snippet and name == "lab_controller.lua" then src = src .. "\n" .. snippet end
        local chunk, err = loadstring(src, "@" .. args.bot .. "/" .. name)
        if not chunk then error("load " .. name .. ": " .. tostring(err)) end
        local w = { _name = name }
        local env = setmetatable({ widget = w, widgetHandler = widgetHandler }, { __index = _G })
        setfenv(chunk, env)
        local ok, e = pcall(chunk)
        if not ok then
            errors[#errors + 1] = { frame = 0, widget = name, err = tostring(e) }
            W.Log("[SIM-ERR] " .. name .. " load: " .. tostring(e))
        else
            widgets[#widgets + 1] = w
        end
    end

    local tb = debug.traceback
    local function CallW(w, name, ...)
        local f = w[name]
        if not f or w._removed then return end
        local ok, e = xpcall(function(...) return f(w, ...) end, tb, ...)
        if not ok then
            errors[#errors + 1] = { frame = W.frame, widget = w._name, callin = name, err = tostring(e) }
            W.Log("[SIM-ERR] " .. w._name .. " " .. name .. ": " .. tostring(e))
            w._removed = true          -- BAR removes a widget whose callin errors
            W.Log("[SIM-ERR] widget removed: " .. w._name)
        end
    end

    -- stock widget emulation: unit_immobile_builder (nano turrets: FIGHT when created and when idle)
    local function NanoFight(id, defID, team)
        if not P.NANO_FIGHT or team ~= W.myTeam then return end
        local d = defsById[defID]
        if not (d and d.isBuilder and not d.canMove and not d.isFactory) then return end
        local u = W.units[id]
        if not u then return end
        local x = u.x > P.MAP_X / 2 and u.x - 50 or u.x + 50
        local z = u.z > P.MAP_Z / 2 and u.z - 50 or u.z + 50
        W.GiveOrderAny(id, CMD_FIGHT, { x, P.GROUND_Y, z }, { "meta" })
    end

    W.callin = function(name, ...)
        local t0 = os.clock()
        if name == "UnitCreated" or name == "UnitIdle" then
            local id, defID, team = ...
            NanoFight(id, defID, team)
        end
        local team = select(3, ...)
        for i = 1, #widgets do CallW(widgets[i], name, ...) end
        prof.callin = prof.callin + os.clock() - t0
    end

    for i = 1, #widgets do CallW(widgets[i], "Initialize") end
    if args.patch then
        local ok, e = pcall(dofile, args.patch)
        if not ok then errors[#errors + 1] = { frame = 0, widget = "patch", err = tostring(e) } end
    end
    for i = 1, #widgets do CallW(widgets[i], "GameStart") end

    -- ── sampling ────────────────────────────────────────────────────────────
    local timeline, snaps = {}, {}
    local function CountUnits(team)
        local fin, wip = {}, {}
        for _, id in ipairs(W.TeamList(team)) do
            local u = W.units[id]
            if u then
                local tgt = u.built and fin or wip
                tgt[u.cat] = (tgt[u.cat] or 0) + 1
            end
        end
        return fin, wip
    end
    local function CopyLedger(l)
        local o = {}
        for cls, t in pairs(l) do o[cls] = {}; for k, v in pairs(t) do o[cls][k] = math.floor(v + 0.5) end end
        return o
    end
    local function Sample(frame)
        local T = W.teams[W.myTeam]
        local fin, wip = CountUnits(W.myTeam)
        local bp = 0
        for _, id in ipairs(W.TeamList(W.myTeam)) do
            local u = W.units[id]
            if u and u.built and u.isBuilder then bp = bp + (u.d.buildSpeed or 0) end
        end
        timeline[#timeline + 1] = {
            frame = frame, m = T.metal, ms = T.mStor, mi = T.mInc, mx = T.mExp, mp = T.mPull,
            e = T.energy, es = T.eStor, ei = T.eInc, ex = T.eExp, ep = T.ePull,
            mprod = T.mProduced, eprod = T.eProduced, mused = T.mUsed, mwaste = T.mWaste, ewaste = T.eWaste,
            mrecl = T.mReclaimed, units = T.count, fin = fin, wip = wip, bp = bp, mexfrac = T.mexFrac,
            ledger = CopyLedger(T.ledger), spent = CopyLedger({ x = T.spentBy }).x,
            stallM = T.stallM, stallE = T.stallE, blocked = T.blockedBuilds or 0,
            sink_blocks = T.sink and #T.sink.blocks or 0, dragon_m = T.sink and T.sink.unitM_spent or 0,
            dragons = T.sink and T.sink.unitsDone or 0, sink_setup_m = T.sink and T.sink.setupM_spent or 0,
        }
    end
    local function Snap(frame)
        local list = {}
        for _, id in ipairs(W.TeamList(W.myTeam)) do
            local u = W.units[id]
            if u then list[#list + 1] = { u.d.name, math.floor(u.x), math.floor(u.z), math.floor(u.progress * 100) / 100 } end
        end
        snaps[#snaps + 1] = { frame = frame, units = list }
    end

    -- ── main loop ───────────────────────────────────────────────────────────
    local END = args.end_frame or 36000
    local STEP = P.STEP
    local snapEvery = args.snap_every or 1800
    local wall0 = os.clock()
    local minuteWall = {}
    W.frame = 0
    for frame = 1, END do
        W.frame = frame
        if frame == 1 then
            W.Spawn("corcom", 0, P.START[1][1], P.START[1][2])
            W.Spawn("corcom", 1, P.START[2][1], P.START[2][2])
        end
        local t0 = os.clock()
        W.ApplyOrders(frame)
        prof.orders = prof.orders + os.clock() - t0
        if frame % STEP == 0 then
            local t1 = os.clock()
            W.Step(STEP)
            prof.step = prof.step + os.clock() - t1
        end
        W.callin("GameFrame", frame)
        if frame % P.SAMPLE_EVERY == 0 then Sample(frame) end
        if frame % snapEvery == 0 then Snap(frame) end
        if frame % 1800 == 0 then minuteWall[#minuteWall + 1] = os.clock() - wall0 end
        if #errors > 20 then break end
    end

    -- overrides for modules that never went through BC.Apply: report them (they were not applied)
    local notApplied = {}
    for m in pairs(setOv) do if not applied[m] then notApplied[#notApplied + 1] = m end end

    local missing = {}
    for k in pairs(W.missing) do missing[#missing + 1] = k end
    table.sort(missing)
    local log = {}
    for i, l in ipairs(W.log) do log[i] = { l[1], l[2] } end

    local result = {
        args = { bot = args.bot, seed = args.seed, end_frame = END, vacuum = args.vacuum, set = setOv, presets = presetOv,
                 phys = args.phys or {} },
        timeline = timeline, snaps = snaps, events = W.events, log = log, errors = errors, missing = missing,
        overrides_not_applied = notApplied, blocked_by = W.teams[W.myTeam].blockedBy or {},
        prof = { wall = os.clock() - wall0, callin = prof.callin, step = prof.step, orders = prof.orders,
                 minute_wall = minuteWall, orders_given = W.ordersGiven or 0, scans = Spring and Spring.__scans },
    }
    return result
end
