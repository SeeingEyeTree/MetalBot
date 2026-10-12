-- bar_framework/defense_crew.lua   (LINE_CLICK_v16)
-- Structures the grids never build on their own: anti-air (flak) when bombers are coming, anti-nuke
-- launchers, and nuke silos -- plus stockpiling for the last two and firing our own missiles.
--
-- It gives no orders to factories.  A builder is borrowed by INSERTING one build command at the front of its
-- queue (CMD.INSERT, position 0), so whatever it was doing resumes afterwards.  Orders are tracked and re-issued
-- if another widget overwrote them.
--
-- USAGE (two widgets use it, each for its own half):
--   macro_controller:  DC.Init{teamID=..}; DC.Update(frame, mb)          -- builds + stockpiles
--   unit_controller:   DC.Init{teamID=..}; DC.Fire(frame, targets, EI)    -- fires our silos
-- `mb` is WG.MetalBot: mb.airAlarm = {frame, n, x, z}, mb.intel (airValue, airLabs, silos), mb.homeX/homeZ.

local M = {}

-- â”€â”€ Tunables â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

M.BUILD_AA          = true    -- false: no loose flak/AA (the slot-spine bots build none for now)
M.BUILD_ANTINUKE    = true    -- false: no loose anti-nukes (they are grid capstones: line_transition ANTINUKE_GRIDS);
                              -- anti-nukes that stand are still stockpiled and helped
M.PERIOD            = 60      -- frames between build passes
M.ALARM_TTL         = 900     -- an air alarm counts for this long after its last sighting
M.AA_NAMES          = { "corflak", "corrl" }   -- flak first (T2 builders), the T1 Defender otherwise
M.AA_BASE           = 2       -- once the enemy has any air at all
M.AA_PER_AIR_VALUE  = 400     -- ...plus one per this much remembered enemy air value
M.AA_BASE_MAX       = 8
M.AA_ALARM_BONUS    = 4       -- extra the moment bombers are heading for us
M.AA_ALARM_MIN      = 6
M.AA_MAX            = 14
M.AA_RING_MIN       = 110     -- AA sits this far from a factory / the commander...
M.AA_RING_MAX       = 420     -- ...and at most this far
M.ANTINUKE_NAME     = "corfmd"
M.MOBILE_ANTINUKE   = "cormabm"   -- Savior, built by the lab controller from a T2 vehicle plant (spine bots)
M.ANTINUKE_INCOME   = 350     -- metal/s before the first anti-nuke (about the T2 economy)
M.ANTINUKE_SECOND   = 1200    -- ...the second
M.ANTINUKE_STOCK    = 3       -- missiles kept stockpiled/queued
M.SILO_NAME         = "corsilo"
M.SILO_INCOME       = 700     -- metal/s before the first silo
M.SILO_SECOND       = 1800
M.SILO_STOCK        = 2
M.ORDER_FAIL_FRAMES = 2400    -- a build order that never produced a structure is dropped after this
M.REISSUE_AFTER     = 90      -- frames before a vanished order is re-sent
M.NUKE_INTERVAL     = 600     -- frames between launches
M.NUKE_CLUSTER_R    = 650     -- targets this close count as one cluster
M.NUKE_MIN_VALUE    = 1500    -- cluster value (metal + energy/70 of eco/build power) worth a missile
M.NUKE_MIN_HOME     = 2500    -- never aim closer to our own base than this

-- â”€â”€ State â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local myTeamID
local tasks = {}        -- [key] = { pending = {builder, defID, x, z, frame, tries}, fails = {} }
local lastNuke = -1e9
local lastLog = {}

local CMD_INSERT    = (CMD and CMD.INSERT) or 1
local CMD_ATTACK    = (CMD and CMD.ATTACK) or 20
local CMD_STOCKPILE = (CMD and CMD.STOCKPILE) or 100

function M.Init(opts) myTeamID = opts.teamID; M.WG = opts.WG end

local function Clock(frame) return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

local function Log(key, frame, text)
    if lastLog[key] == text then return end
    lastLog[key] = text
    Spring.Echo("[DC] " .. Clock(frame) .. " " .. text)
end

local function DefID(name)
    local d = UnitDefNames and UnitDefNames[name]
    return d and d.id
end

local function IsDone(uid)
    local _, _, _, _, build = Spring.GetUnitHealth(uid)
    return build == nil or build >= 1
end

