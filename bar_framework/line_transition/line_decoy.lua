-- bar_framework/line_transition/line_decoy.lua
-- THE LINE BECOMES DECOY LABS (user 2026-10-16): once the spine can no longer spend the income, the economy line is eaten, a 3x2 block of
-- slots at a time, and turned into T2 bot labs.  They make the decoy commanders the sink needs, and each has up to DECOY_LINE_PER_LAB (8)
-- decoys assisting it (lab_rules assigns them there before the sink labs): build power for more decoys without more nanos (a unit-cap cost).
-- More labs are added as the demand for decoys grows, up to DECOY_LINE_MAX.
--
--   WHEN   the spine is saturated (income >= DECOY_LINE_FRAC x what its nanos can spend, SPINE.SpendCapacity) -> one lab; one more while
--          the decoys the sink wants exceed the decoys that exist by a lab's worth (DECOY_LINE_PER_LAB), at most one per DECOY_LINE_GAP.
--   WHERE  the end of the line first: the last 3 columns x 2 rows of an outer lane, then back toward the start, then the other lanes.  Any
--          mex / wind / free slot may go (the mexes too: the line is the early economy and the late game no longer needs it); a starter,
--          reserved or occupied-by-something-else block is skipped.
--   HOW    a con borrowed from the spine (a T2 bot con if one is free: a T1 bot con can place coralab, a vehicle con cannot) reclaims what
--          stands there, then places the lab; up to DECOY_LINE_HELPERS more borrowed cons repair the frame.  The finished lab is adopted by
--          the spine (it makes decoys like any non-T1 spine lab) and published as WG.DecoyLabs.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  Options: DECOY_LINE DECOY_LINE_MAX DECOY_LINE_PER_LAB
-- DECOY_LINE_FRAC DECOY_LINE_MIN_INCOME DECOY_LINE_GAP DECOY_LINE_HELPERS DECOY_LINE_LAB

local M = {}

