-- bar_framework/lab_orders.lua  (the "spine API": systems ask the factories for units by tier, the stance loop keeps the rest)
--
-- User 2026-11-01: "I think it is time to add some kind of basic API with priorities to the spine.  The normal orders would just be what the
-- stance is asking for in a loop but there are interrupts and high prio orders ... Building the support groups should be a high prio unless
-- there is a direct threat to the spine."  The stance loop stays where it was (lab_rules' "spine" / "army" wants); the air rush stays the
-- interrupt (lab_rules "air-rush", a flush want).  This module is the request layer between them: a system says "I want N more of these"
-- and the labs that can make them insert them ahead of their queues until the request is met.
--
--   LO.Request(key, { picks = { names, best first }, n = N | function() -> N, tier = "high" | "normal", where = function(lab) -> bool,
--                     held_ok = bool, budget = bool, require = bool })
--       called every tick the system still wants them (a request not renewed for STALE frames is dropped); n = how many MORE the system wants
--       right now; require = false: the spine never plans a lab for it (the lift's transports: the T1 air labs make them)
--   LO.Drop(key)    LO.Status(key) -> { n, queued, building, made }    LO.Wanted() -> { [unitName] = true }   (first picks only a spine lab could make)
--
-- Tiers: "high" = lab_broker want at HIGH_PRIO (147, just under the air rush), one insert per lab per service ahead of its queue, at most PER_LAB of
-- one request waiting in a lab; paused while a raid group is within SPINE_THREAT_R of a spine lab (then the defence / garrison / stance wants act).
-- "normal" = NORMAL_PRIO (60, under the defence floor and the standing roles), same mechanics, never paused.
--
-- The pick: the best pick (first in the list) that any usable lab can build; a lab that cannot build it gives nothing for that request.  So the
-- flak truck is never swapped for a Lasher while a T2 vehicle plant stands, and the Lasher is made when none does (the requester's list decides).
-- Accounting from the queues, not from picks (lab_rules' group-support counted picks the broker then dropped): an insert is recorded per lab and
-- unit type; UnitCreated with that lab as builder moves one to `building`; every tick the recorded inserts are cut to what the lab's real queue
-- still holds of that type (a cleared or lost order drops out at once).  room = n - waiting - building.  The army budget is charged when a unit
-- STARTS (lab_rules' onStart hook), not when it is picked.
--
-- LO.Wanted() is read by slot_spine (SetRequired): a lab that builds a wanted unit is planned even when the stance has no use for it (how the T2
-- vehicle plant comes for the Quakers before the T2 stance).  Logs [LO] rows.  Published as WG.LabOrders.

local M = {}

M.CFG = {
    HIGH_PRIO      = 147,
    NORMAL_PRIO    = 60,
    GRACE          = 15,       -- frames between two orders of these wants in one lab
    PER_LAB        = 1,        -- at most this many inserts of ALL requests waiting (not started) in one lab: an insert goes to position 1, so a second one
                               -- would jump the first (game 2026-11-01: flak inserts kept jumping two waiting Quakers for 2.5 min)
    STALE          = 300,      -- a request not renewed for this many frames is dropped
    SPINE_THREAT_R = 1500,     -- a raid group (mb.raid.groups) this close to a spine lab pauses the high tier
    THREAT_MIN     = 300,      -- ...when worth at least this
    THREAT_TTL     = 300,      -- frames a raid sighting counts
    LOG_EVERY      = 900,
}

local O = {}                  -- Install options
local reqs = {}               -- [key] = request
local keys = {}               -- request keys in registration order
local waiting = {}            -- [labID] = { [defID] = { key, ... } }: inserts not started yet, oldest first
local started = {}            -- [unitID] = key: units started for a request, until finished / dead
local usable = {}             -- [labID] = defID: this tick's labs that may take requests
local paused, pausedLogF = false, -1e9
local lastLog = -1e9

local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function DefOf(name) local d = UnitDefNames and UnitDefNames[name]; return d and d.id end
local function NameOf(defID) local d = UnitDefs[defID]; return d and d.name or tostring(defID) end

local function N(r)
    local n = r.n
    if type(n) == "function" then
        local ok, v = pcall(n)
        n = ok and v or 0
    end
    return math.max(0, math.floor(n or 0))
end

-- this request's inserts waiting in lab `id` (any type), and in all labs
local function WaitingIn(id, key)
    local c = 0
    for _, list in pairs(waiting[id] or {}) do
        for _, k in ipairs(list) do if k == key then c = c + 1 end end
    end
    return c
end
local function WaitingAll(key)
    local c = 0
    for id in pairs(waiting) do c = c + WaitingIn(id, key) end
    return c
end
local function Building(key)
    local c = 0
    for uid, k in pairs(started) do if k == key then c = c + 1 end end
    return c
end

function M.Request(key, spec)
    local r = reqs[key]
    if not r then
        r = { key = key, made = 0, since = Spring.GetGameFrame() }
        reqs[key] = r
        keys[#keys + 1] = key
    end
    r.picks, r.n, r.tier, r.where, r.held_ok, r.budget = spec.picks or {}, spec.n, spec.tier or "high", spec.where, spec.held_ok, spec.budget
    r.require = spec.require ~= false          -- false: never makes the spine plan a lab for it (Wanted)
    r.renewed = Spring.GetGameFrame()
    return r
end

function M.Drop(key)
    if not reqs[key] then return end
    reqs[key] = nil
    for i, k in ipairs(keys) do if k == key then table.remove(keys, i); break end end
end

function M.Status(key)
    local r = reqs[key]
    if not r then return nil end
    return { n = N(r), queued = WaitingAll(key), building = Building(key), made = r.made }
end

-- The best pick of a request that one of this tick's usable labs can build (nil: none can -- slot_spine is asked for the lab).
local function Best(r)
    for _, name in ipairs(r.picks) do
        local id = DefOf(name)
        if id then
            for _, ldef in pairs(usable) do
                if O.BT.Options(ldef)[id] then return id end
            end
        end
    end
    return nil
end

-- the best pick of every live request that no usable lab outside the spine can build (the line's air lab makes the transports: no spine lab for
-- them; only the T2 vehicle plant makes Quakers: the spine keeps one, also once it stands)
function M.Wanted()
    local out = {}
    for _, key in ipairs(keys) do
        local r = reqs[key]
        if r and r.picks[1] and r.spineOnly and r.require then out[r.picks[1]] = true end
    end
    return out
end

-- ── lab_broker wants ──────────────────────────────────────────────────────────

local function Excluded(lab, r)
    if lab.skip or lab.isSink or lab.isRezLab or lab.isSpamLab or lab.isScoutLab or lab.isProxyLab then return true end
    if lab.held and not r.held_ok then return true end
    if r.where and not r.where(lab) then return true end
    return false
end

local function WaitingLab(id)
    local c = 0
    for _, list in pairs(waiting[id] or {}) do c = c + #list end
    return c
end

-- the request of this tier that got a unit least recently (round-robin: two requests on one lab take turns)
local function Pick(tier, lab, frame)
    if tier == "high" and paused then return nil end
    if WaitingLab(lab.id) >= M.CFG.PER_LAB then return nil end
    local pickR
    for _, key in ipairs(keys) do
        local r = reqs[key]
        if r and r.tier == tier and not Excluded(lab, r) and r.best and O.BT.Options(lab.defID)[r.best]
           and N(r) - WaitingAll(key) - Building(key) > 0 then
            if not pickR or (r.lastF or -1e9) < (pickR.lastF or -1e9) then pickR = r end
        end
    end
    if not pickR then return nil end
    local best = pickR.best
    pickR.lastF = frame
    waiting[lab.id] = waiting[lab.id] or {}
    local list = waiting[lab.id][best] or {}
    waiting[lab.id][best] = list
    list[#list + 1] = pickR.key
    return best, "lo-" .. pickR.key
end

local function Applies(lab, tier)
    if tier == "high" and paused then return false end
    for _, key in ipairs(keys) do
        local r = reqs[key]
        if r and r.tier == tier and r.best and not Excluded(lab, r) then return true end
    end
    return false
end

-- add = lab_rules' add (the AIR_AA_GATE wrap) or LB.AddWant bound to the broker; BT = build_tree; onStart(defID, r) = the budget charge
function M.Install(o)
    O = o or {}
    for k, v in pairs(O.cfg or {}) do M.CFG[k] = v end
    reqs, keys, waiting, started, usable = {}, {}, {}, {}, {}
    O.add{ name = "lo-high", prio = M.CFG.HIGH_PRIO, mode = "ahead", grace = M.CFG.GRACE, noPending = true, ignorePending = true, note = false,
           applies = function(lab) return Applies(lab, "high") end,
           pick = function(lab, frame) return Pick("high", lab, frame) end }
    O.add{ name = "lo-normal", prio = M.CFG.NORMAL_PRIO, mode = "ahead", grace = M.CFG.GRACE, noPending = true, ignorePending = true, note = false,
           applies = function(lab) return Applies(lab, "normal") end,
           pick = function(lab, frame) return Pick("normal", lab, frame) end }
    if O.WG then O.WG.LabOrders = { Request = M.Request, Drop = M.Drop, Status = M.Status, Wanted = M.Wanted } end
    Spring.Echo("[LO] lab orders on (high " .. M.CFG.HIGH_PRIO .. ", normal " .. M.CFG.NORMAL_PRIO .. ")")
end

-- ── events ────────────────────────────────────────────────────────────────────

function M.UnitCreated(uid, defID, builderID)
    local w = builderID and waiting[builderID]
    local list = w and w[defID]
    if not (list and #list > 0) then return end
    local key = table.remove(list, 1)
    if #list == 0 then w[defID] = nil end
    local r = reqs[key]
    started[uid] = key
    if r then
        r.made = r.made + 1
        if r.budget ~= false and O.onStart then O.onStart(defID, r) end
    end
end

function M.UnitDone(uid) started[uid] = nil end           -- finished or destroyed
function M.ForgetLab(labID) waiting[labID] = nil end

-- ── tick (lab_rules' GameFrame, before the labs are serviced) ─────────────────

local function QueueCount(labID, defID)
    local cmds = Spring.GetFactoryCommands and Spring.GetFactoryCommands(labID, -1) or Spring.GetUnitCommands(labID, -1)
    local c = 0
    for _, cmd in ipairs(type(cmds) == "table" and cmds or {}) do if cmd.id == -defID then c = c + 1 end end
    return c
end

-- labs = { [labID] = defID } (every finished factory); spine = WG.Spine (IsLab, IsLeaving); mb = WG.MetalBot
function M.Tick(frame, labs, spine, mb)
    -- the labs that may take requests this tick
    usable = {}
    for id, ldef in pairs(labs) do
        local pb = WG and WG.ProxyBase                     -- (a proxy lab takes no requests: slot_spine still plans its own labs for them)
        if Spring.GetUnitDefID(id) and not (spine and spine.IsLeaving and spine.IsLeaving(id)) and not (pb and pb.labs and pb.labs[id]) then usable[id] = ldef end
    end
    -- stale requests out
    for i = #keys, 1, -1 do
        local r = reqs[keys[i]]
        if not r or frame - (r.renewed or 0) > M.CFG.STALE then
            if r then Spring.Echo(string.format("[LO] %s %s dropped (not renewed)", Clock(frame), keys[i])) end
            reqs[keys[i]] = nil
            table.remove(keys, i)
        end
    end
    -- waiting inserts cut to what the real queues hold (a lab that died or was cleared drops its share at once)
    for id, byDef in pairs(waiting) do
        if not usable[id] then waiting[id] = nil
        else
            for defID, list in pairs(byDef) do
                -- the queue also holds the unit in production (its order stays until it finishes): a started unit of this request in this lab counts there
                local q = QueueCount(id, defID)
                local inProd = 0
                for uid, k in pairs(started) do
                    if Spring.GetUnitIsBeingBuilt and Spring.GetUnitIsBeingBuilt(uid) and Spring.GetUnitDefID(uid) == defID then
                        local _, target = Spring.GetUnitWorkerTask(id)
                        if target == uid then inProd = inProd + 1 end
                    end
                end
                local keep = math.max(0, q - inProd)
                while #list > keep do table.remove(list, #list) end
                if #list == 0 then byDef[defID] = nil end
            end
        end
    end
    for uid in pairs(started) do if not Spring.GetUnitDefID(uid) then started[uid] = nil end end
    -- each request's best pick this tick, and whether only the spine can make its first pick
    for _, key in ipairs(keys) do
        local r = reqs[key]
        r.best = Best(r)
        local id = r.picks[1] and DefOf(r.picks[1])
        r.spineOnly = id ~= nil
        if id then
            for lid, ldef in pairs(usable) do
                if not (spine and spine.IsLab and spine.IsLab(lid)) and O.BT.Options(ldef)[id] then r.spineOnly = false; break end
            end
        end
    end
    -- a direct threat to the spine pauses the high tier
    local was = paused
    paused = false
    local rd = mb and mb.raid
    if spine and rd and rd.groups and frame - (rd.frame or -1e9) <= M.CFG.THREAT_TTL then
        local r2 = M.CFG.SPINE_THREAT_R * M.CFG.SPINE_THREAT_R
        for _, g in ipairs(rd.groups) do
            if (g.value or 0) >= M.CFG.THREAT_MIN then
                for id in pairs(usable) do
                    if spine.IsLab and spine.IsLab(id) then
                        local x, _, z = Spring.GetUnitPosition(id)
                        if x and (x - g.x) ^ 2 + (z - g.z) ^ 2 <= r2 then paused = true; break end
                    end
                end
            end
            if paused then break end
        end
    end
    if paused ~= was then
        Spring.Echo(string.format("[LO] %s high tier %s", Clock(frame), paused and "PAUSED: a raid group is at the spine" or "resumed"))
    end
    if frame - lastLog >= M.CFG.LOG_EVERY and #keys > 0 then
        lastLog = frame
        local parts = {}
        for _, key in ipairs(keys) do
            local r = reqs[key]
            parts[#parts + 1] = string.format("%s %s n %d wait %d build %d made %d", key, r.best and NameOf(r.best) or ("no lab for " .. tostring(r.picks[1])),
                N(r), WaitingAll(key), Building(key), r.made)
        end
        Spring.Echo("[LO] " .. Clock(frame) .. (paused and " (high paused) " or " ") .. table.concat(parts, " | "))
    end
end

return M
