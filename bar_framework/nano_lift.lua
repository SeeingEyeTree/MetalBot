-- bar_framework/nano_lift.lua  (TILE_V2)
-- Seeding the first mex grid with build power we already own.
--
-- The grid's air con starts it, and the air transport that comes out of the air lab right after the con carries
-- two nanos from the slot lines to where the grid's capstone will stand: it lifts the nano with the fewest free
-- slots around it (it is about to stop being useful) , sets it down on the capstone footprint, then lifts a
-- second.  The seeds finish the grid's first items quickly, so the grid needs no existing nanos in range, and
-- the lines keep their other nanos.  When the grid has SEED_RECLAIM_NANOS nanos of its own the seeds are
-- reclaimed (they sit where the capstone goes, and the metal comes back).
--
-- States: ready -> loading -> carrying -> ready (second nano) -> done.   failed = no lift will happen
-- (nano not transportable, no drop point, transport lost, timeout): the macro then goes back to normal grid pacing.
--
-- Hooks (macro): NL.Init, NL.OnTransport(unitID), NL.OnLoaded, NL.OnUnloaded, NL.Update(frame).

local NL = {}

NL.CFG = {
    COUNT         = 2,       -- nanos to carry
    RECLAIM_AT    = 10,      -- the grid's own built nanos at which the seeds are reclaimed
    LOAD_TIMEOUT  = 900,     -- frames to get a nano loaded
    UNLOAD_TIMEOUT = 450,    -- frames to set it down at one spot before trying the next
    MAX_UNLOAD_TRIES = 8,    -- spots tried before the nano is dumped where the transport is
    IDLE_WAIT     = 300,     -- frames to wait for a lift candidate to be idle before taking the best anyway
    OUT_WAIT      = 75,      -- frames after the transport comes out before it is given an order
    REORDER       = 240,     -- frames after which a LOAD order that has not taken is sent again
    DROP_OFFSET   = 40,      -- elmos from the capstone centre
    CAP_OFFSET    = { x = 8, z = -8 },   -- the capstone's tile-local offset in mex_grid_alab
}

local CMD_STOP         = 0
local CMD_LOAD_UNITS   = (CMD and CMD.LOAD_UNITS)   or 75
local CMD_UNLOAD_UNITS = (CMD and CMD.UNLOAD_UNITS) or 80

local env = nil
local S = { state = "wait", transport = nil, target = nil, deadline = 0, lifted = 0, seeds = {},
            reclaimed = false, readySince = nil, dropPoints = {} }
NL.S = S

local function Alive(id) return id ~= nil and Spring.GetUnitDefID(id) ~= nil end

local function Echo(fmt, ...) Spring.Echo("[LIFT] " .. string.format(fmt, ...)) end

local function Fail(why)
    if S.state == "failed" then return end
    -- Never strand a nano in the air: set it down wherever the transport is.
    if S.state == "carrying" and Alive(S.transport) then
        local x, y, z = Spring.GetUnitPosition(S.transport)
        if x then Spring.GiveOrderToUnit(S.transport, CMD_UNLOAD_UNITS, { x, y, z, 300 }, {}) end
    end
    S.state = "failed"
    Echo("lift abandoned: %s", why)
    if env and env.onFail then pcall(env.onFail, why) end
end

-- env: { SC, crew = function() -> slot crew, nano = function() -> nano_broker, firstGrid = function() -> grid state,
--        reclaim = function(unitID), nanoDef = defID, onFail = function(why) }
function NL.Init(e)
    env = e
end

-- What the engine says about carrying a nano (logged once at start-up).
function NL.Probe()
    local nd = UnitDefNames and UnitDefNames.cornanotc
    local td = UnitDefNames and UnitDefNames.corvalk
    local function f(d, k) return d and tostring(d[k]) or "?" end
    Echo("probe: cornanotc cantBeTransported=%s mass=%s xsize=%s | corvalk transportCapacity=%s transportMass=%s transportSize=%s",
        f(nd, "cantBeTransported"), f(nd, "mass"), f(nd, "xsize"), f(td, "transportCapacity"),
        f(td, "transportMass"), f(td, "transportSize"))
    if nd and nd.cantBeTransported then
        Echo("probe: cornanotc cannot be transported in this build")
    end
    return nd and not nd.cantBeTransported
