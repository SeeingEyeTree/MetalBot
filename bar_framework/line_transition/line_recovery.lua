-- bar_framework/line_transition/line_recovery.lua
-- Line recovery: rebuild the line's lost nanos.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): LINE_RECOVER LINE_RECOVER_R RECOVER_EVERY RECOVER_SAFE_R

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock
    local ThreatNear = X.ThreatNear     -- grid_recovery

    -- ── LINE_RECOVER (the "linenano" job) ───────────────────────────────────────
    -- Round 3 (user 2026-10-13): after the line is built its builders are released, so a destroyed line nano was never
    -- rebuilt (14 -> 7 nanos by 12:00).  Only the nano spots near a T1 air lab matter (their build power makes the air cons):
    -- a spot that stays empty over two looks with no raid near is rebuilt by a free air con.
    -- queued slots still empty (a stood-up or reclaimed one drops out)
    local function LineNanoWant(T)
        local q, n = T.lineRecQueue, 0
        for i = #q, 1, -1 do
            if q[i].state ~= "free" or q[i].recCon then q[i].recQueued = nil; table.remove(q, i) else n = n + 1 end
        end
        return n
    end

    -- the con holds out of the pool until the nano stands
    local function StartLineNano(T, conID, frame)
        local nanoID = UnitDefNames.cornanotc and UnitDefNames.cornanotc.id
        local s = table.remove(T.lineRecQueue, 1)
        if not (s and nanoID) then return false end
        local y = Spring.GetGroundHeight(s.wx, s.wz) or 0
        Spring.GiveOrderToUnit(conID, -nanoID, { s.wx, y, s.wz, 0 }, {})
        s.recCon, s.recAt = conID, frame
        T.lineRecovered = (T.lineRecovered or 0) + 1
        Spring.Echo(string.format("[LT] %s RECOVER line nano at (%d, %d): con %d rebuilds it (%d so far)",
            Clock(frame), s.wx, s.wz, conID, T.lineRecovered))
        return true
    end

    local function UpdateLineRecovery(T, frame)
        local C = T.CFG
        if not C.LINE_RECOVER or not T.L or not T.L.nanos or frame - (T.lineRecF or -1e9) < C.RECOVER_EVERY then return end
        T.lineRecF = frame
        local nanoID = UnitDefNames.cornanotc and UnitDefNames.cornanotc.id
        if not nanoID then return end
        local labs = {}
        for _, id in ipairs({ T.airLabID, T.lab2 and T.lab2.labID }) do
            if id and Spring.GetUnitDefID(id) then
                local x, _, z = Spring.GetUnitPosition(id)
                if x then labs[#labs + 1] = { x = x, z = z } end
            end
        end
        if #labs == 0 then return end
        for _, s in ipairs(T.L.nanos) do
            if s.state == "nano" then
                s.wasNano = true
            elseif s.state == "free" and s.wasNano then
                local near = false
                for _, lb in ipairs(labs) do
                    if (s.wx - lb.x) ^ 2 + (s.wz - lb.z) ^ 2 <= C.LINE_RECOVER_R ^ 2 then near = true end
                end
                if near and not ThreatNear(T, s.wx, s.wz, C.RECOVER_SAFE_R) then
                    if s.recMiss then
                        -- is it already up (a rebuild that finished)?
                        for _, uid in ipairs(Spring.GetUnitsInCylinder(s.wx, s.wz, 40, T.teamID) or {}) do
                            if Spring.GetUnitDefID(uid) == nanoID then
                                s.state, s.unitID, s.recMiss = "nano", uid, nil
                                if s.recCon then CB.Release(T.CB, s.recCon); s.recCon = nil end
                                s.recQueued = nil
                                if T.crew then T.crew.nNano = (T.crew.nNano or 0) + 1 end
                                break
                            end
                        end
                        if s.recCon and frame - s.recAt > 1800 then      -- the rebuild stalled: give the con back, try again
                            CB.Release(T.CB, s.recCon, true)
                            s.recCon, s.recQueued = nil, nil
                        end
                        if s.state == "free" and not s.recCon and not s.recQueued then
                            s.recQueued = true                            -- the linenano job gives it a con
                            T.lineRecQueue[#T.lineRecQueue + 1] = s
                        end
                    else
                        s.recMiss = frame                              -- first look: confirm on the next one
                    end
                end
            end
        end
    end

    X.UpdateLineRecovery = UpdateLineRecovery

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.linenano = function(T, cb)
        CB.AddJob(cb, { name = "linenano", section = "line", prio = 75, tier = "t1", useReserve = true,
            want = function() return T.CFG.LINE_RECOVER and LineNanoWant(T) or 0 end,
            start = function(id, frame) return StartLineNano(T, id, frame) end,
            onLost = function(id)
                for _, s in ipairs((T.L and T.L.nanos) or {}) do
                    if s.recCon == id then s.recCon, s.recQueued = nil, nil end
                end
            end })
    end
end

return M
