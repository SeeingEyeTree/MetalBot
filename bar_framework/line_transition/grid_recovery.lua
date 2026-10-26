-- bar_framework/line_transition/grid_recovery.lua
-- Grid recovery and audit: remember each grid's mexes, rebuild lost ones, and the periodic audit of grid state.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): AUDIT_EVERY AUDIT_FULL_FUS AUDIT_FULL_MOHO AUDIT_FULL_NANOS GRID_RECOVER RECOVER_EVERY
--   RECOVER_MIN_MEX RECOVER_SAFE_R

local M = {}

function M.Install(X)
    local Clock, Key = X.Clock, X.Key
    local AssignCons, FreeT2 = X.AssignCons, X.FreeT2     -- con_orders

    -- AUDIT_EVERY: what stands in every grid (a read-only count; logs only)
    local function AuditGrids(T, frame)
        local K = T.CFG
        if not K.AUDIT_EVERY or frame % K.AUDIT_EVERY ~= 0 or #T.allAnchors == 0 then return end
        local half = (T.BP.GRID_SPACING or 480) / 2
        local def = { mex = UnitDefNames.cormex and UnitDefNames.cormex.id, moho = UnitDefNames.cormoho and UnitDefNames.cormoho.id,
                      fus = UnitDefNames.corfus and UnitDefNames.corfus.id, nano = UnitDefNames.cornanotc and UnitDefNames.cornanotc.id,
                      win = UnitDefNames.corwin and UnitDefNames.corwin.id }
        local boxes = {}
        for i, g in ipairs(T.allAnchors) do boxes[i] = { ax = g.anchorX, az = g.anchorZ, mex = 0, moho = 0, fus = 0, nano = 0, win = 0 } end
        for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
            local d = Spring.GetUnitDefID(uid)
            local kind
            for k, id in pairs(def) do if id == d then kind = k; break end end
            if kind and not Spring.GetUnitIsBeingBuilt(uid) then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then
                    for _, b in ipairs(boxes) do
                        if math.abs(x - b.ax) <= half and math.abs(z - b.az) <= half then b[kind] = b[kind] + 1; break end
                    end
                end
            end
        end
        local n, noNano, fewNano, fullNano, full, t1, t2, fus, nano, win, someT2 = #boxes, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        local bk = { 0, 0, 0, 0, 0 }        -- grids by finished nanos: 0 | 1 | 2-5 | 6-(full-1) | full  (sums to the grid count)
        for _, b in ipairs(boxes) do
            local i = (b.nano == 0 and 1) or (b.nano == 1 and 2) or (b.nano <= 5 and 3) or (b.nano < K.AUDIT_FULL_NANOS and 4) or 5
            bk[i] = bk[i] + 1
            t1, t2, fus, nano, win = t1 + b.mex, t2 + b.moho, fus + b.fus, nano + b.nano, win + b.win
            if b.nano == 0 then noNano = noNano + 1 end
            if b.nano < 2 then fewNano = fewNano + 1 end
            if b.nano >= K.AUDIT_FULL_NANOS then fullNano = fullNano + 1 end
            if b.moho > 0 then someT2 = someT2 + 1 end
            if b.moho >= K.AUDIT_FULL_MOHO and b.fus >= K.AUDIT_FULL_FUS then full = full + 1 end
        end
        local t2cons = 0
        local t2def = UnitDefNames.coraca and UnitDefNames.coraca.id
        if t2def then
            for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do if Spring.GetUnitDefID(uid) == t2def then t2cons = t2cons + 1 end end
        end
        local nHelp = 0
        for _ in pairs(T.fusHelpers or {}) do nHelp = nHelp + 1 end
        if T.airOrderWhy then
            local parts = {}
            for k, v in pairs(T.airOrderWhy) do parts[#parts + 1] = k .. " " .. v end
            table.sort(parts)
            Spring.Echo(string.format("[AUDIT] %s T1 air con orders so far: %s", Clock(frame), table.concat(parts, ", ")))
        end
        Spring.Echo(string.format("[AUDIT] %s T2 cons alive %d (free %d), retrofits running %d, grids retrofit-eligible %d, retrofitted-started %d, helpers on jobs %d",
            Clock(frame), t2cons, FreeT2(T), #T.upgradeStates, #T.completed, (function() local c = 0 for _ in pairs(T.upgradedKeys) do c = c + 1 end return c end)(), nHelp))
        Spring.Echo(string.format(
            "[AUDIT] %s grids %d | T2 mex %d of %d (%.0f%%) | fusions %d | winds %d | nanos %d (grids by nanos: 0:%d 1:%d 2-5:%d 6-%d:%d all %d:%d) | grids with any T2 %d (%.0f%%), FULLY upgraded %d (%.0f%%)",
            Clock(frame), n, t2, t1 + t2, 100 * t2 / math.max(1, t1 + t2), fus, win, nano, bk[1], bk[2], bk[3], K.AUDIT_FULL_NANOS - 1, bk[4], K.AUDIT_FULL_NANOS, bk[5],
            someT2, 100 * someT2 / n, full, 100 * full / n))
    end

    -- Remember a finished grid's mex spots (merged over re-runs: on a re-run the mexes still standing are "skipped").
    local function RememberGridMexes(T, gs)
        local key = Key(gs.anchorX, gs.anchorZ)
        T.gridMexes = T.gridMexes or {}
        local list = T.gridMexes[key]
        if not list then list = { anchorX = gs.anchorX, anchorZ = gs.anchorZ, spots = {}, have = {} }; T.gridMexes[key] = list end
        for _, it in ipairs(gs.queue) do
            if it.cls == "metal" and it.act ~= "reclaim" and it.status == "built" then
                local sk = math.floor(it.wx) .. "," .. math.floor(it.wz)
                if not list.have[sk] then list.have[sk] = true; list.spots[#list.spots + 1] = { x = it.wx, z = it.wz } end
            end
        end
    end

    -- A finished retrofit's own mex spots (the T2 mexes it built).  2026-10-25: the T1 grid has 22 mexes, the retrofit 18 T2 mexes and
    -- 4 fusions on the corner spots, so a retrofitted grid always had "4 of 22 mex spots empty" against the T1 list -> the retrofit
    -- was re-opened every RECOVER_EVERY, forever (500+ recoveries a game in eco_sim, each holding a T2 con: the fusion push and the
    -- other retrofits starved; real game: income flat at 3.2k from 21:00).  A retrofitted grid is now judged against these.
    local function RememberRetrofitMexes(T, st)
        if not st then return end
        local key = Key(st.anchorX, st.anchorZ)
        T.gridMexes = T.gridMexes or {}
        local list = T.gridMexes[key]
        if not list then list = { anchorX = st.anchorX, anchorZ = st.anchorZ, spots = {}, have = {} }; T.gridMexes[key] = list end
        list.retroSpots, list.retroHave = list.retroSpots or {}, list.retroHave or {}
        for _, it in ipairs(st.queue or {}) do
            if it.cls == "metal" and it.act ~= "reclaim" and it.status == "built" then
                local sk = math.floor(it.wx) .. "," .. math.floor(it.wz)
                if not list.retroHave[sk] then list.retroHave[sk] = true; list.retroSpots[#list.retroSpots + 1] = { x = it.wx, z = it.wz } end
            end
        end
    end

    -- Is any mex of ours (T1 or T2, finished or a frame) standing on this spot?
    local function MexAt(T, x, z)
        for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 40, T.teamID) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and (d.extractsMetal or 0) > 0 then return true end
        end
        return false
    end

    local function ThreatNear(T, x, z, r)
        local mb = T.WG and T.WG.MetalBot
        for _, t in ipairs((mb and mb.threats) or {}) do
            if t.x and (t.x - x) ^ 2 + (t.z - z) ^ 2 <= r * r then return true end
        end
        return false
    end

    local function UpdateRecovery(T, frame)
        local C = T.CFG
        if not C.GRID_RECOVER or not T.gridMexes or frame - (T.recoverF or -1e9) < C.RECOVER_EVERY then return end
        T.recoverF = frame
        -- grids being built, re-run or retrofitted right now are not judged (a retrofit reclaims its T1 mexes on purpose)
        local busy = {}
        for _, gs in ipairs(T.gridStates) do busy[Key(gs.anchorX, gs.anchorZ)] = true end
        for _, us in ipairs(T.upgradeStates) do busy[Key(us.anchorX, us.anchorZ)] = true end
        for _, g in ipairs(T.pendingGrids) do busy[Key(g.anchorX, g.anchorZ)] = true end
        T.recoverMiss = T.recoverMiss or {}
        for key, list in pairs(T.gridMexes) do
            if busy[key] then
                T.recoverMiss[key] = nil
            else
                local gone = 0
                local spots = (T.upgradedKeys[key] and list.retroSpots and #list.retroSpots > 0) and list.retroSpots or list.spots
                local emptyKey = {}
                for _, s in ipairs(spots) do
                    if not MexAt(T, s.x, s.z) then gone = gone + 1; emptyKey[#emptyKey + 1] = math.floor(s.x) .. "," .. math.floor(s.z) end
                end
                emptyKey = table.concat(emptyKey, ";")
                if list.gaveUp == emptyKey then gone = 0 end      -- these spots stayed empty through repeated re-runs: not refillable
                if gone < C.RECOVER_MIN_MEX then
                    T.recoverMiss[key] = nil
                elseif not T.recoverMiss[key] then
                    T.recoverMiss[key] = frame                     -- first look: confirm on the next one
                elseif ThreatNear(T, list.anchorX, list.anchorZ, C.RECOVER_SAFE_R) then
                    -- the raid is still there: wait
                else
                    T.recoverMiss[key] = nil
                    -- the same spots empty again right after a re-run: count it; after RECOVER_SAME_MAX in a row give up on them
                    if list.lastEmpty == emptyKey then list.same = (list.same or 0) + 1 else list.same, list.lastEmpty = 0, emptyKey end
                    local giveUp = list.same >= (C.RECOVER_SAME_MAX or 2)
                    if giveUp then
                        list.gaveUp = emptyKey
                        Spring.Echo(string.format("[LT] %s RECOVER grid (%d, %d): the same %d spots stayed empty after %d re-runs -> left alone",
                            Clock(frame), list.anchorX, list.anchorZ, gone, list.same))
                    end
                    if not giveUp then
                    T.recovered = (T.recovered or 0) + 1
                    if T.upgradedKeys[key] and T.upgradeBP then
                        T.upgradedKeys[key] = nil                  -- retrofit again: the T2 con rebuilds the mohos
                        Spring.Echo(string.format("[LT] %s RECOVER grid (%d, %d): %d of %d mex spots empty -> retrofit re-opened (%d recoveries)",
                            Clock(frame), list.anchorX, list.anchorZ, gone, #list.spots, T.recovered))
                        AssignCons(T)
                    else
                        table.insert(T.pendingGrids, 1, { anchorX = list.anchorX, anchorZ = list.anchorZ,
                                                          rotation = T.gridRotation[key] or 0, recover = true })
                        Spring.Echo(string.format("[LT] %s RECOVER grid (%d, %d): %d of %d mex spots empty -> grid re-run queued first (%d recoveries)",
                            Clock(frame), list.anchorX, list.anchorZ, gone, #list.spots, T.recovered))
                    end
                    end   -- not giveUp
                end
            end
        end
    end

    X.AuditGrids = AuditGrids
    X.RememberRetrofitMexes = RememberRetrofitMexes
    X.RememberGridMexes = RememberGridMexes
    X.ThreatNear = ThreatNear
    X.UpdateRecovery = UpdateRecovery
end

return M
