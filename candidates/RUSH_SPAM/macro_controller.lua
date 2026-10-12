-- RUSH_SPAM macro: a deliberately dumb economy.  Mex on every nearby metal spot, wind turbines
-- everywhere, a bot lab first, then more vehicle plants (up to MAX_VP) with nano turrets beside the
-- factories.  Every constructor (commander + con bots) takes the next task whenever it is idle.
-- Modelled on a human's "paintkid" game (mex + wind spam, nanos, 1 bot lab + 6 vehicle plants on
-- repeat).  Cortex only (the harness gives both teams Cortex).

local widget = widget
local Spring = Spring

function widget:GetInfo()
    return {
        name = "Macro Controller", desc = "RUSH_SPAM economy + factory spam (COR)",
        author = "", date = "2026", license = "GNU GPL, v3 or later", layer = 0, enabled = true,
    }
end

-- ── Tunables ──────────────────────────────────────────────────────────────────
local MEX_RADIUS    = 1000   -- metal spots within this of the commander are used
local MEX_LATTICE   = 160    -- mex spacing when metal is everywhere
local MAX_VP        = 5      -- vehicle plants besides the bot lab
local WIND_PER_MEX  = 2.5    -- wind target per mex
local WIND_PER_FAC  = 4      -- extra wind per factory
local NANOS_PER_FAC = 3
local FAC_RING      = 260    -- factories sit on a ring this far from the commander start
local WIND_RADIUS   = 900    -- wind lattice extends this far from the base
local VP_PER_INCOME = 12     -- one more vehicle plant per this much metal income/s
local TICK          = 15     -- frames between idle checks

local DEBUG = false
local ORDER_GRACE = 75   -- orders take ~30 frames to land; don't re-poll a builder before then
local lastOrder = {}
local spGiveOrder = Spring.GiveOrderToUnit

local myTeam, baseX, baseZ
local defs = {}              -- name -> defID
local cons = {}              -- constructor unitID -> true
local pending = {}           -- builder unitID -> {name=, spot=} while it still has its order
local live = {}              -- name -> units alive (including unfinished)
local mexSpots = {}          -- {x=, z=, taken=bool}
local windSites, windIdx = {}, 0
local facIdx = 0
local facs = {}              -- factory unitID -> {x=, z=, nanos=}
local started = false

