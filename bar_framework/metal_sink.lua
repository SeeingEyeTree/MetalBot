-- bar_framework/metal_sink.lua   (generalises DRAGON_ECO's dragon_lab.lua, user 2026-10-16)
-- The METAL SINK: when the spine can no longer spend the income, extra labs standing apart from it make one chosen unit forever,
-- helped by decoy commanders.  "Sink unit X" is the whole configuration: the lab that makes it is looked up (the cheapest lab that
-- has it in its build options: a T2 air plant for Dragons, a gantry for Juggernauts), a sink SPOT takes any lab, and the unit's
-- energy per metal tells the energy economy what ratio to aim at.
--
--   WHEN    the first lab starts when income reaches SINK_SPEND_FRAC (0.85) of what the spine can spend (SPINE.SpendCapacity():
--           standing nanos x what one nano puts into the comp: 100k BP of Mammoths ~ 3.4k m/s); without a capacity figure, at
--           SINK_INCOME.  More labs, one at a time, while the metal bank keeps floating (SINK_FLOAT_*), up to SINK_MAX.
--   WHERE   sink spots lie on a lattice in front of the spine, SINK_PITCH elmos apart (a lab's width + 4 nano footprints of room),
--           the middle one first, then alternating left / right, SINK_ROW spots per row, further rows toward the enemy.  A spot
--           that cannot be built on is skipped for a while.
--   BUILD   one con from the con broker's "sinklab" job (section "sink") places the lab frame; up to SINK_HELPERS more free cons
--           repair it until it stands.
--   DECOYS  each finished lab has room for SINK_DECOYS (32) decoy commanders assisting it; the lab controller makes them and
--           assigns them through WG.SinkLabs[id].decoys.
--   ENERGY  EnergyRatio() = the sink unit's energy cost per metal (a Dragon: 14.1), once a sink lab is being built or stands;
--           line_transition's energy push aims at it (the ledger's EnergyTarget, eco_ledger.lua) unless EP_RATIO is set.
--
-- Published as WG.SinkLabs = { [id] = {id, x, z, ready, decoys, decoyMax, unit, spot} } (finished labs).  WG.DragonLabs / WG.DragonLab
-- keep the same data for the DRAGON_ECO controllers until they are moved over.
--
-- USAGE (macro_controller)
--   local MS = VFS.Include("LuaUI/Widgets/bar_framework/metal_sink.lua")
--   MS.Init{ cfg = CFG, CB = con_broker, SPINE = function() return SPINE end, trans = function() return trans end,
--            teamID = myTeamID, Clock = Clock, Capacity = function() return SPINE.SpendCapacity() end }
--   MS.Update(frame, res)   (every frame; acts every 30)   MS.OnCreated(uid, defID, builderID, frame)   MS.OnFinished(uid, frame)
--   MS.OnDestroyed(uid, attackerID, attackerDefID, frame) (logging)
-- Log rows "[SINK]".  Tests: tests/test_metal_sink.lua, tests/test_dragon_eco_bot.lua (the whole macro).

local M = {}
local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")   -- typed WG access (bar_framework/wg_channels.lua)
local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")   -- spend / energy / unit-cap questions (C3)
local BT = VFS.Include("LuaUI/Widgets/bar_framework/build_tree.lua")   -- the build tree (C1): which lab makes the unit, who places it

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")   -- unit roles per faction (C4)
M.CFG = {
    SINK_UNIT         = ROLES.Get("sink_unit"),   -- the unit the sink makes (a Dragon)
    SINK_LAB          = nil,         -- the lab that makes it; nil = the cheapest lab that has SINK_UNIT in its build options
    SINK_SPEND_FRAC   = 0.85,        -- the first lab starts when income >= this x what the spine can spend ...
    SINK_MIN_INCOME   = 500,         -- ... and never below this income (a few nanos early on make a tiny capacity)
    SINK_INCOME       = 2000,        -- smoothed metal income (m/s) that starts it when the spine reports no capacity
    SINK_FRONT        = 700,         -- elmos past the spine's front-most block to the first row
    SINK_PITCH        = 384,         -- elmos between sink spots: lab width (4 nanos) + 4 nanos of room (a nano is 48)
    SINK_ROW          = 5,           -- spots per row (middle, then alternating sides)
    SINK_HELPERS      = 6,           -- free air cons (any tier) that assist the con that places the lab (55 BP alone: ~10 min)
    SINK_TIMEOUT      = 150 * 30,    -- frames for the frame to appear before the spot is given up
    SINK_MAX          = 10,
    SINK_PARALLEL     = 3,           -- labs being built at once
    SINK_TRIES        = 6,           -- a lab frame that keeps dying at one spot is given up (the spot rests SINK_BAD_FRAMES)
    SINK_LAB_UTIL     = 0.8,         -- share of a lab's absorb the lab count plans on
    SINK_DECOYS       = 32,          -- decoy commanders one sink lab can have assisting it
    SINK_BAD_FRAMES   = 100 * 30,    -- a spot that could not be built on is not tried again for this long
    SINK_FLOAT_FRAC   = 0.10,        -- one more lab while the metal bank has held max(SINK_FLOAT_MIN, FRAC x storage) ...
    SINK_FLOAT_MIN    = 3000,
    SINK_FLOAT_FRAMES = 20 * 30,     -- ... for this long
}

local Spring, UnitDefs, UnitDefNames, WG, Game, CMD = Spring, UnitDefs, UnitDefNames, WG, Game, CMD
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local CMD_REPAIR = (CMD and CMD.REPAIR) or 40

local E, K, CB = nil, M.CFG, nil
local SK = { jobs = {}, done = {}, nDone = 0, bad = {} }
M.State = SK

local function Clock(frame) return E.Clock and E.Clock(frame) or string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

function M.Init(env)
    E = env
    K = {}
    for k, v in pairs(M.CFG) do K[k] = (env.cfg and env.cfg[k] ~= nil) and env.cfg[k] or v end
    CB = env.CB
    SK = { jobs = {}, done = {}, nDone = 0, bad = {} }
    M.State = SK
end

-- ── what the sink makes and the lab for it ─────────────────────────────────────────────────────────

local function UnitDef() return UnitDefNames[K.SINK_UNIT] end

-- The lab that makes the sink unit: SINK_LAB, else the cheapest factory with the unit among its build options.
function M.LabDef()
    if SK.labDef ~= nil then return SK.labDef or nil end
    local u = UnitDef()
    local best
    if u then
        if K.SINK_LAB and UnitDefNames[K.SINK_LAB] then best = UnitDefNames[K.SINK_LAB]
        else best = BT.CheapestLab(u) end
    end
    SK.labDef = best or false
    return best
end

-- The unit's energy cost per metal (a Dragon: 14.1).  nil without a sink unit.
function M.UnitEnergyPerMetal()
    local u = UnitDef()
    if not u or (u.metalCost or 0) <= 0 then return nil end
    return (u.energyCost or 0) / u.metalCost
end

-- The energy:metal ratio the economy should aim at because of the sink: the sink unit's, from the moment a lab is wanted (a spot picked).
function M.EnergyRatio()
    if SK.nDone == 0 and #SK.jobs == 0 then return nil end
    return M.UnitEnergyPerMetal()
end

-- true when an air constructor can place the lab (a T2 air plant, a gantry: T2 air cons build both); else a ground con must
-- (a T2 bot lab: a T1 bot con) and it is borrowed from the spine's own cons (E.BorrowCon / E.GiveBackCon).
local function AirCanPlace()
    if SK.airOK ~= nil then return SK.airOK end
    local lab = M.LabDef()
    SK.airOK = lab ~= nil and #BT.Placers(lab).air > 0
    return SK.airOK
end

-- Can this builder place the sink lab?
local function CanPlace(conID)
    local lab = M.LabDef()
    return lab ~= nil and BT.CanBuild(spGetUnitDefID(conID), lab.id)
end

-- ── sink spots ───────────────────────────────────────────────────────────────────────────────────────────

-- Position of spot n (1-based) on the lattice, or nil when the spine has no front yet.
local function SpotPos(n)
    local SPINE = E.SPINE()
    local geo, blocks
    if SPINE and SPINE.Front then geo, blocks = SPINE.Front() end
    if not geo or not blocks or #blocks == 0 then return nil end
    if not SK.origin then
        local mx, mz, front = 0, 0, -1e18
        for _, b in ipairs(blocks) do mx, mz = mx + b.x / #blocks, mz + b.z / #blocks end
        for _, b in ipairs(blocks) do front = math.max(front, (b.x - mx) * geo.dx + (b.z - mz) * geo.dz) end
        SK.origin = { x = mx + geo.dx * (front + K.SINK_FRONT), z = mz + geo.dz * (front + K.SINK_FRONT), geo = geo }
    end
    local o = SK.origin
    local row, j = math.floor((n - 1) / K.SINK_ROW), (n - 1) % K.SINK_ROW
    local off = math.floor((j + 1) / 2) * ((j % 2 == 1) and 1 or -1)      -- 0, +1, -1, +2, -2
    local x = o.x + o.geo.dx * row * K.SINK_PITCH + o.geo.px * off * K.SINK_PITCH
    local z = o.z + o.geo.dz * row * K.SINK_PITCH + o.geo.pz * off * K.SINK_PITCH
    x, z = math.floor(x / 16) * 16 + 8, math.floor(z / 16) * 16 + 8
    return x, z, o.geo.facing or 0
end
M.SpotPos = SpotPos

local function SpotTaken(n)
    for _, L in pairs(SK.done) do if L.spot == n then return true end end
    for _, J in ipairs(SK.jobs) do if J.spot == n then return true end end
    return false
end

-- The first free sink spot where the lab can be built (open ground, none of our other structures near), or nil.
local function FindSpot(frame)
    local lab = M.LabDef()
    if not lab then return nil end
    local mapX, mapZ = (Game and Game.mapSizeX) or 8192, (Game and Game.mapSizeZ) or 8192
    local tried = 0
    for n = 1, K.SINK_MAX + K.SINK_ROW * 2 do
        if not SpotTaken(n) and not (SK.bad[n] and frame - SK.bad[n] < K.SINK_BAD_FRAMES) then
            local x, z, facing = SpotPos(n)
            if not x then return nil end
            tried = tried + 1
            local ok = false
            if x > 200 and z > 200 and x < mapX - 200 and z < mapZ - 200 then
                local y = Spring.GetGroundHeight(x, z) or 0
                local t = Spring.TestBuildOrder(lab.id, x, y, z, facing)
                ok = t and t > 0
                if ok then
                    -- no structure of ours (except the other sink labs, which the lattice keeps apart) close by
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 200, E.teamID) or {}) do
                        local ud = UnitDefs[spGetUnitDefID(uid) or -1]
                        if ud and (ud.speed or 0) == 0 and not SK.done[uid] then ok = false; break end
                    end
                end
                if ok then return x, y, z, facing, n end
            end
            SK.bad[n] = frame
        end
    end
    return nil
