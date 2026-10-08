-- bar_framework/tile_crew.lua  (TILE_BOT only)
-- The con-bot tile opening: a 4x4 block of 15x15-cell (240-elmo) tiles around the
-- commander.  The commander's own tile is blueprints/general/bad_com_start.lua; every
-- other tile is blueprints/general/con_bot_grid.lua.  Each of the (up to) four con bots
-- owns one ROW of tiles and builds them in a line: it walks to the tile's standing
-- point -- from there every building in the tile is inside its build range -- and builds
-- the whole tile with a single-builder blueprint_placer state, so it never walks while
-- building.  What it builds next inside the tile is chosen by the caller's interrupts
-- (energy / metal / bank), not just the layout order.
--
-- Block layout, in tile units (col along colVec, row along rowVec; C = commander tile):
--
--      row -1:  9  10  11  12        con 3
--      row  0:  C   2   3   4        con 1 (it builds the commander tile's nano first)
--      row +1:  5   6   7   8        con 2
--      row +2: 13  14  15  16        con 4
--
-- The tile's open area (tile-local x -64..80, z 16..128, 9x7 cells) is where an air lab
-- (corap, 9x6 cells) fits, and only with its long side along the tile's x axis: the lab
-- must turn WITH the tile (facing = BP_PLACER.RotateFacing(0, rot)), never on its own.

local TC = {}

TC.TILE = 240                       -- elmos between adjacent tile anchors (15 cells)
TC.STAND = { x = 8, z = 32 }        -- tile-local standing point: just above the mexes,
                                    -- <=154 elmos from every item in con_bot_grid
TC.AIR_LAB = { x = 8, z = 72 }      -- tile-local centre of the open area
TC.CENTER = { x = 8, z = 8 }        -- tile-local centre of the tile's footprint
                                    -- (the editor grid spans -112..128)
TC.HALF = 120                       -- half the tile's width
-- Commander spawn -> commander-tile anchor, tile-local.  Taken from the reference
-- replay: spawn (3072, 5952) snapped, anchor (3104, 5968).
TC.COM_OFFSET = { x = 32, z = 16 }
TC.ROWS = {
    { row =  0, cols = { 1, 2, 3 } },
    { row =  1, cols = { 0, 1, 2, 3 } },
    { row = -1, cols = { 0, 1, 2, 3 } },
    { row =  2, cols = { 0, 1, 2, 3 } },
}
-- Paths through the block: each row's open areas join into one corridor (the side gaps
-- between a tile's top wind and its nano, tile-local z 32..80), open at both ends of the
-- block.  bad_com_start's corlab exits east into row 0's corridor, so nothing may ever be
-- built in row 0's open areas -- an air lab there would wall in every con bot after it.
TC.LAB_EXIT_ROW = 0

local ARRIVE_DIST   = 40     -- close enough to the standing point to start building
local MOVE_TIMEOUT  = 600    -- frames; start building wherever it got to
local MOVE_RETRY    = 90     -- frames before an idle, far-away con is re-ordered to move
local HELP_RECHECK  = 150    -- frames between helper re-targets

local CMD_STOP, CMD_MOVE, CMD_GUARD = 0, 10, 25

-- Same convention as blueprint_placer's RotateOffset (Spring: x east, z south).
local function Rotate(x, z, r)
    if     r == 1 then return -z,  x
    elseif r == 2 then return -x, -z
    elseif r == 3 then return  z, -x
    end
    return x, z
end
TC.Rotate = Rotate

local function Sign(v) if v < 0 then return -1 end return 1 end

-- Where the block goes and which way it grows.
--   comX, comZ  commander spawn
--   mapX, mapZ  map size
-- Rows grow AWAY from the map centre along the axis the enemy is on (the eco sits
-- behind the commander), unless the map edge leaves no room; columns grow toward the
-- centre along the other axis.  In the reference replay (spawn 3069,5950 on a
-- southern start) that is rows +z and columns +x, which is what the player did.
function TC.Layout(comX, comZ, mapX, mapZ)
    local T = TC.TILE
    local vx, vz = mapX / 2 - comX, mapZ / 2 - comZ
    local colVec, rowVec, colSign, rowAxisPos, rowAxisMax
    local zMain = math.abs(vz) >= math.abs(vx)
    if zMain then
        colSign = Sign(vx)
        local rowSign = -Sign(vz)
        -- Two rows on the +row side: make sure they fit inside the map.
        local reach = comZ + rowSign * (2 * T + T)
        if reach < 64 or reach > mapZ - 64 then rowSign = -rowSign end
        colVec = { x = colSign * T, z = 0 }
        rowVec = { x = 0, z = rowSign * T }
    else
        colSign = Sign(vz)
        local rowSign = -Sign(vx)
        local reach = comX + rowSign * (2 * T + T)
        if reach < 64 or reach > mapX - 64 then rowSign = -rowSign end
        colVec = { x = 0, z = colSign * T }
        rowVec = { x = rowSign * T, z = 0 }
    end
    -- Turn the tiles so tile-local +x runs along colVec: each row's corridor then runs
    -- the length of the row, and the bot lab (facing tile-local east) exits along it.
    local rot
    if zMain then rot = colSign > 0 and 0 or 2
    else          rot = colSign > 0 and 1 or 3 end

    local ox, oz = Rotate(TC.COM_OFFSET.x, TC.COM_OFFSET.z, rot)
    local ax = math.floor(comX / 16 + 0.5) * 16 + ox
    local az = math.floor(comZ / 16 + 0.5) * 16 + oz

    local L = { anchorX = ax, anchorZ = az, rot = rot, colVec = colVec, rowVec = rowVec,
                rows = {} }
    function L.TileAnchor(col, row)
        return ax + col * colVec.x + row * rowVec.x, az + col * colVec.z + row * rowVec.z
    end
    for ri, r in ipairs(TC.ROWS) do
        local list = {}
        for _, c in ipairs(r.cols) do
            local tx, tz = L.TileAnchor(c, r.row)
            list[#list + 1] = { anchorX = tx, anchorZ = tz, col = c, row = r.row,
                                key = c .. ":" .. r.row, done = false }
        end
        L.rows[ri] = list
    end
    return L
end

-- World position of a tile-local point.
function TC.Local(L, tile, p)
    local x, z = Rotate(p.x, p.z, L.rot)
    return tile.anchorX + x, tile.anchorZ + z
end

-- Axis-aligned bounds of the whole 4x4 block (for keeping other buildings out of it).
function TC.BlockBounds(L)
    local cx, cz = Rotate(TC.CENTER.x, TC.CENTER.z, L.rot)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for col = 0, 3 do
        for row = -1, 2 do
            local tx, tz = L.TileAnchor(col, row)
            tx, tz = tx + cx, tz + cz
            minX, maxX = math.min(minX, tx - TC.HALF), math.max(maxX, tx + TC.HALF)
            minZ, maxZ = math.min(minZ, tz - TC.HALF), math.max(maxZ, tz + TC.HALF)
        end
    end
    return minX, maxX, minZ, maxZ
end

function TC.InBlock(L, x, z, half)
    local minX, maxX, minZ, maxZ = TC.BlockBounds(L)
    half = half or 0
    return x + half > minX and x - half < maxX and z + half > minZ and z - half < maxZ
end

-- The block is exactly 2x2 cells of the 480-elmo mex grid.  Their centres, so the grid
-- expansion can mark them taken and grow from their edges.
function TC.GridCells(L)
    local cx, cz = Rotate(TC.CENTER.x, TC.CENTER.z, L.rot)
    local out = {}
    for _, c0 in ipairs({ 0, 2 }) do
        for _, r0 in ipairs({ -1, 1 }) do
            local col, row = c0 + 0.5, r0 + 0.5
            out[#out + 1] = {
                anchorX = L.anchorX + col * L.colVec.x + row * L.rowVec.x + cx,
                anchorZ = L.anchorZ + col * L.colVec.z + row * L.rowVec.z + cz,
            }
        end
    end
    return out
end

-- The grid cells just beyond both ends of the block's rows.  A mex grid there seals the
-- row corridors (mex_grid_alab is walled with wind on every side), so these stay free
-- until the con bots are finished and out.
function TC.EndCells(L)
    local cx, cz = Rotate(TC.CENTER.x, TC.CENTER.z, L.rot)
    local out = {}
    for _, col in ipairs({ -1.5, 4.5 }) do
        for _, row in ipairs({ -0.5, 1.5 }) do
            out[#out + 1] = {
                anchorX = L.anchorX + col * L.colVec.x + row * L.rowVec.x + cx,
                anchorZ = L.anchorZ + col * L.colVec.z + row * L.rowVec.z + cz,
            }
        end
    end
    return out
end

-- ── The crew ─────────────────────────────────────────────────────────────────

-- opts: BP (blueprint_placer), tileBP (con_bot_grid), layout (TC.Layout),
--       interrupts (function returning a fresh interrupt list), onRowDone(conID)
function TC.NewCrew(opts)
    local crew = { BP = opts.BP, tileBP = opts.tileBP, L = opts.layout,
                   interrupts = opts.interrupts, onRowDone = opts.onRowDone,
                   onCommanderFree = opts.onCommanderFree,
                   cons = {}, freeRows = {}, tilesDone = 0,
                   reserved = 1 }   -- row 1 waits for con #1, busy on the com tile first
    for ri = 1, #TC.ROWS do crew.freeRows[ri] = ri end
    -- What a nano-only pass (a con finishing a tile the commander left without nanos) skips.
    crew.nanoOnlySkip = {}
    for _, name in ipairs({ "cormex", "corwin" }) do
        local ud = UnitDefNames and UnitDefNames[name]
        if ud then crew.nanoOnlySkip[ud.id] = true end
    end
    return crew
end

function TC.FreeRows(crew) return #crew.freeRows end

-- Rows a new con could be given: the free ones, plus the commander's (it hands that over).
function TC.RowsAvailable(crew)
    local n = #crew.freeRows
    if crew.cmdr and crew.cons[crew.cmdr] then n = n + 1 end
    return n
end

-- ── The commander as a stand-in con (TILE_V2) ────────────────────────────────
-- With one con bot (a con costs 2-3 mexes at ~10 m/s) the commander places mexes and winds
-- on a tile row like a con would.  It cannot build nano turrets, so those tiles are flagged
-- `nanoSkipped`; when a later con takes the row over it builds the missing nanos (a
-- "nano-only" pass: the tile state skips mex and wind, which already stand).

-- Next tile for a builder on its row: the first one not built, else (cons only) the first
-- one the commander left without nanos.  Sets c.tileIdx / c.nanoOnly; false when finished.
local function PickTile(crew, c)
    local tiles = crew.L.rows[c.row]
    c.nanoOnly = nil
    for i, t in ipairs(tiles) do
        if not t.done then c.tileIdx = i; return true end
    end
    if not c.cmdr then
        for i, t in ipairs(tiles) do
            if t.nanoSkipped then c.tileIdx, c.nanoOnly = i, true; return true end
        end
    end
    return false
end

local YIELD_TIMEOUT = 450   -- frames the commander may take to finish its tile once asked to go

-- The commander leaves the crew.  Its row goes back to the free list unless a con is
-- already waiting to take it over.
local function FreeCommander(crew, c, why)
    crew.cons[c.id] = nil
    if crew.cmdr == c.id then crew.cmdr = nil end
    local waiter = false
    for _, o in pairs(crew.cons) do
        if o.waitFor == c.id then waiter = true end
    end
    if not waiter then table.insert(crew.freeRows, 1, c.row) end
    Spring.Echo(string.format("[TC] commander leaves row %d (%s)", c.row, why))
    if crew.onCommanderFree then pcall(crew.onCommanderFree, c.id) end
end

-- Put the commander on the first free row (never the one held for con #1) that still has a
-- tile to build.  skipDefIDs: what it cannot build (nano turrets).
function TC.AddCommander(crew, comID, skipDefIDs)
    if crew.cons[comID] then return nil end
    for i, ri in ipairs(crew.freeRows) do
        if ri ~= crew.reserved then
            local c = { id = comID, row = ri, phase = "move", cmdr = true, skip = skipDefIDs }
            if PickTile(crew, c) then
                table.remove(crew.freeRows, i)
                crew.cons[comID] = c
                crew.cmdr = comID
                Spring.GiveOrderToUnit(comID, CMD_STOP, {}, {})
                Spring.Echo(string.format("[TC] commander takes row %d as a stand-in con (no nanos)", ri))
                return ri
            end
        end
    end
    return nil
end

-- Ask the commander to leave: at once if it has not started a tile, else when that tile is
-- done (or after YIELD_TIMEOUT).
function TC.Yield(crew, id)
    local c = crew.cons[id]
    if not (c and c.cmdr) then return end
    if c.yield == nil then c.yield = true end
    if c.phase == "move" then FreeCommander(crew, c, "yielded before starting a tile") end
end

-- Give a con bot the next free row.  Returns the row index, or nil if all are taken.
-- Row 1 (beside the commander's tile) is held for con #1, which passes takeReserved;
-- the others skip it while any other row is free.
function TC.AddCon(crew, conID, takeReserved)
    if crew.cons[conID] then return crew.cons[conID].row end
    local pick = nil
    for i, ri in ipairs(crew.freeRows) do
        if takeReserved and ri == crew.reserved then pick = i; break end
        if not pick and ri ~= crew.reserved then pick = i end
    end
    if not pick and #crew.freeRows > 0 then pick = 1 end
    if not pick then
        -- No free row: take over the commander's.  It finishes the tile it is on first.
        local cm = crew.cmdr and crew.cons[crew.cmdr]
        if not cm then return nil end
        TC.Yield(crew, cm.id)               -- frees the row at once if it has not started a tile
        if #crew.freeRows > 0 then
            pick = 1
        else
            crew.cons[conID] = { id = conID, row = cm.row, phase = "wait", waitFor = cm.id }
            Spring.GiveOrderToUnit(conID, CMD_STOP, {}, {})
            Spring.Echo(string.format("[TC] con %d will take over row %d from the commander",
                conID, cm.row))
            return cm.row
        end
    end
    local ri = table.remove(crew.freeRows, pick)
    if ri == crew.reserved then crew.reserved = nil end
    local tiles = crew.L.rows[ri]
    local c = { id = conID, row = ri, phase = "move" }
    crew.cons[conID] = c
    if not PickTile(crew, c) then c.phase = "done" end   -- nothing left on it
    Spring.GiveOrderToUnit(conID, CMD_STOP, {}, {})
    Spring.Echo(string.format("[TC] con %d takes row %d (%d tiles)", conID, ri, #tiles))
    return ri
end

-- Stop managing a con (the macro controller has a new job for it).
function TC.Release(crew, conID)
    crew.cons[conID] = nil
end

function TC.RowDone(crew, conID)
    local c = crew.cons[conID]
    return c ~= nil and c.phase == "done"
end

function TC.AllDone(crew)
    if #crew.freeRows > 0 then return false end
    for _, c in pairs(crew.cons) do
        if c.phase ~= "done" then return false end
    end
    return true
end

-- Finished tiles, nearest the commander tile first.
function TC.FinishedTiles(crew)
    local out = {}
    for _, row in ipairs(crew.L.rows) do
        for _, t in ipairs(row) do
            if t.done then out[#out + 1] = t end
        end
    end
    local ax, az = crew.L.anchorX, crew.L.anchorZ
    table.sort(out, function(a, b)
        return (a.anchorX - ax) ^ 2 + (a.anchorZ - az) ^ 2
             < (b.anchorX - ax) ^ 2 + (b.anchorZ - az) ^ 2
    end)
    return out
end

-- A con still building its row, nearest to (x, z): the one worth helping.
function TC.NearestBuilder(crew, x, z, maxDist, exceptID)
    local best, bestD2 = nil, (maxDist or math.huge) ^ 2
    for id, c in pairs(crew.cons) do
        if id ~= exceptID and c.phase ~= "done" and Spring.GetUnitDefID(id) then
            local ux, _, uz = Spring.GetUnitPosition(id)
            if ux then
                local d2 = (ux - x) ^ 2 + (uz - z) ^ 2
                if d2 < bestD2 then best, bestD2 = id, d2 end
            end
        end
    end
    return best
end

local function StartTile(crew, c, frame)
    local tile = crew.L.rows[c.row][c.tileIdx]
    -- Close enough: drop the rest of the walk, so the placer (which waits for an idle
    -- builder) issues the first build order right away.
    Spring.GiveOrderToUnit(c.id, CMD_STOP, {}, {})
    local st = crew.BP.New(crew.tileBP, c.id, tile.anchorX, tile.anchorZ, crew.L.rot,
                           crew.interrupts())
    -- A fresh tile has no nanos of its own yet: interrupts must work without them.
    st.interruptMinNanos = 0
    -- Types this builder does not build here (the commander: nanos; a nano-only pass: mex and
    -- wind).  Retired up front so no interrupt can send the builder to an item it cannot place.
    local skip = c.nanoOnly and crew.nanoOnlySkip or c.skip
    if skip then
        st.skipDefIDs = skip
        for _, item in ipairs(st.queue) do
            if item.defID and skip[item.defID] and item.act ~= "reclaim" then
                item.built, item.status = true, "skipped"
            end
        end
    end
    c.st, c.phase = st, "build"
    c.tileStart = frame
end

local function NextTile(crew, c, frame)
    local tiles = crew.L.rows[c.row]
    local tile = tiles[c.tileIdx]
    if tile then
        if c.nanoOnly then
            tile.nanoSkipped = false
            Spring.Echo(string.format("[TC] tile %s nanos done by con %d", tile.key, c.id))
        elseif not tile.done then
            tile.done = true
            if c.cmdr then tile.nanoSkipped = true end
            crew.tilesDone = crew.tilesDone + 1
            Spring.Echo(string.format("[TC] tile %s done by %s %d in %.0fs (%d tiles done)",
                tile.key, c.cmdr and "the commander" or "con", c.id,
                (frame - (c.tileStart or frame)) / 30, crew.tilesDone))
        end
    end
    c.st = nil
    if c.cmdr and c.yield then FreeCommander(crew, c, "yielded"); return end
    if PickTile(crew, c) then
        c.phase, c.moveOrdered = "move", nil
    elseif c.cmdr then
        FreeCommander(crew, c, "row finished")
    else
        c.phase = "done"
        Spring.Echo(string.format("[TC] con %d finished row %d", c.id, c.row))
        if crew.onRowDone then pcall(crew.onRowDone, c.id) end
    end
end

local function UpdateMove(crew, c, frame)
    local tile = crew.L.rows[c.row][c.tileIdx]
    local sx, sz = TC.Local(crew.L, tile, TC.STAND)
    local ux, _, uz = Spring.GetUnitPosition(c.id)
    if not ux then return end
    local d2 = (ux - sx) ^ 2 + (uz - sz) ^ 2
    if not c.moveOrdered then
        Spring.GiveOrderToUnit(c.id, CMD_MOVE, { sx, Spring.GetGroundHeight(sx, sz) or 0, sz }, {})
        c.moveOrdered, c.moveFrame = frame, frame
        return
    end
    if d2 <= ARRIVE_DIST * ARRIVE_DIST or frame - c.moveOrdered > MOVE_TIMEOUT then
        StartTile(crew, c, frame)
        return
    end
    -- Idle but not there: the order was dropped or the path blocked; ask again.
    local cmds = Spring.GetUnitCommands(c.id, 1)
    if (not cmds or #cmds == 0) and frame - c.moveFrame > MOVE_RETRY then
        if d2 <= (ARRIVE_DIST * 3) ^ 2 then
            StartTile(crew, c, frame)
        else
            Spring.GiveOrderToUnit(c.id, CMD_MOVE, { sx, Spring.GetGroundHeight(sx, sz) or 0, sz }, {})
            c.moveFrame = frame
        end
    end
end

-- A con with its row finished helps whichever con is still building nearest to it.
local function UpdateHelper(crew, c, frame)
    if c.helpCheck and frame - c.helpCheck < HELP_RECHECK then return end
    c.helpCheck = frame
    if c.guarding and crew.cons[c.guarding] and crew.cons[c.guarding].phase ~= "done"
       and Spring.GetUnitDefID(c.guarding) then
        return
    end
    local ux, _, uz = Spring.GetUnitPosition(c.id)
    local target = ux and TC.NearestBuilder(crew, ux, uz, nil, c.id)
    if target then
        Spring.GiveOrderToUnit(c.id, CMD_GUARD, { target }, {})
    elseif c.guarding then
        Spring.GiveOrderToUnit(c.id, CMD_STOP, {}, {})
    end
    c.guarding = target
end

function TC.Update(crew, frame, res)
    for id, c in pairs(crew.cons) do
        if not Spring.GetUnitDefID(id) then
            -- Dead: its unfinished tiles go back up for the next con.
            crew.cons[id] = nil
            if crew.cmdr == id then crew.cmdr = nil end
            local waiter = false          -- a con already waiting for this (the commander's) row
            for _, o in pairs(crew.cons) do
                if o.waitFor == id then waiter = true end
            end
            if c.phase ~= "done" and c.phase ~= "wait" and not waiter then
                table.insert(crew.freeRows, 1, c.row)
            end
            Spring.Echo(string.format("[TC] con %d lost, row %d %s", id, c.row,
                c.phase ~= "done" and "freed" or "was finished"))
        elseif c.phase == "move" then
            UpdateMove(crew, c, frame)
        elseif c.phase == "wait" then
            -- Waiting for the commander to finish its tile and hand the row over.
            if not crew.cons[c.waitFor] then
                c.waitFor = nil
                if PickTile(crew, c) then c.phase, c.moveOrdered = "move", nil
                else c.phase = "done" end
            end
        elseif c.phase == "build" then
            crew.BP.Update(c.st, frame, res)
            if c.st.done then
                NextTile(crew, c, frame)
            elseif c.cmdr and c.yield then
                if c.yield == true then c.yield = frame end
                if frame - c.yield > YIELD_TIMEOUT then FreeCommander(crew, c, "yield timeout") end
            end
        else
            UpdateHelper(crew, c, frame)
        end
    end
end

function TC.OnUnitFinished(crew, unitID, unitDefID, x, z)
    for _, c in pairs(crew.cons) do
        if c.st and not c.st.done then
            crew.BP.OnUnitFinished(c.st, unitID, unitDefID, x, z)
        end
    end
end

return TC