local function Def(n) local d = UnitDefNames[n]; return d and d.id end
local function Dist2(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return dx * dx + dz * dz end
local function Snap(v) return math.floor(v / 16 + 0.5) * 16 end

local function CanBuild(defID, x, z)
    local r = Spring.TestBuildOrder(defID, x, Spring.GetGroundHeight(x, z), z, 0)
    return r ~= nil and r >= 1
end

-- ── Metal spots: scan the metal map, cluster lit cells ────────────────────────
local function FindMexSpots()
    local spots, step = {}, 32
    local x0, x1 = math.max(0, baseX - MEX_RADIUS), math.min(Game.mapSizeX, baseX + MEX_RADIUS)
    local z0, z1 = math.max(0, baseZ - MEX_RADIUS), math.min(Game.mapSizeZ, baseZ + MEX_RADIUS)
    for x = x0, x1, step do
        for z = z0, z1, step do
            local m = Spring.GetMetalAmount(math.floor(x / 16), math.floor(z / 16))
            if m and m > 0 then
                local joined = false
                for _, s in ipairs(spots) do
                    if Dist2(x, z, s.x, s.z) < 96 * 96 then
                        s.n = s.n + 1
                        s.x = s.x + (x - s.x) / s.n
                        s.z = s.z + (z - s.z) / s.n
                        joined = true
                        break
                    end
                end
                if not joined then spots[#spots + 1] = { x = x, z = z, n = 1 } end
            end
        end
    end
    if #spots > 60 then
        -- metal everywhere (Full Metal Plate): a mex works on any tile, so use a sparse lattice
        spots = {}
        for gx = -MEX_RADIUS, MEX_RADIUS, MEX_LATTICE do
            for gz = -MEX_RADIUS, MEX_RADIUS, MEX_LATTICE do
                local x, z = Snap(baseX + gx), Snap(baseZ + gz)
                if Dist2(x, z, baseX, baseZ) > 100 * 100 and x > 64 and z > 64
                    and x < Game.mapSizeX - 64 and z < Game.mapSizeZ - 64 then
                    spots[#spots + 1] = { x = x, z = z, n = 1 }
                end
            end
        end
    end
    for _, s in ipairs(spots) do s.x, s.z = Snap(s.x), Snap(s.z) end
    return spots
end

-- Wind lattice: every 64 elmos around the base, nearest first, skipping the base itself.
local function BuildWindSites()
    local sites = {}
    for gx = -WIND_RADIUS, WIND_RADIUS, 64 do
        for gz = -WIND_RADIUS, WIND_RADIUS, 64 do
            local x, z = Snap(baseX + gx), Snap(baseZ + gz)
            local d = Dist2(x, z, baseX, baseZ)
            local onMetal = false
            for _, m in ipairs(mexSpots) do
                if Dist2(x, z, m.x, m.z) < 90 * 90 then onMetal = true; break end
            end
            if not onMetal and d > 140 * 140 and d < WIND_RADIUS * WIND_RADIUS
                and x > 64 and z > 64 and x < Game.mapSizeX - 64 and z < Game.mapSizeZ - 64 then
                sites[#sites + 1] = { x = x, z = z, d = d }
            end
        end
    end
    table.sort(sites, function(a, b) return a.d < b.d end)
    return sites
end

local function NextWindSite()
    for _ = 1, 60 do
        windIdx = windIdx + 1
        local s = windSites[windIdx]
        if not s then windIdx = 0; return end
        if CanBuild(defs.corwin, s.x, s.z) then return s.x, s.z end
    end
end

local function NextFactorySite(defID)
    for _ = 1, 40 do
        facIdx = facIdx + 1
        local a = facIdx * 2.39996
        local r = FAC_RING + 40 * math.floor(facIdx / 8)
        local x, z = Snap(baseX + r * math.cos(a)), Snap(baseZ + r * math.sin(a))
        if CanBuild(defID, x, z) then return x, z end
    end
end

local function NextNanoSite()
    local best
    for _, f in pairs(facs) do
        if f.nanos < NANOS_PER_FAC and (not best or f.nanos < best.nanos) then best = f end
    end
    if not best then return end
    best.nanos = best.nanos + 1
    for i = 1, 12 do
        local a = (best.nanos * 2 + i) * 0.9
        local x, z = Snap(best.x + 110 * math.cos(a)), Snap(best.z + 110 * math.sin(a))
        if CanBuild(defs.cornanotc, x, z) then return x, z end
    end
end

local function NextMexSpot(bx, bz)
    local best, bd
    for _, s in ipairs(mexSpots) do
        if not s.taken then
            local d = Dist2(s.x, s.z, bx, bz)
            if not bd or d < bd then best, bd = s, d end
        end
    end
    return best
end

-- ── Task choice ───────────────────────────────────────────────────────────────
local function Count(name)
    local n = live[name] or 0
    for _, p in pairs(pending) do if p.name == name then n = n + 1 end end
    return n
end

local function Income()
    local _, _, _, inc = Spring.GetTeamResources(myTeam, "metal")
    return inc or 0
end

-- Returns name, x, z, spot (the metal spot claimed, if any).
local function ChooseTask(bx, bz)
    local nMex = Count("cormex")
    local nFac = Count("corlab") + Count("corvp")
    local function mex()
        local s = NextMexSpot(bx, bz)
        if s then return "cormex", s.x, s.z, s end
    end
    local function wind()
        local x, z = NextWindSite()
        if x then return "corwin", x, z end
    end
    local function fac(name)
        local x, z = NextFactorySite(defs[name])
        if x then return name, x, z end
    end
    local r1, r2, r3, r4
    -- opening: a few mex and wind, then the bot lab
    if nMex < math.min(3, #mexSpots) then r1, r2, r3, r4 = mex(); if r1 then return r1, r2, r3, r4 end end
    if Count("corwin") < 3 then r1, r2, r3 = wind(); if r1 then return r1, r2, r3 end end
    if Count("corlab") < 1 then r1, r2, r3 = fac("corlab"); if r1 then return r1, r2, r3 end end
    -- keep wind ahead of what the mex and factories want
    if Count("corwin") < nMex * WIND_PER_MEX + nFac * WIND_PER_FAC then
        r1, r2, r3 = wind(); if r1 then return r1, r2, r3 end
    end
    -- more plants as income allows, nanos beside each
    local vpWant = math.min(MAX_VP, 1 + math.floor(Income() / VP_PER_INCOME))
    if Count("corvp") < vpWant then r1, r2, r3 = fac("corvp"); if r1 then return r1, r2, r3 end end
    if Count("cornanotc") < NANOS_PER_FAC * nFac then
        local x, z = NextNanoSite(); if x then return "cornanotc", x, z end
    end
    r1, r2, r3, r4 = mex(); if r1 then return r1, r2, r3, r4 end
    -- nothing else useful: more wind
    return wind()
end

-- Busy only while its first command is a build order: BAR's stock widgets hand fresh con bots
-- a repair/assist order, which would otherwise make them look permanently busy.
local function Building(uid)
    local cmds = Spring.GetUnitCommands(uid, 1)
    return cmds and cmds[1] and cmds[1].id < 0
end

local function GiveTask(uid)
    local x, _, z = Spring.GetUnitPosition(uid)
    if not x then return end
    local name, tx, tz, spot = ChooseTask(x, z)
    if not name then
        if DEBUG then Spring.Echo("[RUSH] no task for " .. uid) end
        return
    end
    if DEBUG then Spring.Echo(string.format("[RUSH] task %d %s %d,%d", uid, name, tx, tz)) end
    if spot then spot.taken = true; spot.tries = (spot.tries or 0) + 1 end
    pending[uid] = { name = name, spot = spot }
    spGiveOrder(uid, -defs[name], { tx, Spring.GetGroundHeight(tx, tz), tz, 0 }, {})
end

-- ── Callbacks ─────────────────────────────────────────────────────────────────
function widget:Initialize()
    myTeam = Spring.GetMyTeamID()
    for _, n in ipairs({ "cormex", "corwin", "corlab", "corvp", "cornanotc" }) do defs[n] = Def(n) end
end

local function Start()
    for _, uid in ipairs(Spring.GetTeamUnits(myTeam)) do
        local ud = UnitDefs[Spring.GetUnitDefID(uid)]
        if ud and ud.customParams and ud.customParams.iscommander then
            local x, _, z = Spring.GetUnitPosition(uid)
            baseX, baseZ = x, z
            cons[uid] = true
        end
    end
    if not baseX then return end
    mexSpots = FindMexSpots()
    windSites = BuildWindSites()
    started = true
    Spring.Echo(string.format("[RUSH] base %d,%d  metal spots %d  wind sites %d",
        baseX, baseZ, #mexSpots, #windSites))
end

local function NoteFactory(uid)
    if facs[uid] then return end
    local x, _, z = Spring.GetUnitPosition(uid)
    if x then facs[uid] = { x = x, z = z, nanos = 0 } end
end

function widget:UnitCreated(uid, defID, team)
    if team == myTeam and UnitDefs[defID].isFactory then NoteFactory(uid) end
end

function widget:UnitFinished(uid, defID, team)
    if team ~= myTeam then return end
    local ud = UnitDefs[defID]
    if DEBUG then Spring.Echo(string.format("[RUSH] finished %s builder=%s move=%s", ud.name, tostring(ud.isBuilder), tostring(ud.canMove))) end
    if ud.isFactory then NoteFactory(uid)
    elseif ud.isBuilder and ud.canMove then cons[uid] = true end
end

function widget:UnitDestroyed(uid, defID, team)
    local p = pending[uid]
    if p and p.spot then p.spot.taken = false end
    cons[uid] = nil; pending[uid] = nil; facs[uid] = nil
end

-- Recount live structures; free metal spots whose mex was lost.
local function Reconcile()
    live = {}
    local mexAt = {}
    for _, uid in ipairs(Spring.GetTeamUnits(myTeam)) do
        local nm = UnitDefs[Spring.GetUnitDefID(uid)].name
        live[nm] = (live[nm] or 0) + 1
        if nm == "cormex" then
            local x, _, z = Spring.GetUnitPosition(uid)
            mexAt[#mexAt + 1] = { x, z }
        end
    end
    local claimed = {}
    for _, p in pairs(pending) do if p.spot then claimed[p.spot] = true end end
    for _, s in ipairs(mexSpots) do
        local has = false
        for _, m in ipairs(mexAt) do
            if Dist2(m[1], m[2], s.x, s.z) < 64 * 64 then has = true; break end
        end
        if has then s.tries = 0 end
        s.taken = has or claimed[s] or (s.tries or 0) >= 3   -- 3 orders and still no mex: give up on it
    end
end

function widget:GameFrame(n)
    if not started then
        if n >= 5 then Start() end
        return
    end
    if n % TICK ~= 0 then return end
    if n % 30 == 0 then Reconcile() end
    if DEBUG and n % 900 == 0 then
        local info = {}
        for uid in pairs(cons) do
            local cmds = Spring.GetUnitCommands(uid, 1)
            info[#info + 1] = string.format("%d:q%d:%s", uid, Spring.GetUnitCommands(uid, 0) or -1,
                cmds and cmds[1] and tostring(cmds[1].id) or "-")
        end
        Spring.Echo("[RUSH] cons " .. table.concat(info, " "))
    end
    if n % 1800 == 0 then
        Spring.Echo(string.format("[RUSH] %d:%02d mex %d wind %d lab %d vp %d nano %d cons %d inc %.0f",
            math.floor(n / 1800), 0, live.cormex or 0, live.corwin or 0, live.corlab or 0, live.corvp or 0,
            live.cornanotc or 0, live.corck or 0, Income()))
    end
    for uid in pairs(cons) do
        if n - (lastOrder[uid] or -999) > ORDER_GRACE and not Building(uid) then
            lastOrder[uid] = n
            pending[uid] = nil
            GiveTask(uid)
        end
    end
end