end

-- ── labs in flight ─────────────────────────────────────────────────────────────────────────────────────────
-- A JOB is one lab being placed: { spot, x, y, z, facing, con, groundCon, id (the frame), helpers, since, tries }.  Up to
-- SINK_PARALLEL jobs run at once, so a sink that has to absorb thousands of m/s is not limited to one lab every few minutes.

local function ReleaseCons(J)
    local trans = E.trans()
    if not (trans and trans.CB and CB) then return end
    if J.con and J.groundCon then
        if E.GiveBackCon then E.GiveBackCon(J.con) end
    elseif J.con then CB.Release(trans.CB, J.con, false) end
    J.groundCon = nil
    for id in pairs(J.helpers) do CB.Release(trans.CB, id, true) end
    J.con, J.helpers = nil, {}
end

local function DropJob(J)
    for i, other in ipairs(SK.jobs) do if other == J then table.remove(SK.jobs, i); break end end
end

-- ── published state ───────────────────────────────────────────────────────────────────────────────────────

local function Publish()
    if not WG then return end
    local ids = {}
    for id in pairs(SK.done) do ids[#ids + 1] = id end
    table.sort(ids)
    if not WG.SinkLabs then CH.Publish(WG, "SinkLabs", {}) end
    if not WG.DragonLabs then CH.Publish(WG, "DragonLabs", {}) end
    for id in pairs(WG.SinkLabs) do if not SK.done[id] then WG.SinkLabs[id] = nil end end
    for id in pairs(WG.DragonLabs) do if not SK.done[id] then WG.DragonLabs[id] = nil end end
    for _, id in ipairs(ids) do
        local L = SK.done[id]
        local rec = WG.SinkLabs[id] or { id = id, x = L.x, z = L.z, ready = true, decoys = {}, decoyMax = K.SINK_DECOYS,
                                         unit = K.SINK_UNIT, spot = L.spot }
        WG.SinkLabs[id], WG.DragonLabs[id] = rec, rec
    end
    CH.Publish(WG, "DragonLab", ids[1] and WG.SinkLabs[ids[1]] or nil)
end

-- ── how many labs ──────────────────────────────────────────────────────────────────────────────────────

-- True when the spine's spend is the limit: income has reached SINK_SPEND_FRAC of what it can spend.
function M.SpineSaturated(res)
    local cap = (E.Capacity and E.Capacity()) or LEDGER.Capacity(WG, "spine")
    return LEDGER.Saturated(res, cap, { satFrac = K.SINK_SPEND_FRAC, minIncome = K.SINK_MIN_INCOME, fallbackIncome = K.SINK_INCOME })
end

-- Metal/s one finished sink lab can put into the sink unit: its own build power plus its decoys' (SINK_DECOYS x the decoy's), times
-- the unit's metal per build power.  (A Dragon lab with 32 decoys: ~10k BP x 5100 / 120000 = ~420 m/s.)
function M.LabAbsorb()
    local u, lab = UnitDef(), M.LabDef()
    if not (u and lab and (u.buildTime or 0) > 0) then return nil end
    local decoy = UnitDefNames[E.decoyDef or ROLES.Get("decoy")]
    local bp = (lab.buildSpeed or 0) + K.SINK_DECOYS * ((decoy and decoy.buildSpeed) or 300)
    return bp * (u.metalCost or 0) / u.buildTime
