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
        local q = math.floor((a + 72 + 24) / 48)
        nc.nanos[unitID] = { x = x, z = z, a = a, c = c, i = i, q = q, reach = nc.L.BlocksInReach(a, c, REACH_ITEM),
                             fill = (nc.fillRows and nc.fillRows[i .. ":" .. q]) and true or false }      -- a fill row's nano (the sink's lift takes these first)
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
        -- CAP_MODE (user 2026-11-08: "Eco and nanos in the nano cols should be reclaimed as they can"): at the unit cap with too few slots free, a block
        -- past T1 counts as done too
        local cm = T.WG and T.WG.CapMode
        local capShort = cm and cm.on and (cm.free or 0) < (cm.want or 0)
        local function Final(j, r)
            local b = X.NcBlock(nc, j, r)
            if b then return b.state == "final" or (b.state == "t1done" and (b.kind == "lab" or capShort)) end
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

    -- ── nanos the metal sink may fly away (bar_framework/sink_lift.lua, user 2026-11-04) ─────────────────────────────────────
    -- nc.LiftPick(n, x, z, busy, maxTier): up to n block nanos for the sink (maxTier 0: only reclaim candidates, 0.5: + fill rows, 1: + parked, 2: any), nearest (x, z) first, where those the reclaim rule would take anyway (every
    -- block in reach final) beat parked ones by 800 elmos and parked ones beat the rest by 800.  Never a focused / reclaiming / unfinished nano, one on work at
    -- HANDOFF priority or higher, or one of the NC_LAB_NANOS kept by each T2 air lab.  busy(id) -> true skips more.
    -- nc.Forget(id): the nano left the block (carried away): out of the registry, so focus / park / reclaim leave it alone.  Its spot reads
    -- empty, so recovery rebuilds it while a block in its reach still needs build power.
    function X.NcLiftApi(T, nc)
        local function Final(j, r)
            local b = X.NcBlock(nc, j, r)
            if b then return b.state == "final" or (b.state == "t1done" and b.kind == "lab") end
            return not nc.L.RowOK(r)
        end
        function nc.LiftPick(n, x, z, busy, maxTier)
            local K, NANO = T.CFG, T.BP.NANO
            local keep = {}
            for _, lab in pairs(nc.labIDs or {}) do
                local d = {}
                for id, nn in pairs(nc.nanos) do d[#d + 1] = { id = id, d = (nn.x - lab.x) ^ 2 + (nn.z - lab.z) ^ 2 } end
                table.sort(d, function(a, b) return a.d < b.d end)
                for k = 1, math.min(K.NC_LAB_NANOS or 0, #d) do keep[d[k].id] = true end
            end
            local cands = {}
            for id, nn in pairs(nc.nanos) do
                if not keep[id] and not nc.focus[id] and not nc.reclaiming[id] and not (busy and busy(id))
                   and not Spring.GetUnitIsBeingBuilt(id) and not (NANO and NANO.IsBusy(id, NANO.PRIO.HANDOFF)) then
                    local all = #nn.reach > 0
                    for _, br in ipairs(nn.reach) do if not Final(br.j, br.r) then all = false; break end end
                    -- distance first (a flight is the bottleneck), each tier counts as 800 elmos further
                    -- fill-row nanos (extra density: the pattern left the row empty in T1) right after the reclaim candidates
                    local tier = all and 0 or (nn.fill and 0.5) or (nc.parked[id] and 1 or 2)
                    if tier <= (maxTier or 2) then cands[#cands + 1] = { id = id, tier = tier, d = math.sqrt((nn.x - x) ^ 2 + (nn.z - z) ^ 2) + 800 * tier } end
                end
            end
            table.sort(cands, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
            local out = {}
            for k = 1, math.min(n, #cands) do out[k] = cands[k].id end
            return out
        end
        -- nc.NurseryPick(n, x, z, busy): up to n finished nanos standing in nursery blocks, nearest (x, z) first (they are not in the registry)
        function nc.NurseryPick(n, x, z, busy)
            local nd = UnitDefNames[ROLES.Get("nano")]
            if not nd then return {} end
            local cands = {}
            for _, b in pairs(nc.blocks) do
                if b.kind == "nursery" then
                    for _, it in ipairs(nc.L.BlockItems("nursery", b.j, b.r)) do
                        for _, uid in ipairs(Spring.GetUnitsInCylinder(it.x, it.z, 20, T.teamID) or {}) do
                            if Spring.GetUnitDefID(uid) == nd.id and not Spring.GetUnitIsBeingBuilt(uid) and not (busy and busy(uid)) then
                                cands[#cands + 1] = { id = uid, d = (it.x - x) ^ 2 + (it.z - z) ^ 2 }
                            end
                        end
                    end
                end
            end
            table.sort(cands, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
            local out = {}
            for k = 1, math.min(n, #cands) do out[k] = cands[k].id end
            return out
        end
        function nc.Forget(id)
            if not nc.nanos[id] then return end
            nc.nanos[id] = nil
            nc.nanoN = nc.nanoN - 1
            nc.focus[id], nc.parked[id], nc.reclaiming[id] = nil, nil, nil
        end
    end

    -- nursery blocks (any state) and whether the sink wants another (nc.nurseryWant, set by sink_lift.lua)
    function X.NcNurseryCount(nc)
        local n = 0
        for _, b in pairs(nc.blocks) do if b.kind == "nursery" then n = n + 1 end end
        return n
    end
    function X.NcNurseryWanted(nc) return (nc.nurseryWant or 0) > X.NcNurseryCount(nc) end

    function X.NcNanos(T, nc, frame, res)
        local K = T.CFG
        if K.NC_FOCUS and frame % 30 == 0 then Focus(T, nc, frame, res) end
        if frame % 60 == 0 then Park(T, nc, frame, res) end
        local cm = T.WG and T.WG.CapMode
        if K.NC_RECLAIM_NANOS and (nc.t2 or (cm and cm.on)) and frame % 300 == 0 then Reclaim(T, nc, frame) end
    end
end

return M
