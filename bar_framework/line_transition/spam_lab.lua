-- bar_framework/line_transition/spam_lab.lua
-- The spam lab (user 2026-10-30): "a bot lab with 4 nanos that always makes grunts" for the army groups' spam element
-- (bar_framework/support/spam.lua: Grunts run ahead of a group for vision and to soak the first shots).  Built the way rez_lab.lua builds the
-- rez lab: the site (a 3x2 block of an outer lane plus SPAM_LAB_NANOS nano slots in the two columns beside it) is RESERVED at the start, so the
-- line, the decoy labs and the sink never take it (when the line has no free block left, the site goes just past a lane's end: PickBeyondSite); once income and the clock allow AND some group record opts into spam
-- (WG.ArmyGroups.SpamWanted(), the unit controller), a lane builder is given the nanos and the lab (LC.QueueJob).  The finished lab is published
-- as WG.SpamLab = { id }; lab_rules' "spam-lab" want is then the ONLY thing that orders it (lab.only), and only while the element is short.  The
-- nanos guard the lab (nano_broker SPINE priority), so their build power goes into its queue.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  Options read (LT.CFG): SPAM_LAB SPAM_LAB_INCOME SPAM_LAB_FRAME
-- SPAM_LAB_UNIT SPAM_LAB_NANOS SPAM_LAB_LANES SPAM_LAB_URGENT SPAM_LAB_BEYOND_K

local M = {}
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")

local GUARD_EVERY = 300      -- frames between re-guards of the lab by its nanos

function M.Install(X)
    local LT, Clock = X.LT, X.Clock

    -- The first lane (SPAM_LAB_LANES order) with a free 3x2 block whose two columns before it are free too, searched from the lane's end
    -- backwards (the rez lab and the T2 bot lab take the lane ends first).
    local function PickSite(T)
        local LC, C = T.LC, T.CFG
        local last = (LC.SITE_K_LAST or LC.K_LAST)
        for _, laneID in ipairs(C.SPAM_LAB_LANES) do
            local lane = T.L.lanes[laneID]
            if lane then
                local at = {}
                for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
                for k0 = last - 2, last - 8, -1 do
                    local slots, good = {}, true
                    for row = 1, 2 do
                        for k = k0, k0 + 2 do
                            local s = at[row] and at[row][k]
                            if s and s.state == "free" then slots[#slots + 1] = s else good = false end
                        end
                    end
                    local nanos = {}
                    if good then
                        for col = 1, 2 do
                            for row = 1, 2 do
                                local s = at[row] and at[row][k0 - col]
                                if s and s.state == "free" and #nanos < C.SPAM_LAB_NANOS then nanos[#nanos + 1] = s end
                            end
                        end
                    end
                    if good and #nanos >= C.SPAM_LAB_NANOS then
                        local site = { lane = lane, laneID = laneID, slots = slots, nanos = nanos, k0 = k0 }
                        local wx, wz = 0, 0
                        for _, s in ipairs(slots) do wx, wz = wx + s.wx, wz + s.wz end
                        site.wx, site.wz = wx / #slots, wz / #slots
                        return site
                    end
                end
            end
        end
        return nil
    end

    -- No free block on the line (by the grids phase it is usually full -- eco_sim 2026-10-30: two free slots left in all four lanes): the site
    -- goes just PAST the end of a lane instead, on the lane's own spacing (the lab BEYOND_K columns past the last slot, the nanos between).
    -- Nothing reserves that ground; the spots are tested (TestBuildOrder, Spot) when the job is queued.
    local function PickBeyondSite(T)
        local LC, C = T.LC, T.CFG
        local last = LC.K_LAST
        for _, laneID in ipairs(C.SPAM_LAB_LANES) do
            local lane = T.L.lanes[laneID]
            local at = {}
            for _, s in ipairs(lane and lane.slots or {}) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
            local a, b = at[1] and at[1][last], at[1] and at[1][last - 1]
            local r2 = at[2] and at[2][last]
            if a and b then
                local kx, kz = a.wx - b.wx, a.wz - b.wz                 -- one column along the lane
                local rx, rz = 0, 0
                if r2 then rx, rz = r2.wx - a.wx, r2.wz - a.wz end      -- one row across it
                local bk = C.SPAM_LAB_BEYOND_K
                local site = { laneID = laneID, beyond = true, slots = {}, nanos = {}, k0 = last + bk,
                               wx = a.wx + kx * bk + rx * 0.5, wz = a.wz + kz * bk + rz * 0.5 }
                for i = 1, C.SPAM_LAB_NANOS do
                    local col = 1 + math.floor((i - 1) / 2)             -- columns last+1, last+2 ..., two rows each
                    local row = (i - 1) % 2
                    site.nanos[#site.nanos + 1] = { wx = a.wx + kx * col + rx * row, wz = a.wz + kz * col + rz * row }
                end
                return site
            end
        end
        return nil
    end

    local SHIFT = 160      -- elmos round the site Spot searches for a legal build spot (wider than rez_lab's 96: the site past a lane is a guess)
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
        local order = { T.slSite.laneID }
        for _, id in ipairs(T.LC.CON_LANES) do if id ~= order[1] then order[#order + 1] = id end end
        for _, id in ipairs(order) do
            local c = T.LC.LaneBuilder(T.crew, id)
            local b = c and c.id
            local bd = b and Spring.GetUnitDefID(b)
            -- not the commander (lane 1's builder): it put the frame up and walked off to its own work (eco_sim 2026-10-30, unfinished at 13:30)
            local cmdr = bd and UnitDefs[bd] and UnitDefs[bd].customParams and UnitDefs[bd].customParams.iscommander
            if bd and not cmdr and T.BP.CanBuild(bd, defID) then return b end
        end
        return nil
    end

    local function Wanted(T)
        local AG = T.WG and T.WG.ArmyGroups
        return AG ~= nil and AG.SpamWanted ~= nil and AG.SpamWanted()
    end

    local function UpdateSpamLab(T, frame, res)
        local C = T.CFG
        if not C.SPAM_LAB or not T.L then return end
        local def = UnitDefNames[C.SPAM_LAB_UNIT]
        if not def then return end
        local income = (res and (res.metalIncomeS or res.metalIncome)) or 0
        if not T.slSite and T.slState ~= "none" and T.slState ~= "off" then
            local site = PickSite(T)
            local onLine = site ~= nil
            if not site then
                local free = {}          -- which columns were free, per lane (rows 1 + 2), for tuning SPAM_LAB_LANES / the search
                for _, laneID in ipairs(C.SPAM_LAB_LANES) do
                    local lane, ks = T.L.lanes[laneID], {}
                    for _, s in ipairs(lane and lane.slots or {}) do
                        if s.state == "free" and s.row <= 2 then ks[#ks + 1] = s.row .. ":" .. s.k end
                    end
                    free[#free + 1] = laneID .. "[" .. table.concat(ks, " ") .. "]"
                end
                Spring.Echo("[LT] " .. Clock(frame) .. " spam lab: no free 3x2 block (+ nano columns) on the line; free row:k " .. table.concat(free, " "))
                site = PickBeyondSite(T)
            end
            if not site then
                T.slState = "none"
                Spring.Echo("[LT] " .. Clock(frame) .. " spam lab: no site (no lane to build past either)")
                return
            end
            if onLine then
                for _, s in ipairs(site.slots) do s.state = "reserved" end
                for _, s in ipairs(site.nanos) do s.state = "reserved" end
            end
            T.slSite, T.slState = site, "reserved"
            Spring.Echo(string.format("[LT] %s spam lab site %s: lane %d, k %d-%d (+%d nano spots)", Clock(frame),
                onLine and "reserved on the line" or "past the lane's end", site.laneID, site.k0, site.k0 + 2, #site.nanos))
        end
        if T.slState == "reserved" and income >= C.SPAM_LAB_INCOME and frame >= C.SPAM_LAB_FRAME and frame - (T.slTryF or -1e9) >= 300
           and Wanted(T) then
            T.slTryF = frame
            local builder = Builder(T, def.id)
            if not builder then
                if frame - (T.slLogF or -1e9) >= 1800 then
                    T.slLogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " spam lab due: no lane builder can place " .. def.name .. " yet")
                end
                return
            end
            local x, z, f = Spot(T, T.slSite, def.id)
            if not x then
                if frame - (T.slLogF or -1e9) >= 1800 then
                    T.slLogF = frame
                    Spring.Echo("[LT] " .. Clock(frame) .. " spam lab due: no legal spot for " .. def.name)
                end
                return
            end
            T.LC.QueueJob(T.crew, builder, { name = def.name, x = x, z = z, f = f, tag = "spamlab", urgent = C.SPAM_LAB_URGENT })
            local nanoDef = UnitDefNames[ROLES.Get("nano")]
            local nNanos = 0
            for _, s in ipairs(T.slSite.nanos) do
                local nx, nz = s.wx, s.wz
                if T.slSite.beyond then nx, nz = nil, nil; if nanoDef then nx, nz = Spot(T, s, nanoDef.id) end end    -- off the line: a tested spot
                if nx then
                    T.LC.QueueJob(T.crew, builder, { name = ROLES.Get("nano"), x = nx, z = nz, f = 0, tag = "slnano" })
                    nNanos = nNanos + 1
                end
            end
            T.slState, T.slFrame = "queued", frame
            Spring.Echo(string.format("[LT] %s SPAM LAB queued: %s at (%d, %d) + %d nanos by lane builder %d, income %.0f", Clock(frame), def.name,
                x, z, nNanos, builder, income))
        end
        if T.slState == "queued" and frame - (T.slLogF or T.slFrame) >= 900 then
            T.slLogF = frame
            Spring.Echo(string.format("[LT] %s spam lab still queued/building %ds after the order", Clock(frame), (frame - T.slFrame) / 30))
        end
        -- the nanos keep guarding the lab (a nano the broker gave other work comes back once it is free)
        local NANO = T.BP.NANO
        if T.slLabID and NANO and T.slNanoIDs and frame - (T.slGuardF or -1e9) >= GUARD_EVERY then
            T.slGuardF = frame
            if Spring.GetUnitDefID(T.slLabID) then
                for nid in pairs(T.slNanoIDs) do
                    if Spring.GetUnitDefID(nid) then NANO.Guard(NANO.PRIO.SPINE, nid, T.slLabID) else T.slNanoIDs[nid] = nil end
                end
            end
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
        Spring.Echo(string.format("[LT] %s spam lab frame up: %d nano(s) assisting", Clock(T.frame), n))
    end

    local function JobDone(T, j, state)
        if j.tag == "slnano" then
            if state == "done" and j.unitID then
                T.slNanoIDs = T.slNanoIDs or {}
                T.slNanoIDs[j.unitID] = true
                T.slGuardF = nil                          -- guard the lab on the next pass
            end
            Spring.Echo(string.format("[LT] %s spam lab nano %s", Clock(T.frame), state))
            return
        end
        if state ~= "done" then
            T.slTries = (T.slTries or 0) + 1
            Spring.Echo(string.format("[LT] %s spam lab job %s (try %d)", Clock(T.frame), state, T.slTries))
            if T.slTries >= 3 then
                T.slState = "off"
                if not T.slSite.beyond then
                    for _, s in ipairs(T.slSite.slots) do s.state = "free" end
                    for _, s in ipairs(T.slSite.nanos) do s.state = "free" end
                end
                T.slSite = nil
            else
                T.slState = "reserved"
            end
            return
        end
        T.slLabID, T.slState = j.unitID, "done"
        T.slGuardF = nil
        if T.WG then CH.Publish(T.WG, "SpamLab", { id = j.unitID }) end    -- lab_rules: that lab makes the spam element's units and nothing else
        Spring.Echo(string.format("[LT] %s SPAM LAB finished (%d); %.0fs after it was queued", Clock(T.frame), j.unitID,
            (T.frame - (T.slFrame or T.frame)) / 30))
    end

    -- The lab died: lab_rules stops treating that id as the spam lab; the site is not rebuilt (its slots stay reserved).
    local function Destroyed(T, unitID)
        if unitID ~= T.slLabID then return end
        T.slLabID = nil
        if T.WG and T.WG.SpamLab and T.WG.SpamLab.id == unitID then T.WG.SpamLab = nil end
    end

    X.UpdateSpamLab, X.SpamLabJobStarted, X.SpamLabJobDone, X.SpamLabDestroyed = UpdateSpamLab, JobStarted, JobDone, Destroyed
end

return M
