-- bar_framework/air_transport.lua  (2026-10-29)
-- Move one unit with an air transport (user 2026-10-29: picking up nanos, cons and HLLTs and setting them down somewhere else; nothing
-- uses it yet).  What lifts what is the unit's mass against the transport's transportmass (game data, units/*.lua): the Valkyrie (corvalk,
-- 750) lifts a nano (cornanotc, 700) and a con (corck), NOT an HLLT (corhllt, 10200; an LLT is 5100); the T2 transport (corseah, no
-- transportmass = the engine's 100000) lifts the HLLT.  Engine test: tests/engine/transport_test.py (all four cases, 2026-10-29).  A move is two orders to the transport: LOAD_UNITS on the unit, then (queued) UNLOAD_UNIT
-- at the spot.  AT.Update follows each job through its phases and says when it is done or why it failed.
--
--   local AT = VFS.Include("LuaUI/Widgets/bar_framework/air_transport.lua")
--   AT.CanCarry(transportDefID, unitDefID)        -> true | false, why        (unit defs only: size, mass, cantBeTransported)
--   local job, why = AT.Move(transportID, unitID, x, z, frame [, opts])     -> job table, or nil and why
--        opts.timeout (frames, default 45 s) -- the job fails if it is not done by then
--        opts.arrive  (elmos, default 200)   -- "done" = set down within this of (x, z)
--        opts.force   (default false)        -- skip AT.CanCarry and let the engine decide
--   AT.Update(frame)                             -> list of jobs that finished this call (job.state = "done" | "failed", job.why)
--   AT.Job(transportID)                          -> the transport's current job (nil when idle)
--   AT.Cancel(transportID)                       -> stops the transport and forgets its job
-- Job phases: "pickup" (flying to the unit) -> "carrying" (Spring.GetUnitTransporter(unit) == transport) -> "done" (set down at the spot).
-- Failures: the transport or the unit died, the timeout passed, or the transport has nothing left to do and the unit is not at the spot.
-- One job per transport (a T1 transport carries one unit); a new Move on a busy transport replaces its job.

local M = {}

M.CMD_LOAD_UNITS  = (CMD and CMD.LOAD_UNITS) or 75
M.CMD_UNLOAD_UNIT = (CMD and CMD.UNLOAD_UNIT) or 81
M.CMD_STOP        = (CMD and CMD.STOP) or 0
M.TIMEOUT         = 45 * 30
M.ARRIVE          = 200

local jobs = {}          -- [transportID] = job

-- Whether this transport type can lift this unit type, from the unit defs (the engine has the last word: a failed load shows up in Update).
function M.CanCarry(transportDefID, unitDefID)
    local t, u = UnitDefs[transportDefID], UnitDefs[unitDefID]
    if not (t and u) then return false, "unknown unit def" end
    if (t.transportCapacity or 0) <= 0 then return false, t.name .. " is not a transport" end
    if u.cantBeTransported then return false, u.name .. " cannot be transported" end
    local size = math.max(u.xsize or 0, u.zsize or 0) / 2            -- footprint in the engine's transport-size units (16-elmo squares)
    if t.transportSize and t.transportSize > 0 and size > t.transportSize then
        return false, string.format("%s is too big (%d > %d)", u.name, size, t.transportSize)
    end
    if t.transportMass and t.transportMass > 0 and (u.mass or 0) > t.transportMass then
        return false, string.format("%s is too heavy (%.0f > %.0f)", u.name, u.mass or 0, t.transportMass)
    end
    return true
end

function M.Move(transportID, unitID, x, z, frame, opts)
    opts = opts or {}
    local tDef, uDef = Spring.GetUnitDefID(transportID), Spring.GetUnitDefID(unitID)
    if not tDef then return nil, "no transport" end
    if not uDef then return nil, "no unit" end
    if not opts.force then
        local ok, why = M.CanCarry(tDef, uDef)
        if not ok then return nil, why end
    end
    local y = Spring.GetGroundHeight(x, z) or 0
    Spring.GiveOrderToUnit(transportID, M.CMD_LOAD_UNITS, { unitID }, {})
    Spring.GiveOrderToUnit(transportID, M.CMD_UNLOAD_UNIT, { x, y, z }, { "shift" })
    local job = { transport = transportID, unit = unitID, x = x, z = z, startF = frame or 0, state = "pickup",
                  timeout = opts.timeout or M.TIMEOUT, arrive = opts.arrive or M.ARRIVE }
    jobs[transportID] = job
    return job
end

function M.Job(transportID) return jobs[transportID] end

function M.Cancel(transportID)
    if jobs[transportID] and Spring.GetUnitDefID(transportID) then
        Spring.GiveOrderToUnit(transportID, M.CMD_STOP, {}, {})
    end
    jobs[transportID] = nil
end

local function Finish(out, job, state, why, frame)
    job.state, job.why, job.endF = state, why, frame
    jobs[job.transport] = nil
    out[#out + 1] = job
end

function M.Update(frame)
    local out = {}
    for tid, job in pairs(jobs) do
        if not Spring.GetUnitDefID(tid) then
            Finish(out, job, "failed", "transport died", frame)
        elseif not Spring.GetUnitDefID(job.unit) then
            Finish(out, job, "failed", "unit died", frame)
        else
            local carrier = Spring.GetUnitTransporter(job.unit)
            if carrier == tid then
                job.state = "carrying"
                job.loadedF = job.loadedF or frame
            else
                local x, _, z = Spring.GetUnitPosition(job.unit)
                local near = x and (x - job.x) ^ 2 + (z - job.z) ^ 2 <= job.arrive ^ 2
                local busy = (Spring.GetUnitCommandCount and (Spring.GetUnitCommandCount(tid) or 0) > 0)
                if job.state == "carrying" and near then
                    Finish(out, job, "done", nil, frame)
                elseif job.state == "carrying" and not busy then
                    Finish(out, job, "failed", "set down away from the spot", frame)
                elseif job.state == "pickup" and not busy and frame - job.startF > 30 then
                    Finish(out, job, "failed", "the transport dropped the load order", frame)
                end
            end
            if jobs[tid] == job and frame - job.startF > job.timeout then
                Finish(out, job, "failed", "timeout in phase " .. job.state, frame)
            end
        end
    end
    return out
end

return M
