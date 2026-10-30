-- bar_framework/line_transition/scout_lab.lua
-- The scout labs (user 2026-10-30): "constant scouting of the map ... you can extend the line a little bit and add your own air, ground lab and
-- nanos to make the scouts needed".  Two labs that make scouts and nothing else, for the scout wing (bar_framework/scout_wing.lua):
--   air    = a T1 air lab (ROLES lab_t1_air: corap -> corfink air scouts)
--   ground = a T1 vehicle lab (ROLES lab_t1_veh: corvp -> corfav; Cortex's bot lab builds no scout)
-- each with SCOUT_LAB_NANOS nanos.  Both stand PAST THE END of one lane (the line extended a few columns, spam_lab.lua's PickBeyondSite geometry):
-- the air lab SCOUT_LAB_AIR_K columns past the lane's last slot, the ground lab SCOUT_LAB_GND_K, each lab's nanos in the column 3 before it.
-- Nothing reserves that ground; every spot is tested (TestBuildOrder, Spot) when the job is queued.  Once the clock and income allow, a lane builder
-- (never the commander) gets the lab, then its nanos (a nano takes as long to build as the lab: nanos first put the frame up 72 s late in a real
-- game); that builder is on HIGH priority until those jobs are done.  The ground lab goes to another lane builder when there is one.  The finished labs are
-- published as WG.ScoutLabs = { air = id, ground = id }; lab_rules' "scout-lab" want is then the only thing that orders them (lab.only), and the
-- units they make belong to the scout wing (unit_runtime SCOUT_WING).  A lab that dies is REBUILT (SCOUT_LAB_REBUILD_S later), with any lost nanos.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  Options read (LT.CFG): SCOUT_LAB SCOUT_LAB_FRAME SCOUT_LAB_INCOME
-- SCOUT_LAB_GND_FRAME SCOUT_LAB_GND_INCOME SCOUT_LAB_NANOS SCOUT_LAB_LANES SCOUT_LAB_AIR_K SCOUT_LAB_GND_K SCOUT_LAB_URGENT SCOUT_LAB_GND_URGENT
-- SCOUT_LAB_REBUILD_S SCOUT_LAB_KINDS SCOUT_LAB_HIGH

local M = {}
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")

local GUARD_EVERY = 300      -- frames between re-guards of a lab by its nanos
local SHIFT = 160            -- elmos round a site Spot searches for a legal build spot
local KIND_ROLE = { air = "lab_t1_air", ground = "lab_t1_veh" }
local LAB_TAG   = { air = "sclab_air", ground = "sclab_gnd" }
local NANO_TAG  = { air = "scnano_air", ground = "scnano_gnd" }
local TAG_KIND  = { sclab_air = "air", sclab_gnd = "ground", scnano_air = "air", scnano_gnd = "ground" }

function M.Install(X)
    local LT, Clock = X.LT, X.Clock

    local function SetHigh(T, id, on)
        if not (T.CFG.SCOUT_LAB_HIGH and id and Spring.GetUnitDefID(id)) then return end
        local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD
        Spring.GiveOrderToUnit(id, (gc and gc.PRIORITY) or 34571, { (on == false) and 0 or 1 }, {})
    end

    local function Echo(frame, fmt, ...) Spring.Echo("[LT] " .. Clock(frame) .. " scout lab " .. string.format(fmt, ...)) end

    -- The lane end the labs go past: the first lane in SCOUT_LAB_LANES that has its last two row-1 slots (the lane's direction) and is not
    -- in `skip` (a lane where the jobs failed three times).  Returns the lane's end slot and one column / one row step.
    local function LaneEnd(T, skip)
        local LC, C = T.LC, T.CFG
        local last = LC.K_LAST
        for _, laneID in ipairs(C.SCOUT_LAB_LANES) do
            local lane = T.L.lanes[laneID]
            if lane and not skip[laneID] then
                local at = {}
                for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
                local a, b = at[1] and at[1][last], at[1] and at[1][last - 1]
                local r2 = at[2] and at[2][last]
                if a and b then
                    local rx, rz = 0, 0
                    if r2 then rx, rz = r2.wx - a.wx, r2.wz - a.wz end
                    return { laneID = laneID, a = a, kx = a.wx - b.wx, kz = a.wz - b.wz, rx = rx, rz = rz }
                end
            end
        end
        return nil
    end

    -- the site of one lab `k` columns past the lane's end, its nanos (two rows) in the column 3 before it
    local function Site(e, k, nNanos)
        local a = e.a
        local site = { laneID = e.laneID, k = k, nanos = {},
                       wx = a.wx + e.kx * k + e.rx * 0.5, wz = a.wz + e.kz * k + e.rz * 0.5 }
        for i = 1, nNanos do
            local col = k - 3 - math.floor((i - 1) / 2)
            local row = (i - 1) % 2
            site.nanos[i] = { wx = a.wx + e.kx * col + e.rx * row, wz = a.wz + e.kz * col + e.rz * row }
        end
        return site
    end

    local function Spot(T, wx, wz, defID)
        local base = T.BP.RotateFacing(0, T.L.rot)
        local best
        for dx = -SHIFT, SHIFT, 16 do
            for dz = -SHIFT, SHIFT, 16 do
                local d = dx * dx + dz * dz
                if not best or d < best.d then
                    local x, z = T.BP.SnapToBuildGrid(defID, wx + dx, wz + dz, base)
                    local y = Spring.GetGroundHeight(x, z) or 0
                    local ok = Spring.TestBuildOrder(defID, x, y, z, base)
                    if ok and ok ~= 0 then best = { d = d, x = x, z = z, f = base } end
                end
            end
        end
        if best then return best.x, best.z, best.f end
        return nil
    end

    -- a lane builder that can place the lab: the site lane's first, then the con lanes; never the commander.  One with no jobs queued
    -- first (eco_sim 2026-10-30: the vehicle lab went to the builder that had just been given the spam lab + 4 nanos and stood 220 s
    -- after the order), and not `avoid` (the other scout lab's builder) unless nobody else can.
    local function Builder(T, laneID, defID, avoid)
        local order = { laneID }
        for _, id in ipairs(T.LC.CON_LANES) do if id ~= laneID then order[#order + 1] = id end end
        local best, bestRank
        for _, id in ipairs(order) do
            local c = T.LC.LaneBuilder(T.crew, id)
            local b = c and c.id
            local bd = b and Spring.GetUnitDefID(b)
            local cmdr = bd and UnitDefs[bd] and UnitDefs[bd].customParams and UnitDefs[bd].customParams.iscommander
            if bd and not cmdr and T.BP.CanBuild(bd, defID) then
                local busy = c.jobs ~= nil and #c.jobs > 0
                local rank = (b == avoid and 2 or 0) + (busy and 1 or 0)
                if not bestRank or rank < bestRank then best, bestRank = b, rank end
            end
        end
        return best
    end

    local function Publish(T)
        local S = T.scl
        local v = { air = S.air and S.air.labID or nil, ground = S.ground and S.ground.labID or nil }
        if T.WG then CH.Publish(T.WG, "ScoutLabs", (v.air or v.ground) and v or nil) end
    end

    local function Init(T)
        local C = T.CFG
        local S = { skip = {}, kinds = {} }
        for _, kind in ipairs(C.SCOUT_LAB_KINDS) do
            S[kind] = { kind = kind, state = "wait", nanoIDs = {}, tries = 0 }
            S.kinds[#S.kinds + 1] = kind
        end
        T.scl = S
        return S
    end

    local function PlaceSites(T, frame)
        local S, C = T.scl, T.CFG
        local e = LaneEnd(T, S.skip)
        if not e then
            Echo(frame, "off: no lane end to build past (SCOUT_LAB_LANES)")
            for _, kind in ipairs(S.kinds) do S[kind].state = "off" end
            return false
        end
        for _, kind in ipairs(S.kinds) do
            local L = S[kind]
            L.site = Site(e, kind == "air" and C.SCOUT_LAB_AIR_K or C.SCOUT_LAB_GND_K, C.SCOUT_LAB_NANOS)
        end
        S.laneID = e.laneID
        Echo(frame, "sites past the end of lane %d (air %d, ground %d columns out)", e.laneID, C.SCOUT_LAB_AIR_K, C.SCOUT_LAB_GND_K)
        return true
    end

    local function NanosAlive(L)
        local n = 0
        for nid in pairs(L.nanoIDs) do
            if Spring.GetUnitDefID(nid) then n = n + 1 else L.nanoIDs[nid] = nil end
        end
        return n
    end

    -- queue one lab (and the nanos it is missing) on a lane builder
    local function QueueLab(T, L, frame, income, avoid)
        local C = T.CFG
        local def = UnitDefNames[ROLES.Get(KIND_ROLE[L.kind])]
        if not def then L.state = "off"; return nil end
        local builder = Builder(T, L.site.laneID, def.id, avoid)
        if not builder then
            if frame - (L.logF or -1e9) >= 1800 then L.logF = frame; Echo(frame, "%s due: no lane builder can place %s yet", L.kind, def.name) end
            return nil
        end
        local x, z, f = Spot(T, L.site.wx, L.site.wz, def.id)
        if not x then
            if frame - (L.logF or -1e9) >= 1800 then L.logF = frame; Echo(frame, "%s due: no legal spot for %s", L.kind, def.name) end
            return nil
        end
        local urgent = (L.kind == "air") and C.SCOUT_LAB_URGENT or (L.kind == "ground" and C.SCOUT_LAB_GND_URGENT)
        T.LC.QueueJob(T.crew, builder, { name = def.name, x = x, z = z, f = f, tag = LAB_TAG[L.kind], urgent = urgent })
        local nanoName = ROLES.Get("nano")
        local nanoDef = UnitDefNames[nanoName]
        local nNanos = 0
        for i = NanosAlive(L) + 1, #L.site.nanos do      -- then the nanos: they speed up the scouts, the lab makes them alone
            local s = L.site.nanos[i]
            local nx, nz = nil, nil
            if nanoDef then nx, nz = Spot(T, s.wx, s.wz, nanoDef.id) end
            if nx then
                T.LC.QueueJob(T.crew, builder, { name = nanoName, x = nx, z = nz, f = 0, tag = NANO_TAG[L.kind] })
                nNanos = nNanos + 1
            end
        end
        L.state, L.frame, L.builder, L.pending = "queued", frame, builder, 1 + nNanos
        SetHigh(T, builder, true)           -- a line con is low priority: in a metal stall the frame got nothing (real game: 125 s to build)
        Echo(frame, "%s QUEUED: %s at (%d, %d) + %d nanos by lane builder %d, income %.0f", L.kind, def.name, x, z, nNanos, builder, income)
        return builder
    end

    local function UpdateScoutLabs(T, frame, res)
        local C = T.CFG
        if not C.SCOUT_LAB or not T.L then return end
        local S = T.scl or Init(T)
        local income = (res and (res.metalIncomeS or res.metalIncome)) or 0
        if frame < math.min(C.SCOUT_LAB_FRAME, C.SCOUT_LAB_GND_FRAME) then return end
        if not S.laneID and not S.off then
            if not PlaceSites(T, frame) then S.off = true; return end
        end
        if S.off then return end
        local used = nil
        for _, kind in ipairs(S.kinds) do       -- a builder still on the other lab's jobs is taken only when nobody else can
            if S[kind].state == "queued" then used = S[kind].builder end
        end
        for _, kind in ipairs(S.kinds) do
            local L = S[kind]
            local gateF, gateI = C.SCOUT_LAB_FRAME, C.SCOUT_LAB_INCOME
            if kind == "ground" then gateF, gateI = C.SCOUT_LAB_GND_FRAME, C.SCOUT_LAB_GND_INCOME end
            if L.state == "wait" and frame >= gateF and income >= gateI and frame - (L.tryF or -1e9) >= 300 and frame >= (L.rebuildF or 0) then
                L.tryF = frame
                used = QueueLab(T, L, frame, income, used) or used
            elseif L.state == "queued" and frame - (L.logF or L.frame) >= 900 then
                L.logF = frame
                Echo(frame, "%s still queued/building %ds after the order", kind, (frame - L.frame) / 30)
            end
            -- the nanos keep guarding the lab (a nano the broker gave other work comes back once it is free)
            local NANO = T.BP.NANO
            if L.labID and NANO and frame - (L.guardF or -1e9) >= GUARD_EVERY then
                L.guardF = frame
                if Spring.GetUnitDefID(L.labID) then
                    for nid in pairs(L.nanoIDs) do
                        if Spring.GetUnitDefID(nid) then NANO.Guard(NANO.PRIO.SPINE, nid, L.labID) else L.nanoIDs[nid] = nil end
                    end
                end
            end
        end
    end

    local function JobStarted(T, j)
        local NANO = T.BP.NANO
        if not (NANO and j.unitID and (j.tag == LAB_TAG.air or j.tag == LAB_TAG.ground)) then return end
        local x, _, z = Spring.GetUnitPosition(j.unitID)
        if not x then return end
        local n = 0
        for _, nid in ipairs(T.BP.NanosInRange(x, z) or {}) do
            if NANO.Assist(NANO.PRIO.HANDOFF, nid, j.unitID) then n = n + 1 end
        end
        Echo(T.frame, "%s frame up: %d nano(s) assisting", TAG_KIND[j.tag], n)
    end

    local function JobDone(T, j, state)
        local S = T.scl
        local kind = TAG_KIND[j.tag]
        local L = S and kind and S[kind]
        if not L then return end
        L.pending = (L.pending or 1) - 1
        if L.pending <= 0 then SetHigh(T, L.builder, false) end     -- back to low, every con's default
        if j.tag == NANO_TAG[kind] then
            if state == "done" and j.unitID then
                L.nanoIDs[j.unitID] = true
                L.guardF = nil
                SetHigh(T, j.unitID, true)
            end
            return
        end
        if state ~= "done" then
            L.tries = L.tries + 1
            Echo(T.frame, "%s job %s (try %d)", kind, state, L.tries)
            L.state = "wait"
            if L.tries >= 3 then         -- this lane end does not work: both labs move to the next lane in SCOUT_LAB_LANES
                S.skip[L.site.laneID] = true
                S.laneID = nil
                for _, k in ipairs(S.kinds) do S[k].tries = 0 end
                Echo(T.frame, "lane %d given up; trying the next lane", L.site.laneID)
            end
            return
        end
        L.labID, L.state, L.tries, L.guardF = j.unitID, "done", 0, nil
        SetHigh(T, j.unitID, true)
        Publish(T)
        Echo(T.frame, "%s FINISHED (%d); %.0fs after it was queued", kind, j.unitID, (T.frame - (L.frame or T.frame)) / 30)
    end

    -- A scout lab died: lab_rules stops treating that id as a scout lab; after SCOUT_LAB_REBUILD_S it is queued again (with any lost nanos).
    local function Destroyed(T, unitID)
        local S = T.scl
        if not S then return end
        for _, kind in ipairs(S.kinds) do
            local L = S[kind]
            if L.labID == unitID then
                L.labID, L.state = nil, "wait"
                L.rebuildF = (T.frame or 0) + T.CFG.SCOUT_LAB_REBUILD_S * 30
                Publish(T)
                Echo(T.frame or 0, "%s lab lost; rebuilt in %ds", kind, T.CFG.SCOUT_LAB_REBUILD_S)
            end
        end
    end

    X.UpdateScoutLabs, X.ScoutLabJobStarted, X.ScoutLabJobDone, X.ScoutLabDestroyed = UpdateScoutLabs, JobStarted, JobDone, Destroyed
    X.SCOUT_LAB_TAGS = TAG_KIND
end

return M