end

-- Labs the sink should have now.  0 until the spine is saturated.  Then enough to absorb what the spine cannot spend (income minus the
-- spine's full capacity, at SINK_LAB_UTIL of a lab's absorb), and one more than there are while the metal bank floats -- the sink exists
-- to stop banking, so a floating bank always asks for another lab.  Never more than SINK_MAX.
function M.DesiredLabs(frame, res)
    local have = SK.nDone + #SK.jobs
    local sat, cap = M.SpineSaturated(res)
    SK.lastCap = cap
    if have == 0 and not sat then return 0 end
    local want = math.max(have, 1)
    local inc = res.metalIncomeS or res.metalIncome or 0
    local absorb = M.LabAbsorb()
    if absorb and absorb > 0 then
        local surplus = math.max(0, inc - (cap or 0))
        want = math.max(want, math.ceil(surplus / (K.SINK_LAB_UTIL * absorb)))
    end
    local floating = res.metal >= math.max(K.SINK_FLOAT_MIN, K.SINK_FLOAT_FRAC * res.metalStorage)
    if floating then
        SK.floatSince = SK.floatSince or frame
        if frame - SK.floatSince >= K.SINK_FLOAT_FRAMES then want = math.max(want, have + 1) end
    else
        SK.floatSince = nil
    end
    return math.min(want, K.SINK_MAX)
