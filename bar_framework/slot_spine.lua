-- bar_framework/slot_spine.lua
-- The SLOT SPINE: permanent blocks of nanos with lab slots in front, labs chosen from the unit comp.
--
-- WHY (user, 2026-10-12)
--   spine.lua hard-codes its labs: each cell kind (T1 / T2 / T3 / AIR) is a blueprint with fixed labs, so a new unit
--   type, or a switch to bombers, means opening a new cell and building its nanos from scratch -- a lab with no build
--   power for minutes.  Here the build power is the permanent part and the labs are tenants:
--     * BLOCK = 16 nanos (4x4) + 2 SLOTS on the enemy-facing side (blueprints/general/NanoBlock.lua).  Blocks are opened
--       AHEAD of need: enough nanos stand to spend `nanoShare x income`, whether or not a lab is there yet.
--     * LABS are decided at run time.  SetUnits() gives the comp (unit defs + share of army spend); the planner finds the
--       cheapest set of labs that can build it (a lab that already stands costs nothing), sizes the count by how much
--       each lab can absorb, and puts missing labs in free slots.
--     * SWAP: a lab no unit in the comp needs is reclaimed (only when its slot is wanted, and only once it has stood
--       unneeded for RECLAIM_DELAY), and the slot is reused.  The nanos stay, so the new lab has all its BP at once.
--     * NANOS guard the labs in reach, split by what each lab can absorb; nanos beyond what the spend needs are parked.
--     * SLACK (CFG.SLACK_BLOCKS): from SLACK_INCOME metal/s, two spare blocks (every nano standing, both slots free) are kept
--       ahead, so a comp change can put new labs straight into free slots with their BP already there.
--   Cons: a lab is placed by a con that can build it (a T1 bot / vehicle con for T2 plants, any con for T1 plants) --
--   taken from the host's pool, or made by one of our labs when NextOrder is asked (conWanted).  T2 air is excluded.
--
-- USAGE (macro_controller; same shape as spine.lua so a host can swap one for the other)
--   SS.Init{ BP_PLACER, NANO, blueprint = NanoBlock, baseX, baseZ, mapX, mapZ, AnchorKey, Reserve, TakeCon, ReturnCon,
--            DeferStop, MexGridsReady (opt), ArmyValue (opt) -> ground army value, Floating (opt) -> bool, geo (opt) }
--   SS.Start(frame)  SS.Update(frame, res)  SS.OnUnitCreated / OnUnitFinished / OnUnitFromFactory / OnUnitDestroyed
--   SS.SetUnits({ {defID=, share=}, ... })   the comp (strategy.lua: Strategy:UnitList()); SS.SetShare(s); SS.SetNanoFloor(f)
-- USAGE (lab_controller): SS.IsLab(uid)  SS.IsLeaving(uid)  SS.NextOrder(labID, labDefID) -> a con to queue, or nil.
-- Log rows are "[SLOT]".

local SP
do
    local ok, r = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/spine.lua")    -- geometry helpers only
    SP = ok and r or nil
end

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")   -- unit roles per faction (C4)
local BT = VFS.Include("LuaUI/Widgets/bar_framework/build_tree.lua")   -- the build tree (C1): who can build what

local M = {}

