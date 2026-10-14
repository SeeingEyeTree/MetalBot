-- ecosim/world.lua -- the simulated engine: units, command queues, construction, resources.
--
-- Fidelity targets (what the user asked for): where buildings stand (footprints, occupancy), builder reach and travel,
-- build power and the resource flow with BAR's builder-priority stall rule.  No combat, no pathing (flat map, straight
-- lines), no features/wrecks.  Constants: ecosim/physics.lua.
--
-- Driven by ecosim/runner.lua: W.Init(P, defs), then per frame W.ApplyOrders(frame) and every P.STEP frames W.Step().
-- Engine callins go out through W.callin(name, ...), set by the runner.

local W = {}
local P
local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs

-- engine command ids
local CMD = {
    STOP = 0, INSERT = 1, REMOVE = 2, WAIT = 5, TIMEWAIT = 6, MOVE = 10, PATROL = 15, FIGHT = 16, ATTACK = 20,
    AREA_ATTACK = 21, GUARD = 25, REPAIR = 40, FIRE_STATE = 45, MOVE_STATE = 50, SETBASE = 55, SELFD = 65,
    LOAD_UNITS = 75, UNLOAD_UNITS = 80, ONOFF = 85, RECLAIM = 90, CLOAK = 95, STOCKPILE = 100, MANUALFIRE = 105,
    REPEAT = 115, TRAJECTORY = 120, RESURRECT = 125, CAPTURE = 130, AUTOREPAIRLEVEL = 135, IDLEMODE = 145,
    OPT_ALT = 128, OPT_CTRL = 64, OPT_SHIFT = 32, OPT_RIGHT = 16, OPT_INTERNAL = 8, OPT_META = 4,
}
W.CMD = CMD
local STATE_CMDS = { [45] = true, [50] = true, [85] = true, [95] = true, [115] = true, [120] = true, [135] = true,
                     [145] = true, [100] = true, [55] = true }

-- ── state ────────────────────────────────────────────────────────────────────

function W.Init(phys, defs)
    P = phys
    W.P = P
    W.defs = defs                  -- UnitDefs (id -> def), engine-shaped
    W.frame = 0
    W.units = {}
    W.nextID = 1000
    W.nextTag = 1
    W.orders = {}                  -- pending orders (lagged)
    W.teams = {}
    W.hash = {}                    -- bucket key -> { [id] = true }
    W.frames = {}                  -- unfinished units: id -> true (FIGHT searches these)
    W.frameHash = {}
    W.occ = {}                     -- 8-elmo square index -> structure unit id
    W.mexOwner = {}                -- metal-map square index -> extractor id
    W.log = {}
    W.timeline = {}
    W.events = {}
    W.missing = {}
    W.rng = phys.SEED or 1
    W.metalSq = nil
    for t = 0, 1 do
        W.teams[t] = {
            metal = P.START_METAL, energy = P.START_ENERGY, mStor = 0, eStor = 0,
            mInc = 0, eInc = 0, mPull = 0, ePull = 0, mExp = 0, eExp = 0, mWaste = 0, eWaste = 0,
            mProduced = 0, eProduced = 0, mUsed = 0, eUsed = 0, mReclaimed = 0,
            unitStorM = 0, unitStorE = 0, count = 0, list = nil, set = {},
            energyMake = 0, metalMake = 0, wind = 0, upkeepE = 0, mexes = {}, mexInc = 0, makers = {},
            ledger = {}, spentBy = {}, stallM = 0, stallE = 0, steps = 0,
        }
    end
    W.sqCount = floor(P.MAP_X / 16)
    W.mapSqX = W.sqCount
end

