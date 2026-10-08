-- bar_framework/line_transition.lua  (LINE_BOT)
-- The line's transition: an air lab, two nanos beside it, then air cons running mex grids.
--
--   1. WAIT.  The line builds as usual; no slot is reserved.  Each tick the closest 6 open slots (3x2) to an outer
--      lane's con (lane 4, else 3) are the candidate site.
--   2. TRIGGER.  The air lab goes down when it can be built flat out, not limited by metal:
--          T = lab buildTime / (build power that can reach it)         seconds
--          metal bank + metal income * T  >=  lab metal cost
--      (BP = that con + every nano in range of the spot.)  A latest-frame fallback forces it.
--   3. LAB.  The site's 6 slots are taken (the line stops using them) and the lab is a line_crew job on that con.
--   4. NANOS.  Two nanos on open slots beside the lab, then idle nanos in reach guard the lab while it owes air cons.
--   5. GRIDS.  Air cons run mex_grid_alab blueprints.  The first grid sits GAP elmos (48 = 3 cells) beyond the
--      line's outer edge, centred on the lab; the rest follow the normal adjacency expansion, minus any cell
--      that would overlap the line.  From here it is TILE_BOT's grid system: spend-pressure hand-off, the T2 air
--      lab capstone, and T2 retrofits of finished grids (not ported: wind consolidation, the spine, the silo capstone).
--
-- Log lines: "[LT] ...".

local LT = {}

LT.CFG = {
    GAP            = 48,          -- elmos between the line's outer edge and the first grid
    LATEST_FRAME   = 6 * 60 * 30, -- build the lab by now whatever the bank says
    EARLIEST_FRAME = 10 * 30,     -- the bank test is the real gate; this only waits for the outer con to exist
    CLAIM_WHEN_OPEN = 14,         -- hold the site once the lane has this few open slots (6 lab + 2 nano + spare)
    LOG_EVERY      = 450,
    GRIDS_OPENING  = 2,           -- grids "opening" at once (TILE_BOT's pacing); all there is while the line is unfinished
    GRIDS_OPENING_MAX = 4,        -- ceiling for the bank / fast triggers once the line is built (a 6:00 log had 13 open)
    GRID_BANK      = 500,
    GRID_BANK_GAP  = 15 * 30,
    GRID_FAST_INCOME = 550,       -- metal income (M/s, smoothed) at which an idle air con opens a grid at once, bank or not:
                                  -- once units soak up the income the bank sits near 0 and the bank triggers never fire
                                  -- (20:02 match: 750-890 M/s at 14-16 min, bank ~200, one grid opening, 8-10 cells waiting)
    GRID_BANK_FAST = 3000,        -- ...or the bank at which it does so (no 15 s gap)...
    GRID_FAST_ENERGY = 0.20,      -- ...provided the energy bank is at least this share of storage
    GRID_HANDOFF   = 0.30,
    AIR_CON_RESERVE = 2,
    UPGRADE_CONS_PER_LAB = 2,     -- T2 air cons each advanced air lab builds
    RETROFIT_STALL_FRAC  = 0.15,  -- retrofit builders stop below this share of metal storage...
    RETROFIT_RESUME_FRAC = 0.30,  -- ...and resume above this
    SPEND_FAST = 0.15, SPEND_SLOW = 0.60,   -- grid hand-off progress: under-spending / short of metal
    BANK_HIGH = 0.25, BANK_LOW = 0.08,
    -- Unit-cap relief (TILE_BOT's values).  "Tight" = headroom under 1000 units, but never more than 20% of the cap.
    CONSOLIDATE_SLACK = 1000, CAP_SLACK_FRAC = 0.20, WIND_LATTICE = 48,
    CONSOLIDATE_SCAN = 300, CONSOLIDATE_MAX = 60,
    RECLAIM_TRIGGER_FRAC = 0.20, RECLAIM_BUDGET_FRAC = 0.02, RECLAIM_EVERY = 90,
    -- ENERGY PUSH (2026-10-08, off by default; LINE_CLICK_v4 turns it on): from ~16:00 of a mirror game metal sat at
    -- its 30k cap and was wasted (pull 380 of 635 M/s) while energy ran at 93% of income -- army units cost ~15 E per
    -- metal, so energy, not metal, capped spending.  When metal floats and energy is the binding resource, free T2 cons
    -- turn 2x2 blocks of winds into fusions (the consolidation job, before the unit cap), up to EP_INFLIGHT at once;
    -- with no free T2 con an idle advanced air lab makes one.
    -- GRID EXPANSION (2026-10-08, off by default; LINE_CLICK_v13 turns them on).  In a 30-minute game v12 sat at 2
    -- grids from 4:00 to 7:40 and at 7-8 from 9:30 to 15:00 with 2-4 air cons idle and 0 cells waiting:
    --   COLLECT_ALWAYS: new cells were only looked for while the bank held GRID_BANK metal, and the army spends the
    --     bank -- look whenever the list is empty;
    --   GRID_ENEMY_SIDE: cells were never allowed past the line's enemy-facing edge, i.e. toward the map interior; with
    --     the base ~850 from the map edge that left one row of grids.  Allow cells this many elmos past that edge (0 = old).
    COLLECT_ALWAYS = false,
    GRID_ENEMY_SIDE = 0,
    ENERGY_PUSH = false,
    EP_START = 10 * 60 * 30, EP_MFRAC = 0.30, EP_MIN_METAL = 3000,   -- "metal floats"
    EP_EFRAC = 0.50, EP_EPULL = 0.85,                                -- "energy binds": bank under half, pull >= 85% of income
    EP_INFLIGHT = 2, EP_EVERY = 300, EP_CON_EVERY = 1800,
    AIR_CON_TIMEOUT = 80 * 30,
    -- Vehicle lab (the spine's seed): finished by ~4:30 (the human reference had its lab done at 3:57 and its
    -- units arrived at ~5:30); it is queued backwards from that deadline.  4 slots (2x2) on the other outer lane.
    VP_DONE_FRAME = 4 * 60 * 30 + 30 * 30,
    VP_MARGIN     = 10 * 30,
    VP_COLS       = 2,
    VP_NAME       = "corvp",
    SPINE_GAP     = 0,            -- elmos between the line's outer edge and spine cell 1 (in front of the vehicle lab)
    VP_CONS       = 1,            -- ground cons the vehicle lab makes first: they build the spine (no air cons do)
    SPINE_EARLY_CONS = 1,         -- ground cons the spine may have (alive + ordered) until its cell 1 is built
    AIR_CON_CAP_EARLY = 3,        -- air cons allowed (alive + ordered) until the air lab's two nanos stand (or, as a
    AIR_CON_CAP_UNTIL = 0.30,     -- fallback, the first grid is this share built)
}

local HALF_GRID = 240
local LINE_BOX  = { x0 = -176, x1 = 1152, z0 = -432, z1 = 320 }   -- b-frame: starter + all slot rows

local CMD_STOP   = 0
local CMD_INSERT = (CMD and CMD.INSERT) or 1
local OPT_ALT, OPT_CTRL, OPT_INTERNAL = (CMD and CMD.OPT_ALT) or 128, (CMD and CMD.OPT_CTRL) or 64, (CMD and CMD.OPT_INTERNAL) or 8
local CMD_GUARD  = (CMD and CMD.GUARD) or 25

local function Clock(frame)
    return string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60)
end

local function Key(ax, az) return ax .. "," .. az end

