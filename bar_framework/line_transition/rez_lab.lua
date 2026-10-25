-- bar_framework/line_transition/rez_lab.lua
-- A T1 bot lab for rez bots on the line (user 2026-10-25: "floor rez bot production ... build one T1 bot lab in the line like a T2 bot lab
-- would be built, just build it early; reserve it in the line and make sure sink labs can't override it").  The starter bot lab is reclaimed
-- early, so without this nothing made rez bots unless a spine slot happened to hold a T1 bot lab.
-- Built the way t2bot_lab.lua builds the T2 bot lab: the site (a 3x2 block of an outer lane's last slots plus nano slots beside it) is
-- RESERVED at the start, so the line, the decoy labs (line_decoy.lua) and the sink never take it; once income and the clock allow, a lane builder
-- is given the job (LC.QueueJob).  The finished lab is NOT adopted by the spine or the sink (it is on the line, not a slot or a sink spot): the
-- lab controller's rez floor (lab_rules REZ_* options) fills it with rez bots.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  Options read (LT.CFG): REZ_LAB REZ_LAB_INCOME REZ_LAB_FRAME
-- REZ_LAB_UNIT REZ_LAB_NANOS REZ_LAB_LANES REZ_LAB_URGENT

local M = {}
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

function M.Install(X)
    local LT, Clock = X.LT, X.Clock

    local function PickSite(T)
        local LC, C = T.LC, T.CFG
        for _, laneID in ipairs(C.REZ_LAB_LANES) do
            local lane = T.L.lanes[laneID]
            if lane then
                local at = {}
                for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
                local k0 = LC.K_LAST - 2
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
                        if s and s.state == "free" and #site.nanos < C.REZ_LAB_NANOS then site.nanos[#site.nanos + 1] = s end
                    end
                    return site
                end
            end
        end
        return nil
    end

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

    local function Builder(T, defID)
        local order = { T.rzSite.laneID }
        for _, id in ipairs(T.LC.CON_LANES) do if id ~= order[1] then order[#order + 1] = id end end
        for _, id in ipairs(order) do
            local c = T.LC.LaneBuilder(T.crew, id)
            local b = c and c.id
            local bd = b and Spring.GetUnitDefID(b)
            if bd and T.BP.CanBuild(bd, defID) then return b end
        end
        return nil
    end

    local function UpdateRezLab(T, frame, res)
        local C = T.CFG
        if not C.REZ_LAB or not T.L then return end
        local def = UnitDefNames[C.REZ_LAB_UNIT]
        if not def then return end
        local income = (res and (res.metalIncomeS or res.metalIncome)) or 0
        if not T.rzSite and T.rzState ~= "none" and T.rzState ~= "off" then
            local site = PickSite(T)
            if not site then
                T.rzState = "none"
                Spring.Echo("[LT] " .. Clock(frame) .. " rez lab: no free 3x2 block at the end of an outer lane")
                return
            end
            for _, s in ipairs(site.slots) do s.state = "reserved" end
            for _, s in ipairs(site.nanos) do s.state = "reserved" end
            T.rzSite, T.rzState = site, "reserved"
            Spring.Echo(string.format("[LT] %s rez lab site reserved: lane %d, slots k %d-%d (+%d nano slots)", Clock(frame),
                site.laneID, site.k0, site.k0 + 2, #site.nanos))
        end
        if T.rzState == "reserved" and income >= C.REZ_LAB_INCOME and frame >= C.REZ_LAB_FRAME and frame - (T.rzTryF or -1e9) >= 300 then
            T.rzTryF = frame
            local builder = Builder(T, def.id)
            if not builder then
                if frame - (T.rzLogF or -1e9) >= 1800 then
                    T.rzLogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " rez lab due: no lane builder can place " .. def.name .. " yet")
                end
                return
            end
            local x, z, f = Spot(T, T.rzSite, def.id)
            if not x then
                if frame - (T.rzLogF or -1e9) >= 1800 then
                    T.rzLogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " rez lab due: no legal spot for " .. def.name)
                end
                return
            end
            for _, s in ipairs(T.rzSite.nanos) do
                T.LC.QueueJob(T.crew, builder, { name = ROLES.Get("nano"), x = s.wx, z = s.wz, f = 0, tag = "rzlnano" })
            end
            T.LC.QueueJob(T.crew, builder, { name = def.name, x = x, z = z, f = f, tag = "rezlab", urgent = C.REZ_LAB_URGENT })
            T.rzState, T.rzFrame = "queued", frame
            Spring.Echo(string.format("[LT] %s REZ LAB queued: %s at (%d, %d) by lane builder %d, income %.0f", Clock(frame), def.name,
                x, z, builder, income))
        end
        if T.rzState == "queued" and frame - (T.rzLogF or T.rzFrame) >= 900 then
            T.rzLogF = frame
            Spring.Echo(string.format("[LT] %s rez lab still queued/building %ds after the order", Clock(frame), (frame - T.rzFrame) / 30))
        end
    end

    local function JobStarted(T, j)
        local NANO = T.BP.NANO
        if not (NANO and j.unitID) then return end
        local x, _, z = Spring.GetUnitPosition(j.unitID)
        if not x then return end
        local n = 0
        for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
            if NANO.Assist(NANO.PRIO.HANDOFF, nid, j.unitID) then n = n + 1 end
        end
        Spring.Echo(string.format("[LT] %s rez lab frame up: %d nano(s) assisting", Clock(T.frame), n))
    end

    local function JobDone(T, j, state)
        if j.tag == "rzlnano" then
            Spring.Echo(string.format("[LT] %s rez lab nano %s", Clock(T.frame), state))
            return
        end
        if state ~= "done" then
            T.rzTries = (T.rzTries or 0) + 1
            Spring.Echo(string.format("[LT] %s rez lab job %s (try %d)", Clock(T.frame), state, T.rzTries))
            if T.rzTries >= 3 then
                T.rzState = "off"
                for _, s in ipairs(T.rzSite.slots) do s.state = "free" end
                for _, s in ipairs(T.rzSite.nanos) do s.state = "free" end
                T.rzSite = nil
            else
                T.rzState = "reserved"
            end
            return
        end
        T.rzLabID, T.rzState = j.unitID, "done"
        Spring.Echo(string.format("[LT] %s REZ LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.rzFrame or T.frame)) / 30))
    end

    X.UpdateRezLab, X.RezLabJobStarted, X.RezLabJobDone = UpdateRezLab, JobStarted, JobDone
end

return M
