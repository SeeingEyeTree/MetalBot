-- bar_framework/line_transition/t2bot_lab.lua
-- A T2 bot lab on the last slots of the line (user 2026-10-16): it makes the T2 bot cons the slot spine's blocks keep (slot_spine
-- BLOCK_CONS) and the cons its T2 jobs need, and it is a lab the spine can count on for decoy commanders (the sink).
-- The site is reserved at the start (a 3x2 block of an outer lane's last slots plus nano slots beside it, so the line never builds
-- there).  Once metal income reaches T2BOT_INCOME (600 m/s: not before, so the early eco is not eaten) a lane builder (a T1 bot con --
-- an AIR con cannot place a T2 lab) is given the job the way the vehicle lab is (LC.QueueJob: the lane's builder, at the far end of its
-- section, which is where these slots are): the nanos beside it first, then the lab.  When it stands the spine adopts it.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  Options read (LT.CFG): T2BOT_LAB T2BOT_INCOME T2BOT_CONS
-- T2BOT_CON_UNIT T2BOT_LAB_UNIT T2BOT_NANOS T2BOT_LANES

local M = {}

function M.Install(X)
    local LT, Clock = X.LT, X.Clock

    -- the last 3 columns x rows 1-2 of the first outer lane whose six slots are all still free, and nano slots in the column before
    local function PickSite(T)
        local LC, C = T.LC, T.CFG
        for _, laneID in ipairs(C.T2BOT_LANES) do
            local lane = T.L.lanes[laneID]
            if lane then
                local at = {}
                for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
                local k0 = (LC.SITE_K_LAST or LC.K_LAST) - 2
                local slots, good = {}, true
                for row = 1, 2 do
                    for k = k0, k0 + 2 do
                        local s = at[row] and at[row][k]
                        if s and s.state == "free" then slots[#slots + 1] = s else good = false end
                    end
                end
                if good then
                    local site = { lane = lane, laneID = laneID, slots = slots, nanos = {}, k0 = k0 }
                    local wx, wz = 0, 0
                    for _, s in ipairs(slots) do wx, wz = wx + s.wx, wz + s.wz end
                    site.wx, site.wz = wx / #slots, wz / #slots
                    for row = 1, 2 do
                        local s = at[row] and at[row][k0 - 1]
                        if s and s.state == "free" and #site.nanos < C.T2BOT_NANOS then site.nanos[#site.nanos + 1] = s end
                    end
                    return site
                end
            end
        end
        return nil
    end

    -- a legal spot for the lab: the site centre, else the nearest legal place within SHIFT elmos of it (the lab is 144 elmos square, the slot
    -- block 192 x 128: it reaches into the lane corridor, and a wind / mex of the next slot can be in the way)
    local SHIFT = 96
    local function Spot(T, site, defID)
        local base = T.BP.RotateFacing(0, T.L.rot)
        local best
        for dx = -SHIFT, SHIFT, 16 do
            for dz = -SHIFT, SHIFT, 16 do
                local d = dx * dx + dz * dz
                if not best or d < best.d then
                    local x, z = T.BP.SnapToBuildGrid(defID, site.wx + dx, site.wz + dz, base)
                    local y = Spring.GetGroundHeight(x, z) or 0
                    local ok = Spring.TestBuildOrder(defID, x, y, z, base)
                    if ok and ok ~= 0 then best = { d = d, x = x, z = z, f = base } end
                end
            end
        end
        if best then return best.x, best.z, best.f end
        return nil
    end

    -- a lane builder (the site's lane first) that can place the lab
    local function Builder(T, defID)
        local order = { T.t2bSite.laneID }
        for _, id in ipairs(T.LC.CON_LANES) do if id ~= order[1] then order[#order + 1] = id end end
        for _, id in ipairs(order) do
            local c = T.LC.LaneBuilder(T.crew, id)        -- the crew's record for the lane's builder
            local b = c and c.id
            local bd = b and Spring.GetUnitDefID(b)
            if bd and T.BP.CanBuild(bd, defID) then return b end
        end
        return nil
    end

    local function UpdateT2BotLab(T, frame, res)
        local C = T.CFG
        if not C.T2BOT_LAB or not T.L then return end
        local def = UnitDefNames[C.T2BOT_LAB_UNIT]
        if not def then return end
        local income = (res and (res.metalIncomeS or res.metalIncome)) or 0
        if not T.t2bSite and T.t2bState ~= "none" then
            local site = PickSite(T)
            if not site then
                T.t2bState = "none"
                Spring.Echo("[LT] " .. Clock(frame) .. " T2 bot lab: no free 3x2 block at the end of an outer lane")
                return
            end
            for _, s in ipairs(site.slots) do s.state = "reserved" end
            for _, s in ipairs(site.nanos) do s.state = "reserved" end
            T.t2bSite, T.t2bState = site, "reserved"
            Spring.Echo(string.format("[LT] %s T2 bot lab site reserved: lane %d, slots k %d-%d (+%d nano slots)", Clock(frame),
                site.laneID, site.k0, site.k0 + 2, #site.nanos))
        end
        if T.t2bState == "reserved" and income >= C.T2BOT_INCOME and frame - (T.t2bTryF or -1e9) >= 300 then
            T.t2bTryF = frame
            local builder = Builder(T, def.id)
            if not builder then
                if frame - (T.t2bLogF or -1e9) >= 1800 then
                    T.t2bLogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " T2 bot lab due: no lane builder can place " .. def.name .. " yet")
                end
                return
            end
            local x, z, f = Spot(T, T.t2bSite, def.id)
            if not x then
                if frame - (T.t2bLogF or -1e9) >= 1800 then
                    T.t2bLogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " T2 bot lab due: no legal spot for " .. def.name)
                end
                return
            end
            for _, s in ipairs(T.t2bSite.nanos) do
                T.LC.QueueJob(T.crew, builder, { name = "cornanotc", x = s.wx, z = s.wz, f = 0, tag = "t2bnano" })
            end
            T.LC.QueueJob(T.crew, builder, { name = def.name, x = x, z = z, f = f, tag = "t2bot" })
            T.t2bState, T.t2bFrame = "queued", frame
            Spring.Echo(string.format("[LT] %s T2 BOT LAB queued: %s at (%d, %d) by lane builder %d, income %.0f", Clock(frame), def.name,
                x, z, builder, income))
        end
        if T.t2bState == "queued" and frame - (T.t2bLogF or T.t2bFrame) >= 900 then       -- still going: say so
            T.t2bLogF = frame
            Spring.Echo(string.format("[LT] %s T2 bot lab still queued/building %ds after the order", Clock(frame), (frame - T.t2bFrame) / 30))
        end
        -- built: hand it to the spine once it runs
        if T.t2bState == "done" and T.t2bLabID and not T.t2bAdopted and T.spineOn and Spring.GetUnitDefID(T.t2bLabID) then
            if T.spineMod.AdoptLab(T.t2bLabID, Spring.GetUnitDefID(T.t2bLabID), C.T2BOT_CONS, C.T2BOT_CON_UNIT) then
                T.t2bAdopted = true
                Spring.Echo(string.format("[LT] %s T2 bot lab %d handed to the spine (%d %s first)", Clock(frame), T.t2bLabID,
                    C.T2BOT_CONS, C.T2BOT_CON_UNIT))
            end
        end
    end

    -- line_crew's job callbacks (LT.OnJobStarted / OnJobDone call these for the "t2bot" / "t2bnano" tags)
    local function JobStarted(T, j)
        local NANO = T.BP.NANO
        if not (NANO and j.unitID) then return end
        local x, _, z = Spring.GetUnitPosition(j.unitID)
        if not x then return end
        local n = 0
        for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
            if NANO.Assist(NANO.PRIO.HANDOFF, nid, j.unitID) then n = n + 1 end
        end
        Spring.Echo(string.format("[LT] %s T2 bot lab frame up: %d nano(s) assisting", Clock(T.frame), n))
    end

    local function JobDone(T, j, state)
        if j.tag == "t2bnano" then
            Spring.Echo(string.format("[LT] %s T2 bot lab nano %s", Clock(T.frame), state))
            return
        end
        if state ~= "done" then
            T.t2bTries = (T.t2bTries or 0) + 1
            Spring.Echo(string.format("[LT] %s T2 bot lab job %s (try %d)", Clock(T.frame), state, T.t2bTries))
            if T.t2bTries >= 3 then
                T.t2bState = "off"
                for _, s in ipairs(T.t2bSite.slots) do s.state = "free" end
                for _, s in ipairs(T.t2bSite.nanos) do s.state = "free" end
            else
                T.t2bState = "reserved"                  -- try again
            end
            return
        end
        T.t2bLabID, T.t2bState = j.unitID, "done"
        Spring.Echo(string.format("[LT] %s T2 BOT LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.t2bFrame or T.frame)) / 30))
    end

    X.UpdateT2BotLab, X.T2BotJobStarted, X.T2BotJobDone = UpdateT2BotLab, JobStarted, JobDone
end

return M