M.CFG = {
    BLOCK_PITCH     = 272,    -- elmos between blocks along the stack axis (240 + 32: room for the energy storages in the gap)
    FRONT           = 480,    -- elmos from the base to the first block anchor (same as spine's first cell)
    MAX_BLOCKS      = 9,
    STACK_HALF      = 4,
    UPDATE_EVERY    = 30,
    LAB_CANDIDATES  = { ROLES.Get("lab_t1_bot"), ROLES.Get("lab_t1_veh"), ROLES.Get("lab_t1_air"), ROLES.Get("lab_t2_bot"), ROLES.Get("lab_t2_veh"), ROLES.Get("lab_t3") },   -- labs the planner may use (no T2 air)
    AIR_LABS        = { [ROLES.Get("lab_t2_air")] = true },     -- labs only an AIR con can place (a T1 ground con cannot build a T2 air plant; the T1 air lab is placed by ground cons):
                                             -- a T1 air con is pulled from the host's pool and one is ordered (env.QueueAirCon) when none is free
    WIDE_LABS       = { [ROLES.Get("lab_t2_air")] = true },     -- labs that take both slots of a block whatever their footprint (user 2026-10-16: one T2 air lab per block; two T1 air labs fit)
    WIDE_ELMOS      = 160,    -- a lab wider than this takes BOTH slots of a block (the gantry), centred between them
    WIDE_X          = 72,     -- where a wide lab's centre sits in front of the block
    COVER_FRAC      = 0.95,   -- stop adding labs once this share of the comp can be built
    MIN_UNIT_SHARE  = 0.02,   -- units under this share do not justify a lab of their own
    ABSORB_SECONDS  = 2.5,    -- a lab takes at most buildTime/this BP, i.e. absorbs metalCost/this metal per second
    LAB_UTIL        = 0.8,    -- fraction of that a lab really sustains
    NANO_CAP        = nil,    -- { max = n, untilF = frame }: at most n spine nanos before that frame (CORE_6K); nil = sized from the spend
    RUSH_NANOS      = false,  -- user 2026-10-26: while the labs rush units out every spine nano guards a lab, at NANO.PRIO.RUSH (CORE: true)
    RUSH_SHARE      = 0.8,    -- ... an army share this high counts as rushing
    CORE_NANOS      = 4,      -- nanos built when a block opens; the rest are released as the spend needs them
    NANO_HEADROOM   = 1.15,   -- nano capacity kept over what the spend absorbs
    BUILD_AHEAD     = 1.0,    -- nanos are sized for this share of income whatever the army share (1 = all of it) ...
    NANO_SHARE_CAP  = nil,    -- user 2026-10-27 (8k metal of idle nanos; the machine's attack share is 1.0): nanos are sized for at most this share of income
    NANO_BUILD_UTIL = 0,      -- >0: no NEW nano is built (past LAB_MIN_NANOS' floor) while fewer than this share of the standing nanos are building something
    NANO_UTIL_GATE  = 0,      -- CORE (user 2026-10-26): >0 = build-ahead sizing and every lab beyond the first of its type wait until this share of the
                              -- standing nanos is building something (smoothed, NanoUtil); 0 = off.  Labs/nanos still follow the army share.
    BUILD_AHEAD_INCOME = 500, -- ... but only from this metal income; below it nanos/labs follow the army share alone, so the
                              -- metal goes to the mex grids (sized for 100% from the first minute they starved the grids)
    NANO_BATCH      = 6,      -- nanos released per tick
    NANO_INFLIGHT   = 12,     -- released nanos that may be unfinished at once
    MOVES_MAX       = 6,      -- nano assignment changes per tick
    BLOCK_LAB_NANOS = 0,       -- >0: a block gets a lab in a free slot for every this-many of its nanos that stand (0 = the plan alone decides)
    PARK_NANOS      = true,
    GUARD_NANOS     = true,    -- false: the spine never orders a nano to guard / assist (the engine's own assist does it); surplus nanos are still parked to the army share
    BUILDERS_PER_JOB = 2,     -- cons on a job (a block or a lab slot)
    MAX_JOBS        = 3,      -- lab slot jobs (build or clear) at once
    FLOAT_MULT      = 1,      -- while both banks float (free run) nanos and labs are planned for this multiple of income (capacity look-ahead)
    MAX_JOBS_FLOAT  = 6,      -- ... while metal and energy both bank (free run): spending capacity is what is short then
    RECLAIM_DELAY   = 900,    -- frames a lab must have been unneeded before it may be reclaimed
    RECLAIM_UNNEEDED = false, -- DRAGON_ECO: a lab the plan no longer has at all (slot or adopted) is reclaimed after RECLAIM_DELAY even when
                              -- no slot is wanted, once a lab that builds the comp stands (false: only when its slot is wanted)
    CLEAR_NEEDS_CON = false,  -- DRAGON_ECO: a lab is cleared (any path) only while one of the spine's cons that can build its replacement is
                              -- within CLEAR_CON_R of it, so the slot is rebuilt at once
    CLEAR_CON_R     = 900,
    LAB_TAKES_BLOCK_CON = false,  -- DRAGON_ECO: a lab job with no free con takes one off a nano block's job (a block keeps held
                                  -- nanos for minutes, so its builders never came free and the T2 bot labs never got a con)
    WAVE_SWAP       = false,  -- CORE (user 2026-10-16): on a stance change the labs the plan no longer needs are swapped in two waves: half at
                              -- once (no RECLAIM_DELAY, no job cap), the other half SWAP_WAVE_GAP after the first wave's new labs stand, so the
                              -- kept half keeps producing (from the previous stance's units: see IsReplacing); nanos near a clearing/building
                              -- slot are never parked (they assist its builder); the plan ignores the "standing lab is free" bias
    SWAP_WAVE_GAP   = 900,    -- frames between wave 1 finishing and wave 2 starting
    SLOT_BAD_FRAMES = 450,    -- a slot whose lab the placer gave up on (its ground was blocked: units standing there) rests this long
    SWAP_WINDOW     = 5400,   -- the plan ignores standing labs, and a dropped lab goes at once, only this long after the comp's unit set changed
    SWAP_TIMEOUT    = 3600,   -- wave 1 that has not finished after this many frames lets wave 2 go anyway
    BLOCK_CONS      = false,  -- CORE: every block keeps a resident T1 vehicle con and T2 bot con (BLOCK_CON_UNITS) that only place/reclaim its own
                              -- slot labs (other jobs fall back to the shared pool while one is missing)
    BLOCK_CON_UNITS = { ROLES.Get("con_t1_veh"), ROLES.Get("con_t2_bot") },
    IDLE_LAB_T2     = false,  -- CORE: a slot lab with nothing queued or building for IDLE_LAB_FRAMES is replaced by a T2 bot lab (always usable:
                              -- decoy commanders for the sink), at most one per block per IDLE_LAB_GAP
    IDLE_LAB_FRAMES = 900,
    IDLE_LAB_GAP    = 1800,
    IDLE_LAB_UNIT   = ROLES.Get("lab_t2_bot"),
    IDLE_LAB_MIN_BANK = 0.25, -- ... and only while the metal bank is at least this share of storage (or both banks float): a T2 lab costs metal
    REBUILD_NANOS   = false,  -- DRAGON_ECO (user 2026-10-14): a nano an enemy destroyed is built again at its spot (a lab is always rebuilt by the
                              -- planner; without this a lost nano stays lost)
    REBUILD_DELAY   = 900,    -- frames after the loss before the nano is re-queued ...
    REBUILD_SAFE_R  = 1200,   -- ... and only while no threat (env.Safe) is this close to its spot
    GATE_COST       = 1000,   -- labs this expensive wait for army value (below)
    GATE_MARGIN     = 1.0,    -- ground army value must reach margin x lab cost (env.ArmyValue); floating overrides
    LOG_EVERY       = 1800,
    CON_ORDER_TTL   = 1800,
    CONS_MIN        = 3,      -- ground cons our labs keep making while a block or lab slot has work ...
    CONS_PER_INCOME = 150,    -- ... plus one per this much metal income, up to CONS_MAX
    CONS_MAX        = 8,
    -- user 2026-10-26 (slimegirl game: ~5 ground cons far too early): until EARLY_CONS_UNTIL (frame) or EARLY_CONS_LABS labs stand, the spine keeps at most
    -- EARLY_CONS ground cons (one is enough to place the nanos and the labs).  0 = off.
    EARLY_CONS      = 0,
    CON_CAP         = 0,                  -- >0: until CON_CAP_UNTIL (frame) the spine has at most this many ground cons in total (residents and every order kind count)
    CON_CAP_UNTIL   = 10 * 60 * 30,
    EARLY_CONS_LABS = 2,
    EARLY_CONS_UNTIL = 6 * 60 * 30,
    -- the first FIRST_VP spine labs are vehicle plants (VP_NAME), and each waits until FIRST_LAB_NANOS spine nanos stand ("two nanos, vp, then two
    -- more": the other CORE_NANOS are built right after the lab is placed).  0 = off (the stance comp picks the labs).
    FIRST_VP        = 0,
    FIRST_VP_NAME   = ROLES.Get("lab_t1_veh"),
    FIRST_LAB_NANOS = 2,
    LAB_MIN_NANOS   = 0,      -- user 2026-10-27: no spine lab is started until LAB_MIN_NANOS spine nanos stand for it (this many x (1 + the labs already placed in slots)); 0 = off
    EXPECT_UNTIL    = 10800,  -- frames (6:00): the host's own lab (S.expect) is awaited, not duplicated in a slot, until then
    BLOCK_OPEN_FRAC = 0.75,   -- the next block opens once this share of the released nanos stand
    SLACK_BLOCKS    = 2,      -- spare blocks (all nanos standing, both slots free) kept ready for a transition; 0 = off
    SLACK_INCOME    = 500,    -- ... once metal income reaches this (and the mex grids are ready)
    NANOS_PER_BLOCK = 16,
    STORE_UNIT      = ROLES.Get("storage"),   -- the storages in the NanoBlock side gaps (held until the energy income needs them)
    STORE_SECONDS   = 5,      -- energy storage kept = this many seconds of energy income, so the bank fraction is a signal
    STORE_INCOME    = 300,    -- ... once metal income reaches this (and the mex grids are ready)
    STORE_BATCH     = 2,      -- held storages released per tick
    STORE_INFLIGHT  = 4,      -- released storages that may be unfinished at once
    STORE_MIN_BANK  = 0.10,   -- ... and only while the metal bank is at least this share of storage (a storage costs metal)
    FREE_ON         = 0.50,   -- FREE RUN: both banks (metal and energy) at least this share of storage -> no nano controls ...
    FREE_OFF        = 0.30,   -- ... until either falls under this (hysteresis)
    SLACK_MIN_BANK  = 0.30,   -- slack nanos are only started while the metal bank is at least this share of storage (res.metal /
                              -- res.metalStorage): spare metal pays for them, labs and units keep what they need
    QUEUE_DEPTH     = 3,      -- units kept queued in each lab (lab_controller)
    T1_LABS         = { [ROLES.Get("lab_t1_bot")] = true, [ROLES.Get("lab_t1_veh")] = true, [ROLES.Get("lab_t1_air")] = true },   -- labs the lab controller also runs the normal picks on
}

-- The macro loads blueprints by this table (as it does for spine.lua).
M.BLUEPRINT = { T1 = "NanoBlock" }

local S = nil
local CMD_STOP = 0

local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
-- A lab only an AIR con can place: the AIR_LABS option forces it, else the build tree says so (no ground con has it in its options).
local function AirOnly(name)
    if (M.CFG.AIR_LABS or {})[name] then return true end
    local d = UnitDefNames[name or ""]
    return d ~= nil and d.isFactory == true and BT.NeedsAir(d.id)
end
local function Cfg() return M.CFG end
local function Log(fmtStr, ...)
    local f = S and S.frame or 0
    local sec = math.floor(f / 30)
    Spring.Echo(string.format("[SLOT%s] %d:%02d " .. fmtStr, S and S.env and S.env.logTag or "", math.floor(sec / 60), sec % 60, ...))
end

local function RotateOffset(x, z, r)
    if r == 0 then return x, z elseif r == 1 then return -z, x elseif r == 2 then return -x, -z elseif r == 3 then return z, -x end
    return x, z
end
local function Dist2(ax, az, bx, bz) return (ax - bx) ^ 2 + (az - bz) ^ 2 end
local function HalfExtent(d) return math.max(d.xsize or 0, d.zsize or d.ysize or 0) * 8 / 2 end

-- ── Geometry (the spine.lua surface line_transition uses to find room and reserve ground) ─────────────────────────
-- A "cell" here is a block: line_transition reserves a 480 box around each anchor, which covers the 192 x 240 block and
-- the lab slots in front of it.
function M.GeometryFor(dx, dz, px, pz) return SP.GeometryFor(dx, dz, px, pz) end
function M.Geometry(baseX, baseZ, mapX, mapZ) return SP.Geometry(baseX, baseZ, mapX, mapZ) end
function M.StackOffset(i) return SP.StackOffset(i) end

function M.CellAnchor(geo, baseX, baseZ, i) return M.BlockAnchor(geo, baseX, baseZ, i) end
function M.LaneAnchor(geo, baseX, baseZ, i)
    local ax, az = M.BlockAnchor(geo, baseX, baseZ, i)
    return ax + geo.dx * 480, az + geo.dz * 480
end

function M.BlockAnchor(geo, baseX, baseZ, i)
    local k = SP.StackOffset(i)
    return baseX + geo.dx * Cfg().FRONT + geo.px * k * Cfg().BLOCK_PITCH,
           baseZ + geo.dz * Cfg().FRONT + geo.pz * k * Cfg().BLOCK_PITCH
end

-- ── The comp -> labs planner ─────────────────────────────────────────────────

local function Metal(defID) local d = UnitDefs[defID]; return d and d.metalCost or 0 end

-- Which candidate labs can build which comp units.  Returns { [labName] = { defID, units = {unit defID...} } }
local function LabTable(units)
    local out = {}
    for _, name in ipairs(Cfg().LAB_CANDIDATES) do
        local ld = UnitDefNames[name]
        if ld and ld.buildOptions then
            local opt = BT.Options(ld.id)
            local list = {}
            for _, u in ipairs(units) do if opt[u.defID] then list[#list + 1] = u end end
            if #list > 0 then out[name] = { name = name, defID = ld.id, cost = ld.metalCost or 0, units = list } end
        end
    end
    return out
end

-- Greedy cover: the lab that covers the most uncovered comp share per metal (a standing lab costs nothing) is taken
-- first.  `standing` = { [labName] = count }; `allowed(name)` gates expensive labs.  Returns { [labName] = share covered }.
function M.Cover(units, standing, allowed, noBias)
    local K = Cfg()
    local tab = LabTable(units)
    local covered, plan, total = {}, {}, 0
    for _, u in ipairs(units) do if u.share >= K.MIN_UNIT_SHARE then total = total + u.share end end
    if total <= 0 then return plan end
    local got = 0
    while got < K.COVER_FRAC * total do
        local best, bestScore, bestShare
        for name, L in pairs(tab) do
            if not plan[name] and (not allowed or allowed(name) or (standing and (standing[name] or 0) > 0)) then
                local s = 0
                for _, u in ipairs(L.units) do
                    if not covered[u.defID] and u.share >= K.MIN_UNIT_SHARE then s = s + u.share end
                end
                if s > 0 then
                    local cost = (not noBias and standing and (standing[name] or 0) > 0) and 1 or math.max(1, L.cost)
                    local score = s / cost
                    if not best or score > bestScore or (score == bestScore and name < best) then
                        best, bestScore, bestShare = name, score, s
                    end
                end
            end
        end
        if not best then break end
        plan[best] = bestShare
        got = got + bestShare
        for _, u in ipairs(tab[best].units) do covered[u.defID] = true end
    end
    -- the share each lab actually builds = the covered units assigned to it (first lab in the plan that covers a unit)
    return plan, tab
end

-- How many of each lab the comp needs at this spend (metal/s).  Every lab in the plan counts at least 1.
function M.Counts(units, plan, tab, spend)
    local K = Cfg()
    local out = {}
    for name, share in pairs(plan) do
        -- metal-weighted average unit cost of what this lab builds: absorbs avgCost / ABSORB_SECONDS metal/s
        local sm, ss = 0, 0
        for _, u in ipairs(tab[name].units) do sm, ss = sm + u.share * Metal(u.defID), ss + u.share end
        local avg = ss > 0 and sm / ss or 100
        local absorb = avg / K.ABSORB_SECONDS * K.LAB_UTIL
        out[name] = math.max(1, math.ceil(share * spend / math.max(absorb, 1) - 1e-9))
    end
    return out
end

-- ── State ─────────────────────────────────────────────────────────────────────

local HOLD = { status = "held" }
local function IsHeld(it) return it.waitsFor == HOLD end

function M.Init(env)
    env.blueprint = env.blueprint or (env.blueprints and env.blueprints.T1)
    env.ArmyValue = env.ArmyValue or env.GroundArmyValue
    S = {
        env = env, started = false, frame = 0, geo = nil,
        blocks = {}, slots = {}, sessions = {}, labs = {}, nanos = {}, cons = {},
        conWanted = {}, conPending = {},
        units = {}, share = 0, nanoFloor = 0, income = 0, nanoRate = 8,
        lastLog = -1e9, nanoAllowed = 0, nanoNeed = 0,
        plan = {}, need = {}, conOrders = 0, conOut = 0,
        expect = env.Expect or { corvp = 1 },   -- labs the host builds itself and will AdoptLab
    }
    return S
end

function M.State() return S end

-- The comp: { {defID = , share = }, ... } (strategy.lua).  Also sizes the nano throttle: metal/s one nano can spend.
function M.SetUnits(units)
    if not S then return end
    S.units = {}
    local sum = 0
    for _, u in ipairs(units or {}) do if u.defID and (u.share or 0) > 0 then sum = sum + u.share end end
    if sum <= 0 then return end
    -- WAVE_SWAP: a change of the unit SET (a stance switch) opens the swap window; share wobble inside a stance does not
    local ids = {}
    for _, u in ipairs(units) do if u.defID and (u.share or 0) > 0 then ids[#ids + 1] = u.defID end end
    table.sort(ids)
    local sig = table.concat(ids, ",")
    if S.unitSig and sig ~= S.unitSig then S.stanceChangeAt = S.frame end
    S.unitSig = sig
    local nd = UnitDefNames.cornanotc
    local bp = nd and nd.buildSpeed or 200
    local rate = 0
    for _, u in ipairs(units) do
        if u.defID and (u.share or 0) > 0 then
            S.units[#S.units + 1] = { defID = u.defID, share = u.share / sum }
            local d = UnitDefs[u.defID]
            if d and (d.buildTime or 0) > 0 then rate = rate + (u.share / sum) * bp * (d.metalCost or 0) / d.buildTime end
        end
    end
    S.nanoRate = rate > 0 and rate or S.nanoRate
end

-- The most metal/s the FULL planned spine can spend on its comp: every block it may open (MAX_BLOCKS, at most the stack's 2 x STACK_HALF + 1)
-- x NANOS_PER_BLOCK nanos x what one nano puts into the comp (bp x metalCost / buildTime, share-weighted: S.nanoRate).  Mammoths with 100k BP:
-- 100000 x 3500 / 103400 = ~3.4k m/s.  The metal sink starts when income nears it (metal_sink.lua, 85%), so the spine keeps growing until
-- it is nearly as big as it will ever be.  Returns capacity, planned nanos, standing nanos, standing capacity; nil until a comp is set.
function M.SpendCapacity()
    if not S or not S.units or #S.units == 0 then return nil end
    local K = Cfg()
    local standing = 0
    for uid in pairs(S.nanos) do
        if Alive(uid) and not Spring.GetUnitIsBeingBuilt(uid) then standing = standing + 1 end
    end
    local planned = math.min(K.MAX_BLOCKS, 2 * K.STACK_HALF + 1) * K.NANOS_PER_BLOCK
    return planned * S.nanoRate, planned, standing, standing * S.nanoRate
end

-- RUSH_NANOS: the labs are rushing units out (an urgent raid / air raid, or the army share is RUSH_SHARE or more): every spine nano guards a lab
-- (none parked) at NANO.PRIO.RUSH.  The caller says when (SetRush); a share this high counts by itself.
function M.SetRush(on) if S then S.rushFlag = on and true or false end end
-- The host (line_transition VP2) holds the first block back: no block opens before this frame (nil = no hold; math.huge = until released).
function M.SetOpenAfter(f) if S then S.openAfter = f end end
local function RushOn()
    local K = Cfg()
    if not K.RUSH_NANOS or not S then return false end
    return S.rushFlag == true or (S.share or 0) >= (K.RUSH_SHARE or 0.8)
end
function M.SetShare(s) if S then S.share = math.max(0, math.min(1, s or 0)) end end
function M.SetNanoFloor(f) if S then S.nanoFloor = f or 0 end end
-- Absolute build-power floor (metal/s of corgator production the nanos must be able to absorb), whatever the income.
-- PAINTKID_BOT: asked for ahead of its gator stream; 0 / unset changes nothing for the other bots.
function M.SetSpendFloor(mps) if S then S.spendFloor = mps or 0 end end
function M.Share() return S and S.share or 0 end

-- ── Sessions (placer states for blocks and slot jobs) ────────────────────────

local function NewSession(kind, layout, ax, az, extra)
    local env = S.env
    local st = env.BP_PLACER.NewDistributed({ layout = layout }, ax, az, S.geo.rot, {})
    for _, item in ipairs(st.queue) do
        if item.cls == "factory" then item.f = S.geo.facing end
    end
    local ses = { kind = kind, state = st, ax = ax, az = az, since = S.frame }
    for k, v in pairs(extra or {}) do ses[k] = v end
    st.onComplete = function() ses.done = true end
    S.sessions[#S.sessions + 1] = ses
    return ses
end

local function PendingDefs(st)
    local defs, reclaim = {}, false
    for _, it in ipairs(st.queue) do
        if it.status ~= "built" and it.status ~= "skipped" and not IsHeld(it) then
            if it.act == "reclaim" then reclaim = true
            elseif it.defID then defs[it.defID] = true end
        end
    end
    return defs, reclaim
end

local function BuilderCan(st, defID)
    for _, b in ipairs(st.builders) do
        local bd = Spring.GetUnitDefID(b)
        if bd and S.env.BP_PLACER.CanBuild(bd, defID) then return true end
    end
    return false
end

-- Is this con one of a block's residents (block.cons[role] == uid)?
local function IsResident(uid)
    for _, b in ipairs(S.blocks) do
        if b.cons then for _, id in pairs(b.cons) do if id == uid then return true end end end
    end
    return false
end

local function TakeOwnCon(defID, x, z)
    local best, bestD
    for uid, state in pairs(S.cons) do
        local bd = Spring.GetUnitDefID(uid)
        if not bd then S.cons[uid] = nil
        elseif state == true and (not defID or S.env.BP_PLACER.CanBuild(bd, defID)) then
            if not x then
                S.cons[uid] = "busy"
                return uid
            end
            local ux, _, uz = Spring.GetUnitPosition(uid)         -- the free con nearest the job
            local d = ux and (ux - x) ^ 2 + (uz - z) ^ 2 or 1e18
            if not bestD or d < bestD or (d == bestD and uid < best) then best, bestD = uid, d end
        end
    end
    if best then S.cons[best] = "busy"; return best end
    if Cfg().BLOCK_CONS then          -- no free con: an idle resident of a block with no swap going on does the job (and goes back after)
        local swapping = {}
        for _, slot in ipairs(S.slots) do
            if slot.state == "clear" or slot.state == "build" or slot.wantLab then swapping[slot.block] = true end
        end
        for _, b in ipairs(S.blocks) do
            if b.cons and not swapping[b] and not (S.swap and S.swap.stage) then
                for _, role in ipairs(Cfg().BLOCK_CON_UNITS) do
                    local uid = b.cons[role]
                    if uid and S.cons[uid] == "res" and Alive(uid) then
                        local bd = Spring.GetUnitDefID(uid)
                        if not defID or S.env.BP_PLACER.CanBuild(bd, defID) then
                            S.cons[uid] = "resbusy"
                            return uid
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function ReleaseBuilders(ses)
    local env, st = S.env, ses.state
    local list = {}
    for i, uid in ipairs(st.builders) do list[i] = uid end
    for _, uid in ipairs(list) do
        env.BP_PLACER.RemoveBuilder(st, uid)
        if Alive(uid) then
            local d = UnitDefs[Spring.GetUnitDefID(uid)]
            if d and d.canFly then env.ReturnCon(uid)
            elseif S.cons[uid] then
                S.cons[uid] = (S.cons[uid] == "resbusy") and "res" or true
                Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
            end
        end
    end
end

-- LAB_TAKES_BLOCK_CON: a builder of a nano block's session that can build defID moves to a lab job
local function TakeBlockCon(defID)
    for _, other in ipairs(S.sessions) do
        if other.kind == "block" and not other.done then
            for _, b in ipairs(other.state.builders) do
                local bd = Spring.GetUnitDefID(b)
                if bd and S.cons[b] and S.env.BP_PLACER.CanBuild(bd, defID) then
                    S.env.BP_PLACER.RemoveBuilder(other.state, b)
                    S.cons[b] = "busy"
                    Log("con %d moves from block #%d to a %s job", b, other.block and other.block.index or 0,
                        (UnitDefs[defID] or {}).name or "?")
                    return b
                end
            end
        end
    end
    return nil
end
-- POOL API (C2; con_broker's CB.AddPool / CB.TakeAny / CB.GiveBack wrap these).  Another system (the metal sink, the line decoy labs) borrows
-- one of the spine's ground cons that can place req.defID: a free one (the nearest to req.near), else an idle block resident, and with
-- req.allowBlock a builder off a nano block's job.  The con is "busy" for the spine, and its borrower is remembered: only that borrower can
-- give it back, and a resident goes back to being a resident (it used to come back as a plain pool con, and the block lost it for good).
function M.PoolTake(owner, req)
    if not S then return nil end
    req = req or {}
    local x, z = req.near and req.near[1], req.near and req.near[2]
    local uid = TakeOwnCon(req.defID, x, z)
    if not uid and req.allowBlock and req.defID then uid = TakeBlockCon(req.defID) end
    if uid then
        S.borrowed = S.borrowed or {}
        S.borrowed[uid] = { owner = owner }
    end
    return uid
end
function M.PoolGive(uid, owner)
    if not S or not S.cons[uid] then return false end
    local b = S.borrowed and S.borrowed[uid]
    if b and owner and b.owner ~= owner then return false end       -- not the one that took it
    if S.borrowed then S.borrowed[uid] = nil end
    if Alive(uid) then
        S.cons[uid] = IsResident(uid) and "res" or true
        Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
    else
        S.cons[uid] = nil
    end
    return true
end
-- The host asked this lab for cons first (AdoptLab conWant) and it has not made them all yet.
local ConCapReached        -- defined below (CON_CAP)
function M.FirstConWanted(labID)
    local L = S and S.labs[labID]
    return L ~= nil and not L.leaving and L.conWant ~= nil and (L.conMade or 0) < L.conWant and not ConCapReached()
end
function M.PoolCount()
    local total, idle = 0, 0
    if S then
        for uid, st in pairs(S.cons) do
            if Alive(uid) then
                total = total + 1
                if st == true or st == "res" then idle = idle + 1 end
            end
        end
    end
    return { total = total, idle = idle }
end

-- (the older entry points: the DRAGON_ECO macro and the tests call these; a borrow here may also take a builder off a block job)
function M.BorrowCon(defID)
    return M.PoolTake("borrow", { defID = defID, allowBlock = true })
end
function M.GiveBackCon(uid)
    M.PoolGive(uid, nil)
end


-- BLOCK_CONS: the block's resident con (one of BLOCK_CON_UNITS) that can build defID (nil: any) moves to a job of its slots.
local function TakeResident(block, defID)
    if not (block and block.cons and Cfg().BLOCK_CONS) then return nil end
    for _, role in ipairs(Cfg().BLOCK_CON_UNITS) do
        local uid = block.cons[role]
        if uid and Alive(uid) and S.cons[uid] == "res" then
            local bd = Spring.GetUnitDefID(uid)
            if not defID or S.env.BP_PLACER.CanBuild(bd, defID) then
                S.cons[uid] = "resbusy"
                return uid
            end
        end
    end
    return nil
end

-- EARLY_CONS: true while the spine is capped at EARLY_CONS ground cons (fewer than EARLY_CONS_LABS labs stand, before EARLY_CONS_UNTIL)
local function EarlyConCap()
    local K = Cfg()
    if (K.EARLY_CONS or 0) <= 0 or S.frame >= K.EARLY_CONS_UNTIL then return false end
    local labs = 0
    for uid, L in pairs(S.labs) do if Alive(uid) and not L.leaving then labs = labs + 1 end end
    return labs < K.EARLY_CONS_LABS
end
local function AliveGroundCons()
    local n = 0
    for uid, st in pairs(S.cons) do
        if Alive(uid) and st ~= "res" and st ~= "resbusy" then n = n + 1 end
    end
    return n
end
-- CON_CAP (user 2026-10-27: 6 vehicle cons made for no reason, one is enough for the spine): until CON_CAP_UNTIL the spine has at most CON_CAP ground cons in
-- all, counting residents and every kind of order (AdoptLab quotas, a job's wanted con, block residents).  A lost con is replaced (the count drops).
ConCapReached = function()
    local K = Cfg()
    if (K.CON_CAP or 0) <= 0 or S.frame >= K.CON_CAP_UNTIL then return false end
    local n = 0
    for uid in pairs(S.cons) do if Alive(uid) then n = n + 1 end end
    return n + math.max(0, S.conOrders - S.conOut) >= K.CON_CAP
end

-- A resident con a block still lacks and this lab can make: returns defID, block, role (nil if none).  An order is remembered
-- (b.conOrdered) for CON_ORDER_TTL so one lab does not order it twice.
local function ResidentWanted(ld)
    local K = Cfg()
    if not K.BLOCK_CONS or EarlyConCap() or ConCapReached() then return nil end
    local opt = BT.Options(ld.id)
    for _, b in ipairs(S.blocks) do
        b.cons, b.conOrdered = b.cons or {}, b.conOrdered or {}
        for _, role in ipairs(K.BLOCK_CON_UNITS) do
            local rd = UnitDefNames[role]
            local uid = b.cons[role]
            if uid and not Alive(uid) then b.cons[role], uid = nil, nil end
            local t = b.conOrdered[role]
            if t and S.frame - t > K.CON_ORDER_TTL then b.conOrdered[role], t = nil, nil end
            if rd and not uid and not t and opt[rd.id] then return rd.id, b, role end
        end
    end
    return nil
end

local function ServiceBuilders(ses)
    local env, st = S.env, ses.state
    local defs, reclaim = PendingDefs(st)
    if next(defs) == nil and not reclaim then
        if #st.builders > 0 then ReleaseBuilders(ses) end
        return
    end
    for defID in pairs(defs) do
        if BuilderCan(st, defID) then
            S.conWanted[defID] = nil
        else
            local air = AirOnly((UnitDefs[defID] or {}).name)
            local sx, sz = ses.slot and ses.slot.wx, ses.slot and ses.slot.wz
            local uid = (ses.slot and not air and TakeResident(ses.slot.block, defID)) or (not air and TakeOwnCon(defID, sx, sz))
                        or ((not env.GroundOnly or air) and env.TakeCon(defID, false))
                        or (ses.kind ~= "block" and not air and Cfg().LAB_TAKES_BLOCK_CON and TakeBlockCon(defID)) or nil
            if uid then env.BP_PLACER.AddBuilder(st, uid)
            else
                S.conWanted[defID] = true
                -- an air lab waits for a T1 air con: the line's air lab makes one (once per CON_ORDER_TTL)
                if air and env.QueueAirCon and S.frame - (S.airConAskF or -1e9) >= Cfg().CON_ORDER_TTL / 2 then
                    S.airConAskF = S.frame
                    env.QueueAirCon()
                    Log("an air con is ordered for the %s job", (UnitDefs[defID] or {}).name or "?")
                end
            end
        end
    end
    if reclaim and #st.builders == 0 then
        local uid = (ses.slot and TakeResident(ses.slot.block, nil)) or TakeOwnCon(nil) or (not env.GroundOnly and env.TakeCon(nil, true)) or nil
        if uid then env.BP_PLACER.AddBuilder(st, uid) end
    end
    if ses.kind == "block" then
        local nano = UnitDefNames.cornanotc
        while nano and #st.builders < Cfg().BUILDERS_PER_JOB do
            local uid = TakeOwnCon(nano.id) or (not env.GroundOnly and env.TakeCon(nano.id, true)) or nil
            if not uid or not env.BP_PLACER.AddBuilder(st, uid) then break end
        end
    end
end

-- ── Blocks and slots ─────────────────────────────────────────────────────────

local function OpenBlock()
    local env, K = S.env, Cfg()
    if #S.blocks >= K.MAX_BLOCKS then return nil end
    local ax, az
    for _ = 1, 2 * K.STACK_HALF + 1 do
        S.opened = (S.opened or 0) + 1
        if math.abs(SP.StackOffset(S.opened)) > K.STACK_HALF then return nil end
        ax, az = M.BlockAnchor(S.geo, env.baseX, env.baseZ, S.opened)
        local m = 200
        if ax >= m and az >= m and ax <= env.mapX - m and az <= env.mapZ - m
           and (not env.CellOK or env.CellOK(ax, az)) then break end
        ax = nil
    end
    if not ax then return nil end
    local bp = env.blueprint
    local ses = NewSession("block", bp.layout, ax, az)
    local block = { index = #S.blocks + 1, ax = ax, az = az, ses = ses, held = {}, heldStore = {}, slotsIdx = {} }
    -- the first CORE_NANOS (nearest the labs) are built at once, the rest wait to be released
    local n = 0
    for _, it in ipairs(ses.state.queue) do
        if it.cls == "nano" then
            n = n + 1
            if n > K.CORE_NANOS then
                it.spineWaits, it.waitsFor = it.waitsFor, HOLD
                block.held[#block.held + 1] = it
            end
        end
    end
    -- energy storages wait until ThrottleStorage releases them.  A storage row in the gap between two blocks is shared: a
    -- storage whose spot another block already holds is dropped from this block's queue.
    local q, i = ses.state.queue, 1
    while i <= #q do
        local it = q[i]
        local drop = false
        if it.n == K.STORE_UNIT and it.act ~= "reclaim" then
            for _, ob in ipairs(S.blocks) do
                for _, o in ipairs(ob.ses.state.queue) do
                    if o.n == K.STORE_UNIT and math.abs(o.wx - it.wx) < 16 and math.abs(o.wz - it.wz) < 16 then drop = true; break end
                end
                if drop then break end
            end
            if not drop then
                it.spineWaits, it.waitsFor = it.waitsFor, HOLD
                block.heldStore[#block.heldStore + 1] = it
            end
        end
        if drop then table.remove(q, i) else i = i + 1 end
    end
    ses.block = block
    for _, s in ipairs(bp.slots or {}) do
        local rx, rz = RotateOffset(s.x, s.z, S.geo.rot)
        local slot = { block = block, x = s.x, z = s.z, wx = ax + rx, wz = az + rz, state = "free", id = #S.slots + 1 }
        S.slots[#S.slots + 1] = slot
        block.slotsIdx[#block.slotsIdx + 1] = slot
    end
    S.blocks[#S.blocks + 1] = block
    Log("opened block #%d at (%d, %d): %d nanos (%d held), %d slots", block.index, ax, az, n, #block.held, #block.slotsIdx)
    return block
end

local function ReleaseHeld(block, k, list)
    list = list or "held"
    local n = 0
    while n < k and #block[list] > 0 do
        local it = table.remove(block[list], 1)
        it.waitsFor, it.spineWaits = it.spineWaits, nil
        n = n + 1
    end
    return n
end

local function NanoDef() return UnitDefNames.cornanotc end

-- Blocks with both lab slots free: the "open" blocks a transition can put labs in.
local function SpareBlocks()
    local n = 0
    for _, b in ipairs(S.blocks) do
        local free = true
        for _, s in ipairs(b.slotsIdx) do if s.state ~= "free" then free = false; break end end
        if free then n = n + 1 end
    end
    return n
end

-- Share of the standing, finished nanos that are building something (parked or idle ones count as unused), smoothed.
-- nil while no nano stands (no gate then).
local function NanoUtil()
    if S.frame - (S.utilFrame or -1e9) < 15 then return S.util end
    S.utilFrame = S.frame
    local n, busy = 0, 0
    for uid in pairs(S.nanos) do
        if Alive(uid) and not Spring.GetUnitIsBeingBuilt(uid) then
            n = n + 1
            if Spring.GetUnitIsBuilding(uid) ~= nil then busy = busy + 1 end
        end
    end
    if n == 0 then S.util = nil; return nil end
    local u = busy / n
    S.util = S.util and (S.util * 0.8 + u * 0.2) or u
    return S.util
end

-- Is the build-ahead / extra-lab gate open?  (always, when NANO_UTIL_GATE is 0 or no nano stands)
local function UtilOpen()
    local g = Cfg().NANO_UTIL_GATE or 0
    if g <= 0 then return true end
    local u = NanoUtil()
    return u == nil or u >= g
end

local function ThrottleNanos()
    local K = Cfg()
    local allowed, inflight = 0, 0
    for _, b in ipairs(S.blocks) do
        for _, it in ipairs(b.ses.state.queue) do
            if it.cls == "nano" and not IsHeld(it) and it.status ~= "skipped" then
                allowed = allowed + 1
                if it.status ~= "built" then inflight = inflight + 1 end
            end
        end
    end
    local ready = (not S.env.MexGridsReady) or S.mexReady
    local ahead = (ready and S.income >= K.BUILD_AHEAD_INCOME and UtilOpen()) and K.BUILD_AHEAD or 0
    local nanoShare = math.max(S.share, S.nanoFloor, ahead)
    if K.NANO_SHARE_CAP then nanoShare = math.min(nanoShare, K.NANO_SHARE_CAP) end
    local mult = S.freeRun and K.FLOAT_MULT or 1
    local need = math.ceil(K.NANO_HEADROOM * nanoShare * S.income * mult / math.max(S.nanoRate, 1e-6) - 1e-9)
    if (S.spendFloor or 0) > 0 then
        local g = UnitDefNames.corgator
        local nd = NanoDef()
        if g and nd and (g.buildTime or 0) > 0 and (g.metalCost or 0) > 0 then
            local gRate = (nd.buildSpeed or 200) * g.metalCost / g.buildTime    -- metal/s one nano puts into gators
            need = math.max(need, math.ceil(K.NANO_HEADROOM * S.spendFloor / gRate - 1e-9))
        end
    end
    S.nanoAllowed, S.nanoNeed = allowed, need    -- nanoNeed (what the spend uses) drives guarding; slack nanos stay parked
    -- slack: keep SLACK_BLOCKS blocks free of labs, with every nano of theirs standing, on top of the blocks in use
    local buildNeed = need
    -- LAB_MIN_NANOS: build (not necessarily use) the nanos a waiting lab needs: LAB_MIN_NANOS per lab, placed ones + the next
    if (K.LAB_MIN_NANOS or 0) > 0 then
        local placed = 0
        for _, slot in ipairs(S.slots) do if slot.state == "build" or slot.state == "lab" then placed = placed + 1 end end
        buildNeed = math.max(buildNeed, K.LAB_MIN_NANOS * (1 + placed))
    end
    S.spare = SpareBlocks()
    if K.SLACK_BLOCKS > 0 and ready and S.income >= K.SLACK_INCOME and (S.bankFrac or 1) >= K.SLACK_MIN_BANK then
        buildNeed = math.max(need, (#S.blocks - S.spare + K.SLACK_BLOCKS) * K.NANOS_PER_BLOCK)
    end
    -- NANO_CAP = { max, untilF }: until that frame at most `max` spine nanos are built (a nano is 230 metal that is not army)
    local cap = K.NANO_CAP
    if cap and S.frame < (cap.untilF or 0) then buildNeed = math.min(buildNeed, cap.max) end
    -- NANO_BUILD_UTIL: the standing nanos are mostly idle (a lab waiting for its next order, or metal short): more nanos would only add idle ones
    if (K.NANO_BUILD_UTIL or 0) > 0 and allowed > 0 then
        local u = NanoUtil()
        if u ~= nil and u < K.NANO_BUILD_UTIL then
            local floorNeed = (K.LAB_MIN_NANOS or 0) > 0 and K.LAB_MIN_NANOS * (1 + (function() local p = 0; for _, slot in ipairs(S.slots) do if slot.state == "build" or slot.state == "lab" then p = p + 1 end end return p end)()) or 0
            buildNeed = math.min(buildNeed, math.max(allowed, floorNeed))
            if S.frame - (S.utilLogF or -1e9) >= 900 and need > allowed then
                S.utilLogF = S.frame
                Log("nano gate: %d nanos stand, %.0f%% building (< %.0f%%): none of the %d more wanted are built", allowed, u * 100, K.NANO_BUILD_UTIL * 100, need - allowed)
            end
        end
    end
    S.nanoBuildNeed = buildNeed
    if allowed >= buildNeed then return end
    local k = math.min(K.NANO_BATCH, buildNeed - allowed, K.NANO_INFLIGHT - inflight)
    for _, b in ipairs(S.blocks) do
        if k <= 0 then break end
        k = k - ReleaseHeld(b, k)
    end
    -- every block fully released and still short: open the next (one at a time)
    if k > 0 and S.started and not (S.openAfter and S.frame < S.openAfter) then
        for _, b in ipairs(S.blocks) do if #b.held > 0 then return end end
        for _, ses in ipairs(S.sessions) do
            if ses.kind == "block" and not ses.done then
                local n, built = 0, 0
                for _, it in ipairs(ses.state.queue) do
                    if it.cls == "nano" and not IsHeld(it) then
                        n = n + 1
                        if it.status == "built" then built = built + 1 end
                    end
                end
                if n == 0 or built < Cfg().BLOCK_OPEN_FRAC * n then return end
            end
        end
        OpenBlock()
    end
end

-- Energy storage worth STORE_SECONDS of energy income (on top of whatever else stands), built from the blocks' held
-- corestors.  Without it a late game bank of 6-7k is under a second of a 16k/s income and the bank fraction says nothing.
local function ThrottleStorage(res)
    local K = Cfg()
    if not (S.mexReady and res and res.energyStorage and res.energyIncome) then return end
    local sd = UnitDefNames[K.STORE_UNIT]
    local per = (sd and sd.energyStorage and sd.energyStorage > 0) and sd.energyStorage or 6000
    local allowed, inflight, built = 0, 0, 0
    for _, b in ipairs(S.blocks) do
        for _, it in ipairs(b.ses.state.queue) do
            if it.n == K.STORE_UNIT and it.act ~= "reclaim" and not IsHeld(it) and it.status ~= "skipped" then
                allowed = allowed + 1
                if it.status == "built" then built = built + 1 else inflight = inflight + 1 end
            end
        end
    end
    local target = K.STORE_SECONDS * res.energyIncome
    local other = math.max(0, res.energyStorage - built * per)
    local need = math.max(0, math.ceil((target - other) / per - 1e-9))
    S.storeAllowed, S.storeNeed, S.storeTarget = allowed, need, target
    if allowed >= need or S.income < K.STORE_INCOME or (S.bankFrac or 1) < K.STORE_MIN_BANK then return end
    local k = math.min(K.STORE_BATCH, need - allowed, K.STORE_INFLIGHT - inflight)
    for _, b in ipairs(S.blocks) do
        if k <= 0 then break end
        k = k - ReleaseHeld(b, k, "heldStore")
    end
end

-- ── Labs: plan, place, swap ──────────────────────────────────────────────────

local function Standing()
    local have, building = {}, {}
    if S.frame < Cfg().EXPECT_UNTIL then
        for name, n in pairs(S.expect) do if n > 0 then have[name] = (have[name] or 0) + n end end
    end
    for uid, L in pairs(S.labs) do          -- a lab the host built (the line's vehicle plant) counts as standing
        if not L.slot and not L.leaving and Alive(uid) then have[L.name] = (have[L.name] or 0) + 1 end
    end
    for _, slot in ipairs(S.slots) do
        if slot.state == "lab" then have[slot.labName] = (have[slot.labName] or 0) + 1
        elseif slot.state == "build" then building[slot.labName] = (building[slot.labName] or 0) + 1 end
    end
    return have, building
end

local function LabAllowed(name)
    local d = UnitDefNames[name]
    if not d then return false end
    local K = Cfg()
    if (d.metalCost or 0) < K.GATE_COST or S.floating or not S.env.ArmyValue then return true end
    return (S.env.ArmyValue() or 0) >= K.GATE_MARGIN * d.metalCost
end

local function IsWide(name)
    local d = UnitDefNames[name]
    return d ~= nil and (math.max(d.xsize or 0, d.zsize or d.ysize or 0) * 8 > Cfg().WIDE_ELMOS or (Cfg().WIDE_LABS or {})[name] == true)
end

-- The other slot of a slot's block (a block has two).
local function Partner(slot)
    for _, o in ipairs(slot.block.slotsIdx) do if o ~= slot then return o end end
    return nil
end

-- A free slot; for a wide lab, a block whose slots are BOTH free.
local function FreeSlot(wide)
    for _, s in ipairs(S.slots) do
        if s.state == "free" and not (s.badUntil and S.frame < s.badUntil) then
            if not wide then return s end
            local p = Partner(s)
            if p and p.state == "free" then return s end
        end
    end
    return nil
end

local function JobCount()
    local n = 0
    for _, ses in ipairs(S.sessions) do if ses.kind ~= "block" and not ses.done then n = n + 1 end end
    return n
end

local function StartBuild(slot, name)
    local x, z = slot.x, slot.z
    if IsWide(name) then
        local p = Partner(slot)
        x, z = Cfg().WIDE_X, 0
        slot.wide = true
        if p then p.state, p.owner = "taken", slot end
    end
    local ses = NewSession("lab", { { n = name, x = x, z = z, f = 1 } }, slot.block.ax, slot.block.az,
                           { slot = slot })
    slot.state, slot.labName, slot.ses = "build", name, ses
    Log("slot %d: building %s", slot.id, name)
end

-- CLEAR_NEEDS_CON: is one of our cons that can build `labName` (or, nil, any lab the plan builds the comp with) within CLEAR_CON_R?
local function ConInRange(x, z, labName)
    local K = Cfg()
    if not K.CLEAR_NEEDS_CON then return true end
    local targets = {}
    if labName then
        local d = UnitDefNames[labName]
        if d then targets[1] = d.id end
    else
        for name, share in pairs(S.plan or {}) do
            local d = UnitDefNames[name]
            if d and share > 0 then targets[#targets + 1] = d.id end
        end
    end
    local r2 = K.CLEAR_CON_R * K.CLEAR_CON_R
    for uid in pairs(S.cons) do
        local bd = Spring.GetUnitDefID(uid)
        if bd then
            local ux, _, uz = Spring.GetUnitPosition(uid)
            if ux and (ux - x) ^ 2 + (uz - z) ^ 2 <= r2 then
                for _, t in ipairs(targets) do
                    if S.env.BP_PLACER.CanBuild(bd, t) then return true end
                end
            end
        end
    end
    return false
end

-- world position of a slot's lab (its unit), else the block's anchor
local function SlotPos(slot)
    if slot.uid then
        local x, _, z = Spring.GetUnitPosition(slot.uid)
        if x then return x, z end
    end
    return slot.block.ax, slot.block.az
end

local function StartClear(slot)
    local cx, cz = slot.x, slot.z
    if slot.wide then cx, cz = Cfg().WIDE_X, 0 end
    -- The placer finds a reclaim target only among its OWN queue entries that carry a unit (blueprint_placer FindReclaimTarget): a reclaim
    -- item alone read "nothing standing there" and finished at once, so the slot was freed with the lab still on it (CORE_STD games 4-8:
    -- the old plants stood all game and the new plant could not be placed over them).  The lab goes into the queue as a built entry first.
    local ses = NewSession("clear", { { n = slot.labName, x = cx, z = cz, f = 1 }, { n = slot.labName, x = cx, z = cz, f = 1, a = "reclaim" } },
                           slot.block.ax, slot.block.az, { slot = slot })
    do
        local first = ses.state.queue[1]
        if first and slot.uid then first.status, first.built, first.frameID = "built", true, slot.uid end
    end
    local was = slot.labName
    slot.state, slot.ses = "clear", ses
    if slot.uid then
        local L = S.labs[slot.uid]
        if L then L.leaving = true end
        Spring.GiveOrderToUnit(slot.uid, CMD_STOP, {}, {})
    end
    Log("slot %d: clearing %s", slot.id, tostring(was))
end

-- RECLAIM_UNNEEDED: labs the plan has dropped (need 0) are cleared once one that builds the comp (plan share > 0) stands.  Slot labs
-- go through StartClear; an adopted lab (the host's own, not in a slot) gets a reclaim session at its own position.
local function ReclaimUnneeded(need, plan, have)
    local K = Cfg()
    local ready = false
    for name, share in pairs(plan) do if share > 0 and (have[name] or 0) > 0 then ready = true end end
    if not ready then return end
    local maxJobs = S.freeRun and K.MAX_JOBS_FLOAT or K.MAX_JOBS
    for _, slot in ipairs(S.slots) do
        if JobCount() >= maxJobs then return end
        if slot.state == "lab" and (need[slot.labName] or 0) == 0 and slot.surplusSince
           and S.frame - slot.surplusSince >= K.RECLAIM_DELAY and ConInRange(SlotPos(slot)) then
            StartClear(slot)
        end
    end
    local ids = {}
    for uid, L in pairs(S.labs) do if L.adopted and not L.leaving then ids[#ids + 1] = uid end end
    table.sort(ids)
    for _, uid in ipairs(ids) do
        local L = S.labs[uid]
        if (need[L.name] or 0) == 0 and Alive(uid) then
            L.surplusSince = L.surplusSince or S.frame
            if S.frame - L.surplusSince >= K.RECLAIM_DELAY and JobCount() < maxJobs then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x and ConInRange(x, z) then
                    local cses = NewSession("clear", { { n = L.name, x = 0, z = 0, f = 1 }, { n = L.name, x = 0, z = 0, f = 1, a = "reclaim" } }, x, z,
                                            { adoptedUid = uid })
                    local first = cses.state.queue[1]
                    if first then first.status, first.built, first.frameID = "built", true, uid end
                    L.leaving = true
                    Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
                    Log("adopted %s %d: clearing (no longer in the plan)", L.name, uid)
                end
            end
        else
            L.surplusSince = nil
        end
    end
end

-- Can anything we have make a con that can place this lab?  A con already standing, or a standing lab that builds one.
local function HasConSource(labName)
    local target = UnitDefNames[labName]
    if not target then return true end
    if AirOnly(labName) then return S.env.QueueAirCon ~= nil or S.env.TakeCon ~= nil end    -- an air con can be pulled / ordered
    for uid, state in pairs(S.cons) do
        local bd = Spring.GetUnitDefID(uid)
        if bd and S.env.BP_PLACER.CanBuild(bd, target.id) then return true end
    end
    for uid in pairs(S.labs) do        -- a standing lab that makes a ground con able to place it
        local ld = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if ld and BT.ConMadeBy(ld, { canPlace = target.id }) then return true end
    end
    return false
end

-- A planned lab nobody can place (a T2 plant needs a T1 con, which a T1 lab makes) pulls in the cheapest T1 lab that
-- makes such a con.  `plan` gets the lab with share 0, so it counts once.
function M.Enablers(plan, hasSource)
    local K = Cfg()
    for _ = 1, 3 do                               -- a T3 plant needs a T2 con, whose lab needs a T1 con...
    local names = {}
    for name in pairs(plan) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local d = UnitDefNames[name]
        if d and (d.metalCost or 0) >= K.GATE_COST and not hasSource(name) then
            local allow = {}                          -- the candidate labs not in the plan yet
            for _, cand in ipairs(K.LAB_CANDIDATES) do if not plan[cand] then allow[cand] = true end end
            local e = BT.EnablerLab(d, allow)
            local best = e and e.name
            if best then plan[best] = 0 end
        end
    end
    end
end

-- ── WAVE_SWAP / IDLE_LAB_T2 (CORE) ──────────────────────────────────────────

-- Is a lab of the previous stance that waits to be swapped out: it keeps producing the previous stance's units (lab_rules asks).
function M.IsReplacing(labID)
    if not S or not Cfg().WAVE_SWAP then return false end
    local L = S.labs[labID]
    local slot = L and L.slot
    return slot ~= nil and slot.state == "lab" and slot.surplusSince ~= nil and not L.leaving
end

local function LabBusy(uid)
    if S.env.LabBusy then return S.env.LabBusy(uid) end
    local cmds = Spring.GetFactoryCommands and Spring.GetFactoryCommands(uid, -1) or Spring.GetUnitCommands(uid, -1)
    if type(cmds) == "table" and #cmds > 0 then return true end
    return Spring.GetUnitIsBuilding(uid) ~= nil
end

-- Clear the slots in `list` (most-wanted-first order is the caller's).  No RECLAIM_DELAY, no job cap, no con-in-range test.
local function ClearWave(list)
    for _, slot in ipairs(list) do StartClear(slot) end
end

-- WAVE_SWAP: replace the surplus labs where a lab the plan needs is missing and no free slot takes it.  Wave 1 = half (spread over
-- the blocks, round robin), wave 2 = the rest SWAP_WAVE_GAP after wave 1's new labs stand.
local function SwapWaves(need, have, building)
    local K = Cfg()
    local missing, wideWanted = 0, false
    for name, n in pairs(need) do
        local m = n - (have[name] or 0) - (building[name] or 0)
        local d0 = UnitDefNames[name]
        if m > 0 and not (d0 and (d0.metalCost or 0) >= K.GATE_COST and not HasConSource(name)) then
            missing = missing + m * (IsWide(name) and 2 or 1)        -- a wide lab (the gantry) takes both slots of a block
            if IsWide(name) then wideWanted = true end
        end
    end
    local free, clearing, victims = 0, 0, {}
    local forced = S.swapFresh or S.swap ~= nil
    for _, slot in ipairs(S.slots) do
        if slot.state == "free" then free = free + 1
        elseif slot.state == "clear" then clearing = clearing + 1
        elseif slot.state == "lab" and slot.surplusSince and not slot.keep and not slot.wide
               and ((forced and S.plan[slot.labName] == nil) or S.frame - slot.surplusSince >= K.RECLAIM_DELAY) then
            -- a lab the plan dropped (a stance change) goes at once; one only beyond its count (the need wobbles with income) waits
            victims[#victims + 1] = slot
        end
    end
    local want = missing - free - clearing
    -- a lab the stance dropped goes whether or not another lab is missing (its BP would idle; the freed slot is refilled by the planner,
    -- else the idle-lab rule / spare blocks use it): reclaim all of them, in the two waves
    if forced then
        local obsolete = 0
        for _, v in ipairs(victims) do if S.plan[v.labName] == nil then obsolete = obsolete + 1 end end
        want = math.max(want, obsolete)
    end
    local sw = S.swap
    if sw and sw.stage == 1 then
        local done = true
        for _, e in ipairs(sw.slots) do
            local sl = e.slot
            local ok = (sl.state == "lab" and sl.uid ~= e.old) or (sl.state == "free" and missing == 0)
            if not ok then done = false end
        end
        if done or S.frame - sw.since >= K.SWAP_TIMEOUT then
            sw.stage, sw.gapUntil = 2, S.frame + K.SWAP_WAVE_GAP
            Log("swap: wave 1 done, wave 2 at +%ds", K.SWAP_WAVE_GAP / 30)
        end
    elseif sw and sw.stage == 2 then
        if S.frame >= sw.gapUntil then
            S.swap = nil
            if want > 0 and #victims > 0 then
                local n = math.min(want, #victims)
                table.sort(victims, function(a, b) return a.surplusSince < b.surplusSince end)
                local list = {}
                for i = 1, n do list[i] = victims[i] end
                Log("swap: wave 2, %d labs", #list)
                ClearWave(list)
            end
        end
    elseif not sw and want > 0 and #victims > 0 and clearing == 0 then
        local n = math.min(want, #victims)
        -- round robin over the blocks so each block keeps half its labs producing
        local byBlock, order = {}, {}
        table.sort(victims, function(a, b) return a.id < b.id end)
        for _, v in ipairs(victims) do
            local b = v.block.index
            if not byBlock[b] then byBlock[b] = {}; order[#order + 1] = b end
            table.insert(byBlock[b], v)
        end
        local picked, k = {}, 1
        if wideWanted then
            -- a wide lab needs BOTH slots of a block: take whole blocks (those with the most victims first)
            table.sort(order, function(a, b)
                if #byBlock[a] ~= #byBlock[b] then return #byBlock[a] > #byBlock[b] end
                return a < b
            end)
            for _, b in ipairs(order) do
                if #picked >= n then break end
                for _, v in ipairs(byBlock[b]) do picked[#picked + 1] = v end
            end
        else
            while #picked < n do
                local any = false
                for _, b in ipairs(order) do
                    local v = byBlock[b][k]
                    if v and #picked < n then picked[#picked + 1] = v; any = true end
                end
                if not any then break end
                k = k + 1
            end
        end
        n = #picked
        local half = n == 1 and 1 or math.ceil(n / 2)
        if wideWanted and n > 2 then                 -- keep the halves on whole blocks
            half = 2 * math.ceil(n / 4)
            if half >= n then half = n - (n % 2 == 0 and 2 or 1) end
            if half < 1 then half = n end
        end
        local wave = {}
        S.swap = { stage = 1, since = S.frame, slots = {} }
        for i = 1, half do
            wave[i] = picked[i]
            S.swap.slots[i] = { slot = picked[i], old = picked[i].uid }
        end
        Log("swap: wave 1, %d of %d labs", #wave, n)
        ClearWave(wave)
    end
end

-- IDLE_LAB_T2: a slot lab with nothing queued or building for IDLE_LAB_FRAMES is replaced by a T2 bot lab.
local function IdleLabs()
    local K = Cfg()
    for _, slot in ipairs(S.slots) do
        if slot.state == "lab" and slot.uid and Alive(slot.uid) then
            local L = S.labs[slot.uid]
            if L and not L.leaving then
                if LabBusy(slot.uid) then
                    L.emptySince = nil
                else
                    L.emptySince = L.emptySince or S.frame
                    local b = slot.block
                    if slot.labName ~= K.IDLE_LAB_UNIT and S.frame - L.emptySince >= K.IDLE_LAB_FRAMES
                       and S.frame - (b.idleSwapAt or -1e9) >= K.IDLE_LAB_GAP and not slot.wide
                       and (S.floating or (S.bankFrac or 0) >= K.IDLE_LAB_MIN_BANK) and UnitDefNames[K.IDLE_LAB_UNIT]
                       and LabAllowed(K.IDLE_LAB_UNIT) and HasConSource(K.IDLE_LAB_UNIT) then
                        b.idleSwapAt = S.frame
                        slot.wantLab = K.IDLE_LAB_UNIT
                        Log("idle lab slot %d (%s) empty %ds -> %s", slot.id, slot.labName, (S.frame - L.emptySince) / 30, K.IDLE_LAB_UNIT)
                        StartClear(slot)
                    end
                end
            end
        end
    end
end

-- A freed slot that was promised a lab (IDLE_LAB_T2) gets it before the planner's missing loop.
local function FillWanted()
    local K = Cfg()
    for _, slot in ipairs(S.slots) do
        if slot.wantLab and slot.state == "free" then
            if JobCount() < math.max(K.MAX_JOBS, #S.slots) and HasConSource(slot.wantLab) then
                StartBuild(slot, slot.wantLab)
                slot.keep = true
            end
            slot.wantLab = nil
        end
    end
end

local function PlanLabs()
    local K = Cfg()
    if #S.units == 0 or #S.slots == 0 then return end
    local have, building = Standing()
    local standing = {}
    for n, c in pairs(have) do standing[n] = c end
    for n, c in pairs(building) do standing[n] = (standing[n] or 0) + c end
    local fresh = K.WAVE_SWAP and S.stanceChangeAt ~= nil and S.frame - S.stanceChangeAt <= K.SWAP_WINDOW
    S.swapFresh = fresh
    local plan, tab = M.Cover(S.units, standing, LabAllowed, fresh)
    if next(plan) then
        M.Enablers(plan, HasConSource)
        for name in pairs(plan) do
            if not tab[name] then
                local d = UnitDefNames[name]
                tab[name] = { name = name, defID = d.id, cost = d.metalCost or 0, units = {} }
            end
        end
    end
    local ahead = (((not S.env.MexGridsReady) or S.mexReady) and S.income >= K.BUILD_AHEAD_INCOME and UtilOpen()) and K.BUILD_AHEAD or 0
    local spend = S.income * math.min(math.max(S.share, S.nanoFloor, ahead), K.NANO_SHARE_CAP or 1) * (S.freeRun and K.FLOAT_MULT or 1)
    local need = M.Counts(S.units, plan, tab, spend)
    -- FIRST_VP: until that many labs stand (or are building), the missing ones are vehicle plants, whatever the comp says
    local forcedVp, forcedNeed = false, 0
    if (K.FIRST_VP or 0) > 0 and S.frame < K.EARLY_CONS_UNTIL then
        -- labs that physically stand or are being placed (Standing() also counts the expected vehicle plant until EXPECT_UNTIL, even after it
        -- stands, which would count it twice); the expected plant counts only while no vehicle plant has been adopted yet
        local vp = K.FIRST_VP_NAME
        local total, haveVp = 0, 0
        for uid, L in pairs(S.labs) do
            if Alive(uid) and not L.leaving then
                total = total + 1
                if L.name == vp then haveVp = haveVp + 1 end
            end
        end
        for _, slot in ipairs(S.slots) do
            if slot.state == "build" then
                total = total + 1
                if slot.labName == vp then haveVp = haveVp + 1 end
            end
        end
        if haveVp == 0 and (S.expect[vp] or 0) > 0 then total = total + 1; haveVp = 1 end
        if total < K.FIRST_VP and UnitDefNames[vp] then
            forcedNeed = (have[vp] or 0) + (building[vp] or 0) + (K.FIRST_VP - total)
            need[vp] = math.max(need[vp] or 0, forcedNeed)
            plan[vp] = plan[vp] or 1
            if not tab[vp] then tab[vp] = { name = vp, defID = UnitDefNames[vp].id, cost = UnitDefNames[vp].metalCost or 0, units = {} } end
            forcedVp = true
        end
    end
    -- slots are limited: keep the labs with the most comp share first when there are more wanted than places
    local order = {}
    for name in pairs(need) do order[#order + 1] = name end
    local fv = forcedVp and K.FIRST_VP_NAME or nil
    table.sort(order, function(a, b)
        if fv and a ~= b and (a == fv or b == fv) then return a == fv end     -- FIRST_VP: the forced plant is placed first
        if plan[a] ~= plan[b] then return plan[a] > plan[b] end return a < b
    end)
    local room = #S.slots
    for _, name in ipairs(order) do
        local c = math.min(need[name], math.max(1, room - (#order - 1)))
        need[name] = c
        room = room - c
    end
    if forcedVp then need[K.FIRST_VP_NAME] = math.max(need[K.FIRST_VP_NAME] or 0, forcedNeed) end    -- the slot-room cap above must not trim the forced plant
    -- BLOCK_LAB_NANOS: a block puts a lab in a slot for every BLOCK_LAB_NANOS of its nanos that stand (at most one per slot), whatever the plan counts already (the host's
    -- adopted plants fill the plan; without this the first slot lab came after two full blocks of nanos, mirror 2026-10-27)
    if (K.BLOCK_LAB_NANOS or 0) > 0 and #order > 0 then
        local per, want, cur = {}, 0, 0
        for uid, n in pairs(S.nanos) do
            if Alive(uid) and not Spring.GetUnitIsBeingBuilt(uid) then per[n.block] = (per[n.block] or 0) + 1 end
        end
        for _, c in pairs(per) do want = want + math.min(2, math.floor(c / K.BLOCK_LAB_NANOS)) end
        for _, slot in ipairs(S.slots) do if slot.state == "build" or slot.state == "lab" then cur = cur + 1 end end
        if want > cur then
            for _, name in ipairs(order) do
                if HasConSource(name) then
                    need[name] = math.max(need[name] or 0, (have[name] or 0) + (building[name] or 0) + (want - cur))
                    break
                end
            end
        end
    end
    S.plan, S.need = plan, need

    -- mark surplus: a standing lab beyond need (or not in the plan at all) has been unneeded since...
    local seen = {}
    for _, slot in ipairs(S.slots) do
        if slot.state == "lab" then
            seen[slot.labName] = (seen[slot.labName] or 0) + 1
            local surplus = seen[slot.labName] > (need[slot.labName] or 0) and not slot.keep
            if surplus then slot.surplusSince = slot.surplusSince or S.frame else slot.surplusSince = nil end
        end
    end

    if K.RECLAIM_UNNEEDED then ReclaimUnneeded(need, plan, have) end
    if K.IDLE_LAB_T2 then IdleLabs() end
    if K.WAVE_SWAP then SwapWaves(need, have, building) end
    FillWanted()
    local maxJobs = S.freeRun and K.MAX_JOBS_FLOAT or K.MAX_JOBS
    if K.WAVE_SWAP then maxJobs = math.max(maxJobs, #S.slots) end

    -- missing labs go into free slots; if there is none, a surplus lab that has stood unneeded long enough goes
    for _, name in ipairs(order) do
        local missing = need[name] - (have[name] or 0) - (building[name] or 0)
        -- a lab nothing can place yet waits for its enabler (the T1 lab that makes the con): never park a slot on it
        local d0 = UnitDefNames[name]
        if missing > 0 and d0 and (d0.metalCost or 0) >= K.GATE_COST and not HasConSource(name) then missing = 0 end
        if missing > 0 and S.frame - (S.wantLogF or -1e9) >= 1800 then
            S.wantLogF = S.frame
            local fr = 0
            for _, sl in ipairs(S.slots) do if sl.state == "free" then fr = fr + 1 end end
            Log("wants %d more %s: free slots %d, jobs %d/%d, wide %s, con source %s", missing, name, fr, JobCount(), maxJobs, tostring(IsWide(name)),
                tostring(HasConSource(name)))
        end
        -- FIRST_VP: until the first labs stand, only the vehicle plant is started (the other labs wait for it)
        if forcedVp and name ~= K.FIRST_VP_NAME then missing = 0 end
        -- FIRST_VP: the forced plant waits until FIRST_LAB_NANOS spine nanos stand (nanos before the lab), and skips the nano-use gate below
        local forcedHere = forcedVp and name == K.FIRST_VP_NAME
        if forcedHere and missing > 0 then
            local built = 0
            for uid in pairs(S.nanos) do if Alive(uid) and not Spring.GetUnitIsBeingBuilt(uid) then built = built + 1 end end
            if built < (K.FIRST_LAB_NANOS or 0) then
                if S.frame - (S.firstVpLogF or -1e9) >= 900 then
                    S.firstVpLogF = S.frame
                    Log("first vehicle plant waits for nanos: %d of %d stand", built, K.FIRST_LAB_NANOS)
                end
                missing = 0
            end
        end
        -- LAB_MIN_NANOS: nanos before labs -- a new spine lab waits until LAB_MIN_NANOS nanos stand for each lab (placed ones + this one)
        if (K.LAB_MIN_NANOS or 0) > 0 and missing > 0 then
            local built, placed = 0, 0
            for uid in pairs(S.nanos) do if Alive(uid) and not Spring.GetUnitIsBeingBuilt(uid) then built = built + 1 end end
            for _, slot in ipairs(S.slots) do if slot.state == "build" or slot.state == "lab" then placed = placed + 1 end end
            if built < K.LAB_MIN_NANOS * (1 + placed) then
                if S.frame - (S.labNanoLogF or -1e9) >= 900 then
                    S.labNanoLogF = S.frame
                    Log("lab %s waits for nanos: %d stand, %d wanted (%d per lab, %d placed)", name, built, K.LAB_MIN_NANOS * (1 + placed), K.LAB_MIN_NANOS, placed)
                end
                missing = 0
            end
        end
        -- NANO_UTIL_GATE: a lab beyond the first of its type waits while the standing nanos are mostly idle
        if not forcedHere and missing > 0 and (have[name] or 0) + (building[name] or 0) > 0 and not UtilOpen() then
            if S.frame - (S.utilLogF or -1e9) >= 1800 then
                S.utilLogF = S.frame
                Log("lab gate: %d more %s wait, nano use %.0f%% < %.0f%%", missing, name, (S.util or 0) * 100, K.NANO_UTIL_GATE * 100)
            end
            missing = 0
        end
        while missing > 0 and JobCount() < maxJobs do
            local slot = FreeSlot(IsWide(name))
            if not slot then
                local victim
                for _, s in ipairs(S.slots) do
                    if s.state == "lab" and s.surplusSince and S.frame - s.surplusSince >= K.RECLAIM_DELAY
                       and (not victim or s.surplusSince < victim.surplusSince) then
                        local sx, sz = SlotPos(s)
                        if ConInRange(sx, sz, name) then victim = s end     -- CLEAR_NEEDS_CON: a con for `name` must be near
                    end
                end
                if victim and not K.WAVE_SWAP then StartClear(victim) end
                break
            end
            StartBuild(slot, name)
            missing = missing - 1
        end
    end
end

-- ── Nano control ─────────────────────────────────────────────────────────────

local function NanoLabs()
    -- standing labs: { uid, x, z, reach-half, weight }
    local out = {}
    for uid, L in pairs(S.labs) do
        if Alive(uid) and not L.leaving and not Spring.GetUnitIsBeingBuilt(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            local d = UnitDefs[Spring.GetUnitDefID(uid)]
            if x and d then out[#out + 1] = { uid = uid, x = x, z = z, half = HalfExtent(d), w = L.absorb or 1, n = 0 } end
        end
    end
    table.sort(out, function(a, b) return a.uid < b.uid end)
    return out
end

local function UpdateNanos()
    local K, NANO = Cfg(), S.env.NANO
    if not NANO then return end
    local list = {}
    for uid, n in pairs(S.nanos) do
        if Alive(uid) and not Spring.GetUnitIsBeingBuilt(uid) then list[#list + 1] = uid else S.nanos[uid] = nil end
    end
    table.sort(list)
    if S.freeRun then
        -- banking both: hand every nano back to the engine's own assist behaviour
        local n = 0
        for _, uid in ipairs(list) do
            local nn = S.nanos[uid]
            if nn.guard or nn.parked then
                NANO.Release(uid)
                nn.guard, nn.parked = nil, nil
                n = n + 1
            end
        end
        S.active, S.parked = 0, 0
        if n > 0 then Log("free run: %d nanos released (metal and energy banking)", n) end
        return
    end
    local labs = NanoLabs()
    local activeWant = math.min(#list, math.max(0, S.nanoNeed))
    if S.floating then activeWant = #list end
    local rush = RushOn()
    if rush then activeWant = #list end
    local gp = rush and NANO.PRIO.RUSH or NANO.PRIO.SPINE
    if rush ~= S.rushLogged then
        S.rushLogged = rush
        if not rush then                                   -- rush over: the guards go back to the normal spine priority
            for _, uid in ipairs(list) do
                local a = NANO.Assignment(uid)
                if a and a.prio == NANO.PRIO.RUSH then a.prio = NANO.PRIO.SPINE end
            end
        end
        Log("%s: %d spine nanos %s", rush and "RUSH on" or "rush over", #list, rush and "all guard a lab at high priority" or "back to the spend-sized set")
    end
    local nd = NanoDef()
    local reachBase = nd and nd.buildDistance or 128
    local moves = 0
    local noGuard = K.GUARD_NANOS == false
    -- WAVE_SWAP: nanos near a slot that is being cleared or built are never parked; they assist the builder of that job
    local swapSites = {}
    if K.WAVE_SWAP then
        for _, slot in ipairs(S.slots) do
            if slot.state == "clear" or slot.state == "build" then
                local bl = slot.ses and slot.ses.state and slot.ses.state.builders and slot.ses.state.builders[1]
                swapSites[#swapSites + 1] = { x = slot.wx, z = slot.wz, builder = bl and Alive(bl) and bl or nil }
            end
        end
    end
    local function SwapSite(x, z)
        local r = reachBase + 64
        for _, w in ipairs(swapSites) do if Dist2(x, z, w.x, w.z) <= r * r then return w end end
        return nil
    end
    -- count what is assigned already
    for i, uid in ipairs(list) do
        local n = S.nanos[uid]
        if n.guard then
            for _, l in ipairs(labs) do if l.uid == n.guard then l.n = l.n + 1 end end
        end
    end
    for i, uid in ipairs(list) do
        local n = S.nanos[uid]
        local x, _, z = Spring.GetUnitPosition(uid)
        if x and moves < K.MOVES_MAX then
            local a = NANO.Assignment(uid)
            if a and a.prio < gp then
                -- a hand-off or reclaim owns it right now
            elseif noGuard and i <= activeWant then
                -- GUARD_NANOS off: an active nano is left to the engine's own assist (no guard order); only the surplus is parked below
                if n.parked or n.guard or n.assist then
                    NANO.Release(uid)
                    n.parked, n.guard, n.assist = nil, nil, nil
                    moves = moves + 1
                end
            elseif not noGuard and SwapSite(x, z) then
                local w = SwapSite(x, z)
                if w.builder then
                    if n.assist ~= w.builder then
                        for _, l in ipairs(labs) do if l.uid == n.guard then l.n = l.n - 1 end end
                        NANO.Release(uid)
                        if NANO.Guard(NANO.PRIO.SPINE, uid, w.builder) then n.assist, n.guard, n.parked = w.builder, nil, nil; moves = moves + 1 end
                    end
                elseif n.parked or n.assist then
                    NANO.Release(uid)               -- no builder yet: the engine's own assist behaviour, not parked
                    n.parked, n.assist = nil, nil
                    moves = moves + 1
                end
            elseif i <= activeWant then
                -- best lab in reach: lowest nanos per absorb weight
                local best, bs
                for _, l in ipairs(labs) do
                    local reach = reachBase + l.half
                    if Dist2(x, z, l.x, l.z) <= reach * reach then
                        local score = (l.n + (n.guard == l.uid and 0 or 1)) / l.w
                        if not bs or score < bs then best, bs = l, score end
                    end
                end
                if best and rush and n.guard == best.uid then
                    NANO.Guard(gp, uid, best.uid)            -- already guarding it: raise the claim to the rush priority
                elseif best and n.guard ~= best.uid then
                    NANO.Release(uid)
                    if NANO.Guard(gp, uid, best.uid) then
                        for _, l in ipairs(labs) do if l.uid == n.guard then l.n = l.n - 1 end end
                        n.guard, n.parked, n.assist = best.uid, nil, nil
                        best.n = best.n + 1
                        moves = moves + 1
                    end
                elseif not best and not n.parked and K.PARK_NANOS then
                    NANO.Release(uid)
                    if NANO.Park(NANO.PRIO.SPINE, uid) then n.parked, n.guard, n.assist = true, nil, nil; moves = moves + 1 end
                end
            elseif K.PARK_NANOS and not n.parked then
                for _, l in ipairs(labs) do if l.uid == n.guard then l.n = l.n - 1 end end
                NANO.Release(uid)
                if NANO.Park(NANO.PRIO.SPINE, uid) then n.parked, n.guard, n.assist = true, nil, nil; moves = moves + 1 end
            end
        end
    end
    S.active = 0
    for _, uid in ipairs(list) do
        local nn = S.nanos[uid]
        if nn and (nn.guard or (noGuard and not nn.parked)) then S.active = S.active + 1 end
    end
    S.parked = #list - S.active
end

-- ── Start / Update ───────────────────────────────────────────────────────────

-- REBUILD_NANOS: re-open the queue item of a lost nano once REBUILD_DELAY has passed and nothing threatens the spot.
local function UpdateRebuild()
    if not S.rebuild or #S.rebuild == 0 then return end
    local K, keep = Cfg(), {}
    for _, r in ipairs(S.rebuild) do
        local it, b = r.item, r.block
        if not (b and b.ses) or it.status ~= "pending" and it.status ~= "built" then
            -- the item moved on (rebuilt, skipped, or the block is gone)
        elseif S.frame - r.since < K.REBUILD_DELAY or (S.env.Safe and not S.env.Safe(it.wx, it.wz, K.REBUILD_SAFE_R)) then
            keep[#keep + 1] = r
        elseif it.status == "built" then
            it.status, it.built, it.frameID, it.claimedBy, it.retries, it.deferUntil = "pending", false, nil, nil, 0, nil
            b.ses.done, b.ses.state.done = false, false
            local present = false
            for _, ses in ipairs(S.sessions) do if ses == b.ses then present = true; break end end
            if not present then S.sessions[#S.sessions + 1] = b.ses end
            S.rebuilt = (S.rebuilt or 0) + 1
            Log("block %d: nano at (%d, %d) lost, built again (%d so far)", b.index, it.wx, it.wz, S.rebuilt)
        end
    end
    S.rebuild = keep
end

function M.Start(frame, opts)
    if not S or S.started then return end
    local env = S.env
    if not SP then Spring.Echo("[SLOT] spine.lua geometry unavailable"); return end
    S.geo = env.geo or SP.Geometry(env.baseX, env.baseZ, env.mapX, env.mapZ)
    S.started, S.frame = true, frame or 0
    -- reserve every block spot and its lane so mex grids stay off them
    for i = 1, 2 * Cfg().STACK_HALF + 1 do
        local ax, az = M.BlockAnchor(S.geo, env.baseX, env.baseZ, i)
        env.Reserve(env.AnchorKey(ax, az))
        env.Reserve(env.AnchorKey(ax + S.geo.dx * 240, az + S.geo.dz * 240))
    end
    Log("start: enemy direction (%d, %d), rotation %d, lab facing %d", S.geo.dx, S.geo.dz, S.geo.rot, S.geo.facing)
    if not (opts and opts.deferOpen) then OpenBlock() end
end

function M.OpenFirst()
    if not S or not S.started or #S.blocks > 0 then return false end
    return OpenBlock() ~= nil
end

function M.Update(frame, res)
    if not S or not S.started then return end
    S.frame = frame
    local raw = res and res.metalIncome
    if raw then
        S.income = S.incomeSeen and (S.income + 0.1 * (raw - S.income)) or raw
        S.incomeSeen = true
    end
    if res and res.metal and res.metalStorage and res.metalStorage > 0 then S.bankFrac = res.metal / res.metalStorage end
    -- FREE RUN (user, 2026-10-12): while metal AND energy both bank, the nanos are left alone (nothing guarded, nothing parked)
    if res and res.metal and res.metalStorage and res.metalStorage > 0 and res.energy and res.energyStorage and res.energyStorage > 0 then
        local m, e = res.metal / res.metalStorage, res.energy / res.energyStorage
        local K = Cfg()
        if S.freeRun then S.freeRun = m >= K.FREE_OFF and e >= K.FREE_OFF
        else S.freeRun = m >= K.FREE_ON and e >= K.FREE_ON end
    end
    S.floating = ((S.env.Floating and S.env.Floating()) or S.freeRun) or false
    for _, ses in ipairs(S.sessions) do
        if not ses.done then S.env.BP_PLACER.Update(ses.state, frame, res or {}) end
    end
    if frame % Cfg().UPDATE_EVERY ~= 0 then return end

    if not S.mexReady and S.env.MexGridsReady and S.env.MexGridsReady() then S.mexReady = true end

    -- finished sessions: a clear frees its slot, a build is recorded when the lab finishes (OnUnitFinished)
    local keep = {}
    for _, ses in ipairs(S.sessions) do
        if ses.done then
            ReleaseBuilders(ses)
            local slot = ses.slot
            if ses.kind == "clear" and slot then
                if slot.uid then S.labs[slot.uid] = nil end
                slot.state, slot.uid, slot.labName, slot.ses, slot.surplusSince, slot.keep = "free", nil, nil, nil, nil, nil
                if slot.wide then
                    slot.wide = nil
                    local p = Partner(slot)
                    if p and p.owner == slot then p.state, p.owner = "free", nil end
                end
                Log("slot %d: free", slot.id)
            elseif ses.kind == "clear" and ses.adoptedUid then
                S.labs[ses.adoptedUid] = nil
                Log("adopted lab %d: cleared", ses.adoptedUid)
            elseif ses.kind == "lab" and slot and slot.state == "build" then
                if slot.uid then
                    slot.state = "lab"
                else
                    -- the placer finished the session without a lab standing (it skipped the item after its retries: ground blocked,
                    -- no builder could reach it).  The slot stayed "build" for the rest of the game (CORE_STD game 6: three slots, 5+ min).
                    local it = ses.state.queue[1] or {}
                    Log("slot %d: %s not built (placer item %s after %ds); the slot rests %ds", slot.id, tostring(slot.labName), tostring(it.status),
                        (frame - ses.since) / 30, Cfg().SLOT_BAD_FRAMES / 30)
                    slot.state, slot.labName, slot.ses, slot.wide = "free", nil, nil, nil
                    slot.badUntil = frame + Cfg().SLOT_BAD_FRAMES
                    local p = Partner(slot)
                    if p and p.owner == slot then p.state, p.owner = "free", nil end
                end
            end
        else
            keep[#keep + 1] = ses
        end
    end
    S.sessions = keep

    -- lab jobs take cons before the block's nanos do: a lab with no nanos is the lesser problem (the block already has
    -- its core), a slot with no lab is idle build power
    for _, ses in ipairs(S.sessions) do if ses.kind ~= "block" then ServiceBuilders(ses) end end
    for _, ses in ipairs(S.sessions) do if ses.kind == "block" then ServiceBuilders(ses) end end
    -- a clear session's builders keep reclaiming the lab: the placer gives the order once and, when something else moved the con (a step-out,
    -- another job, the engine dropping it), nothing gave it again (simulated swaps: five labs "clearing" for 5+ minutes)
    for _, ses in ipairs(S.sessions) do
        if ses.kind == "clear" and not ses.done then
            local target = (ses.slot and ses.slot.uid) or ses.adoptedUid
            if target and Alive(target) then
                for _, b in ipairs(ses.state.builders) do
                    if Alive(b) and frame - (ses.reclaimF or -1e9) >= 90 then
                        local cmds = Spring.GetUnitCommands(b, 1)
                        local c1 = type(cmds) == "table" and cmds[1] or nil
                        if not (c1 and c1.id == 90) then Spring.GiveOrderToUnit(b, 90, { target }, {}) end
                    end
                end
                if frame - (ses.reclaimF or -1e9) >= 90 then ses.reclaimF = frame end
            end
        end
    end
    -- WATCHDOG: a lab / clear job that has run 90 s with its builder far from the site (something else pulled it away) loses that builder;
    -- ServiceBuilders then gives it the nearest free con (stress runs: clears of 250-580 s with the con 400 elmos off)
    for _, ses in ipairs(S.sessions) do
        if (ses.kind == "lab" or ses.kind == "clear") and not ses.done and ses.slot and frame - ses.since >= 2700 then
            local list = {}
            for i, b in ipairs(ses.state.builders) do list[i] = b end
            for _, b in ipairs(list) do
                local bx, _, bz = Spring.GetUnitPosition(b)
                local d = Alive(b) and (S.geo and (S.frame) and bx) and math.sqrt((bx - ses.slot.wx) ^ 2 + (bz - ses.slot.wz) ^ 2) or 0
                local bd = Spring.GetUnitDefID(b)
                if d > 250 and bd and not UnitDefs[bd].canFly and frame - (ses.dogF or -1e9) >= 900 then
                    ses.dogF = frame
                    S.env.BP_PLACER.RemoveBuilder(ses.state, b)
                    S.cons[b] = (S.cons[b] == "resbusy") and "res" or true
                    Spring.GiveOrderToUnit(b, CMD_STOP, {}, {})
                    Log("watchdog: con %d is %d elmos from slot %d's %s job after %ds; it is replaced", b, d, ses.slot.id, ses.kind, (frame - ses.since) / 30)
                end
            end
        end
    end
    local pending = {}
    for _, ses in ipairs(S.sessions) do for d in pairs((PendingDefs(ses.state))) do pending[d] = true end end
    for d in pairs(S.conWanted) do if not pending[d] then S.conWanted[d] = nil end end
    for d, t in pairs(S.conPending) do if frame - t > Cfg().CON_ORDER_TTL then S.conPending[d] = nil end end
    -- labs on their way out take no more orders
    for _, slot in ipairs(S.slots) do
        if slot.state == "clear" and slot.uid and Alive(slot.uid) then Spring.GiveOrderToUnit(slot.uid, CMD_STOP, {}, {}) end
    end

    UpdateRebuild()
    ThrottleNanos()
    ThrottleStorage(res)
    PlanLabs()
    UpdateNanos()

    -- a lab job that has run a minute: who builds it and what the placer says (diagnosing builds that never finish)
    if frame - (S.lastJobLog or -1e9) >= 900 then
        S.lastJobLog = frame
        for _, ses in ipairs(S.sessions) do
            if ses.kind ~= "block" and not ses.done and frame - ses.since >= 1800 then
                local it = ses.state.queue[1] or {}
                local bs = {}
                for _, b in ipairs(ses.state.builders) do
                    local bx, _, bz = Spring.GetUnitPosition(b)
                    local bd = Spring.GetUnitDefID(b)
                    bs[#bs + 1] = string.format("%d(%s %s @%d,%d)", b, bd and UnitDefs[bd].name or "dead", tostring(S.cons[b]), bx or -1, bz or -1)
                end
                Log("job %s slot %s %s running %ds: item %s uid %s builders %d [%s] conWanted %s", ses.kind, ses.slot and ses.slot.id or "-",
                    tostring(it.n), (frame - ses.since) / 30, tostring(it.status), tostring(it.frameID or it.uid), #ses.state.builders,
                    table.concat(bs, " "), tostring(next(S.conWanted) ~= nil))
            end
        end
    end
    if frame - S.lastLog >= Cfg().LOG_EVERY then
        S.lastLog = frame
        local labs = {}
        for _, slot in ipairs(S.slots) do
            labs[#labs + 1] = string.format("%d:%s%s", slot.id, slot.state, slot.labName and ("/" .. slot.labName) or "")
        end
        local pl = {}
        for name, n in pairs(S.need or {}) do pl[#pl + 1] = string.format("%s=%d", name, n) end
        table.sort(pl)
        Log("plan %s", table.concat(pl, " "))
        Log("blocks %d (spare %d), nanos allowed %d need %d build %d (active %d parked %d), income %.0f share %.2f, estor allowed %d need %d target %.0f; slots %s",
            #S.blocks, S.spare or 0, S.nanoAllowed, S.nanoNeed, S.nanoBuildNeed or S.nanoNeed, S.active or 0, S.parked or 0,
            S.income, S.share, S.storeAllowed or 0, S.storeNeed or 0, S.storeTarget or 0, table.concat(labs, " "))
    end
end

-- ── Unit callbacks ───────────────────────────────────────────────────────────

local function SlotAt(x, z, name)
    local best, bd
    for _, s in ipairs(S.slots) do
        local d = Dist2(x, z, s.wx, s.wz)
        -- a slot waiting for exactly this lab takes it from 200 elmos (the placer may nudge a lab onto valid ground)
        local reach = (name and s.state == "build" and s.labName == name) and 200 or 70
        if d <= reach * reach and (not bd or d < bd) then best, bd = s, d end
    end
    return best
end

-- The block whose layout has a nano at (x, z): a nano of a mex grid next door is not one of ours.
local function BlockAt(x, z)
    for _, b in ipairs(S.blocks) do
        for _, it in ipairs(b.ses.state.queue) do
            if it.cls == "nano" and math.abs(x - it.wx) <= 24 and math.abs(z - it.wz) <= 24 then return b end
        end
    end
    return nil
end

function M.OnUnitCreated(uid, defID, builderID)
    if not S then return end
    for _, ses in ipairs(S.sessions) do
        if not ses.done then S.env.BP_PLACER.OnUnitCreated(ses.state, uid, defID, builderID) end
    end
end

function M.OnUnitFinished(uid, defID, x, z)
    if not S then return end
    S.slotLabNames = S.slotLabNames or { corlab = true, corvp = true, coralab = true, coravp = true, corgant = true }
    for _, ses in ipairs(S.sessions) do
        if not ses.done then S.env.BP_PLACER.OnUnitFinished(ses.state, uid, defID, x, z) end
    end
    local d = UnitDefs[defID]
    if not d or not x then return end
    if d.isFactory then
        local slot = SlotAt(x, z, d.name)
        if slot then
            local absorb = (d.metalCost or 0) / Cfg().ABSORB_SECONDS
            local L = { slot = slot, name = d.name, conMade = 0, absorb = 1 }
            -- what the lab can absorb: the share-weighted unit cost of the comp units it builds
            local opt = {}
            for _, o in ipairs(d.buildOptions or {}) do opt[o] = true end
            local sm, ss = 0, 0
            for _, u in ipairs(S.units) do if opt[u.defID] then sm, ss = sm + u.share * Metal(u.defID), ss + u.share end end
            if ss > 0 then absorb = sm / ss / Cfg().ABSORB_SECONDS end
            L.absorb = math.max(absorb, 1)
            S.labs[uid] = L
            slot.uid, slot.labName, slot.state = uid, d.name, "lab"
            Log("slot %d: %s stands", slot.id, d.name)
        elseif BlockAt(x, z) or S.slotLabNames[d.name] then
            Log("%s finished at (%d, %d) and matches no slot", d.name, x, z)
        end
    elseif d.isBuilder and (d.speed == nil or d.speed == 0) and not d.canFly then
        local b = BlockAt(x, z)
        if b then
            local item
            for _, it in ipairs(b.ses.state.queue) do
                if it.cls == "nano" and it.status == "built" and math.abs(x - it.wx) <= 24 and math.abs(z - it.wz) <= 24 then item = it; break end
            end
            S.nanos[uid] = { block = b.index, item = item }
        end
    end
end

function M.OnUnitFromFactory(uid, defID, factID)
    if not S or not S.labs[factID] then return end
    local d = UnitDefs[defID]
    if d and d.isBuilder and not d.isFactory and (d.speed or 0) > 0 and not d.canFly then
        if Cfg().BLOCK_CONS then
            for _, b in ipairs(S.blocks) do
                local t = b.conOrdered and b.conOrdered[d.name]
                if t and not (b.cons[d.name] and Alive(b.cons[d.name])) then
                    b.cons[d.name], b.conOrdered[d.name] = uid, nil
                    S.cons[uid] = "res"
                    Spring.GiveOrderToUnit(uid, 10, { b.ax, 0, b.az }, {})     -- CMD.MOVE to its block
                    Log("block %d: resident %s", b.index, d.name)
                    return
                end
            end
        end
        S.cons[uid] = true
        S.conOut = S.conOut + 1
        S.conPending[defID] = nil
        Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
        if S.env.DeferStop then S.env.DeferStop(uid) end
    end
end

-- A lab the host built itself (LINE_BOT's vehicle plant on the line): not in a slot, but it counts as standing, its
-- nanos come from the nearest block, it makes `cons` ground cons first, and its units follow the stance.
function M.AdoptLab(uid, defID, cons, conName)
    if not S then return false end
    local d = UnitDefs[defID or Spring.GetUnitDefID(uid) or -1]
    if not d then return false end
    local L = { slot = nil, name = d.name, conMade = 0, conWant = cons, conName = conName, absorb = 1, adopted = true }
    local opt = {}
    for _, o in ipairs(d.buildOptions or {}) do opt[o] = true end
    local sm, ss = 0, 0
    for _, u in ipairs(S.units) do if opt[u.defID] then sm, ss = sm + u.share * Metal(u.defID), ss + u.share end end
    L.absorb = ss > 0 and math.max(sm / ss / Cfg().ABSORB_SECONDS, 1) or 1
    S.labs[uid] = L
    if S.expect[d.name] and S.expect[d.name] > 0 then S.expect[d.name] = S.expect[d.name] - 1 end
    return true
end

-- (spine.lua's air cons offered to a cell: this spine uses the host's pool through env.TakeCon.)
-- AIR LABS: lab sessions that wait for an air con (the T2 air plant), so the host's con broker can hand the spine one (the "spine" job's want)
function M.AirConWant()
    if not S then return 0 end
    local n = 0
    for _, ses in ipairs(S.sessions) do
        if ses.kind == "lab" and not ses.done and #ses.state.builders == 0 then
            local it = ses.state.queue[1]
            if it and AirOnly(it.n) and it.status ~= "built" then n = n + 1 end
        end
    end
    return n
end
-- ...and an air con the broker offers: it goes to the first air-lab session that has none and that it can place.
function M.OfferCon(uid)
    if not S or not Alive(uid) then return false end
    local bd = Spring.GetUnitDefID(uid)
    local d = bd and UnitDefs[bd]
    if not (d and d.canFly) then return false end
    for _, ses in ipairs(S.sessions) do
        if ses.kind == "lab" and not ses.done and #ses.state.builders == 0 then
            local it = ses.state.queue[1]
            if it and AirOnly(it.n) and it.status ~= "built" and S.env.BP_PLACER.CanBuild(bd, it.defID) then
                S.env.BP_PLACER.AddBuilder(ses.state, uid)
                S.conWanted[it.defID] = nil
                Log("air con %d takes the %s job", uid, it.n)
                return true
            end
        end
    end
    return false
end

-- A ground con from the host's build order joins the idle cons.
function M.AdoptCon(uid)
    if not S or not uid or not Alive(uid) then return false end
    S.cons[uid] = true
    Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
    return true
end

function M.OnUnitDestroyed(uid, attackerID)
    if not S then return end
    -- REBUILD_NANOS: a nano the enemy killed (an attacker; our own reclaims have none) is queued to be built again
    local N = S.nanos[uid]
    if N and N.item and attackerID and Cfg().REBUILD_NANOS and not N.item.sacrificed then
        S.rebuild = S.rebuild or {}
        S.rebuild[#S.rebuild + 1] = { item = N.item, block = S.blocks[N.block], since = S.frame }
    end
    for _, ses in ipairs(S.sessions) do
        if not ses.done then S.env.BP_PLACER.OnUnitDestroyed(ses.state, uid) end
    end
    local L = S.labs[uid]
    if L and L.slot then
        local slot = L.slot
        if slot.state == "lab" or slot.state == "clear" then
            if slot.state == "lab" then slot.state, slot.labName = "free", nil end
            slot.uid, slot.surplusSince, slot.keep, slot.wantLab = nil, nil, nil, nil
            if slot.wide and slot.state == "free" then
                slot.wide = nil
                local p = Partner(slot)
                if p and p.owner == slot then p.state, p.owner = "free", nil end
            end
        end
    end
    S.labs[uid], S.nanos[uid], S.cons[uid] = nil, nil, nil
    if S.borrowed then S.borrowed[uid] = nil end
end

-- ── Lab hook ─────────────────────────────────────────────────────────────────

function M.IsLab(labID) return S ~= nil and S.labs[labID] ~= nil end
-- A T1 lab (also runs the lab controller's normal picks: scouts, defenders, rez bots) or the host's adopted plant.
function M.IsT1Lab(labID)
    local L = S and S.labs[labID]
    return L ~= nil and Cfg().T1_LABS[L.name] == true      -- (the host's adopted plant is a corvp; an adopted T2 lab is not a T1 lab)
end
function M.IsLeaving(labID) local L = S and S.labs[labID]; return L ~= nil and L.leaving == true end

-- A con this lab could make that a pending job is waiting for (nil if none).  The lab controller queues the rest of the
-- lab's units from the strategy's picks.
function M.NextOrder(labID, labDefID)
    local L = S and S.labs[labID]
    if not L or L.leaving then return nil end
    local ld = UnitDefs[labDefID]
    if not ld or not ld.buildOptions then return nil end
    -- keep making ground cons while there is something to place: blocks and lab slots wait on them
    local work = false
    for _, ses in ipairs(S.sessions) do if not ses.done then work = true; break end end
    if work then
        local alive = 0
        for uid, st in pairs(S.cons) do
            if not Alive(uid) then S.cons[uid] = nil elseif st ~= "res" and st ~= "resbusy" then alive = alive + 1 end
        end
        local target = math.min(Cfg().CONS_MAX, Cfg().CONS_MIN + math.floor(S.income / Cfg().CONS_PER_INCOME))
        if EarlyConCap() then target = math.min(target, Cfg().EARLY_CONS) end
        if alive + math.max(0, S.conOrders - S.conOut) < target and not ConCapReached() then
            -- the con that can place the most wanted job; else any ground con this lab makes
            local best
            for _, od in ipairs(BT.ConsMadeBy(ld)) do
                local score = 0
                for wanted in pairs(S.conWanted) do if BT.CanBuild(od.id, wanted) then score = score + 1 end end
                if not best or score > best.score then best = { id = od.id, score = score } end
            end
            if best then S.conOrders = S.conOrders + 1; return best.id end
        end
    end
    if L.conWant and L.conMade < L.conWant and not ConCapReached() then          -- the cons the host asked this lab for first
        local od = BT.ConMadeBy(ld, { name = L.conName })
        if od then
            L.conMade = L.conMade + 1
            if (Cfg().CON_CAP or 0) > 0 then S.conOrders = S.conOrders + 1 end
            return od.id
        end
    end
    for wanted in pairs(S.conWanted) do
        for _, od in ipairs(BT.ConsMadeBy(ld)) do
            if ConCapReached() then break end
            if EarlyConCap() and AliveGroundCons() + math.max(0, S.conOrders - S.conOut) >= Cfg().EARLY_CONS then break end
            if BT.CanBuild(od.id, wanted) and not S.conPending[od.id] then
                S.conPending[od.id] = S.frame
                return od.id
            end
        end
    end
    -- BLOCK_CONS: the blocks' resident cons are the lowest priority (they only make a swap quick); a job above waited for none of them
    local rid, rb, rrole = ResidentWanted(ld)
    if rid then rb.conOrdered[rrole] = S.frame; return rid end
    return nil
end

-- The spine's facing and block anchors (DRAGON_ECO places its Dragon lab in front of them): geo = { dx, dz, px, pz, ... }, blocks = { {x, z}, ... }
function M.Front()
    if not S or not S.geo then return nil end
    local out = {}
    for _, b in ipairs(S.blocks) do out[#out + 1] = { x = b.ax, z = b.az } end
    return S.geo, out
end

function M.Status()
    if not S then return nil end
    local labs = {}
    for _, slot in ipairs(S.slots) do labs[#labs + 1] = { id = slot.id, state = slot.state, lab = slot.labName } end
    return { blocks = #S.blocks, slots = labs, nanoAllowed = S.nanoAllowed, nanoNeed = S.nanoNeed,
             spare = S.spare, buildNeed = S.nanoBuildNeed,
             active = S.active, parked = S.parked, share = S.share, need = S.need, plan = S.plan,
             capacity = M.SpendCapacity() }
end

return M