end

function NL.OnTransport(unitID)
    if S.transport or S.state == "failed" then return end
    S.transport, S.state = unitID, "ready"
    S.readySince = nil
    S.outFrame = S.now or 0      -- the factory's auto-guard order lands AFTER this callback: orders wait OUT_WAIT frames
    Echo("transport %d is out; waiting for the first grid", unitID)
end

function NL.Failed() return S.state == "failed" end
function NL.Done() return S.state == "done" end
function NL.Seeds() return S.seeds end

-- Where seed number k goes: on the capstone footprint of grid `gs` (state.anchorX/Z/rotation), a few
-- elmos off its centre, on a spot the engine accepts.
-- `attempt` > 1 starts further down the list of candidate spots: the first one may have been built over by the
-- grid's own frames since the lift began (a second nano once hovered 900 frames over such a spot).
local function DropPoint(gs, k, attempt)
    local C = NL.CFG
    local rot = gs.rotation or 0
    local cx, cz = env.SC.Rotate(C.CAP_OFFSET.x, C.CAP_OFFSET.z, rot)
    cx, cz = gs.anchorX + cx, gs.anchorZ + cz
    local o = C.DROP_OFFSET
    local sign = (k == 1) and -1 or 1
    local tries = { { sign * o, 0 }, { 0, sign * o }, { sign * o, o }, { -sign * o, 0 }, { 0, -sign * o },
                    { 0, 0 }, { sign * 2 * o, 0 }, { 0, sign * 2 * o } }
    for i = (attempt or 1), #tries do
        local t = tries[i]
        local dx, dz = env.SC.Rotate(t[1], t[2], rot)
        local x, z = cx + dx, cz + dz
        local y = Spring.GetGroundHeight(x, z) or 0
        local ok = Spring.TestBuildOrder(env.nanoDef, x, y, z, 0)
        if ok and ok ~= 0 then return x, y, z, i end
    end
    return nil
end

local function Pick(crew)
    local list = env.SC.LeastOpenNanos(crew, 4)
    for _, c in ipairs(list) do
        if not Spring.GetUnitIsBuilding(c.unitID) and not env.nano().Assignment(c.unitID) then return c end
    end
    return list[1]          -- (none idle: the caller decides whether to wait)
end

local function CountGridNanos(gs)
    local n = 0
    for _, it in ipairs(gs.queue or {}) do
        if it.cls == "nano" and (it.status == "built" or it.built == true) then n = n + 1 end
    end
    return n
end

local function ReclaimSeeds(gs)
    S.reclaimed = true
    for _, seed in ipairs(S.seeds) do
        if Alive(seed.id) then
            Echo("seed nano %d is reclaimed (%d grid nanos built)", seed.id, CountGridNanos(gs))
            env.reclaim(seed.id)
        end
    end
end