function LT.New(o)
    local T = { BP = o.BP, LC = o.LC, crew = o.crew, L = o.layout, gridBP = o.gridBP, teamID = o.teamID,
                CFG = LT.CFG, phase = "wait", frame = 0,
                gridStates = {}, freeAirCons = {}, pendingGrids = {}, assigned = {}, completed = {}, completedKeys = {},
                allAnchors = {}, gridCands = {}, pendingSince = {}, gridsAssigned = 0,
                airConsOrdered = 0, orders = {}, lastReserve = -1e9, lastBankGrid = -1e9,
                pendingStops = {}, airLabNanos = {}, labNanoIDs = {}, labTries = 0,
                spineMod = o.spine, spineBPs = o.spineBPs, spineOn = false, WG = o.WG,
                airConsAlive = {}, firstGridOK = false,
                vpPhase = o.spine and "wait" or "off", vpTries = 0,
                upgradeBP = o.upgradeBP, upgradeStates = {}, upgradedKeys = {}, gridFinished = {}, gridRotation = {},
                freeT2Cons = {}, retrofitPaused = false,
                consolidateOn = false, consolidateJobs = {}, consolidatedKeys = {}, windBlocks = {}, reclaimingWinds = {} }
    -- Which outer lane faces the enemy (the map centre): the vehicle lab and the spine go there; the air lab and the
    -- mex grids go on the other side.  b-z outward is lane 4 (north), b+z outward is lane 3 (south).
    local ex, ez = o.layout.mapX / 2 - o.layout.anchorX, o.layout.mapZ / 2 - o.layout.anchorZ
    for _, id in ipairs({ 3, 4 }) do
        local ox, oz = o.LC.Rotate(0, id == 3 and 1 or -1, o.layout.rot)
        if ox * ex + oz * ez > 0 then T.enemyLane = id else T.awayLane = T.awayLane or id end
    end
    T.enemyLane = T.enemyLane or 3
    T.awayLane = T.awayLane or (T.enemyLane == 3 and 4 or 3)
    -- Is world point (ax, az) past the line's enemy-facing edge (the half-plane the grids must stay out of)?
    T.OnEnemySide = function(self, ax, az)
        local bx, bz = self.LC.Rotate(ax - self.L.anchorX, az - self.L.anchorZ, (4 - self.L.rot) % 4)
        local out = (self.enemyLane == 3) and 1 or -1
        local edge = (out > 0) and LINE_BOX.z1 or LINE_BOX.z0
        return out * (bz - edge) > (self.CFG.GRID_ENEMY_SIDE or 0)
    end
    -- Does a grid cell at (ax, az) overlap any cell or exit lane of the spine's stack?  (480-elmo cells.)
    T.OverlapsSpine = function(self, ax, az)
        for _, b in ipairs(self.spineBoxes or {}) do
            if math.abs(ax - b.x) < 480 and math.abs(az - b.z) < 480 then return true end
        end
        return false
    end
    if o.cfg then                       -- per-bot overrides of LT.CFG (A/B variants differ only by these flags)
        T.CFG = {}
        for k, v in pairs(LT.CFG) do T.CFG[k] = v end
        for k, v in pairs(o.cfg) do T.CFG[k] = v end
    end
    -- The line's footprint in world coordinates (rotations are multiples of 90 degrees: the box stays a box).
    local xs, zs = {}, {}
    for _, bx in ipairs({ LINE_BOX.x0, LINE_BOX.x1 }) do
        for _, bz in ipairs({ LINE_BOX.z0, LINE_BOX.z1 }) do
            local wx, wz = o.LC.World(T.L, bx, bz)
            xs[#xs + 1], zs[#zs + 1] = wx, wz
        end
    end
    T.lineBox = { x0 = math.min(unpack(xs)), x1 = math.max(unpack(xs)), z0 = math.min(unpack(zs)), z1 = math.max(unpack(zs)) }
    return T
end

-- ── Air lab ──────────────────────────────────────────────────────────────────

-- Cheapest factory the builder can place that makes a flying constructor.
local function FindAirLabDef(builderID)
    local bd = UnitDefs[Spring.GetUnitDefID(builderID) or -1]
    local best, bestCost = nil, math.huge
    for _, optID in ipairs((bd and bd.buildOptions) or {}) do
        local od = UnitDefs[optID]
        if od and od.isFactory and od.buildOptions then
            for _, subID in ipairs(od.buildOptions) do
                local sd = UnitDefs[subID]
                if sd and sd.isBuilder and sd.canFly and not sd.isFactory then
                    if (od.metalCost or math.huge) < bestCost then best, bestCost = optID, od.metalCost or math.huge end
                    break
                end
            end
        end
    end
    return best
end

local function FindAirConDef(labDefID)
    local d = labDefID and UnitDefs[labDefID]
    for _, optID in ipairs((d and d.buildOptions) or {}) do
        local od = UnitDefs[optID]
        if od and od.isBuilder and od.canFly and not od.isFactory then return optID end
    end
    return nil
end

-- Site: the 6 open slots (3 columns x 2 rows of one lane's section) closest to an outer lane's builder, plus
-- up to 2 more open slots beside them for the nanos.  Nothing is reserved until the lab is queued.
-- opts (all optional): lanes = lane ids to look in, cols = columns of the block (default 3; 2 rows each).
function LT.PickSite(T, opts)
    local LC, best = T.LC, nil
    opts = opts or {}
    local cols = opts.cols or 3
    for _, laneID in ipairs(opts.lanes or LC.TRANS_LANES) do
        local b = LC.LaneBuilder(T.crew, laneID)
        local bxw, _, bzw = nil, nil, nil
        if b then bxw, _, bzw = Spring.GetUnitPosition(b.id) end
        if bxw then
            local lane = T.L.lanes[laneID]
            local at = {}                       -- at[row][k] = slot, open ones only
            for _, s in ipairs(lane.slots) do
                if s.state == "free" then at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
            end
            for k0 = LC.K_FIRST, LC.K_LAST - (cols - 1) do
                local slots, ok = {}, true
                for row = 1, 2 do
                    for k = k0, k0 + cols - 1 do
                        local s = at[row] and at[row][k]
                        if s then slots[#slots + 1] = s else ok = false end
                    end
                end
                if ok then
                    local wx, wz, bx, bz = 0, 0, 0, 0
                    for _, s in ipairs(slots) do wx, wz, bx, bz = wx + s.wx, wz + s.wz, bx + s.bx, bz + s.bz end
                    wx, wz, bx, bz = wx / #slots, wz / #slots, bx / #slots, bz / #slots
                    local d = math.sqrt((wx - bxw) ^ 2 + (wz - bzw) ^ 2)
                    if not best or d < best.d then
                        best = { d = d, lane = laneID, builder = b.id, slots = slots, wx = wx, wz = wz, bx = bx, bz = bz, k0 = k0 }
                    end
                end
            end
        end
    end
    if not best then return nil end
    -- Nano slots: open slots of that lane beside the block (columns k0-1 and k0+3 first), nearest to it.
    local inLab = {}
    for _, s in ipairs(best.slots) do inLab[s] = true end
    local cands = {}
    for _, s in ipairs(T.L.lanes[best.lane].slots) do
        if s.state == "free" and not inLab[s] then
            local beside = (s.k == best.k0 - 1 or s.k == best.k0 + cols) and 0 or 1
            cands[#cands + 1] = { s = s, beside = beside, d = math.sqrt((s.wx - best.wx) ^ 2 + (s.wz - best.wz) ^ 2) }
        end
    end
    table.sort(cands, function(a, b) if a.beside ~= b.beside then return a.beside < b.beside end return a.d < b.d end)
    best.nanos = {}
    for i = 1, math.min(2, #cands) do best.nanos[i] = cands[i].s end
    return best
end

-- Spot: the middle of the site, facing with the lab's long side along the line.
function LT.LabSpot(T, site)
    local LC = T.LC
    local wx, wz = site.wx, site.wz
    local ud = UnitDefs[T.labDefID]
    local xs, zs = (ud.xsize or 0) * 8, (ud.zsize or ud.ysize or 0) * 8
    local lx = LC.Rotate(1, 0, T.L.rot)                     -- the line's long axis in world space
    local base = T.BP.RotateFacing(0, T.L.rot)
    local good, rest = {}, {}
    for _, f in ipairs({ base, (base + 2) % 4, (base + 1) % 4, (base + 3) % 4 }) do
        local fx, fz = xs, zs
        if f % 2 == 1 then fx, fz = zs, xs end
        local fits = (lx ~= 0 and fx >= fz) or (lx == 0 and fz >= fx)
        if fits then good[#good + 1] = f else rest[#rest + 1] = f end
    end
    for _, f in ipairs(rest) do good[#good + 1] = f end
    if not T.spotLogged then
        T.spotLogged = true
        Spring.Echo(string.format("[LT] air lab %s footprint %dx%d elmos (facing 0), slot rectangle 192x128; facings %s",
            ud.name, xs, zs, table.concat(good, ",")))
    end
    for _, f in ipairs(good) do
        local x, z = T.BP.SnapToBuildGrid(T.labDefID, wx, wz, f)
        local y = Spring.GetGroundHeight(x, z) or 0
        local ok = Spring.TestBuildOrder(T.labDefID, x, y, z, f)
        if ok and ok ~= 0 then return x, z, f end
    end
    return nil
end

-- Seconds to build the lab with everything that can reach it, and whether the bank covers it by then.
function LT.LabPlan(T, res, x, z, builderID, defID)
    local lab = UnitDefs[defID or T.labDefID]
    local bp = (UnitDefs[Spring.GetUnitDefID(builderID) or -1] or {}).buildSpeed or 0
    local nanos = 0
    for _, n in ipairs(T.BP.NanosInRange(x, z) or {}) do
        local nd = UnitDefs[Spring.GetUnitDefID(n) or -1]
        if nd then bp = bp + (nd.buildSpeed or 0); nanos = nanos + 1 end
    end
    bp = math.max(bp, 1)
    local t = (lab.buildTime or lab.metalCost or 1000) / bp
    local cost = lab.metalCost or 0
    local avail = res.metal + res.metalIncome * t
    return { t = t, bp = bp, nanos = nanos, cost = cost, avail = avail, ok = avail >= cost,
             energyOk = (res.energy + res.energyIncome * t) >= (lab.energyCost or 0) }
end

local function UpdateWait(T, frame, res)
    local LC = T.LC
    if frame < T.CFG.EARLIEST_FRAME then return end
    if T.site and not LC.LaneBuilder(T.crew, T.site.lane) then       -- its builder died: give the slots back
        for _, s in ipairs(T.site.slots) do s.state = "free" end
        for _, s in ipairs(T.site.nanos) do s.state = "free" end
        T.site = nil
    end
    -- The air lab (and with it the mex grids) goes on the outer lane AWAY from the enemy; the vehicle lab and the
    -- spine take the enemy-facing one.
    local site = T.site or LT.PickSite(T, { lanes = { T.awayLane } })
    if not site then
        if frame % 300 == 0 then Spring.Echo("[LT] " .. Clock(frame) .. " no 6 open slots (3x2) left in an outer lane") end
        return
    end
    local b = { id = site.builder }
    if not T.labDefID then
        T.labDefID = FindAirLabDef(b.id)
        if not T.labDefID then
            Spring.Echo("[LT] the outer con cannot place an air factory; transition off")
            T.phase = "off"
            return
        end
    end
    local x, z, f = LT.LabSpot(T, site)
    if not x then
        if frame % 300 == 0 then Spring.Echo("[LT] " .. Clock(frame) .. " no legal spot for the air lab yet") end
        return
    end
    local p = LT.LabPlan(T, res, x, z, b.id)
    if frame % T.CFG.LOG_EVERY == 0 then
        Spring.Echo(string.format("[LT] %s lab plan: BP %.0f (%d nanos) -> %.0fs; bank %d + %.1f/s x %.0fs = %.0f vs cost %d (%s)%s",
            Clock(frame), p.bp, p.nanos, p.t, res.metal, res.metalIncome, p.t, p.avail, p.cost,
            p.ok and "enough" or "short", p.energyOk and "" or "; energy short"))
    end
    local late = frame >= T.CFG.LATEST_FRAME
    -- Before the bank is ready the site is only a candidate, re-picked every tick near the con.  It is claimed
    -- early only when the lane is about to run out of open slots (the line would eat the site otherwise).
    if not T.site then
        local open = 0
        for _, s in ipairs(T.L.lanes[site.lane].slots) do if s.state == "free" then open = open + 1 end end
        if p.ok or late or open <= T.CFG.CLAIM_WHEN_OPEN then
            for _, s in ipairs(site.slots) do s.state = "reserved" end
            for _, s in ipairs(site.nanos) do s.state = "reserved" end
            T.site = site
            if not (p.ok or late) then
                Spring.Echo(string.format("[LT] %s lane %d is down to %d open slots: site held (6 + %d nano) until the bank is ready",
                    Clock(frame), site.lane, open, #site.nanos))
            end
        end
    end
    if not (p.ok or late) then return end
    local ud = UnitDefs[T.labDefID]
    LC.QueueJob(T.crew, b.id, { name = ud.name, x = x, z = z, f = f, tag = "lab" })
    T.phase, T.labFrame = "lab", frame
    Spring.Echo(string.format("[LT] %s AIR LAB queued (%s) at (%d, %d) facing %d: %s; BP %.0f, %.0fs, bank %d income %.1f",
        Clock(frame), ud.name, x, z, f, late and "latest-frame fallback" or "bank covers the build", p.bp, p.t,
        res.metal, res.metalIncome))
end

-- ── Air cons ─────────────────────────────────────────────────────────────────

-- Until the first grid is ~30% built the bot keeps at most AIR_CON_CAP_EARLY air cons (alive + ordered): more
-- compete with that grid for metal and nanos.
local function LiftAirConCap(T, why)
    if T.firstGridOK then return end
    T.firstGridOK = true
    Spring.Echo(string.format("[LT] %s air con cap (%d) lifted: %s", Clock(T.frame), T.CFG.AIR_CON_CAP_EARLY, why))
end

local function AirConsEarlyFull(T)
    if T.firstGridOK then return false end
    local alive = 0
    for id in pairs(T.airConsAlive) do
        if Spring.GetUnitDefID(id) then alive = alive + 1 else T.airConsAlive[id] = nil end
    end
    return alive + T.airConsOrdered >= T.CFG.AIR_CON_CAP_EARLY
end

local function QueueAirCon(T, frame)
    if AirConsEarlyFull(T) then return end
    local lab = T.airLabID
    if lab and Spring.GetUnitDefID(lab) and T.airConDefID then
        local _, busy = Spring.GetUnitWorkerTask(lab)
        Spring.GiveOrderToUnit(lab, CMD_INSERT, { busy and 1 or 0, -T.airConDefID, OPT_ALT + OPT_INTERNAL }, OPT_ALT + OPT_CTRL)
        T.airConsOrdered = T.airConsOrdered + 1
        T.orders[#T.orders + 1] = frame
    end
end

local function AirConOrderDone(T)
    if #T.orders > 0 then table.remove(T.orders, 1) end
    T.airConsOrdered = math.max(0, T.airConsOrdered - 1)
end

local function KeepAirConReserve(T, frame)
    if T.consolidateOn or not T.airLabID or not T.airConDefID or frame - T.lastReserve < 90 then return end
    if #T.freeAirCons + T.airConsOrdered < #T.pendingGrids + T.CFG.AIR_CON_RESERVE then
        QueueAirCon(T, frame)
        T.lastReserve = frame
    end
end

-- Idle nanos in reach of the lab guard it while it owes air cons (lowest priority; any hand-off takes them back).
-- While the line is unfinished only the lab's own two nanos do: the line's nanos stay free to help its builders
-- (a guarding nano builds nothing but the lab's air cons; a 6:00 log had every nano on the lab and 40% of the line open).
local function UpdateLabAssist(T, frame)
    if frame % 30 ~= 0 or not T.airLabID then return end
    local NANO = T.BP.NANO
    if not NANO then return end
    if T.airConsOrdered > 0 and Spring.GetUnitDefID(T.airLabID) then
        local x, _, z = Spring.GetUnitPosition(T.airLabID)
        local lineBuilt = T.LC.SlotsRemaining(T.L) == 0
        for _, n in ipairs(T.BP.NanosInRange(x, z) or {}) do
            if lineBuilt or T.labNanoIDs[n] then
                local idle = NANO.Assignment(n) == nil and not (Spring.GetUnitIsBuilding and Spring.GetUnitIsBuilding(n))
                if (idle or T.airLabNanos[n]) and NANO.Guard(NANO.PRIO.BALANCE, n, T.airLabID) then T.airLabNanos[n] = true end
            elseif T.airLabNanos[n] then
                local a = NANO.Assignment(n)
                if a and a.target == T.airLabID and a.prio == NANO.PRIO.BALANCE then NANO.Release(n) end
                T.airLabNanos[n] = nil
            end
        end
    else
        for n in pairs(T.airLabNanos) do
            local a = NANO.Assignment(n)
            if a and a.target == T.airLabID and a.prio == NANO.PRIO.BALANCE then NANO.Release(n) end
            T.airLabNanos[n] = nil
        end
    end
end

-- ── Grids ────────────────────────────────────────────────────────────────────

local function InsideLine(T, ax, az)
    local b = T.lineBox
    return ax - HALF_GRID < b.x1 and b.x0 < ax + HALF_GRID and az - HALF_GRID < b.z1 and b.z0 < az + HALF_GRID
end

local function AddCompleted(T, ax, az)
    local k = Key(ax, az)
    if not T.completedKeys[k] then
        T.completedKeys[k] = true
        T.completed[#T.completed + 1] = { anchorX = ax, anchorZ = az }
    end
end

-- Free cells next to `sources`, never on the line, queued as candidates.
local function Collect(T, sources)
    if T.consolidateOn then return end      -- at the cap the headroom is for army, not more grid
    for _, r in ipairs(T.BP.FindAllValidPlacements(T.gridBP, sources)) do
        local k = Key(r.anchorX, r.anchorZ)
        if not T.assigned[k] and not InsideLine(T, r.anchorX, r.anchorZ) and not T.OverlapsSpine(T, r.anchorX, r.anchorZ)
           and not T.OnEnemySide(T, r.anchorX, r.anchorZ) then
            T.assigned[k] = true
            T.gridCands[#T.gridCands + 1] = r
        end
    end
end

-- Capstone: the blueprint crowns each grid with a T2 air lab (coraap), which is what makes the T2 air cons that
-- do the retrofits.  A grid's own con that cannot place it has the entry retired so the grid can still finish.
local function ApplyCapstone(T, st, conID)
    for _, item in ipairs(st.queue) do
        if item.cls == "factory" then
            local cdef = Spring.GetUnitDefID(conID)
            if not (cdef and T.BP.CanBuild(cdef, item.defID)) then
                item.built, item.status = true, "skipped"
            end
            return
        end
    end
end

-- A T2 con is one that can build what the upgrade blueprint asks for (same question the placer asks).
local function IsT2Con(T, defID)
    local bp = T.upgradeBP
    if not (bp and bp.layout and bp.layout[1]) then return false end
    local ud = UnitDefNames[bp.layout[1].n]
    return ud and T.BP.CanBuild(defID, ud.id) or false
end

local TryAssignUpgrades

local function TryAssignGrids(T, frame)
    while #T.freeAirCons > 0 and #T.pendingGrids > 0 do
        local conID = table.remove(T.freeAirCons, 1)
        if Spring.GetUnitDefID(conID) then
            Spring.GiveOrderToUnit(conID, CMD_STOP, {}, {})
            local g = table.remove(T.pendingGrids, 1)
            local k = Key(g.anchorX, g.anchorZ)
            if T.pendingSince[k] then
                Spring.Echo(string.format("[LT] grid %d at (%d, %d) waited %.1fs for a con", T.gridsAssigned + 1,
                    g.anchorX, g.anchorZ, (frame - T.pendingSince[k]) / 30))
            end
            T.allAnchors[#T.allAnchors + 1] = { anchorX = g.anchorX, anchorZ = g.anchorZ, key = k }
            T.gridRotation[k] = g.rotation
            local st = T.BP.New(T.gridBP, conID, g.anchorX, g.anchorZ, g.rotation, T.BP.GRID_INTERRUPTS)
            -- The grid's own factory is the last thing built, unless metal piles up unspent.
            st.deferFactories, st.handoffProgress = true, T.CFG.GRID_HANDOFF
            if T.gridsAssigned == 0 then T.firstGrid = st end
            T.gridsAssigned = T.gridsAssigned + 1
            ApplyCapstone(T, st, conID)
            if T.consolidateOn and T.windDefID then st.skipDefIDs = { [T.windDefID] = true } end
            st.onNanoThreshold = function(gs)
                AddCompleted(T, gs.anchorX, gs.anchorZ)
                Collect(T, T.completed)
                TryAssignGrids(T, T.frame)
            end
            -- 70% built is enough to retrofit: the grid's nanos are up and its con is off on the outlying items.
            st.onMostlyDone = function(gs)
                local key = Key(gs.anchorX, gs.anchorZ)
                if not T.gridFinished[key] then
                    T.gridFinished[key] = true
                    Spring.Echo(string.format("[LT] grid (%d, %d) mostly built -- retrofit eligible", gs.anchorX, gs.anchorZ))
                    TryAssignUpgrades(T)
                end
            end
            st.onComplete = function(gs)
                AddCompleted(T, gs.anchorX, gs.anchorZ)
                T.gridFinished[Key(gs.anchorX, gs.anchorZ)] = true
                Spring.Echo(string.format("[LT] %s grid (%d, %d) finished -- retrofit eligible", Clock(T.frame), gs.anchorX, gs.anchorZ))
                Collect(T, T.completed)
                TryAssignGrids(T, T.frame)
                TryAssignUpgrades(T)
            end
            T.gridStates[#T.gridStates + 1] = st
        end
    end
end

-- ── Retrofit: a finished grid is upgraded in place to T2 mexes + fusions by a T2 air con ─────────────────────

TryAssignUpgrades = function(T)
    if not T.upgradeBP then return end
    -- ENERGY PUSH: while energy binds, keep enough free T2 cons for its fusion jobs (a retrofit adds metal too,
    -- which is the resource that is floating).
    local keep = 0
    if T.CFG.ENERGY_PUSH and T.epBound then keep = math.max(0, T.CFG.EP_INFLIGHT - #T.consolidateJobs) end
    while #T.freeT2Cons > keep do
        local conID = T.freeT2Cons[1]
        if not Spring.GetUnitDefID(conID) then
            table.remove(T.freeT2Cons, 1)
        else
            -- Nearest finished grid not yet retrofitted (a grid still building would compete with its own retrofit).
            local cx, _, cz = Spring.GetUnitPosition(conID)
            local best, bestD2, bestKey = nil, math.huge, nil
            for _, a in ipairs(T.completed) do
                local key = Key(a.anchorX, a.anchorZ)
                if T.gridFinished[key] and not T.upgradedKeys[key] then
                    local dx, dz = (cx or 0) - a.anchorX, (cz or 0) - a.anchorZ
                    local d2 = dx * dx + dz * dz
                    if d2 < bestD2 then best, bestD2, bestKey = a, d2, key end
                end
            end
            if not best then return end
            table.remove(T.freeT2Cons, 1)
            T.upgradedKeys[bestKey] = true
            Spring.GiveOrderToUnit(conID, CMD_STOP, {}, {})
            local st = T.BP.New(T.upgradeBP, conID, best.anchorX, best.anchorZ, T.gridRotation[bestKey] or 0,
                                T.BP.GRID_INTERRUPTS)
            st.clearBlockers = true                      -- reclaim the mex/winds the fusions need
            st.clearOnlyDefIDs = {}
            for _, n in ipairs({ "corwin", "cormex" }) do
                local ud = UnitDefNames[n]
                if ud then st.clearOnlyDefIDs[ud.id] = true end
            end
            st.handoffProgress = T.CFG.GRID_HANDOFF
            st.onComplete = function(us)                 -- the con goes straight on to the next grid
                if us.builderID and Spring.GetUnitDefID(us.builderID) then
                    T.freeT2Cons[#T.freeT2Cons + 1] = us.builderID
                    TryAssignUpgrades(T)
                end
            end
            T.upgradeStates[#T.upgradeStates + 1] = st
            Spring.Echo(string.format("[LT] %s retrofit started at (%d, %d) by con %d", Clock(T.frame),
                best.anchorX, best.anchorZ, conID))
        end
    end
end

-- A retrofit must never compete with a normal grid for metal (T2 mexes earn less per metal): while stalling,
-- retrofit builders are stopped.
local function UpdateRetrofits(T, frame, res)
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 1
    if not T.retrofitPaused and mFrac < T.CFG.RETROFIT_STALL_FRAC then
        T.retrofitPaused = true
        for _, us in ipairs(T.upgradeStates) do
            if us.builderID and Spring.GetUnitDefID(us.builderID) then
                Spring.GiveOrderToUnit(us.builderID, CMD_STOP, {}, {})
                us.currentTask = nil
            end
        end
    elseif T.retrofitPaused and mFrac > T.CFG.RETROFIT_RESUME_FRAC then
        T.retrofitPaused = false
    end
    if not T.retrofitPaused then
        local i = 1
        while i <= #T.upgradeStates do
            local us = T.upgradeStates[i]
            if us.done then table.remove(T.upgradeStates, i)
            else T.BP.Update(us, frame, res); i = i + 1 end
        end
    end
    if #T.freeT2Cons > (T.consolidateOn and 1 or 0) then TryAssignUpgrades(T) end
end

-- Under-spending means too few frames are open at once: hand frames to the nanos sooner so the builder places
-- the next one.  Short on metal, the opposite (finish what is started).  Income above pull = under-spending.
local function UpdateSpendPressure(T, res)
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
    local underSpending = res.metalIncome > res.metalPull * 1.05
    local handoff = T.CFG.GRID_HANDOFF
    if mFrac < T.CFG.BANK_LOW and not underSpending then handoff = T.CFG.SPEND_SLOW
    elseif underSpending or mFrac > T.CFG.BANK_HIGH then handoff = T.CFG.SPEND_FAST end
    for _, st in ipairs(T.gridStates)    do st.handoffProgress = handoff end
    for _, st in ipairs(T.upgradeStates) do st.handoffProgress = handoff end
end

-- ── Unit-cap relief: wind consolidation (TILE_BOT's) ─────────────────────────────────────────────────────────
-- Four winds in a 2x2 block are replaced by ONE fusion or one T2 mex (~34x the energy per unit slot).  Starts
-- when the cap is tight: grids stop building wind, retrofits become eligible at once, winds are reclaimed in a
-- rationed trickle and the T2 cons turn the freed ground into fusions / T2 mexes.

local function CapSlack(T, absolute)
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
    if not maxU or maxU <= 0 then return absolute end
    return math.min(absolute, math.floor(maxU * T.CFG.CAP_SLACK_FRAC))
end

-- Every unclaimed 2x2 block of finished winds, in one pass (winds sit on a global 48-elmo lattice).
local function ScanWindBlocks(T)
    if not T.windDefID then return end
    T.windBlocks = {}
    local at = {}
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        if Spring.GetUnitDefID(uid) == T.windDefID and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then at[math.floor(x + 0.5) .. "," .. math.floor(z + 0.5)] = uid end
        end
    end
    local L, taken = T.CFG.WIND_LATTICE, {}
    for key in pairs(at) do
        if #T.windBlocks >= T.CFG.CONSOLIDATE_MAX then break end
        local sx, sz = key:match("(-?%d+),(-?%d+)")
        local x, z = tonumber(sx), tonumber(sz)
        local k2, k3, k4 = (x + L) .. "," .. z, x .. "," .. (z + L), (x + L) .. "," .. (z + L)
        if at[k2] and at[k3] and at[k4] and not (taken[key] or taken[k2] or taken[k3] or taken[k4]) then
            local cx, cz = x + L / 2, z + L / 2
            local ckey = math.floor(cx) .. "," .. math.floor(cz)
            if not T.consolidatedKeys[ckey] then
                taken[key], taken[k2], taken[k3], taken[k4] = true, true, true, true
                T.windBlocks[#T.windBlocks + 1] = { cx = cx, cz = cz, key = ckey, winds = { at[key], at[k2], at[k3], at[k4] } }
            end
        end
    end
end

-- Condemn a rationed number of winds and put every nano that can reach each one on reclaiming it (rationed: the
-- energy loss must not be a cliff).
local function UpdateWindReclaim(T)
    local NANO = T.BP.NANO
    if not NANO then return end
    T.windDefID = T.windDefID or (UnitDefNames["corwin"] and UnitDefNames["corwin"].id)
    if not T.windDefID then return end
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
    if not (maxU and cnt) or (maxU - cnt) > maxU * T.CFG.RECLAIM_TRIGGER_FRAC then return end
    local active = 0
    for wid in pairs(T.reclaimingWinds) do
        if Spring.GetUnitDefID(wid) then active = active + 1 else T.reclaimingWinds[wid] = nil end
    end
    local budget = math.max(1, math.floor(maxU * T.CFG.RECLAIM_BUDGET_FRAC))
    if active >= budget then return end
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        if active >= budget then break end
        if Spring.GetUnitDefID(uid) == T.windDefID and not T.reclaimingWinds[uid] and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local used = 0
                for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
                    if NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nid, uid) then used = used + 1 end
                end
                if used > 0 then T.reclaimingWinds[uid], active = true, active + 1 end
            end
        end
    end
end

local function StartConsolidation(T, conID, res, forceName)
    local block
    while #T.windBlocks > 0 do
        local b = table.remove(T.windBlocks, 1)
        if not T.consolidatedKeys[b.key] then block = b; break end
    end
    if not block then return false end
    -- Replace the block with whichever resource is scarcer right now (the energy push always wants a fusion).
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 1
    local eFrac = res.energyStorage > 0 and res.energy / res.energyStorage or 1
    local name = forceName or ((eFrac <= mFrac) and "corfus" or "cormoho")
    local ud = UnitDefNames[name]
    if not ud or not T.BP.CanBuild(Spring.GetUnitDefID(conID), ud.id) then return false end
    T.consolidatedKeys[block.key] = true
    Spring.GiveOrderToUnit(conID, CMD_STOP, {}, {})
    -- One-item blueprint; clearBlockers reclaims the four winds, and ONLY winds, to make room.
    local st = T.BP.New({ layout = { { n = name, x = 0, z = 0, f = 0 } } }, conID, block.cx, block.cz, 0, {})
    st.clearBlockers = true
    st.clearOnlyDefIDs = { [T.windDefID] = true }
    T.consolidateJobs[#T.consolidateJobs + 1] = st
    Spring.Echo(string.format("[LT] %s consolidating 4 winds at (%d, %d) into %s", Clock(T.frame), block.cx, block.cz, name))
    return true
end

local function CheckCapPressure(T)
    if T.consolidateOn then
        if T.windDefID then
            for _, gs in ipairs(T.gridStates) do
                gs.skipDefIDs = gs.skipDefIDs or {}
                gs.skipDefIDs[T.windDefID] = true
            end
        end
        return
    end
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
    local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
    if not (maxU and cnt) or (maxU - cnt) > CapSlack(T, T.CFG.CONSOLIDATE_SLACK) then return end
    T.consolidateOn = true
    T.windDefID = UnitDefNames["corwin"] and UnitDefNames["corwin"].id
    -- Every grid becomes retrofit-eligible now, finished or not: a T1->T2 mex upgrade costs no unit slot.
    local marked = 0
    for _, g in ipairs(T.allAnchors) do
        if not T.gridFinished[g.key] then
            T.gridFinished[g.key] = true
            AddCompleted(T, g.anchorX, g.anchorZ)
            marked = marked + 1
        end
    end
    Spring.Echo(string.format("[LT] %s unit cap tight (%d/%d): grids stop building wind, consolidation on, %d more grids marked for retrofit",
        Clock(T.frame), cnt, maxU, marked))
    TryAssignUpgrades(T)
end

-- ENERGY PUSH (see LT.CFG): metal floating while energy binds -> wind blocks become fusions.
local function EnergyBound(T, frame, res)
    local C = T.CFG
    if frame < C.EP_START then return false end
    local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
    local eFrac = res.energyStorage > 0 and res.energy / res.energyStorage or 1
    local ei = res.energyIncomeS or res.energyIncome or 0
    local ep = res.energyPullS or res.energyPull or 0
    return mFrac >= C.EP_MFRAC and res.metal >= C.EP_MIN_METAL and eFrac < C.EP_EFRAC and ep >= C.EP_EPULL * ei
end

local function UpdateEnergyPush(T, frame, res)
    local C = T.CFG
    if not C.ENERGY_PUSH or T.consolidateOn or frame - (T.epFrame or -1e9) < C.EP_EVERY then return end
    T.epFrame = frame
    T.epBound = EnergyBound(T, frame, res)
    if not T.epBound then return end
    if #T.consolidateJobs >= C.EP_INFLIGHT then return end
    ScanWindBlocks(T)
    if #T.windBlocks == 0 then return end
    local started = 0
    while #T.consolidateJobs < C.EP_INFLIGHT and #T.freeT2Cons > 0 and #T.windBlocks > 0 do
        local conID = T.freeT2Cons[1]
        if not Spring.GetUnitDefID(conID) then table.remove(T.freeT2Cons, 1)
        elseif StartConsolidation(T, conID, res, "corfus") then table.remove(T.freeT2Cons, 1); started = started + 1
        else break end
    end
    T.epStarted = (T.epStarted or 0) + started
    if started > 0 then
        Spring.Echo(string.format("[LT] %s ENERGY PUSH: %d wind block(s) -> fusion (metal %.0f/%.0f, energy %.0f/%.0f, pull %.0f of %.0f E/s), %d so far",
            Clock(frame), started, res.metal, res.metalStorage, res.energy, res.energyStorage,
            res.energyPullS or res.energyPull, res.energyIncomeS or res.energyIncome, T.epStarted))
    elseif #T.freeT2Cons == 0 and frame - (T.epConFrame or -1e9) >= C.EP_CON_EVERY then
        -- no free T2 con: an advanced air lab with nothing queued makes one (it then joins the free pool)
        for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and d.isFactory and uid ~= T.airLabID and not Spring.GetUnitIsBeingBuilt(uid) then
                local t2 = FindAirConDef(Spring.GetUnitDefID(uid))
                local q = Spring.GetFactoryCommands and Spring.GetFactoryCommands(uid, 1)
                if t2 and IsT2Con(T, t2) and (not q or #q == 0) then
                    Spring.GiveOrderToUnit(uid, -t2, { 0 }, {})
                    T.epConFrame = frame
                    Spring.Echo(string.format("[LT] %s ENERGY PUSH: no free T2 con, lab %d makes one", Clock(frame), uid))
                    break
                end
            end
        end
    end
end

local function UpdateConsolidation(T, frame, res)
    UpdateEnergyPush(T, frame, res)
    if T.consolidateOn then
        if frame % T.CFG.CONSOLIDATE_SCAN == 0 or #T.windBlocks == 0 then ScanWindBlocks(T) end
        -- Converting wind beats retrofitting another grid at the cap: every free T2 con starts a job at once.
        while #T.freeT2Cons > 0 and #T.windBlocks > 0 do
            local conID = T.freeT2Cons[1]
            if not Spring.GetUnitDefID(conID) then table.remove(T.freeT2Cons, 1)
            elseif StartConsolidation(T, conID, res) then table.remove(T.freeT2Cons, 1)
            else break end
        end
    end
    local i = 1
    while i <= #T.consolidateJobs do
        local cs = T.consolidateJobs[i]
        if cs.done then
            if cs.builderID and Spring.GetUnitDefID(cs.builderID) then T.freeT2Cons[#T.freeT2Cons + 1] = cs.builderID end
            table.remove(T.consolidateJobs, i)
        else
            T.BP.Update(cs, frame, res)
            i = i + 1
        end
    end
end

local StartSpine      -- defined with the spine glue below

-- The first grid: GAP elmos beyond the line's outer edge, centred on the lab (or the next cell along the line).
local function OpenFirstGrid(T, frame, labX, labZ)
    local LC = T.LC
    local bx0 = T.site.bx
    -- Beyond the edge of the lab's own side first; if that side is unbuildable (map edge, cliff), further along it,
    -- then the far side.
    local north = LINE_BOX.z0 - T.CFG.GAP - HALF_GRID
    local south = LINE_BOX.z1 + T.CFG.GAP + HALF_GRID
    local near, far = north, south
    if T.site.lane == 3 then near, far = south, north end
    -- The spine reserves its cells and exit lanes before any grid cell is seeded (grid cells then keep off them).
    if T.spineMod then StartSpine(T, frame) end
    local tries = {}
    for _, dx in ipairs({ 0, -480, 480, -960 }) do tries[#tries + 1] = { dx, near } end
    for _, dx in ipairs({ 0, -480, 480 }) do tries[#tries + 1] = { dx, far } end
    for _, try in ipairs(tries) do
        local dx, bz = try[1], try[2]
        local wx, wz = LC.World(T.L, bx0 + dx, bz)
        wx, wz = math.floor(wx / 16 + 0.5) * 16, math.floor(wz / 16 + 0.5) * 16
        -- Reuse the placer's own probe + rotation choice: ask for the east neighbour of a pseudo-anchor.
        for _, r in ipairs(T.BP.FindAllValidPlacements(T.gridBP, { { anchorX = wx - T.BP.GRID_SPACING, anchorZ = wz } })) do
            if r.anchorX == wx and r.anchorZ == wz and not T.OverlapsSpine(T, wx, wz) then
                r.rotation = T.BP.BestRotation(T.gridBP, wx, wz, labX, labZ)
                T.assigned[Key(wx, wz)] = true
                T.pendingGrids[#T.pendingGrids + 1] = r
                T.pendingSince[Key(wx, wz)] = frame
                Spring.Echo(string.format("[LT] %s first grid cell (%d, %d) rot %d, %d elmos beyond the line (b %d, %d)",
                    Clock(frame), wx, wz, r.rotation, T.CFG.GAP, bx0 + dx, bz))
                return true
            end
        end
    end
    Spring.Echo("[LT] no valid first grid cell beyond the line; grids off")
    return false
end

-- Opening every free cell at once starves the first grids of build power; pace them (TILE_BOT).
local function ReleaseCandidates(T, frame, res)
    if #T.gridCands == 0 and not T.consolidateOn
       and (T.CFG.COLLECT_ALWAYS or (res.metal >= T.CFG.GRID_BANK and frame - T.lastBankGrid >= T.CFG.GRID_BANK_GAP)) then
        local sources = {}
        for _, a in ipairs(T.completed) do sources[#sources + 1] = a end
        for _, g in ipairs(T.allAnchors) do sources[#sources + 1] = g end
        Collect(T, sources)
    end
    if #T.gridCands == 0 then return end
    local opening = #T.pendingGrids
    for _, gs in ipairs(T.gridStates) do
        if not gs.done and not gs.nanoThresholdFired then opening = opening + 1 end
    end
    -- The line is the cheapest metal sink and its nanos/cons are the build power: until it is built, grids get only
    -- the paced trickle; after that the bank / fast triggers may run up to GRIDS_OPENING_MAX at once.
    local lineBuilt = T.LC.SlotsRemaining(T.L) == 0
    local why
    local idleCon = #T.freeAirCons > #T.pendingGrids
    local energyOK = res.energyStorage > 0 and res.energy / res.energyStorage >= T.CFG.GRID_FAST_ENERGY
    local income = res.metalIncomeS or res.metalIncome or 0
    if opening < T.CFG.GRIDS_OPENING then why = "pace"
    elseif not lineBuilt then return
    elseif income >= T.CFG.GRID_FAST_INCOME and idleCon and energyOK then
        -- A big economy: expand whenever an air con stands idle.  No bank test (the army spends it), and no
        -- GRIDS_OPENING_MAX either: the idle-con test is the limit, and cons only come as fast as the air lab makes them.
        why = "fast-income"
    elseif opening >= T.CFG.GRIDS_OPENING_MAX then return
    elseif res.metal >= T.CFG.GRID_BANK and frame - T.lastBankGrid >= T.CFG.GRID_BANK_GAP then
        why, T.lastBankGrid = "bank", frame
    elseif res.metal >= T.CFG.GRID_BANK_FAST and idleCon and energyOK then
        -- Metal piling up, energy healthy and an air con standing idle: the 15 s gap is only there to stop the
        -- early game sinking its metal into slow grids.  Measured 10:00-17:30: 4-10 idle cons, 16-18 cells
        -- waiting, 230-350k banked, one grid per 15 s.
        why = "fast"
    end
    if not why then return end
    local r = table.remove(T.gridCands, 1)
    T.pendingGrids[#T.pendingGrids + 1] = r
    T.pendingSince[Key(r.anchorX, r.anchorZ)] = frame
    QueueAirCon(T, frame)
    Spring.Echo(string.format("[LT] %s grid cell (%d, %d) opened (%s: %d opening, bank %.0f, %d waiting)",
        Clock(frame), r.anchorX, r.anchorZ, why, opening, res.metal, #T.gridCands))
    TryAssignGrids(T, frame)
end

local function UpdateGrids(T, frame, res)
    if not T.firstGridOK and T.firstGrid then
        local st, n, done = T.firstGrid, 0, 0
        for _, it in ipairs(st.queue) do
            n = n + 1
            if it.status == "built" or it.status == "skipped" or it.built then done = done + 1 end
        end
        if st.done or (n > 0 and done / n >= T.CFG.AIR_CON_CAP_UNTIL) then
            LiftAirConCap(T, string.format("first grid %d%% built", n > 0 and math.floor(100 * done / n) or 100))
        end
    end
    local i = 1
    while i <= #T.gridStates do
        local gs = T.gridStates[i]
        if gs.done then
            if gs.builderID and Spring.GetUnitDefID(gs.builderID) then T.freeAirCons[#T.freeAirCons + 1] = gs.builderID end
            table.remove(T.gridStates, i)
        else
            T.BP.Update(gs, frame, res)
            i = i + 1
        end
    end
    ReleaseCandidates(T, frame, res)
    if #T.freeAirCons > 0 and #T.pendingGrids > 0 then TryAssignGrids(T, frame) end
    CheckCapPressure(T)
    UpdateRetrofits(T, frame, res)
    UpdateConsolidation(T, frame, res)
    if frame % T.CFG.RECLAIM_EVERY == 0 then UpdateWindReclaim(T) end
    UpdateSpendPressure(T, res)
    while #T.orders > 0 and frame - T.orders[1] > T.CFG.AIR_CON_TIMEOUT do
        Spring.Echo("[LT] an air con order never came out; forgetting it")
        AirConOrderDone(T)
    end
    UpdateLabAssist(T, frame)
    KeepAirConReserve(T, frame)
end

-- ── Spine (TILE_BOT's unit production, hosted here) ──────────────────────────────────────────────────────────
-- What the spine borrows (see SPINE_BRIEF.md): constructors from the air-con pool, a way to reserve grid cells, the
-- unit-cap test, and a lab.  Its stack of 480-cell blueprints lies on the grid lattice (anchored on the first grid
-- cell), is reserved when the air lab finishes (before any grid cell is seeded), and cell 1 opens when the vehicle
-- lab stands.  Everything unit-related lives in bar_framework/spine.lua.

local function SpineTakeCon(T, defID, t1Only)
    local lists = t1Only and { T.freeAirCons } or { T.freeAirCons, T.freeT2Cons }
    for _, list in ipairs(lists) do
        local i = 1
        while i <= #list do
            local cid  = list[i]
            local cdef = Spring.GetUnitDefID(cid)
            if not cdef then
                table.remove(list, i)
            elseif not defID or T.BP.CanBuild(cdef, defID) then
                table.remove(list, i)
                return cid
            else
                i = i + 1
            end
        end
    end
    return nil
end

local function SpineReturnCon(T, uid)
    local def = Spring.GetUnitDefID(uid)
    if not def then return end
    Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
    if IsT2Con(T, def) then
        T.freeT2Cons[#T.freeT2Cons + 1] = uid
        TryAssignUpgrades(T)
    else
        T.freeAirCons[#T.freeAirCons + 1] = uid
        TryAssignGrids(T, T.frame)
    end
end

-- Metal value of our finished ground army (armed, mobile, non-air, non-builder).  Gates the T2 labs.
local function SpineGroundArmyValue(T)
    if T.frame - (T.groundAVFrame or -1e9) < 15 then return T.groundAV or 0 end
    local total = 0
    for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and not d.isBuilder and not d.isFactory and not d.canFly
           and (d.speed or 0) > 0 and d.weapons and #d.weapons > 0
           and not Spring.GetUnitIsBeingBuilt(uid) then
            total = total + (d.metalCost or 0)
        end
    end
    T.groundAV, T.groundAVFrame = total, T.frame
    return total
end

-- The first three grids are at least 70% built (retrofit eligible): from here the spine releases nanos for 100% army.
local function SpineMexGridsReady(T)
    local n = 0
    for _ in pairs(T.gridFinished) do n = n + 1 end
    return n >= 3
end

local function FacingFor(dx, dz)          -- Spring facing: 0 south (+z), 1 east, 2 north, 3 west
    if dz > 0 then return 0 elseif dz < 0 then return 2 elseif dx > 0 then return 1 end
    return 3
end

-- The outer lane the vehicle lab goes on: the one the air lab did not take.
-- The vehicle lab's lane: the outer lane that faces the enemy (needs a builder on it before a site can be claimed).
local function VpLane(T)
    return T.enemyLane
end

-- Spine geometry: cell 1 sits directly in front of the vehicle lab (just outside the line, on the lab's side), so the
-- lab's two nanos reach it; the labs face away from the line and the stack of cells runs PARALLEL to the line.
-- Returns { geo, baseX, baseZ } (base = one cell behind cell 1) or nil.
local function SpineGeo(T)
    local SPINE, LC = T.spineMod, T.LC
    local lane = VpLane(T)
    if not lane then return nil end
    local out = (lane == 3) and 1 or -1                           -- b-z outward: lane 3 south of the line, lane 4 north
    local bx = T.vpSite and T.vpSite.bx or (LC.X0 + 64 * 8)       -- the lab's place along the line
    local bz = out > 0 and (LINE_BOX.z1 + T.CFG.SPINE_GAP + HALF_GRID) or (LINE_BOX.z0 - T.CFG.SPINE_GAP - HALF_GRID)
    local cx, cz = LC.World(T.L, bx, bz)
    cx, cz = math.floor(cx / 16 + 0.5) * 16, math.floor(cz / 16 + 0.5) * 16
    local fx, fz = LC.Rotate(0, out, T.L.rot)                     -- front: away from the line
    local sx, sz = LC.Rotate(1, 0, T.L.rot)                       -- stack: along the line
    local geo = SPINE.GeometryFor(fx, fz, sx, sz)
    local C = T.BP.GRID_SPACING
    local baseX, baseZ = cx - fx * C, cz - fz * C
    for n = 1, 3 do
        local ax, az = SPINE.CellAnchor(geo, baseX, baseZ, n)
        if ax < 240 or az < 240 or ax > T.L.mapX - 240 or az > T.L.mapZ - 240 then return nil end
    end
    return { geo = geo, baseX = baseX, baseZ = baseZ }
end

StartSpine = function(T, frame)
    local SPINE = T.spineMod
    if T.spineOn or not (SPINE and T.spineBPs and T.spineBPs.T1) then return end
    local g = SpineGeo(T)
    if not g then
        Spring.Echo("[LT] spine: no room in front of the vehicle lab; spine off")
        T.spineMod = nil
        return
    end
    -- Every cell and exit lane of the stack: grid cells must keep off them (their own lattice differs).
    T.spineBoxes = {}
    for n = 1, 2 * SPINE.CFG.STACK_HALF + 1 do
        local ax, az = SPINE.CellAnchor(g.geo, g.baseX, g.baseZ, n)
        local lx, lz = SPINE.LaneAnchor(g.geo, g.baseX, g.baseZ, n)
        T.spineBoxes[#T.spineBoxes + 1] = { x = ax, z = az }
        T.spineBoxes[#T.spineBoxes + 1] = { x = lx, z = lz }
    end
    SPINE.Init{
        BP_PLACER = T.BP, NANO = T.BP.NANO, blueprints = T.spineBPs,
        baseX = g.baseX, baseZ = g.baseZ, mapX = T.L.mapX, mapZ = T.L.mapZ,
        geo = g.geo, GroundOnly = true,        -- built by the vehicle lab's ground cons only, never by air cons
        EarlyCons = T.CFG.SPINE_EARLY_CONS,    -- one ground con until cell 1 is built
        AnchorKey   = Key,
        Reserve     = function(key) T.assigned[key] = true end,
        CellOK      = function(ax, az) return not InsideLine(T, ax, az) end,
        TakeCon     = function(defID, t1Only) return SpineTakeCon(T, defID, t1Only) end,
        ReturnCon   = function(uid) SpineReturnCon(T, uid) end,
        QueueAirCon = function() QueueAirCon(T, T.frame) end,
        DeferStop   = function(uid) T.pendingStops[#T.pendingStops + 1] = { id = uid, fire = T.frame + 30 } end,
        CapPressure = function()
            local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
            local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
            return (maxU and cnt and (maxU - cnt) <= CapSlack(T, T.CFG.CONSOLIDATE_SLACK)) and true or false
        end,
        Threat      = function()
            local mb = T.WG and T.WG.MetalBot
            if not mb then return nil, 0 end
            return mb.urgency, mb.threats and #mb.threats or 0
        end,
        MexGridsReady   = function() return SpineMexGridsReady(T) end,
        GroundArmyValue = function() return SpineGroundArmyValue(T) end,
    }
    -- lab_controller reads WG.Spine.  The widget's WG is passed in: a module included with VFS.Include does not
    -- see the widget environment's globals (a bare WG was nil in the real game and killed this function here).
    if T.WG then T.WG.Spine = SPINE end
    SPINE.Start(frame, { deferOpen = true })
    T.spineOn = true
    local c1x, c1z = SPINE.CellAnchor(g.geo, g.baseX, g.baseZ, 1)
    Spring.Echo(string.format("[LT] %s spine: cell 1 at (%d, %d) in front of the vehicle lab, front (%d, %d), stack along (%d, %d)",
        Clock(frame), c1x, c1z, g.geo.dx, g.geo.dz, g.geo.px, g.geo.pz))
    -- The vehicle lab can already stand (air lab finished late): hand it over now.
    if T.vpID and Spring.GetUnitDefID(T.vpID) then
        SPINE.AdoptLab(T.vpID, Spring.GetUnitDefID(T.vpID), T.CFG.VP_CONS)
        SPINE.OpenFirst()
    end
end

-- ── Vehicle lab: 4 slots (2x2) + 2 nanos on the outer lane the air lab did not take ─────────────────────────────

-- Spot: the middle of the 2x2 block, facing outward (toward the lane's corridor, which the lab's units leave by).
local function VpSpot(T, site)
    local out = (site.lane == 3) and 1 or -1            -- b-z outward: lane 3 is south of the line, lane 4 north
    local ox, oz = T.LC.Rotate(0, out, T.L.rot)
    local face = FacingFor(ox, oz)
    if not T.vpSpotLogged then
        T.vpSpotLogged = true
        local ud = UnitDefs[T.vpDefID]
        Spring.Echo(string.format("[LT] vehicle lab %s footprint %dx%d elmos, 2x2 slot block 128x128; facing %d (outward)",
            ud.name, (ud.xsize or 0) * 8, (ud.zsize or ud.ysize or 0) * 8, face))
    end
    for _, f in ipairs({ face, (face + 2) % 4, (face + 1) % 4, (face + 3) % 4 }) do
        local x, z = T.BP.SnapToBuildGrid(T.vpDefID, site.wx, site.wz, f)
        local y = Spring.GetGroundHeight(x, z) or 0
        local ok = Spring.TestBuildOrder(T.vpDefID, x, y, z, f)
        if ok and ok ~= 0 then return x, z, f end
    end
    return nil
end

local function ReleaseVpSite(T)
    if not T.vpSite then return end
    for _, s in ipairs(T.vpSite.slots) do s.state = "free" end
    for _, s in ipairs(T.vpSite.nanos) do s.state = "free" end
    T.vpSite = nil
end

-- Queued backwards from the deadline: it must be FINISHED by VP_DONE_FRAME, so it starts when
-- frame >= deadline - build time (with everything that reaches it) - margin.  Always after the air lab is queued.
local function UpdateVehicleLab(T, frame, res)
    if T.vpPhase ~= "wait" or T.phase == "off" then return end
    local LC = T.LC
    if T.vpSite and not LC.LaneBuilder(T.crew, T.vpSite.lane) then ReleaseVpSite(T) end
    if not T.vpSite then
        local lane = VpLane(T)
        local site = lane and LT.PickSite(T, { lanes = { lane }, cols = T.CFG.VP_COLS })
        if not site then
            if frame % 300 == 0 and lane and LC.LaneBuilder(T.crew, lane) then
                local open = 0
                for _, s in ipairs((lane and T.L.lanes[lane] or { slots = {} }).slots) do if s.state == "free" then open = open + 1 end end
                Spring.Echo(string.format("[LT] %s no open 2x2 block on lane %s (builder %s, %d open slots) for the vehicle lab yet",
                    Clock(frame), tostring(lane), LC.LaneBuilder(T.crew, lane or 0) and "yes" or "no", open))
            end
            return
        end
        for _, s in ipairs(site.slots) do s.state = "reserved" end
        for _, s in ipairs(site.nanos) do s.state = "reserved" end
        T.vpSite = site
    end
    local site = T.vpSite
    local ud = UnitDefNames[T.CFG.VP_NAME]
    local bdef = Spring.GetUnitDefID(site.builder)
    if not ud or not (bdef and T.BP.CanBuild(bdef, ud.id)) then
        Spring.Echo("[LT] the lane's con cannot place " .. T.CFG.VP_NAME .. "; vehicle lab off")
        ReleaseVpSite(T)
        T.vpPhase = "off"
        return
    end
    T.vpDefID = ud.id
    local x, z, f = VpSpot(T, site)
    if not x then
        if frame % 300 == 0 then Spring.Echo("[LT] " .. Clock(frame) .. " no legal spot for the vehicle lab yet") end
        return
    end
    local p = LT.LabPlan(T, res, x, z, site.builder, T.vpDefID)
    local fire = T.CFG.VP_DONE_FRAME - math.floor(p.t * 30) - T.CFG.VP_MARGIN
    if not T.labFrame then return end            -- the site is held; the air lab always goes first
    if frame % T.CFG.LOG_EVERY == 0 then
        Spring.Echo(string.format("[LT] %s vehicle lab plan: BP %.0f (%d nanos) -> %.0fs; start at %s for done by %s; bank %d",
            Clock(frame), p.bp, p.nanos, p.t, Clock(math.max(fire, 0)), Clock(T.CFG.VP_DONE_FRAME), res.metal))
    end
    if frame < fire then return end
    -- urgent: the lane's con drops the slot it is on (it was seen stuck on one) and goes straight to the lab.
    LC.QueueJob(T.crew, site.builder, { name = ud.name, x = x, z = z, f = f, tag = "vp", urgent = true })
    T.vpPhase, T.vpFrame = "lab", frame
    Spring.Echo(string.format("[LT] %s VEHICLE LAB queued (%s) at (%d, %d) facing %d; BP %.0f, %.0fs, bank %d income %.1f%s",
        Clock(frame), ud.name, x, z, f, p.bp, p.t, res.metal, res.metalIncome, p.ok and "" or " (bank short)"))
end

-- ── Job results: lab, then its nanos ────────────────────────────────────────

-- Called by line_crew when a job's frame appears: every nano in reach goes onto the lab (the vehicle lab was built
-- by its con alone while the nanos worked on other jobs).
function LT.OnJobStarted(T, j)
    if j.tag ~= "lab" and j.tag ~= "vp" then return end
    local NANO = T.BP.NANO
    if not (NANO and j.unitID) then return end
    local x, _, z = Spring.GetUnitPosition(j.unitID)
    if not x then return end
    local n = 0
    for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
        if NANO.Assist(NANO.PRIO.HANDOFF, nid, j.unitID) then n = n + 1 end
    end
    Spring.Echo(string.format("[LT] %s %s frame up: %d nano(s) assisting", Clock(T.frame), j.tag == "vp" and "vehicle lab" or "air lab", n))
end

-- Called by line_crew when a job ends.
function LT.OnJobDone(T, j, state)
    if j.tag == "lab" then
        if state ~= "done" then
            T.labTries = T.labTries + 1
            Spring.Echo(string.format("[LT] air lab job %s (try %d)", state, T.labTries))
            T.phase = T.labTries >= 3 and "off" or "wait"
            -- Give the slots back to the line; the next try picks a fresh site.
            for _, s in ipairs(T.site.slots) do s.state = "free" end
            for _, s in ipairs(T.site.nanos) do s.state = "free" end
            T.site = nil
            return
        end
        T.airLabID, T.phase = j.unitID, "grids"
        T.airConDefID = FindAirConDef(T.labDefID)
        Spring.Echo(string.format("[LT] %s AIR LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.labFrame or T.frame)) / 30))
        -- Two nanos on the open slots beside the lab, on the same con.
        local LC = T.LC
        for _, s in ipairs(T.site.nanos) do
            LC.QueueJob(T.crew, T.site.builder, { name = "cornanotc", x = s.wx, z = s.wz, f = 0, tag = "labnano" })
        end
        if #T.site.nanos < 2 then Spring.Echo("[LT] only " .. #T.site.nanos .. " open slot(s) for lab nanos") end
        T.labNanosPending = #T.site.nanos
        if T.labNanosPending == 0 then LiftAirConCap(T, "no lab nanos to wait for") end
        local lx, _, lz = Spring.GetUnitPosition(T.airLabID)
        if T.airConDefID and lx then
            OpenFirstGrid(T, T.frame, lx, lz)
            for _ = 1, 1 + T.CFG.AIR_CON_RESERVE do QueueAirCon(T, T.frame) end
        else
            Spring.Echo("[LT] the air lab has no air constructor to build")
        end
    elseif j.tag == "labnano" then
        Spring.Echo(string.format("[LT] %s lab nano %s", Clock(T.frame), state))
        if state == "done" and j.unitID then T.labNanoIDs[j.unitID] = true end
        T.labNanosPending = math.max(0, (T.labNanosPending or 1) - 1)
        if T.labNanosPending == 0 then LiftAirConCap(T, "the air lab's nanos are up") end
    elseif j.tag == "vp" then
        if state ~= "done" then
            T.vpTries = T.vpTries + 1
            Spring.Echo(string.format("[LT] vehicle lab job %s (try %d)", state, T.vpTries))
            T.vpPhase = T.vpTries >= 3 and "off" or "wait"
            ReleaseVpSite(T)
            return
        end
        T.vpID, T.vpPhase = j.unitID, "done"
        Spring.Echo(string.format("[LT] %s VEHICLE LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.vpFrame or T.frame)) / 30))
        for _, s in ipairs(T.vpSite.nanos) do
            T.LC.QueueJob(T.crew, T.vpSite.builder, { name = "cornanotc", x = s.wx, z = s.wz, f = 0, tag = "vpnano" })
        end
        if T.spineOn then
            T.spineMod.AdoptLab(j.unitID, Spring.GetUnitDefID(j.unitID), T.CFG.VP_CONS)
            T.spineMod.OpenFirst()
        end
    elseif j.tag == "vpnano" then
        Spring.Echo(string.format("[LT] %s vehicle lab nano %s", Clock(T.frame), state))
    end
end

-- ── Entry points ─────────────────────────────────────────────────────────────

function LT.Update(T, frame, res)
    T.frame = frame
    local i = 1
    while i <= #T.pendingStops do
        local ps = T.pendingStops[i]
        if frame >= ps.fire then
            if Spring.GetUnitDefID(ps.id) then Spring.GiveOrderToUnit(ps.id, CMD_STOP, {}, {}) end
            table.remove(T.pendingStops, i)
        else
            i = i + 1
        end
    end
    if T.phase == "wait" then UpdateWait(T, frame, res)
    elseif T.phase == "grids" then UpdateGrids(T, frame, res) end
    UpdateVehicleLab(T, frame, res)
    if T.spineOn then T.spineMod.Update(frame, res) end
end

function LT.OnUnitCreated(T, unitID, defID, builderID)
    if T.spineOn then T.spineMod.OnUnitCreated(unitID, defID, builderID) end
end

function LT.OnUnitFinished(T, unitID, defID, x, z)
    local d = UnitDefs[defID]
    -- A capstone (advanced) air lab can make the T2 con that does retrofits.
    if d and d.isFactory and T.upgradeBP and unitID ~= T.airLabID then
        local t2 = FindAirConDef(defID)
        if t2 and IsT2Con(T, t2) then
            for _ = 1, T.CFG.UPGRADE_CONS_PER_LAB do Spring.GiveOrderToUnit(unitID, -t2, { 0 }, {}) end
        end
    end
    -- Air cons come out guarding the lab: stop them now and again once that order has landed.
    if T.airLabID and d and d.isBuilder and d.canFly and not d.isFactory then
        Spring.GiveOrderToUnit(unitID, CMD_STOP, {}, {})
        T.pendingStops[#T.pendingStops + 1] = { id = unitID, fire = T.frame + 30 }
        if IsT2Con(T, defID) then
            T.freeT2Cons[#T.freeT2Cons + 1] = unitID
            TryAssignUpgrades(T)
        else
            AirConOrderDone(T)
            T.airConsAlive[unitID] = true
            -- Grids first (starting them fast is what scales the economy); the spine gets a new con only when
            -- no grid is waiting for one.
            if not (#T.pendingGrids == 0 and T.spineOn and T.spineMod.OfferCon(unitID)) then
                T.freeAirCons[#T.freeAirCons + 1] = unitID
                TryAssignGrids(T, T.frame)
            end
        end
    end
    if T.spineOn then T.spineMod.OnUnitFinished(unitID, defID, x, z) end
    for _, gs in ipairs(T.gridStates) do
        if not gs.done then T.BP.OnUnitFinished(gs, unitID, defID, x, z) end
    end
    for _, us in ipairs(T.upgradeStates) do
        if not us.done then T.BP.OnUnitFinished(us, unitID, defID, x, z) end
    end
    for _, cs in ipairs(T.consolidateJobs) do
        if not cs.done then T.BP.OnUnitFinished(cs, unitID, defID, x, z) end
    end
end

function LT.OnUnitFromFactory(T, unitID, defID, factID)
    if factID and factID == T.airLabID then Spring.GiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
    if T.spineOn then T.spineMod.OnUnitFromFactory(unitID, defID, factID) end
end

function LT.OnUnitDestroyed(T, unitID)
    -- A dead builder's id is KEPT in its session: the placer's Update checks Spring.GetUnitDefID(state.builderID) and
    -- ends the session itself; a nil id made that call error and removed the whole macro widget (seen at 6:30 when
    -- an enemy air raid killed an air con).
    T.airConsAlive[unitID] = nil
    if unitID == T.airLabID then T.airLabID = nil end
    if T.spineOn then T.spineMod.OnUnitDestroyed(unitID) end
end

function LT.Status(T)
    return string.format("phase %s grids %d (open %d) aircons free %d ordered %d", T.phase, T.gridsAssigned,
        #T.pendingGrids, #T.freeAirCons, T.airConsOrdered)
end

return LT
