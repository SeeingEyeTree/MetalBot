-- tests/test_slot_spine.lua
-- bar_framework/slot_spine.lua against tests/spring_stub.lua with a FAKE placer (items are finished by hand, so each
-- step is judged on the decisions, not on pathing).  Run: python tests/run_lua.py tests/test_slot_spine.lua
--   * planner: the cheapest labs that cover the comp; a gated T2 lab waits for army value; counts grow with spend;
--   * a block opens with 16 nanos, 4 built at once, the rest released as the spend needs them (also at share 0:
--     build-ahead), and the next block opens only when the first is fully released;
--   * labs go into free slots, a con that can build them is taken from the pool, a con is asked for when none can;
--   * SWAP: when the comp changes and the slots are full, an unneeded lab is reclaimed (after RECLAIM_DELAY, and only
--     then) and the slot gets the lab the new comp needs; a leaving lab takes no orders;
--   * nanos guard the labs in reach and move to the NEW lab right after a swap.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W
W.units, W.features, W.orders, W.log, W.errors, W.widgets = {}, {}, {}, {}, {}, {}
W.frame, WG = 0, {}

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local SS = VFS.Include("LuaUI/Widgets/bar_framework/slot_spine.lua")
local SP = VFS.Include("LuaUI/Widgets/bar_framework/spine.lua")
local BLOCK = VFS.Include("LuaUI/Widgets/blueprints/general/NanoBlock.lua")
local function Id(n) return UnitDefNames[n].id end

-- ── fake placer ───────────────────────────────────────────────────────────────
local function Rot(x, z, r)
    if r == 0 then return x, z elseif r == 1 then return -z, x elseif r == 2 then return -x, -z end
    return z, -x
