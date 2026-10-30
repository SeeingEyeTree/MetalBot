-- bar_framework/line_transition/nano_cols/fronts.lua
-- The nano-column block (user 2026-10-30; LT.CFG.NANO_COLS): replaces the mex grids.  Geometry: nano_cols/layout.lua.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The functions take the transition's state table T;
-- what other modules need is exported on X (the shared internals table).
--
-- When the T1 air lab stands (where the first grid used to open) the block is laid out beyond the line's away edge: NC_NANO_COLS nano
-- columns with a building column on each side (B N B N B N B).  It is built by FRONTS that grow from the origin row up (+a) and down (-a):
--   nano front   (one per nano column and direction, a T1 air con)  the next nano row (3 nanos) by NC_NANO_PATTERN ("1010": every other row
--                in T1); at most NC_NANO_AHEAD block rows ahead of the building fronts beside it; in T2 it goes back and fills the rows it skipped
--   build front  (one per building column and direction, a T1 air con)  the next block: a mex block (5x3) or a wind block (6x4) by the
--                energy projection (NC_E_RATIO_T1); once T2 has started never wind -- an "energy gap" (left empty for fusions) where the T2
--                projection wants energy (NC_E_RATIO); a T2 air lab block when one is wanted (NC_T2_LAB_INCOME / _STEP / _MAX); at most
--                NC_BUILD_LEAD block rows ahead of the nano fronts beside it
--   retro front  (one per building column and direction, a T2 con)  T1 blocks behind the build front: mex -> 15 mohos; wind / gap -> an energy
--                block (NC_ENERGY_UNIT fusion 4x2 or afus 3x2) when energy is short, else 15 mohos; wind blocks first near the unit budget
-- Each block / nano row is one blueprint_placer session on the con (hand-off to nanos at NC_HANDOFF, winds reclaimed under a retrofit).
-- A front with no work frees its con; the broker gives it to the next front that has work (fronts are staffed inner columns first).
-- The fronts stop at the map edge and while the eco units (every unit but the army) are over NC_UNIT_FRAC of the unit cap.
-- Nanos (focus, parking to the army share, reclaim behind finished retrofits): nano_cols/nanos.lua.
-- Log rows "[NC] ...".  Options read (LT.CFG): NANO_COLS NC_* (see LT.CFG).

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock
    local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
    local UQ = VFS.Include("LuaUI/Widgets/bar_framework/unit_query.lua")
    local LAYOUT = VFS.Include("LuaUI/Widgets/bar_framework/line_transition/nano_cols/layout.lua")
    local LINE_BOX = X.LINE_BOX
    local OrderT2Spread, T2Shortfall, FreeT2, ConHold, LiftAirConCap = X.OrderT2Spread, X.T2Shortfall, X.FreeT2, X.ConHold, X.LiftAirConCap
    local NcNanos, NcNanoFinished, NcNanoDestroyed = X.NcNanos, X.NcNanoFinished, X.NcNanoDestroyed     -- nano_cols/nanos

    local KIND_RANK = { nano = 1, build = 2, retro = 3 }
    local RedoReady                     -- (defined with Startable)
    -- projections only (Full Metal Plate: every extractor sits on 4 squares of 592.5 metal; knowledge/economy_numbers.md)
    local M_MEX, M_MOHO = 15 * 2.37, 15 * 9.48

    local function Def(role) return UnitDefNames[ROLES.Get(role)] end
    local function WindE()
        local ud = Def("wind")
        local cap = ud and ud.windGenerator or 25
        local lo, hi = (Game and Game.windMin) or 0, (Game and Game.windMax) or cap
        return math.min(cap, (lo + hi) / 2)
    end
    local function EnergyBlockE(T)
        local unit = T.CFG.NC_ENERGY_UNIT
        local ud = Def(unit)
        return (ud and ud.energyMake or 0) * (LAYOUT.UNITS[unit] or 0)
    end

    local function BlockKey(j, r) return j .. ":" .. r end
    local function Block(nc, j, r) return nc.blocks[BlockKey(j, r)] end
    local function RowOfStep(f) return f.dir > 0 and f.step or -(f.step + 1) end   -- block row (build / retro) or nano row (nano)

    -- ── projections ────────────────────────────────────────────────────────────────────────────────────

    local function Income(res) return res.metalIncomeS or res.metalIncome or 0, res.energyIncomeS or res.energyIncome or 0 end
    local function EBank(res) return (res.energyStorage or 0) > 0 and res.energy / res.energyStorage or 0.5 end

    -- T1: is energy the resource to add next?  (income + the blocks being built) against NC_E_RATIO_T1 x metal
    local function NeedEnergyT1(T, nc, res)
        local mi, ei = Income(res)
        local b = EBank(res)
        if b < 0.10 then return true elseif b > 0.90 then return false end
        return ei + nc.run.wind * 24 * WindE() < T.CFG.NC_E_RATIO_T1 * (mi + nc.run.mex * M_MEX)
    end

    -- T2, a new block: leave an energy gap?  The FUTURE income counts every T1 mex block as mohos, every wind block and gap as an energy block.
    local function NeedEnergyFuture(T, nc, res)
        local mi, ei = Income(res)
        local eb = EnergyBlockE(T)
        local c = nc.count
        local mfut = mi + c.mexT1 * (M_MOHO - M_MEX) + nc.run.mex * M_MOHO + M_MOHO
        local efut = ei + (c.gap + c.windT1) * eb - c.windT1 * 24 * WindE() + nc.run.energy * eb
        return efut < T.CFG.NC_E_RATIO * mfut
    end

    -- T2, a retrofit: is energy short now (income + retrofits running against NC_E_RATIO x metal)?
    local function NeedEnergyNow(T, nc, res)
        local mi, ei = Income(res)
        local b = EBank(res)
        if b < 0.10 then return true elseif b > 0.90 then return false end
        local eb = EnergyBlockE(T)
        return ei + nc.run.energy * eb - nc.run.windOut * 24 * WindE() < T.CFG.NC_E_RATIO * (mi + nc.run.moho * (M_MOHO - M_MEX))
    end

    local function Budget(T)
        local cap = (Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(T.teamID)) or (Game and Game.maxUnits) or 3000
        return T.CFG.NC_UNIT_FRAC * cap
    end

    -- T2 air lab blocks wanted: the first at NC_T2_LAB_INCOME metal income or once the eco units fill NC_T2_LAB_CAP_FRAC of the unit budget
    -- (T1 mexes pay back in ~20 s, a moho in ~90 s: T1 first while there is room), then one more per NC_T2_LAB_STEP of income
    local function LabsWanted(T, nc, res)
        local K = T.CFG
        local mi = Income(res)
        local byCap = nc.ecoUnits >= (K.NC_T2_LAB_CAP_FRAC or 2) * Budget(T)
        if mi < K.NC_T2_LAB_INCOME and not byCap then return 0 end
        return math.min(K.NC_T2_LABS_MAX, 1 + math.floor(math.max(0, mi - K.NC_T2_LAB_INCOME) / K.NC_T2_LAB_STEP))
    end
    local function BudgetOK(T, nc, n) return nc.ecoUnits + nc.added + n <= Budget(T) end

    -- ── gates ──────────────────────────────────────────────────────────────────────────────────────────

    local function FrontAt(nc, kind, col, dir) return nc.fk[kind .. ":" .. col .. ":" .. dir] end

    -- block rows the nano fronts beside building column j have reached (the furthest of them; math.huge when one is finished)
    local function NanoReach(nc, j, dir)
        local best
        for _, i in ipairs({ j - 1, j }) do
            local f = FrontAt(nc, "nano", i, dir)
            if f then
                local v = f.done and math.huge or math.floor(f.step / 4)
                best = math.max(best or v, v)
            end
        end
        return best or math.huge
    end

    -- blocks started by the build fronts beside nano column i
    local function BuildReach(nc, i, dir)
        local best
        for _, j in ipairs({ i, i + 1 }) do
            local f = FrontAt(nc, "build", j, dir)
            if f then
                local v = f.done and math.huge or f.step
                best = math.max(best or v, v)
            end
        end
        return best or math.huge
    end

    -- ── what a front can do next ───────────────────────────────────────────────────────────────────────

    local function PatternOn(T, q)
        local p = T.CFG.NC_NANO_PATTERN or "1"
        local k = (q % #p) + 1
        return p:sub(k, k) ~= "0"
    end

    -- a nano front's next forward row (skipping the pattern's empty rows, which are remembered for the T2 fill); nil = none now
    local function NanoForward(T, nc, f)
        local K = T.CFG
        for _ = 1, 8 do
            if f.done then return nil end
            local q = RowOfStep(f)
            if not nc.L.RowOK(nc.L.RowOfNano(q)) then
                f.done = true
                Spring.Echo(string.format("[NC] %s nano front %d%s reached the map edge (%d rows)", Clock(T.frame), f.col, f.dir > 0 and "+" or "-", f.step))
                return nil
            end
            local ahead = K.NC_NANO_AHEAD
            if ahead and math.floor(f.step / 4) > BuildReach(nc, f.col, f.dir) + ahead then return nil end
            local ferried = nc.ferryRows[f.col .. ":" .. q]       -- a ferried line nano stands there (nano_cols/ferry.lua frees the row later)
            if PatternOn(T, q) and not ferried then return q end
            if not ferried then f.skipped[#f.skipped + 1] = q end
            f.step = f.step + 1
        end
        return nil
    end

    local function NanoFill(T, nc, f)
        if not (T.CFG.NC_FILL and nc.t2) then return nil end
        return f.skipped[1]
    end

    local function BuildForward(T, nc, f)
        if f.done then return nil end
        local r = RowOfStep(f)
        if not nc.L.RowOK(r) then
            f.done = true
            Spring.Echo(string.format("[NC] %s build front %d%s reached the map edge (%d blocks)", Clock(T.frame), f.col, f.dir > 0 and "+" or "-", f.step))
            return nil
        end
        if f.step > NanoReach(nc, f.col, f.dir) + T.CFG.NC_BUILD_LEAD then return nil end
        return r
    end

    -- retrofit candidates of a retro front: T1 blocks on its column and side
    local function RetroCandidates(nc, f)
        local out = {}
        for _, b in pairs(nc.blocks) do
            if b.j == f.col and b.state == "t1done" and b.kind ~= "lab" and b.kind ~= "airlab" and ((f.dir > 0) == (b.r >= 0)) then out[#out + 1] = b end
        end
        return out
    end

    -- a recovered block waits for nanos in reach of it (the T1 air lab block and a first-time redo do not)
    RedoReady = function(T, nc, b)
        if not b.recovered or b.kind == "mex" then return true end      -- a mex (50 metal, ~20 s payback) is rebuilt at once: after a wipe metal is what is short
        local cx, cz = nc.L.BlockCenter(b.j, b.r)
        return #(T.BP.NanosInRange(cx, cz) or {}) >= (T.CFG.NC_RECOVER_NANOS or 0)
    end

    -- does the front have work for one more con now?
    local function Startable(T, nc, f)
        local cap = (f.kind == "retro" and T.CFG.NC_RETRO_CONS_PER_FRONT or T.CFG.NC_CONS_PER_FRONT)
        if f.kind ~= "retro" and #f.redo > 0 then cap = math.max(cap, T.CFG.NC_REDO_CONS_PER_FRONT or 0) end   -- rebuilding after losses: more cons
        if f.active >= cap then return false end
        if f.kind == "nano" then
            if #f.redo > 0 then return true end
            if not BudgetOK(T, nc, 3) then return false end
            return NanoForward(T, nc, f) ~= nil or NanoFill(T, nc, f) ~= nil
        elseif f.kind == "build" then
            if #f.redo > 0 and RedoReady(T, nc, f.redo[1]) then return true end
            -- NC_BUILD_EARLY_MAX: while the block has few nanos only this many block sessions run at once, so the nano fronts keep most cons
            local early = T.CFG.NC_BUILD_AFTER_NANOS and nc.nanoN < (T.CFG.NC_BUILD_EARLY_NANOS or 12)
            if early then
                local act = 0
                for _, g in ipairs(nc.fronts) do if g.kind == "build" then act = act + g.active end end
                if act >= (T.CFG.NC_BUILD_EARLY_MAX or 3) then return false end
            end
            if not BudgetOK(T, nc, 24) then return false end
            return BuildForward(T, nc, f) ~= nil
        else
            if not nc.t2 then return false end
            if T.CFG.NC_RETRO_NANOS and nc.nanoN < T.CFG.NC_RETRO_NANOS and X.NcPendingRows(nc) > 0 then return true end
            return #RetroCandidates(nc, f) > 0
        end
    end

    local function Want(T, kind)
        local nc = T.nc
        if not nc or nc.off then return 0 end
        local n = 0
        for _, f in ipairs(nc.fronts) do
            if f.kind == kind and Startable(T, nc, f) then n = n + 1 end
        end
        return n
    end

    -- ── sessions ───────────────────────────────────────────────────────────────────────────────────────

    local function NewSession(T, conID, items, ax, az, clearWinds)
        local layout = {}
        for _, it in ipairs(items) do
            layout[#layout + 1] = { n = ROLES.Get(it.role), x = it.x - ax, z = it.z - az, f = 0 }
        end
        local st = T.BP.New({ layout = layout }, conID, ax, az, 0, {})
        for _, it in ipairs(st.queue) do
            it.strictFrame = true                                        -- items 48 apart: a neighbour's frame must not pass for ours
            -- already standing (a block recovered by nano_cols/recovery.lua rebuilds only its holes)
            for _, uid in ipairs(Spring.GetUnitsInCylinder(it.wx, it.wz, 12) or {}) do
                if Spring.GetUnitDefID(uid) == it.defID and not Spring.GetUnitIsBeingBuilt(uid) then
                    it.built, it.status, it.frameID = true, "built", uid
                    break
                end
            end
        end
        st.handoffProgress = T.CFG.NC_HANDOFF
        st.interruptMinNanos = 0
        -- the hand-off needs a few standing nanos on the state; ours stand in the nano columns, outside the placer's own +-240 box
        st.nanoUnitIDs = T.BP.NanosInRange(ax, az) or {}
        if clearWinds then
            st.clearBlockers = true
            st.clearOnlyDefIDs = {}
            for _, role in ipairs({ "wind", "mex" }) do
                local ud = Def(role)
                if ud then st.clearOnlyDefIDs[ud.id] = true end
            end
        end
        return st
    end

    local function Echo(T, fmt, ...) Spring.Echo(string.format("[NC] %s " .. fmt, Clock(T.frame), ...)) end
    local function FrontName(f) return string.format("%s %d%s", f.kind, f.col, f.dir > 0 and "+" or "-") end

    local function StartNano(T, nc, f, conID)
        local q, fill = table.remove(f.redo, 1), false          -- a row whose builder died first, then the next forward row, then a T2 fill
        if not q and BudgetOK(T, nc, 3) then
            q = NanoForward(T, nc, f)
            if q then f.step = f.step + 1 end
            if not q then
                q = NanoFill(T, nc, f)
                if q then table.remove(f.skipped, 1); fill = true end
            end
        end
        if not q then return false end
        local items = nc.L.NanoItems(f.col, q)
        local st = NewSession(T, conID, items, items[2].x, items[2].z)
        st.nc = { front = f, kind = "nano", q = q, fill = fill }
        nc.rows[f.col .. ":" .. q] = "run"
        nc.added = nc.added + 3
        return st
    end

    -- NC_LAB_SPACING: T2 air labs are spread over the block (raid answers come from all of them): none within that many block rows in this or
    -- a neighbouring building column
    local function LabSpaced(T, nc, j, r)
        local sp = T.CFG.NC_LAB_SPACING or 0
        for _, b in pairs(nc.blocks) do
            if b.kind == "lab" and math.abs(b.j - j) <= 1 and math.abs(b.r - r) < sp then return false end
        end
        return true
    end

    local function StartBuild(T, nc, f, conID, res)
        local b = (#f.redo > 0 and RedoReady(T, nc, f.redo[1])) and table.remove(f.redo, 1) or nil
        if not b then
            local r = BuildForward(T, nc, f)
            while r do
                -- the block's kind
                local kind
                if nc.labsPlanned < LabsWanted(T, nc, res) and LabSpaced(T, nc, f.col, r) then kind = "lab"
                elseif nc.t2 and not (T.CFG.NC_WIND_UNTIL_FUSION and (nc.count.fusion or 0) + (nc.count.afus or 0) < T.CFG.NC_WIND_UNTIL_FUSION) then
                    kind = NeedEnergyFuture(T, nc, res) and "gap" or "mex"
                else kind = NeedEnergyT1(T, nc, res) and "wind" or "mex" end
                b = { j = f.col, r = r, kind = kind, state = "t1" }
                nc.blocks[BlockKey(f.col, r)] = b
                f.step = f.step + 1
                if kind == "lab" then nc.labsPlanned = nc.labsPlanned + 1 end
                if kind ~= "gap" then break end
                -- an energy gap: nothing to build now (a T2 con fills it), the front moves on
                b.state = "t1done"
                nc.count.gap = nc.count.gap + 1
                Echo(T, "%s: block %d energy gap (left for %s)", FrontName(f), r, T.CFG.NC_ENERGY_UNIT)
                b = nil
                r = BuildForward(T, nc, f)
            end
            if not b then return false end
        end
        b.state = "t1"
        local items = nc.L.BlockItems(b.kind, b.j, b.r)
        local cx, cz = nc.L.BlockCenter(b.j, b.r)
        local st = NewSession(T, conID, items, cx, cz)
        st.nc = { front = f, kind = "build", block = b }
        if b.kind == "mex" or b.kind == "wind" then nc.run[b.kind] = nc.run[b.kind] + 1 end
        nc.added = nc.added + #items
        Echo(T, "%s: con %d builds block %d (%s)", FrontName(f), conID, b.r, b.kind)
        return st
    end

    local function StartRetro(T, nc, f, conID, res)
        local cands = RetroCandidates(nc, f)
        if #cands == 0 then return false end
        local K = T.CFG
        local needE = NeedEnergyNow(T, nc, res)
        local tight = nc.ecoUnits > K.NC_CAP_WIND_FIRST * Budget(T)
        local function Score(b)
            local s
            if tight and b.kind == "wind" then s = 0
            elseif needE then s = (b.kind == "gap" and 1) or (b.kind == "wind" and 2) or 3
            else s = (b.kind == "mex" and 1) or (b.kind == "wind" and 2) or 3 end
            return s * 1e6 + math.abs(b.r)
        end
        table.sort(cands, function(a, b) return Score(a) < Score(b) end)
        local b = cands[1]
        local target
        if b.rebuildTarget then
            target, b.rebuildTarget = b.rebuildTarget, nil                -- recovered: rebuilt as it was
        elseif b.kind == "mex" then
            -- NC_MEX_TO_ENERGY: energy is short and no wind block or gap is left on this front: the T1 mex block becomes an energy block
            target = (needE and K.NC_MEX_TO_ENERGY) and K.NC_ENERGY_UNIT or "moho"
        else target = needE and K.NC_ENERGY_UNIT or "moho" end
        b.state, b.target = "retro", target
        local items = nc.L.BlockItems(target, b.j, b.r)
        local cx, cz = nc.L.BlockCenter(b.j, b.r)
        local st = NewSession(T, conID, items, cx, cz, true)
        st.nc = { front = f, kind = "retro", block = b, target = target }
        if target == "moho" then nc.run.moho = nc.run.moho + 1 else nc.run.energy = nc.run.energy + 1 end
        if b.kind == "wind" then nc.run.windOut = nc.run.windOut + 1 end
        Echo(T, "%s: T2 con %d retrofits block %d (%s -> %s)%s", FrontName(f), conID, b.r, b.kind, target, tight and " [unit budget tight]" or "")
        return st
    end

    -- a con of the job's tier was handed to us: the first front (in staffing order) with work takes it; the front it worked last first
    local function Start(T, kind, conID, frame, res)
        local nc = T.nc
        if not nc or nc.off then return false end
        res = res or T.lastRes
        local pick
        for _, f in ipairs(nc.fronts) do
            if f.kind == kind and f.lastCon == conID and Startable(T, nc, f) then pick = f; break end
        end
        if not pick then
            for _, f in ipairs(nc.fronts) do
                if f.kind == kind and Startable(T, nc, f) then pick = f; break end
            end
        end
        -- NC_RETRO_NANOS: while the block has fewer nanos than this and nano rows wait to be rebuilt, a T2 con rebuilds nanos first
        if kind == "retro" and T.CFG.NC_RETRO_NANOS and nc.nanoN < T.CFG.NC_RETRO_NANOS then
            for _, nf in ipairs(nc.fronts) do
                if nf.kind == "nano" and #nf.redo > 0 then
                    local st = StartNano(T, nc, nf, conID)
                    if st then nf.active = nf.active + 1; return st end
                end
            end
        end
        if not pick then return false end
        local st
        if kind == "nano" then st = StartNano(T, nc, pick, conID)
        elseif kind == "build" then st = StartBuild(T, nc, pick, conID, res)
        else st = StartRetro(T, nc, pick, conID, res) end
        if not st then return false end
        pick.active = pick.active + 1
        pick.lastCon = conID
        return st
    end

    local function Complete(st)
        for _, it in ipairs(st.queue) do
            if not it.built and it.act ~= "reclaim" then return false end
        end
        return true
    end

    local function SessionDone(T, st)
        local nc, info = T.nc, st.nc
        if not (nc and info) then return end
        local f = info.front
        f.active = math.max(0, f.active - 1)
        local ok = Complete(st)
        if info.kind == "nano" then
            local key = f.col .. ":" .. info.q
            if ok then
                nc.rows[key] = "built"
                nc.nanoRowsBuilt = nc.nanoRowsBuilt + 1
            else
                nc.rows[key] = nil
                f.redo[#f.redo + 1] = info.q
            end
        elseif info.kind == "build" then
            local b = info.block
            if b.kind == "mex" or b.kind == "wind" then nc.run[b.kind] = math.max(0, nc.run[b.kind] - 1) end
            if ok and b.recovered then
                b.state, b.recovered = "t1done", nil
                Echo(T, "%s: block %d (%s) rebuilt", FrontName(f), b.r, b.kind)
            elseif ok then
                b.state = "t1done"
                if b.kind == "mex" then
                    nc.count.mexT1 = nc.count.mexT1 + 1
                    T.gridFinished["nc" .. BlockKey(b.j, b.r)] = true        -- SpineMexGridsReady counts these like finished grids
                elseif b.kind == "wind" then
                    nc.count.windT1 = nc.count.windT1 + 1
                end
                Echo(T, "%s: block %d (%s) built", FrontName(f), b.r, b.kind)
            else
                b.state = "redo"
                f.redo[#f.redo + 1] = b
                Echo(T, "%s: block %d (%s) left unfinished -- queued again", FrontName(f), b.r, b.kind)
            end
        else
            local b = info.block
            if info.target == "moho" then nc.run.moho = math.max(0, nc.run.moho - 1) else nc.run.energy = math.max(0, nc.run.energy - 1) end
            if b.kind == "wind" then nc.run.windOut = math.max(0, nc.run.windOut - 1) end
            if ok and b.wasFinal then
                b.state, b.wasFinal = "final", nil
                Echo(T, "%s: block %d rebuilt (%s)", FrontName(f), b.r, info.target)
            elseif ok then
                b.state = "final"
                if b.kind == "mex" then nc.count.mexT1 = math.max(0, nc.count.mexT1 - 1)
                elseif b.kind == "wind" then nc.count.windT1 = math.max(0, nc.count.windT1 - 1)
                elseif b.kind == "gap" then nc.count.gap = math.max(0, nc.count.gap - 1) end
                nc.count[info.target] = (nc.count[info.target] or 0) + 1
                Echo(T, "%s: block %d retrofitted (%s -> %s)", FrontName(f), b.r, b.kind, info.target)
            else
                b.state, b.target = "t1done", nil
            end
        end
    end

    -- ── opening the block ──────────────────────────────────────────────────────────────────────────────

    -- a block row of layout L may be built: inside the map, clear of the line and the spine's cells, not on the enemy's side of the line
    local function MakeRowOK(T, L)
        local cache = {}
        return function(r)
            if cache[r] ~= nil then return cache[r] end
            local ok = L.RowFits(r)
            if ok then
                local a = L.RowA(r)
                local xs, zs = {}, {}
                for _, ac in ipairs({ { a - 96, 0 }, { a + 96, 0 }, { a - 96, L.width }, { a + 96, L.width } }) do
                    local x, z = L.World(ac[1], ac[2])
                    xs[#xs + 1], zs[#zs + 1] = x, z
                end
                local x0, x1, z0, z1 = math.min(unpack(xs)), math.max(unpack(xs)), math.min(unpack(zs)), math.max(unpack(zs))
                local b = T.lineBox
                if b and x0 < b.x1 and b.x0 < x1 and z0 < b.z1 and b.z0 < z1 then ok = false end
                for _, sb in ipairs(T.spineBoxes or {}) do
                    if ok and x0 < sb.x + 240 and sb.x - 240 < x1 and z0 < sb.z + 240 and sb.z - 240 < z1 then ok = false end
                end
                for j = 0, L.nb - 1 do
                    local cx, cz = L.BlockCenter(j, r)
                    if ok and T.OnEnemySide and T.OnEnemySide(T, cx, cz) then ok = false end
                end
            end
            cache[r] = ok
            return ok
        end
    end

    -- rows of room from the origin row each way (contiguous, at most `cap`)
    local function Room(L, cap)
        local up, down = 0, 0
        while up < cap and L.RowOK(up) do up = up + 1 end
        while down < cap and L.RowOK(-down - 1) do down = down + 1 end
        return up, down
    end

    -- Where the block goes (user 2026-10-30: "check the geometry; if it does not fit, move it or make it smaller").  First choice: beyond the
    -- line's away edge (the rows' side), columns along the line.  When fewer than NC_NANO_COLS columns fit there, or there are fewer than
    -- NC_MIN_ROOM block rows of room, both ENDS of the line are tried too, the block turned 90 degrees (columns across the line, growing
    -- toward and away from the enemy until the enemy-side limit).  The most nano columns wins, then the most room (eco_sim close starts:
    -- 1 column on the away side made 3.6k m/s at 20:00 against 9.0k with 3).
    local function Candidates(T)
        local K, LC = T.CFG, T.LC
        local out = (T.awayLane == 3) and 1 or -1
        local zmid = (LINE_BOX.z0 + LINE_BOX.z1) / 2
        local function Snap(x, z) return math.floor(x / 16 + 0.5) * 16, math.floor(z / 16 + 0.5) * 16 end
        local list = {}
        do
            local edge = out > 0 and (LINE_BOX.z1 + K.NC_GAP) or (LINE_BOX.z0 - K.NC_GAP)
            local bx0 = (T.site and T.site.bx) or (LC.X0 + 64 * 8)          -- origin row: level with the air lab along the line
            local ox, oz = Snap(LC.World(T.L, bx0, edge))
            local ux, uz = LC.Rotate(1, 0, T.L.rot)
            local vx, vz = LC.Rotate(0, out, T.L.rot)
            list[#list + 1] = { name = "away", ox = ox, oz = oz, ux = ux, uz = uz, vx = vx, vz = vz }
        end
        for _, e in ipairs({ { "start", LINE_BOX.x0 - K.NC_GAP, -1 }, { "end", LINE_BOX.x1 + K.NC_GAP, 1 } }) do
            local ox, oz = Snap(LC.World(T.L, e[2], zmid))
            local ux, uz = LC.Rotate(0, 1, T.L.rot)
            local vx, vz = LC.Rotate(e[3], 0, T.L.rot)
            list[#list + 1] = { name = e[1], ox = ox, oz = oz, ux = ux, uz = uz, vx = vx, vz = vz }
        end
        return list
    end

    function X.OpenNanoCols(T, frame)
        local K = T.CFG
        if T.spineMod then X.StartSpine(T, frame) end
        local best, bestScore
        for ci, cnd in ipairs(Candidates(T)) do
            if ci > 1 and best and best.name == "away" and best.L.nc == K.NC_NANO_COLS and best.room >= K.NC_MIN_ROOM then break end
            for n = K.NC_NANO_COLS, 1, -1 do
                local L = LAYOUT.New({ ox = cnd.ox, oz = cnd.oz, ux = cnd.ux, uz = cnd.uz, vx = cnd.vx, vz = cnd.vz, nc = n,
                                       mapX = T.L.mapX, mapZ = T.L.mapZ, margin = K.NC_MARGIN })
                L.RowOK = MakeRowOK(T, L)
                local up, down = 0, 0
                if L.RowOK(0) then up, down = Room(L, 30) end
                Spring.Echo(string.format("[NC] placement %s: %d nano columns (%d wide) at (%d, %d): room %d block rows up, %d down",
                    cnd.name, n, L.width, cnd.ox, cnd.oz, up, down))
                if up + down >= math.min(K.NC_MIN_ROOM, 8) then
                    local score = n * 1000 + math.min(up + down, K.NC_MIN_ROOM)
                    if not bestScore or score > bestScore then best, bestScore = { L = L, name = cnd.name, room = up + down }, score end
                    break
                end
            end
        end
        if not best then
            Spring.Echo("[NC] no room for the block next to the line: nano columns off")
            T.nc = { off = true }
            return false
        end
        local L = best.L
        local ox, oz, ux, uz, vx, vz = L.ox, L.oz, L.ux, L.uz, L.vx, L.vz
        local nc = { L = L, blocks = {}, rows = {}, fronts = {}, fk = {}, run = { mex = 0, wind = 0, moho = 0, energy = 0, windOut = 0 },
                     count = { mexT1 = 0, windT1 = 0, gap = 0 }, labsPlanned = 0, t2 = false, ecoUnits = 0, added = 0,
                     nanoRowsBuilt = 0, startFrame = frame, nanos = {}, nanoN = 0, parked = {}, focus = {}, reclaiming = {}, parkTarget = 0, helpers = {}, ferryRows = {} }
        T.nc = nc
        local mid = L.width / 2
        local function Add(kind, col, cc)
            for _, d in ipairs({ 1, -1 }) do
                local f = { kind = kind, col = col, dir = d, step = 0, active = 0, ring = math.abs(cc - mid), skipped = {}, redo = {} }
                nc.fronts[#nc.fronts + 1] = f
                nc.fk[kind .. ":" .. col .. ":" .. d] = f
            end
        end
        for i = 0, L.nc - 1 do Add("nano", i, L.NC0(i) + LAYOUT.NW / 2) end
        for j = 0, L.nb - 1 do
            Add("build", j, L.BC0(j) + LAYOUT.BW / 2)
            Add("retro", j, L.BC0(j) + LAYOUT.BW / 2)
        end
        table.sort(nc.fronts, function(a, b)
            if a.ring ~= b.ring then return a.ring < b.ring end
            if a.kind ~= b.kind then return KIND_RANK[a.kind] < KIND_RANK[b.kind] end
            if a.dir ~= b.dir then return a.dir > b.dir end
            return a.col < b.col
        end)
        X.NcFerryOpen(T, nc, frame)
        local up, down = Room(L, 200)
        local cx, cz = L.World(0, L.width)
        Spring.Echo(string.format("[NC] %s layout (%s side): %d nano + %d building columns, %d wide, origin (%d, %d) along (%d, %d), across (%d, %d) to (%d, %d); room %d block rows up, %d down; unit budget %d",
            Clock(frame), best.name, L.nc, L.nb, L.width, ox, oz, ux, uz, vx, vz, cx, cz, up, down, math.floor(Budget(T))))
        return true
    end

    -- ── per-update work ────────────────────────────────────────────────────────────────────────────────

    -- eco units: extractors, energy (wind / fusions / converters), storage and nano turrets -- the economy's own structures.  Labs, cons and
    -- decoys are the army's / the sink's (the sink's labs and decoys grew to ~360 units by 20:00 in eco_sim and must not eat the block's room).
    local ECO_DEF = {}
    local function IsEco(defID)
        local e = ECO_DEF[defID]
        if e == nil then
            local d = UnitDefs[defID]
            e = d ~= nil and not d.isFactory and (d.speed or 0) == 0 and ((d.extractsMetal or 0) > 0 or (d.energyMake or 0) > 0 or (d.windGenerator or 0) > 0
                or (d.metalStorage or 0) > 0 or (d.energyStorage or 0) > 0 or (d.isBuilder and (d.buildSpeed or 0) > 0) or (d.customParams and d.customParams.energyconv_capacity ~= nil))
            ECO_DEF[defID] = e
        end
        return e
    end
    local function CountEcoUnits(T)
        local n = 0
        for _, uid in ipairs(UQ.snapshot(T.teamID).ids) do
            local defID = Spring.GetUnitDefID(uid)
            if defID and IsEco(defID) then n = n + 1 end
        end
        return n
    end

    -- [NC] map: one line per block row (top = furthest +a); building columns show the block (lower case T1, upper case T2:
    -- m/M mex/moho, w wind, g gap, F fusion, A afus, L lab, ~ being built, . empty); nano columns the nano rows standing (0-4)
    local MAPCH = { mex = "m", wind = "w", gap = "g", lab = "L", moho = "M", fusion = "F", afus = "A" }
    local function MapDump(T, nc)
        local lo, hi = 0, -1
        for _, b in pairs(nc.blocks) do lo, hi = math.min(lo, b.r), math.max(hi, b.r) end
        for _, f in ipairs(nc.fronts) do
            if f.kind == "nano" then
                local r = nc.L.RowOfNano(RowOfStep(f))
                lo, hi = math.min(lo, r), math.max(hi, r)
            end
        end
        Spring.Echo(string.format("[NC] map %s (rows %d..%d; columns B N B ..., away side to the right)", Clock(T.frame), lo, hi))
        for r = hi, lo, -1 do
            local s = {}
            for j = 0, nc.L.nb - 1 do
                local b = Block(nc, j, r)
                local ch = "."
                if b then
                    if b.state == "final" then ch = MAPCH[b.target] or "?"
                    elseif b.state == "t1done" then ch = MAPCH[b.kind] or "?"
                    elseif b.state == "retro" then ch = (MAPCH[b.target] or "?") .. "~"
                    else ch = (MAPCH[b.kind] or "?") .. "~" end
                end
                s[#s + 1] = string.format("%-2s", ch)
                if j < nc.L.nc then
                    local n = 0
                    for m = 0, 3 do if nc.rows[j .. ":" .. (4 * r + m)] == "built" then n = n + 1 end end
                    s[#s + 1] = tostring(n)
                end
            end
            Spring.Echo(string.format("[NC] map %+4d |%s|", r, table.concat(s, " ")))
        end
    end

    local function Status(T, nc, frame)
        local active, want = {}, {}
        for _, f in ipairs(nc.fronts) do
            active[f.kind] = (active[f.kind] or 0) + f.active
            if Startable(T, nc, f) then want[f.kind] = (want[f.kind] or 0) + 1 end
        end
        local c = nc.count
        local parked, focus = 0, 0
        for _ in pairs(nc.parked) do parked = parked + 1 end
        for _ in pairs(nc.focus) do focus = focus + 1 end
        Spring.Echo(string.format("[NC] %s blocks T1 mex %d wind %d gap %d | T2 moho %d fusion %d afus %d | labs %d | nano rows %d, nanos %d (parked %d, focus %d) | cons on nano %d build %d retro %d, work waiting %d / %d / %d | eco units %d / %d | t2 %s",
            Clock(frame), c.mexT1, c.windT1, c.gap, c.moho or 0, c.fusion or 0, c.afus or 0, nc.labsPlanned, nc.nanoRowsBuilt, nc.nanoN, parked, focus,
            active.nano or 0, active.build or 0, active.retro or 0, want.nano or 0, want.build or 0, want.retro or 0,
            nc.ecoUnits, math.floor(Budget(T)), tostring(nc.t2)))
    end

    function X.UpdateNanoCols(T, frame, res)
        local nc = T.nc
        if not nc or nc.off then return end
        local K = T.CFG
        -- the early air-con cap (GRID_START) lifts when the first nano row stands, or after GRID_START.wait
        if not T.firstGridOK then
            local GS = K.GRID_START
            if nc.nanoRowsBuilt >= 1 then LiftAirConCap(T, "the first nano row of the block stands")
            elseif not GS or (GS.wait and frame - nc.startFrame >= GS.wait) then LiftAirConCap(T, "the block started without a nano row") end
        end
        if not nc.t2 and (CB.Count(T.CB, 2) > 0 or (nc.labIDs and next(nc.labIDs))) then
            nc.t2 = true
            Echo(T, "T2 started: no more wind blocks, energy gaps where the projection wants energy")
        end
        if frame % 60 == 0 then nc.ecoUnits, nc.added = CountEcoUnits(T), 0 end
        X.UpdateNcHelpers(T, frame)
        X.NcFerryUpdate(T, nc, frame)
        X.NcRecover(T, nc, frame, res)
        -- NC_CON_LAB: the oldest T2 air lab of the block is held for T2 cons (macro_runtime's TileLabHold) while the retro fronts want cons;
        -- the other labs are free for the lab controller (raid Wasps, the defence floor)
        if K.NC_CON_LAB and frame % 30 == 0 then
            if not (nc.conLab and Spring.GetUnitDefID(nc.conLab)) then
                nc.conLab = nil
                for id in pairs(nc.labIDs or {}) do if not nc.conLab or id < nc.conLab then nc.conLab = id end end
            end
            nc.conLabHeld = nc.conLab ~= nil and Want(T, "retro") > 0
        end
        NcNanos(T, nc, frame, res)
        if frame % K.NC_LOG_EVERY == 0 then Status(T, nc, frame) end
        -- a session whose builder has stood with an empty queue for 20 s: log what its queue holds (a stuck session holds its con for ever)
        if frame % 900 == 0 then
            for _, kind in ipairs({ "nano", "build", "retro" }) do
                for _, st in ipairs(T.ncSessions[kind]) do
                    local n = st.builderID and Spring.GetUnitCommands(st.builderID, 0) or -1
                    if n == 0 then st.ncIdleSince = st.ncIdleSince or frame else st.ncIdleSince = nil end
                    if st.ncIdleSince and frame - st.ncIdleSince >= 600 then
                        local built, rel, skip, pend = 0, 0, 0, 0
                        for _, it in ipairs(st.queue) do
                            if it.status == "skipped" then skip = skip + 1 elseif it.built then built = built + 1
                            elseif it.released then rel = rel + 1 else pend = pend + 1 end
                        end
                        Echo(T, "idle session: %s con %d (%s) idle %ds -- items built %d released %d skipped %d pending %d, current %s, done %s orphaned %s",
                            FrontName(st.nc.front), st.builderID or -1, tostring(Spring.GetUnitDefID(st.builderID or -1) ~= nil), math.floor((frame - st.ncIdleSince) / 30),
                            built, rel, skip, pend, tostring(st.currentTask and st.currentTask.n), tostring(st.done), tostring(st.orphaned))
                    end
                end
            end
        end
        if K.NC_MAP_EVERY and frame % K.NC_MAP_EVERY == 0 then MapDump(T, nc) end
    end

    -- T2 cons for the retro fronts (the retro job's produce): spread over the T2 air labs, what the broker says is short
    local function RetroProduce(T, frame, res)
        if frame % 150 ~= 0 or FreeT2(T) > 0 then return end
        if frame - (T.ncT2Frame or -1e9) < 450 or ConHold(T, frame, "nano-column T2 cons") then return end
        local waiting = Want(T, "retro")
        if waiting == 0 then return end
        local n = OrderT2Spread(T, frame, math.min(waiting, math.max(0, T2Shortfall(T, frame))), T.CFG.T2_LAB_DEPTH)
        if n > 0 then
            T.ncT2Frame = frame
            Echo(T, "%d retro front(s) waiting -> %d T2 con(s) ordered", waiting, n)
        end
    end

    function X.NcUnitFinished(T, unitID, defID, x, z)
        local nc = T.nc
        if not nc or nc.off or not x then return end
        local ud = UnitDefs[defID]
        if not ud then return end
        if ud.name == ROLES.Get("lab_t2_air") then
            local a, c = nc.L.Local(x, z)
            if c >= 0 and c <= nc.L.width then
                nc.labIDs = nc.labIDs or {}
                nc.labIDs[unitID] = { x = x, z = z }
            end
        end
        NcNanoFinished(T, nc, unitID, defID, x, z)
        X.NcFerryUnitFinished(T, nc, unitID, defID)
        X.NcRecoverUnitFinished(T, nc, unitID, defID, x, z)
    end

    function X.NcUnitDestroyed(T, unitID)
        local nc = T.nc
        if not nc or nc.off then return end
        if nc.labIDs then nc.labIDs[unitID] = nil end
        NcNanoDestroyed(T, nc, unitID)
    end

    -- con_broker jobs (registered by line_transition's RegisterJobs; nothing is registered without NANO_COLS)
    local function AddJob(T, cb, kind, prio, tier, produce)
        CB.AddJob(cb, { name = "nc" .. kind, section = "nanocols", prio = prio, tier = tier, useReserve = true,
            sessions = T.ncSessions[kind],
            want = function() return Want(T, kind) end,
            near = function()
                local nc = T.nc
                if not nc or nc.off then return nil end
                return nc.L.World(0, nc.L.width / 2)
            end,
            start = function(id, frame, res) return Start(T, kind, id, frame, res) end,
            onDone = function(st)
                SessionDone(T, st)
                if st.builderID and Spring.GetUnitDefID(st.builderID) then CB.Release(cb, st.builderID) end
            end,
            produce = produce })
    end
    X.jobs = X.jobs or {}
    X.jobs.ncnano = function(T, cb)
        if not T.CFG.NANO_COLS then return end
        T.ncSessions = T.ncSessions or { nano = {}, build = {}, retro = {} }
        AddJob(T, cb, "nano", 72, "t1")
    end
    X.jobs.ncbuild = function(T, cb)
        if not T.CFG.NANO_COLS then return end
        T.ncSessions = T.ncSessions or { nano = {}, build = {}, retro = {} }
        -- NC_BUILD_AFTER_NANOS (user 2026-10-30: the block waited for all its nanos before the first mex / wind): once this many nanos stand the build job
        -- outranks the nano job (72), within NC_BUILD_EARLY_MAX sessions until the block has NC_BUILD_EARLY_NANOS nanos
        AddJob(T, cb, "build", function()
            local after, nc = T.CFG.NC_BUILD_AFTER_NANOS, T.nc
            return (after and nc and nc.nanoN >= after) and 74 or 70
        end, "t1")
    end
    X.jobs.ncretro = function(T, cb)
        if not T.CFG.NANO_COLS then return end
        T.ncSessions = T.ncSessions or { nano = {}, build = {}, retro = {} }
        AddJob(T, cb, "retro", 50, "t2", function(frame, res) RetroProduce(T, frame, res) end)
    end

    -- HELPERS (the "nchelp" job): free T1 cons guard the builders of the block's sessions -- NC_HELP_NANO per nano row (a lone air con
    -- takes ~96 s per nano: the first nanos are the bootstrap of everything else), NC_HELP_BUILD per T1 block, NC_HELP_RETRO per retrofit
    -- (a T1 con assists a T2 frame; once the unit budget is full the T1 cons have nothing else to do) -- at most NC_HELPER_CAP.
    -- Any front takes them back at once (preemptable).
    local function HelpSlots(T)
        local nc, K = T.nc, T.CFG
        local out, total = {}, 0
        if not nc or nc.off then return out, 0 end
        local have = {}
        for _, st in pairs(nc.helpers) do have[st] = (have[st] or 0) + 1 end
        for _, kind in ipairs({ "nano", "build", "retro" }) do
            local per = (kind == "nano" and K.NC_HELP_NANO) or (kind == "build" and K.NC_HELP_BUILD) or K.NC_HELP_RETRO
            for _, st in ipairs(T.ncSessions[kind]) do
                if not st.done and st.builderID and Spring.GetUnitDefID(st.builderID) then
                    local open = per - (have[st] or 0)
                    if open > 0 then out[#out + 1] = { st = st, n = open, nano = kind == "nano" }; total = total + open end
                end
            end
        end
        local held = 0
        for _ in pairs(nc.helpers) do held = held + 1 end
        local cap = K.NC_HELPER_CAP
        if K.NC_HELPER_CAP_RECOVER and X.NcPendingRows(nc) > 0 then cap = math.max(cap, K.NC_HELPER_CAP_RECOVER) end
        return out, math.max(0, math.min(total, cap - held))
    end

    local function StartHelper(T, id)
        local slots, n = HelpSlots(T)
        if n <= 0 then return false end
        local x, _, z = Spring.GetUnitPosition(id)
        local best, bd
        for _, sl in ipairs(slots) do
            local bx, _, bz = Spring.GetUnitPosition(sl.st.builderID)
            local d = (bx and x) and ((bx - x) ^ 2 + (bz - z) ^ 2) or 0
            if not sl.nano then d = d + 1e8 end            -- nano rows first
            if not bd or d < bd then best, bd = sl.st, d end
        end
        if not best then return false end
        Spring.GiveOrderToUnit(id, X.CMD_GUARD, { best.builderID }, {})
        T.nc.helpers[id] = best
        return true
    end

    function X.UpdateNcHelpers(T, frame)
        local nc = T.nc
        if not nc or nc.off or frame % 15 ~= 0 then return end
        for id, st in pairs(nc.helpers) do
            if not Spring.GetUnitDefID(id) then nc.helpers[id] = nil
            elseif st.done then nc.helpers[id] = nil; CB.Release(T.CB, id, true) end
        end
    end

    X.jobs.nchelp = function(T, cb)
        if not T.CFG.NANO_COLS then return end
        T.ncSessions = T.ncSessions or { nano = {}, build = {}, retro = {} }
        CB.AddJob(cb, { name = "nchelp", section = "nanocols", prio = 20, tier = "t1", preemptable = true, urgent = false,
            want = function() local _, n = HelpSlots(T); return n end,
            start = function(id) return StartHelper(T, id) end,
            onPreempt = function(id) if T.nc and T.nc.helpers then T.nc.helpers[id] = nil end end,
            onLost = function(id) if T.nc and T.nc.helpers then T.nc.helpers[id] = nil end end })
    end

    X.NcBlock = Block
    X.NcRowOfStep = RowOfStep
    X.NcNewSession = NewSession
end

return M