-- Our finished + unfinished structures of any of these defs.
local function CountOf(names)
    local ids = {}
    for _, n in ipairs(names) do local id = DefID(n); if id then ids[#ids + 1] = id end end
    if #ids == 0 then return 0, {} end
    local units = Spring.GetTeamUnitsByDefs(myTeamID, ids) or {}
    return #units, units
end

local function CanBuild(builderDef, defID)
    local d = UnitDefs[builderDef]
    if not d or not d.buildOptions then return false end
    for _, o in ipairs(d.buildOptions) do if o == defID then return true end end
    return false
end

-- Free spot near (ax, az): rings from minR out to maxR, 8 bearings each, starting at `bearing`.
local function FindSite(defID, ax, az, minR, maxR, bearing, fails)
    local step = 60
    for r = minR, maxR, step do
        for k = 0, 15 do
            local a = (bearing or 0) + k * math.pi / 8
            local x, z = ax + math.cos(a) * r, az + math.sin(a) * r
            local key = math.floor(x / 40) .. ":" .. math.floor(z / 40)
            if not fails[key] then
                local y = Spring.GetGroundHeight(x, z) or 0
                local ok = Spring.TestBuildOrder(defID, x, y, z, 0)
                if ok == 3 or ok == 1 then return x, y, z, key end
            end
        end
    end
end

-- The nearest of our idle-or-busy constructors that can build defID.
local function PickBuilder(defID, x, z)
    local best, bestD, bestDef
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        local bd = Spring.GetUnitDefID(uid)
        local d = bd and UnitDefs[bd]
        if d and d.isBuilder and not d.isFactory and (d.speed or 0) > 0 and not (d.customParams and d.customParams.iscommander)
           and IsDone(uid) and CanBuild(bd, defID) then
            local ux, _, uz = Spring.GetUnitPosition(uid)
            if ux then
                local dist = (ux - x) ^ 2 + (uz - z) ^ 2
                -- Prefer a constructor with nothing queued: it costs the economy nothing.
                local q = Spring.GetUnitCommands(uid, 1)
                if q and #q > 0 then dist = dist + 1e12 end   -- any idle constructor beats any busy one
                if not bestD or dist < bestD then best, bestD, bestDef = uid, dist, bd end
            end
        end
    end
    return best
end

local function OrderBuild(builder, defID, x, y, z)
    local q = Spring.GetUnitCommands(builder, 1)
    if not q or #q == 0 then
        Spring.GiveOrderToUnit(builder, -defID, { x, y, z, 0 }, {})      -- idle: an ordinary build order
    else
        -- Busy: CMD.INSERT at the front was dropped in testing (the grids' placer rewrites its constructors'
        -- queues), so append: it runs when the constructor's current job is done.
        Spring.GiveOrderToUnit(builder, -defID, { x, y, z, 0 }, { "shift" })
    end
end

local function HasOrder(builder, defID)
    local q = Spring.GetUnitCommands(builder, 12)
    if not q then return false end
    for _, c in ipairs(q) do if c.id == -defID then return true end end
    return false
end

-- Make sure `want` structures from `names` exist near the anchors.  anchors = list of {x, z, bearing}.
local function Ensure(key, frame, names, want, anchors, minR, maxR)
    local t = tasks[key]
    if not t then t = { fails = {} }; tasks[key] = t end
    local have = CountOf(names)
    local p = t.pending
    if p then
        if have > (p.have or 0) or frame - p.frame > M.ORDER_FAIL_FRAMES or not Spring.GetUnitDefID(p.builder) then
            if have <= (p.have or 0) then t.fails[p.key] = true end
            t.pending = nil
        elseif frame - p.frame > M.REISSUE_AFTER and not HasOrder(p.builder, p.defID) then
            -- Another widget replaced the order (the grids' placer re-issues its constructors' queues).
            p.tries = (p.tries or 0) + 1
            if p.tries > 4 then
                local q = Spring.GetUnitCommands(p.builder, 3) or {}
                local ids = {}
                for _, c in ipairs(q) do ids[#ids + 1] = tostring(c.id) end
                local bd = UnitDefs[Spring.GetUnitDefID(p.builder) or 0]
                Log(key, frame, string.format("%s: builder %d (%s, queue %s) keeps losing the order, trying elsewhere",
                    key, p.builder, bd and bd.name or "?", table.concat(ids, ",")))
                t.fails[p.key] = true; t.pending = nil
            else
                local y = Spring.GetGroundHeight(p.x, p.z) or 0
                OrderBuild(p.builder, p.defID, p.x, y, p.z)
                p.frame = frame
            end
        end
        return have
    end
    if have >= want or #anchors == 0 then return have end
    for _, name in ipairs(names) do
        local defID = DefID(name)
        if defID then
            -- Start at a different anchor each time, and fall through to the next if this one is built up.
            local x, y, z, skey
            for i = 0, #anchors - 1 do
                local anchor = anchors[((have + i) % #anchors) + 1]
                x, y, z, skey = FindSite(defID, anchor.x, anchor.z, minR, maxR, anchor.bearing, t.fails)
                if x then break end
            end
            if not x then
                Log(key .. name .. "-nosite", frame, string.format("%s: no free site for %s near any of %d anchors", key, name, #anchors))
            else
                local builder = PickBuilder(defID, x, z)
                if not builder then
                    Log(key .. "-nobuilder", frame, string.format("%s: no constructor can build %s", key, name))
                end
                if builder then
                    OrderBuild(builder, defID, x, y, z)
                    t.pending = { builder = builder, defID = defID, x = x, z = z, frame = frame, key = skey, have = have }
                    Log(key, frame, string.format("%s: ordering %s at %d,%d (have %d / want %d)", key, name, x, z, have, want))
                    return have
                end
            end
        end
    end
    return have
end

-- â”€â”€ Anchors â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

-- Factories first (what a bomber run is after), then the commander, then home.
local function Anchors(mb, bearing)
    local out = {}
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or 0]
        if d and (d.isFactory or (d.customParams and d.customParams.iscommander)) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then out[#out + 1] = { x = x, z = z, bearing = bearing, v = d.isFactory and 1 or 2 } end
        end
    end
    table.sort(out, function(a, b) if a.v ~= b.v then return a.v < b.v end return a.x < b.x end)
    if #out == 0 and mb and mb.homeX then out[1] = { x = mb.homeX, z = mb.homeZ, bearing = bearing } end
    return out
end

-- â”€â”€ Stockpile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function Stockpile(names, wanted)
    local _, units = CountOf(names)
    for _, uid in ipairs(units) do
        if IsDone(uid) and Spring.GetUnitStockpile then
            local have, queued = Spring.GetUnitStockpile(uid)
            local total = (have or 0) + (queued or 0)
            for _ = total + 1, wanted do
                Spring.GiveOrderToUnit(uid, CMD_STOCKPILE, {}, {})
            end
        end
    end
end

-- â”€â”€ Update â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

-- Big structures (silo, anti-nuke) take minutes with one constructor: idle constructors help.
M.ASSIST_MAX = 8
local CMD_REPAIR = (CMD and CMD.REPAIR) or 40
local function Assist(names)
    local _, units = CountOf(names)
    for _, target in ipairs(units) do
        if not IsDone(target) then
            local tx, _, tz = Spring.GetUnitPosition(target)
            local helpers = 0
            for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
                if helpers >= M.ASSIST_MAX then break end
                local d = UnitDefs[Spring.GetUnitDefID(uid) or 0]
                if d and d.isBuilder and not d.isFactory and (d.speed or 0) > 0 and (d.buildSpeed or 0) >= 50
                   and not (d.customParams and d.customParams.iscommander) then
                    local q = Spring.GetUnitCommands(uid, 1)
                    local ux, _, uz = Spring.GetUnitPosition(uid)
                    if tx and ux and (not q or #q == 0) and (ux - tx) ^ 2 + (uz - tz) ^ 2 <= 2500 ^ 2 then
                        Spring.GiveOrderToUnit(uid, CMD_REPAIR, { target }, {})
                        helpers = helpers + 1
                    end
                end
            end
        end
    end
end

-- ── Anti-nuke cover (M.COVER, spine bots) ───────────────────────────────────────────────────────────────────────────
-- Saviors (cormabm, mobile) are spread so that every cluster of our eco / build power is inside an interceptor's
-- coverage.  A point a Savior cannot walk to (no path: it makes no progress) gets a corfmd built there by a T2 con instead.
M.COVER            = true
M.COVER_PERIOD     = 300      -- frames between re-plans
M.COVER_MAX        = 8        -- cover points (= Saviors + anti-nukes) at most
M.COVER_FRAC       = 0.85     -- share of the interceptor's radius used for the plan
M.COVER_CELL       = 240      -- structures are bucketed into cells this wide before the cover is planned
M.COVER_STUCK      = 1200     -- frames a Savior may take without getting closer before its point counts as unreachable
M.COVER_FALLBACK_R = { cormabm = 1200, corfmd = 2000 }
local cover = { goal = {}, blocked = {}, last = -1e9, points = {} }
local CMD_MOVE = (CMD and CMD.MOVE) or 10

-- Coverage radius of an anti-nuke def (weapon coverageRange, else the fallback table).
local function CoverRadius(name)
    local d = UnitDefNames and UnitDefNames[name]
    if d and d.weapons and WeaponDefs then
        for _, w in ipairs(d.weapons) do
            local wd = WeaponDefs[w.weaponDef or w.weaponDefID or -1]
            if wd and (wd.coverageRange or 0) > 0 then return wd.coverageRange end
        end
    end
    return M.COVER_FALLBACK_R[name] or 1200
end

-- items = { {x =, z =, w =}, ... } -> up to maxN centres {x, z, w} (w = weight covered) that cover as much weight as
-- possible within radius R: greedy, each pick the cell centre covering the most uncovered weight, then re-centred on
-- the weighted mean of what it covers.  Pure.
function M.CoverPoints(items, R, maxN, cell)
    cell = cell or M.COVER_CELL
    local cells, list = {}, {}
    for _, it in ipairs(items) do
        local k = math.floor(it.x / cell) .. ":" .. math.floor(it.z / cell)
        local c = cells[k]
        if not c then c = { x = 0, z = 0, w = 0 }; cells[k] = c; list[#list + 1] = c end
        c.x, c.z, c.w = c.x + it.x * it.w, c.z + it.z * it.w, c.w + it.w
    end
    for _, c in ipairs(list) do c.x, c.z = c.x / c.w, c.z / c.w end
    local out, r2 = {}, R * R
    while #out < maxN do
        local best, bestW
        for _, c in ipairs(list) do
            if not c.done then
                local w = 0
                for _, o in ipairs(list) do
                    if not o.done and (o.x - c.x) ^ 2 + (o.z - c.z) ^ 2 <= r2 then w = w + o.w end
                end
                if not bestW or w > bestW then best, bestW = c, w end
            end
        end
        if not best then break end
        local sx, sz, sw = 0, 0, 0
        for _, o in ipairs(list) do
            if not o.done and (o.x - best.x) ^ 2 + (o.z - best.z) ^ 2 <= r2 then
                o.done = true
                sx, sz, sw = sx + o.x * o.w, sz + o.z * o.w, sw + o.w
            end
        end
        out[#out + 1] = { x = sx / sw, z = sz / sw, w = sw }
    end
    return out
end

local function CoverItems()
    local items = {}
    for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or 0]
        if d and (d.speed or 0) == 0 and IsDone(uid)
           and ((d.extractsMetal or 0) > 0 or d.isFactory or d.isBuilder or (d.energyMake or 0) >= 200) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then items[#items + 1] = { x = x, z = z, w = d.metalCost or 50 } end
        elseif d and d.customParams and d.customParams.iscommander then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then items[#items + 1] = { x = x, z = z, w = 1500 } end
        end
    end
    return items
end

local function KeyOf(p) return math.floor(p.x / 400) .. ":" .. math.floor(p.z / 400) end

local function CoverUpdate(frame, income, silosSeen)
    if frame - cover.last < M.COVER_PERIOD then return end
    cover.last = frame
    local G = M.WG
    if not G then return end
    G.AntiNuke = G.AntiNuke or {}
    if income < M.ANTINUKE_INCOME and not silosSeen then G.AntiNuke.saviorWant = 0; return end
    local R = CoverRadius(M.MOBILE_ANTINUKE) * M.COVER_FRAC
    local points = M.CoverPoints(CoverItems(), R, M.COVER_MAX)
    cover.points = points
    -- standing corfmd cover the points near them
    local fmdID, savID = DefID(M.ANTINUKE_NAME), DefID(M.MOBILE_ANTINUKE)
    local fixed, savs = {}, {}
    if fmdID then
        for _, uid in ipairs(Spring.GetTeamUnitsByDefs(myTeamID, { fmdID }) or {}) do
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then fixed[#fixed + 1] = { x = x, z = z, R = CoverRadius(M.ANTINUKE_NAME) * M.COVER_FRAC } end
        end
    end
    if savID then
        for _, uid in ipairs(Spring.GetTeamUnitsByDefs(myTeamID, { savID }) or {}) do
            if IsDone(uid) then savs[#savs + 1] = uid end
        end
    end
    local function Served(p)
        for _, f in ipairs(fixed) do
            if (f.x - p.x) ^ 2 + (f.z - p.z) ^ 2 <= (0.5 * f.R) ^ 2 then return true end
        end
        return false
    end
    local taken, want = {}, 0
    for _, p in ipairs(points) do
        if not Served(p) then
            local key = KeyOf(p)
            if cover.blocked[key] then
                -- unreachable on foot: an anti-nuke is built there by a T2 con
                Ensure("cover", frame, { M.ANTINUKE_NAME }, #fixed + 1, { { x = p.x, z = p.z, bearing = 0 } }, 0, 360)
                Assist({ M.ANTINUKE_NAME })
            else
                want = want + 1
                -- a Savior already heading for (or standing at) this point keeps it; else the nearest free one takes it
                local mine
                for _, uid in ipairs(savs) do
                    local g = cover.goal[uid]
                    if not taken[uid] and g and (g.x - p.x) ^ 2 + (g.z - p.z) ^ 2 <= (0.5 * R) ^ 2 then mine = uid; break end
                end
                if not mine then
                    local bd
                    for _, uid in ipairs(savs) do
                        if not taken[uid] and not cover.goal[uid] then
                            local x, _, z = Spring.GetUnitPosition(uid)
                            local dd = x and (x - p.x) ^ 2 + (z - p.z) ^ 2
                            if dd and (not bd or dd < bd) then mine, bd = uid, dd end
                        end
                    end
                    if mine then
                        cover.goal[mine] = { x = p.x, z = p.z, key = key, best = math.sqrt(bd), at = frame }
                        Spring.GiveOrderToUnit(mine, CMD_MOVE, { p.x, Spring.GetGroundHeight(p.x, p.z) or 0, p.z }, {})
                        Log("cover" .. mine, frame, string.format("cover: Savior %d -> (%d, %d)", mine, p.x, p.z))
                    end
                end
                if mine then
                    taken[mine] = true
                    local g = cover.goal[mine]
                    local x, _, z = Spring.GetUnitPosition(mine)
                    local dist = x and math.sqrt((x - g.x) ^ 2 + (z - g.z) ^ 2) or 0
                    if dist < g.best - 100 then
                        g.best, g.at = dist, frame
                    elseif dist > 350 and frame - g.at > M.COVER_STUCK then
                        cover.blocked[g.key] = true
                        cover.goal[mine] = nil
                        want = want - 1
                        Log("coverblk" .. g.key, frame, string.format(
                            "cover: no path to (%d, %d); an anti-nuke is built there instead", g.x, g.z))
                    elseif dist > 150 and frame - g.at > 300 then
                        Spring.GiveOrderToUnit(mine, CMD_MOVE, { g.x, Spring.GetGroundHeight(g.x, g.z) or 0, g.z }, {})
                    end
                end
            end
        end
    end
    for uid in pairs(cover.goal) do if not Spring.GetUnitDefID(uid) then cover.goal[uid] = nil end end
    G.AntiNuke.saviorWant = math.max(0, want)          -- Saviors wanted: points nothing fixed serves and that are reachable
    G.AntiNuke.points = #points
    local nBlocked = 0
    for _ in pairs(cover.blocked) do nBlocked = nBlocked + 1 end
    Log("coverplan", frame, string.format("cover plan: %d points, %d fixed anti-nukes, %d Saviors wanted (%d standing), %d unreachable",
        #points, #fixed, want, #savs, nBlocked))
end

function M.Update(frame, mb)
    if not myTeamID or frame % M.PERIOD ~= 0 or not mb then return end
    local _, _, _, income = Spring.GetTeamResources(myTeamID, "metal")
    income = income or 0
    local intel = mb.intel or {}
    local alarm = mb.airAlarm
    local alarmOn = alarm and frame - (alarm.frame or -1e9) <= M.ALARM_TTL

    -- Anti-air.  Facing the bombers: put the first ring on the side they come from.
    local bearing = 0
    if alarmOn and mb.homeX and alarm.x then
        bearing = math.atan2(alarm.z - mb.homeZ, alarm.x - mb.homeX)
    elseif mb.axisX then
        bearing = math.atan2(mb.axisZ, mb.axisX)
    end
    local wantAA = 0
    if (intel.airValue or 0) > 0 or (intel.airLabs or 0) > 0 then
        wantAA = math.min(M.AA_BASE_MAX, M.AA_BASE + math.floor((intel.airValue or 0) / M.AA_PER_AIR_VALUE))
    end
    if alarmOn then
        wantAA = math.min(M.AA_MAX, math.max(M.AA_ALARM_MIN, wantAA + M.AA_ALARM_BONUS))
    end
    if wantAA > 0 and M.BUILD_AA then
        Ensure("aa", frame, M.AA_NAMES, wantAA, Anchors(mb, bearing), M.AA_RING_MIN, M.AA_RING_MAX)
    end

    -- Anti-nuke: from a T2 economy on, sooner if we have seen an enemy silo.
    local silosSeen = (intel.silos or 0) > 0
    local wantAN = 0
    if income >= M.ANTINUKE_INCOME or silosSeen then wantAN = 1 end
    if income >= M.ANTINUKE_SECOND or (silosSeen and income >= M.ANTINUKE_INCOME) then wantAN = 2 end
    if M.COVER and not M.BUILD_ANTINUKE then
        local okC, errC = pcall(CoverUpdate, frame, income, silosSeen)
        if not okC then Log("covererr", frame, "cover error: " .. tostring(errC)) end
    end
    if wantAN > 0 and M.BUILD_ANTINUKE then
        Ensure("antinuke", frame, { M.ANTINUKE_NAME }, wantAN, Anchors(mb, bearing), 250, 1100)
    end
    if wantAN > 0 or not M.BUILD_ANTINUKE then
        Stockpile({ M.ANTINUKE_NAME, M.MOBILE_ANTINUKE }, M.ANTINUKE_STOCK)   -- the Savior (cormabm) is a mobile anti-nuke
        Assist({ M.ANTINUKE_NAME })
    end

    -- Silos: a late-game option; the economy has to be far past needing the metal for something else.
    local wantSilo = 0
    if income >= M.SILO_INCOME then wantSilo = 1 end
    if income >= M.SILO_SECOND then wantSilo = 2 end
    if wantSilo > 0 then
        Ensure("silo", frame, { M.SILO_NAME }, wantSilo, Anchors(mb, bearing + math.pi), 300, 1500)
    end
    -- Silos that exist (grid capstones from line_transition, or the loose ones above) always get stockpiled and helped.
    Stockpile({ M.SILO_NAME }, M.SILO_STOCK)
    Assist({ M.SILO_NAME })
end

-- â”€â”€ Firing â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

-- targets: EI.RaidTargets(frame) -- {x, z, value, bp, eco, factory, builder}.  Picks the densest cluster of
-- enemy build power / economy that no anti-nuke covers and is far from our own base, and fires one missile.
function M.Fire(frame, targets, EI, homeX, homeZ)
    if not myTeamID or frame - lastNuke < M.NUKE_INTERVAL or not targets or #targets == 0 then return end
    local silo
    for _, uid in ipairs((select(2, CountOf({ M.SILO_NAME }))) or {}) do
        if IsDone(uid) and Spring.GetUnitStockpile then
            local have = Spring.GetUnitStockpile(uid)
            if have and have > 0 then silo = uid; break end
        end
    end
    if not silo then return end
    local best, bestV
    for _, a in ipairs(targets) do
        if not a.mobile then
            local v = 0
            for _, b in ipairs(targets) do
                if not b.mobile and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= M.NUKE_CLUSTER_R ^ 2 then
                    v = v + (b.value or 0) * ((b.bp and b.bp > 0 or b.eco or b.factory) and 1.5 or 1)
                end
            end
            if v >= M.NUKE_MIN_VALUE and (not bestV or v > bestV)
               and not (EI and EI.AntiNukeCovers(a.x, a.z))
               and (not homeX or (a.x - homeX) ^ 2 + (a.z - homeZ) ^ 2 >= M.NUKE_MIN_HOME ^ 2) then
                best, bestV = a, v
            end
        end
    end
    if not best then return end
    local y = Spring.GetGroundHeight(best.x, best.z) or 0
    Spring.GiveOrderToUnit(silo, CMD_ATTACK, { best.x, y, best.z }, {})
    lastNuke = frame
    Spring.Echo(string.format("[DC] %s nuke launched at %d,%d (cluster value %.0f)", Clock(frame), best.x, best.z, bestV))
end

return M

