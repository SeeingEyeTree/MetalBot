-- bar_framework/line_transition/energy.lua
-- The energy push: unit-cap pressure, wind blocks and reclaim, consolidation (wind -> fusions / T2 mexes), fusion helpers.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): CAP_SLACK_FRAC CONSOLIDATE_MAX CONSOLIDATE_SCAN CONSOLIDATE_SLACK CONSOL_FALLING ENERGY_BUILDING
--   ENERGY_PRIORITY ENERGY_PUSH EP_BANK_SECONDS EP_CON_BATCH EP_CON_EVERY EP_EFRAC EP_EPULL EP_EVERY EP_INFLIGHT EP_MFRAC
--   EP_MIN_METAL EP_RATIO EP_RATIO_MIN_INCOME EP_START FUSION_HELPERS RECLAIM_BUDGET_FRAC RECLAIM_TRIGGER_FRAC
--   TIGHT_FLOAT_FRAC TIGHT_FLOAT_FRAMES TIGHT_FLOAT_START TIGHT_ON_FLOAT WIND_LATTICE

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock
    local CMD_GUARD = X.CMD_GUARD
    local ConHold, T2Shortfall, OrderT2Spread, AssignCons = X.ConHold, X.T2Shortfall, X.OrderT2Spread, X.AssignCons     -- con_orders
    local AddCompleted = X.AddCompleted     -- grid_core
    local HelperRoom = X.HelperRoom     -- grid_helpers
    local RetrofitsWaiting = X.RetrofitsWaiting     -- grid_retrofit

    local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")     -- spend / energy / unit-cap questions (C3)
    local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
    local function CapSlack(T, absolute) return LEDGER.CapSlack(T.teamID, T.CFG.CAP_SLACK_FRAC, absolute) end

    -- Every unclaimed 2x2 block of finished winds, in one pass (winds sit on a global 48-elmo lattice).
    local function ScanWindBlocks(T)
        if not T.windDefID then return end
        T.windBlocks = {}
        local at = {}
        for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
            if Spring.GetUnitDefID(uid) == T.windDefID and not Spring.GetUnitIsBeingBuilt(uid) then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then at[math.floor(x + 0.5) .. "," .. math.floor(z + 0.5)] = uid end
            end
        end
        local L, taken = T.CFG.WIND_LATTICE, {}
        for key in pairs(at) do
            if #T.windBlocks >= T.CFG.CONSOLIDATE_MAX then break end
            local sx, sz = key:match("(-?%d+),(-?%d+)")
            local x, z = tonumber(sx), tonumber(sz)
            local k2, k3, k4 = (x + L) .. "," .. z, x .. "," .. (z + L), (x + L) .. "," .. (z + L)
            if at[k2] and at[k3] and at[k4] and not (taken[key] or taken[k2] or taken[k3] or taken[k4]) then
                local cx, cz = x + L / 2, z + L / 2
                local ckey = math.floor(cx) .. "," .. math.floor(cz)
                if not T.consolidatedKeys[ckey] then
                    taken[key], taken[k2], taken[k3], taken[k4] = true, true, true, true
                    T.windBlocks[#T.windBlocks + 1] = { cx = cx, cz = cz, key = ckey, winds = { at[key], at[k2], at[k3], at[k4] } }
                end
            end
        end
    end

    -- Condemn a rationed number of winds and put every nano that can reach each one on reclaiming it (rationed: the
    -- energy loss must not be a cliff).
    local function UpdateWindReclaim(T)
        local NANO = T.BP.NANO
        if not NANO then return end
        T.windDefID = T.windDefID or (UnitDefNames["corwin"] and UnitDefNames["corwin"].id)
        if not T.windDefID then return end
        local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)
        local cnt  = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(T.teamID)
        if not (maxU and cnt) or (maxU - cnt) > maxU * T.CFG.RECLAIM_TRIGGER_FRAC then return end
        local active = 0
        for wid in pairs(T.reclaimingWinds) do
            if Spring.GetUnitDefID(wid) then active = active + 1 else T.reclaimingWinds[wid] = nil end
        end
        local budget = math.max(1, math.floor(maxU * T.CFG.RECLAIM_BUDGET_FRAC))
        if active >= budget then return end
        for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
            if active >= budget then break end
            if Spring.GetUnitDefID(uid) == T.windDefID and not T.reclaimingWinds[uid] and not Spring.GetUnitIsBeingBuilt(uid) then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then
                    local used = 0
                    for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
                        if NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nid, uid) then used = used + 1 end
                    end
                    if used > 0 then T.reclaimingWinds[uid], active = true, active + 1 end
                end
            end
        end
    end

    local function StartConsolidation(T, conID, res, forceName)
        local block
        while #T.windBlocks > 0 do
            local b = table.remove(T.windBlocks, 1)
            if not T.consolidatedKeys[b.key] then block = b; break end
        end
        if not block then return false end
        -- Replace the block with whichever resource is scarcer right now (the energy push always wants a fusion).
        local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 1
        local eFrac = res.energyStorage > 0 and res.energy / res.energyStorage or 1
        local name = forceName or ((eFrac <= mFrac) and "corfus" or "cormoho")
        local ud = UnitDefNames[name]
        if not ud or not T.BP.CanBuild(Spring.GetUnitDefID(conID), ud.id) then
            table.insert(T.windBlocks, 1, block)          -- this con cannot build it: the block waits for another
            return false
        end
        T.consolidatedKeys[block.key] = true
        -- One-item blueprint; clearBlockers reclaims the four winds, and ONLY winds, to make room.
        local st = T.BP.New({ layout = { { n = name, x = 0, z = 0, f = 0 } } }, conID, block.cx, block.cz, 0, {})
        st.clearBlockers = true
        st.clearOnlyDefIDs = { [T.windDefID] = true }
        Spring.Echo(string.format("[LT] %s consolidating 4 winds at (%d, %d) into %s", Clock(T.frame), block.cx, block.cz, name))
        return st
    end

    local function CheckCapPressure(T, res, frame)
        if T.consolidateOn then
            if T.windDefID then
                for _, gs in ipairs(T.gridStates) do
                    gs.skipDefIDs = gs.skipDefIDs or {}
                    gs.skipDefIDs[T.windDefID] = true
                end
            end
            return
        end
        local capLeft, maxU, cnt = LEDGER.CapLeft(T.teamID)
        -- TIGHT_ON_FLOAT: metal banked at its storage cap means the builders are soaked in low-metal work (winds); the
        -- unit-cap rule below is what moves them onto retrofits / fusions, but it fired at 13:54 in one identical run and
        -- 16:13 in another.  Fire it when the bank has sat above TIGHT_FLOAT_FRAC of storage for TIGHT_FLOAT_FRAMES.
        local floatTight = false
        if T.CFG.TIGHT_ON_FLOAT and res and frame >= T.CFG.TIGHT_FLOAT_START then
            local frac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
            if frac >= T.CFG.TIGHT_FLOAT_FRAC then
                T.floatSince = T.floatSince or frame
                floatTight = frame - T.floatSince >= T.CFG.TIGHT_FLOAT_FRAMES
            else
                T.floatSince = nil
            end
        end
        if not floatTight and (not capLeft or capLeft > CapSlack(T, T.CFG.CONSOLIDATE_SLACK)) then return end
        T.consolidateOn = true
        T.windDefID = UnitDefNames["corwin"] and UnitDefNames["corwin"].id
        -- Every grid becomes retrofit-eligible now, finished or not: a T1->T2 mex upgrade costs no unit slot.
        local marked = 0
        for _, g in ipairs(T.allAnchors) do
            if not T.gridFinished[g.key] then
                T.gridFinished[g.key] = true
                AddCompleted(T, g.anchorX, g.anchorZ)
                marked = marked + 1
            end
        end
        Spring.Echo(string.format("[LT] %s %s (%d/%d): grids stop building wind, consolidation on, %d more grids marked for retrofit",
            Clock(T.frame), floatTight and "metal floating at the cap" or "unit cap tight", cnt or 0, maxU or 0, marked))
        AssignCons(T)
    end

    -- ENERGY PUSH (see LT.CFG): metal floating while energy binds -> wind blocks become fusions.
    local function EnergyBound(T, frame, res)
        local C = T.CFG
        if frame < C.EP_START then return false end
        local mFrac = res.metalStorage > 0 and res.metal / res.metalStorage or 0
        local eFrac = res.energyStorage > 0 and res.energy / res.energyStorage or 1
        local ei = res.energyIncomeS or res.energyIncome or 0
        local ep = res.energyPullS or res.energyPull or 0
        -- EP_BANK_SECONDS: a bank under this many seconds of pull is empty at any scale (half of a 58k store is 2 s of a 15k E/s pull)
        local low = eFrac < C.EP_EFRAC or (C.EP_BANK_SECONDS and res.energy < C.EP_BANK_SECONDS * ep)
        -- EP_RATIO (look-ahead): army units cost ~15 E per metal, so energy income under EP_RATIO x metal income will bind as soon
        -- as the metal is spent -- build energy now instead of after the float starts.
        local mi = res.metalIncomeS or res.metalIncome or 0
        -- ... or the ratio the metal sink asks for: its unit's energy per metal (the ledger's EnergyTarget, registered by metal_sink.lua)
        local ratio = LEDGER.EnergyTarget(T.WG, C.EP_RATIO)
        if ratio and mi >= (C.EP_RATIO_MIN_INCOME or 300) and ei < ratio * mi then return true end
        return mFrac >= C.EP_MFRAC and res.metal >= C.EP_MIN_METAL and low and ep >= C.EP_EPULL * ei
    end

    -- No free T2 con for an energy job: an advanced air lab makes one (it then joins the free pool).  Normally only a lab with
    -- nothing queued; with EP_CON_FORCE any such lab (a bot whose lab controller keeps those queues full never has an idle one).
    local function MakeEnergyT2Con(T, frame, tag)
        local C = T.CFG
        if frame - (T.epConFrame or -1e9) < C.EP_CON_EVERY then return end
        if ConHold(T, frame, tag .. " T2 con") then return end
        local nCon = math.min(C.EP_CON_BATCH or 1, math.max(0, T2Shortfall(T, frame)))     -- never more than the jobs still want
        if nCon == 0 then return end
        local n, lab = OrderT2Spread(T, frame, nCon)       -- spread over the labs; EP_CON_FORCE: ahead of a full queue
        if n > 0 then
            T.epConFrame = frame
            Spring.Echo(string.format("[LT] %s %s: no free T2 con, lab %d makes %d", Clock(frame), tag, lab, n))
        end
    end

    local function UpdateEnergyPush(T, frame, res)
        local C = T.CFG
        if not C.ENERGY_PUSH or frame - (T.epFrame or -1e9) < C.EP_EVERY then return end
        T.epFrame = frame
        T.epBound = EnergyBound(T, frame, res)
        if T.consolidateOn then
            -- consolidation: energy is priority #1 while it binds or its income is falling off its peak (the winds are going)
            local ei = res.energyIncomeS or res.energyIncome or 0
            T.eiPeak = math.max(T.eiPeak or 0, ei)
            if not T.epBound and C.FUSION_HELPERS and ei < C.CONSOL_FALLING * T.eiPeak then T.epBound = true end
            return                                    -- UpdateConsolidation starts the jobs
        end
        if not T.epBound then return end
        if #T.consolidateJobs >= C.EP_INFLIGHT then return end
        ScanWindBlocks(T)                -- the consolidation job (ConsolWant / StartConsolidation) starts them
    end

    -- The consolidation job: wind blocks -> fusions (or T2 mexes), one T2 con per block.  While the energy push binds it is
    -- limited to EP_INFLIGHT blocks at once; once the cap is tight (consolidateOn) every block gets a con.
    local function ConsolForce(T)
        local C = T.CFG
        if not T.consolidateOn then return C.ENERGY_BUILDING or "corfus" end
        return (T.epBound and C.FUSION_HELPERS) and (C.ENERGY_BUILDING or "corfus") or nil     -- energy first: fusions
    end

    local function ConsolWant(T)
        local C = T.CFG
        if T.ecoPaused or #T.windBlocks == 0 then return 0 end
        if T.consolidateOn then return #T.windBlocks end
        if C.ENERGY_PUSH and T.epBound then return math.max(0, math.min(C.EP_INFLIGHT - #T.consolidateJobs, #T.windBlocks)) end
        return 0
    end

    local function StartConsolidationJob(T, conID, frame, res)
        res = res or T.lastRes
        if not res then return false end
        local st = StartConsolidation(T, conID, res, ConsolForce(T))
        if st and not T.consolidateOn then
            T.epStarted = (T.epStarted or 0) + 1
            Spring.Echo(string.format("[LT] %s ENERGY PUSH: wind block -> fusion (metal %.0f/%.0f, energy %.0f/%.0f, pull %.0f of %.0f E/s), %d so far",
                Clock(frame), res.metal, res.metalStorage, res.energy, res.energyStorage,
                res.energyPullS or res.energyPull or 0, res.energyIncomeS or res.energyIncome or 0, T.epStarted))
        end
        return st
    end

    -- no T2 con for the job: an advanced air lab makes one
    local function ConsolProduce(T, frame)
        if not T.consolidateOn then MakeEnergyT2Con(T, frame, "ENERGY PUSH")
        elseif ConsolForce(T) then MakeEnergyT2Con(T, frame, "CONSOLIDATION") end
    end

    local function FusionHelperWant(T)
        local K = T.CFG.FUSION_HELPERS
        if not K or T.ecoPaused or #(T.fusJobs or {}) == 0 then return 0 end
        if K == true then return math.min(64, HelperRoom(T)) end
        local have = {}
        for _, cs in pairs(T.fusHelpers) do have[cs] = (have[cs] or 0) + 1 end
        local n = 0
        for _, cs in ipairs(T.fusJobs) do n = n + math.max(0, K - (have[cs] or 0)) end
        return math.min(n, HelperRoom(T))
    end

    -- every con that is available goes to a fusion job, always the CLOSEST one (a con flying across the map to the "emptiest" job
    -- wastes its time); full jobs (K = a number caps each job; true = no cap) are skipped
    local function StartFusionHelper(T, id)
        local K = T.CFG.FUSION_HELPERS
        local cap = (K == true) and math.huge or K
        local have = {}
        for _, cs in pairs(T.fusHelpers) do have[cs] = (have[cs] or 0) + 1 end
        local x, _, z = Spring.GetUnitPosition(id)
        local pick, bestD
        for _, cs in ipairs(T.fusJobs or {}) do
            if not cs.done and cs.builderID and Spring.GetUnitDefID(cs.builderID) and (have[cs] or 0) < cap then
                local bx, _, bz = Spring.GetUnitPosition(cs.builderID)
                local d = (bx and x) and ((bx - x) ^ 2 + (bz - z) ^ 2) or 0
                if not bestD or d < bestD then pick, bestD = cs, d end
            end
        end
        if not pick then return false end
        Spring.GiveOrderToUnit(id, CMD_GUARD, { pick.builderID }, {})
        T.fusHelpers[id] = pick
        return true
    end

    local function UpdateFusionHelpers(T, frame)
        local K = T.CFG.FUSION_HELPERS
        if not K or frame % 30 ~= 0 then return end
        local jobs = {}
        for _, list in ipairs({ T.consolidateJobs, T.ecellStates or {} }) do
            for _, cs in ipairs(list) do
                if not cs.done and cs.builderID and Spring.GetUnitDefID(cs.builderID) then jobs[#jobs + 1] = cs end
            end
        end
        -- ENERGY_PRIORITY: nanos in reach of a fusion job help its builder, ahead of everything else, while energy stalls
        local NANO = T.BP.NANO
        if T.CFG.ENERGY_PRIORITY and NANO and NANO.PRIO.ENERGY then
            T.energyNanos = T.energyNanos or {}
            local want = T.epBound or T.ecellWant
            for n, cs in pairs(T.energyNanos) do
                local live = false
                for _, j in ipairs(jobs) do if j == cs then live = true; break end end
                if not Spring.GetUnitDefID(n) then
                    T.energyNanos[n] = nil
                elseif not want or not live then
                    local a = NANO.Assignment(n)
                    if a and a.prio == NANO.PRIO.ENERGY then NANO.Release(n) end
                    T.energyNanos[n] = nil
                end
            end
            if want then
                for _, cs in ipairs(jobs) do
                    local x, _, z = Spring.GetUnitPosition(cs.builderID)
                    if x then
                        for _, n in ipairs(T.BP.NanosInRange(x, z) or {}) do
                            if not T.energyNanos[n] and NANO.Guard(NANO.PRIO.ENERGY, n, cs.builderID) then T.energyNanos[n] = cs end
                        end
                    end
                end
            end
        end
        -- no fusion job running: the idle cons help the retrofits instead (T2 mexes are the biggest eco lever left)
        if #jobs == 0 then
            for _, cs in ipairs(T.upgradeStates or {}) do
                if not cs.done and cs.builderID and Spring.GetUnitDefID(cs.builderID) then jobs[#jobs + 1] = cs end
            end
        end
        T.fusJobs = jobs
        -- helpers whose job ended go back to the pool
        for id, cs in pairs(T.fusHelpers) do
            local live = false
            for _, j in ipairs(jobs) do if j == cs then live = true; break end end
            if not Spring.GetUnitDefID(id) then
                T.fusHelpers[id] = nil
            elseif not live then
                T.fusHelpers[id] = nil
                CB.Release(T.CB, id, true)
            end
        end
        local n = 0
        for _ in pairs(T.fusHelpers) do n = n + 1 end
        if n ~= (T.fusHelpersLogged or 0) then
            T.fusHelpersLogged = n
            Spring.Echo(string.format("[LT] %s fusion helpers: %d air cons on %d jobs", Clock(frame), n, #jobs))
        end
    end

    local function UpdateConsolidation(T, frame, res)
        UpdateEnergyPush(T, frame, res)
        if T.consolidateOn and (frame % T.CFG.CONSOLIDATE_SCAN == 0 or #T.windBlocks == 0) then ScanWindBlocks(T) end
        UpdateFusionHelpers(T, frame)
    end

    X.CapSlack = CapSlack
    X.UpdateWindReclaim = UpdateWindReclaim
    X.CheckCapPressure = CheckCapPressure
    X.MakeEnergyT2Con = MakeEnergyT2Con
    X.UpdateConsolidation = UpdateConsolidation

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.consolidate = function(T, cb)
        CB.AddJob(cb, { name = "consolidate", section = "energy", tier = "t2", useReserve = true, prio = 45,   -- after the retrofits, but it may use the T2 hold
            sessions = T.consolidateJobs, paused = function() return T.ecoPaused end,
            want = function() return ConsolWant(T) end,
            start = function(id, frame, res) return StartConsolidationJob(T, id, frame, res) end,
            canTake = function(id)
                local force = ConsolForce(T)
                local ud = force and UnitDefNames[force]
                return not ud or T.BP.CanBuild(Spring.GetUnitDefID(id), ud.id)
            end,
            produce = function(frame) ConsolProduce(T, frame) end })
    end
    X.jobs.fusionhelp = function(T, cb)
        CB.AddJob(cb, { name = "fusionhelp", section = "energy", tier = "any", preemptable = true,
            prio = function() return 30 end,
            want = function() return FusionHelperWant(T) end,
            start = function(id) return StartFusionHelper(T, id) end,
            canTake = function(id, tier)                              -- a T2 con helps only when no wind block or retrofit needs it
                return tier == 1 or (#T.windBlocks == 0 and RetrofitsWaiting(T) == 0)
            end,
            onPreempt = function(id) T.fusHelpers[id] = nil end,
            onLost = function(id) T.fusHelpers[id] = nil end })
    end
end

return M
