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

local M = {}

M.CFG = {
    BLOCK_PITCH     = 240,    -- elmos between blocks along the stack axis
    FRONT           = 480,    -- elmos from the base to the first block anchor (same as spine's first cell)
    MAX_BLOCKS      = 9,
    STACK_HALF      = 4,
    UPDATE_EVERY    = 30,
    LAB_CANDIDATES  = { "corlab", "corvp", "corap", "coralab", "coravp", "corgant" },   -- labs the planner may use (no T2 air)
    WIDE_ELMOS      = 160,    -- a lab wider than this takes BOTH slots of a block (the gantry), centred between them
    WIDE_X          = 72,     -- where a wide lab's centre sits in front of the block
    COVER_FRAC      = 0.95,   -- stop adding labs once this share of the comp can be built
    MIN_UNIT_SHARE  = 0.02,   -- units under this share do not justify a lab of their own
    ABSORB_SECONDS  = 2.5,    -- a lab takes at most buildTime/this BP, i.e. absorbs metalCost/this metal per second
    LAB_UTIL        = 0.8,    -- fraction of that a lab really sustains
    CORE_NANOS      = 4,      -- nanos built when a block opens; the rest are released as the spend needs them
    NANO_HEADROOM   = 1.15,   -- nano capacity kept over what the spend absorbs
    BUILD_AHEAD     = 1.0,    -- nanos are sized for this share of income whatever the army share (1 = all of it)
    NANO_BATCH      = 6,      -- nanos released per tick
    NANO_INFLIGHT   = 12,     -- released nanos that may be unfinished at once
    MOVES_MAX       = 6,      -- nano assignment changes per tick
    PARK_NANOS      = true,
    BUILDERS_PER_JOB = 2,     -- cons on a job (a block or a lab slot)
    MAX_JOBS        = 3,      -- lab slot jobs (build or clear) at once
    RECLAIM_DELAY   = 900,    -- frames a lab must have been unneeded before it may be reclaimed
    GATE_COST       = 1000,   -- labs this expensive wait for army value (below)
    GATE_MARGIN     = 1.0,    -- ground army value must reach margin x lab cost (env.ArmyValue); floating overrides
    LOG_EVERY       = 1800,
    CON_ORDER_TTL   = 1800,
    CONS_MIN        = 3,      -- ground cons our labs keep making while a block or lab slot has work ...
    CONS_PER_INCOME = 150,    -- ... plus one per this much metal income, up to CONS_MAX
    CONS_MAX        = 8,
    EXPECT_UNTIL    = 10800,  -- frames (6:00): the host's own lab (S.expect) is awaited, not duplicated in a slot, until then
    BLOCK_OPEN_FRAC = 0.75,   -- the next block opens once this share of the released nanos stand
    SLACK_BLOCKS    = 2,      -- spare blocks (all nanos standing, both slots free) kept ready for a transition; 0 = off
    SLACK_INCOME    = 500,    -- ... once metal income reaches this (and the mex grids are ready)
    NANOS_PER_BLOCK = 16,
    QUEUE_DEPTH     = 3,      -- units kept queued in each lab (lab_controller)
    T1_LABS         = { corlab = true, corvp = true, corap = true },   -- labs the lab controller also runs the normal picks on
}

-- The macro loads blueprints by this table (as it does for spine.lua).
M.BLUEPRINT = { T1 = "NanoBlock" }

local S = nil
local CMD_STOP = 0

local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function Cfg() return M.CFG end
local function Log(fmtStr, ...)
    local f = S and S.frame or 0
    local sec = math.floor(f / 30)
    Spring.Echo(string.format("[SLOT] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
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
            local opt = {}
            for _, o in ipairs(ld.buildOptions) do opt[o] = true end
            local list = {}
            for _, u in ipairs(units) do if opt[u.defID] then list[#list + 1] = u end end
            if #list > 0 then out[name] = { name = name, defID = ld.id, cost = ld.metalCost or 0, units = list } end
        end
    end
    return out
end

-- Greedy cover: the lab that covers the most uncovered comp share per metal (a standing lab costs nothing) is taken
-- first.  `standing` = { [labName] = count }; `allowed(name)` gates expensive labs.  Returns { [labName] = share covered }.
function M.Cover(units, standing, allowed)
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
                    local cost = (standing and (standing[name] or 0) > 0) and 1 or math.max(1, L.cost)
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

local function TakeOwnCon(defID)
    for uid, state in pairs(S.cons) do
        local bd = Spring.GetUnitDefID(uid)
        if not bd then S.cons[uid] = nil
        elseif state == true and (not defID or S.env.BP_PLACER.CanBuild(bd, defID)) then
            S.cons[uid] = "busy"
            return uid
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
            elseif S.cons[uid] then S.cons[uid] = true; Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {}) end
        end
    end
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
            local uid = TakeOwnCon(defID) or (not env.GroundOnly and env.TakeCon(defID, false)) or nil
            if uid then env.BP_PLACER.AddBuilder(st, uid) else S.conWanted[defID] = true end
        end
    end
    if reclaim and #st.builders == 0 then
        local uid = TakeOwnCon(nil) or (not env.GroundOnly and env.TakeCon(nil, true)) or nil
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
    local block = { index = #S.blocks + 1, ax = ax, az = az, ses = ses, held = {}, slotsIdx = {} }
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

local function ReleaseHeld(block, k)
    local n = 0
    while n < k and #block.held > 0 do
        local it = table.remove(block.held, 1)
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
    local ahead = ready and K.BUILD_AHEAD or 0
    local nanoShare = math.max(S.share, S.nanoFloor, ahead)
    local need = math.ceil(K.NANO_HEADROOM * nanoShare * S.income / math.max(S.nanoRate, 1e-6) - 1e-9)
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
    S.spare = SpareBlocks()
    if K.SLACK_BLOCKS > 0 and ready and S.income >= K.SLACK_INCOME then
        buildNeed = math.max(need, (#S.blocks - S.spare + K.SLACK_BLOCKS) * K.NANOS_PER_BLOCK)
    end
    S.nanoBuildNeed = buildNeed
    if allowed >= buildNeed then return end
    local k = math.min(K.NANO_BATCH, buildNeed - allowed, K.NANO_INFLIGHT - inflight)
    for _, b in ipairs(S.blocks) do
        if k <= 0 then break end
        k = k - ReleaseHeld(b, k)
    end
    -- every block fully released and still short: open the next (one at a time)
    if k > 0 and S.started then
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
    return d ~= nil and math.max(d.xsize or 0, d.zsize or d.ysize or 0) * 8 > Cfg().WIDE_ELMOS
end

-- The other slot of a slot's block (a block has two).
local function Partner(slot)
    for _, o in ipairs(slot.block.slotsIdx) do if o ~= slot then return o end end
    return nil
end

-- A free slot; for a wide lab, a block whose slots are BOTH free.
local function FreeSlot(wide)
    for _, s in ipairs(S.slots) do
        if s.state == "free" then
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

local function StartClear(slot)
    local cx, cz = slot.x, slot.z
    if slot.wide then cx, cz = Cfg().WIDE_X, 0 end
    local ses = NewSession("clear", { { n = slot.labName, x = cx, z = cz, f = 1, a = "reclaim" } },
                           slot.block.ax, slot.block.az, { slot = slot })
    local was = slot.labName
    slot.state, slot.ses = "clear", ses
    if slot.uid then
        local L = S.labs[slot.uid]
        if L then L.leaving = true end
        Spring.GiveOrderToUnit(slot.uid, CMD_STOP, {}, {})
    end
    Log("slot %d: clearing %s", slot.id, tostring(was))
end

-- Can anything we have make a con that can place this lab?  A con already standing, or a standing lab that builds one.
local function HasConSource(labName)
    local target = UnitDefNames[labName]
    if not target then return true end
    for uid, state in pairs(S.cons) do
        local bd = Spring.GetUnitDefID(uid)
        if bd and S.env.BP_PLACER.CanBuild(bd, target.id) then return true end
    end
    for uid in pairs(S.labs) do
        local ld = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        for _, o in ipairs(ld and ld.buildOptions or {}) do
            local od = UnitDefs[o]
            if od and od.isBuilder and not od.isFactory and (od.speed or 0) > 0 and not od.canFly
               and S.env.BP_PLACER.CanBuild(o, target.id) then return true end
        end
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
            local best
            for _, cand in ipairs(K.LAB_CANDIDATES) do
                local cd = UnitDefNames[cand]
                if cd and cd.buildOptions and not plan[cand] and (cd.metalCost or 0) < (d.metalCost or 0) then
                    for _, o in ipairs(cd.buildOptions) do
                        local od = UnitDefs[o]
                        if od and od.isBuilder and not od.isFactory and (od.speed or 0) > 0 and not od.canFly
                           and S.env.BP_PLACER.CanBuild(o, d.id) then
                            if not best or (cd.metalCost or 0) < (UnitDefNames[best].metalCost or 0) then best = cand end
                            break
                        end
                    end
                end
            end
            if best then plan[best] = 0 end
        end
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
    local plan, tab = M.Cover(S.units, standing, LabAllowed)
    if next(plan) then
        M.Enablers(plan, HasConSource)
        for name in pairs(plan) do
            if not tab[name] then
                local d = UnitDefNames[name]
                tab[name] = { name = name, defID = d.id, cost = d.metalCost or 0, units = {} }
            end
        end
    end
    local ahead = ((not S.env.MexGridsReady) or S.mexReady) and K.BUILD_AHEAD or 0
    local spend = S.income * math.max(S.share, S.nanoFloor, ahead)
    local need = M.Counts(S.units, plan, tab, spend)
    -- slots are limited: keep the labs with the most comp share first when there are more wanted than places
    local order = {}
    for name in pairs(need) do order[#order + 1] = name end
    table.sort(order, function(a, b) if plan[a] ~= plan[b] then return plan[a] > plan[b] end return a < b end)
    local room = #S.slots
    for _, name in ipairs(order) do
        local c = math.min(need[name], math.max(1, room - (#order - 1)))
        need[name] = c
        room = room - c
    end
    S.plan, S.need = plan, need

    -- mark surplus: a standing lab beyond need (or not in the plan at all) has been unneeded since...
    local seen = {}
    for _, slot in ipairs(S.slots) do
        if slot.state == "lab" then
            seen[slot.labName] = (seen[slot.labName] or 0) + 1
            local surplus = seen[slot.labName] > (need[slot.labName] or 0)
            if surplus then slot.surplusSince = slot.surplusSince or S.frame else slot.surplusSince = nil end
        end
    end

    -- missing labs go into free slots; if there is none, a surplus lab that has stood unneeded long enough goes
    for _, name in ipairs(order) do
        local missing = need[name] - (have[name] or 0) - (building[name] or 0)
        -- a lab nothing can place yet waits for its enabler (the T1 lab that makes the con): never park a slot on it
        local d0 = UnitDefNames[name]
        if missing > 0 and d0 and (d0.metalCost or 0) >= K.GATE_COST and not HasConSource(name) then missing = 0 end
        while missing > 0 and JobCount() < K.MAX_JOBS do
            local slot = FreeSlot(IsWide(name))
            if not slot then
                local victim
                for _, s in ipairs(S.slots) do
                    if s.state == "lab" and s.surplusSince and S.frame - s.surplusSince >= K.RECLAIM_DELAY
                       and (not victim or s.surplusSince < victim.surplusSince) then victim = s end
                end
                if victim then StartClear(victim) end
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
    local labs = NanoLabs()
    local activeWant = math.min(#list, math.max(0, S.nanoNeed))
    if S.floating then activeWant = #list end
    local nd = NanoDef()
    local reachBase = nd and nd.buildDistance or 128
    local moves = 0
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
            if a and a.prio < NANO.PRIO.SPINE then
                -- a hand-off or reclaim owns it right now
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
                if best and n.guard ~= best.uid then
                    NANO.Release(uid)
                    if NANO.Guard(NANO.PRIO.SPINE, uid, best.uid) then
                        for _, l in ipairs(labs) do if l.uid == n.guard then l.n = l.n - 1 end end
                        n.guard, n.parked = best.uid, nil
                        best.n = best.n + 1
                        moves = moves + 1
                    end
                elseif not best and not n.parked and K.PARK_NANOS then
                    NANO.Release(uid)
                    if NANO.Park(NANO.PRIO.SPINE, uid) then n.parked, n.guard = true, nil; moves = moves + 1 end
                end
            elseif K.PARK_NANOS and not n.parked then
                for _, l in ipairs(labs) do if l.uid == n.guard then l.n = l.n - 1 end end
                NANO.Release(uid)
                if NANO.Park(NANO.PRIO.SPINE, uid) then n.parked, n.guard = true, nil; moves = moves + 1 end
            end
        end
    end
    S.active = 0
    for _, uid in ipairs(list) do if S.nanos[uid] and S.nanos[uid].guard then S.active = S.active + 1 end end
    S.parked = #list - S.active
end

-- ── Start / Update ───────────────────────────────────────────────────────────

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
    S.floating = (S.env.Floating and S.env.Floating()) or false
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
                slot.state, slot.uid, slot.labName, slot.ses, slot.surplusSince = "free", nil, nil, nil, nil
                if slot.wide then
                    slot.wide = nil
                    local p = Partner(slot)
                    if p and p.owner == slot then p.state, p.owner = "free", nil end
                end
                Log("slot %d: free", slot.id)
            elseif ses.kind == "lab" and slot and slot.state == "build" then
                slot.state = slot.uid and "lab" or slot.state
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
    local pending = {}
    for _, ses in ipairs(S.sessions) do for d in pairs((PendingDefs(ses.state))) do pending[d] = true end end
    for d in pairs(S.conWanted) do if not pending[d] then S.conWanted[d] = nil end end
    for d, t in pairs(S.conPending) do if frame - t > Cfg().CON_ORDER_TTL then S.conPending[d] = nil end end
    -- labs on their way out take no more orders
    for _, slot in ipairs(S.slots) do
        if slot.state == "clear" and slot.uid and Alive(slot.uid) then Spring.GiveOrderToUnit(slot.uid, CMD_STOP, {}, {}) end
    end

    ThrottleNanos()
    PlanLabs()
    UpdateNanos()

    if frame - S.lastLog >= Cfg().LOG_EVERY then
        S.lastLog = frame
        local labs = {}
        for _, slot in ipairs(S.slots) do
            labs[#labs + 1] = string.format("%d:%s%s", slot.id, slot.state, slot.labName and ("/" .. slot.labName) or "")
        end
        Log("blocks %d (spare %d), nanos allowed %d need %d build %d (active %d parked %d), income %.0f share %.2f; slots %s",
            #S.blocks, S.spare or 0, S.nanoAllowed, S.nanoNeed, S.nanoBuildNeed or S.nanoNeed, S.active or 0, S.parked or 0,
            S.income, S.share, table.concat(labs, " "))
    end
end

-- ── Unit callbacks ───────────────────────────────────────────────────────────

local function SlotAt(x, z, name)
    local best, bd
    for _, s in ipairs(S.slots) do
        local d = Dist2(x, z, s.wx, s.wz)
        local reach = (name and IsWide(name) and s.state == "build" and s.labName == name) and 200 or 70
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
        end
    elseif d.isBuilder and (d.speed == nil or d.speed == 0) and not d.canFly then
        local b = BlockAt(x, z)
        if b then S.nanos[uid] = { block = b.index } end
    end
end

function M.OnUnitFromFactory(uid, defID, factID)
    if not S or not S.labs[factID] then return end
    local d = UnitDefs[defID]
    if d and d.isBuilder and not d.isFactory and (d.speed or 0) > 0 and not d.canFly then
        S.cons[uid] = true
        S.conOut = S.conOut + 1
        S.conPending[defID] = nil
        Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
        if S.env.DeferStop then S.env.DeferStop(uid) end
    end
end

-- A lab the host built itself (LINE_BOT's vehicle plant on the line): not in a slot, but it counts as standing, its
-- nanos come from the nearest block, it makes `cons` ground cons first, and its units follow the stance.
function M.AdoptLab(uid, defID, cons)
    if not S then return false end
    local d = UnitDefs[defID or Spring.GetUnitDefID(uid) or -1]
    if not d then return false end
    local L = { slot = nil, name = d.name, conMade = 0, conWant = cons, absorb = 1, adopted = true }
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
function M.OfferCon(uid) return false end

-- A ground con from the host's build order joins the idle cons.
function M.AdoptCon(uid)
    if not S or not uid or not Alive(uid) then return false end
    S.cons[uid] = true
    Spring.GiveOrderToUnit(uid, CMD_STOP, {}, {})
    return true
end

function M.OnUnitDestroyed(uid)
    if not S then return end
    for _, ses in ipairs(S.sessions) do
        if not ses.done then S.env.BP_PLACER.OnUnitDestroyed(ses.state, uid) end
    end
    local L = S.labs[uid]
    if L and L.slot then
        local slot = L.slot
        if slot.state == "lab" or slot.state == "clear" then
            if slot.state == "lab" then slot.state, slot.labName = "free", nil end
            slot.uid, slot.surplusSince = nil, nil
            if slot.wide and slot.state == "free" then
                slot.wide = nil
                local p = Partner(slot)
                if p and p.owner == slot then p.state, p.owner = "free", nil end
            end
        end
    end
    S.labs[uid], S.nanos[uid], S.cons[uid] = nil, nil, nil
end

-- ── Lab hook ─────────────────────────────────────────────────────────────────

function M.IsLab(labID) return S ~= nil and S.labs[labID] ~= nil end
-- A T1 lab (also runs the lab controller's normal picks: scouts, defenders, rez bots) or the host's adopted plant.
function M.IsT1Lab(labID)
    local L = S and S.labs[labID]
    return L ~= nil and (L.adopted == true or Cfg().T1_LABS[L.name] == true)
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
        for uid in pairs(S.cons) do if Alive(uid) then alive = alive + 1 else S.cons[uid] = nil end end
        local target = math.min(Cfg().CONS_MAX, Cfg().CONS_MIN + math.floor(S.income / Cfg().CONS_PER_INCOME))
        if alive + math.max(0, S.conOrders - S.conOut) < target then
            -- the con that can place the most wanted job; else any ground con this lab makes
            local best
            for _, optID in ipairs(ld.buildOptions) do
                local od = UnitDefs[optID]
                if od and od.isBuilder and not od.isFactory and (od.speed or 0) > 0 and not od.canFly then
                    local score = 0
                    for wanted in pairs(S.conWanted) do if S.env.BP_PLACER.CanBuild(optID, wanted) then score = score + 1 end end
                    if not best or score > best.score then best = { id = optID, score = score } end
                end
            end
            if best then S.conOrders = S.conOrders + 1; return best.id end
        end
    end
    if L.conWant and L.conMade < L.conWant then          -- the cons the host asked this lab for first
        for _, optID in ipairs(ld.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.isBuilder and not od.isFactory and (od.speed or 0) > 0 and not od.canFly then
                L.conMade = L.conMade + 1
                return optID
            end
        end
    end
    for wanted in pairs(S.conWanted) do
        for _, optID in ipairs(ld.buildOptions) do
            local od = UnitDefs[optID]
            if od and od.isBuilder and not od.isFactory and (od.speed or 0) > 0 and not od.canFly
               and S.env.BP_PLACER.CanBuild(optID, wanted) and not S.conPending[optID] then
                S.conPending[optID] = S.frame
                return optID
            end
        end
    end
    return nil
end

function M.Status()
    if not S then return nil end
    local labs = {}
    for _, slot in ipairs(S.slots) do labs[#labs + 1] = { id = slot.id, state = slot.state, lab = slot.labName } end
    return { blocks = #S.blocks, slots = labs, nanoAllowed = S.nanoAllowed, nanoNeed = S.nanoNeed,
             spare = S.spare, buildNeed = S.nanoBuildNeed,
             active = S.active, parked = S.parked, share = S.share, need = S.need, plan = S.plan }
end

return M