end
local sessions = {}
local P = {}
function P.NewDistributed(bp, ax, az, rot)
    local st = { queue = {}, builders = {}, done = false }
    for i, u in ipairs(bp.layout) do
        local d = UnitDefNames[u.n]
        local rx, rz = Rot(u.x, u.z, rot)
        st.queue[#st.queue + 1] = { n = u.n, defID = d.id, wx = ax + rx, wz = az + rz, f = u.f, idx = i,
            cls = (u.n == "cornanotc") and "nano" or (d.isFactory and "factory" or "other"),
            act = u.a or "build", status = "pending" }
    end
    sessions[#sessions + 1] = st
    return st
end
function P.CanBuild(bDef, defID)
    for _, o in ipairs(UnitDefs[bDef].buildOptions or {}) do if o == defID then return true end end
    return false
end
function P.AddBuilder(st, uid) st.builders[#st.builders + 1] = uid; return true end
function P.RemoveBuilder(st, uid) for i, b in ipairs(st.builders) do if b == uid then table.remove(st.builders, i) break end end end
function P.Update() end
function P.OnUnitCreated() end
function P.OnUnitFinished() end
function P.OnUnitDestroyed() end

-- finish one placer item: spawn the unit and tell the spine; mark the session done when nothing is left
local function Finish(st, it)
    it.status = "built"
    if it.act ~= "reclaim" then
        local id = S.Spawn(it.n, 0, it.wx, it.wz, { silent = true })
        SS.OnUnitFinished(id, it.defID, it.wx, it.wz)
        it.uid = id
    end
    local left = false
    for _, q in ipairs(st.queue) do if q.status ~= "built" and q.status ~= "skipped" then left = true end end
    if not left then st.done = true; if st.onComplete then st.onComplete() end end
end
local function FinishAllReleased(st)
    for _, it in ipairs(st.queue) do
        if it.status ~= "built" and it.waitsFor == nil and it.act ~= "reclaim" then Finish(st, it) end
    end
end

-- ── fake nano broker ──────────────────────────────────────────────────────────
local NANO = { PRIO = { SPINE = 2.5 } }
local assign = {}
function NANO.Guard(prio, n, lab) assign[n] = { prio = prio, mode = "guard", target = lab }; return true end
function NANO.Park(prio, n) assign[n] = { prio = prio, mode = "park" }; return true end
function NANO.Release(n) assign[n] = nil; return true end
function NANO.Assignment(n) return assign[n] end

-- ── env ───────────────────────────────────────────────────────────────────────
local pool = {}
local armyValue = 0
local env = {
    BP_PLACER = P, NANO = NANO, blueprint = BLOCK,
    baseX = W.start[0][1], baseZ = W.start[0][2], mapX = S.MAP, mapZ = S.MAP,
    AnchorKey = function(x, z) return math.floor(x) .. "," .. math.floor(z) end,
    Reserve = function() end,
    TakeCon = function(defID)
        for i, uid in ipairs(pool) do
            local d = Spring.GetUnitDefID(uid)
            if not defID or P.CanBuild(d, defID) then table.remove(pool, i); return uid end
        end
        return nil
    end,
    ReturnCon = function() end, DeferStop = function() end,
    ArmyValue = function() return armyValue end,
    Expect = {},        -- (the bot's own vehicle plant is not awaited in these scenarios)
}

-- ── planner (pure) ────────────────────────────────────────────────────────────
local mixed = { { defID = Id("corak"), share = 0.2 }, { defID = Id("corgator"), share = 0.3 },
                { defID = Id("corraid"), share = 0.2 }, { defID = Id("corbw"), share = 0.3 } }
local plan, tab = SS.Cover(mixed, {}, nil)
check(plan.corlab and plan.corvp and plan.corap and not plan.coralab, "the cover picks one lab per unit family")
local cnt = SS.Counts(mixed, plan, tab, 50)
local cntBig = SS.Counts(mixed, plan, tab, 400)
check(cnt.corvp >= 1 and cntBig.corvp > cnt.corvp, "more spend -> more labs of a type (" .. cnt.corvp .. " -> " .. cntBig.corvp .. ")")
local heavy = { { defID = Id("corsumo"), share = 1 } }
check(next((SS.Cover(heavy, {}, function(n) return n ~= "coralab" end))) == nil, "a gated T2 lab is not planned")
check((SS.Cover(heavy, {}, function() return true end)).coralab == 1, "an allowed T2 lab is planned")
check((SS.Cover(heavy, { coralab = 1 }, function() return false end)).coralab == 1, "a standing lab stays in the plan even when gated")

-- ── start, block, build-ahead ────────────────────────────────────────────────
SS.Init(env)
SS.Start(0)
local st = SS.State()
check(#st.blocks == 1 and #st.slots == 2, "start opens one block with two slots")
local q = st.blocks[1].ses.state.queue
local held = 0
for _, it in ipairs(q) do if it.waitsFor ~= nil then held = held + 1 end end
check(#q == 24 and held == 20, "16 nanos + 8 storages, 4 nanos built at once, 12 nanos + 8 storages held (" .. #q .. ", " .. held .. ")")

local vehicles = { { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } }
SS.SetUnits(vehicles)
SS.SetShare(0)
local conA = S.Spawn("corck", 0, st.blocks[1].ax - 300, st.blocks[1].az, { silent = true })
local conC = S.Spawn("corck", 0, st.blocks[1].ax - 320, st.blocks[1].az + 40, { silent = true })
SS.CFG.BUILDERS_PER_JOB = 1       -- the block takes one con, the lab job the other
SS.CFG.BUILD_AHEAD_INCOME = 0     -- these tests run at low income; the income gate has its own check below
pool = { conA, conC }
local frame, income = 0, 40
local function Tick(n, res)
    for _ = 1, n or 1 do frame = frame + 30; W.frame = frame; SS.Update(frame, res or { metalIncome = income }) end
end
Tick(3)
check(st.nanoNeed >= 2, "build-ahead: nanos are wanted for the income even at share 0 (need " .. st.nanoNeed .. ")")

-- ── a lab goes into a slot; a con is taken ───────────────────────────────────
local jobs = {}
for _, ses in ipairs(st.sessions) do if ses.kind == "lab" then jobs[#jobs + 1] = ses end end
check(#jobs == 1 and jobs[1].state.queue[1].n == "corvp", "the vehicle comp puts a vehicle plant in a slot")
check(#jobs[1].state.builders == 1 and jobs[1].state.builders[1] == conC, "a con that can build it is taken from the pool")
Finish(jobs[1].state, jobs[1].state.queue[1])
Tick(2)
local labSlot
for _, s in ipairs(st.slots) do if s.state == "lab" then labSlot = s end end
check(labSlot and labSlot.labName == "corvp", "the finished plant occupies its slot")
local vpUid = labSlot.uid
check(SS.IsLab(vpUid) and not SS.IsLeaving(vpUid), "it is a lab of the spine")

-- a con is requested when none can build the lab
local air = { { defID = Id("corbw"), share = 0.6 }, { defID = Id("corveng"), share = 0.4 } }
SS.SetUnits(air)
pool = {}
Tick(2)
local airJob
for _, ses in ipairs(st.sessions) do if ses.kind == "lab" and ses.state.queue[1].n == "corap" then airJob = ses end end
check(airJob ~= nil, "the bomber comp adds an air plant in the free slot (the vehicle plant stays: slots are not full)")
check(st.conWanted[Id("corap")], "no con can build it: one is wanted")
local cv = S.Spawn("corlab", 0, 100, 100, { silent = true })
SS.OnUnitFinished(cv, Id("corlab"), 100, 100)    -- (not in a slot: ignored)
check(not SS.IsLab(cv), "a lab outside any slot is not ours")
pool = { S.Spawn("corck", 0, 500, 500, { silent = true }) }
Tick(2)
check(#airJob.state.builders == 1, "a con is assigned once one exists")
Finish(airJob.state, airJob.state.queue[1])
Tick(2)

-- ── nanos guard the labs ──────────────────────────────────────────────────────
FinishAllReleased(st.blocks[1].ses.state)
for _, it in ipairs(st.blocks[1].ses.state.queue) do if it.status ~= "built" and it.waitsFor == nil then Finish(st.blocks[1].ses.state, it) end end
Tick(6)
local guards, byLab = 0, {}
for n, a in pairs(assign) do
    if a.mode == "guard" then guards = guards + 1; byLab[a.target] = (byLab[a.target] or 0) + 1 end
end
check(guards > 0 and next(byLab) ~= nil, "built nanos guard a lab (" .. guards .. ")")
local labsGuarded = 0
for _ in pairs(byLab) do labsGuarded = labsGuarded + 1 end
check(labsGuarded == 2, "both standing labs get nanos (" .. labsGuarded .. ")")

-- ── SWAP: slots full, the comp changes ────────────────────────────────────────
SS.SetUnits({ { defID = Id("corak"), share = 1 } })     -- infantry: only corlab builds it
Tick(3)
local hasClear = false
for _, ses in ipairs(st.sessions) do if ses.kind == "clear" then hasClear = true end end
check(not hasClear, "an unneeded lab is not reclaimed at once (RECLAIM_DELAY)")
local clear
for _ = 1, 60 do
    Tick(1)
    for _, ses in ipairs(st.sessions) do if ses.kind == "clear" then clear = ses end end
    if clear then break end
end
check(clear ~= nil and clear.state.queue[1].act == "reclaim", "after the delay a reclaim of one unneeded lab starts")
local leavingUid = clear.slot.uid
check(SS.IsLeaving(leavingUid), "the leaving lab is marked, so the lab controller queues nothing more in it")
local nClear = 0
for _, ses in ipairs(st.sessions) do if ses.kind == "clear" then nClear = nClear + 1 end end
check(nClear == 1, "one slot at a time is cleared")
Finish(clear.state, clear.state.queue[1])
W.units[leavingUid] = nil
Tick(3)
local newJob
for _, ses in ipairs(st.sessions) do if ses.kind == "lab" and ses.state.queue[1].n == "corlab" then newJob = ses end end
check(newJob ~= nil, "the freed slot gets the lab the new comp needs")
local conB = S.Spawn("corck", 0, 520, 520, { silent = true })
pool = { conB }
Tick(2)
if newJob then
    Finish(newJob.state, newJob.state.queue[1])
    Tick(8)
    local newLab
    for _, s in ipairs(st.slots) do if s.state == "lab" and s.labName == "corlab" then newLab = s.uid end end
    check(newLab ~= nil, "the new lab stands in the swapped slot")
    local onNew = 0
    for n, a in pairs(assign) do if a.mode == "guard" and a.target == newLab then onNew = onNew + 1 end end
    check(onNew > 0, "nanos moved to the new lab within a few ticks (" .. onNew .. ")")
end

-- ── a gated T2 lab waits for army value ──────────────────────────────────────
SS.SetUnits({ { defID = Id("corsumo"), share = 1 } })
armyValue = 0
local before = 0
for _, ses in ipairs(st.sessions) do if ses.state.queue[1].n == "coralab" then before = before + 1 end end
Tick(40)
local after = 0
for _, ses in ipairs(st.sessions) do if ses.state.queue[1].n == "coralab" then after = after + 1 end end
check(after == 0, "a T2 lab is not placed while the army is worth less than its cost")
armyValue = 5000
Tick(40)
local clearing = false
for _, ses in ipairs(st.sessions) do if ses.kind == "clear" then clearing = true end end
check(st.plan.coralab ~= nil and clearing, "...and is planned once it is (a lab nobody needs makes way for it)")

-- ── a second block opens only when the first is fully released ───────────────
SS.SetUnits(vehicles)
income = 400
Tick(2)
local relNow = 0
for _, it in ipairs(st.blocks[1].ses.state.queue) do if it.waitsFor == nil then relNow = relNow + 1 end end
check(relNow > 4 and #st.blocks == 1, "a higher income releases more of the block's nanos (" .. relNow .. ")")
for _ = 1, 40 do
    FinishAllReleased(st.blocks[1].ses.state)
    Tick(1, { metalIncome = 1500 })
end
check(#st.blocks >= 2, "a high income opens the next block (" .. #st.blocks .. ")")

-- ── the host's own lab (the line's vehicle plant) and a T2 lab that needs a con source ───────────────────────────
SS.Init(env)
SS.Start(0)
st = SS.State()
income = 40
table.insert(UnitDefs[Id("corck")].buildOptions, Id("coralab"))    -- the stub's T1 bot con cannot place a T2 lab; the real one can
local vp = S.Spawn("corvp", 0, 900, 900, { silent = true })
check(SS.AdoptLab(vp, Id("corvp"), 1) and SS.IsLab(vp) and SS.IsT1Lab(vp), "an adopted plant is a T1 spine lab")
check(SS.NextOrder(vp, Id("corvp")) == Id("corcv") or UnitDefs[SS.NextOrder(vp, Id("corvp")) or 0] == nil,
      "the adopted plant first makes the con the host asked for")
SS.SetUnits({ { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } })
SS.SetShare(0.3)
pool = {}
frame = 0
Tick(3)
local extraVp = 0
for _, ses in ipairs(st.sessions) do if ses.kind == "lab" and ses.state.queue[1].n == "corvp" then extraVp = extraVp + 1 end end
check(extraVp == 0, "the adopted plant counts as standing: no second plant at a spend one plant absorbs")
SS.SetUnits({ { defID = Id("corsumo"), share = 1 } })
armyValue = 5000
Tick(3)
local plan2 = {}
local d = SS.State().plan
check(d.coralab ~= nil and d.corlab == 0, "a T2 bot lab with no con source pulls in the T1 lab that makes the con (plan " ..
      tostring(d.coralab) .. "/" .. tostring(d.corlab) .. ")")

-- the enabler is placed first; the lab nothing can place yet waits
local sawLab, sawCoralab = false, false
for _, ses in ipairs(SS.State().sessions) do
    if ses.kind == "lab" and ses.state.queue[1].n == "corlab" then sawLab = true end
    if ses.kind == "lab" and ses.state.queue[1].n == "coralab" then sawCoralab = true end
end
check(sawLab and not sawCoralab, "the T1 bot lab (the con source) is placed before the T2 lab that needs its con")

-- the host's own plant is awaited, not duplicated in a slot, in the first minutes
env.Expect = { corvp = 1 }
SS.Init(env)
SS.Start(0)
SS.SetUnits({ { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } })
SS.SetShare(0.3)
income = 40
frame = 0
Tick(3)
local dup = 0
for _, ses in ipairs(SS.State().sessions) do if ses.kind == "lab" and ses.state.queue[1].n == "corvp" then dup = dup + 1 end end
check(dup == 0, "a plant the host is about to adopt is not built a second time in a slot")
env.Expect = {}

-- ── slack: two spare blocks, fully built, from SLACK_INCOME ──────────────────────────────────────────────────────────
local function Blocks()
    local b, spareBuilt = SS.State().blocks, 0
    for _, blk in ipairs(b) do
        local free, built = true, 0
        for _, s in ipairs(blk.slotsIdx) do if s.state ~= "free" then free = false end end
        for _, it in ipairs(blk.ses.state.queue) do if it.cls == "nano" and it.status == "built" then built = built + 1 end end
        if free and built == 16 then spareBuilt = spareBuilt + 1 end
    end
    return #b, spareBuilt
end
local function Run(inc, ticks)
    for _ = 1, ticks do
        for _, blk in ipairs(SS.State().blocks) do FinishAllReleased(blk.ses.state) end
        Tick(1, { metalIncome = inc })
    end
end
env.Expect = {}
SS.Init(env)
SS.Start(0)
SS.SetUnits({ { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } })
SS.SetShare(0)
pool = {}
frame = 0
Run(300, 80)
local nb, spare = Blocks()
check(nb == 1 and spare == 0, "below SLACK_INCOME no spare blocks are built (" .. nb .. " blocks, " .. spare .. " spare)")
Run(600, 200)
nb, spare = Blocks()
check(spare >= SS.CFG.SLACK_BLOCKS and SS.State().spare >= SS.CFG.SLACK_BLOCKS,
      "from SLACK_INCOME two spare blocks stand fully built (" .. nb .. " blocks, " .. spare .. " spare)")
check(SS.State().nanoNeed < SS.State().nanoBuildNeed, "slack nanos are built but not counted as needed for guarding")
-- an empty bank holds the slack back: production keeps the metal
local blocksBefore = #SS.State().blocks
SS.Init(env); SS.Start(0)
SS.SetUnits({ { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } }); SS.SetShare(0)
frame = 0
for _ = 1, 200 do
    for _, blk in ipairs(SS.State().blocks) do FinishAllReleased(blk.ses.state) end
    Tick(1, { metalIncome = 600, metal = 100, metalStorage = 10000 })
end
nb, spare = Blocks()
check(SS.State().nanoBuildNeed == SS.State().nanoNeed, "with a near-empty metal bank the slack is not built (build " .. SS.State().nanoBuildNeed .. " need " .. SS.State().nanoNeed .. ")")
SS.Init(env); SS.Start(0)
SS.SetUnits({ { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } }); SS.SetShare(0)
Run(600, 200)
-- a lab goes into a spare block: a replacement opens
local before = #SS.State().blocks
local slot = SS.State().blocks[1].slotsIdx[1]
slot.state, slot.labName = "lab", "corvp"
Run(600, 200)
nb, spare = Blocks()
check(nb >= before and spare >= SS.CFG.SLACK_BLOCKS and SS.State().spare >= SS.CFG.SLACK_BLOCKS,
      "with a slot in use two blocks are still spare (" .. nb .. " blocks, " .. spare .. " spare)")
local nbSlack = nb
-- off
slot.state, slot.labName = "free", nil
SS.CFG.SLACK_BLOCKS = 0
SS.Init(env)
SS.Start(0)
SS.SetUnits({ { defID = Id("corgator"), share = 1 } })
SS.SetShare(0)
frame = 0
Run(600, 120)
check(#SS.State().blocks < nbSlack, "SLACK_BLOCKS = 0 builds only what the spend needs (" .. #SS.State().blocks .. " < " .. nbSlack .. " blocks)")
SS.CFG.SLACK_BLOCKS = 2

-- free run: banking both metal and energy -> every nano is released, none guarded or parked
SS.CFG.SLACK_BLOCKS = 2
SS.Init(env); SS.Start(0)
SS.SetUnits({ { defID = Id("corgator"), share = 0.5 }, { defID = Id("corraid"), share = 0.5 } }); SS.SetShare(0.2)
pool = {}
frame = 0
for k in pairs(assign) do assign[k] = nil end
for _ = 1, 120 do
    for _, blk in ipairs(SS.State().blocks) do FinishAllReleased(blk.ses.state) end
    Tick(1, { metalIncome = 600, metal = 2000, metalStorage = 10000, energy = 2000, energyStorage = 10000 })
end
local ctl = 0
for _ in pairs(assign) do ctl = ctl + 1 end
check(ctl > 0, "normal bank: nanos are controlled (" .. ctl .. ")")
for _ = 1, 10 do Tick(1, { metalIncome = 600, metal = 9000, metalStorage = 10000, energy = 9000, energyStorage = 10000 }) end
ctl = 0
for _ in pairs(assign) do ctl = ctl + 1 end
check(ctl == 0 and SS.State().freeRun, "metal and energy both banking: no nano is guarded or parked (" .. ctl .. ")")
for _ = 1, 10 do Tick(1, { metalIncome = 600, metal = 9000, metalStorage = 10000, energy = 500, energyStorage = 10000 }) end
check(not SS.State().freeRun, "energy short again: controls resume")

-- build-ahead is gated by income: below BUILD_AHEAD_INCOME nanos follow the army share only
SS.SetShare(0)
SS.CFG.BUILD_AHEAD_INCOME = 500
for _ = 1, 60 do Tick(1, { metalIncome = 100 }) end
check(SS.State().nanoNeed == 0, "income gate: 100 m/s at share 0 wants no nanos (" .. SS.State().nanoNeed .. ")")
for _ = 1, 80 do Tick(1, { metalIncome = 800 }) end
check(SS.State().nanoNeed >= 2, "income gate: 800 m/s sizes nanos for the income (" .. SS.State().nanoNeed .. ")")

-- energy storage: 16k/s of energy income with 6.5k of storage wants ~5 s of buffer; the held storages are released a few at a time
SS.CFG.STORE_SECONDS = 5
local function StoreHeld()
    local n = 0
    for _, blk in ipairs(SS.State().blocks) do n = n + #blk.heldStore end
    return n
end
SS.State().mexReady = true
local held0 = StoreHeld()
for _ = 1, 4 do Tick(1, { metalIncome = 800, metal = 3000, metalStorage = 10000, energy = 3000, energyStorage = 6500, energyIncome = 16000 }) end
check(SS.State().storeNeed == 13, "storage: 5 s of 16k/s over 6.5k stored wants 13 corestors (" .. tostring(SS.State().storeNeed) .. ")")
check(StoreHeld() < held0 and held0 - StoreHeld() <= SS.CFG.STORE_INFLIGHT, "storage: some released, within the in-flight limit (" .. held0 .. " -> " .. StoreHeld() .. ")")
held0 = StoreHeld()
for _ = 1, 4 do Tick(1, { metalIncome = 800, metal = 100, metalStorage = 10000, energy = 3000, energyStorage = 6500, energyIncome = 16000 }) end
check(StoreHeld() == held0, "storage: none released while the metal bank is empty")

-- shared storage rows: no two blocks hold a storage at the same spot
do
    local seen, dup, total = {}, 0, 0
    for _, blk in ipairs(SS.State().blocks) do
        for _, it in ipairs(blk.ses.state.queue) do
            if it.n == "corestor" then
                total = total + 1
                local key = math.floor(it.wx / 16 + 0.5) .. "," .. math.floor(it.wz / 16 + 0.5)
                if seen[key] then dup = dup + 1 end
                seen[key] = true
            end
        end
    end
    check(dup == 0 and total > 0, "storage rows are shared between blocks (" .. total .. " storages, " .. dup .. " duplicated)")
end

check(#W.errors == 0, "no Lua errors")
print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
