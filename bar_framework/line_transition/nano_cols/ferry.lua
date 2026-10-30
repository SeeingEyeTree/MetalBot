-- bar_framework/line_transition/nano_cols/ferry.lua
-- The nano ferry (user 2026-10-30): an air con builds a nano turret very slowly (~96 s alone), so the block's first nano rows are the
-- bootstrap of everything else.  When the block opens, the air lab makes NC_FERRY_TRANSPORTS T1 air transport (corvalk: it lifts a nano,
-- tests/engine/transport_test.py); it carries NC_FERRY_NANOS finished nanos from the line to the middle nano column, into rows the nano
-- pattern leaves empty next to the origin (they block nothing there and reach the first rows of nanos and blocks).  Once the block is
-- going (NC_FERRY_RELEASE_ROWS nano rows built, or T2) the transport carries them back to their line spots and the rows they stood on go
-- back to the nano front (built now if the pattern wants them, else left for the T2 fill).  Moves: bar_framework/air_transport.lua.
-- Part of line_transition (installed before nano_cols/fronts.lua).  Log rows "[NC] ferry ...".  Options read (LT.CFG): NC_FERRY_*.

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock
    local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
    local AT = VFS.Include("LuaUI/Widgets/bar_framework/air_transport.lua")

    local function Echo(T, fmt, ...) Spring.Echo(string.format("[NC] %s ferry: " .. fmt, Clock(T.frame or 0), ...)) end
    local function TransportDef() return UnitDefNames[ROLES.Get("transport_air")] end
    local function NanoDef() return UnitDefNames[ROLES.Get("nano")] end

    -- the line nanos to carry: finished line nanos, those away from the air lab first (LINE_RECOVER rebuilds an empty spot near it), then nearest the block
    local function PickNanos(T, nc, n)
        local nd = NanoDef()
        local slots = T.L and T.L.nanos or {}
        local lx, lz
        if T.airLabID then local x, _, z = Spring.GetUnitPosition(T.airLabID); lx, lz = x, z end
        local ox, oz = nc.L.World(0, 0)
        local cands = {}
        for _, s in ipairs(slots) do
            if s.state == "nano" then
                for _, uid in ipairs(Spring.GetUnitsInCylinder(s.wx, s.wz, 30, T.teamID) or {}) do
                    if nd and Spring.GetUnitDefID(uid) == nd.id and not Spring.GetUnitIsBeingBuilt(uid) and not (T.labNanoIDs and T.labNanoIDs[uid]) then
                        local nearLab = lx and (s.wx - lx) ^ 2 + (s.wz - lz) ^ 2 <= (T.CFG.LINE_RECOVER_R or 700) ^ 2
                        cands[#cands + 1] = { id = uid, x = s.wx, z = s.wz, d = (nearLab and 1e9 or 0) + (s.wx - ox) ^ 2 + (s.wz - oz) ^ 2 }
                        break
                    end
                end
            end
        end
        table.sort(cands, function(a, b) return a.d < b.d end)
        local out = {}
        for k = 1, math.min(n, #cands) do out[#out + 1] = cands[k] end
        return out
    end

    -- the rows the ferried nanos stand on: in the middle nano column, the first row each way from the origin the pattern leaves empty
    local function FerryRows(T, nc, n)
        local i = math.floor(nc.L.nc / 2)
        local p = T.CFG.NC_NANO_PATTERN or "1"
        local function Off(q) local k = (q % #p) + 1; return p:sub(k, k) == "0" end
        local rows = {}
        for _, d in ipairs({ 1, -1 }) do
            local q = d > 0 and 0 or -1
            for _ = 1, 8 do if Off(q) then break end; q = q + d end
            if not Off(q) then q = d > 0 and 1 or -1 end     -- a dense pattern: the row next to the origin row (the front skips it until the nano leaves)
            rows[#rows + 1] = { i = i, q = q, dir = d }
        end
        local out = {}
        for k = 1, n do out[k] = rows[(k - 1) % #rows + 1] end
        return out
    end

    function X.NcFerryOpen(T, nc, frame)
        local K = T.CFG
        if (K.NC_FERRY_NANOS or 0) <= 0 then return end
        local td = TransportDef()
        if not td then Echo(T, "no air transport def (%s)", tostring(ROLES.Get("transport_air"))); return end
        local picks = PickNanos(T, nc, K.NC_FERRY_NANOS)
        if #picks == 0 then Echo(T, "no finished line nano to carry"); return end
        local rows = FerryRows(T, nc, #picks)
        local fe = { items = {}, tids = {}, ordered = 0, orderF = -1e9 }
        for k, pk in ipairs(picks) do
            local r = rows[k]
            local it = nc.L.NanoItems(r.i, r.q)[2]              -- the middle of the row
            fe.items[k] = { unit = pk.id, home = { x = pk.x, z = pk.z }, dest = { x = it.x, z = it.z }, i = r.i, q = r.q, dir = r.dir, state = "wait" }
            nc.ferryRows[r.i .. ":" .. r.q] = true
        end
        nc.ferry = fe
        Echo(T, "%d line nano(s) go to the middle nano column (rows %s) by air transport", #picks,
            table.concat((function() local t = {}; for _, it in ipairs(fe.items) do t[#t + 1] = tostring(it.q) end; return t end)(), ", "))
    end

    -- a finished transport from our air lab while the ferry waits for one: it is the ferry's
    function X.NcFerryUnitFinished(T, nc, unitID, defID)
        local fe = nc.ferry
        local td = TransportDef()
        if not fe or not td or defID ~= td.id or #fe.tids >= (T.CFG.NC_FERRY_TRANSPORTS or 1) then return end
        fe.tids[#fe.tids + 1] = unitID
        fe.ordered = math.max(0, fe.ordered - 1)
        Spring.GiveOrderToUnit(unitID, AT.CMD_STOP, {}, {})
        Echo(T, "transport %d ready", unitID)
    end

    -- the row a ferried nano stood on goes back to its nano front: built now if the pattern wants it, else left for the T2 fill
    local function FreeRow(T, nc, it)
        nc.ferryRows[it.i .. ":" .. it.q] = nil
        local f = nc.fk["nano:" .. it.i .. ":" .. it.dir]
        if not f then return end
        local p = T.CFG.NC_NANO_PATTERN or "1"
        local k = (it.q % #p) + 1
        local passed = it.dir > 0 and it.q < f.step or (it.dir < 0 and -it.q - 1 < f.step)
        if not passed then return end                         -- the front has not reached it yet: it builds it in turn
        if p:sub(k, k) ~= "0" then f.redo[#f.redo + 1] = it.q else f.skipped[#f.skipped + 1] = it.q end
    end

    function X.NcFerryUpdate(T, nc, frame)
        local fe, K = nc.ferry, T.CFG
        if not fe or fe.done or frame % 30 ~= 0 then return end
        for _, job in ipairs(AT.Update(frame)) do
            local it = job.item
            if it then
                if job.state == "done" then
                    it.state = (it.state == "going") and "placed" or "home"
                    Echo(T, "nano %d %s", it.unit, it.state == "placed" and string.format("set down in nano column %d row %d", it.i, it.q) or "back on the line")
                    if it.state == "home" then FreeRow(T, nc, it) end
                else
                    Echo(T, "move of nano %d failed (%s)", it.unit, tostring(job.why))
                    it.state = (it.state == "going") and "wait" or "placed"
                    it.fails = (it.fails or 0) + 1
                end
            end
        end
        -- the transports: alive ones, and order one more while short
        for k = #fe.tids, 1, -1 do if not Spring.GetUnitDefID(fe.tids[k]) then table.remove(fe.tids, k) end end
        local need = (K.NC_FERRY_TRANSPORTS or 1) - #fe.tids
        if need > 0 and fe.ordered == 0 and frame - fe.orderF > 2700 and T.airLabID and Spring.GetUnitDefID(T.airLabID) then
            local td = TransportDef()
            if td then
                CB.OrderCon(T.WG, T.airLabID, td.id, frame, true)      -- ahead of the queue (after the unit in production)
                fe.ordered, fe.orderF = fe.ordered + 1, frame
                Echo(T, "transport ordered from the air lab")
            end
        elseif fe.ordered > 0 and frame - fe.orderF > 2700 then
            fe.ordered = 0                                          -- the order never came out: order again
        end
        -- release: the block is going (or T2): carry them home
        local release = nc.nanoRowsBuilt >= (K.NC_FERRY_RELEASE_ROWS or 8) or nc.t2
        local alldone = true
        for _, it in ipairs(fe.items) do
            if not Spring.GetUnitDefID(it.unit) then
                if it.state ~= "lost" then it.state = "lost"; FreeRow(T, nc, it) end
            elseif it.state ~= "home" then
                alldone = false
                if release and it.state == "wait" then it.state = "home"; FreeRow(T, nc, it) end     -- never left the line
            end
        end
        if alldone then
            fe.done = true
            Echo(T, "done (the nanos are back on the line)")
            return
        end
        for _, tid in ipairs(fe.tids) do
            if not AT.Job(tid) then
                for _, it in ipairs(fe.items) do
                    local go = (it.state == "wait" and not release and (it.fails or 0) < 3)
                    local back = (it.state == "placed" and release)
                    if go or back then
                        local to = go and it.dest or it.home
                        local job, why = AT.Move(tid, it.unit, to.x, to.z, frame, { arrive = 120 })
                        if job then
                            job.item = it
                            it.state = go and "going" or "returning"
                            Echo(T, "transport %d carries nano %d %s", tid, it.unit, go and "to the block" or "back to the line")
                        else
                            Echo(T, "transport %d cannot carry nano %d: %s", tid, it.unit, tostring(why))
                            it.fails = (it.fails or 0) + 1
                            if not go then it.state = "home"; FreeRow(T, nc, it) end
                        end
                        break
                    end
                end
            end
        end
    end
end

return M
