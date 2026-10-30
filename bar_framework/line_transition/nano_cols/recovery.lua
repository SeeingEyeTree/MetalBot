-- bar_framework/line_transition/nano_cols/recovery.lua
-- Recovery for the nano-column block (user 2026-10-30, after stress tests in eco_sim: killing the block's nanos left 3.3k m/s at 20:00 instead
-- of 8.9k, wiping the block 0.7k, killing the T1 air lab froze income at 2.4k -- nothing was ever rebuilt).
--   BLOCKS / NANO ROWS (NC_RECOVER, every NC_RECOVER_EVERY frames): a finished block (T1 or T2, the T2 air labs and T1 air lab blocks included)
--     whose item spots are buildable again lost something: a T1 block goes back on its build front's redo list, a retrofitted block back to its
--     retro front with the same target.  A finished nano row with an empty nano spot goes back on its nano front -- only while a block in its
--     reach still needs build power (a stretch whose blocks are all final loses its nanos to the reclaim anyway).  Not while an enemy stands
--     within NC_RECOVER_SAFE_R of it.  "Buildable again" (TestBuildOrder > 0) means nothing else stands there: an anti-nuke put on a mex spot
--     (defense_crew COVER_REPLACE_MEX) or a skipped item does not count as lost.
--   T1 AIR LAB (NC_AIRLAB_RECOVER): with no T1 air lab standing (the line's was killed) there are no air cons, so the fronts stop.  The next
--     block of the first build front with room becomes a T1 air lab, built by a block con -- or, when no T1 air con is left, by a ground con
--     borrowed from the spine (con_broker CB.TakeAny).  The new lab is the macro's air lab from then on (T.airLabID).
-- Part of line_transition (installed after nano_cols/fronts.lua).  Log rows "[NC] recover ...".

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock
    local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

    local function Echo(T, fmt, ...) Spring.Echo(string.format("[NC] %s recover: " .. fmt, Clock(T.frame or 0), ...)) end

    local function Free(defID, x, z)
        if not defID then return false end
        local y = Spring.GetGroundHeight(x, z) or 0
        local r = Spring.TestBuildOrder(defID, x, y, z, 0)
        if not (r and r > 0) then return false end
        -- something of this type stands there anyway (eco_sim never marks a factory's footprint: a standing T2 lab read as lost every 10 s)
        for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 16) or {}) do
            if Spring.GetUnitDefID(uid) == defID then return false end
        end
        return true
    end

    -- redo lists rebuild from the origin outward: the first nanos / blocks back are the ones the rest can be built from
    local function InsertByRow(list, item, row)
        local k = #list + 1
        for i, it in ipairs(list) do
            local r = type(it) == "table" and it.r or it
            if math.abs(row) < math.abs(r) then k = i; break end
        end
        table.insert(list, k, item)
    end

    local function Safe(T, x, z)
        local R = T.CFG.NC_RECOVER_SAFE_R
        if not R or R <= 0 then return true end
        local ally = Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()
        for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, R) or {}) do
            local a = Spring.GetUnitAllyTeam(uid)
            if a and ally and a ~= ally then return false end
        end
        return true
    end

    -- the kind of items a finished block should have standing now
    local function StandingKind(b)
        if b.state == "final" then return b.target end
        if b.state == "t1done" and b.kind ~= "gap" then return b.kind end
        return nil
    end

    local function Missing(nc, kind, j, r)
        local n = 0
        for _, it in ipairs(nc.L.BlockItems(kind, j, r)) do
            local ud = UnitDefNames[ROLES.Get(it.role)]
            if ud and Free(ud.id, it.x, it.z) then n = n + 1 end
        end
        return n
    end

    local function PendingRows(nc)
        local n = 0
        for _, f in ipairs(nc.fronts) do if f.kind == "nano" then n = n + #f.redo end end
        return n
    end
    X.NcPendingRows = PendingRows

    local function CheckBlocks(T, nc)
        local nBlk, nRow = 0, 0
        for _, b in pairs(nc.blocks) do
            local kind = StandingKind(b)
            if kind then
                local miss = Missing(nc, kind, b.j, b.r)
                if miss > 0 then
                    local cx, cz = nc.L.BlockCenter(b.j, b.r)
                    if Safe(T, cx, cz) then
                        local dir = b.r >= 0 and 1 or -1
                        if b.state == "final" then
                            b.state, b.rebuildTarget, b.wasFinal = "t1done", b.target, true   -- the retro front rebuilds it as it was
                            Echo(T, "block %d:%d (%s) lost %d -- back to its retro front", b.j, b.r, b.target, miss)
                        else
                            local f = nc.fk["build:" .. b.j .. ":" .. dir]
                            if f then
                                b.state, b.recovered = "redo", true
                                InsertByRow(f.redo, b, b.r)
                                Echo(T, "block %d:%d (%s) lost %d -- back to its build front", b.j, b.r, b.kind, miss)
                            end
                        end
                        nBlk = nBlk + 1
                    end
                end
            end
        end
        -- nano rows: only while a block in reach still needs build power
        local nanoDef = UnitDefNames[ROLES.Get("nano")]
        for key, state in pairs(nc.rows) do
            if state == "built" then
                local i, q = key:match("^(%-?%d+):(%-?%d+)$")
                i, q = tonumber(i), tonumber(q)
                local items = nc.L.NanoItems(i, q)
                local miss = 0
                for _, it in ipairs(items) do if Free(nanoDef and nanoDef.id, it.x, it.z) then miss = miss + 1 end end
                if miss > 0 and Safe(T, items[2].x, items[2].z) then
                    local useful = false
                    for _, br in ipairs(nc.L.BlocksInReach(items[2].a, items[2].c, 432)) do
                        local b = X.NcBlock(nc, br.j, br.r)
                        if nc.L.RowOK(br.r) and not (b and (b.state == "final" or (b.state == "t1done" and b.kind == "lab"))) then useful = true; break end
                    end
                    local f = nc.fk["nano:" .. i .. ":" .. (q >= 0 and 1 or -1)]
                    if useful and f then
                        nc.rows[key] = nil
                        InsertByRow(f.redo, q, q)
                        nc.nanoRowsBuilt = math.max(0, nc.nanoRowsBuilt - 1)
                        nRow = nRow + 1
                    end
                end
            end
        end
        if nRow > 0 then Echo(T, "%d nano row(s) lost nanos -- back to their nano fronts", nRow) end
        -- NC_FERRY_REARM: the block lost (almost) all its nanos: the ferry brings line nanos again to restart it (the transport is reused)
        local K = T.CFG
        if K.NC_FERRY_REARM and nc.nanoN < K.NC_FERRY_REARM and nRow + PendingRows(nc) > 0 and (not nc.ferry or nc.ferry.done)
           and (T.frame or 0) - (nc.ferryRearmF or -1e9) > 3600 then
            nc.ferryRearmF = T.frame
            local tids = nc.ferry and nc.ferry.tids or {}
            X.NcFerryOpen(T, nc, T.frame or 0)
            if nc.ferry then
                nc.ferry.rearm = true                 -- released once the block has 2 x NC_FERRY_REARM nanos again (not by the T2 / row rule)
                for _, id in ipairs(tids) do if Spring.GetUnitDefID(id) then nc.ferry.tids[#nc.ferry.tids + 1] = id end end
                Echo(T, "only %d nanos left in the block: the ferry runs again", nc.nanoN)
            end
        end
        nc.recovered = (nc.recovered or 0) + nBlk + nRow
    end

    -- ── the T1 air lab ─────────────────────────────────────────────────────────────────────────────────

    local function AirLabStands(T)
        if T.airLabID and Spring.GetUnitDefID(T.airLabID) and not Spring.GetUnitIsBeingBuilt(T.airLabID) then return true end
        return #(X.AirConLabs(T)) > 0
    end

    -- a new block on the first build front (staffing order) that has a free next row: it becomes the air lab
    local function AllocAirLabBlock(T, nc)
        for _, f in ipairs(nc.fronts) do
            if f.kind == "build" and not f.done then
                local r = X.NcRowOfStep(f)
                if nc.L.RowOK(r) and not X.NcBlock(nc, f.col, r) then
                    local b = { j = f.col, r = r, kind = "airlab", state = "redo" }
                    nc.blocks[f.col .. ":" .. r] = b
                    f.step = f.step + 1
                    table.insert(f.redo, 1, b)                -- the front's next con builds it first
                    return b, f
                end
            end
        end
        return nil
    end

    local function CheckAirLab(T, nc, frame, res)
        local K = T.CFG
        if not K.NC_AIRLAB_RECOVER or not T.airConDefID then return end
        if AirLabStands(T) then
            if nc.airLab then Echo(T, "a T1 air lab stands again"); nc.airLab = nil end
            return
        end
        local A = nc.airLab
        if not A then
            local b = AllocAirLabBlock(T, nc)
            if not b then
                if frame - (nc.airLabNoRoomF or -1e9) > 1800 then nc.airLabNoRoomF = frame; Echo(T, "no T1 air lab and no free block for one") end
                return
            end
            A = { block = b, since = frame }
            nc.airLab = A
            Echo(T, "no T1 air lab stands: block %d:%d becomes one", b.j, b.r)
        end
        -- no T1 air con left to build it: borrow a ground con (the spine's) and build it ourselves
        if A.block.state == "redo" and CB.Count(T.CB, 1) == 0 and not A.con then
            local lab = UnitDefNames[ROLES.Get("lab_t1_air")]
            local cx, cz = nc.L.BlockCenter(A.block.j, A.block.r)
            local uid = lab and CB.TakeAny(T.CB, "ncairlab", { defID = lab.id, kind = "ground", near = { cx, cz } })
            if uid then
                for _, f in ipairs(nc.fronts) do
                    for k = #f.redo, 1, -1 do if f.redo[k] == A.block then table.remove(f.redo, k) end end
                end
                local items = nc.L.BlockItems("airlab", A.block.j, A.block.r)
                A.con, A.st = uid, X.NcNewSession(T, uid, items, cx, cz)
                A.block.state = "t1"
                Echo(T, "no T1 air con left: ground con %d builds the air lab", uid)
            elseif frame - (A.askF or -1e9) > 900 then
                A.askF = frame
                Echo(T, "no T1 air con and no ground con to borrow yet")
            end
        end
        if A.st then
            T.BP.Update(A.st, frame, res)
            if A.st.done then
                if A.con and Spring.GetUnitDefID(A.con) then CB.GiveBack(T.CB, A.con, "ncairlab") end
                A.block.state = "t1done"
                A.con, A.st = nil, nil
            end
        end
    end

    function X.NcRecover(T, nc, frame, res)
        local K = T.CFG
        if K.NC_AIRLAB_RECOVER and frame % 30 == 0 then CheckAirLab(T, nc, frame, res) end
        if K.NC_RECOVER and frame % K.NC_RECOVER_EVERY == 0 then CheckBlocks(T, nc) end
    end

    -- a T1 air lab finished in the block: it is the macro's air lab now (air cons, the TileLabHold, the reserve)
    function X.NcRecoverUnitFinished(T, nc, unitID, defID, x, z)
        local A = nc.airLab
        if A and A.st then T.BP.OnUnitFinished(A.st, unitID, defID, x, z) end
        local ud = UnitDefs[defID]
        if not (ud and ud.name == ROLES.Get("lab_t1_air")) then return end
        local _, c = nc.L.Local(x, z)
        if c < 0 or c > nc.L.width then return end
        if not (T.airLabID and Spring.GetUnitDefID(T.airLabID)) then
            T.airLabID = unitID
            T.labDefID = T.labDefID or defID
            Echo(T, "T1 air lab %d stands in the block: air cons come from it", unitID)
        end
    end
end

return M