function NL.Update(frame)
    if not env then return end
    S.now = frame
    local gs = env.firstGrid()

    -- The seeds go back once the grid has nanos of its own (also if the grid finished early).
    if #S.seeds > 0 and not S.reclaimed and gs and (CountGridNanos(gs) >= NL.CFG.RECLAIM_AT or gs.done) then
        ReclaimSeeds(gs)
    end

    if S.state == "wait" or S.state == "done" or S.state == "failed" then return end
    if not Alive(S.transport) then Fail("the transport was lost"); return end
    local crew = env.crew()
    if not (gs and crew and Alive(gs.builderID)) then return end        -- the first grid has no con yet

    if S.state == "ready" then
        if frame - (S.outFrame or 0) < NL.CFG.OUT_WAIT then return end    -- (see OnTransport)
        if S.lifted > 0 and (S.reclaimed or CountGridNanos(gs) >= NL.CFG.RECLAIM_AT) then
            S.state = "done"                                              -- the grid no longer needs a second seed
            Echo("the grid already has %d nanos: no second lift", CountGridNanos(gs))
            return
        end
        local c = Pick(crew)
        if not c then return end                                          -- no nano to take yet
        S.readySince = S.readySince or frame
        if (Spring.GetUnitIsBuilding(c.unitID) or env.nano().Assignment(c.unitID))
           and frame - S.readySince < NL.CFG.IDLE_WAIT then
            return                                                        -- wait a little for an idle one
        end
        S.readySince = nil
        local k = S.lifted + 1
        if not DropPoint(gs, k, 1) then Fail("no free drop point on the capstone footprint"); return end
        S.target, S.state, S.deadline, S.attempt = c.unitID, "loading", frame + NL.CFG.LOAD_TIMEOUT, 1
        Echo("lift %d: nano %d (%d free slots around it) -> grid at (%d, %d)", k, c.unitID, c.open, gs.anchorX, gs.anchorZ)
        Spring.GiveOrderToUnit(S.transport, CMD_STOP, {}, {})
        Spring.GiveOrderToUnit(S.transport, CMD_LOAD_UNITS, { c.unitID }, {})
        S.lastOrder = frame

    elseif S.state == "loading" then
        -- An order that did not take (overwritten, dropped) is sent again; it is not a failure until the deadline.
        if frame - (S.lastOrder or frame) >= NL.CFG.REORDER and frame <= S.deadline and Alive(S.target) then
            S.lastOrder = frame
            Spring.GiveOrderToUnit(S.transport, CMD_LOAD_UNITS, { S.target }, {})
        end
        if frame > S.deadline then Fail("the nano was not loaded in time (not transportable?)") end

    elseif S.state == "carrying" then
        if frame > S.deadline then
            -- The spot is probably taken: try the next one (the spot is re-tested each time), then give up.
            S.attempt = (S.attempt or 1) + 1
            local k = S.lifted + 1
            local x, y, z, idx = nil, nil, nil, nil
            if S.attempt <= NL.CFG.MAX_UNLOAD_TRIES then x, y, z, idx = DropPoint(gs, k, S.attempt) end
            if not x then Fail("the nano was not set down in time"); return end
            S.attempt = idx
            S.deadline = frame + NL.CFG.UNLOAD_TIMEOUT
            Echo("drop spot %d is blocked; flying on to (%d, %d)", idx - 1, x, z)
            Spring.GiveOrderToUnit(S.transport, CMD_UNLOAD_UNITS, { x, y, z, 96 }, {})
        end
    end
end

function NL.OnLoaded(unitID, transportID)
    if S.state ~= "loading" or unitID ~= S.target or transportID ~= S.transport then return end
    -- The nano left its slot: the slot is free again and the broker forgets it.
    local crew = env.crew()
    if crew then env.SC.ReleaseUnit(crew, unitID) end
    env.nano().Release(unitID)
    local k = S.lifted + 1
    local gs = env.firstGrid()
    -- The spot is chosen NOW (not when the lift began): the grid keeps building around the capstone.
    local x, y, z, idx = nil, nil, nil, nil
    if gs then x, y, z, idx = DropPoint(gs, k, 1) end
    if not x then Fail("no free drop point on the capstone footprint"); return end
    S.attempt = idx
    S.state, S.deadline = "carrying", (S.now or 0) + NL.CFG.UNLOAD_TIMEOUT
    Spring.GiveOrderToUnit(S.transport, CMD_UNLOAD_UNITS, { x, y, z, 96 }, {})
    Echo("nano %d loaded, flying to (%d, %d)", unitID, x, z)
end

function NL.OnUnloaded(unitID, transportID)
    if S.state ~= "carrying" or unitID ~= S.target or transportID ~= S.transport then return end
    local x, _, z = Spring.GetUnitPosition(unitID)
    S.lifted = S.lifted + 1
    S.seeds[#S.seeds + 1] = { id = unitID, x = x, z = z }
    local gs = env.firstGrid()
    if gs and Alive(gs.builderID) then env.nano().Guard(env.nano().PRIO.HANDOFF, unitID, gs.builderID) end
    Echo("seed nano %d down at (%d, %d) (%d of %d)", unitID, x or 0, z or 0, S.lifted, NL.CFG.COUNT)
    S.target = nil
    -- It landed after the grid already had its own nanos: it only blocks the capstone now.
    if S.reclaimed then
        Echo("seed nano %d is reclaimed at once (the grid is already up)", unitID)
        env.reclaim(unitID)
    end
    S.state = (S.lifted >= NL.CFG.COUNT) and "done" or "ready"
end

return NL
