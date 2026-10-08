-- bar_framework/spine.lua
-- The SPINE: a stack of grid cells that can only make units.
--
-- WHY THIS EXISTS
-- ---------------
-- The mex grids turn metal into economy; the spine turns it into army.  Keeping them
-- separate lets the unit/eco split be ONE number (army_share) instead of a tangle of
-- nano reassignments, and it lets the bot react fast: a spine cell has a long lead time
-- (nanos, labs, cons for the next tier), so the bot keeps enough of them standing to
-- spend ALL of its income on units if it ever wants to, then throttles the nanos.
--
-- HOW IT IS BUILT
--   * Cells are 480x480 blueprints (T1Spine / T2Spine / T3Spine).  They stack along one
--     axis, starting on the enemy-facing side of the starter base.  Labs exit toward the
--     enemy; the cell on that side of every spine cell is reserved as an exit lane.
--   * A cell is built by blueprint_placer's DISTRIBUTED mode, so several builders (air
--     cons, plus ground cons the spine's own T1 labs make) share one queue and each
--     takes what it is able to place.  Items nobody can place raise a con request, which
--     the lab hook (NextOrder) answers.
--   * A NEW CELL OPENS WHEN capacity < current metal income.  Capacity is what the
--     assigned T2/T3 cells could spend at a theoretical 100% unit spend, not what is
--     being spent on units now.  Cells are cheap and their lead time is long, so the
--     bot keeps them ahead of the economy.
--
-- HOW IT IS CONTROLLED
--   * army_share (0..1) is the fraction of income spent on units.  It comes from an
--     ordered list of POLICIES (M.policies); each takes the share so far and returns a
--     new one.  Add threat/opportunity logic with M.AddPolicy -- nothing else changes.
--   * share x income = unit metal wanted.  The spine turns that into a fraction f of
--     its theoretical capacity and keeps f of each lab's nanos guarding the lab; the
--     rest are parked.  Whole nanos only, a few moves per tick, so it does not thrash.
--
-- USAGE (macro_controller)
--   SPINE.Init{...}  once       SPINE.Start(frame)  when the air lab is up
--   SPINE.Update(frame, res)    every 10 frames
--   SPINE.OnUnitCreated / OnUnitFinished / OnUnitFromFactory / OnUnitDestroyed
-- USAGE (lab_controller, via WG.Spine)
--   SPINE.IsLab(labID)   SPINE.NextOrder(labID, labDefID)   SPINE.CFG.QUEUE_DEPTH

local M = {}

-- ── Tunables: everything worth changing lives here ───────────────────────────

M.CFG = {
    CELL              = 480,    -- elmos between cells; must equal BP_PLACER.GRID_SPACING
    STACK_HALF        = 4,      -- cells reserved on each side of the first one
    START_FRAME       = 5400,   -- army_share is 0 before this (3:00).  The T2 labs wait for ground
                                -- army value, and only T1 labs can make it, so it starts early.
    FLOOR             = 0.20,   -- army_share from START_FRAME on
    EXPAND_FROM       = 5400,   -- T2+ cells may open from here (3:00)
    EXPAND_MARGIN     = 1.0,    -- open another cell while capacity < margin x income
    MAX_OPENING       = 2,      -- cells under construction at once
    SETTLED_FRAC      = 0.9,    -- a cell counts as built once this share of items settled
    PLAN              = { "T1", "T2", "T2" },   -- kind of cell 1, 2, 3 ...
    DEFAULT_KIND      = "T3",                   -- ... then this
    BUILDERS_PER_CELL = 2,      -- air cons on each cell beyond the one-per-missing-item
    AIR_CONS_PER_CELL = 0,      -- air cons queued when a cell opens (cells use the ground cons
                                -- the T1 labs make; the macro caps air cons at 3 early on)
    ABSORB_SECONDS    = 2.5,    -- a lab takes at most buildTime/this BP (game_mechanics 2.5)
    UPDATE_EVERY      = 30,     -- frames between control ticks
    MOVES_MAX         = 6,      -- nanos switched per tick
    QUEUE_DEPTH       = 3,      -- units kept queued in each spine lab
    CON_ORDER_TTL     = 1800,   -- frames before an unanswered con order is repeated
    PARK_NANOS        = true,   -- park idle spine nanos (see PARK_NOTE in nano_broker)
    LOG_EVERY         = 1800,   -- frames between status lines
    INCOME_SMOOTH     = 0.1,    -- EMA weight per update for the income the spine reacts to
    -- Nano throttle.  Building nanos pulls a lot of metal, so a cell is opened with its
    -- lab(s) and only CORE_NANOS nanos; the rest of its nanos wait ("held") and are let
    -- go only as army spending needs them.
    THROTTLE_NANOS    = true,
    CORE_NANOS        = 4,      -- nanos built with each lab, the ones closest to it
    -- Labs are held too.  The T1 cell's FIRST lab and its core nanos are hard-coded (built at
    -- once); every other lab is released later: a T2/T3 lab once our ground army value is at
    -- least its metal cost (a lab that costs more than the army we have is a lab we cannot
    -- feed); the T1 cell's second lab once army share is above zero and this long after the
    -- first lab finished (its con places the T2 vehicle plant).
    LAB_GATE_AV       = true,
    LAB_GATE_MARGIN   = 1.0,    -- ground army value must reach margin x lab cost
    T1_LAB2_DELAY     = 3600,   -- frames (2 min) after the first T1 lab finishes
    NANO_HEADROOM    = 1.15,   -- keep this much nano capacity over what units should absorb
    NANO_BATCH        = 4,      -- nanos released per control tick, at most
    NANO_INFLIGHT_MAX = 6,      -- released nanos that may be unfinished at once
    -- Threat: army_share is lifted while the unit controller sees a threat, and held this
    -- long after the last sighting so labs and nanos do not thrash.
    THREAT_RUSH       = 1.0,    -- production urgency "rush" (outmatched)
    THREAT_BUILD      = 0.6,    -- urgency "build" (thin cover)
    THREAT_SEEN       = 0.5,    -- enemies inside the line, urgency "none"
    THREAT_HOLD       = 900,    -- frames (30 s)
    -- Once the first mex grids are mostly built, nanos for 100% army spend are let go
    -- whatever the current share: spending then needs no build-up (env.MexGridsReady).
    -- Army units cost ~15 energy per metal, so energy has to be ready too:
    ENERGY_BUFFER_S   = 30,     -- storage worth this many seconds of full army spend
    STORE_BATCH       = 2,      -- held energy storages released per control tick, at most
    STORE_INFLIGHT_MAX = 4,     -- released storages that may be unfinished at once
    GEN_COVER         = 0.25,   -- generation floor: eco pull + this share of full army spend
    STORE_UNIT        = "corestor",
}