local function Rand()            -- deterministic LCG (math.random is the bot's)
    W.rng = (W.rng * 1103515245 + 12345) % 2147483648
    return W.rng / 2147483648
end
W.Rand = Rand

local function Log(s) W.log[#W.log + 1] = { W.frame, s } end
W.Log = Log

local function Event(kind, t) t.kind = kind; t.frame = W.frame; W.events[#W.events + 1] = t end
W.Event = Event

-- ── def helpers ──────────────────────────────────────────────────────────────

local catCache = {}
local function Category(d)
    local c = catCache[d.id]
    if c then return c end
    local name = d.name or ""
    if (d.extractsMetal or 0) > 0 then
        c = (d.customParams and tonumber(d.customParams.techlevel or 1) or 1) >= 2 and "moho" or "mex"
        if name:find("moho") or name:find("mexp") then c = "moho" end
    elseif (d.windGenerator or 0) > 0 then c = "wind"
    elseif name:find("afus") then c = "afus"
    elseif name:find("fus") then c = "fusion"
    elseif d.customParams and (d.customParams.energyconv_capacity or d.customParams.energyconv_efficiency) then c = "maker"
    elseif (d.energyMake or 0) > 0 and not d.canMove and not d.isBuilder then c = "energy"
    elseif d.isFactory then c = "lab"
    elseif d.isBuilder and not d.canMove then c = "nano"
    elseif d.isBuilder and d.canMove then c = (d.customParams and d.customParams.iscommander) and "com" or "con"
    elseif ((d.energyStorage or 0) > 1000 or (d.metalStorage or 0) > 500) and not d.canMove then c = "storage"
    elseif d.canMove and d.weapons and #d.weapons > 0 then c = "army"
    elseif not d.canMove and d.weapons and #d.weapons > 0 then c = "defense"
    else c = "other" end
    catCache[d.id] = c
    return c
end
W.Category = Category

local function BuilderClass(u)
    local d = u.d
    if d.isFactory then return "fac" end
    if not d.canMove then return (d.customParams and tonumber(d.customParams.techlevel or 1) or 1) >= 2 and "nano2" or "nano" end
    if d.customParams and d.customParams.iscommander then return "com" end
    local tl = d.customParams and tonumber(d.customParams.techlevel or 1) or 1
    return (tl >= 2 and "con2" or "con1")
end

local function Footprint(d, facing)
    local xs, zs = d.xsize or 2, d.zsize or 2
    if facing == 1 or facing == 3 then xs, zs = zs, xs end
    return xs, zs
end
W.Footprint = Footprint

local function TargetRadius(d)
    if P.RADIUS_RULE == "radius" then return d.radius or 16 end
    if d.canMove then return d.radius or 16 end
    local xs, zs = d.xsize or 2, d.zsize or 2
    return max(xs, zs) * 4
end
W.TargetRadius = TargetRadius

-- engine CGameHelper::Pos2BuildPos
function W.Pos2BuildPos(defID, x, z, facing)
    local d = W.defs[defID]
    if not d then return x, z end
    local xs, zs = Footprint(d, facing or 0)
    if xs % 4 == 2 then x = floor(x / 16) * 16 + 8 else x = floor((x + 8) / 16) * 16 end
    if zs % 4 == 2 then z = floor(z / 16) * 16 + 8 else z = floor((z + 8) / 16) * 16 end
    return x, z
end

-- ── spatial hash ─────────────────────────────────────────────────────────────

local function HKey(x, z) local h = P.HASH; return floor(x / h) * 4096 + floor(z / h) end

local function HashAdd(tbl, u)
    local k = HKey(u.x, u.z)
    local b = tbl[k]
    if not b then b = {}; tbl[k] = b end
    b[u.id] = true
    return k
end

local function HashMove(u)
    local k = HKey(u.x, u.z)
    if k ~= u.hk then
        local b = W.hash[u.hk]; if b then b[u.id] = nil end
        u.hk = HashAdd(W.hash, u)
    end
end

-- ids within r of (x, z); team filter optional; frameOnly searches the unfinished-unit hash
function W.UnitsInCylinder(x, z, r, team, frameOnly)
    local h = P.HASH
    local tbl = frameOnly and W.frameHash or W.hash
    local out, n = {}, 0
    local r2 = r * r
    local bx0, bx1 = floor((x - r) / h), floor((x + r) / h)
    local bz0, bz1 = floor((z - r) / h), floor((z + r) / h)
    local units = W.units
    for bx = bx0, bx1 do
        for bz = bz0, bz1 do
            local b = tbl[bx * 4096 + bz]
            if b then
                for id in pairs(b) do
                    local u = units[id]
                    if u and (team == nil or u.team == team) then
                        local dx, dz = u.x - x, u.z - z
                        if dx * dx + dz * dz <= r2 then n = n + 1; out[n] = id end
                    end
                end
            end
        end
    end
    return out
end

-- ── occupancy (8-elmo squares) ───────────────────────────────────────────────

local function Cells(d, x, z, facing)
    local xs, zs = Footprint(d, facing)
    local x0 = floor((x - xs * 4) / 8 + 0.5)
    local z0 = floor((z - zs * 4) / 8 + 0.5)
    return x0, z0, xs, zs
end

local SQ = 4096    -- occupancy index stride (12288 / 8 = 1536 squares per side)

-- engine TestBuildOrder: 0 blocked, 1 mobile in the way, 2 free.  `ignore` = a unit id whose footprint does not count.
function W.TestBuild(defID, x, z, facing, ignore)
    local d = W.defs[defID]
    if not d then return 0 end
    local x0, z0, xs, zs = Cells(d, x, z, facing or 0)
    if x0 < 0 or z0 < 0 or (x0 + xs) * 8 > P.MAP_X or (z0 + zs) * 8 > P.MAP_Z then return 0 end
    local occ = W.occ
    local depth = d.extractsMetal or 0
    for i = x0, x0 + xs - 1 do
        local base = i * SQ
        for j = z0, z0 + zs - 1 do
            local o = occ[base + j]
            if o and o ~= ignore then
                -- BAR "Mex Upgrade Reclaimer": a finished extractor opens its yardmap, so a deeper extractor may be
                -- placed on top (the old one keeps extracting until the new one finishes, then it is refunded)
                local ou = W.units[o]
                if not (depth > 0 and ou and ou.built and (ou.d.extractsMetal or 0) > 0 and (ou.d.extractsMetal or 0) < depth) then
                    return 0, o
                end
            end
        end
    end
    return 2
end

local function Occupy(u)
    local x0, z0, xs, zs = Cells(u.d, u.x, u.z, u.facing or 0)
    local occ = W.occ
    for i = x0, x0 + xs - 1 do
        local base = i * SQ
        for j = z0, z0 + zs - 1 do occ[base + j] = u.id end
    end
    u.occupies = true
end

local function Unoccupy(u)
    if not u.occupies then return end
    local x0, z0, xs, zs = Cells(u.d, u.x, u.z, u.facing or 0)
    local occ = W.occ
    for i = x0, x0 + xs - 1 do
        local base = i * SQ
        for j = z0, z0 + zs - 1 do if occ[base + j] == u.id then occ[base + j] = nil end end
    end
    u.occupies = nil
end

-- ── metal extraction ─────────────────────────────────────────────────────────

local function MetalPerSquare()
    if W.metalSq then return W.metalSq end
    if P.METAL_PER_SQUARE then W.metalSq = P.METAL_PER_SQUARE; return W.metalSq end
    -- derive from an isolated cormex yielding MEX_CONST.cormex
    local d = W.defsByName and W.defsByName.cormex
    if d and (d.extractsMetal or 0) > 0 then
        local r = d.extractRange or 0
        local n = 0
        local rs = floor(r / 16) + 1
        for i = -rs, rs do for j = -rs, rs do
            local dx, dz = (i + 0.5) * 16 - 8, (j + 0.5) * 16 - 8
            if dx * dx + dz * dz <= r * r then n = n + 1 end
        end end
        W.metalSq = P.MEX_CONST.cormex / (d.extractsMetal * max(n, 1))
    else
        W.metalSq = 1
    end
    return W.metalSq
end

local function MexSquares(u)
    local d = u.d
    local r = d.extractRange or 0
    local cx, cz = u.x, u.z
    local out = {}
    local i0, i1 = floor((cx - r) / 16), floor((cx + r) / 16)
    local j0, j1 = floor((cz - r) / 16), floor((cz + r) / 16)
    local n = W.sqCount
    for i = max(0, i0), min(n - 1, i1) do
        for j = max(0, j0), min(n - 1, j1) do
            local dx, dz = i * 16 + 8 - cx, j * 16 + 8 - cz
            if dx * dx + dz * dz <= r * r then out[#out + 1] = i * SQ + j end
        end
    end
    return out
end

local function MexYield(u)
    if P.MEX_MODE == "constant" then
        return P.MEX_CONST[u.d.name] or (u.d.extractsMetal or 0) * 2370
    end
    return (u.d.extractsMetal or 0) * MetalPerSquare() * (u.mexOwned or 0)
end

local function RecalcMexTeam(t)
    local T = W.teams[t]
    local s = 0
    for id in pairs(T.mexes) do
        local u = W.units[id]
        if u then u.mexYield = MexYield(u); s = s + u.mexYield end
    end
    T.mexInc = s
end

local function MexClaim(u)
    if P.MEX_MODE == "constant" then return end
    u.mexSq = MexSquares(u)
    local own = W.mexOwner
    local depth = u.d.extractsMetal or 0
    local touched = {}
    local n = 0
    for _, k in ipairs(u.mexSq) do
        local o = own[k]
        local ou = o and W.units[o]
        if not ou then own[k] = u.id; n = n + 1
        elseif (ou.d.extractsMetal or 0) < depth then
            own[k] = u.id; n = n + 1
            ou.mexOwned = ou.mexOwned - 1
            touched[o] = true
        end
    end
    u.mexOwned = n
end

local function MexRelease(u)
    if not u.mexSq then return end
    local own = W.mexOwner
    local freed = {}
    for _, k in ipairs(u.mexSq) do
        if own[k] == u.id then own[k] = nil; freed[#freed + 1] = k end
    end
    u.mexSq = nil
    if #freed == 0 then return end
    -- neighbours pick freed squares up (deepest first, then oldest)
    local T = W.teams[u.team]
    local cands = {}
    for id in pairs(T.mexes) do
        local m = W.units[id]
        if m and m ~= u and m.mexSq and abs(m.x - u.x) < 400 and abs(m.z - u.z) < 400 then cands[#cands + 1] = m end
    end
    table.sort(cands, function(a, b)
        local da, db = a.d.extractsMetal or 0, b.d.extractsMetal or 0
        if da ~= db then return da > db end
        return a.id < b.id
    end)
    for _, k in ipairs(freed) do
        for _, m in ipairs(cands) do
            local hit = false
            for _, mk in ipairs(m.mexSq) do if mk == k then hit = true; break end end
            if hit then own[k] = m.id; m.mexOwned = m.mexOwned + 1; break end
        end
    end
end

-- ── units ────────────────────────────────────────────────────────────────────

local function TeamList(t)
    local T = W.teams[t]
    if not T.list then
        local l, n = {}, 0
        for id in pairs(T.set) do n = n + 1; l[n] = id end
        table.sort(l)
        T.list = l
    end
    return T.list
end
W.TeamList = TeamList

local function Storages(T)
    T.mStor = P.BASE_M_STORAGE + T.unitStorM
    T.eStor = P.BASE_E_STORAGE + T.unitStorE
end

local PRIO_HASH = 2654435761
local function NewUnit(defID, team, x, z, facing, beingBuilt, builderID)
    local d = W.defs[defID]
    local id = W.nextID
    W.nextID = id + 1
    local u = {
        id = id, defID = defID, d = d, team = team, ally = team, x = x, z = z, facing = facing or 0,
        built = not beingBuilt, progress = beingBuilt and 0 or 1, cmds = {}, active = true, born = W.frame,
        isBuilder = (d.buildSpeed or 0) > 0 and (d.isBuilder or d.isFactory),
        static = not d.canMove, builderID = builderID, used = 0, cat = Category(d),
        prioKey = (id * PRIO_HASH) % 4294967296, idleNotified = true,
    }
    u.passive = u.isBuilder and not (d.customParams and d.customParams.iscommander) and P.PRIORITY
    if d.isFactory then u.fq = {} end
    W.units[id] = u
    u.hk = HashAdd(W.hash, u)
    local T = W.teams[team]
    T.set[id] = true; T.list = nil; T.count = T.count + 1
    if not d.canMove then
        if (d.extractsMetal or 0) > 0 then
            local o = W.occ[floor(x / 8) * SQ + floor(z / 8)]
            local ou = o and W.units[o]
            if ou and ou.built and (ou.d.extractsMetal or 0) > 0 then u.under = o end
        end
        Occupy(u)
    end
    if beingBuilt then W.frames[id] = true; u.fk = HashAdd(W.frameHash, u) end
    return u
end

local function FinishEcon(u)
    local T = W.teams[u.team]
    local d = u.d
    T.unitStorM = T.unitStorM + (d.metalStorage or 0)
    T.unitStorE = T.unitStorE + (d.energyStorage or 0)
    Storages(T)
    T.energyMake = T.energyMake + (d.energyMake or 0) - min(0, d.energyUpkeep or 0)   -- negative upkeep = output (solar)
    T.metalMake = T.metalMake + (d.metalMake or 0)
    if (d.windGenerator or 0) > 0 then T.wind = T.wind + 1 end
    T.upkeepE = T.upkeepE + max(0, d.energyUpkeep or 0)
    if (d.extractsMetal or 0) > 0 then
        T.mexes[u.id] = true
        MexClaim(u)
        RecalcMexTeam(u.team)
    end
    if u.cat == "maker" then T.makers[u.id] = true end
end

local function UnfinishEcon(u)
    local T = W.teams[u.team]
    local d = u.d
    T.unitStorM = T.unitStorM - (d.metalStorage or 0)
    T.unitStorE = T.unitStorE - (d.energyStorage or 0)
    Storages(T)
    T.energyMake = T.energyMake - (d.energyMake or 0) + min(0, d.energyUpkeep or 0)
    T.metalMake = T.metalMake - (d.metalMake or 0)
    if (d.windGenerator or 0) > 0 then T.wind = T.wind - 1 end
    T.upkeepE = T.upkeepE - max(0, d.energyUpkeep or 0)
    if T.mexes[u.id] then
        T.mexes[u.id] = nil
        MexRelease(u)
        RecalcMexTeam(u.team)
    end
    T.makers[u.id] = nil
end

-- A unit that exists at game start (commander): created and finished at once.
function W.Spawn(defName, team, x, z)
    local d = W.defsByName[defName]
    local u = NewUnit(d.id, team, x, z, 0, false, nil)
    FinishEcon(u)
    W.callin("UnitCreated", u.id, u.defID, team, nil)
    W.callin("UnitFinished", u.id, u.defID, team)
    return u
end

function W.Kill(u, reason)
    if not W.units[u.id] then return end
    if u.built then UnfinishEcon(u) end
    Unoccupy(u)
    if u.under and not u.built then          -- an unfinished upgrade frame: the mex beneath blocks its square again
        local m = W.units[u.under]
        if m then Occupy(m) end
    end
    W.units[u.id] = nil
    local b = W.hash[u.hk]; if b then b[u.id] = nil end
    if W.frames[u.id] then
        W.frames[u.id] = nil
        local fb = W.frameHash[u.fk]; if fb then fb[u.id] = nil end
    end
    local T = W.teams[u.team]
    T.set[u.id] = nil; T.list = nil; T.count = T.count - 1
    u.dead = true
    if u.cat ~= "army" then Event("destroyed", { id = u.id, name = u.d.name, reason = reason, x = u.x, z = u.z }) end
    W.callin("UnitDestroyed", u.id, u.defID, u.team, nil, nil, nil)
end

local function Finish(t)
    t.built = true
    t.progress = 1
    W.frames[t.id] = nil
    local fb = W.frameHash[t.fk]; if fb then fb[t.id] = nil end
    FinishEcon(t)
    t.finishedFrame = W.frame
    t.idleNotified = false
    if t.under then                          -- Mex Upgrade Reclaimer: the mex beneath is removed and refunded
        local m = W.units[t.under]
        t.under = nil
        if m then
            local T = W.teams[m.team]
            T.metal = T.metal + (m.d.metalCost or 0)
            T.mReclaimed = T.mReclaimed + (m.d.metalCost or 0)
            m.occupies = nil                 -- its squares belong to the new extractor now
            W.Kill(m, "upgraded")
        end
    end
    if t.cat ~= "army" then
        Event("finished", { id = t.id, name = t.d.name, cat = t.cat, x = t.x, z = t.z, born = t.born })
    end
    W.teams[t.team].finishedN = (W.teams[t.team].finishedN or 0) + 1
    W.callin("UnitFinished", t.id, t.defID, t.team)
end

-- ── orders ───────────────────────────────────────────────────────────────────

local function Bit(o, b) return floor(o / b) % 2 == 1 end

local function NormOpts(o)
    local r = { shift = false, ctrl = false, alt = false, meta = false, internal = false, right = false, coded = 0 }
    if type(o) == "number" then
        r.shift, r.ctrl, r.alt = Bit(o, 32), Bit(o, 64), Bit(o, 128)
        r.meta, r.internal, r.right = Bit(o, 4), Bit(o, 8), Bit(o, 16)
        r.coded = o
    elseif type(o) == "table" then
        for k, v in pairs(o) do
            if type(k) == "number" and type(v) == "string" then r[v] = true
            elseif type(k) == "string" then r[k] = v and true or false end
        end
        r.coded = (r.shift and 32 or 0) + (r.ctrl and 64 or 0) + (r.alt and 128 or 0) + (r.meta and 4 or 0)
                + (r.internal and 8 or 0) + (r.right and 16 or 0)
    end
    return r
end
W.NormOpts = NormOpts

local function CopyParams(p)
    if type(p) == "number" then return { p } end
    local c = {}
    if type(p) == "table" then for i = 1, #p do c[i] = p[i] end end
    return c
end

local function PStr(p)
    local s = {}
    for i = 1, #(p or {}) do s[i] = type(p[i]) == "number" and string.format("%.0f", p[i]) or tostring(p[i]) end
    return table.concat(s, ",")
end
W.PStr = PStr

function W.GiveOrder(id, cmd, params, opts)
    local u = W.units[id]
    if not u or u.team ~= W.myTeam then return false end
    if W.trace and W.trace[id] then
        local o = NormOpts(opts)
        Log(string.format("[TRACE] %d give cmd %d {%s}%s", id, cmd, PStr(type(params) == "table" and params or { params }), o.shift and " shift" or ""))
    end
    local lag = P.ORDER_LAG + floor((Rand() * 2 - 1) * P.ORDER_JITTER + 0.5)
    if lag < 1 then lag = 1 end
    -- the engine delivers a unit's orders in the order they were given: jitter must never reorder them
    local at = max(W.frame + lag, u.lastOrderAt or 0)
    u.lastOrderAt = at
    local o = W.orders
    o[#o + 1] = { at = at, id = id, cmd = cmd, params = CopyParams(params), opts = NormOpts(opts) }
    W.ordersGiven = (W.ordersGiven or 0) + 1
    return true
end

-- engine-internal order (the stock-widget emulations use it; same lag as a widget order)
W.GiveOrderAny = function(id, cmd, params, opts)
    local u = W.units[id]
    if not u then return end
    local at = max(W.frame + P.ORDER_LAG, u.lastOrderAt or 0)
    u.lastOrderAt = at
    W.orders[#W.orders + 1] = { at = at, id = id, cmd = cmd, params = CopyParams(params), opts = NormOpts(opts) }
end

local function NewCmd(cmd, params, opts)
    local tag = W.nextTag
    W.nextTag = tag + 1
    return { id = cmd, params = params, opts = opts, tag = tag }
end

local function ClearWork(u) u.work = nil; u.moving = nil end

local function FactoryOrder(u, cmd, params, opts)
    local n = 1
    if opts.shift then n = n * 5 end
    if opts.ctrl then n = n * 20 end
    local fq = u.fq
    if opts.right then
        for _ = 1, n do
            for i = #fq, 1, -1 do if fq[i].id == cmd then
                if i == 1 and u.fbuild then local f = W.units[u.fbuild]; if f and not f.built then W.Kill(f, "cancel") end; u.fbuild = nil end
                table.remove(fq, i); break
            end end
        end
        return
    end
    for _ = 1, n do
        local c = NewCmd(cmd, {}, opts)
        if opts.alt then table.insert(fq, 1, c) else fq[#fq + 1] = c end
    end
    u.idleNotified = false
end

local function IsImmobileBuilder(d) return d.isBuilder and not d.canMove and not d.isFactory end

local function ApplyOrder(o)
    local u = W.units[o.id]
    if not u then return end
    local cmd, params, opts = o.cmd, o.params, o.opts
    if cmd == CMD.STOCKPILE then
        if P.STOCKPILE[u.d.name] then
            local n = (opts.shift and 5 or 1) * (opts.ctrl and 20 or 1)
            u.stockQ = math.max(0, (u.stockQ or 0) + (opts.right and -n or n))
        end
        return
    end
    if STATE_CMDS[cmd] or cmd >= 30000 then
        if cmd == CMD.ONOFF then u.active = (params[1] or 1) ~= 0 end
        return
    end
    if cmd == CMD.SELFD then
        if u.selfdAt then u.selfdAt = nil
        else u.selfdAt = W.frame + ((u.d.selfDestructCountdown and u.d.selfDestructCountdown * 30) or P.SELFD_FRAMES) end
        return
    end
    if cmd == CMD.INSERT then
        local pos, icmd, iopts = params[1] or 0, params[2], params[3] or 0
        local ip = {}
        for i = 4, #params do ip[#ip + 1] = params[i] end
        local io = NormOpts(iopts)
        if u.fq and icmd and icmd < 0 then
            local c = NewCmd(icmd, ip, io)
            local fq = u.fq
            local idx = (pos < 0 or pos >= #fq) and (#fq + 1) or (pos + 1)
            if idx == 1 and u.fbuild then
                -- the engine starts the inserted unit first; the current frame waits (it is kept)
                u.fbuildHold = u.fbuildHold or {}
            end
            table.insert(fq, idx, c)
            u.idleNotified = false
            return
        end
        if icmd and icmd < 0 then
            local x, z = W.Pos2BuildPos(-icmd, ip[1] or 0, ip[3] or 0, ip[4] or 0)
            ip[1], ip[3] = x, z
        end
        local c = NewCmd(icmd, ip, io)
        local q = u.cmds
        local idx = (pos < 0 or pos >= #q) and (#q + 1) or (pos + 1)
        table.insert(q, idx, c)
        if idx == 1 then ClearWork(u) end
        u.idleNotified = false
        return
    end
    if cmd == CMD.REMOVE then
        local q = u.fq or u.cmds
        for _, tag in ipairs(params) do
            for i = #q, 1, -1 do
                if (opts.alt and q[i].id == tag) or q[i].tag == tag then table.remove(q, i) end
            end
        end
        if u.fq then
            for _, tag in ipairs(params) do
                for i = #u.cmds, 1, -1 do if u.cmds[i].tag == tag then table.remove(u.cmds, i) end end
            end
        end
        return
    end
    if u.fq and cmd < 0 then FactoryOrder(u, cmd, params, opts); return end
    if cmd == CMD.STOP then
        u.cmds = {}
        ClearWork(u)
        if u.fq then end      -- STOP does not empty a factory's build queue
        return
    end
    if cmd == CMD.WAIT then return end
    if cmd < 0 then
        local x, z = W.Pos2BuildPos(-cmd, params[1] or 0, params[3] or 0, params[4] or 0)
        params[1], params[3] = x, z
    end
    if P.NANO_FIGHT and IsImmobileBuilder(u.d) and opts.shift and cmd ~= CMD.FIGHT then
        local q = u.cmds
        if q[#q] and q[#q].id == CMD.FIGHT then q[#q] = nil end   -- unit_immobile_builder: drop the trailing FIGHT
    end
    local c = NewCmd(cmd, params, opts)
    if opts.shift then
        u.cmds[#u.cmds + 1] = c
    else
        u.cmds = { c }
        ClearWork(u)
    end
    u.idleNotified = false
end

-- apply every order due by this frame (called every frame by the runner)
function W.ApplyOrders(frame)
    local o = W.orders
    if #o == 0 then return end
    local keep, nk = {}, 0
    local due, nd = {}, 0
    for i = 1, #o do
        if o[i].at <= frame then nd = nd + 1; due[nd] = o[i] else nk = nk + 1; keep[nk] = o[i] end
    end
    if nd == 0 then return end
    W.orders = keep
    for i = 1, nd do ApplyOrder(due[i]) end
end

-- ── command execution ────────────────────────────────────────────────────────

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return sqrt(dx * dx + dz * dz) end

local function Reach(u, td) return (u.d.buildDistance or 0) + TargetRadius(td) + P.RANGE_PAD end

local function Pop(u, why)
    if W.trace and W.trace[u.id] then
        local c = u.cmds[1]
        Log(string.format("[TRACE] %d pop cmd %s {%s} (%s) at %.0f,%.0f", u.id, c and c.id or "-", c and PStr(c.params) or "", why or "?", u.x, u.z))
    end
    table.remove(u.cmds, 1)
    ClearWork(u)
end

-- move u toward (x, z), stopping at distance `stop`; returns true when within stop
local function MoveToward(u, x, z, stop, dt)
    local dx, dz = x - u.x, z - u.z
    local d = sqrt(dx * dx + dz * dz)
    if d <= stop then
        if u.moving then u.arriveAt = W.frame + P.ARRIVE_FRAMES end    -- decelerate / settle before building
        u.moving = nil
        return true
    end
    if not u.moving and P.START_MOVE_FRAMES > 0 then
        -- take-off / turn / accelerate: a builder that was standing loses START_MOVE_FRAMES before it covers ground
        if not u.moveWaitUntil then u.moveWaitUntil = W.frame + P.START_MOVE_FRAMES end
        if W.frame < u.moveWaitUntil then return false end
    end
    u.moveWaitUntil = nil
    local sp = (u.d.speed or 0) * dt
    if sp <= 0 then return false end
    local step = min(sp, d - stop * 0.98)
    u.x = u.x + dx / d * step
    u.z = u.z + dz / d * step
    u.moving = true
    HashMove(u)
    if d - step <= stop then u.arriveAt = W.frame + P.ARRIVE_FRAMES; u.moving = nil; return P.ARRIVE_FRAMES <= 0 end
    return false
end

local function AtCap(team) return W.teams[team].count >= P.MAX_UNITS end

-- a builder is in reach of target unit t (moving if it can); returns true when it can work on t this step
local function Approach(u, t, dt)
    local r = Reach(u, t.d)
    local d = Dist(u.x, u.z, t.x, t.z)
    if d <= r then u.moving = nil; return true end
    if u.static then return false end
    return MoveToward(u, t.x, t.z, r * P.MOVE_STOP, dt)
end

local function Work(u, t, kind)
    if u.arriveAt and W.frame < u.arriveAt then u.state = "travel"; return end
    u.work = t.id; u.workKind = kind
end

local function ExecBuild(u, c, dt)
    local defID = -c.id
    local d = W.defs[defID]
    if not d then Pop(u, "nodef"); return end
    if c.frameID then
        local t = W.units[c.frameID]
        if not t or t.built then Pop(u, t and "built" or "frame gone"); return end
        if Approach(u, t, dt) then Work(u, t, "build") end
        return
    end
    local x, z = c.params[1] or u.x, c.params[3] or u.z
    local r = Reach(u, d)
    local dd = Dist(u.x, u.z, x, z)
    if W.trace and W.trace[u.id] and W.frame % 300 == 0 then
        local ok, occ = W.TestBuild(defID, x, z, c.params[4] or 0)
        Log(string.format("[TRACE] %d exec build %s at %.0f,%.0f dist %.0f reach %.0f test %s occ %s cap %s", u.id, d.name, x, z, dd, r,
            tostring(ok), tostring(occ and W.units[occ] and W.units[occ].d.name), tostring(W.teams[u.team].count)))
    end
    if dd > r then
        if u.static then Pop(u, "out of reach"); return end
        MoveToward(u, x, z, r * P.MOVE_STOP, dt)
        u.state = "move"
        return
    end
    u.moving = nil
    local facing = c.params[4] or 0
    local ok, occ = W.TestBuild(defID, x, z, facing)
    if ok == 0 then
        local o = occ and W.units[occ]
        if o and not o.built and o.defID == defID and abs(o.x - x) < 1 and abs(o.z - z) < 1 then
            c.frameID = o.id
            Work(u, o, "build")
            return
        end
        Pop(u, "blocked by " .. tostring(o and o.d.name))
        local T = W.teams[u.team]
        T.blockedBuilds = (T.blockedBuilds or 0) + 1
        -- "<nil" = out of the map (e.g. an edge grid's capstone): run.json blocked_by counts these per def / blocker / builder class
        local key = d.name .. "<" .. tostring(o and o.d.name) .. (o and (o.built and "" or "(frame)") or "") .. " by " .. (u.bclass or "?")
        T.blockedBy = T.blockedBy or {}
        T.blockedBy[key] = (T.blockedBy[key] or 0) + 1
        return
    end
    if AtCap(u.team) then u.state = "cap"; return end
    local t = NewUnit(defID, u.team, x, z, facing, true, u.id)
    c.frameID = t.id
    W.callin("UnitCreated", t.id, defID, u.team, u.id)
    if W.units[t.id] and not t.built then Work(u, t, "build") end
end

-- what is unit g working on (for GUARD)
local function GuardTarget(g)
    if not g.built then return g end
    if g.fq and g.fbuild then return W.units[g.fbuild] end
    if g.work then
        local t = W.units[g.work]
        if t and g.workKind == "build" then return t end
    end
    return nil
end

local function ExecGuard(u, c, dt)
    local g = W.units[c.params[1] or -1]
    if not g then Pop(u); return end
    local t = GuardTarget(g)
    if t and not t.built then
        if Approach(u, t, dt) then Work(u, t, "build") end
        return
    end
    -- nothing to assist: mobile guards follow
    if not u.static then
        local r = Reach(u, g.d)
        MoveToward(u, g.x, g.z, r * 0.8, dt)
    end
    u.state = "guard_idle"
end

local function NearestFrame(u, r, team)
    local best, bd
    for _, id in ipairs(W.UnitsInCylinder(u.x, u.z, r + 120, team, true)) do
        local t = W.units[id]
        if t and not t.built and t.id ~= u.id then
            local d = Dist(u.x, u.z, t.x, t.z)
            if d <= (u.d.buildDistance or 0) + TargetRadius(t.d) + P.RANGE_PAD + (u.static and 0 or (r - (u.d.buildDistance or 0))) then
                if not bd or d < bd then best, bd = t, d end
            end
        end
    end
    return best
end

local function ExecRepair(u, c, dt)
    local p = c.params
    if #p >= 4 then
        local t = NearestFrame(u, (u.d.buildDistance or 0) + (p[4] or 0), u.team)
        if not t then Pop(u); return end
        if Approach(u, t, dt) then Work(u, t, "build") end
        return
    end
    local t = W.units[p[1] or -1]
    if not t or t.built then Pop(u); return end
    if Approach(u, t, dt) then Work(u, t, "build")
    elseif u.static then Pop(u) end
end

local function ExecReclaim(u, c, dt)
    local p = c.params
    if #p ~= 1 then Pop(u); return end            -- area reclaim: no features in the sim
    local t = W.units[p[1]]
    if not t then Pop(u); return end
    if Approach(u, t, dt) then Work(u, t, "reclaim")
    elseif u.static then Pop(u) end
end

local function ExecFight(u, c, dt)
    local r = (u.d.buildDistance or 0) + (u.static and 0 or 150)
    if u.isBuilder then
        local t = NearestFrame(u, r, u.team)
        if t then
            if Approach(u, t, dt) then Work(u, t, "build") end
            return
        end
    end
    if u.static then u.state = "fight_idle"; return end
    local x, z = c.params[1] or u.x, c.params[3] or u.z
    if MoveToward(u, x, z, 16, dt) then
        if c.id == CMD.PATROL then
            -- patrol: turn round (keep the command)
            c.params[1], c.params[3] = c.ox or u.x, c.oz or u.z
        else Pop(u) end
    end
end

local function ExecMove(u, c, dt)
    if u.static then Pop(u); return end
    local x, z = c.params[1] or u.x, c.params[3] or u.z
    if MoveToward(u, x, z, 8, dt) then Pop(u) end
end

local function ExecUnit(u, dt)
    local c = u.cmds[1]
    if W.trace and W.trace[u.id] and W.frame % 300 == 0 then
        local f = c and c.frameID and W.units[c.frameID]
        Log(string.format("[TRACE] %d exec n=%d head %s frameID %s (%s %.2f) used %.2f", u.id, #u.cmds, c and c.id or "-",
            tostring(c and c.frameID), f and f.d.name or "-", f and f.progress or -1, u.used or 0))
    end
    u.work, u.state = nil, nil
    if not c then
        if not u.idleNotified then
            u.idleNotified = true
            W.callin("UnitIdle", u.id, u.defID, u.team)
        end
        return
    end
    local id = c.id
    if id < 0 then
        if not u.isBuilder then Pop(u); return end
        ExecBuild(u, c, dt)
    elseif id == CMD.MOVE then ExecMove(u, c, dt)
    elseif id == CMD.REPAIR then if u.isBuilder then ExecRepair(u, c, dt) else Pop(u) end
    elseif id == CMD.GUARD then if u.isBuilder then ExecGuard(u, c, dt) else Pop(u) end
    elseif id == CMD.RECLAIM then if u.isBuilder then ExecReclaim(u, c, dt) else Pop(u) end
    elseif id == CMD.FIGHT or id == CMD.PATROL then
        if c.ox == nil then c.ox, c.oz = u.x, u.z end
        ExecFight(u, c, dt)
    elseif id == CMD.ATTACK or id == CMD.AREA_ATTACK or id == CMD.MANUALFIRE then Pop(u)
    elseif id == CMD.RESURRECT or id == CMD.CAPTURE or id == CMD.LOAD_UNITS or id == CMD.UNLOAD_UNITS then Pop(u)
    elseif id == CMD.WAIT or id == CMD.TIMEWAIT then Pop(u)
    else
        if not W.missing["cmd" .. id] then W.missing["cmd" .. id] = true; Log("[SIM] unhandled command " .. id) end
        Pop(u)
    end
end

local function ExecFactory(u, dt)
    -- rally / guard commands on a factory are ignored; it works its build queue
    local fq = u.fq
    local c = fq[1]
    if not c then
        u.fbuild = nil
        if not u.idleNotified then u.idleNotified = true; W.callin("UnitIdle", u.id, u.defID, u.team) end
        return
    end
    local f = u.fbuild and W.units[u.fbuild]
    if f and f.defID ~= -c.id and not f.built then
        -- an inserted order went to the front: the engine builds it first (the old frame is dropped here)
        W.Kill(f, "factory_switch")
        f = nil
    end
    if not f then
        if AtCap(u.team) then u.state = "cap"; return end
        local def = W.defs[-c.id]
        if not def then table.remove(fq, 1); return end
        local fx, fz = u.x, u.z
        local t = NewUnit(-c.id, u.team, fx, fz, 0, true, u.id)
        t.inFactory = u.id
        u.fbuild = t.id
        W.callin("UnitCreated", t.id, t.defID, u.team, u.id)
        f = W.units[t.id]
        if not f then u.fbuild = nil; return end
    end
    u.work, u.workKind = f.id, "build"
end

-- ── a physics step ───────────────────────────────────────────────────────────

local function LedgerAdd(T, cls, key, v)
    local l = T.ledger[cls]
    if not l then l = {}; T.ledger[cls] = l end
    l[key] = (l[key] or 0) + v
end

-- ── army spending sink (user, 2026-10-14) ────────────────────────────────────
-- "More eco is only good to spend on units": once metal can no longer be spent on eco, blocks of 1 T2 air lab + 40 decoy commanders
-- (cordecom, 300 BP each: the most BP per unit slot) build Dragons (corcrwh) on repeat.  Modelled as magic: no units, no positions; a
-- block first pays its own setup cost (40 x cordecom + coraap) at its full build rate, then pulls Dragon costs at 12.6k BP.  Each block
-- competes for resources like any other low-priority builder and holds SINK.slots unit-cap slots (41 builders + ~5 Dragons alive in
-- the vacuum test).  Off unless P.SINK.on.

local function SinkInit(T)
    local S = P.SINK
    local dd, lab, dec = W.defsByName[S.unit], W.defsByName[S.lab], W.defsByName[S.builder]
    T.sink = {
        blocks = {}, bp = S.builders * (dec.buildSpeed or 0) + (lab.buildSpeed or 0),
        unitM = dd.metalCost, unitE = dd.energyCost, unitBT = dd.buildTime,
        setupM = S.builders * dec.metalCost + lab.metalCost, setupE = S.builders * dec.energyCost + lab.energyCost,
        setupBT = S.builders * dec.buildTime + lab.buildTime,
        floatSince = nil, lastAdd = -1e9, unitsDone = 0, unitM_spent = 0, setupM_spent = 0, stalled = 0,
    }
end

local function SinkMaybeAdd(T, t)
    local S, K = P.SINK, T.sink
    local need = max(S.bank_min, S.bank_frac * T.mStor)
    if T.metal >= need then K.floatSince = K.floatSince or W.frame else K.floatSince = nil end
    if not K.floatSince or W.frame - K.floatSince < S.hold * 30 or W.frame - K.lastAdd < S.gap * 30 then return end
    if #K.blocks >= S.max_blocks or T.count + S.slots > P.MAX_UNITS - S.cap_margin then return end
    local b = { sink = true, passive = true, team = t, prioKey = ((#K.blocks + 7) * PRIO_HASH * 7919) % 4294967296, setup = 0, prog = 0 }
    K.blocks[#K.blocks + 1] = b
    K.lastAdd = W.frame
    T.count = T.count + S.slots          -- the block's builders and its live Dragons hold unit slots
    Event("sink_block", { n = #K.blocks, bank = T.metal, inc = T.mInc })
    Log(string.format("[SIM] army sink block %d added (bank %.0f, metal income %.0f)", #K.blocks, T.metal, T.mInc))
end

-- one block's draw this step: returns metal, energy, and a function that applies the progress
local function SinkDemand(K, b, dt)
    if b.setup < 1 then
        local p = min(K.bp / K.setupBT * dt, 1 - b.setup)
        return K.setupM * p, K.setupE * p, function() b.setup = b.setup + p; K.setupM_spent = K.setupM_spent + K.setupM * p end
    end
    local p = K.bp / K.unitBT * dt
    return K.unitM * p, K.unitE * p, function()
        b.prog = b.prog + p
        K.unitM_spent = K.unitM_spent + K.unitM * p
        while b.prog >= 1 do b.prog = b.prog - 1; K.unitsDone = K.unitsDone + 1 end
    end
end

function W.Step(nframes)
    local dt = nframes / 30
    local units = W.units
    W.stepN = (W.stepN or 0) + 1

    -- 1. self-destructs
    for id, u in pairs(units) do
        if u.selfdAt and W.frame >= u.selfdAt then W.Kill(u, "selfd") end
    end

    -- 2. command execution (snapshot of ids: callins may add units)
    local ids = {}
    for id in pairs(units) do ids[#ids + 1] = id end
    table.sort(ids)
    local demands = {}
    for i = 1, #ids do
        local u = units[ids[i]]
        if u and u.built then
            if u.fq then ExecFactory(u, dt)
            elseif #u.cmds > 0 or not u.idleNotified then ExecUnit(u, dt) end
            -- engine idle behaviour of static builders (maneuver move state): a nano whose orders give it nothing
            -- to build in reach (idle, WAIT, a guard whose target builds out of reach) assists the nearest
            -- construction in its build range.  nano_broker.lua: "a nano that only has a WAIT queued still
            -- auto-assists nearby builds (measured: 27 of 28 parked spine nanos building)".  Paused nanos do not.
            local head = u.cmds[1]
            local autoOk = P.STATIC_AUTO_ASSIST == true or P.STATIC_AUTO_ASSIST == "all"
                or (P.STATIC_AUTO_ASSIST == "idle" and (not head or head.id == CMD.WAIT))
            if autoOk and u.static and u.isBuilder and not u.fq and u.active and not (u.work and units[u.work]) then
                local t = NearestFrame(u, u.d.buildDistance or 0, u.team)
                if t then u.work, u.workKind, u.state = t.id, "build", "auto" end
            end
            if u.isBuilder and u.work and units[u.work] and u.active then demands[#demands + 1] = u end
        end
    end
    if P.SINK and P.SINK.on then
        local T = W.teams[W.myTeam]
        if not T.sink then SinkInit(T) end
        if W.frame >= (P.SINK.start or 0) * 30 then SinkMaybeAdd(T, W.myTeam) end
        for _, b in ipairs(T.sink.blocks) do demands[#demands + 1] = b end
    end

    -- 3. resources: income first
    for t = 0, 1 do
        local T = W.teams[t]
        local wind = P.WIND
        local eInc = T.energyMake + T.wind * wind
        local mInc = T.metalMake
        -- upkeep (mex energy): paid before builders; short energy throttles extraction
        local up = T.upkeepE * dt
        local eAvail = T.energy + eInc * dt
        local frac = 1
        if up > 0 then
            if eAvail < up then frac = max(0, eAvail / up) end
            T.energy = T.energy - up * frac
        end
        mInc = mInc + T.mexInc * frac
        T.mexFrac = frac
        -- energy converters (game_energy_conversion): above MM_LEVEL of storage they turn energy into metal
        local mmM, mmE = 0, 0
        if next(T.makers) and T.eStor > 0 then
            local wantE = 0
            local ratio = 0
            for id in pairs(T.makers) do
                local m = units[id]
                if m then
                    local cp = m.d.customParams or {}
                    local cap = tonumber(cp.energyconv_capacity) or 0
                    local eff = tonumber(cp.energyconv_efficiency) or 0
                    wantE = wantE + cap
                    ratio = ratio + cap * eff
                end
            end
            if wantE > 0 and T.energy > T.eStor * P.MM_LEVEL then
                local use = min(wantE * dt, T.energy - T.eStor * P.MM_LEVEL)
                mmE = use / dt
                mmM = mmE * (ratio / wantE)
                T.energy = T.energy - use
            end
        end
        mInc = mInc + mmM
        T.mIncNow, T.eIncNow = mInc, eInc
        T.mmE = mmE
        T.otherEPull = T.upkeepE * frac + mmE
    end

    -- 3b. stockpiling (nuke / anti-nuke missiles): the engine draws their cost every frame, outside the priority gadget
    for t = 0, 1 do
        local T = W.teams[t]
        for id, u in pairs(units) do
            if u.team == t and (u.stockQ or 0) > 0 and u.built then
                local sp = P.STOCKPILE[u.d.name]
                local f = dt / sp[3]
                local m, e = sp[1] * f, sp[2] * f
                if T.metal + T.mIncNow * dt >= m and T.energy + T.eIncNow * dt >= e then
                    T.metal, T.energy = T.metal - m, T.energy - e
                    T.mUsed = T.mUsed + m
                    T.spentBy.stockpile = (T.spentBy.stockpile or 0) + m
                    T.stockE = (T.stockE or 0) + e
                    u.stockProg = (u.stockProg or 0) + f
                    if u.stockProg >= 1 then u.stockProg = 0; u.stockQ = u.stockQ - 1; u.stockHave = (u.stockHave or 0) + 1 end
                end
            end
        end
    end

    -- 4. builder allocation (BAR builder priority gadget), then progress
    local spendM, spendE = { [0] = 0, [1] = 0 }, { [0] = 0, [1] = 0 }
    local pullM, pullE = { [0] = 0, [1] = 0 }, { [0] = 0, [1] = 0 }
    -- order: non-passive (commander) first, then passive in a stable hash order
    table.sort(demands, function(a, b)
        if a.passive ~= b.passive then return not a.passive end
        return a.prioKey < b.prioKey
    end)
    local budM, budE = {}, {}
    for t = 0, 1 do
        local T = W.teams[t]
        budM[t] = T.metal - max(T.mIncNow * P.STALL_MARGIN_INC_M, T.mStor * P.STALL_MARGIN_STO) - 1 + dt * T.mIncNow
        budE[t] = T.energy - max(T.eIncNow * P.STALL_MARGIN_INC_E, T.eStor * P.STALL_MARGIN_STO) - 1 + dt * T.eIncNow
        if not P.PRIORITY then
            budM[t] = T.metal + dt * T.mIncNow
            budE[t] = T.energy + dt * T.eIncNow
        end
    end
    local progress = {}     -- target id -> progress added this step
    local reclaimAmt = {}
    for i = 1, #demands do
        local u = demands[i]
        if u.sink then
            local T = W.teams[u.team]
            local m, e, apply = SinkDemand(T.sink, u, dt)
            if budM[u.team] - m > 0 and budE[u.team] - e > 0 then
                budM[u.team], budE[u.team] = budM[u.team] - m, budE[u.team] - e
                spendM[u.team], spendE[u.team] = spendM[u.team] + m, spendE[u.team] + e
                T.spentBy.dragons = (T.spentBy.dragons or 0) + (u.setup >= 1 and m or 0)
                T.spentBy.sink_setup = (T.spentBy.sink_setup or 0) + (u.setup < 1 and m or 0)
                apply()
            else
                T.sink.stalled = T.sink.stalled + 1
            end
            pullM[u.team], pullE[u.team] = pullM[u.team] + m, pullE[u.team] + e
        else
        local t = units[u.work]
        local T = W.teams[u.team]
        local cls = u.bclass or BuilderClass(u)
        u.bclass = cls
        local bp = u.d.buildSpeed or 0
        u.used = 0
        if t and u.workKind == "build" and not t.built then
            local td = t.d
            local rate = bp / max(td.buildTime or 1, 1)              -- progress per second
            local remain = 1 - t.progress - (progress[t.id] or 0)
            if remain > 0 then
                local p = min(rate * dt, remain)
                local m = (td.metalCost or 0) <= 1 and 0 or (td.metalCost or 0) * p
                local e = (td.energyCost or 0) * p
                local okM = m <= 0 or budM[u.team] - m > 0
                local okE = e <= 0 or budE[u.team] - e > 0
                if okM and okE then
                    budM[u.team] = budM[u.team] - m
                    budE[u.team] = budE[u.team] - e
                    spendM[u.team] = spendM[u.team] + m
                    spendE[u.team] = spendE[u.team] + e
                    progress[t.id] = (progress[t.id] or 0) + p
                    u.used = p / (rate * dt)
                    LedgerAdd(T, cls, "build:" .. t.cat, bp * dt * u.used)
                    if u.used < 0.999 then LedgerAdd(T, cls, "overbuild", bp * dt * (1 - u.used)) end
                    T.spentBy[t.cat] = (T.spentBy[t.cat] or 0) + m
                else
                    LedgerAdd(T, cls, okM and "stall_e" or "stall_m", bp * dt)
                    if not okM then T.stallM = T.stallM + 1 end
                    if not okE then T.stallE = T.stallE + 1 end
                end
                pullM[u.team] = pullM[u.team] + m
                pullE[u.team] = pullE[u.team] + e
            else
                LedgerAdd(T, cls, "overbuild", bp * dt)
            end
        elseif t and u.workKind == "reclaim" then
            local rs = u.d.reclaimSpeed or bp
            local td = t.d
            local frac = rs / max(td.buildTime or 1, 1) * dt
            reclaimAmt[t.id] = (reclaimAmt[t.id] or 0) + frac
            LedgerAdd(T, cls, "reclaim", bp * dt)
            u.used = 1
        end
        end
    end
    for tid, p in pairs(progress) do
        local t = units[tid]
        if t then
            t.progress = t.progress + p
            if t.progress >= 0.99999 then
                Finish(t)
                if t.inFactory then
                    local fac = units[t.inFactory]
                    t.inFactory = nil
                    if fac then
                        if fac.fq[1] and -fac.fq[1].id == t.defID then table.remove(fac.fq, 1) end
                        fac.fbuild = nil
                        t.x = t.x + P.FACTORY_EXIT
                        HashMove(t)
                        W.callin("UnitFromFactory", t.id, t.defID, t.team, fac.id, fac.defID, false)
                    end
                end
            end
        end
    end
    for tid, frac in pairs(reclaimAmt) do
        local t = units[tid]
        if t then
            local T = W.teams[t.team]
            local before = t.progress
            if t.built then
                t.reclaimLeft = (t.reclaimLeft or 1) - frac
                if t.reclaimLeft <= 0 then
                    local back = (t.d.metalCost or 0)
                    T.metal = T.metal + back
                    T.mReclaimed = T.mReclaimed + back
                    W.Kill(t, "reclaimed")
                end
            else
                t.progress = before - frac
                local back = (t.d.metalCost or 0) * min(frac, before)
                T.metal = T.metal + back
                T.mReclaimed = T.mReclaimed + back
                if t.progress <= 0 then W.Kill(t, "reclaimed") end
            end
        end
    end

    -- 5. bank update
    for t = 0, 1 do
        local T = W.teams[t]
        T.metal = T.metal + T.mIncNow * dt - spendM[t]
        T.energy = T.energy + T.eIncNow * dt - spendE[t]
        T.mProduced = T.mProduced + T.mIncNow * dt
        T.eProduced = T.eProduced + T.eIncNow * dt
        T.mUsed = T.mUsed + spendM[t]
        T.eUsed = T.eUsed + spendE[t] + T.otherEPull * dt
        if T.metal > T.mStor then T.mWaste = T.mWaste + T.metal - T.mStor; T.metal = T.mStor end
        if T.energy > T.eStor then T.eWaste = T.eWaste + T.energy - T.eStor; T.energy = T.eStor end
        if T.metal < 0 then T.metal = 0 end
        if T.energy < 0 then T.energy = 0 end
        T.mInc, T.eInc = T.mIncNow, T.eIncNow
        T.mExp, T.eExp = spendM[t] / dt, spendE[t] / dt + T.otherEPull
        T.mPull, T.ePull = pullM[t] / dt, pullE[t] / dt + T.otherEPull
        T.steps = T.steps + 1
    end

    -- 6. ledger of builders that did not work this step
    for i = 1, #ids do
        local u = units[ids[i]]
        if u and u.built and u.isBuilder and u.team == W.myTeam and not u.d.isFactory then
            if not (u.work and units[u.work]) or not u.active then
                local cls = u.bclass or BuilderClass(u)
                u.bclass = cls
                u.used = 0
                local bp = (u.d.buildSpeed or 0) * dt
                local T = W.teams[u.team]
                local k
                if not u.active then k = "off"
                elseif u.moving then k = "travel"
                elseif #u.cmds == 0 then k = "idle"
                else k = u.state or ("wait_" .. tostring(u.cmds[1].id)) end
                LedgerAdd(T, cls, k, bp)
            end
        elseif u and u.built and u.d.isFactory and u.team == W.myTeam and not u.work then
            LedgerAdd(W.teams[u.team], "fac", "idle", (u.d.buildSpeed or 0) * dt)
        end
    end
end

return W
