-- tests/test_con_broker.lua     python tests/run_lua.py tests/test_con_broker.lua
-- bar_framework/con_broker.lua: one owner per air con, jobs in priority order, nearest con, the hold and the reserve, preemption of
-- helper jobs, refused starts, finished sessions freeing their builder, dead cons, T1/T2 tiers, production hooks, outside owners.

local S = dofile("tests/spring_stub.lua")
S.ROOT = "./"
local W = S.W

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local CB = VFS.Include("LuaUI/Widgets/bar_framework/con_broker.lua")
local T2 = UnitDefNames.coraca.id

local function New()
    W.units, W.orders, W.log = {}, {}, {}
    local cb = CB.New{ isT2 = function(d) return d == T2 end, updateSession = function(st) st.updates = (st.updates or 0) + 1 end,
                       echo = function(s) W.log[#W.log + 1] = s end }
    return cb
end
local function Con(cb, x, tier)
    local id = S.Spawn(tier == 2 and "coraca" or "corca", 0, x or 0, 0, { silent = true })
    CB.Add(cb, id)
    return id
end
local function Stops(id)
    local n = 0
    for _, o in ipairs(W.orders) do if o.id == id and o.cmd == 0 then n = n + 1 end end
    return n
end
-- a plain job: wants `n()` cons, remembers who it got
local function Job(cb, name, prio, tier, n, extra)
    local j
    j = { name = name, prio = prio, tier = tier, got = {}, want = function() return n() - #j.got end,
                start = function(id) j.got[#j.got + 1] = id; return true end }
    for k, v in pairs(extra or {}) do j[k] = v end
    CB.AddJob(cb, j)
    return j
end

-- ── registry ──────────────────────────────────────────────────────────────────
local cb = New()
local a, b = Con(cb, 0, 1), Con(cb, 10, 2)
check(CB.Add(cb, a) == false, "a con is registered once (no duplicates)")
check(CB.Count(cb, 1) == 1 and CB.Count(cb, 2) == 1 and CB.NFree(cb, 1) == 1 and CB.NFree(cb, 2) == 1, "T1 and T2 told apart; both free")
check(CB.Owner(cb, a) == nil and CB.IsManaged(cb, a), "a free con has no owner")

-- ── priority, tiers ───────────────────────────────────────────────────────────
cb = New()
local c1 = Con(cb, 0, 1)
local low  = Job(cb, "low", 10, "t1", function() return 5 end)
local high = Job(cb, "high", 90, "t1", function() return 1 end)
CB.Assign(cb, 100)
check(#high.got == 1 and #low.got == 0 and CB.Owner(cb, c1) == "high", "the higher job gets the only con")
check(Stops(c1) == 1, "a con is STOPped when handed out")
local c2 = Con(cb, 0, 1)
CB.Assign(cb, 110)
check(#low.got == 1 and low.got[1] == c2, "the next con goes on to the next job")

cb = New()
local t1c, t2c = Con(cb, 0, 1), Con(cb, 0, 2)
local jt2 = Job(cb, "t2job", 50, "t2", function() return 2 end)
local jt1 = Job(cb, "t1job", 40, "t1", function() return 2 end)
CB.Assign(cb, 100)
check(jt2.got[1] == t2c and #jt2.got == 1 and jt1.got[1] == t1c and #jt1.got == 1, "a tier job takes only cons of its tier")
cb = New()
t1c, t2c = Con(cb, 0, 2), Con(cb, 0, 1)             -- the T2 is OLDER
local jany = Job(cb, "any", 50, "any", function() return 1 end)
CB.Assign(cb, 100)
check(jany.got[1] == t2c, "a tier-any job takes a T1 con before a T2 one (even when the T2 is older)")

-- ── nearest con ───────────────────────────────────────────────────────────────
cb = New()
local far, near = Con(cb, 3000, 1), Con(cb, 100, 1)
local jn = Job(cb, "near", 50, "t1", function() return 1 end, { near = function() return 0, 0 end })
CB.Assign(cb, 100)
check(jn.got[1] == near, "the con nearest the job's place wins")
cb = New()
far, near = Con(cb, 3000, 1), Con(cb, 100, 1)
jn = Job(cb, "fifo", 50, "t1", function() return 1 end)
CB.Assign(cb, 100)
check(jn.got[1] == far, "a job with no place gets the oldest free con")

-- ── hold (T2 cons kept back from retrofits) ───────────────────────────────────
cb = New()
local h1 = Con(cb, 0, 2)
local retro = Job(cb, "retro", 60, "t2", function() return 1 end)
local fus   = Job(cb, "fus", 40, "t2", function() return 1 end, { useReserve = true })
CB.SetHold(cb, 2, 1)
CB.Assign(cb, 100)
check(#retro.got == 0 and #fus.got == 1, "the held con goes to the job that may use it, not to the higher one")

-- ── preemption ────────────────────────────────────────────────────────────────
cb = New()
local p1, p2 = Con(cb, 0, 1), Con(cb, 0, 1)
local lost = {}
local helpers = Job(cb, "helpers", 20, "t1", function() return 2 end,
    { preemptable = true, urgent = false, onPreempt = function(id) lost[#lost + 1] = id end })
CB.Assign(cb, 100)
check(#helpers.got == 2, "the helper job takes the idle cons")
local grid = Job(cb, "grid", 70, "t1", function() return 1 end)
CB.Assign(cb, 110)
check(#grid.got == 1 and #lost == 1 and lost[1] == grid.got[1], "a higher job takes a con off the helpers, who are told")
check(CB.Owner(cb, grid.got[1]) == "grid", "...and owns it")
local meh = Job(cb, "meh", 10, "t1", function() return 1 end)
CB.Assign(cb, 120)
check(#meh.got == 0, "a lower job cannot take from the helpers")
local polite = Job(cb, "polite", 80, "t1", function() return 1 end, { urgent = false })
CB.Assign(cb, 130)
check(#polite.got == 0, "urgent = false: free cons only")

cb = New()
for _ = 1, 6 do Con(cb, 0, 2) end
local hl = Job(cb, "hl", 20, "t2", function() return 6 end, { preemptable = true, urgent = false, onPreempt = function() end })
CB.Assign(cb, 100)
local big = Job(cb, "big", 70, "t2", function() return 6 end, { preemptMax = 2 })
CB.Assign(cb, 110)
check(#big.got == 2, "preemptMax caps the cons taken off helpers per pass (" .. #big.got .. ")")

-- canPreempt / heldPrio: an idle crew member is worth less than a busy one
cb = New()
local m1, m2 = Con(cb, 0, 1), Con(cb, 0, 1)
local busy = { [m1] = true }
local crew = Job(cb, "crew", 72, "t1", function() return 2 end, { urgent = false, preemptable = true,
    canPreempt = function(id) return not busy[id] end, heldPrio = function(id) return busy[id] and 72 or 25 end })
CB.Assign(cb, 100)
local fusion = Job(cb, "fusion", 30, "t1", function() return 1 end)
CB.Assign(cb, 110)
check(fusion.got[1] == m2, "only the idle crew member can be taken (canPreempt / heldPrio)")

-- ── refused start ─────────────────────────────────────────────────────────────
cb = New()
local r1, r2 = Con(cb, 0, 1), Con(cb, 0, 1)
local tried = {}
local fussy = { name = "fussy", prio = 50, tier = "t1", want = function() return 1 end,
                start = function(id) tried[#tried + 1] = id; return id == r2 end }
CB.AddJob(cb, fussy)
CB.Assign(cb, 100)
check(#tried == 2 and CB.Owner(cb, r2) == "fussy" and CB.Owner(cb, r1) == nil, "a refused con goes back to the pool, the next one is tried")
local never = { name = "never", prio = 60, tier = "t1", want = function() return 3 end, start = function() return false end }
CB.AddJob(cb, never)
CB.Assign(cb, 110)                                   -- must terminate
check(CB.Owner(cb, r1) == nil, "a job that refuses every con ends the pass, the con stays free")

-- ── sessions ──────────────────────────────────────────────────────────────────
cb = New()
local s1 = Con(cb, 0, 1)
local sessions = {}
local want = 1
CB.AddJob(cb, { name = "build", prio = 50, tier = "t1", sessions = sessions, want = function() return want end,
                start = function(id) want = 0; return { builderID = id, done = false } end })
CB.Update(cb, 100, {})
check(#sessions == 1 and CB.Owner(cb, s1) == "build", "a session returned by start is tracked")
CB.Update(cb, 110, {})
check(sessions[1].updates and sessions[1].updates >= 1, "the broker runs the placer update on it")
sessions[1].done = true
CB.Update(cb, 120, {})
check(#sessions == 0 and CB.Owner(cb, s1) == nil and CB.NFree(cb, 1) == 1, "a finished session is dropped and its builder is free")

cb = New()
local s2 = Con(cb, 0, 1)
local paused = true
sessions = {}
CB.AddJob(cb, { name = "p", prio = 50, tier = "t1", sessions = sessions, paused = function() return paused end,
                want = function() return #sessions == 0 and 1 or 0 end, start = function(id) return { builderID = id } end })
CB.Update(cb, 100, {}); CB.Update(cb, 110, {})
check((sessions[1].updates or 0) == 0, "paused(): the session is not updated")
paused = false
CB.Update(cb, 120, {})
check(sessions[1].updates == 1, "...and runs again after")

local seen = {}
CB.EachSession(cb, function(st) seen[#seen + 1] = st end)
check(#seen == 1, "EachSession visits the live sessions")

-- a dead builder: onOrphan can hold the update
cb = New()
local o1 = Con(cb, 0, 1)
sessions = {}
local orphans = 0
CB.AddJob(cb, { name = "o", prio = 50, tier = "t1", sessions = sessions, want = function() return #sessions == 0 and 1 or 0 end,
                start = function(id) return { builderID = id } end, onOrphan = function() orphans = orphans + 1; return true end })
CB.Update(cb, 100, {})
S.Kill(o1)
CB.Update(cb, 110, {})
check(orphans == 1 and (sessions[1].updates or 0) == 0 and CB.Count(cb) == 0, "a dead builder: onOrphan asked, the session is not updated, the con is forgotten")

-- ── dead cons ─────────────────────────────────────────────────────────────────
cb = New()
local d1 = Con(cb, 0, 1)
local lostIds = {}
local dj = Job(cb, "d", 50, "t1", function() return 1 end, { onLost = function(id) lostIds[#lostIds + 1] = id end })
CB.Assign(cb, 100)
CB.Remove(cb, d1)
check(lostIds[1] == d1 and CB.Count(cb) == 0, "Remove tells the owner")
local d2 = Con(cb, 0, 1)
S.Kill(d2)
CB.Assign(cb, 110)
check(CB.Count(cb) == 0, "a con that died without a callback is dropped at the next hand-out")

-- ── shortfall: the reserve ────────────────────────────────────────────────────
cb = New()
Con(cb, 0, 1)
local sj = Job(cb, "grids", 70, "t1", function() return 3 end, { start = function() return false end })
local hj = Job(cb, "helpers", 20, "t1", function() return 9 end, { preemptable = true, urgent = false })
CB.SetReserve(cb, 1, 2)
-- unmet 3 (helpers are not demand) + reserve 2 - free 1 - ordered 1
check(CB.Shortfall(cb, 1, 1, false, 100) == 3, "shortfall = what the jobs want + reserve - free - ordered (" .. CB.Shortfall(cb, 1, 1, false, 100) .. ")")
-- helpers' cons count as ready only with countIdle
cb = New()
local g1 = Con(cb, 0, 1)
Job(cb, "helpers", 20, "t1", function() return 9 end, { preemptable = true, urgent = false })
CB.Assign(cb, 100)
CB.SetReserve(cb, 1, 2)
check(CB.Available(cb, 1, false) == 0 and CB.Available(cb, 1, true) == 1, "helpers count as ready only when asked")
check(CB.Shortfall(cb, 1, 0, true, 100) == 1 and CB.Shortfall(cb, 1, 0, false, 100) == 2, "shortfall with and without the helpers")

-- ── produce ───────────────────────────────────────────────────────────────────
cb = New()
local made = 0
local pj = Job(cb, "needs", 50, "t2", function() return 1 end, { produce = function() made = made + 1 end })
CB.Update(cb, 100, {})
check(made == 1, "a job that wants a con and has none asks the labs")
Con(cb, 0, 2)
CB.Update(cb, 110, {})
check(made == 1, "...not when it got one")
cb = New()
made = 0
local want2 = 0
Job(cb, "needs2", 50, "t2", function() return 0 end, { needs = function() return want2 end, produce = function() made = made + 1 end })
want2 = 1
CB.Update(cb, 100, {})
check(made == 1, "needs() drives production when want() is 0 (a job that holds off for another reason)")

-- ── outside owners (defense_crew) ─────────────────────────────────────────────
cb = New()
local f1, f2 = Con(cb, 0, 1), Con(cb, 0, 1)
local gridj = Job(cb, "grid", 70, "t1", function() return 1 end)
local help = Job(cb, "helpers", 20, "t1", function() return 5 end, { preemptable = true, urgent = false, onPreempt = function() end })
CB.Assign(cb, 100)
check(CB.Usable(cb, f1) == false, "a con on a real job is not usable by an outsider")
local hid = help.got[1]
check(CB.Usable(cb, hid) == true and CB.Seize(cb, hid, "cover") and CB.Owner(cb, hid) == "cover", "a helper con can be seized for cover")
CB.Release(cb, hid, true)
check(CB.Owner(cb, hid) == nil, "...and given back")
check(CB.Usable(cb, 987654) == true, "an unmanaged unit is the caller's business")
local taken = CB.Take(cb, "spine", { tier = 1 })
check(taken == hid and CB.Owner(cb, hid) == "spine", "Take claims a free con for a plain owner")
check(CB.Take(cb, "spine", { tier = 1 }) == nil, "...none left: nil (helpers' cons stay put without preempt)")
Con(cb, 0, 1); CB.Assign(cb, 140)                  -- a new con: the helpers take it
check(CB.Take(cb, "spine", { tier = 1, preempt = true }) ~= nil, "...preempt = true takes one off the helpers")

-- ── kinds and unit types (defs): a job that wants one type, ground cons ───────────
cb = New()
local air1 = Con(cb, 0, 1)
local gnd1 = S.Spawn("corcv", 0, 0, 0, { silent = true }); CB.Add(cb, gnd1)
check(CB.Count(cb, nil, nil, "ground") == 1 and CB.Count(cb, nil, nil, "air") == 1, "air and ground cons are told apart")
local airJob = Job(cb, "airjob", 50, "t1", function() return 2 end)
CB.Assign(cb, 100)
check(#airJob.got == 1 and airJob.got[1] == air1, "a default job (kind air) never takes a ground con")
local gJob = Job(cb, "groundjob", 40, "t1", function() return 1 end, { kind = "ground" })
CB.Assign(cb, 110)
check(gJob.got[1] == gnd1, "kind = ground takes the ground con")

cb = New()
local ca, cv = Con(cb, 0, 1), S.Spawn("corcv", 0, 0, 0, { silent = true })
CB.Add(cb, cv)
local only = Job(cb, "onlycv", 50, "any", function() return 2 end, { defs = { corcv = true } })
CB.Assign(cb, 100)
check(#only.got == 1 and only.got[1] == cv, "defs: the job takes only that unit type (and any kind)")
check(CB.NFree(cb, nil, { corca = true }) == 1 and CB.NFree(cb, nil, { corcv = true }) == 0, "NFree counts one unit type")

-- per-type shortfall and reserve
cb = New()
local tw = { corcv = true }
local twJob = Job(cb, "proxy", 50, "any", function() return 1 end, { defs = tw })
Job(cb, "other", 50, "t1", function() return 4 end, { start = function() return false end })
check(CB.Shortfall(cb, 1, 0, false, 100, nil, tw) == 1, "per-type shortfall counts only the jobs that ask for the type")
CB.SetReserve(cb, 1, 2, tw)
check(CB.Shortfall(cb, 1, 0, false, 100, nil, tw) == 3, "...plus that type's own reserve")
check(CB.Shortfall(cb, 1, 1, false, 100, nil, tw) == 2, "...minus what is ordered")
local cv2 = S.Spawn("corcv", 0, 0, 0, { silent = true }); CB.Add(cb, cv2)
CB.Assign(cb, 100)
check(CB.Shortfall(cb, 1, 0, false, 100, nil, tw) == 2, "a con held by the job is not 'ready'; the reserve still wants 2 free")
CB.Release(cb, cv2)
check(CB.NFree(cb, nil, tw) == 1 and CB.Shortfall(cb, 1, 0, false, 100, nil, tw) == 1, "released: ready again, the reserve is short by 1")
check(CB.Shortfall(cb, 1, 0, false, 100) == 4 + 0 - 0, "the untyped shortfall is unchanged by the typed reserve (" .. CB.Shortfall(cb, 1, 0, false, 100) .. ")")

-- produce looks only for free cons the job could use
cb = New()
made = 0
Con(cb, 0, 1)                                           -- a free AIR con: no use to a corcv job
Job(cb, "wantsgnd", 50, "any", function() return 1 end, { defs = { corcv = true }, produce = function() made = made + 1 end })
CB.Update(cb, 100, {})
check(made == 1, "produce fires when the only free con is the wrong type")

-- Take with kind / defs
cb = New()
local ta = Con(cb, 0, 1)
local tg = S.Spawn("corcv", 0, 0, 0, { silent = true }); CB.Add(cb, tg)
check(CB.Take(cb, "x", { kind = "ground" }) == tg and CB.Take(cb, "y", { defs = { corca = true } }) == ta, "Take honours kind and defs")

-- ── re-entrancy ───────────────────────────────────────────────────────────────
cb = New()
Con(cb, 0, 1)
local depth = 0
CB.AddJob(cb, { name = "re", prio = 50, tier = "t1", want = function() return 1 end,
                start = function() depth = depth + 1; CB.Assign(cb, 100); return true end })
CB.Assign(cb, 100)
check(depth == 1, "an Assign called from a start is ignored")

check(CB.Status(cb):find("T1%+T2") ~= nil, "Status prints the holdings")

-- ── pools (C2): ground cons another system keeps, asked for through the broker ─────────────────────────────
cb = New()
local ground, takeLog, giveLog = { 501, 502 }, {}, {}
CB.AddPool(cb, "g", { take = function(owner, req) local id = table.remove(ground, 1); takeLog[#takeLog + 1] = owner; return id end,
                      give = function(uid, owner) ground[#ground + 1] = uid; giveLog[#giveLog + 1] = owner end,
                      count = function() return { total = 5, idle = #ground } end })
check(not pcall(CB.AddPool, cb, "g", { take = function() end, give = function() end }), "a pool name is registered once")
local u1, from = CB.TakeAny(cb, "sinklab", { kind = "ground" })
check(u1 == 501 and from == "g", "TakeAny takes from the pool")
check(CB.Status(cb):find("lent: sinklab 1", 1, true) ~= nil, "Status lists who holds a pooled con")
check(not CB.GiveBack(cb, u1, "linedecoy") and #giveLog == 0, "only the borrower can give a con back")
check(CB.GiveBack(cb, u1, "sinklab") and giveLog[1] == "sinklab" and ground[#ground] == 501, "the borrower gives it back to the pool")
check(not CB.GiveBack(cb, u1, "sinklab"), "...once")
local u2 = CB.TakeAny(cb, "linedecoy", { kind = "ground" })
CB.Forget(cb, u2)
check(CB.GiveBack(cb, u2, "linedecoy") == false, "a con that died (Forget) is no longer lent")
check(CB.TakeAny(cb, "x", { kind = "ground" }) ~= nil and CB.TakeAny(cb, "x", { kind = "ground" }) == nil, "an empty pool gives nil")
-- air cons: kind = "any" falls back to the broker's own
local airId = Con(cb, 0, 1)
ground = {}
check(CB.TakeAny(cb, "x", { kind = "ground" }) == nil, "kind ground never takes an air con")
check(CB.TakeAny(cb, "x", { kind = "any" }) == airId, "kind any falls back to the broker's air cons")

-- a spine-owned con is not for defense_crew: the "spine" job is not preemptable
cb = New()
CB.AddJob(cb, { name = "spine", prio = 100, tier = "any", want = function() return 0 end, start = function() return false end })
local gid = S.Spawn("corck", 0, 0, 0, { silent = true })
CB.Add(cb, gid)
check(CB.Usable(cb, gid), "an unowned ground con is usable by defense_crew")
CB.Claim(cb, gid, "spine")
check(not CB.Usable(cb, gid) and not CB.Seize(cb, gid, "defense"), "a con claimed as the spine's is not usable or seizable")

-- a job can be removed and registered again (metal_sink.Init twice)
cb = New()
Job(cb, "sinklab", 95, "any", function() return 0 end)
CB.RemoveJob(cb, "sinklab")
check(pcall(Job, cb, "sinklab", 95, "any", function() return 0 end), "after RemoveJob the name can be registered again")

print(string.format("con_broker: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
