-- tests/test_lab_broker.lua     python tests/run_lua.py tests/test_lab_broker.lua
-- bar_framework/lab_broker.lua with the engine replaced by a fake queue: priority order, the empty / ahead / topup / tail modes,
-- the insert gate (one insert until a unit starts), grace, depth fill, the separate busy-queue ranking (aheadPrio), skip, hooks.

Spring = Spring or { Echo = function() end }
local LB = dofile("bar_framework/lab_broker.lua")

local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- a fake factory: queues[labID] = number of orders waiting; every order is logged
local queues, log, echoes = {}, {}, {}
local function NewBroker(o)
    queues, log, echoes = {}, {}, {}
    o = o or {}
    o.queueLen = function(id) return queues[id] or 0 end
    o.order    = function(id, d) queues[id] = (queues[id] or 0) + 1; log[#log + 1] = { id = id, d = d, how = "tail" } end
    o.insert   = function(id, d) queues[id] = (queues[id] or 0) + 1; log[#log + 1] = { id = id, d = d, how = "ahead" } end
    o.echo     = function(s) echoes[#echoes + 1] = s end
    o.unitName = function(d) return "u" .. tostring(d) end
    return LB.New(o)
end
local function Lab(id) return { id = id, defID = 1000 } end
local function Last() return log[#log] end

-- ── priority: the highest want with an answer wins; a want that answers nil is passed over ──
do
    local lb = NewBroker()
    local want = { low = 1, high = nil, mid = 2 }
    LB.AddWant(lb, { name = "low",  prio = 10, pick = function() return want.low end })
    LB.AddWant(lb, { name = "high", prio = 90, pick = function() return want.high end })
    LB.AddWant(lb, { name = "mid",  prio = 50, pick = function() return want.mid end })
    local n, d = LB.Service(lb, Lab(1), 0)
    check(n == "mid" and d == 2, "a want with no answer is passed over; the next highest wins")
    want.high = 3
    LB.Service(lb, Lab(2), 0)
    check(Last().d == 3, "the highest-priority want wins when it answers")
    check(#log == 2, "one order per lab per service")
end

-- ── flush: a busy queue is cleared once per key, then filled to depth; after that it tops up; a new key clears again ──
do
    local lb = NewBroker{ clear = function(id) log[#log + 1] = { id = id, how = "clear" }; queues[id] = 0 end }
    local key, on = "raid1", true
    LB.AddWant(lb, { name = "army", prio = 10, mode = "topup", depth = 3, pick = function() return 1 end })
    LB.AddWant(lb, { name = "aa", prio = 150, mode = "flush", depth = 3, grace = 0,
                     flushKey = function() return key end, pick = function() if on then return 7 end end })
    queues[1] = 5
    LB.Service(lb, Lab(1), 0)
    check(log[1].how == "clear" and #log == 4 and log[2].d == 7 and log[4].d == 7 and queues[1] == 3,
          "flush: the busy queue is cleared, then filled to depth with the want's unit")
    LB.Service(lb, Lab(1), 1)
    check(#log == 4, "flush: same key, full queue: nothing more")
    queues[1] = 1
    LB.Service(lb, Lab(1), 2)
    check(#log == 6 and log[5].how == "tail" and log[6].d == 7, "flush: same key, short queue: topped up, not cleared")
    key = "raid2"
    LB.Service(lb, Lab(1), 3)
    check(log[7].how == "clear", "flush: a new key clears again")
    on = false
    queues[1] = 4
    local before = #log
    LB.Service(lb, Lab(1), 4)
    check(#log == before, "flush: no pick, no clear")
    LB.Forget(lb, 1)
    check(lb.flushed[1] == nil, "Forget drops the flush record")
end

-- ── EndFlush: the flush key is over -- its units come off every lab it flushed, other labs untouched ──
do
    local removed = {}
    local lb = NewBroker{ clear = function(id) queues[id] = 0 end, remove = function(id, set) removed[#removed + 1] = { id = id, set = set } end }
    LB.AddWant(lb, { name = "aa", prio = 150, mode = "flush", depth = 2, grace = 0, flushKey = function() return "r1" end, pick = function() return 7 end })
    queues[1], queues[2] = 3, 3
    LB.Service(lb, Lab(1), 0); LB.Service(lb, Lab(2), 0)
    lb.flushed[3] = "r0"
    local n = LB.EndFlush(lb, "r1", { [7] = true })
    check(n == 2 and #removed == 2 and removed[1].set[7] and lb.flushed[1] == nil and lb.flushed[3] == "r0",
          "EndFlush: the key's labs get their units removed; another key's lab is left alone")
end

-- ── grace: a lab just ordered is left alone; a want's own grace overrides ──
do
    local lb = NewBroker()
    LB.AddWant(lb, { name = "a", prio = 10, pick = function() return 1 end })
    LB.AddWant(lb, { name = "quick", prio = 20, grace = 30, mode = "tail", pick = function() return 2 end })
    LB.Service(lb, Lab(1), 100)
    check(#log == 1 and Last().d == 2, "first service orders")
    queues[1] = 0
    LB.Service(lb, Lab(1), 110)
    check(#log == 1, "within every want's grace: nothing ordered")
    LB.Service(lb, Lab(1), 140)
    check(#log == 2 and Last().d == 2, "the shorter grace opens first; the default-grace want still waits")
    queues[1] = 0
    LB.Forget(lb, 1)
    LB.Service(lb, Lab(1), 141)
    check(#log == 3, "Forget clears the grace")
end

-- ── modes on a busy queue: only ahead / topup / tail wants are tried; 'empty' wants wait ──
do
    local lb = NewBroker()
    LB.AddWant(lb, { name = "empty-only", prio = 99, mode = "empty", pick = function() return 1 end })
    LB.AddWant(lb, { name = "ahead", prio = 10, mode = "ahead", pick = function() return 2 end })
    queues[1] = 2
    LB.Service(lb, Lab(1), 0)
    check(Last().d == 2 and Last().how == "ahead", "busy queue: the ahead want inserts, the empty-only want is skipped")
    check(lb.pending[1] == 0, "an insert on a busy queue sets the pending gate")
    LB.Service(lb, Lab(1), 500)   -- grace long past
    check(#log == 1, "pending gate: no second insert while the first has not started")
    LB.UnitStarted(lb, 1)
    LB.Service(lb, Lab(1), 500)
    check(#log == 2, "UnitStarted opens the gate")
    LB.Service(lb, Lab(1), 1000)
    check(#log == 2, "the second insert (frame 500) set the gate again: still shut at 1000")
    LB.Service(lb, Lab(1), 1200)
    check(#log == 3, "the gate times out after PENDING_TIMEOUT frames")
    queues[2] = 0
    LB.Service(lb, Lab(2), 0)
    check(Last().d == 1 and Last().how == "tail", "empty queue: the highest want orders at the tail")
end

-- ── noPending: the want's own timer limits it, the gate stays open ──
do
    local lb = NewBroker()
    LB.AddWant(lb, { name = "ring", prio = 10, mode = "ahead", noPending = true, pick = function() return 5 end })
    queues[1] = 1
    LB.Service(lb, Lab(1), 0)
    check(Last().how == "ahead" and lb.pending[1] == nil, "noPending: inserted, no gate set")
end

-- ── the busy ranking can differ from the idle one (aheadPrio) ──
do
    local lb = NewBroker()
    LB.AddWant(lb, { name = "pool",  prio = 90, mode = "ahead", pick = function() return 1 end })
    LB.AddWant(lb, { name = "floor", prio = 80, aheadPrio = 92, mode = "ahead", pick = function() return 2 end })
    queues[1] = 0
    LB.Service(lb, Lab(1), 0)
    check(Last().d == 1, "idle lab: pool (90) outranks floor (80)")
    queues[2] = 3
    LB.Service(lb, Lab(2), 0)
    check(Last().d == 2, "busy lab: floor (aheadPrio 92) outranks pool (90)")
end

-- ── topup: fill to depth, only while the queue is short; each slot asks pick again ──
do
    local lb = NewBroker()
    local slots = {}
    LB.AddWant(lb, { name = "spine", prio = 10, mode = "topup", depth = 3,
        pick = function(lab, frame, slot) slots[#slots + 1] = slot; return 100 + slot end })
    queues[1] = 1
    LB.Service(lb, Lab(1), 0)
    check(#log == 2 and log[1].d == 102 and log[2].d == 103, "topup places the missing slots (queue had 1 of 3)")
    check(slots[1] == 2 and slots[2] == 3, "pick is told which queue slot it fills")
    check(queues[1] == 3, "queue is full after the top-up")
    LB.Service(lb, Lab(1), 1000)
    check(#log == 2, "a full queue is not topped up")
    -- a pick that runs dry stops the fill
    local lb2 = NewBroker()
    LB.AddWant(lb2, { name = "dry", prio = 1, mode = "topup", depth = 4, pick = function(l, f, slot) if slot <= 2 then return 7 end end })
    LB.Service(lb2, Lab(1), 0)
    check(#log == 2, "nil from pick ends the fill early")
end

-- ── depth on an empty queue (a function), tail mode on a long queue ──
do
    local lb = NewBroker()
    LB.AddWant(lb, { name = "dragons", prio = 10, mode = "empty", depth = function() return 3 end, pick = function() return 9 end })
    LB.Service(lb, Lab(1), 0)
    check(#log == 3, "depth 3 on an empty queue places 3")
    local lb2 = NewBroker()
    LB.AddWant(lb2, { name = "savior", prio = 10, mode = "tail", pick = function() return 4 end })
    queues[1] = 5
    LB.Service(lb2, Lab(1), 0)
    check(#log == 1 and Last().how == "tail", "tail mode appends to a long queue, once")
end

-- ── applies, skip, hooks, status ──
do
    local seen = {}
    local lb = NewBroker{ onOrder = function(d, lab, w, how, frame, n) seen[#seen + 1] = w.name .. ":" .. d .. ":" .. n end }
    local hits = 0
    LB.AddWant(lb, { name = "gated", prio = 50, applies = function(lab) return lab.ok end, onOrder = function() hits = hits + 1 end,
        pick = function() return 3 end })
    LB.AddWant(lb, { name = "fallback", prio = 5, why = "fb", pick = function() return 8 end })
    LB.Service(lb, Lab(1), 0)
    check(Last().d == 8, "applies=false passes the want over")
    local l2 = Lab(2); l2.ok = true
    LB.Service(lb, l2, 0)
    check(Last().d == 3 and hits == 1, "applies=true: ordered, the want's onOrder ran")
    local l3 = Lab(3); l3.ok, l3.skip = true, true
    local before = #log
    LB.Service(lb, l3, 0)
    check(#log == before, "lab.skip: nothing ordered")
    check(seen[1] == "fallback:8:1" and seen[2] == "gated:3:1", "the global onOrder hook sees every order (want, unit, n)")
    check(#echoes == 2 and echoes[1]:find("fb") and echoes[1]:find("u8"), "an order is announced with the want's why label")
    LB.Order(lb, 7, 55, 10)
    check(Last().d == 55 and Last().id == 7, "LB.Order gives an outside order and records it")
    queues[1] = 0
    check(lb.stats.gated == 1 and lb.stats.fallback == 1 and lb.orders == 3, "stats count orders per want (outside orders count as a total)")
    LB.Update(lb, 100000)
    check(echoes[#echoes]:find("%[LB%]") ~= nil, "the periodic [LB] row is written")
end

-- ── registration errors ──
do
    local lb = NewBroker()
    LB.AddWant(lb, { name = "x", pick = function() end })
    check(not pcall(LB.AddWant, lb, { name = "x", pick = function() end }), "a want name registers once")
    check(not pcall(LB.AddWant, lb, { name = "y" }), "a want needs a pick")
    check(not pcall(LB.AddWant, lb, { name = "z", mode = "sideways", pick = function() end }), "a want needs a known mode")
end

print(string.format("lab_broker: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
