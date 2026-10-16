-- bar_framework/line_transition/second_lab.lua
-- The second air lab.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
-- Options read (LT.CFG): LAB2_FRAME LAB2_LATEST LAB2_NANOS LAB2_NANO_HELP SECOND_AIR_LAB

local M = {}

function M.Install(X)
    local CB, LT, Clock = X.CB, X.LT, X.Clock
    local QueueAirCon = X.QueueAirCon     -- con_orders

    -- A 3x2 block of wind / mex / free line slots (never a starter, reserved or dead slot): the fewest mexes first (the real
    -- line is about half mexes, mixed in with the winds), then nearest the first air lab; and LAB2_NANOS slots of the same
    -- kinds beside it, winds first.  Returns { slots, nanos, wx, wz } or nil.
    local function PickLab2Site(T)
        local LC = T.LC
        local ok = function(s) return s and (s.state == "wind" or s.state == "free" or s.state == "mex") end
        local lx, lz
        if T.airLabID then local x, _, z = Spring.GetUnitPosition(T.airLabID); lx, lz = x, z end
        local best
        for _, lane in ipairs(T.L.lanes) do
            local at = {}
            for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
            for k0 = LC.K_FIRST, LC.K_LAST - 2 do
                for r0 = 1, 1 do                -- rows 1-2, as the first air lab (other row pairs may not be adjacent)
                    local slots, good = {}, true
                    for row = r0, r0 + 1 do
                        for k = k0, k0 + 2 do
                            local s = at[row] and at[row][k]
                            if ok(s) then slots[#slots + 1] = s else good = false end
                        end
                    end
                    if good then
                        local wx, wz, mexes = 0, 0, 0
                        for _, s in ipairs(slots) do
                            wx, wz = wx + s.wx, wz + s.wz
                            if s.state == "mex" then mexes = mexes + 1 end
                        end
                        wx, wz = wx / 6, wz / 6
                        local d = (lx and math.sqrt((wx - lx) ^ 2 + (wz - lz) ^ 2) or 0) + mexes * 100000
                        if not best or d < best.d then
                            best = { d = d, lane = lane, slots = slots, wx = wx, wz = wz, k0 = k0, r0 = r0, mexes = mexes }
                        end
                    end
                end
            end
        end
        if not best then return nil end
        local inLab = {}
        for _, s in ipairs(best.slots) do inLab[s] = true end
        local cands = {}
        for _, s in ipairs(best.lane.slots) do
            if ok(s) and not inLab[s] and s.row >= best.r0 and s.row <= best.r0 + 1
               and (s.k == best.k0 - 1 or s.k == best.k0 + 3 or s.k == best.k0 - 2 or s.k == best.k0 + 4) then
                cands[#cands + 1] = { s = s, d = math.abs(s.k - (best.k0 + 1)) + (s.state == "mex" and 10 or 0) }
            end
        end
        table.sort(cands, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.s.row < b.s.row end)
        best.nanos = {}
        for i = 1, math.min(T.CFG.LAB2_NANOS, #cands) do best.nanos[i] = cands[i].s end
        return best
    end

    -- Planning: is the second lab due, and where would it go?  (T.lab2Site; the "lab2" job gives it a con.)
    local function UpdateSecondLab(T, frame, res)
        local C = T.CFG
        if not C.SECOND_AIR_LAB or not T.labDefID or not T.airLabID then T.lab2Site = nil; return end
        local L2 = T.lab2
        if not L2 then
            T.lab2Site = nil
            if frame < C.LAB2_FRAME then return end
            if T.LC.SlotsRemaining(T.L) > 0 and frame < C.LAB2_LATEST then return end
            local site = PickLab2Site(T)
            if not site then
                if frame - (T.lab2LogF or -1e9) >= 900 then
                    T.lab2LogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " second air lab: no 3x2 block of built line slots")
                end
                return
            end
            T.lab2Site = site
            -- no con to take the job (all on grids, none idle or helping, none on the way): the lab makes one for it
            if CB.Available(T.CB, 1, true) + T.airConsOrdered == 0 then QueueAirCon(T, frame, "lab2", true) end
            if not T.lab2Logged then
                T.lab2Logged = true
                Spring.Echo("[LT] " .. Clock(frame) .. " second air lab due: an air con is wanted for it")
            end
            return
        end
        if L2.st and not L2.st.done and L2.st.builderID and Spring.GetUnitDefID(L2.st.builderID) then
            -- LAB2_NANO_HELP (round 3): every nano in reach reclaims the winds / mexes in the way, then builds the lab frame
            local NANO = T.BP.NANO
            if C.LAB2_NANO_HELP and NANO and frame % 60 == 0 then
                local lab
                for _, uid in ipairs(Spring.GetUnitsInCylinder(L2.x, L2.z, 60, T.teamID) or {}) do
                    if Spring.GetUnitDefID(uid) == T.labDefID then lab = uid; break end
                end
                if lab then
                    L2.labID = lab
                    for _, nid in ipairs(T.BP.NanosInRange(L2.x, L2.z) or {}) do NANO.Guard(NANO.PRIO.BALANCE, nid, lab) end
                else
                    local windID = T.windDefID or (UnitDefNames.corwin or {}).id
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(L2.x, L2.z, 220, T.teamID) or {}) do
                        local did = Spring.GetUnitDefID(uid)
                        if did == windID or did == (UnitDefNames.cormex or {}).id then
                            local x, _, z = Spring.GetUnitPosition(uid)
                            for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, nid, uid) end
                        end
                    end
                end
            end
        end
    end

    -- The lab2 job: one con while the lab is due; later one more if the lab's builder dies mid-job (it then takes the session over).
    local function Lab2Want(T)
        local L2 = T.lab2
        if not L2 then return T.lab2Site and 1 or 0 end
        local st = L2.st
        if st and not st.done and st.builderID and not Spring.GetUnitDefID(st.builderID) then return 1 end
        return 0
    end

    local function StartLab2(T, conID, frame)
        local L2 = T.lab2
        if L2 then                                           -- its con died: this one takes the job over
            L2.st.builderID, L2.st.currentTask = conID, nil
            Spring.Echo(string.format("[LT] %s second air lab: builder died, con %d takes over", Clock(frame), conID))
            return true
        end
        local site = T.lab2Site
        if not site then return false end
        local x, z, f = LT.LabSpot(T, site)
        if not x then
            -- the winds still stand there: TestBuildOrder fails, so place it on the slot centre and let the placer clear it
            x, z = T.BP.SnapToBuildGrid(T.labDefID, site.wx, site.wz, T.BP.RotateFacing(0, T.L.rot))
            f = T.BP.RotateFacing(0, T.L.rot)
        end
        for _, s in ipairs(site.slots) do s.state = "reserved" end
        for _, s in ipairs(site.nanos) do s.state = "reserved" end
        local layout = {}
        for _, s in ipairs(site.nanos) do layout[#layout + 1] = { n = "cornanotc", x = s.wx - x, z = s.wz - z, f = 0 } end
        layout[#layout + 1] = { n = UnitDefs[T.labDefID].name, x = 0, z = 0, f = f }
        local st = T.BP.New({ layout = layout }, conID, x, z, 0, {})
        st.clearBlockers = true
        st.clearOnlyDefIDs = { [(UnitDefNames.corwin or {}).id or -1] = true, [(UnitDefNames.cormex or {}).id or -1] = true }
        T.lab2 = { st = st, x = x, z = z, site = site, since = frame }
        T.lab2Site = nil
        Spring.Echo(string.format("[LT] %s SECOND AIR LAB: %s at (%d, %d), %d line slots reserved (%d of them mexes) + %d nanos, built by con %d",
            Clock(frame), UnitDefs[T.labDefID].name, x, z, #site.slots, site.mexes or 0, #site.nanos, conID))
        return st
    end

    X.PickLab2Site = PickLab2Site
    X.UpdateSecondLab = UpdateSecondLab

    -- con_broker jobs (registered by line_transition's RegisterJobs, in priority-table order)
    X.jobs = X.jobs or {}
    X.jobs.lab2 = function(T, cb)
        CB.AddJob(cb, { name = "lab2", section = "line", prio = 78, tier = "t1", useReserve = true,
            sessions = T.lab2Sessions,
            want = function() return Lab2Want(T) end,
            start = function(id, frame) return StartLab2(T, id, frame) end,
            onOrphan = function(st) return T.lab2 ~= nil and T.lab2.st == st end,     -- wait for a new builder (it takes the job over)
            onDone = function(st, frame)
                local L2 = T.lab2
                if L2 and L2.st == st and not L2.logged then
                    L2.logged = true
                    Spring.Echo(string.format("[LT] %s second air lab site done (lab %s)", Clock(frame), tostring(L2.labID)))
                end
                if st.builderID and Spring.GetUnitDefID(st.builderID) then CB.Release(cb, st.builderID) end
            end })
    end
end

return M
