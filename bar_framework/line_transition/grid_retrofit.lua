-- bar_framework/line_transition/grid_retrofit.lua
-- Grid retrofits: T2 cons upgrade finished grids (nano turrets, T2 mexes), the T2 top-up/deferred orders and the spend-pressure hand-off.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): BANK_HIGH BANK_LOW GRID_HANDOFF RETROFIT_BANK_GATE RETROFIT_FLOAT_BATCH RETROFIT_FLOAT_CONS
--   RETROFIT_FLOAT_FRAC RETROFIT_HOLD_FRAC RETROFIT_MIN_RUNNING RETROFIT_RESUME_FRAC RETROFIT_STALL_FRAC SPEND_FAST
--   SPEND_SLOW T2_CONS_PER_GRID T2_LAB_DEPTH T2_TOPUP_AHEAD T2_TOPUP_METAL_FRAC UPGRADE_CONS_PER_LAB

local M = {}

function M.Install(X)
    local CB, Clock, Key = X.CB, X.Clock, X.Key
    local CMD_STOP = X.CMD_STOP
    local ConHold, T2Ordered, OrderT2Con, T2Shortfall, OrderT2Spread, FreeT2 = X.ConHold, X.T2Ordered, X.OrderT2Con, X.T2Shortfall, X.OrderT2Spread, X.FreeT2     -- con_orders

    -- Finished grids waiting for a T2 con to retrofit them.
    local function RetrofitsWaiting(T)
        local n = 0
        for _, a in ipairs(T.completed) do
            local k = Key(a.anchorX, a.anchorZ)
            if T.gridFinished[k] and not T.upgradedKeys[k] then n = n + 1 end
        end
        return n
    end

    -- The retrofit job's start: the nearest finished grid not yet retrofitted (a grid still building would compete with its own retrofit).
    local function StartRetrofit(T, conID)
        local cx, _, cz = Spring.GetUnitPosition(conID)
        local best, bestD2, bestKey = nil, math.huge, nil
        for _, a in ipairs(T.completed) do
            local key = Key(a.anchorX, a.anchorZ)
            if T.gridFinished[key] and not T.upgradedKeys[key] then
                local dx, dz = (cx or 0) - a.anchorX, (cz or 0) - a.anchorZ
                local d2 = dx * dx + dz * dz
                if d2 < bestD2 then best, bestD2, bestKey = a, d2, key end
            end
        end
        if not best then return false end
        T.upgradedKeys[bestKey] = true
        local st = T.BP.New(T.upgradeBP, conID, best.anchorX, best.anchorZ, T.gridRotation[bestKey] or 0, T.BP.GRID_INTERRUPTS)
        st.clearBlockers = true                      -- reclaim the mex/winds the fusions need
        st.clearOnlyDefIDs = {}
        for _, n in ipairs({ "corwin", "cormex" }) do
            local ud = UnitDefNames[n]
            if ud then st.clearOnlyDefIDs[ud.id] = true end
        end
        st.handoffProgress = T.CFG.GRID_HANDOFF
        Spring.Echo(string.format("[LT] %s retrofit started at (%d, %d) by con %d", Clock(T.frame), best.anchorX, best.anchorZ, conID))
        return st
    end

    -- A retrofit must never compete with a normal grid for metal (T2 mexes earn less per metal): while stalling,
    -- retrofit builders are stopped.
    -- RETROFIT_FLOAT_CONS (the retrofit job's `produce`): metal floats and finished grids wait for a retrofit with no T2 con free:
    -- idle advanced labs make more.
    -- T2 cons are built ONLY on demand (user, 2026-10-14): a finished advanced lab orders none by itself.  This is the retrofit job's
    -- `produce`: it runs when finished grids wait for a retrofit and no T2 con is free; the orders are capped by the broker's shortfall
    -- (jobs' demand + reserve - ready - already ordered).  RETROFIT_FLOAT_CONS adds the metal-float gate (RETROFIT_FLOAT_FRAC).
    local function UpdateRetrofitCons(T, frame, res)
        if frame % 150 ~= 0 or not T.upgradeBP or FreeT2(T) > 0 then return end
        if frame - (T.retroConFrame or -1e9) < 450 then return end       -- let the last order's cons arrive before ordering again
        if ConHold(T, frame, "retrofit T2 cons") then return end
        if T.CFG.RETROFIT_FLOAT_CONS and (res.metalStorage <= 0 or res.metal / res.metalStorage < (T.CFG.RETROFIT_FLOAT_FRAC or 0.2)) then return end
        local waiting = RetrofitsWaiting(T)
        if waiting == 0 then return end
        T.floatConsOrdered = T.floatConsOrdered or 0
        -- what the broker says is short, shared out over the labs (at most T2_LAB_DEPTH queued on each)
        local want = math.min(waiting, math.max(0, T2Shortfall(T, frame)))
        local ordered = OrderT2Spread(T, frame, want, T.CFG.T2_LAB_DEPTH)
        if ordered > 0 then
            T.retroConFrame = frame
            T.floatConsOrdered = T.floatConsOrdered + ordered
            Spring.Echo(string.format("[LT] %s RETROFIT CONS: metal %.0f/%.0f floats, %d grid(s) waiting -> %d T2 con(s) ordered (%d so far)",
                Clock(frame), res.metal, res.metalStorage, waiting, ordered, T.floatConsOrdered))
        end
    end

    -- up-front T2 cons of a lab that finished while the air labs answered a ground raid (CON_HOLD): ordered when the hold ends
    local function UpdateT2Deferred(T, frame)
        if not T.t2Deferred or frame % 60 ~= 0 or ConHold(T, frame, "up-front T2 cons") then return end
        for id, t2 in pairs(T.t2Deferred) do
            T.t2Deferred[id] = nil
            if Spring.GetUnitDefID(id) then
                for _ = 1, T.CFG.UPGRADE_CONS_PER_LAB do OrderT2Con(T, id, t2, frame) end
            end
        end
    end

    -- T2_CONS_PER_GRID: demand-driven T2 cons stop once every finished grid has its retrofit con, but a retrofit with one builder takes minutes
    -- and the late game floats metal: keep T2_CONS_PER_GRID cons per finished grid, ordered over the labs while the bank is healthy.
    local function UpdateT2TopUp(T, frame, res)
        local K = T.CFG
        if not K.T2_CONS_PER_GRID or not T.upgradeBP or T.ecoPaused or frame % 150 ~= 0 then return end
        if frame - (T.t2TopFrame or -1e9) < 450 then return end
        if res.metalStorage <= 0 or res.metal / res.metalStorage < K.T2_TOPUP_METAL_FRAC then return end
        local grids = 0
        for _, a in ipairs(T.completed) do if T.gridFinished[Key(a.anchorX, a.anchorZ)] then grids = grids + 1 end end
        -- T2_TOPUP_AHEAD: grids with this share of their mexes standing count too, so the T2 cons are there when the grid turns eligible (a T2 con
        -- takes ~50 s to build and the retrofit waited for it: 2 T2 cons at 12:00 with 10 grids eligible); the number is nanos standing in the grid
        if K.T2_TOPUP_AHEAD then
            for _, gs in ipairs(T.gridStates) do
                if not gs.done and not T.gridFinished[Key(gs.anchorX, gs.anchorZ)] then
                    local n = 0
                    for _, it in ipairs(gs.queue) do
                        if it.cls == "nano" and it.act ~= "reclaim" and (it.built or it.status == "built") then n = n + 1 end
                    end
                    if n >= K.T2_TOPUP_AHEAD then grids = grids + 1 end
                end
            end
        end
        local have = CB.Count(T.CB, 2) + T2Ordered(T, frame)
        local n = math.min(K.RETROFIT_FLOAT_BATCH or 6, math.floor(K.T2_CONS_PER_GRID * grids) - have)
        if n <= 0 or ConHold(T, frame, "T2 top-up") then return end
        local ordered = OrderT2Spread(T, frame, n, K.T2_LAB_DEPTH)
        if ordered > 0 then
            T.t2TopFrame = frame
            Spring.Echo(string.format("[LT] %s T2 TOP-UP: %d T2 cons for %d finished grids (%d alive/ordered) -> %d ordered", Clock(frame), math.floor(K.T2_CONS_PER_GRID * grids), grids, have, ordered))
        end
    end

    -- The retrofit sessions themselves are run by the broker; this is the stall rule.
    local function UpdateRetrofits(T, frame, res)
        local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 1
        if not T.retrofitPaused and mFrac < T.CFG.RETROFIT_STALL_FRAC then
            T.retrofitPaused = true
            for _, us in ipairs(T.upgradeStates) do
                if us.builderID and Spring.GetUnitDefID(us.builderID) then
                    Spring.GiveOrderToUnit(us.builderID, CMD_STOP, {}, {})
                    us.currentTask = nil
                end
            end
        elseif T.retrofitPaused and mFrac > T.CFG.RETROFIT_RESUME_FRAC then
            T.retrofitPaused = false
        end
    end

    -- Under-spending means too few frames are open at once: hand frames to the nanos sooner so the builder places
    -- the next one.  Short on metal, the opposite (finish what is started).  Income above pull = under-spending.
    local function UpdateSpendPressure(T, res)
        local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
        local underSpending = res.metalIncome > res.metalPull * 1.05
        local handoff = T.CFG.GRID_HANDOFF
        if mFrac < T.CFG.BANK_LOW and not underSpending then handoff = T.CFG.SPEND_SLOW
        elseif underSpending or mFrac > T.CFG.BANK_HIGH then handoff = T.CFG.SPEND_FAST end
        for _, st in ipairs(T.gridStates)    do st.handoffProgress = handoff end
        for _, st in ipairs(T.upgradeStates) do st.handoffProgress = handoff end
    end

    X.RetrofitsWaiting = RetrofitsWaiting
    X.UpdateRetrofitCons = UpdateRetrofitCons
    X.UpdateT2Deferred = UpdateT2Deferred
    X.UpdateT2TopUp = UpdateT2TopUp
    X.UpdateRetrofits = UpdateRetrofits
    X.UpdateSpendPressure = UpdateSpendPressure

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.retrofit = function(T, cb)
        CB.AddJob(cb, { name = "retrofit", section = "grid", prio = 50, tier = "t2",
            -- a floating bank (RETROFIT_HOLD_FRAC of storage) is the best case for retrofits: they may take the cons the hold keeps for the
            -- consolidation / fusion jobs (vacuum test: 60k metal wasted at the cap 15:00-17:00 with 3 retrofits running and 30 T2 cons consolidating)
            useReserve = function()
                local r, f = T.lastRes, T.CFG.RETROFIT_HOLD_FRAC
                return f and r and r.metalStorage > 0 and r.metal / r.metalStorage >= f or false
            end,
            sessions = T.upgradeStates, paused = function() return T.ecoPaused or T.retrofitPaused end,
            preemptMax = 4,                                            -- helpers released for retrofits: a few at a time
            want = function()
                if not T.upgradeBP or T.ecoPaused then return 0 end
                local n = RetrofitsWaiting(T)
                if n > 0 and T.CFG.RETROFIT_BANK_GATE then
                    -- RETROFIT_BANK_GATE: banking (or income above pull) -> open retrofits to spend it; all income spent -> no new ones past the minimum
                    local r = T.lastRes
                    if r and r.metalStorage > 0 and #T.upgradeStates >= T.CFG.RETROFIT_MIN_RUNNING then
                        local banking = r.metal / r.metalStorage >= T.CFG.RETROFIT_BANK_GATE or (r.metalIncome or 0) > (r.metalPull or 0) * 1.02
                        if not banking then return 0 end
                    end
                end
                return n
            end,
            start = function(id) return StartRetrofit(T, id) end,
            onDone = function(st)          -- grid recovery judges a retrofitted grid by the T2 mexes it built (grid_recovery)
                if st.builderID and Spring.GetUnitDefID(st.builderID) then CB.Release(cb, st.builderID) end   -- the default onDone's job
                if T.CFG.GRID_RECOVER and X.RememberRetrofitMexes then X.RememberRetrofitMexes(T, st) end
            end,
            produce = function(frame, res) UpdateRetrofitCons(T, frame, res) end })
    end
end

return M
