-- bar_framework/line_transition/con_orders.lua
-- Ordering constructors from the air lab and the T2 labs: CON_HOLD, the air-con cap, the reserve, who is a T2 con, and handing cons to jobs.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): AIR_CON_AT_BACK AIR_CON_CAP_EARLY AIR_CON_RESERVE AIR_CON_TIMEOUT CONSOL_FUSION_CONS CON_HOLD
--   ENERGY_PUSH EP_CON_FORCE EP_INFLIGHT FUSION_HELPERS IDLE_CON_MAX IDLE_CON_SWEEP RESERVE_COUNT_IDLE T2_CON_RESERVE

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock

    local BT = VFS.Include("LuaUI/Widgets/bar_framework/build_tree.lua")     -- the build tree (C1)
    local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
    local function FindAirConDef(labDefID)
        local d = labDefID and BT.ConMadeBy(labDefID, { air = true })
        return d and d.id or nil
    end

    -- Until the first grid is ~30% built the bot keeps at most AIR_CON_CAP_EARLY air cons (alive + ordered): more
    -- compete with that grid for metal and nanos.
    local function LiftAirConCap(T, why)
        if T.firstGridOK then return end
        T.firstGridOK = true
        Spring.Echo(string.format("[LT] %s air con cap (%d) lifted: %s", Clock(T.frame), T.CFG.AIR_CON_CAP_EARLY, why))
    end

    local function AirConsEarlyFull(T)
        if T.firstGridOK then return false end
        local alive = 0
        for id in pairs(T.airConsAlive) do
            if Spring.GetUnitDefID(id) then alive = alive + 1 else T.airConsAlive[id] = nil end
        end
        local cap = (T.CFG.GRID_START and T.CFG.GRID_START.cap) or T.CFG.AIR_CON_CAP_EARLY
        return alive + T.airConsOrdered >= cap
    end

    -- CON_HOLD: true while the bot wants no constructors from its air labs (logged at most every 30 s).
    local function ConHold(T, frame, what)
        local h = T.CFG.CON_HOLD
        if not h then return false end
        local ok, v = pcall(h)
        if not (ok and v == true) then return false end
        if frame - (T.conHoldLogF or -1e9) >= 900 then
            T.conHoldLogF = frame
            Spring.Echo(string.format("[LT] %s CON HOLD: %s skipped (the air labs answer a ground raid)", Clock(frame), what))
        end
        return true
    end

    -- Every constructor order to a lab goes through here.  With a lab controller that publishes WG.LabBroker the order is the lab
    -- broker's (so its grace / pending gates know about it and two systems never stack orders on one queue); without one (other
    -- bots) it is given directly.  ahead = in front of a busy queue (after the unit in production), else at the tail.
    local function OrderCon(T, labID, defID, frame, ahead)
        CB.OrderCon(T.WG, labID, defID, frame or T.frame or 0, ahead)
    end

    -- T2 cons ordered and not out yet (frames; a lost order times out after AIR_CON_TIMEOUT), so the shortfall counts them as coming.
    local function T2Ordered(T, frame)
        T.t2Orders = T.t2Orders or {}
        while #T.t2Orders > 0 and (frame or 0) - T.t2Orders[1] > T.CFG.AIR_CON_TIMEOUT do table.remove(T.t2Orders, 1) end
        return #T.t2Orders
    end

    -- One T2 con ordered from an advanced lab.  Every T2 order goes through here so the in-flight count is right.
    local function OrderT2Con(T, labID, defID, frame, ahead)
        T2Ordered(T, frame)
        T.t2Orders[#T.t2Orders + 1] = frame or 0
        OrderCon(T, labID, defID, frame, ahead)
    end

    -- How many T2 cons the broker says are still missing (jobs' demand + reserve - ready - ordered).
    local function T2Shortfall(T, frame)
        if not T.CB then return math.huge end          -- (a bare T in a unit test)
        return CB.Shortfall(T.CB, 2, T2Ordered(T, frame), true, frame or 0, T.lastRes)
    end

    -- The T1 air labs that make air cons: the line's air lab and the capstone T1 air labs (AIR_CON_LABS, grid_core), alive and
    -- finished.  A capstone lab's id is found at its site once it stands.
    local function AirConLabs(T)
        local out = {}
        if T.airLabID and Spring.GetUnitDefID(T.airLabID) then out[#out + 1] = T.airLabID end
        for _, c in ipairs(T.capAirLabs or {}) do
            if not (c.id and Spring.GetUnitDefID(c.id)) then
                c.id = nil
                for _, uid in ipairs(Spring.GetUnitsInCylinder(c.x, c.z, 120, T.teamID) or {}) do
                    if Spring.GetUnitDefID(uid) == T.labDefID and not Spring.GetUnitIsBeingBuilt(uid) then c.id = uid; break end
                end
            end
            if c.id and c.id ~= T.airLabID then out[#out + 1] = c.id end
        end
        return out
    end

    local function QueueLen(labID)
        local cmds = Spring.GetFactoryCommands and Spring.GetFactoryCommands(labID, -1) or nil
        return type(cmds) == "table" and #cmds or 0
    end

    local function QueueAirCon(T, frame, why, ahead)
        if AirConsEarlyFull(T) or ConHold(T, frame or 0, "air con") then return end
        if T.CFG.IDLE_CON_SWEEP and (T.idleSurplus or 0) > T.CFG.IDLE_CON_MAX then return end     -- cons stand idle with nothing to assist: no more
        -- the line's air lab, or (AIR_CON_LABS) the T1 air lab with the shortest queue -- also when the line's lab is gone
        local lab = T.airLabID
        local all = AirConLabs(T)
        if #all > 1 or (#all == 1 and all[1] ~= lab) then
            local best, bestN
            for _, id in ipairs(all) do
                local n = QueueLen(id)
                if not bestN or n < bestN then best, bestN = id, n end
            end
            lab = best
        end
        if lab and Spring.GetUnitDefID(lab) and T.airConDefID then
            OrderCon(T, lab, T.airConDefID, frame, ahead or not T.CFG.AIR_CON_AT_BACK)
            T.airConsOrdered = T.airConsOrdered + 1
            T.airOrderWhy = T.airOrderWhy or {}
            T.airOrderWhy[why or "other"] = (T.airOrderWhy[why or "other"] or 0) + 1
            T.orders[#T.orders + 1] = frame
        end
    end

    local function AirConOrderDone(T)
        if #T.orders > 0 then table.remove(T.orders, 1) end
        T.airConsOrdered = math.max(0, T.airConsOrdered - 1)
    end

    -- Before every hand-out: the reserve (cons the labs keep ready, T1 and T2) and the T2 HOLD -- free T2 cons the retrofits must leave
    -- for the fusion jobs: the energy push keeps EP_INFLIGHT, the fusion consolidation CONSOL_FUSION_CONS, an energy cell one, and once
    -- the cap is tight one is always left for the wind blocks (converting wind beats retrofitting another grid at the cap).
    local function SetReserves(T)
        local C = T.CFG
        local keep = 0
        if C.ENERGY_PUSH and T.epBound then keep = math.max(0, C.EP_INFLIGHT - #T.consolidateJobs) end
        if T.consolidateOn and T.epBound and C.FUSION_HELPERS then keep = math.max(keep, C.CONSOL_FUSION_CONS - #T.consolidateJobs) end
        if T.ecellWant then keep = math.max(keep, 1) end
        if T.consolidateOn then keep = math.max(keep, 1) end
        CB.SetReserve(T.CB, 1, C.AIR_CON_RESERVE)
        CB.SetReserve(T.CB, 2, C.T2_CON_RESERVE or 0)
        CB.SetHold(T.CB, 2, keep)
    end

    -- The reserve: T1 air cons ready beyond what the jobs want (con_broker: Unmet + reserve - ready - ordered > 0 -> the lab makes one).
    -- RESERVE_COUNT_IDLE: cons that are only helping (preemptable jobs, idle crew members) count as ready, so idle cons stop being
    -- re-ordered forever; without it only free ones count.
    local function KeepAirConReserve(T, frame, res)
        if T.consolidateOn or not T.airLabID or not T.airConDefID or frame - T.lastReserve < 90 then return end
        if CB.Shortfall(T.CB, 1, T.airConsOrdered, T.CFG.RESERVE_COUNT_IDLE, frame, res) > 0 then
            QueueAirCon(T, frame, "reserve")
            T.lastReserve = frame
        end
    end

    -- A T2 con is one that can build what the upgrade blueprint asks for (same question the placer asks).
    local function IsT2Con(T, defID)
        local bp = T.upgradeBP
        if not (bp and bp.layout and bp.layout[1]) then return false end
        local ud = UnitDefNames[bp.layout[1].n]
        return ud and T.BP.CanBuild(defID, ud.id) or false
    end

    -- Orders n T2 cons spread over the finished advanced air labs: each goes to the lab with the fewest T2 cons already queued there (a lab
    -- builds them one after another, so a batch of 6 on each of the first few labs in unit-id order kept the rest of the labs idle for
    -- minutes -- the main source of run-to-run spread in the vacuum test: 2.8k vs 6.5k income at 20:00 from the same bot).
    -- maxLoad (optional): no lab gets more than that many T2 cons queued.  Returns how many were ordered and the first lab used.  Without EP_CON_FORCE only labs with an empty queue count.
    local function OrderT2Spread(T, frame, n, maxLoad)
        if n <= 0 then return 0 end
        T.t2Sent = T.t2Sent or {}
        local labs = {}
        for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and d.isFactory and uid ~= T.airLabID and not (T.noConLabs and T.noConLabs[uid]) and not Spring.GetUnitIsBeingBuilt(uid) then
                local t2 = FindAirConDef(Spring.GetUnitDefID(uid))
                if t2 and IsT2Con(T, t2) then
                    local q = (Spring.GetFactoryCommands and Spring.GetFactoryCommands(uid, -1)) or {}
                    if type(q) ~= "table" then q = {} end
                    local queued = 0
                    for _, c in ipairs(q) do if c.id == -t2 then queued = queued + 1 end end
                    local sent = T.t2Sent[uid] or {}
                    while #sent > 0 and (frame or 0) - sent[1] > 450 do table.remove(sent, 1) end   -- long enough to show in the queue
                    T.t2Sent[uid] = sent
                    if T.CFG.EP_CON_FORCE or #q == 0 then
                        labs[#labs + 1] = { uid = uid, def = t2, load = math.max(queued, #sent), busy = #q > 0 }
                    end
                end
            end
        end
        if #labs == 0 then return 0 end
        local first, done = nil, 0
        for _ = 1, n do
            local best = labs[1]
            for _, l in ipairs(labs) do if l.load < best.load then best = l end end
            if maxLoad and best.load >= maxLoad then break end
            OrderT2Con(T, best.uid, best.def, frame, best.busy)
            local sent = T.t2Sent[best.uid]
            sent[#sent + 1] = frame or 0
            best.load = best.load + 1
            first = first or best.uid
            done = done + 1
        end
        return done, first
    end

    -- Hand the free cons out now (a session ended, a con arrived, a cell opened); the broker also does it every update.
    local function AssignCons(T, frame)
        if T.CB then CB.Assign(T.CB, frame or T.frame, T.lastRes) end
    end

    local function FreeT2(T) return T.CB and CB.NFree(T.CB, 2) or 0 end

    X.FindAirConDef = FindAirConDef
    X.LiftAirConCap = LiftAirConCap
    X.ConHold = ConHold
    X.T2Ordered = T2Ordered
    X.OrderT2Con = OrderT2Con
    X.T2Shortfall = T2Shortfall
    X.QueueAirCon = QueueAirCon
    X.AirConLabs = AirConLabs
    X.AirConOrderDone = AirConOrderDone
    X.SetReserves = SetReserves
    X.KeepAirConReserve = KeepAirConReserve
    X.IsT2Con = IsT2Con
    X.OrderT2Spread = OrderT2Spread
    X.AssignCons = AssignCons
    X.FreeT2 = FreeT2
end

return M