-- Blueprint file (blueprints/general/<name>.lua) for each kind of cell.
M.BLUEPRINT = { T1 = "T1Spine", T2 = "T2Spine", T3 = "T3Spine" }

-- The unit each lab type is sized and stocked with.  First name that exists wins.
-- (corsumo = Mammoth, correap = Tiger, cordemon = Demon.)  T1 labs are not listed:
-- their capacity is ignored and they only make cons (below).
M.LAB_UNITS = {
    coralab = { "corsumo" },
    coravp  = { "correap" },
    corgant = { "cordemon" },
}

-- Hard-coded cons for the T1 spine: {con unit, how many}.  A T1 bot con places the T2
-- bot lab, a T1 vehicle con the T2 vehicle plant.  Anything more is asked for on demand.
M.T1_CONS = {
    corlab = { "corck", 2 },
    corvp  = { "corcv", 1 },
}

-- ── Policies: how much of income goes to units ───────────────────────────────
-- fn(share, c) -> share.  c = {frame, income, capPressure, capacity, spineCells, ...}.
-- Applied in order; the result is clamped to 0..1.  Replace or insert freely.

local threatLevel, threatLast = 0, -1e9

M.policies = {
    { name = "schedule", fn = function(share, c)
        if c.frame < M.CFG.START_FRAME then return 0 end
        return M.CFG.FLOOR
    end },
    -- A threat rushes army spending, before the 5:00 start too.  c.baseShare keeps the
    -- share without it, which sizes the nano throttle (a threat is not a reason to
    -- build nanos for a fight that is over in a minute).
    { name = "threat", fn = function(share, c)
        c.baseShare = share
        local K = M.CFG
        local sig = 0
        if c.threatUrgency == "rush" then sig = K.THREAT_RUSH
        elseif c.threatUrgency == "build" then sig = K.THREAT_BUILD
        elseif (c.threatCount or 0) > 0 then sig = K.THREAT_SEEN end
        if sig > 0 then
            if sig >= threatLevel or c.frame - threatLast > K.THREAT_HOLD then threatLevel = sig end
            threatLast = c.frame
        elseif c.frame - threatLast > K.THREAT_HOLD then
            threatLevel = 0
        end
        return math.max(share, threatLevel)
    end },
    { name = "cap_override", fn = function(share, c)
        -- Near the unit cap, units are the only thing worth spending on.
        if c.capPressure then return 1 end
        return share
    end },
}

