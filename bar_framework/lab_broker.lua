-- bar_framework/lab_broker.lua  (factory queues: one owner per lab order, a bot lists WANTS, the broker works out the rest)
--
-- A lab controller used to be one long if/else cascade in GameFrame (defence, scouts, floor, roles, army, guards) that also
-- owned the queue mechanics: reading the queue, ordering at the tail or inserting ahead of a busy queue, the grace after an order
-- (a factory's queue reads back late), the "an insert has not started yet" gate.  Every new unit rule meant editing the cascade.
--
-- Now a bot REGISTERS WANTS, each a small rule that says, for one lab, which unit it wants right now (or nothing), and the broker
-- walks them highest priority first and gives the first answer to the lab.  The bot's per-tick facts (counts, room, stall) live in
-- its own context table that the wants read; the per-lab facts (what this lab can build, spine or not) live in the `lab` table the
-- bot hands to Service.  Nothing else orders a lab through here, so grace and pending are always right.
--
--     local LB = VFS.Include("LuaUI/Widgets/bar_framework/lab_broker.lua")
--     local lb = LB.New{ depth = function(lab) return 3 end,
--                        onOrder = function(defID, lab, want, how, frame, n) ... end }   -- bookkeeping for every order
--     LB.AddWant(lb, { name = "scout", prio = 50, mode = "empty",
--         applies = function(lab) return lab.cache and #lab.cache.scouts > 0 end,
--         pick    = function(lab, frame, slot) if ctx.scoutRoom > 0 then return cheapest(lab.cache.scouts) end end })
--     -- every tick, per lab:    LB.Service(lb, lab, frame)
--     -- UnitCreated(builderID): LB.UnitStarted(lb, builderID)       -- an insert has started
--     -- UnitDestroyed(id):      LB.Forget(lb, id)
--
-- Want fields (name and pick required):
--   prio           higher goes first (when the queue is empty, or for a non-"empty" want on any queue)
--   aheadPrio      priority among the wants allowed on a BUSY queue (default prio); the two lists can rank two wants differently
--   mode           "empty"  only when the lab's queue is empty (default);
--                  "ahead"  empty queue: ordered at the tail; busy queue: ONE unit inserted at position 1 (after the unit being
--                           built, so a half-built unit is never thrown away), then no more inserts until a unit starts in that lab
--                           (UnitStarted) or `pendingTimeout` frames pass;
--                  "topup"  the queue holds fewer than `depth` orders: fill it up to depth (a lab that must always have work queued)
--                  "flush"  (2026-10-25, the air-raid AA rush) a busy queue is CLEARED -- the unit in progress too -- once per
--                           `flushKey(lab)` (a raid's id: a new key flushes again), then filled to `depth` with the want's picks;
--                           after that it behaves like "topup".  A nil flushKey never clears.
--   depth          how many orders a tail order places: a number, or function(lab) -> n (default 1).  The broker calls pick again
--                  for each further slot, so a want that wants one unit returns nil from the second call, a want that wants a
--                  full queue of the same unit returns it every time, and the stance's picks differ every call.
--   applies(lab)   cheap filter on the lab (class, holds, stall); evaluated only after the grace check
--   pick(lab, frame, slot) -> defID | nil, why     slot = 1-based queue position the order would take; why overrides the log label
--   grace          frames to leave a lab alone after any order (default cfg.ORDER_GRACE) -- per want, because a spine lab's top-up
--                  retries sooner than the normal wants
--   noPending      an "ahead" insert on a busy queue does not set the pending gate (its own timer limits it)
--   note           false: the bot's onOrder hook is told not to count this order (the want does its own bookkeeping)
--   log            false: no [LB] announce for this want's orders; or function(defID, lab, frame) for a custom line
--   onOrder(defID, lab, n, how, frame)    called for each unit this want orders (n = 1.. within one service), before lb.onOrder
--
-- Fields the bot may set on `lab`: id (required), skip (true: leave the lab alone this tick: leaving, dead).  The broker sets
-- lab.queueLen, lab.empty and lab.nOrdered (orders given in this service so far) before it calls applies/pick.
--
-- External orders (the macro asking the air lab for cons, say) go through LB.Order so the grace and pending gates stay true.
-- Debugging: LB.Status(lb) / the periodic [LB] row lists orders per want.

local LB = {}

LB.CFG = { ORDER_GRACE = 120, PENDING_TIMEOUT = 600, LOG_EVERY = 3600 }

local CMD_OPT_ALT, CMD_OPT_CTRL, CMD_OPT_INTERNAL = 128, 64, 8

-- ── engine access (replaceable for tests) ──────────────────────────────────────

local function DefaultQueueLen(labID)
    local cmds
    if Spring.GetFactoryCommands then cmds = Spring.GetFactoryCommands(labID, -1)
    else cmds = Spring.GetUnitCommands(labID, -1) end
    return (type(cmds) == "table" and #cmds) or 0
end

local function DefaultOrder(labID, defID)
    Spring.GiveOrderToUnit(labID, -defID, {}, {})
end

-- Empty a factory queue, the unit in progress included: a build order with right (dequeue) + ctrl (x20) + shift (x5) takes
-- 100 of that unit off the queue; once per unit type in it.
local function DefaultClear(labID)
    local cmds
    if Spring.GetFactoryCommands then cmds = Spring.GetFactoryCommands(labID, -1)
    else cmds = Spring.GetUnitCommands(labID, -1) end
    local seen = {}
    for _, c in ipairs(type(cmds) == "table" and cmds or {}) do
        local id = c.id
        if id and id < 0 and not seen[id] then
            seen[id] = true
            Spring.GiveOrderToUnit(labID, id, {}, { "right", "ctrl", "shift" })
        end
    end
end

-- Position 1 (after the unit being built) when the lab is working, 0 when idle: position 0 cancels the build in progress.
-- Pattern copied from BAR's own unit_factory_quota.lua.
local function DefaultInsert(labID, defID)
    local INSERT = CMD and CMD.INSERT
    if not INSERT then return DefaultOrder(labID, defID) end
    local _, busyTarget = Spring.GetUnitWorkerTask(labID)
    local pos = busyTarget and 1 or 0
    Spring.GiveOrderToUnit(labID, INSERT, { pos, -defID, (CMD.OPT_ALT or CMD_OPT_ALT) + (CMD.OPT_INTERNAL or CMD_OPT_INTERNAL) },
        (CMD.OPT_ALT or CMD_OPT_ALT) + (CMD.OPT_CTRL or CMD_OPT_CTRL))
end

function LB.New(o)
    o = o or {}
    local cfg = {}
    for k, v in pairs(LB.CFG) do cfg[k] = v end
    for k, v in pairs(o.cfg or {}) do cfg[k] = v end
    return { wants = {}, byName = {}, cfg = cfg, depth = o.depth or 3, last = {}, pending = {}, stats = {}, orders = 0,
             echo = o.echo or function(s) Spring.Echo(s) end, clock = o.clock or tostring,
             queueLen = o.queueLen or DefaultQueueLen, order = o.order or DefaultOrder, insert = o.insert or DefaultInsert,
             clear = o.clear or DefaultClear, flushed = {},
             onOrder = o.onOrder, name = o.unitName or function(d) return (UnitDefs and UnitDefs[d] and UnitDefs[d].name) or tostring(d) end,
             lastLog = -1e9, lastLogOrders = 0, dirty = true }
end

-- ── registry ───────────────────────────────────────────────────────────────────

function LB.AddWant(lb, spec)
    assert(spec.name and spec.pick, "lab_broker want needs name and pick")
    assert(not lb.byName[spec.name], "lab_broker want registered twice: " .. spec.name)
    assert(spec.mode == nil or spec.mode == "empty" or spec.mode == "ahead" or spec.mode == "topup" or spec.mode == "tail"
           or spec.mode == "flush", "lab_broker: bad mode for " .. spec.name)
    spec.mode = spec.mode or "empty"
    spec.prio = spec.prio or 0
    spec.seq = #lb.wants + 1
    lb.wants[spec.seq] = spec
    lb.byName[spec.name] = spec
    lb.stats[spec.name] = 0
    lb.dirty = true
    return spec
end

-- the wants in the order the broker tries them: [all] when the queue is empty, [busy] when it is not
local function Sort(lb)
    local all, busy = {}, {}
    for _, w in ipairs(lb.wants) do
        all[#all + 1] = w
        if w.mode ~= "empty" then busy[#busy + 1] = w end
    end
    table.sort(all, function(a, b) if a.prio ~= b.prio then return a.prio > b.prio end return a.seq < b.seq end)
    local function ap(w) return w.aheadPrio or w.prio end
    table.sort(busy, function(a, b) if ap(a) ~= ap(b) then return ap(a) > ap(b) end return a.seq < b.seq end)
    lb.all, lb.busy, lb.dirty = all, busy, false
end

local function DepthOf(lb, w, lab)
    local d = w.depth
    if type(d) == "function" then d = d(lab) end
    return math.max(1, math.floor(d or 1))
end

-- ── ordering ───────────────────────────────────────────────────────────────────

local function Record(lb, w, defID, lab, how, frame, n)
    lb.last[lab.id] = frame
    lb.orders = lb.orders + 1
    lb.stats[w.name] = (lb.stats[w.name] or 0) + 1
    lab.nOrdered = (lab.nOrdered or 0) + 1
    if w.onOrder then w.onOrder(defID, lab, n, how, frame) end
    if lb.onOrder then lb.onOrder(defID, lab, w, how, frame, n) end
end

-- Give a lab one unit.  how = "tail" or "ahead".  Used by wants (through Service) and by outside systems (LB.Order).
local function Give(lb, defID, lab, how, frame)
    if how == "ahead" then lb.insert(lab.id, defID) else lb.order(lab.id, defID) end
end

-- One lab, once per tick: the first want (by priority) with something to order orders it.  Returns the want's name and the
-- first unit ordered, or nil.
function LB.Service(lb, lab, frame)
    if lab.skip or not lab.id then return nil end
    if lb.dirty then Sort(lb) end
    local id = lab.id
    local len = lb.queueLen(id) or 0
    lab.queueLen, lab.empty, lab.nOrdered = len, len == 0, 0
    local last = lb.last[id]
    local list = len == 0 and lb.all or lb.busy
    for _, w in ipairs(list) do
        local grace = w.grace or lb.cfg.ORDER_GRACE
        local fkey = (w.mode == "flush" and len > 0 and w.flushKey) and w.flushKey(lab) or nil
        local flush = fkey ~= nil and lb.flushed[id] ~= fkey
        if not (last and frame - last < grace) and (not w.applies or w.applies(lab))
           and ((w.mode ~= "topup" and w.mode ~= "flush") or flush or len < DepthOf(lb, w, lab)) then
            local defID, why = w.pick(lab, frame, flush and 1 or len + 1)
            if defID and flush then
                -- clear the queue (the unit in progress too), then fill it from slot 1
                lb.clear(id)
                lb.flushed[id] = fkey
                lb.pending[id] = nil
                len = 0
                lab.queueLen, lab.empty = 0, true
            end
            if defID then
                local label = why or w.why or w.name
                if flush then label = label .. " (queue cleared)" end
                if len > 0 and w.mode == "ahead" then
                    -- a busy queue: one insert, then wait for it to start
                    local p = lb.pending[id]
                    if p and frame - p <= lb.cfg.PENDING_TIMEOUT then return nil end
                    Give(lb, defID, lab, "ahead", frame)
                    if not w.noPending then lb.pending[id] = frame end
                    Record(lb, w, defID, lab, "ahead", frame, 1)
                    LB.Announce(lb, w, defID, lab, label, "ahead", frame, 1)
                    return w.name, defID
                end
                -- the tail: fill the queue to this want's depth (slots len+1 .. depth)
                local depth = DepthOf(lb, w, lab)
                local n = 1
                local first = defID
                Give(lb, defID, lab, "tail", frame)
                Record(lb, w, defID, lab, "tail", frame, n)
                LB.Announce(lb, w, defID, lab, label, "tail", frame, n)
                for slot = len + 2, depth do
                    local more = w.pick(lab, frame, slot)
                    if not more then break end
                    n = n + 1
                    Give(lb, more, lab, "tail", frame)
                    Record(lb, w, more, lab, "tail", frame, n)
                end
                return w.name, first
            end
        end
    end
    return nil
end

function LB.Announce(lb, w, defID, lab, label, how, frame, n)
    if n ~= 1 or w.log == false then return end
    if type(w.log) == "function" then return w.log(defID, lab, frame) end
    local sec = math.floor(frame / 30)
    lb.echo(string.format("[LabCtrl] %d:%02d %-14s %s in %s%s", math.floor(sec / 60), sec % 60, label, lb.name(defID),
        lb.name(lab.defID), how == "ahead" and " (ahead of queue)" or ""))
end

-- An order from outside the wants (the macro's cons for the air lab).  opts.ahead: insert ahead of a busy queue.
function LB.Order(lb, labID, defID, frame, opts)
    opts = opts or {}
    local lab = { id = labID, defID = Spring.GetUnitDefID and Spring.GetUnitDefID(labID), nOrdered = 0 }
    local w = lb.byName.external
    if not w then w = { name = "external", prio = 0, pick = function() end, mode = "ahead", seq = 0, log = false }; lb.byName.external = w; lb.stats.external = 0 end
    local how = opts.ahead and (lb.queueLen(labID) or 0) > 0 and "ahead" or "tail"
    Give(lb, defID, lab, how, frame)
    Record(lb, w, defID, lab, how, frame, 1)
end

-- ── events ─────────────────────────────────────────────────────────────────────

-- a unit started in a lab: its pending insert has been honoured
function LB.UnitStarted(lb, builderID)
    if builderID and lb.pending[builderID] then lb.pending[builderID] = nil end
end

function LB.Forget(lb, labID)
    lb.last[labID], lb.pending[labID], lb.flushed[labID] = nil, nil, nil
end

function LB.Status(lb)
    local names = {}
    for k, n in pairs(lb.stats) do if n > 0 then names[#names + 1] = k end end
    table.sort(names)
    local parts = {}
    for _, k in ipairs(names) do parts[#parts + 1] = string.format("%s %d", k, lb.stats[k]) end
    return string.format("lab orders %d: %s", lb.orders, table.concat(parts, ", "))
end

-- once a tick (cheap): the periodic [LB] row, only when orders were given since the last one
function LB.Update(lb, frame)
    if frame - lb.lastLog < lb.cfg.LOG_EVERY or lb.orders == lb.lastLogOrders then return end
    lb.lastLog, lb.lastLogOrders = frame, lb.orders
    lb.echo(string.format("[LB] %s %s", lb.clock(frame), LB.Status(lb)))
end

return LB
