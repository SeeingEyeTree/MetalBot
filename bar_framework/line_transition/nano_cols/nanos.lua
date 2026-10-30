-- bar_framework/line_transition/nano_cols/nanos.lua
-- The nano-column block's nanos (user 2026-10-30).  Besides the engine's own auto-assist they get exactly three kinds of order:
--   FOCUS   (NC_FOCUS, every 30 frames) the "interrupts": an eco frame of the type the economy needs now (energy frames while energy
--           binds, extractor frames while metal does; a T2 air lab frame always) gets up to NC_FOCUS_MAX nanos in reach at NANO.PRIO.FOCUS,
--           and those nanos are switched to HIGH builder priority (BAR GameCMD.PRIORITY) until the frame is done (NC_FOCUS_HIGH)
--   PARK    (NC_PARK, every 60 frames) to meet the army share: while the army gets less than its share of the spending (spend_governor's
--           measure) and the metal bank is low, NC_PARK_STEP more of the nanos are parked; over the share or floating, fewer.  At least
--           NC_MIN_ACTIVE of them always stay active, focused nanos are never parked, and the cons keep placing new buildings.
--   RECLAIM (NC_RECLAIM_NANOS, every 300 frames, T2 only) a nano every block of whose reach is finished at T2 is reclaimed by a neighbour
--           (frees unit cap for more mohos further out); the NC_LAB_NANOS nearest each T2 air lab of the block stay to support it.
-- Part of line_transition (installed before nano_cols/fronts.lua, which calls these).  Options read (LT.CFG): NC_*.

local M = {}