-- Add a policy.  `index` places it (default: last).  Returns the policy.
function M.AddPolicy(name, fn, index)
    local p = { name = name, fn = fn }
    if index then table.insert(M.policies, index, p)
    else M.policies[#M.policies + 1] = p end
    return p
end

function M.RemovePolicy(name)
    for i = #M.policies, 1, -1 do
        if M.policies[i].name == name then table.remove(M.policies, i) end
    end
end

-- ── Helpers ──────────────────────────────────────────────────────────────────

local S = nil    -- module state, rebuilt by Init
local failed = {}

local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end

local function RotateOffset(x, z, r)    -- same convention as blueprint_placer
    if     r == 0 then return  x,  z
    elseif r == 1 then return -z,  x
    elseif r == 2 then return -x, -z
    elseif r == 3 then return  z, -x
    end
    return x, z
end

-- Spring facing for an axis-aligned direction: 0 south, 1 east, 2 north, 3 west.
local function FacingFor(dx, dz)
    if dz > 0 then return 0 elseif dz < 0 then return 2 elseif dx > 0 then return 1 end
    return 3
end
M.FacingFor = FacingFor

local function IsNanoDef(d)
    return d ~= nil and d.isBuilder and not d.isFactory and (d.speed == nil or d.speed == 0)
           and not d.canFly
end

local function HalfExtent(d)
    return math.max(d.xsize or 0, d.zsize or d.ysize or 0) * 8 / 2
end

local function RefUnit(labName)
    local names = M.LAB_UNITS[labName]
    if not names then return nil end
    for _, n in ipairs(names) do
        local d = UnitDefNames[n]
        if d then return d end
    end
    return nil
end
M.RefUnit = RefUnit

-- Metal per second a lab turns into its reference unit with `bp` build power behind it.
local function LabRate(labDef, bp)
    local u = RefUnit(labDef.name)
    if not u then return 0 end
    local bt = u.buildTime or 0
    if bt <= 0 then return 0 end
    local eff = math.min(bp, bt / M.CFG.ABSORB_SECONDS)
    return eff * (u.metalCost or 0) / bt
end
M.LabRate = LabRate

-- ── Geometry ─────────────────────────────────────────────────────────────────

-- Which way is the enemy, which way do cells stack, how must the blueprint turn.
-- The enemy is assumed to sit at the point mirror of our start (the map is symmetric).
-- "front" (dx, dz) is the way cells step away from the base and the labs face; the stack runs along (px, pz).
-- With only (dx, dz) the stack is perpendicular to it (the enemy-facing default); a host may give both axes.
function M.GeometryFor(dx, dz, px, pz)
    local rot = 0
    for r = 0, 3 do      -- blueprint east (+x) must point along the front
        local rx, rz = RotateOffset(1, 0, r)
        if rx == dx and rz == dz then rot = r end
    end
    return { dx = dx, dz = dz, px = px or dz, pz = pz or dx, rot = rot, facing = FacingFor(dx, dz) }
end

function M.Geometry(baseX, baseZ, mapX, mapZ)
    local ex, ez = mapX - 2 * baseX, mapZ - 2 * baseZ
    local dx, dz
    if math.abs(ex) >= math.abs(ez) then dx, dz = (ex >= 0) and 1 or -1, 0
    else dx, dz = 0, (ez >= 0) and 1 or -1 end
    return M.GeometryFor(dx, dz)
end

-- Cell number (1 = in front of the base) to its offset along the stack: 0, +1, -1, +2 ...
function M.StackOffset(i)
    if i <= 1 then return 0 end
    local m = math.floor(i / 2)
    return (i % 2 == 0) and m or -m
end

function M.CellAnchor(geo, baseX, baseZ, i)
    local C, k = M.CFG.CELL, M.StackOffset(i)
    return baseX + geo.dx * C + geo.px * k * C, baseZ + geo.dz * C + geo.pz * k * C
end

function M.LaneAnchor(geo, baseX, baseZ, i)
    local ax, az = M.CellAnchor(geo, baseX, baseZ, i)
    return ax + geo.dx * M.CFG.CELL, az + geo.dz * M.CFG.CELL
end

-- ── Capacity ─────────────────────────────────────────────────────────────────

-- What a blueprint could spend on units at a theoretical 100%, in metal/s.  Each nano
-- counts toward the nearest lab it can reach.  Returns metal/s, nanos counted.
function M.LayoutCapacity(layout)
    local labs, nanos = {}, {}
    for _, u in ipairs(layout) do
        local d = UnitDefNames[u.n]
        if d and d.isFactory then
            labs[#labs + 1] = { x = u.x, z = u.z, def = d, bp = d.buildSpeed or 0 }
        elseif IsNanoDef(d) then
            nanos[#nanos + 1] = { x = u.x, z = u.z, d = d }
        end
    end
    local counted = 0
    for _, n in ipairs(nanos) do
        local best, bd2 = nil, math.huge
        for _, l in ipairs(labs) do
            local d2 = (n.x - l.x) ^ 2 + (n.z - l.z) ^ 2
            local reach = (n.d.buildDistance or 128) + HalfExtent(l.def)
            if d2 <= reach * reach and d2 < bd2 then best, bd2 = l, d2 end
        end
        if best then best.bp = best.bp + (n.d.buildSpeed or 0); counted = counted + 1 end
    end
    local total = 0
    for _, l in ipairs(labs) do total = total + LabRate(l.def, l.bp) end
    return total, counted
end

-- ── State ────────────────────────────────────────────────────────────────────

-- env = {
--   BP_PLACER, NANO,
--   blueprints = {T1=layoutTable, T2=..., T3=...},
--   baseX, baseZ, mapX, mapZ,
--   AnchorKey(x, z) -> string,
--   Reserve(key)               -- mark a cell as taken so mex grids stay off it
--   TakeCon(defID, t1Only)     -- remove and return a free con able to build defID
--   ReturnCon(unitID)          -- hand an air con back
--   QueueAirCon()              -- ask the air lab for one more
--   DeferStop(unitID)          -- STOP again shortly (the factory's guard lands late)
--   CapPressure() -> bool
--   CellOK(ax, az) -> bool     -- optional: veto a cell position
--   geo                        -- optional: M.GeometryFor(...) instead of the enemy-facing default
--   EarlyCons                  -- optional: max ground cons until cell 1 is built (see ConsAllowed)
--   GroundOnly                 -- optional: cells are built only by ground cons of the spine's own labs (no air cons)
-- }
function M.Init(env)
    S = {
        env = env, started = false, frame = 0, geo = nil,
        cells = {}, opened = 0,
        labs = {}, nanos = {}, cons = {},      -- uid -> info
        conWanted = {}, conPending = {},       -- defID -> true / frame
        share = 0, income = 0, capacity = 0, builtCapacity = 0,
        parked = 0, active = 0, leak = 0,
        capByKind = {},
        lastLog = -1e9,
    }
    S.nanoRate = nil
    for kind, layout in pairs(env.blueprints or {}) do
        local cap, n = M.LayoutCapacity(layout.layout or layout)
        S.capByKind[kind] = cap
        -- Metal/s one extra nano lets a T2/T3 lab absorb: sizes the throttle below.
        if kind ~= "T1" and n > 0 then
            local r = cap / n
            if not S.nanoRate or r < S.nanoRate then S.nanoRate = r end
        end
        Spring.Echo(string.format("[SPINE] %s cell: %d nanos reach a lab, %.0f M/s at 100%% units",
            kind, n, cap))
    end
    S.nanoRate = S.nanoRate or 8
    -- Energy per metal of what the labs make: sizes the energy buffer (see ENERGY_BUFFER_S).
    local sum, cnt = 0, 0
    for name in pairs(M.LAB_UNITS) do
        local u = RefUnit(name)
        if u and (u.metalCost or 0) > 0 then
            sum = sum + (u.energyCost or 0) / u.metalCost
            cnt = cnt + 1
        end
    end
    S.R = cnt > 0 and sum / cnt or 15
    local sd = UnitDefNames[M.CFG.STORE_UNIT]
    S.storePer = (sd and sd.energyStorage and sd.energyStorage > 0) and sd.energyStorage or 6000
    return S
end

function M.State() return S end

local function Cfg() return M.CFG end

local function NextKind()
    local n = S.opened + 1
    return Cfg().PLAN[n] or Cfg().DEFAULT_KIND
end

-- Capacity of every T2/T3 cell that has been assigned, finished or not.  This is the
-- number that decides whether to open another: lead time means counting what is
-- coming, not just what is standing.
local function AssignedCapacity()
    local c = 0
    for _, cell in ipairs(S.cells) do c = c + (S.capByKind[cell.kind] or 0) end
    return c
end

-- Held items: nanos the throttle has not let go of yet.  The placer skips an item whose
-- waitsFor is unfinished, so a shared sentinel keeps it untouched until it is released.
local HOLD = { status = "held" }

local function IsHeld(item) return item.waitsFor == HOLD end

-- Anything the placer could be working on right now?
local function ActiveWork(st)
    for _, it in ipairs(st.queue) do
        if it.status ~= "built" and it.status ~= "skipped" and not IsHeld(it) then
            return true
        end
    end
    return false
end

-- Share of the NON-held items that are settled (held ones are not outstanding work).
local function SettledFrac(st)
    local n, done = 0, 0
    for _, it in ipairs(st.queue) do
        if not IsHeld(it) then
            n = n + 1
            if it.status == "built" or it.status == "skipped" then done = done + 1 end
        end
    end
    if n == 0 then return 1 end
    return done / n
end

local function Hold(it)
    it.spineWaits = it.waitsFor
    it.waitsFor = HOLD
end

local function Unhold(it)
    if it.waitsFor == HOLD then
        it.waitsFor = it.spineWaits
        it.spineWaits = nil
    end
end

-- Every nano belongs to the lab nearest it.  A lab's CORE_NANOS nearest nanos are its core
-- (kept in lab.coreNanos); every other nano is held and goes on cell.held for the throttle.
local function HoldNanos(cell)
    local labs, nanos = {}, {}
    for _, it in ipairs(cell.state.queue) do
        if it.act ~= "reclaim" then
            if it.cls == "factory" then labs[#labs + 1] = it
            elseif it.cls == "nano" then nanos[#nanos + 1] = it end
        end
    end
    for _, n in ipairs(nanos) do
        local best, owner = math.huge, nil
        for _, l in ipairs(labs) do
            local d2 = (n.wx - l.wx) ^ 2 + (n.wz - l.wz) ^ 2
            if d2 < best then best, owner = d2, l end
        end
        n.labDist, n.spLab = best, owner
    end
    table.sort(nanos, function(a, b)
        if a.labDist ~= b.labDist then return a.labDist < b.labDist end
        return (a.idx or 0) < (b.idx or 0)
    end)
    for _, l in ipairs(labs) do l.coreNanos = {} end
    cell.held = {}
    for _, n in ipairs(nanos) do
        local l = n.spLab
        if l and #l.coreNanos < Cfg().CORE_NANOS then
            l.coreNanos[#l.coreNanos + 1] = n
        else
            Hold(n)
            cell.held[#cell.held + 1] = n
        end
    end
end

-- Hold labs (and their core nanos with them).  The T1 cell's first lab is hard-coded and
-- stays; ThrottleLabs releases the rest.  Call after HoldNanos.
local function HoldLabs(cell)
    cell.heldLabs = {}
    local first = (cell.kind == "T1")
    for _, it in ipairs(cell.state.queue) do
        if it.cls == "factory" and it.act ~= "reclaim" then
            if first then
                first = false
            else
                Hold(it)
                for _, n in ipairs(it.coreNanos or {}) do Hold(n) end
                cell.heldLabs[#cell.heldLabs + 1] = it
            end
        end
    end
    table.sort(cell.heldLabs, function(a, b)
        local ca = UnitDefs[a.defID] and UnitDefs[a.defID].metalCost or 0
        local cb = UnitDefs[b.defID] and UnitDefs[b.defID].metalCost or 0
        if ca ~= cb then return ca < cb end
        return (a.idx or 0) < (b.idx or 0)
    end)
end

-- Energy storages wait too, and are released as the energy buffer needs them.
local function HoldStorage(cell)
    cell.heldStore = {}
    for _, it in ipairs(cell.state.queue) do
        if it.n == Cfg().STORE_UNIT and it.act ~= "reclaim" then
            it.spineWaits = it.waitsFor
            it.waitsFor = HOLD
            cell.heldStore[#cell.heldStore + 1] = it
        end
    end
end

local function ReleaseHeld(cell, k, list)
    list = list or "held"
    local n = 0
    while n < k and cell[list] and #cell[list] > 0 do
        local it = table.remove(cell[list], 1)
        it.waitsFor = it.spineWaits
        it.spineWaits = nil
        n = n + 1
    end
    return n
end

local function InCell(x, z)
    local half = Cfg().CELL / 2
    for i, cell in ipairs(S.cells) do
        if math.abs(x - cell.ax) <= half and math.abs(z - cell.az) <= half then return i end
    end
    return nil
end

-- ── Opening cells ────────────────────────────────────────────────────────────

local function InMap(env, x, z)
    local m = Cfg().CELL / 2
    return x >= m and z >= m and x <= env.mapX - m and z <= env.mapZ - m
end

local function OpenCell(kind)
    local env = S.env
    local layout = env.blueprints and env.blueprints[kind]
    if not layout then return nil end
    -- Skip positions that fall off the map rather than stalling the whole spine.
    local ax, az
    for _ = 1, 2 * Cfg().STACK_HALF + 1 do
        S.opened = S.opened + 1
        ax, az = M.CellAnchor(S.geo, env.baseX, env.baseZ, S.opened)
        if math.abs(M.StackOffset(S.opened)) > Cfg().STACK_HALF then return nil end
        if InMap(env, ax, az) and (not env.CellOK or env.CellOK(ax, az)) then break end
        ax = nil
    end
    if not ax then return nil end

    local st = env.BP_PLACER.NewDistributed(layout, ax, az, S.geo.rot, {})
    -- Facing is set here, not taken from the blueprint: the placer adds the rotation to
    -- each f in the opposite sense to how it turns the offsets, so a rotated cell would
    -- point its labs the wrong way.  Every factory exits toward the enemy.
    for _, item in ipairs(st.queue) do
        if item.cls == "factory" then item.f = S.geo.facing end
    end
    local cell = { kind = kind, ax = ax, az = az, state = st, index = S.opened,
                   key = env.AnchorKey(ax, az), settled = false, done = false }
    S.cells[#S.cells + 1] = cell
    if Cfg().THROTTLE_NANOS then HoldNanos(cell) end
    if kind == "T1" or Cfg().LAB_GATE_AV then HoldLabs(cell) end
    HoldStorage(cell)
    st.onComplete = function() cell.done = true end
    for _ = 1, Cfg().AIR_CONS_PER_CELL do env.QueueAirCon() end
    Spring.Echo(string.format(
        "[SPINE] opened %s cell #%d at (%d, %d), %d items (%d nanos held back), "
        .. "capacity now %.0f M/s (income %.0f)",
        kind, S.opened, ax, az, #st.queue, cell.held and #cell.held or 0,
        AssignedCapacity(), S.income))
    return cell
end

-- Reserve the whole stack and its lane up front, so mex grids cannot grow over a cell
-- the spine will want later or over the exits.
local function ReserveStack()
    local env = S.env
    for i = 1, 2 * Cfg().STACK_HALF + 1 do
        local ax, az = M.CellAnchor(S.geo, env.baseX, env.baseZ, i)
        local lx, lz = M.LaneAnchor(S.geo, env.baseX, env.baseZ, i)
        env.Reserve(env.AnchorKey(ax, az))
        env.Reserve(env.AnchorKey(lx, lz))
    end
end

-- Call when the air lab finishes (the same moment the mex grids start).  opts.deferOpen: only reserve the
-- stack now; the host calls M.OpenFirst() when it wants cell 1 built (LINE_BOT: once its vehicle lab stands).
-- env.CellOK(ax, az) -> bool (optional): the host can veto a cell position (LINE_BOT: on the line).
function M.Start(frame, opts)
    if not S or S.started then return end
    local env = S.env
    S.geo = env.geo or M.Geometry(env.baseX, env.baseZ, env.mapX, env.mapZ)
    S.started = true
    ReserveStack()
    Spring.Echo(string.format(
        "[SPINE] start: enemy direction (%d, %d), rotation %d, lab facing %d, stack along (%d, %d)",
        S.geo.dx, S.geo.dz, S.geo.rot, S.geo.facing, S.geo.px, S.geo.pz))
    if opts and opts.deferOpen then S.firstDeferred = true; return end
    OpenCell("T1")
end

function M.OpenFirst()
    if not S or not S.started or not S.firstDeferred then return false end
    S.firstDeferred = false
    return OpenCell("T1") ~= nil
end

-- A lab the host built itself (LINE_BOT's vehicle plant on the line).  It is not inside any cell, but the spine
-- queues its hard-coded cons and demanded cons like a T1 cell lab's, and collects the cons it makes.
function M.AdoptLab(uid, defID, cons)
    if not S then return false end
    local d = UnitDefs[defID or Spring.GetUnitDefID(uid) or -1]
    if not d then return false end
    S.labs[uid] = { cell = 0, name = d.name, conMade = 0, conWant = cons }
    return true
end

-- ── Builders ─────────────────────────────────────────────────────────────────

local function PendingDefs(st)
    local defs = {}
    for _, item in ipairs(st.queue) do
        if item.act ~= "reclaim" and item.defID and not IsHeld(item)
           and item.status ~= "built" and item.status ~= "skipped" then
            defs[item.defID] = true
        end
    end
    return defs
end

local function BuilderCanBuild(st, defID)
    for _, b in ipairs(st.builders) do
        local bd = Spring.GetUnitDefID(b)
        if bd and S.env.BP_PLACER.CanBuild(bd, defID) then return true end
    end
    return false
end

-- An idle ground con one of our T1 labs made, able to place defID.
local function TakeOwnCon(defID)
    for uid, state in pairs(S.cons) do
        local bd = Spring.GetUnitDefID(uid)
        if not bd then S.cons[uid] = nil
        elseif state == true and S.env.BP_PLACER.CanBuild(bd, defID) then
            S.cons[uid] = "busy"
            return uid
        end
    end
    return nil
end

local function GiveBuilder(cell, uid)
    if S.env.BP_PLACER.AddBuilder(cell.state, uid) then return true end
    return false
end

-- Hand a cell's builders back (air cons to the pool, ground cons to idle).
local function ReleaseBuilders(cell)
    local env, st = S.env, cell.state
    local list = {}
    for i, uid in ipairs(st.builders) do list[i] = uid end
    for _, uid in ipairs(list) do
        env.BP_PLACER.RemoveBuilder(st, uid)
        if Alive(uid) then
            local d = UnitDefs[Spring.GetUnitDefID(uid)]
            if d and d.canFly then env.ReturnCon(uid)
            elseif S.cons[uid] then
                S.cons[uid] = true
                Spring.GiveOrderToUnit(uid, 0, {}, {})
            end
        end
    end
end

local function ServiceCellBuilders(cell)
    local env, st = S.env, cell.state
    -- Only held nanos left: nothing to build, so do not sit on cons.
    if not ActiveWork(st) then
        if #st.builders > 0 then ReleaseBuilders(cell) end
        return
    end
    for defID in pairs(PendingDefs(st)) do
        if BuilderCanBuild(st, defID) then
            S.conWanted[defID] = nil
        else
            local uid = TakeOwnCon(defID) or (not env.GroundOnly and env.TakeCon(defID, false)) or nil
            if uid then GiveBuilder(cell, uid) else S.conWanted[defID] = true end
        end
    end
    local nano = UnitDefNames.cornanotc
    if nano then
        while #st.builders < Cfg().BUILDERS_PER_CELL do
            local uid = TakeOwnCon(nano.id) or (not env.GroundOnly and env.TakeCon(nano.id, true)) or nil
            if not uid then break end
            if not GiveBuilder(cell, uid) then break end
        end
    end
end

-- A ground con from the build order (not one of our T1 labs' cons) joins the spine's idle
-- cons instead of going off to build a radar.
function M.AdoptCon(uid)
    if not S or not uid then return false end
    if not Spring.GetUnitDefID(uid) then return false end
    S.cons[uid] = true
    Spring.GiveOrderToUnit(uid, 0, {}, {})
    return true
end

-- A new T1 air con is offered here before the mex grids see it.  Taken if a cell is
-- short of builders and the con can place something that cell still needs.
function M.OfferCon(uid)
    if not S or not S.started or S.env.GroundOnly then return false end
    local bd = Spring.GetUnitDefID(uid)
    if not bd then return false end
    for _, cell in ipairs(S.cells) do
        if not cell.done and #cell.state.builders < Cfg().BUILDERS_PER_CELL then
            local useful = false
            for defID in pairs(PendingDefs(cell.state)) do
                if S.env.BP_PLACER.CanBuild(bd, defID) then useful = true; break end
            end
            if useful and GiveBuilder(cell, uid) then return true end
        end
    end
    return false
end

-- A finished cell gives its builders back.
local function ReleaseCell(cell)
    ReleaseBuilders(cell)
    Spring.Echo(string.format("[SPINE] cell #%d (%s) complete", cell.index, cell.kind))
end

-- ── Nano control ─────────────────────────────────────────────────────────────

local function ModeOf(uid, n)
    -- Trust our record only while the broker still holds the assignment.
    local a = S.env.NANO.Assignment(uid)
    if n.mode == "park" then
        if a and a.prio == S.env.NANO.PRIO.SPINE and a.mode == "park" then return "park" end
    elseif n.mode == "active" then
        if a and a.prio == S.env.NANO.PRIO.SPINE and a.mode == "guard" then return "active" end
    end
    return nil
end

local function NearestLab(uid, n)
    local ux, _, uz = Spring.GetUnitPosition(uid)
    if not ux then return nil end
    local nd = UnitDefs[Spring.GetUnitDefID(uid)]
    local best, bd2 = nil, math.huge
    for lid, l in pairs(S.labs) do
        if l.cell == n.cell and Alive(lid) and not Spring.GetUnitIsBeingBuilt(lid) then
            local lx, _, lz = Spring.GetUnitPosition(lid)
            if lx then
                local d2 = (ux - lx) ^ 2 + (uz - lz) ^ 2
                local reach = ((nd and nd.buildDistance) or 128)
                              + HalfExtent(UnitDefs[Spring.GetUnitDefID(lid)])
                if d2 <= reach * reach and d2 < bd2 then best, bd2 = lid, d2 end
            end
        end
    end
    return best
end

local function SetMode(uid, n, mode, lab)
    local NANO = S.env.NANO
    -- More important work (a hand-off assist, a reclaim) keeps the nano; Release would
    -- throw that assignment away.
    local a = NANO.Assignment(uid)
    if a and a.prio < NANO.PRIO.SPINE then return false end
    NANO.Release(uid)
    if mode == "active" then
        if NANO.Guard(NANO.PRIO.SPINE, uid, lab) then n.mode = "active"; return true end
    elseif Cfg().PARK_NANOS then
        if NANO.Park(NANO.PRIO.SPINE, uid) then n.mode = "park"; return true end
    else
        n.mode = nil
        return true
    end
    n.mode = nil
    return false
end

local function UpdateNanos()
    -- Group the managed nanos by the lab they serve.  Only cells that are built (the
    -- rest must keep auto-assisting construction) and only T2+ (T1 labs just make cons).
    local byLab = {}
    for uid, n in pairs(S.nanos) do
        if not Alive(uid) then S.nanos[uid] = nil
        else
            n.mode = ModeOf(uid, n)
            local cell = S.cells[n.cell]
            if cell and cell.kind ~= "T1" and cell.settled
               and not Spring.GetUnitIsBeingBuilt(uid) then
                n.lab = NearestLab(uid, n)
                if n.lab then
                    local g = byLab[n.lab]
                    if not g then g = { list = {}, bp = 0 }; byLab[n.lab] = g end
                    local d = UnitDefs[Spring.GetUnitDefID(uid)]
                    g.list[#g.list + 1] = uid
                    g.bp = g.bp + ((d and d.buildSpeed) or 0)
                end
            else
                n.lab = nil
            end
        end
    end

    -- Theoretical 100% capacity of what is actually standing.
    local cap = 0
    for lid, g in pairs(byLab) do
        local ld = UnitDefs[Spring.GetUnitDefID(lid)]
        g.cap = LabRate(ld, g.bp + (ld.buildSpeed or 0))
        cap = cap + g.cap
        table.sort(g.list)
    end
    S.builtCapacity = cap

    local want = S.share * S.income
    local f = (cap > 0) and math.min(1, want / cap) or 0

    local moves, active, parked, leak = 0, 0, 0, 0
    for lid, g in pairs(byLab) do
        local total = #g.list
        local target = 0
        if f > 0 then target = math.min(total, math.max(1, math.ceil(f * total - 1e-9))) end
        local cur = 0
        for _, uid in ipairs(g.list) do
            if S.nanos[uid].mode == "active" then cur = cur + 1 end
        end
        -- Park extras first, then wake more; a few per tick.
        if cur > target then
            for i = #g.list, 1, -1 do
                if moves >= Cfg().MOVES_MAX or cur <= target then break end
                local uid = g.list[i]
                if S.nanos[uid].mode == "active" then
                    if SetMode(uid, S.nanos[uid], "park") then cur = cur - 1; moves = moves + 1 end
                end
            end
        elseif cur < target then
            for i = 1, #g.list do
                if moves >= Cfg().MOVES_MAX or cur >= target then break end
                local uid = g.list[i]
                if S.nanos[uid].mode ~= "active" then
                    if SetMode(uid, S.nanos[uid], "active", lid) then cur = cur + 1; moves = moves + 1 end
                end
            end
        end
        -- Anything that is neither guarding nor parked (a new nano, or one the engine
        -- woke up) is parked, so no spine nano drifts into auto-assist unnoticed.
        for i = 1, #g.list do
            if moves >= Cfg().MOVES_MAX then break end
            local uid = g.list[i]
            if S.nanos[uid].mode == nil then
                if SetMode(uid, S.nanos[uid], "park") then moves = moves + 1 end
            end
        end
        for _, uid in ipairs(g.list) do
            local m = S.nanos[uid].mode
            if m == "active" then active = active + 1
            elseif m == "park" then
                parked = parked + 1
                if Spring.GetUnitIsBuilding(uid) then leak = leak + 1 end
            end
        end
    end
    S.active, S.parked, S.leak = active, parked, leak
end

-- ── Nano throttle ────────────────────────────────────────────────────────────
-- How many nanos should exist: enough for units to absorb share x income, plus headroom.
-- T2/T3 cells only; the T1 cell keeps its core nanos.  Whole batches are let go while the
-- number still being built is small, so a rise in army spending does not become a spike
-- in infrastructure spending of its own.
local function CellHasLab(cell)
    for _, it in ipairs(cell.state.queue) do
        if it.cls == "factory" and it.act ~= "reclaim" and it.status == "built" then
            return true
        end
    end
    return false
end

local function ThrottleNanos()
    if not Cfg().THROTTLE_NANOS then return end
    local allowed, inflight = 0, 0
    for _, cell in ipairs(S.cells) do
        if cell.kind ~= "T1" then
            for _, it in ipairs(cell.state.queue) do
                if it.cls == "nano" and it.act ~= "reclaim" and not IsHeld(it)
                   and it.status ~= "skipped" then
                    allowed = allowed + 1
                    if it.status ~= "built" then inflight = inflight + 1 end
                end
            end
        end
    end
    -- After the first mex grids are mostly built the nanos for 100% spend are let go
    -- whatever the share; before that, only what the (non-threat) share needs.
    local nanoShare = S.mexReady and 1 or (S.baseShare or S.share)
    local need = math.ceil(Cfg().NANO_HEADROOM * nanoShare * S.income / S.nanoRate - 1e-9)
    S.nanoAllowed, S.nanoNeed = allowed, need
    if allowed >= need then return end
    local k = math.min(Cfg().NANO_BATCH, need - allowed, Cfg().NANO_INFLIGHT_MAX - inflight)
    for _, cell in ipairs(S.cells) do
        if k <= 0 then break end
        if cell.kind ~= "T1" and cell.held and #cell.held > 0 and CellHasLab(cell) then
            k = k - ReleaseHeld(cell, k)
        end
    end
end

-- Release held labs.  One per tick, cheapest first.  A released lab takes its core nanos.
local function ThrottleLabs()
    local K = Cfg()
    for _, cell in ipairs(S.cells) do
        local list = cell.heldLabs
        if list and #list > 0 then
            local lab = list[1]
            local cost = UnitDefs[lab.defID] and UnitDefs[lab.defID].metalCost or 0
            local release, why = false, nil
            if cell.kind == "T1" then
                if not cell.firstLabFrame and CellHasLab(cell) then cell.firstLabFrame = S.frame end
                if S.share > 0 and cell.firstLabFrame
                   and S.frame - cell.firstLabFrame >= K.T1_LAB2_DELAY then
                    release, why = true, string.format("army share %.0f%%, first lab up %d frames",
                        S.share * 100, S.frame - cell.firstLabFrame)
                end
            else
                local av = S.env.GroundArmyValue and S.env.GroundArmyValue() or 0
                if av >= K.LAB_GATE_MARGIN * cost then
                    release, why = true, string.format("ground army value %.0f >= cost %.0f", av, cost)
                end
            end
            if release then
                table.remove(list, 1)
                Unhold(lab)
                for _, n in ipairs(lab.coreNanos or {}) do Unhold(n) end
                Spring.Echo(string.format("[SPINE] %s cell #%d: lab %s released (%s)",
                    cell.kind, cell.index, tostring(lab.n), why))
                return
            end
        end
    end
end

-- Energy storage worth ENERGY_BUFFER_S seconds of full army spend (R energy per metal), once
-- the nano rule has opened up.  Storages are the spine cells' held corestor items.
local function ThrottleStorage(res)
    if not (S.mexReady and res and res.energyStorage) then return end
    local per = S.storePer
    local allowed, inflight, built = 0, 0, 0
    for _, cell in ipairs(S.cells) do
        for _, it in ipairs(cell.state.queue) do
            if it.n == Cfg().STORE_UNIT and it.act ~= "reclaim" and not IsHeld(it)
               and it.status ~= "skipped" then
                allowed = allowed + 1
                if it.status == "built" then built = built + 1 else inflight = inflight + 1 end
            end
        end
    end
    local target = Cfg().ENERGY_BUFFER_S * S.R * S.income
    local other = math.max(0, res.energyStorage - built * per)   -- storage the spine did not add
    local need = math.ceil((target - other) / per - 1e-9)
    S.storeAllowed, S.storeNeed, S.storeTarget = allowed, math.max(0, need), target
    if allowed >= need then return end
    local k = math.min(Cfg().STORE_BATCH, need - allowed, Cfg().STORE_INFLIGHT_MAX - inflight)
    for _, cell in ipairs(S.cells) do
        if k <= 0 then break end
        if cell.heldStore and #cell.heldStore > 0 then
            k = k - ReleaseHeld(cell, k, "heldStore")
        end
    end
end

-- True when energy income is short of what rushing army needs: eco pull plus GEN_COVER of
-- the energy full army spend would draw.  The macro's energy interrupt ORs this in, so the
-- grids build wind before stored energy runs low.  False until the nano rule opens up.
function M.EnergyShort(res)
    if not (S and S.mexReady and res) then return false end
    local armyNow = S.R * S.share * S.income
    local eco = math.max(0, (res.energyPull or 0) - armyNow)
    local need = eco + S.R * S.income * Cfg().GEN_COVER
    S.energyNeed, S.energyHave = need, res.energyIncome or 0
    return (res.energyIncome or 0) < need
end

-- ── Expansion ────────────────────────────────────────────────────────────────

local function CellsBuilding()
    local n = 0
    for _, cell in ipairs(S.cells) do
        if not cell.settled then n = n + 1 end
    end
    return n
end

local function T1LabsReady()
    local made = 0
    for lid, l in pairs(S.labs) do
        if S.cells[l.cell] and S.cells[l.cell].kind == "T1" and Alive(lid)
           and not Spring.GetUnitIsBeingBuilt(lid) then made = made + 1 end
    end
    return made >= 2
end

local function MaybeExpand()
    local env = S.env
    if S.opened >= 2 * Cfg().STACK_HALF + 1 then return end
    if CellsBuilding() >= Cfg().MAX_OPENING then return end
    if env.CapPressure() then return end
    local kind = NextKind()
    if kind == "T1" then return end         -- opened by Start
    if S.frame < Cfg().EXPAND_FROM then return end
    if not T1LabsReady() then return end
    -- THE RULE: a spine that could not spend all of today's income means a cell is late.
    if AssignedCapacity() >= Cfg().EXPAND_MARGIN * S.income then return end
    OpenCell(kind)
end

-- ── Update ───────────────────────────────────────────────────────────────────

local function ComputeShare(c)
    local share = 0
    for _, p in ipairs(M.policies) do
        local ok, r = pcall(p.fn, share, c)
        if ok and type(r) == "number" then share = r
        elseif not ok and not failed[p.name] then
            failed[p.name] = true
            Spring.Echo("[SPINE] policy '" .. tostring(p.name) .. "' failed: " .. tostring(r))
        end
    end
    return math.max(0, math.min(1, share))
end

function M.Update(frame, res)
    if not S or not S.started then return end
    S.frame = frame
    local raw = res and res.metalIncome
    if raw then
        -- Smoothed (~3 s): reclaim spikes must not open cells or wake nanos.
        S.income = S.incomeSeen and (S.income + Cfg().INCOME_SMOOTH * (raw - S.income)) or raw
        S.incomeSeen = true
    end

    for _, cell in ipairs(S.cells) do
        if not cell.done then
            S.env.BP_PLACER.Update(cell.state, frame, res or {})
            if cell.done then ReleaseCell(cell) end
        end
    end

    if frame % Cfg().UPDATE_EVERY ~= 0 then return end

    local allPending = {}
    for _, cell in ipairs(S.cells) do
        if not cell.done then
            ServiceCellBuilders(cell)
            for defID in pairs(PendingDefs(cell.state)) do allPending[defID] = true end
        end
        if not cell.settled and SettledFrac(cell.state) >= Cfg().SETTLED_FRAC then
            cell.settled = true
        end
    end
    -- A con request only stands while some cell still needs that building.
    for defID in pairs(S.conWanted) do
        if not allPending[defID] then S.conWanted[defID] = nil end
    end
    -- A request nobody answered in time is made again.
    for def, t in pairs(S.conPending) do
        if frame - t > Cfg().CON_ORDER_TTL then S.conPending[def] = nil end
    end

    if not S.mexReady and S.env.MexGridsReady and S.env.MexGridsReady() then
        S.mexReady = true
        Spring.Echo("[SPINE] mex grids ready: nanos for 100% army spend are released, "
            .. "energy buffer and generation floor on")
    end
    local urgency, nThreats
    if S.env.Threat then urgency, nThreats = S.env.Threat() end
    local c = {
        frame = frame, income = S.income, capPressure = S.env.CapPressure(),
        capacity = S.capacity, builtCapacity = S.builtCapacity,
        cells = S.cells, threatUrgency = urgency, threatCount = nThreats or 0,
    }
    S.share = ComputeShare(c)
    S.baseShare = c.baseShare or S.share
    S.capacity = AssignedCapacity()

    MaybeExpand()
    ThrottleLabs()
    ThrottleNanos()
    ThrottleStorage(res)
    UpdateNanos()

    if frame - S.lastLog >= Cfg().LOG_EVERY then
        S.lastLog = frame
        local sec = math.floor(frame / 30)
        local cellInfo = {}
        for _, cell in ipairs(S.cells) do
            local labsUp, nanosUp, labsHeld = 0, 0, cell.heldLabs and #cell.heldLabs or 0
            for _, it in ipairs(cell.state.queue) do
                if it.act ~= "reclaim" and it.status == "built" then
                    if it.cls == "factory" then labsUp = labsUp + 1
                    elseif it.cls == "nano" then nanosUp = nanosUp + 1 end
                end
            end
            cellInfo[#cellInfo + 1] = string.format("#%d %s labs %d (+%d held) nanos %d",
                cell.index, cell.kind, labsUp, labsHeld, nanosUp)
        end
        Spring.Echo("[SPINE] cells: " .. table.concat(cellInfo, "; "))
        Spring.Echo(string.format(
            "[SPINE] %d:%02d share=%.0f%% (base %.0f%%) income=%.0f capacity=%.0f (standing %.0f) "
            .. "cells=%d nanos active=%d parked=%d (allowed %d, wanted %d) "
            .. "storage %d/%d (target %.0f e) energy %.0f/%.0f%s%s",
            math.floor(sec / 60), sec % 60, S.share * 100, (S.baseShare or S.share) * 100,
            S.income, S.capacity,
            S.builtCapacity, #S.cells, S.active, S.parked,
            S.nanoAllowed or 0, S.nanoNeed or 0,
            S.storeAllowed or 0, S.storeNeed or 0, S.storeTarget or 0,
            S.energyHave or 0, S.energyNeed or 0,
            S.mexReady and " MEXREADY" or "",
            S.leak > 0 and (" PARK-LEAK=" .. S.leak) or ""))
    end
end

-- ── Unit callbacks ───────────────────────────────────────────────────────────

function M.OnUnitCreated(uid, defID, builderID)
    if not S then return end
    for _, cell in ipairs(S.cells) do
        if not cell.done then S.env.BP_PLACER.OnUnitCreated(cell.state, uid, defID, builderID) end
    end
end

function M.OnUnitFinished(uid, defID, x, z)
    if not S then return end
    for _, cell in ipairs(S.cells) do
        if not cell.done then S.env.BP_PLACER.OnUnitFinished(cell.state, uid, defID, x, z) end
    end
    local d = UnitDefs[defID]
    if not d or not x then return end
    local ci = InCell(x, z)
    if not ci then return end
    if d.isFactory then
        S.labs[uid] = { cell = ci, name = d.name, conMade = 0 }
    elseif IsNanoDef(d) then
        S.nanos[uid] = { cell = ci }
    end
end

function M.OnUnitFromFactory(uid, defID, factID)
    if not S or not S.labs[factID] then return end
    local d = UnitDefs[defID]
    if d and d.isBuilder and not d.isFactory and (d.speed or 0) > 0 and not d.canFly then
        S.cons[uid] = true
        S.conOut = (S.conOut or 0) + 1
        S.conPending[defID] = nil
        Spring.GiveOrderToUnit(uid, 0, {}, {})
        S.env.DeferStop(uid)
    end
end

function M.OnUnitDestroyed(uid)
    if not S then return end
    for _, cell in ipairs(S.cells) do
        if not cell.done then S.env.BP_PLACER.OnUnitDestroyed(cell.state, uid) end
    end
    S.labs[uid], S.nanos[uid], S.cons[uid] = nil, nil, nil
end

-- ── Lab hook ─────────────────────────────────────────────────────────────────

function M.IsLab(labID) return S ~= nil and S.labs[labID] ~= nil end

-- A T1 spine lab (corlab / corvp): the spine only queues its cons; the lab controller
-- runs the rest of what it makes through the normal picks.
function M.IsT1Lab(labID)
    local L = S and S.labs[labID]
    return L ~= nil and M.T1_CONS[L.name] ~= nil
end

local function DemandCon(labDefID)
    local ld = UnitDefs[labDefID]
    if not ld or not ld.buildOptions then return nil end
    for wanted in pairs(S.conWanted) do
        for _, optID in ipairs(ld.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.isBuilder and not od.isFactory and (od.speed or 0) > 0
               and not od.canFly and S.env.BP_PLACER.CanBuild(optID, wanted)
               and not S.conPending[optID] then
                S.conPending[optID] = S.frame
                return optID
            end
        end
    end
    return nil
end

-- The next unit this spine lab should queue, or nil.  Called by lab_controller until
-- the queue is QUEUE_DEPTH deep.  Cons first (hard-coded, then whatever a cell is
-- waiting for), then the lab's army unit -- only while army_share is above zero.
-- env.EarlyCons (optional): until cell 1 is built, the spine may have at most this many ground cons (alive + ordered
-- and not yet out).  One con is enough to place a cell's first labs and nanos; more only soak up metal.
local function ConsAllowed()
    local limit = S.env.EarlyCons
    if not limit then return true end
    local c1 = S.cells[1]
    if c1 and c1.settled then return true end
    local alive = 0
    for uid in pairs(S.cons) do
        if Alive(uid) then alive = alive + 1 else S.cons[uid] = nil end
    end
    return alive + math.max(0, (S.conOrders or 0) - (S.conOut or 0)) < limit
end

function M.NextOrder(labID, labDefID)
    local L = S and S.labs[labID]
    if not L then return nil end
    local consOK = ConsAllowed()
    local hc = M.T1_CONS[L.name]
    if consOK and hc and L.conMade < (L.conWant or hc[2]) then
        local d = UnitDefNames[hc[1]]
        if d then L.conMade = L.conMade + 1; S.conOrders = (S.conOrders or 0) + 1; return d.id end
    end
    local con = consOK and DemandCon(labDefID) or nil
    if con then S.conOrders = (S.conOrders or 0) + 1; return con end
    if S.share > 0 and M.LAB_UNITS[L.name] then
        local u = RefUnit(L.name)
        if u then return u.id end
    end
    return nil
end

function M.Share() return S and S.share or 0 end

-- Snapshot for logging and tests.
function M.Status()
    if not S then return nil end
    return { share = S.share, income = S.income, capacity = S.capacity,
             builtCapacity = S.builtCapacity, cells = #S.cells, opened = S.opened,
             active = S.active, parked = S.parked, leak = S.leak,
             geo = S.geo, conWanted = S.conWanted }
end

return M