end

-- ── the update ─────────────────────────────────────────────────────────────────────────────────────────

local function SendBuilder(id, J, lab)
    spGiveOrderToUnit(id, -lab.id, { J.x, J.y, J.z, J.facing }, {})
end

-- A con takes a waiting job (the con broker's "sinklab" job, or a borrowed ground con).
local function StartJob(J, id, frame, lab, ground)
    J.con, J.groundCon, J.since, J.tries = id, ground or nil, frame, J.tries + 1
    SendBuilder(id, J, lab)
    Spring.Echo(string.format("[SINK] %s %scon %d places the sink lab (%s) at spot %d (%d, %d), try %d", Clock(frame),
        ground and "spine " or "", id, lab.name, J.spot, J.x, J.z, J.tries))
end

local function WaitingJob()
    for _, J in ipairs(SK.jobs) do if not J.con and not J.id then return J end end
    return nil
end

function M.Update(frame, res)
    local trans = E.trans()
    if not (trans and trans.CB and CB) or frame % 30 ~= 0 then return end
    local cb = trans.CB
    local lab = M.LabDef()
    if not lab then return end
    LEDGER.Register(WG, "sink", { energyPerMetal = M.EnergyRatio })     -- line_transition's energy push reads the ledger's energy target
    -- finished labs that died
    for id in pairs(SK.done) do
        if not spGetUnitDefID(id) then
            SK.done[id], SK.nDone = nil, SK.nDone - 1
            if trans.noConLabs then trans.noConLabs[id] = nil end
            Spring.Echo(string.format("[SINK] %s sink lab %d lost (%d left)", Clock(frame), id, SK.nDone))
            Publish()
        end
    end
    -- the jobs
    local helperTaken = false
    for _, J in ipairs({ unpack(SK.jobs) }) do
        if J.id and spGetUnitDefID(J.id) then
            -- the con and the helpers keep building the frame: an unfinished frame nobody builds decays.  Any of them that has
            -- gone idle (or was given something else) is told to repair it again.
            local function KeepBuilding(id)
                if not (id and spGetUnitDefID(id)) then return end
                local q = Spring.GetUnitCommands(id, 1)
                local c = q and q[1]
                if not c or not ((c.id == CMD_REPAIR and c.params and c.params[1] == J.id) or c.id == -lab.id) then
                    spGiveOrderToUnit(id, CMD_REPAIR, { J.id }, {})
                    SK.retold = (SK.retold or 0) + 1
                end
            end
            KeepBuilding(J.con)
            for id in pairs(J.helpers) do KeepBuilding(id) end
            if frame % 900 == 0 then
                local _, prog = Spring.GetUnitIsBeingBuilt(J.id)
                local nh = 0
                for id in pairs(J.helpers) do if spGetUnitDefID(id) then nh = nh + 1 end end
                Spring.Echo(string.format("[SINK] %s sink lab frame %d (spot %d): %.0f%% built, %d helpers, re-told %d times",
                    Clock(frame), J.id, J.spot, 100 * (prog or 0), nh, SK.retold or 0))
            end
            -- helpers: free air cons repair the frame until it finishes (one new helper per tick across all jobs)
            local n = 0
            for id in pairs(J.helpers) do if spGetUnitDefID(id) then n = n + 1 else J.helpers[id] = nil end end
            if n < K.SINK_HELPERS and not helperTaken then
                -- any air con, free first, else one from a lower-priority helper job (the frame alone took ~4 min in eco_sim)
                local id = CB.Take(cb, "sinklab", { kind = "air", near = { J.x, J.z }, useReserve = true, preempt = true })
                if id then
                    helperTaken = true
                    J.helpers[id] = true
                    spGiveOrderToUnit(id, CMD_REPAIR, { J.id }, {})
                end
            end
        elseif J.id then          -- the lab (or its frame) died: place it again (a spot that keeps failing is given up for a while)
            Spring.Echo(string.format("[SINK] %s sink lab %d at spot %d lost before it finished (try %d)", Clock(frame), J.id, J.spot, J.tries))
            if trans.noConLabs then trans.noConLabs[J.id] = nil end
            ReleaseCons(J)
            J.id, J.since = nil, nil
            if J.tries >= K.SINK_TRIES then SK.bad[J.spot] = frame; DropJob(J) end
        else
            if J.con and not spGetUnitDefID(J.con) then J.con = nil end
            if not J.con then
                -- waiting for a con.  Air labs: the con broker's "sinklab" job hands one over (below).  A ground lab: one of the
                -- spine's own cons, borrowed from the spine.
                if not AirCanPlace() then
                    local id = E.BorrowCon and E.BorrowCon(lab.id)
                    if id then StartJob(J, id, frame, lab, true)
                    elseif frame - (SK.lastNoCon or -1e9) >= 1800 then
                        SK.lastNoCon = frame
                        Spring.Echo(string.format("[SINK] %s no spine con can place the %s yet", Clock(frame), lab.name))
                    end
                end
            elseif frame - J.since > K.SINK_TIMEOUT then
                Spring.Echo(string.format("[SINK] %s spot %d (%d, %d) timed out", Clock(frame), J.spot, J.x, J.z))
                SK.bad[J.spot] = frame
                ReleaseCons(J)
                DropJob(J)
            else
                local q = Spring.GetUnitCommands(J.con, 1)
                if (not q or #q == 0) and frame - J.since > 90 then SendBuilder(J.con, J, lab) end
            end
        end
    end
    -- more labs wanted: open jobs (spots) up to SINK_PARALLEL in flight
    local want = M.DesiredLabs(frame, res)
    while SK.nDone + #SK.jobs < want and #SK.jobs < K.SINK_PARALLEL do
        local x, y, z, facing, spot = FindSpot(frame)
        if not x then
            if not SK.noSite then SK.noSite = true; Spring.Echo(string.format("[SINK] %s no free sink spot", Clock(frame))) end
            break
        end
        SK.jobs[#SK.jobs + 1] = { spot = spot, x = x, y = y, z = z, facing = facing, helpers = {}, tries = 0 }
        local cap = SK.lastCap
        Spring.Echo(string.format("[SINK] %s spot %d (%d, %d) for sink lab #%d of %d wanted (%s -> %s): waiting for a con (income %.0f, spine can spend %s, bank %.0f / %.0f)",
            Clock(frame), spot, x, z, SK.nDone + #SK.jobs, want, lab.name, K.SINK_UNIT, res.metalIncomeS or 0,
            cap and string.format("%.0f", cap) or "?", res.metal, res.metalStorage))
    end
    -- the con broker's job: one con per waiting lab (air labs only)
    if #SK.jobs > 0 and not SK.job and AirCanPlace() then
        SK.job = true
        if cb.byName and cb.byName["sinklab"] then CB.RemoveJob(cb, "sinklab") end     -- a second Init on the same broker must not assert
        CB.AddJob(cb, { name = "sinklab", section = "sink", prio = 95, tier = "any", useReserve = true,
            want = function() local n = 0; for _, J in ipairs(SK.jobs) do if not J.con and not J.id then n = n + 1 end end; return n end,
            canTake = function(id) return CanPlace(id) end,
            near = function() local J = WaitingJob(); if J then return J.x, J.z end end,
            start = function(id, f)
                local J = WaitingJob()
                if not J then return false end
                StartJob(J, id, f, lab, false)
                return true
            end })
    end
end

function M.OnCreated(unitID, unitDefID, builderID, frame)
    local lab = M.LabDef()
    if not (lab and unitDefID == lab.id) then return end
    for _, J in ipairs(SK.jobs) do
        if not J.id and J.con and J.con == builderID then
            J.id = unitID
            local trans = E.trans()
            if trans then trans.noConLabs = trans.noConLabs or {}; trans.noConLabs[unitID] = true end
            Spring.Echo(string.format("[SINK] %s sink lab frame %d started (spot %d)", Clock(frame), unitID, J.spot))
            return
        end
    end
end

function M.OnFinished(unitID, frame)
    for _, J in ipairs(SK.jobs) do
        if J.id == unitID then
            SK.done[unitID], SK.nDone = { x = J.x, z = J.z, spot = J.spot }, SK.nDone + 1
            ReleaseCons(J)
            DropJob(J)
            Publish()
            Spring.Echo(string.format("[SINK] %s sink lab %d finished at spot %d (%d standing, %d in flight)", Clock(frame), unitID, J.spot, SK.nDone, #SK.jobs))
            return
        end
    end
end

function M.OnDestroyed(unitID, attackerID, attackerDefID, frame)
    for _, J in ipairs(SK.jobs) do
        if J.id == unitID then
            local ad = attackerDefID and UnitDefs[attackerDefID]
            local _, prog = Spring.GetUnitIsBeingBuilt(unitID)
            Spring.Echo(string.format("[SINK] %s sink lab %d destroyed by %s (attacker %s), %.0f%% built", Clock(frame), unitID,
                ad and ad.name or "nothing (decay / reclaim / self)", tostring(attackerID), 100 * (prog or 0)))
            return
        end
    end
end

return M