function M.Install(X)
    local Clock, CH = X.Clock, X.CH
    local Roles = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")     -- unit roles (C4)
    local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")   -- the per-frame unit snapshot (C5)
    local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")   -- spend / energy / unit-cap questions (C3)
    local CMD_RECLAIM, CMD_REPAIR, OPT_SHIFT = 90, 40, 32
    local REMOVABLE = { cormex = true, corwin = true, cornanotc = true, corestor = true, corrad = true, corsolar = true }
    local SLOT_OK = { free = true, mex = true, wind = true }
    local RADIUS = 120            -- elmos around the site centre that must be clear (the lab is 144 square)
    local SHIFT = 96

    local function Echo(T, fmt, ...) Spring.Echo(string.format("[LT] %s " .. fmt, Clock(T.frame), ...)) end

    -- the next block of slots to eat: 3 columns x rows 1-2 from the end of the line backwards, outer lanes first
    local function PickSite(T)
        local LC = T.LC
        T.dlBad = T.dlBad or {}
        for _, laneID in ipairs({ 3, 4, 2, 1 }) do
            local lane = T.L.lanes[laneID]
            if lane then
                local at = {}
                for _, s in ipairs(lane.slots) do at[s.row] = at[s.row] or {}; at[s.row][s.k] = s end
                for k0 = LC.K_LAST - 2, LC.K_FIRST, -3 do
                    local slots, good = {}, true
                    for row = 1, 2 do
                        for k = k0, k0 + 2 do
                            local s = at[row] and at[row][k]
                            if s and SLOT_OK[s.state] then slots[#slots + 1] = s else good = false end
                        end
                    end
                    local key = laneID * 100 + k0
                    if good and not T.dlBad[key] then
                        local wx, wz = 0, 0
                        for _, s in ipairs(slots) do wx, wz = wx + s.wx, wz + s.wz end
                        return { key = key, laneID = laneID, k0 = k0, slots = slots, wx = wx / #slots, wz = wz / #slots }
                    end
                end
            end
        end
        return nil
    end

    -- our removable structures on the site, or nil when something else stands there (a lab, a fusion ...)
    local function Standing(T, site)
        local out = {}
        for _, uid in ipairs(Spring.GetUnitsInCylinder(site.wx, site.wz, RADIUS, T.teamID) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and not (d.canMove or (d.speed or 0) > 0) then
                if REMOVABLE[d.name] then out[#out + 1] = uid else return nil end      -- another structure (a lab ...): leave the site alone
            end
        end
        return out
    end

    local function Spot(T, site, defID)
        local f = T.BP.RotateFacing(0, T.L.rot)
        local best
        for dx = -SHIFT, SHIFT, 16 do
            for dz = -SHIFT, SHIFT, 16 do
                local d = dx * dx + dz * dz
                if not best or d < best.d then
                    local x, z = T.BP.SnapToBuildGrid(defID, site.wx + dx, site.wz + dz, f)
                    local ok = Spring.TestBuildOrder(defID, x, Spring.GetGroundHeight(x, z) or 0, z, f)
                    if ok and ok ~= 0 then best = { d = d, x = x, z = z } end
                end
            end
        end
        if best then return best.x, best.z, f end
        return nil
    end

    -- reclaim orders spread over the con and its helpers (each takes every n-th structure, so the site clears in a third of the time)
    local function GiveReclaims(T, J, left)
        local crew = { J.con }
        for _, h in ipairs(J.helpers) do if Spring.GetUnitDefID(h) then crew[#crew + 1] = h end end
        local first = {}
        for i, uid in ipairs(left) do
            local who = crew[(i - 1) % #crew + 1]
            Spring.GiveOrderToUnit(who, CMD_RECLAIM, { uid }, first[who] and OPT_SHIFT or {})
            first[who] = true
        end
    end

    local function Abort(T, why)
        local J = T.dlJob
        if not J then return end
        Echo(T, "line decoy lab at lane %d k %d aborted: %s", J.site.laneID, J.site.k0, why)
        for _, s in ipairs(J.site.slots) do s.noRebuild = nil; if s.state == "reserved" then s.state = "free" end end
        for _, o in ipairs(J.site.extra or {}) do o.noRebuild = nil; if o.state == "reserved" then o.state = "free" end end
        T.dlBad[J.site.key] = true
        X.CB.GiveBack(T.CB, J.con, "linedecoy")
        for _, h in ipairs(J.helpers) do X.CB.GiveBack(T.CB, h, "linedecoy") end
        T.dlJob = nil
        T.dlLastF = T.frame
    end

    -- the decoys the sink wants vs the decoys that exist; > 0 = decoys are short
    local function DecoyShort(T, income, nLine)
        local sink = 0
        for _ in pairs(CH.SinkLabs(T.WG)) do sink = sink + 1 end
        local room = 32 * sink + T.CFG.DECOY_LINE_PER_LAB * nLine
        local want = LEDGER.DecoyDemand(income, room, { min = 0 })
        local dd = Roles.Id("decoy")
        local have = dd and UQ.count_of(T.teamID, dd) or 0       -- the per-frame snapshot (C5)
        return want - have
    end

    local function UpdateLineDecoy(T, frame, res)
        local C = T.CFG
        if not C.DECOY_LINE or not T.spineOn or frame % 30 ~= 0 then return end
        local def = UnitDefNames[C.DECOY_LINE_LAB]
        if not def then return end
        T.dlRecs = T.dlRecs or {}
        if T.WG and not T.dlPublished then CH.Publish(T.WG, "DecoyLabs", T.dlRecs); T.dlPublished = true end
        local nLine = 0
        for id, rec in pairs(T.dlRecs) do
            if Spring.GetUnitDefID(id) then nLine = nLine + 1 else T.dlRecs[id] = nil end
        end
        local J = T.dlJob
        if J then
            if not (Spring.GetUnitDefID(J.con)) then return Abort(T, "its con died") end
            if J.stage == "clear" then
                local left = Standing(T, J.site)
                if left == nil then return Abort(T, "something else stands on the site") end
                if #left == 0 then
                    local x, z, f = Spot(T, J.site, def.id)
                    if not x then
                        if frame - J.since > 1800 then return Abort(T, "no legal spot after clearing") end
                        return
                    end
                    J.x, J.z, J.stage, J.buildF = x, z, "build", frame
                    Spring.GiveOrderToUnit(J.con, -def.id, { x, Spring.GetGroundHeight(x, z) or 0, z, f }, {})
                    Echo(T, "line decoy lab: site clear, %s ordered at (%d, %d)", def.name, x, z)
                elseif frame - (J.orderF or -1e9) >= 150 then
                    J.orderF = frame
                    GiveReclaims(T, J, left)
                elseif frame - J.since > 7200 then
                    local names = {}
                    for _, uid in ipairs(left) do
                        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
                        local cmds = Spring.GetUnitCommands(J.con, 1)
                        names[#names + 1] = (d and d.name or "?") .. "#" .. uid
                    end
                    return Abort(T, "the site did not clear: left " .. table.concat(names, " ") .. "; con " .. tostring(J.con))
                end
            else
                -- building: the frame's helpers repair it; the lab is recognised in LineDecoyFinished
                if frame - J.buildF > 9000 then return Abort(T, "the lab did not finish") end
                if not J.frameID then
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(J.x, J.z, 60, T.teamID) or {}) do
                        if Spring.GetUnitDefID(uid) == def.id and Spring.GetUnitIsBeingBuilt(uid) then J.frameID = uid end
                    end
                    if J.frameID then
                        while #J.helpers < C.DECOY_LINE_HELPERS do
                            local h = (X.CB.TakeAny(T.CB, "linedecoy", { kind = "ground", near = { T.dlJob.site.wx, T.dlJob.site.wz } }))
                            if not h then break end
                            J.helpers[#J.helpers + 1] = h
                            Spring.GiveOrderToUnit(h, CMD_REPAIR, { J.frameID }, {})
                        end
                    end
                end
            end
            return
        end
        -- no job: is another lab due?
        if T.dlNone or nLine >= C.DECOY_LINE_MAX or frame - (T.dlLastF or -1e9) < C.DECOY_LINE_GAP then return end
        local income = (res and (res.metalIncomeS or res.metalIncome)) or 0
        local cap = LEDGER.Capacity(T.WG, "spine") or (T.spineMod.SpendCapacity and (T.spineMod.SpendCapacity()))
        if not (cap and cap > 0) then return end                    -- (no capacity figure: no line decoy labs; the sink's fallback income does not apply)
        if not LEDGER.Saturated(res, cap, { satFrac = C.DECOY_LINE_FRAC, minIncome = C.DECOY_LINE_MIN_INCOME }) then return end
        if nLine > 0 and DecoyShort(T, income, nLine) < C.DECOY_LINE_PER_LAB then return end
        local site = PickSite(T)
        if not site then
            T.dlNone = true
            Echo(T, "line decoy lab: no 3x2 block of line slots left to turn into a lab")
            return
        end
        local con = (X.CB.TakeAny(T.CB, "linedecoy", { defID = def.id, kind = "ground", near = { site.wx, site.wz } }))
        if not con then return end                       -- none free (the spine is using them all): try again
        local left = Standing(T, site)
        if left == nil then
            T.dlBad[site.key] = true
            X.CB.GiveBack(T.CB, con, "linedecoy")
            return
        end
        for _, s in ipairs(site.slots) do s.state, s.noRebuild = "reserved", true end      -- the crew must not rebuild what is reclaimed here
        -- ...nor the neighbouring slots / nanos whose structures fall inside the lab's footprint (they are reclaimed too)
        site.extra = {}
        for _, list in ipairs({ T.L.slots, T.L.nanos or {} }) do
            for _, o in ipairs(list) do
                if not o.noRebuild and (o.wx - site.wx) ^ 2 + (o.wz - site.wz) ^ 2 <= (RADIUS + 16) ^ 2 then
                    o.noRebuild = true
                    site.extra[#site.extra + 1] = o
                end
            end
        end
        T.dlJob = { site = site, con = con, stage = "clear", since = frame, helpers = {} }
        while #T.dlJob.helpers < C.DECOY_LINE_HELPERS do        -- the helpers reclaim with it, then repair the frame
            local h = (X.CB.TakeAny(T.CB, "linedecoy", { kind = "ground", near = { T.dlJob.site.wx, T.dlJob.site.wz } }))
            if not h then break end
            T.dlJob.helpers[#T.dlJob.helpers + 1] = h
        end
        Echo(T, "LINE DECOY LAB %d: eating lane %d slots k %d-%d (%d structures to reclaim), con %d, income %.0f of spine capacity %.0f",
            nLine + 1, site.laneID, site.k0, site.k0 + 2, #left, con, income, cap)
        GiveReclaims(T, T.dlJob, left)
        T.dlJob.orderF = frame
    end

    -- OnUnitFinished: the lab stands
    local function LineDecoyFinished(T, unitID, defID, x, z)
        local J = T.dlJob
        if not (J and J.stage == "build" and x) then return end
        if defID ~= (UnitDefNames[T.CFG.DECOY_LINE_LAB] or {}).id or (x - J.x) ^ 2 + (z - J.z) ^ 2 > 200 * 200 then return end
        T.dlRecs[unitID] = { id = unitID, x = x, z = z, ready = true, decoys = {}, decoyMax = T.CFG.DECOY_LINE_PER_LAB, line = true }
        T.spineMod.AdoptLab(unitID, defID, 0)
        X.CB.GiveBack(T.CB, J.con, "linedecoy")
        for _, h in ipairs(J.helpers) do X.CB.GiveBack(T.CB, h, "linedecoy") end
        Echo(T, "LINE DECOY LAB finished (%d), %.0fs after it was ordered; %d slots eaten", unitID, (T.frame - J.buildF) / 30, #J.site.slots)
        T.dlJob, T.dlLastF = nil, T.frame
    end

    X.UpdateLineDecoy, X.LineDecoyFinished = UpdateLineDecoy, LineDecoyFinished
end

return M