function M.Install(X)
    local Clock = X.Clock
    local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
    local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

    local REACH_ITEM = 432          -- nano build reach to a mex-sized target (400 + its half footprint)
    local function CmdPriority()
        local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD
        return (gc and gc.PRIORITY) or 34571
    end
    local function SetHigh(id, on)
        if Spring.GetUnitDefID(id) then Spring.GiveOrderToUnit(id, CmdPriority(), { on and 1 or 0 }, {}) end
    end

    local FOCUS_ROLE = {}           -- defID -> "metal" | "energy" | "lab"
    local function FocusRole(defID)
        if next(FOCUS_ROLE) == nil then
            for role, kind in pairs({ mex = "metal", moho = "metal", wind = "energy", fusion = "energy", afus = "energy", lab_t2_air = "lab" }) do
                local ud = UnitDefNames[ROLES.Get(role)]
                if ud then FOCUS_ROLE[ud.id] = kind end
            end
        end
        return FOCUS_ROLE[defID]
    end

    local function Reach(defID, dx, dz)
        local ud = UnitDefs[defID or -1]
        local half = ud and math.max(ud.xsize or 0, ud.zsize or 0) * 4 or 32
        local r = 400 + half
        return dx * dx + dz * dz <= r * r
    end

    -- ── nano registry ──────────────────────────────────────────────────────────────────────────────────

    function X.NcNanoFinished(T, nc, unitID, defID, x, z)
        local ud = UnitDefs[defID]
        if not (ud and ud.name == ROLES.Get("nano")) then return end
        local a, c = nc.L.Local(x, z)
        local kind, i = nc.L.ColumnAt(c)
        if kind ~= "N" then return end
        nc.nanos[unitID] = { x = x, z = z, a = a, c = c, i = i, q = math.floor((a + 72 + 24) / 48), reach = nc.L.BlocksInReach(a, c, REACH_ITEM) }
        nc.nanoN = nc.nanoN + 1
    end

    function X.NcNanoDestroyed(T, nc, unitID)
        if not nc.nanos[unitID] then return end
        local n = nc.nanos[unitID]
        nc.nanos[unitID] = nil
        nc.nanoN = nc.nanoN - 1
        if nc.focus[unitID] then nc.focus[unitID] = nil end
        nc.parked[unitID] = nil
        if nc.reclaiming[unitID] then
            nc.reclaiming[unitID] = nil
            nc.rows[n.i .. ":" .. n.q] = "reclaimed"
            nc.reclaimed = (nc.reclaimed or 0) + 1
        end
    end

    -- ── focus ──────────────────────────────────────────────────────────────────────────────────────────

    local function NeedType(res)
        local m = (res.metalStorage or 0) > 0 and res.metal / res.metalStorage or 0.5
        local e = (res.energyStorage or 0) > 0 and res.energy / res.energyStorage or 0.5
        if e < 0.25 and (res.energyPullS or 0) >= 0.95 * (res.energyIncomeS or 0) then return "energy" end
        if e < m then return "energy" end
        return "metal"
    end

    local function Focus(T, nc, frame, res)
        local K, NANO = T.CFG, T.BP.NANO
        local P = NANO.PRIO.FOCUS
        -- focus that ended (frame done, nano taken by a higher job): back to low priority
        for id, tgt in pairs(nc.focus) do
            local a = NANO.Assignment(id)
            if not a or a.target ~= tgt or a.prio ~= P then
                nc.focus[id] = nil
                if K.NC_FOCUS_HIGH then SetHigh(id, false) end
            end
        end
        local need = NeedType(res)
        local frames = {}
        local L = nc.L
        for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
            local defID = Spring.GetUnitDefID(uid)
            local role = defID and FocusRole(defID)
            if role and (role == need or role == "lab") then
                local being, prog = Spring.GetUnitIsBeingBuilt(uid)
                if being then
                    local x, _, z = Spring.GetUnitPosition(uid)
                    if x then
                        local _, c = L.Local(x, z)
                        if c >= 0 and c <= L.width then frames[#frames + 1] = { id = uid, def = defID, x = x, z = z, p = prog or 0, lab = role == "lab" } end
                    end
                end
            end
        end
        if #frames == 0 then return end
        table.sort(frames, function(a, b)
            if a.lab ~= b.lab then return a.lab end
            return a.p > b.p
        end)
        local count = {}
        for _, tgt in pairs(nc.focus) do count[tgt] = (count[tgt] or 0) + 1 end
        for _, fr in ipairs(frames) do
            local have = count[fr.id] or 0
            if have < K.NC_FOCUS_MAX then
                local cands = {}
                for id, n in pairs(nc.nanos) do
                    if not nc.parked[id] and not nc.focus[id] and not nc.reclaiming[id] then
                        local dx, dz = n.x - fr.x, n.z - fr.z
                        if Reach(fr.def, dx, dz) then cands[#cands + 1] = { id = id, d = dx * dx + dz * dz } end
                    end
                end
                table.sort(cands, function(a, b) return a.d < b.d end)
                for _, cnd in ipairs(cands) do
                    if have >= K.NC_FOCUS_MAX then break end
                    if NANO.Assist(P, cnd.id, fr.id) then
                        nc.focus[cnd.id] = fr.id
                        have = have + 1
                        if K.NC_FOCUS_HIGH then SetHigh(cnd.id, true) end
                    end
                end
                count[fr.id] = have
            end
        end
    end

    -- ── parking ────────────────────────────────────────────────────────────────────────────────────────

    local function Park(T, nc, frame, res)
        local K, NANO = T.CFG, T.BP.NANO
        local spine = T.spineMod
        local share = (spine and spine.Share and spine.Share()) or 0
        local list = {}
        for id in pairs(nc.nanos) do
            if not nc.reclaiming[id] and not Spring.GetUnitIsBeingBuilt(id) then list[#list + 1] = id end
        end
        local n = #list
        local maxPark = math.floor(n * (1 - K.NC_MIN_ACTIVE))
        local step = math.max(1, math.ceil(n * K.NC_PARK_STEP))
        local target = nc.parkTarget
        if not K.NC_PARK or share <= 0 then
            target = 0
        else
            local G = T.sg
            -- the bank in seconds of income (a share of storage reads "low" late: every moho adds 600 storage, user 2026-10-30)
            local inc = math.max(1, res.metalIncomeS or res.metalIncome or 1)
            local secs = (res.metal or 0) / inc
            if G and G.realized then
                if G.realized < share - 0.05 and secs < K.NC_PARK_LOW_S then target = target + step
                elseif G.realized > share + 0.05 or secs > K.NC_PARK_FLOAT_S then target = target - step end
            else
                target = math.floor(n * share)
            end
        end
        target = math.max(0, math.min(maxPark, target))
        nc.parkTarget = target
        -- the least useful first: furthest (along the columns) from where the fronts are working
        local work = {}
        for _, f in ipairs(nc.fronts) do
            if not f.done and f.kind ~= "retro" then
                local r = X.NcRowOfStep(f)
                work[#work + 1] = (f.kind == "nano") and nc.L.NanoA(r) or nc.L.RowA(r)
            end
        end
        local function Dist(id)
            local a, best = nc.nanos[id].a, math.huge
            for _, w in ipairs(work) do best = math.min(best, math.abs(a - w)) end
            return best
        end
        local cands = {}
        for _, id in ipairs(list) do
            if not nc.focus[id] then cands[#cands + 1] = { id = id, d = Dist(id) } end
        end
        table.sort(cands, function(a, b) if a.d ~= b.d then return a.d > b.d end return a.id < b.id end)
        local want = {}
        for k = 1, math.min(target, #cands) do want[cands[k].id] = true end
        for id in pairs(nc.parked) do
            if not want[id] then NANO.Release(id); nc.parked[id] = nil end
        end
        for id in pairs(want) do
            if not nc.parked[id] and NANO.Park(NANO.PRIO.SPINE, id) then nc.parked[id] = true end
        end
    end

    -- ── reclaim behind the retrofits ───────────────────────────────────────────────────────────────────

    local function Reclaim(T, nc, frame)
        local K, NANO = T.CFG, T.BP.NANO
        -- keepers: the NC_LAB_NANOS nearest each T2 air lab of the block
        local keep = {}
        for _, lab in pairs(nc.labIDs or {}) do
            local d = {}
            for id, n in pairs(nc.nanos) do d[#d + 1] = { id = id, d = (n.x - lab.x) ^ 2 + (n.z - lab.z) ^ 2 } end
            table.sort(d, function(a, b) return a.d < b.d end)
            for k = 1, math.min(K.NC_LAB_NANOS, #d) do keep[d[k].id] = true end
        end
        local function Final(j, r)
            local b = X.NcBlock(nc, j, r)
            if b then return b.state == "final" or (b.state == "t1done" and b.kind == "lab") end
            return not nc.L.RowOK(r)              -- a row off the map (or on the line / spine / enemy side) never gets built
        end
        local targets = {}
        for id, n in pairs(nc.nanos) do
            if not keep[id] and not nc.reclaiming[id] then
                local all = #n.reach > 0
                for _, br in ipairs(n.reach) do
                    if not Final(br.j, br.r) then all = false; break end
                end
                if all then targets[#targets + 1] = id end
            end
        end
        if #targets == 0 then return end
        local busy, started = {}, 0
        for _, id in ipairs(targets) do busy[id] = true end
        for _, id in ipairs(targets) do
            if started >= K.NC_RECLAIM_BATCH then break end
            local t = nc.nanos[id]
            local best, bd
            for rid, n in pairs(nc.nanos) do
                if rid ~= id and not nc.parked[rid] and not nc.reclaiming[rid] and not busy[rid] then
                    local d = (n.x - t.x) ^ 2 + (n.z - t.z) ^ 2
                    if d <= 424 * 424 and (not bd or d < bd) then best, bd = rid, d end
                end
            end
            if not best then
                -- every neighbour is going too: the last of a finished stretch is reclaimed by another of them
                for rid, n in pairs(nc.nanos) do
                    if rid ~= id and not nc.parked[rid] and not nc.reclaiming[rid] then
                        local d = (n.x - t.x) ^ 2 + (n.z - t.z) ^ 2
                        if d <= 424 * 424 and (not bd or d < bd) then best, bd = rid, d end
                    end
                end
            end
            if best and NANO.Reclaim(NANO.PRIO.WIND_RECLAIM, best, id) then
                nc.reclaiming[id] = best
                if nc.parked[id] then NANO.Release(id); nc.parked[id] = nil end
                started = started + 1
            end
        end
        if started > 0 then
            Spring.Echo(string.format("[NC] %s reclaiming %d nano(s) whose blocks are all finished (%d eligible, %d kept for T2 labs, %d reclaimed so far)",
                Clock(frame), started, #targets, (function() local k = 0; for _ in pairs(keep) do k = k + 1 end; return k end)(), nc.reclaimed or 0))
        end
        -- a reclaim that stopped (reclaimer taken by a higher job): try again next time
        for id, rid in pairs(nc.reclaiming) do
            local a = NANO.Assignment(rid)
            if not a or a.target ~= id then nc.reclaiming[id] = nil end
        end
    end

    function X.NcNanos(T, nc, frame, res)
        local K = T.CFG
        if K.NC_FOCUS and frame % 30 == 0 then Focus(T, nc, frame, res) end
        if frame % 60 == 0 then Park(T, nc, frame, res) end
        if K.NC_RECLAIM_NANOS and nc.t2 and frame % 300 == 0 then Reclaim(T, nc, frame) end
    end
end

return M
