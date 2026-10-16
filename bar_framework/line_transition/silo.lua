-- bar_framework/line_transition/silo.lua
-- The capstone silo job.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock

    local function SiloWant(T)
        if T.ecoPaused then return 0 end
        local n = 0
        for _, job in ipairs(T.siloPending) do if T.gridFinished[job.key] then n = n + 1 end end
        return n
    end

    -- the silo job's start: the first pending silo of a finished grid this con can place
    local function StartSilo(T, conID)
        local cdef = Spring.GetUnitDefID(conID)
        for i, job in ipairs(T.siloPending) do
            if T.gridFinished[job.key] and T.BP.CanBuild(cdef, UnitDefNames[job.name or "corsilo"].id) then
                table.remove(T.siloPending, i)
                local st = T.BP.New({ layout = { { n = job.name or "corsilo", x = 0, z = 0, f = job.f } } }, conID, job.x, job.z, 0, {})
                st.clearBlockers = true
                Spring.Echo(string.format("[LT] %s %s capstone (grid %d) started at (%d, %d) by con %d", Clock(T.frame),
                    job.name or "corsilo", job.grid, job.x, job.z, conID))
                return st
            end
        end
        return false
    end

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.silo = function(T, cb)
        CB.AddJob(cb, { name = "silo", section = "grid", prio = 90, tier = "t2", useReserve = true,
            sessions = T.siloJobs, paused = function() return T.ecoPaused end,
            want = function() return SiloWant(T) end,
            start = function(id) return StartSilo(T, id) end })
    end
end

return M
