-- bar_framework/con_broker.lua  (air constructors: one owner per con, jobs ask for cons, a reserve is kept)
--
-- Every air con (T1 or T2) the bot owns is registered here; a con is FREE or owned by exactly one JOB.  A job is a registered
-- task that says how many cons it wants right now, what to do with a con it is given, and (optionally) the build sessions
-- (blueprint_placer states) it runs.  The broker hands free cons to the jobs, highest priority first (nearest con when the job
-- has a place, else the oldest), takes cons back from lower-priority *preemptable* jobs (helpers) when a higher job has no free
-- con, keeps a HOLD (free cons only jobs flagged `useReserve` may take) and a RESERVE (cons the labs keep ready), updates each job's sessions and frees the builder
-- when a session ends, and works out how many cons the labs still have to make (`Shortfall`, `produce` hooks).
--
-- Adding a job (T2 cons that rebuild a lost silo, as an example) is one registration:
--
--     CB.AddJob(cb, { name = "resilo", prio = 85, tier = "t2", useReserve = true,
--         sessions = T.resiloJobs,                                    -- optional: live list of placer states this job runs
--         want  = function(frame, res) return T.siloLost and 1 or 0 end,   -- cons wanted now (re-asked after every hand-out)
--         start = function(conID, frame, res)                         -- a con was assigned: begin (return the session, true or false)
--             return T.BP.New(siloBP, conID, x, z, 0, {})
--         end,
--         produce = function(frame, res) MakeT2Con(T, frame, "SILO") end })   -- optional: want > 0 and no con could be given
--
-- Everything else (dedup, tiers, STOP on hand-out, freeing the builder on `st.done`, dead cons, the [CB] log) is the broker's.
--
-- Job fields (all optional but name / prio / want / start):
--   kind         "air" (default: the jobs written for air cons) | "ground" | "any": which constructors the job may use,
--   defs         { corca = true, ... } unit names the job accepts (any kind / tier); lets a job ask for one type (a proxy-defence
--                job that only wants Twitchers, a ground con that pre-builds a blueprint), with its own production hook,
--   name, prio (number, or function(cb) -> number), tier "t1" | "t2" | "any" (any: T1 first),
--   section      which system the job belongs to: "grid" | "energy" | "crew" | "line" | "spine" | "dragon" ... (free text; only for
--                reading: CB.Sections / CB.SectionHeld group jobs and their cons by it, priorities stay global).  A job that only
--                names an owner for cons a system takes itself (the spine's Take) registers with want = 0.
--   urgent       (default true; or a function) may take cons from lower-priority preemptable jobs when none is free;
--                false = free cons only.  preemptMax = at most this many cons taken that way per hand-out pass
--   useReserve   may take the cons the hold keeps back (default false: the job must leave `hold[tier]` free cons); a function: evaluated per pick,
--   want(frame, res) -> n          cons wanted now
--   canTake(conID, tier) -> bool   per-con filter
--   near() -> x, z                 the job's place (nearest free con wins)
--   start(conID, frame, res) -> st | true | false     false = refused (the broker tries another con); st is added to `sessions`
--   sessions = {}                  placer states; the broker runs `updateSession(st, frame, res)` on each, unless paused()
--   paused() -> bool, onDone(st, frame, res) (default: free the builder), onOrphan(st) (builder died; true = skip the update)
--   preemptable = true             its cons may be taken by a higher-priority job;  canPreempt(conID) narrows it (idle members only),
--                                  heldPrio(conID) = the priority a held con counts at (an idle crew member is worth less)
--   onPreempt(conID)               the job must forget the con (the broker STOPs it)
--   onLost(conID)                  a con of the job died
--   idleCount() -> n               held cons that count as available for the reserve although the job owns them
--   produce(frame, res)            called when the job still needs cons (needs() or want() > 0) and none is free (make cons:
--                                  the labs are the job's business); needs() = the job's need for production, default want()
--
-- Any builder can be registered (CB.Add), air or ground: a T1 ground con waiting to build a new lab type is a con like any other.
-- Counting calls (Free, NFree, Count, Available, Shortfall, Unmet) take an optional `defs` set to count one unit type.
--
-- A con not owned by a job (spine, defense_crew cover) is Claim()ed / Take()n under a plain owner name and Release()d.

local CB = {}

CB.CFG = { LOG_EVERY = 1800 }

local CMD_STOP = 0

local function alive(id) return id and Spring.GetUnitDefID(id) ~= nil end

function CB.New(o)
    o = o or {}
    return { cons = {}, list = {}, seq = 0, jobs = {}, byName = {}, reserve = { 0, 0 }, hold = { 0, 0 }, isT2 = o.isT2 or function() return false end,
             updateSession = o.updateSession, echo = o.echo or function(s) Spring.Echo(s) end, clock = o.clock or tostring,
             busy = false, lastLog = -1e9, hooks = o.hooks or {}, CFG = o.cfg or CB.CFG }
end

-- ── ordering constructors from a lab ───────────────────────────────────────────

-- The way a constructor is ordered from a lab: through the lab broker when the bot's lab controller published one (WG.LabBroker =
-- { LB = <lab_broker module>, lb = <its instance> }: its grace / pending gates then know about the order), else straight to the
-- lab.  ahead = in front of a busy queue (after the unit being built), else at the tail.
function CB.OrderCon(WG, labID, defID, frame, ahead)
    local lbk = WG and WG.LabBroker
    if lbk and lbk.lb then
        lbk.LB.Order(lbk.lb, labID, defID, frame or 0, { ahead = ahead })
    elseif ahead then
        local busy = Spring.GetUnitWorkerTask and select(2, Spring.GetUnitWorkerTask(labID))
        local alt, internal, ctrl = (CMD and CMD.OPT_ALT) or 128, (CMD and CMD.OPT_INTERNAL) or 8, (CMD and CMD.OPT_CTRL) or 64
        Spring.GiveOrderToUnit(labID, (CMD and CMD.INSERT) or 1, { busy and 1 or 0, -defID, alt + internal }, alt + ctrl)
    else
        Spring.GiveOrderToUnit(labID, -defID, { 0 }, {})
    end
end

-- ── registry ───────────────────────────────────────────────────────────────────

-- A new (or returning) con joins the free pool.  Returns false when it is already known (no duplicates, ever).
function CB.Add(cb, id, defID)
    if cb.cons[id] then return false end
    defID = defID or Spring.GetUnitDefID(id)
    if not defID then return false end
    cb.seq = cb.seq + 1
    local d = UnitDefs[defID] or {}
    local c = { id = id, defID = defID, name = d.name, air = d.canFly == true, tier = cb.isT2(defID) and 2 or 1, owner = nil,
                seq = cb.seq, since = 0 }
    cb.cons[id] = c
    cb.list[#cb.list + 1] = c
    return true
end

function CB.Remove(cb, id)
    local c = cb.cons[id]
    if not c then return end
    cb.cons[id] = nil
    for i, x in ipairs(cb.list) do if x == c then table.remove(cb.list, i); break end end
    local job = c.owner and cb.byName[c.owner]
    if job and job.onLost then job.onLost(id) end
end

function CB.Forget(cb, id) if cb.lent then cb.lent[id] = nil end end    -- a pooled con died: no longer lent

function CB.Owner(cb, id) local c = cb.cons[id]; return c and c.owner end
function CB.IsManaged(cb, id) return cb.cons[id] ~= nil end

local function TierNo(t) return t == "t2" and 2 or (t == "t1" and 1 or nil) end   -- nil = any tier

local function Prio(cb, job)
    local p = job.prio
    if type(p) == "function" then p = p(cb) end
    return p or 0
end

-- does the con's kind / unit type suit (kind: "air" | "ground" | "any"/nil, defs: set of unit names or nil)?
local function KindOK(c, kind, defs)
    if kind == "air" and not c.air then return false end
    if kind == "ground" and c.air then return false end
    if defs and not defs[c.name] then return false end
    return true
end

-- free cons of a tier (1, 2 or nil = both), alive ones only; optional defs = one unit type (set of names), kind = "air" | "ground"
function CB.Free(cb, tier, defs, kind)
    local out = {}
    for _, c in ipairs(cb.list) do
        if not c.owner and (not tier or c.tier == tier) and KindOK(c, kind, defs) and alive(c.id) then out[#out + 1] = c.id end
    end
    return out
end

function CB.NFree(cb, tier, defs, kind) return #CB.Free(cb, tier, defs, kind) end

function CB.Held(cb, name)
    local out = {}
    for _, c in ipairs(cb.list) do if c.owner == name then out[#out + 1] = c.id end end
    return out
end

function CB.Count(cb, tier, defs, kind)
    local n = 0
    for _, c in ipairs(cb.list) do if (not tier or c.tier == tier) and KindOK(c, kind, defs) then n = n + 1 end end
    return n
end

-- Take a con back for the pool (the job is done with it).  stop = cancel its orders (a guard, a queued build).
function CB.Release(cb, id, stop)
    local c = cb.cons[id]
    if not c then return false end
    c.owner = nil
    if stop and alive(id) then Spring.GiveOrderToUnit(id, CMD_STOP, {}, {}) end
    return true
end

-- Hand a specific FREE con to an owner that is not a registered job (a new con the spine takes, a cover lead).
function CB.Claim(cb, id, owner)
    local c = cb.cons[id]
    if not c or c.owner then return false end
    c.owner = owner
    return true
end

-- ── choosing a con ─────────────────────────────────────────────────────────────

local function HeldPrio(cb, h, id)
    if h.heldPrio then return h.heldPrio(id) end
    return Prio(cb, h)
end

local function Dist2(id, x, z)
    local ux, _, uz = Spring.GetUnitPosition(id)
    if not ux then return 0 end
    return (ux - x) ^ 2 + (uz - z) ^ 2
end

local function Fits(cb, job, c, skip)
    if skip and skip[c.id] then return false end
    local t = TierNo(job.tier)
    if t and c.tier ~= t then return false end
    if not KindOK(c, job.kind or (job.defs and "any" or "air"), job.defs) then return false end
    if job.canTake and not job.canTake(c.id, c.tier) then return false end
    return alive(c.id)
end

-- best candidate by (tier rank for "any": T1 first, then nearest to the job / oldest)
local function Better(job, nx, nz, a, b)
    local ra = (not TierNo(job.tier)) and a.tier or 0
    local rb = (not TierNo(job.tier)) and b.tier or 0
    if ra ~= rb then return ra < rb end
    if nx then
        local da, db = Dist2(a.id, nx, nz), Dist2(b.id, nx, nz)
        if da ~= db then return da < db end
    end
    return a.seq < b.seq
end

local function PickFree(cb, job, skip)
    local nx, nz
    if job.near then nx, nz = job.near() end
    local best
    local free = {}
    for _, c in ipairs(cb.list) do
        if not c.owner and Fits(cb, job, c, skip) then free[c.tier] = (free[c.tier] or 0) + 1 end
    end
    for _, c in ipairs(cb.list) do
        if not c.owner and Fits(cb, job, c, skip) then
            -- the hold: a job without useReserve leaves hold[tier] cons free (for the jobs that may use them)
            local ur = job.useReserve
            if type(ur) == "function" then ur = ur() end        -- a job may claim the hold only in some states (e.g. while metal floats)
            if ur or free[c.tier] > (cb.hold[c.tier] or 0) then
                if not best or Better(job, nx, nz, c, best) then best = c end
            end
        end
    end
    return best
end

-- a con of a lower-priority preemptable job (lowest priority first, then nearest)
local function PickPreempt(cb, job, skip)
    local nx, nz
    if job.near then nx, nz = job.near() end
    local myPrio = Prio(cb, job)
    local best, bestP
    for _, c in ipairs(cb.list) do
        local h = c.owner and cb.byName[c.owner]
        if h and h ~= job and h.preemptable and HeldPrio(cb, h, c.id) < myPrio and Fits(cb, job, c, skip)
           and (not h.canPreempt or h.canPreempt(c.id)) then
            local hp = HeldPrio(cb, h, c.id)
            if not best or hp < bestP or (hp == bestP and Better(job, nx, nz, c, best)) then best, bestP = c, hp end
        end
    end
    return best
end

local function SortedJobs(cb)
    local jobs = {}
    for i, j in ipairs(cb.jobs) do jobs[i] = { j = j, p = Prio(cb, j), i = i } end
    table.sort(jobs, function(a, b) if a.p ~= b.p then return a.p > b.p end return a.i < b.i end)
    local out = {}
    for i, e in ipairs(jobs) do out[i] = e.j end
    return out
end

-- Take a free con for a non-job owner (defense_crew cover, spine).  opts: tier = 1|2|nil, canTake, near = {x, z}, preemptFrom = prio
-- (a con of a preemptable job below that priority may be taken when none is free).  Returns the con id or nil.
function CB.Take(cb, owner, opts)
    opts = opts or {}
    local job = { tier = opts.tier == 1 and "t1" or (opts.tier == 2 and "t2" or "any"), canTake = opts.canTake, useReserve = opts.useReserve ~= false,
                  prio = opts.prio or 1e9, kind = opts.kind or "air", defs = opts.defs }
    if opts.near then job.near = function() return opts.near[1], opts.near[2] end end
    local c = PickFree(cb, job)
    if not c and opts.preempt then
        c = PickPreempt(cb, job)
        if c then
            local h = cb.byName[c.owner]
            if h and h.onPreempt then h.onPreempt(c.id) end
            Spring.GiveOrderToUnit(c.id, CMD_STOP, {}, {})
        end
    end
    if not c then return nil end
    c.owner = owner
    return c.id
end

-- ── pools (C2): constructors another system keeps, asked for through the broker ─────────────────────────────────
-- A POOL is a source of ground cons the broker does not track itself (slot_spine's cons and block residents).  It registers
--     CB.AddPool(cb, "spine-ground", { take = function(owner, req) -> uid|nil, give = function(uid, owner), count = function() -> { total, idle } })
-- and everyone else asks through CB.TakeAny(cb, owner, req) instead of reaching into the pool's own tables: the broker then knows who
-- holds which con (CB.Status lists it), a con can only be given back by the one that took it, and the pool's inner states stay private.
--   req: { defID = the unit the con must place, kind = "ground" (default: pools only) | "any" (pools, then the broker's air cons),
--          near = { x, z }, allowBlock = true (the pool may take a builder off a live block job: off by default) }
function CB.AddPool(cb, name, spec)
    cb.pools = cb.pools or { list = {}, byName = {} }
    assert(not cb.pools.byName[name], "con_broker pool registered twice: " .. name)
    assert(spec.take and spec.give, "con_broker pool needs take and give")
    spec.name = name
    cb.pools.list[#cb.pools.list + 1] = spec
    cb.pools.byName[name] = spec
    return spec
end

function CB.TakeAny(cb, owner, req)
    req = req or {}
    cb.lent = cb.lent or {}
    for _, pool in ipairs(cb.pools and cb.pools.list or {}) do
        local uid = pool.take(owner, req)
        if uid then
            cb.lent[uid] = { pool = pool.name, owner = owner }
            return uid, pool.name
        end
    end
    if req.kind == "any" or req.kind == "air" then
        local uid = CB.Take(cb, owner, { canTake = req.canTake, near = req.near, kind = "air" })
        if uid then return uid, "broker" end
    end
    return nil
end

-- Give a con back to the pool it came from.  false when `owner` is not the one that took it (nothing happens).
function CB.GiveBack(cb, uid, owner)
    local l = cb.lent and cb.lent[uid]
    if not l then return false end
    if owner and l.owner ~= owner then return false end
    local pool = cb.pools and cb.pools.byName[l.pool]
    cb.lent[uid] = nil
    if pool then pool.give(uid, l.owner) end
    return true
end

function CB.RemoveJob(cb, name)
    local j = cb.byName[name]
    if not j then return end
    cb.byName[name] = nil
    for i, x in ipairs(cb.jobs) do if x == j then table.remove(cb.jobs, i); break end end
end

-- Can an outside owner (defense_crew) use this con now?  Unmanaged cons: yes (not ours).  Managed: free, or held by a preemptable
-- job that lets it go.  Seize() takes it (the old owner forgets it, the con is STOPped); false when it is busy with a real job.
function CB.Usable(cb, id)
    local c = cb.cons[id]
    if not c then return true end
    if not c.owner then return true end
    local h = cb.byName[c.owner]
    return h ~= nil and h.preemptable == true and (not h.canPreempt or h.canPreempt(id)) or false
end

function CB.Seize(cb, id, owner)
    local c = cb.cons[id]
    if not c then return true end
    if not CB.Usable(cb, id) then return false end
    local h = c.owner and cb.byName[c.owner]
    if h and h.onPreempt then h.onPreempt(id) end
    if c.owner then Spring.GiveOrderToUnit(id, CMD_STOP, {}, {}) end
    c.owner = owner
    return true
end

-- ── jobs ───────────────────────────────────────────────────────────────────────

function CB.AddJob(cb, spec)
    assert(spec.name and spec.want and spec.start, "con_broker job needs name, want and start")
    assert(not cb.byName[spec.name], "con_broker job registered twice: " .. spec.name)
    cb.jobs[#cb.jobs + 1] = spec
    cb.byName[spec.name] = spec
    return spec
end

-- cons a job holds now
function CB.HeldCount(cb, name)
    local n = 0
    for _, c in ipairs(cb.list) do if c.owner == name then n = n + 1 end end
    return n
end

-- every session of every job (for OnUnitFinished fan-out)
function CB.EachSession(cb, fn)
    for _, job in ipairs(cb.jobs) do
        if job.sessions then
            for _, st in ipairs(job.sessions) do if not st.done then fn(st, job) end end
        end
    end
end

-- ── sessions ───────────────────────────────────────────────────────────────────

function CB.RunSessions(cb, frame, res)
    for _, job in ipairs(cb.jobs) do
        local list = job.sessions
        if list then
            local i = 1
            while i <= #list do
                local st = list[i]
                if st.done then
                    table.remove(list, i)
                    if job.onDone then
                        job.onDone(st, frame, res)
                    elseif st.builderID and alive(st.builderID) then
                        CB.Release(cb, st.builderID)
                    end
                else
                    local skip = false
                    if st.builderID and not alive(st.builderID) and job.onOrphan then skip = job.onOrphan(st) == true end
                    if not skip and not (job.paused and job.paused()) and cb.updateSession then cb.updateSession(st, frame, res) end
                    i = i + 1
                end
            end
        end
    end
end

-- ── assignment ─────────────────────────────────────────────────────────────────

local function Assign(cb, frame, res)
    if cb.hooks.before then cb.hooks.before(frame, res) end
    for _, c in ipairs(cb.list) do
        if not alive(c.id) then c.dead = true end
    end
    for i = #cb.list, 1, -1 do
        if cb.list[i].dead then CB.Remove(cb, cb.list[i].id) end
    end
    for _, job in ipairs(SortedJobs(cb)) do
        local skip, guard, preempts = {}, 0, 0
        job.unmet = false
        local urgent = job.urgent
        if type(urgent) == "function" then urgent = urgent() end
        if urgent == nil then urgent = true end
        while guard < 64 do
            guard = guard + 1
            local n = job.want(frame, res) or 0
            if n <= 0 then break end
            local c = PickFree(cb, job, skip)
            local preempted = false
            if not c and urgent and (not job.preemptMax or preempts < job.preemptMax) then
                c = PickPreempt(cb, job, skip)
                preempted = c ~= nil
                if preempted then preempts = preempts + 1 end
            end
            if not c then job.unmet = true; break end
            if preempted then
                local h = cb.byName[c.owner]
                if h and h.onPreempt then h.onPreempt(c.id) end
            end
            if not job.noStop then Spring.GiveOrderToUnit(c.id, CMD_STOP, {}, {}) end
            c.owner, c.since = job.name, frame
            local r = job.start(c.id, frame, res)
            if r then
                if type(r) == "table" and job.sessions then job.sessions[#job.sessions + 1] = r end
            else
                c.owner = nil
                skip[c.id] = true
            end
        end
    end
end

-- Hand out free cons now (callers: a session just ended, a con just arrived).  Re-entrant calls are ignored.
function CB.Assign(cb, frame, res)
    if cb.busy then return end
    cb.busy = true
    local ok, err = pcall(Assign, cb, frame or 0, res)
    cb.busy = false
    if not ok then error(err, 0) end
end

-- ── reserve and production ─────────────────────────────────────────────────────

-- cons wanted by jobs of a tier that cannot be served by preemption (helpers are not demand)
local function DefsOverlap(a, b)
    if not (a and b) then return false end
    for k in pairs(a) do if b[k] then return true end end
    return false
end

-- (defs given: only the jobs that ask for those unit types count; none: every job of the tier)
function CB.Unmet(cb, tier, frame, res, defs)
    local n = 0
    for _, job in ipairs(cb.jobs) do
        local t = TierNo(job.tier)
        if not job.preemptable and (not t or t == tier) and (not defs or DefsOverlap(job.defs, defs)) then
            n = n + math.max(0, job.want(frame, res) or 0)
        end
    end
    return n
end

-- cons ready for a job: free ones, and (countIdle) those held by preemptable / idle-counting jobs
function CB.Available(cb, tier, countIdle, defs, kind)
    kind = kind or (defs and "any" or "air")
    local n = CB.NFree(cb, tier, defs, kind)
    if countIdle then
        for _, job in ipairs(cb.jobs) do
            local t = TierNo(job.tier)
            if not t or t == tier then
                if job.preemptable then
                    for _, c in ipairs(cb.list) do
                        if c.owner == job.name and c.tier == tier and KindOK(c, kind, defs) and (not job.canPreempt or job.canPreempt(c.id)) then n = n + 1 end
                    end
                elseif job.idleCount and not defs then
                    n = n + (job.idleCount() or 0)
                end
            end
        end
    end
    return n
end

-- How many more cons of `tier` the labs should make: what the jobs want + the reserve - what is ready - what is already ordered.
-- With defs: one unit type -- the jobs asking for it + its own reserve (SetReserve(cb, tier, n, defs)) - the ones ready.
function CB.Shortfall(cb, tier, ordered, countIdle, frame, res, defs)
    local reserve = cb.reserve[tier] or 0
    if defs then reserve = cb.defReserve and cb.defReserve[CB.DefsKey(defs)] or 0 end
    return CB.Unmet(cb, tier, frame, res, defs) + reserve - CB.Available(cb, tier, countIdle, defs) - (ordered or 0)
end

function CB.DefsKey(defs)
    local names = {}
    for k in pairs(defs) do names[#names + 1] = k end
    table.sort(names)
    return table.concat(names, ",")
end

-- reserve = the cons the labs keep READY beyond what the jobs want (production target, see Shortfall)
function CB.SetReserve(cb, tier, n, defs)
    if defs then
        cb.defReserve = cb.defReserve or {}
        cb.defReserve[CB.DefsKey(defs)] = math.max(0, n or 0)     -- e.g. keep 2 Twitchers ready: SetReserve(cb, 1, 2, { cortwitcher = true })
    else
        cb.reserve[tier] = math.max(0, n or 0)
    end
end
-- hold = free cons kept back from the jobs that are not flagged `useReserve` (e.g. T2 cons kept for the fusion jobs, not retrofits)
function CB.SetHold(cb, tier, n) cb.hold[tier] = math.max(0, n or 0) end

-- ── per-update entry ───────────────────────────────────────────────────────────

function CB.Update(cb, frame, res, sessionsDone)
    if not sessionsDone then CB.RunSessions(cb, frame, res) end
    CB.Assign(cb, frame, res)
    -- jobs still short of cons ask the labs
    for _, job in ipairs(cb.jobs) do
        if job.produce then
            local n = (job.needs or job.want)(frame, res) or 0
            if n > 0 and #CB.Free(cb, TierNo(job.tier), job.defs, job.kind or (job.defs and "any" or "air")) == 0 then job.produce(frame, res) end
        end
    end
    if cb.hooks.reserve then cb.hooks.reserve(frame, res) end
    if frame - cb.lastLog >= (cb.CFG.LOG_EVERY or 1800) then
        cb.lastLog = frame
        cb.echo(string.format("[CB] %s %s", cb.clock(frame), CB.Status(cb)))
    end
end

-- { [section] = { jobName, ... } } in registration order; jobs without a section go under "other".
function CB.Sections(cb)
    local out = {}
    for _, job in ipairs(cb.jobs) do
        local sec = job.section or "other"
        out[sec] = out[sec] or {}
        out[sec][#out[sec] + 1] = job.name
    end
    return out
end

-- cons held by the jobs of one section: T1 count, T2 count
function CB.SectionHeld(cb, section)
    local t1, t2 = 0, 0
    for _, job in ipairs(cb.jobs) do
        if (job.section or "other") == section then
            for _, c in ipairs(cb.list) do
                if c.owner == job.name then if c.tier == 1 then t1 = t1 + 1 else t2 = t2 + 1 end end
            end
        end
    end
    return t1, t2
end

function CB.Status(cb)
    local held, parts = {}, {}
    for _, c in ipairs(cb.list) do
        local k = c.owner or "free"
        held[k] = held[k] or { 0, 0 }
        held[k][c.tier] = held[k][c.tier] + 1
    end
    local names = {}
    for k in pairs(held) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do parts[#parts + 1] = string.format("%s %d+%d", k, held[k][1], held[k][2]) end
    local pools = {}
    for _, pool in ipairs(cb.pools and cb.pools.list or {}) do
        local lent = {}
        for _, l in pairs(cb.lent or {}) do if l.pool == pool.name then lent[l.owner] = (lent[l.owner] or 0) + 1 end end
        local lk = {}
        for k in pairs(lent) do lk[#lk + 1] = k end
        table.sort(lk)
        local lp = {}
        for _, k in ipairs(lk) do lp[#lp + 1] = string.format("%s %d", k, lent[k]) end
        local c = pool.count and pool.count() or {}
        pools[#pools + 1] = string.format("%s %d (idle %d%s)", pool.name, c.total or 0, c.idle or 0, #lp > 0 and (", lent: " .. table.concat(lp, ", ")) or "")
    end
    return string.format("cons T1+T2: %s | reserve %d+%d%s", table.concat(parts, ", "), cb.reserve[1] or 0, cb.reserve[2] or 0,
        #pools > 0 and (" | pools: " .. table.concat(pools, "; ")) or "")
end

return CB
