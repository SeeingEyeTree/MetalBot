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
    SINK_SPARE_ROWS   = 2,           -- rows of spots searched past SINK_MAX (+ decoy labs): spots off the map or blocked are skipped
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
    -- 2026-10-25 (eco_sim, 6 seeds): "what the spine can spend" leaves out the economy's own spending (grids, retrofits, fusions), so
    -- the first lab went up at 12:21 with 1.5k banked and took cons and metal from the retrofits: -9% income at 20:00, a third fewer
    -- T2 mexes at 18:00.  Now the first lab also needs a floating bank (the SINK_FLOAT_* rule), and the lab count is sized from the
    -- income that is really unspent (income - pull), not income above the spine's capacity.
    SINK_START_FLOAT  = true,
    SINK_START_MIN    = 15000,       -- the first lab's float: the bank held min(SINK_START_CAP, max(SINK_START_MIN, SINK_START_FRAC x storage)) ...
    SINK_START_FRAC   = 0.05,        --   (a 3-5k working bank at 12 min is no float; the real float began at 16-18 min in eco_sim)
    SINK_START_CAP    = 40000,       --   (2026-10-25 game vs a person: 25% of a 504k storage = 126k, the sink started at 20:55 with 226k banked)
    SINK_START_FRAMES = 30 * 30,     -- ... for this long
    SINK_SURPLUS_PULL = true,
    -- THE FORECAST (user 2026-11-04: "there might not be a metal float right this second but the production will go up and the demand will go down"):
    -- with the nano columns' eco forecast (the ledger's "eco" consumer, nano_cols/plan.lua), the surplus the sink sizes itself for is the larger of
    -- now (income - pull) and SINK_FORECAST_H seconds ahead: income then - what the eco can still spend then - what the army and the sink pull now.
    -- The first lab may start on the forecast alone (SINK_FORECAST_START m/s of it for SINK_START_FRAMES), without a floating bank.
    SINK_FORECAST     = false,
    SINK_FORECAST_H   = 150,         -- seconds ahead: about a sink lab + its first decoys
    SINK_FORECAST_START = 800,       -- forecast surplus (m/s) that starts the first lab
    SINK_FORECAST_GATE = 0.85,       -- the forecast counts once the eco units fill this share of the block's unit budget (nano_cols NC_UNIT_FRAC)
    -- DECOY LABS AT THE SINK (user 2026-11-04: "moving the responsibility for building t2 bot labs and bp for them to build decoy coms from the line to
    -- the sink itself"; line_decoy.lua's labs on the line had their exits blocked, and the line made 40-50 decoys a minute where eco_sim wanted 100+).
    -- Some sink spots hold a T2 bot lab (SINK_DECOY_LAB) that makes decoy commanders: its own SINK_DECOY_OWN first (its build power: lab 600 +
    -- 11 x 300 ~ 3.9k, a decoy every ~9 s), then the sink labs'.  The lab is placed by a ground con borrowed from the spine (a T1 bot con can, an air
    -- con cannot), flown there when SINK_LIFT is on.  Published in WG.DecoyLabs (sink = true): lab_rules' "decoy-lab" want owns its queue.
    SINK_DECOY_LABS   = false,
    SINK_DECOY_LAB    = ROLES.Get("lab_t2_bot"),
    SINK_DECOY_OWN    = 11,          -- decoys that assist the decoy lab itself (lab_rules fills these first)
    SINK_DECOY_MAX    = 12,          -- decoy labs at most
    SINK_DECOY_HORIZON = 180,        -- seconds: enough decoy labs to make the decoys still missing within this long ...
    SINK_DECOY_LAB_BP = 3900,        -- ... at this build power each (lab + its own decoys)
    SINK_DECOY_SPEND  = 0.9,         -- decoys wanted = this share of income / one decoy's metal rate on the sink unit (lab_rules DECOY_SPEND)
    -- THE AIR LIFT (bar_framework/sink_lift.lua): nanos of the nano-column block flown to the sink sites for build power in the ramp, phased out as
    -- the decoys arrive (1.5 nanos per decoy), replaced in the block by its recovery.
    SINK_LIFT         = false,
    SINK_LIFT_CON     = true,        -- the decoy lab's ground con is flown to its spot (a T1 bot con walks at 34 elmos/s)
    SINK_LIFT_CON_WAIT = 20 * 30,    -- frames the con waits for a transport before it walks
    SINK_LIFT_TRANSPORTS = 20,       -- light transports at most (74 metal each; a round trip is ~30 s in eco_sim, so 20 move ~40 nanos a minute)
    SINK_LIFT_BUFFER  = 2,           -- nanos picked from the block ahead of a free transport (a picked nano is parked until its flight)
    SINK_DECOY_START_NANOS = 16,     -- nanos a decoy site gets until its own decoys stand (they build the lab frame in seconds)
    SINK_RAMP_NANOS   = 32,          -- nanos a sink lab gets until its decoys stand
    SINK_LIFT_NANOS_MAX = 300,       -- lifted nanos at the sink at most
    SINK_LIFT_KEEP_FRAC = 0.5,       -- never more than this share of the block's nanos away at once
    SINK_LIFT_TIERS   = 1,           -- which block nanos may go: 0 = only those the block would reclaim anyway (all blocks in reach final), 1 = + parked ones,
                                     -- 2 = + nanos still building the eco (eco_sim 2026-11-04, 3 seeds at 0% army: with 2, income at 30:00 was ~1.6k lower)
    SINK_LIFT_BALANCE = 300,         -- frames between phase-out / new-nano passes
    SINK_NURSERY      = false,       -- when the block's idle nanos cannot fill the flights: "rows" = the nano fronts fill the rows the pattern skipped (and refill them
                                     -- once flown); true / "blocks" = nursery blocks of 24 nanos (nano_cols layout "nursery") on building spots
    SINK_NURSERY_MAX  = 4,           -- nursery blocks at most
    SINK_NURSERY_HOLD = 120 * 30,    -- frames after the last shortage that the nurseries are kept
    SINK_NANO_R       = 264,         -- a site's nanos stand within this of it ...
    SINK_NANO_CLEAR   = 216,         -- ... and never this close to another sink spot (FindSpot keeps 200 clear)
    -- THE UNIT CAP (eco_sim 2026-11-04: at the 3000 cap every freed slot went to a decoy -- 33000 build time against a Dragon's 120000 -- and the sink's
    -- spend fell from 4.8k to 1.6k m/s): no new decoys, and no nanos taken from the block, while fewer than this many slots are free.
    SINK_CAP_RESERVE  = 0,           -- slots kept for the sink unit: this + SINK_CAP_PER_LAB x sink labs (0 = off)
    SINK_CAP_PER_LAB  = 2,
}

local Spring, UnitDefs, UnitDefNames, WG, Game, CMD = Spring, UnitDefs, UnitDefNames, WG, Game, CMD
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local CMD_REPAIR = (CMD and CMD.REPAIR) or 40

local E, K, CB = nil, M.CFG, nil
local SK = { jobs = {}, done = {}, nDone = 0, bad = {} }
M.State = SK
local LIFT = nil           -- bar_framework/sink_lift.lua when SINK_LIFT

local function Clock(frame) return E.Clock and E.Clock(frame) or string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

function M.Init(env)
    E = env
    K = {}
    for k, v in pairs(M.CFG) do      -- (not `cfg[k] ~= nil and cfg[k] or v`: that turns an explicit false back into the default)
        if env.cfg and env.cfg[k] ~= nil then K[k] = env.cfg[k] else K[k] = v end
    end
    CB = env.CB
    SK = { jobs = {}, done = {}, nDone = 0, bad = {} }
    M.State = SK
    LIFT = nil
    if K.SINK_LIFT then
        local ok, r = pcall(VFS.Include, "LuaUI/Widgets/bar_framework/sink_lift.lua")
        if ok and r then
            LIFT = r
            LIFT.Init{ teamID = env.teamID, Clock = env.Clock, CB = CB, trans = env.trans, WG = WG, cfg = K,
                       SpotCenters = function(key) return M.SpotCenters(key) end, CapReserve = function() return M.CapReserve() end,
                       decoyBP = function() local d = UnitDefNames[env.decoyDef or ROLES.Get("decoy")]; return d and d.buildSpeed or 300 end }
        else
            Spring.Echo("[SINK] ERROR loading sink_lift: " .. tostring(r))
        end
    end
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

-- The decoy lab (SINK_DECOY_LABS): a T2 bot lab.
function M.DecoyLabDef() return UnitDefNames[K.SINK_DECOY_LAB or ""] end
local function KindLabDef(kind) if kind == "decoy" then return M.DecoyLabDef() end return M.LabDef() end

-- Metal/s one decoy commander puts into the sink unit while it assists a sink lab (a Dragon: 300 x 5100 / 120000 = 12.75; a Juggernaut 7.7).
function M.DecoyRate()
    local u = UnitDef()
    local d = UnitDefNames[(E and E.decoyDef) or ROLES.Get("decoy")]
    if not (u and (u.buildTime or 0) > 0) then return nil end
    return ((d and d.buildSpeed) or 300) * (u.metalCost or 0) / u.buildTime
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
local function AirCanPlace(kind)
    SK.airOK = SK.airOK or {}
    kind = kind or "sink"
    if SK.airOK[kind] ~= nil then return SK.airOK[kind] end
    local lab = KindLabDef(kind)
    SK.airOK[kind] = lab ~= nil and #BT.Placers(lab).air > 0
    return SK.airOK[kind]
end

-- Can this builder place the lab of this kind of site?
local function CanPlace(conID, kind)
    local lab = KindLabDef(kind or "sink")
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
local function FindSpot(frame, kind)
    local lab = KindLabDef(kind or "sink")
    if not lab then return nil end
    local mapX, mapZ = (Game and Game.mapSizeX) or 8192, (Game and Game.mapSizeZ) or 8192
    local tried = 0
    for n = 1, K.SINK_MAX + (K.SINK_DECOY_LABS and K.SINK_DECOY_MAX or 0) + K.SINK_ROW * (K.SINK_SPARE_ROWS or 2) do
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
                    -- no structure of ours (except the other sink labs, which the lattice keeps apart, and nanos the lift is moving) close by
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 200, E.teamID) or {}) do
                        local ud = UnitDefs[spGetUnitDefID(uid) or -1]
                        if ud and (ud.speed or 0) == 0 and not SK.done[uid] and not (LIFT and LIFT.Busy(uid)) then ok = false; break end
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
    for id, L in pairs(SK.done) do if L.kind ~= "decoy" then ids[#ids + 1] = id end end
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
    -- the sink's decoy labs go in WG.DecoyLabs next to any the line made (sink = true marks ours)
    if K.SINK_DECOY_LABS then
        if not WG.DecoyLabs then CH.Publish(WG, "DecoyLabs", {}) end
        for id, rec in pairs(WG.DecoyLabs) do if rec.sink and not SK.done[id] then WG.DecoyLabs[id] = nil end end
        for id, L in pairs(SK.done) do
            if L.kind == "decoy" and not WG.DecoyLabs[id] then
                WG.DecoyLabs[id] = { id = id, x = L.x, z = L.z, ready = true, decoys = {}, decoyMax = K.SINK_DECOY_OWN, line = true, sink = true }
            end
        end
    end
end

-- ── counts by kind ─────────────────────────────────────────────────────────────────────────────────────

local function Count(kind)
    local done, jobs = 0, 0
    for _, L in pairs(SK.done) do if (L.kind or "sink") == kind then done = done + 1 end end
    for _, J in ipairs(SK.jobs) do if (J.kind or "sink") == kind then jobs = jobs + 1 end end
    return done, jobs
end

local function DecoysAlive()
    local d = UnitDefNames[(E and E.decoyDef) or ROLES.Get("decoy")]
    if not d then return 0 end
    return #(Spring.GetTeamUnitsByDefs(E.teamID, { d.id }) or {})
end

-- The plan lab_rules sizes the decoy count from (WG.SinkPlan): the decoy's metal rate on the sink unit, decoys per sink lab, sink labs in flight.
local function PublishPlan()
    if not WG then return end
    local rate = M.DecoyRate()
    if not rate then return end
    local _, jobs = Count("sink")
    CH.Publish(WG, "SinkPlan", { rate = rate, perLab = K.SINK_DECOYS, jobs = jobs, decoyLabs = K.SINK_DECOY_LABS and true or false,
                                 capReserve = M.CapReserve() })
end

-- Unit-cap slots kept for the sink unit (SINK_CAP_RESERVE), 0 when off.
function M.CapReserve()
    if (K.SINK_CAP_RESERVE or 0) <= 0 then return 0 end
    local done = Count("sink")
    return K.SINK_CAP_RESERVE + (K.SINK_CAP_PER_LAB or 0) * done
end

-- Decoy labs the sink should have: enough to make the decoys still missing within SINK_DECOY_HORIZON seconds.  The decoys wanted are
-- lab_rules' own formula (SINK_DECOY_SPEND x income / decoy rate, at most what the sink labs -- standing and in flight -- and the decoy labs
-- have room for); 0 until the first sink lab is wanted.
function M.DesiredDecoyLabs(res)
    if not K.SINK_DECOY_LABS then return 0 end
    local sinkDone, sinkJobs = Count("sink")
    local dDone, dJobs = Count("decoy")
    if sinkDone + sinkJobs == 0 then return 0 end
    local rate = M.DecoyRate()
    if not rate or rate <= 0 then return 0 end
    local room = (sinkDone + sinkJobs) * K.SINK_DECOYS + (dDone + dJobs) * K.SINK_DECOY_OWN
    local inc = res.metalIncomeS or res.metalIncome or 0
    local want = LEDGER.DecoyDemand(inc, room, { spend = K.SINK_DECOY_SPEND, rate = rate, min = 0 })
    local short = want - DecoysAlive()
    local dec = UnitDefNames[(E and E.decoyDef) or ROLES.Get("decoy")]
    local perLab = K.SINK_DECOY_LAB_BP * K.SINK_DECOY_HORIZON / ((dec and dec.buildTime) or 33000)
    local n = math.max(1, math.ceil(math.max(0, short) / math.max(1, perLab)))
    SK.decoyShort = short
    return math.min(K.SINK_DECOY_MAX, math.max(dDone + dJobs, n))
end

-- The sites the air lift serves: every sink spot with a lab standing or being placed.
function M.Sites()
    local out = {}
    for id, L in pairs(SK.done) do
        local kind = L.kind or "sink"
        local rec = (kind == "decoy") and WG and WG.DecoyLabs and WG.DecoyLabs[id] or (WG and WG.SinkLabs and WG.SinkLabs[id])
        local n = 0
        if rec and rec.decoys then for d in pairs(rec.decoys) do if spGetUnitDefID(d) and not Spring.GetUnitIsBeingBuilt(d) then n = n + 1 end end end
        out[#out + 1] = { key = L.spot, x = L.x, z = L.z, facing = L.facing, kind = kind, labID = id, decoys = n, lab = KindLabDef(kind) }
    end
    for _, J in ipairs(SK.jobs) do
        out[#out + 1] = { key = J.spot, x = J.x, z = J.z, facing = J.facing, kind = J.kind or "sink", frameID = J.id, decoys = 0, lab = KindLabDef(J.kind or "sink") }
    end
    for _, x in ipairs((E.extraSites and E.extraSites()) or {}) do out[#out + 1] = x end      -- proxy_base.lua's site (key 1000+), for the lift
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- Centres of every other spot on the lattice (taken or not): a site's nanos keep clear of them.
function M.SpotCenters(exceptKey)
    local out = {}
    for n = 1, K.SINK_MAX + (K.SINK_DECOY_LABS and K.SINK_DECOY_MAX or 0) + K.SINK_ROW * (K.SINK_SPARE_ROWS or 2) do
        if n ~= exceptKey then
            local x, z = SpotPos(n)
            if x then out[#out + 1] = { x = x, z = z } end
        end
    end
    return out
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

-- The surplus SINK_FORECAST_H seconds ahead (m/s), or nil without a forecast: the eco forecast's income then, minus what the eco can still spend
-- then, minus what everything else (army, sink) pulls now.  Logged every minute.
function M.ForecastSurplus(frame, res)
    if not K.SINK_FORECAST then return nil end
    local r = WG and WG.EcoLedger
    local c = r and r.consumers and r.consumers.eco
    if not (c and c.forecast) then return nil end
    local ok, F = pcall(c.forecast, K.SINK_FORECAST_H)
    if not (ok and F) then return nil end
    -- only once the eco has used SINK_FORECAST_GATE of its unit budget ("base it on unitcap for eco taken up"): before that it is still growing, and
    -- a sink sized on a forecast took metal and builders from it (eco_sim 2026-11-04, 60% army: first sink job 17:34 instead of 19:13, metal spent -9%)
    if (F.used or 0) < K.SINK_FORECAST_GATE then return nil end
    local inc = res.metalIncomeS or res.metalIncome or 0
    local pull = res.metalPullS or res.metalPull or 0
    local other = math.max(0, pull - (F.spendNow or 0))
    local s = math.max(inc, F.incFut or inc) - (F.spendFut or 0) - other
    if frame - (SK.fcLogF or -1e9) >= 1800 then
        SK.fcLogF = frame
        Spring.Echo(string.format("[SINK] %s forecast: income %.0f -> %.0f, eco spends %.0f -> %.0f in %ds (%.0fk work left), army + sink pull %.0f -> surplus now %.0f, then %.0f m/s",
            Clock(frame), inc, F.incFut or inc, F.spendNow or 0, F.spendFut or 0, K.SINK_FORECAST_H, (F.remaining or 0) / 1000, other, inc - pull, s))
    end
    return s
end

-- The bank the first lab waits for (SINK_START_*).
function M.StartThreshold(storage)
    return math.min(K.SINK_START_CAP, math.max(K.SINK_START_MIN, K.SINK_START_FRAC * (storage or 0)))
end

-- Labs the sink should have now.  0 until the spine is saturated.  Then enough to absorb what the spine cannot spend (income minus the
-- spine's full capacity, at SINK_LAB_UTIL of a lab's absorb), and one more than there are while the metal bank floats -- the sink exists
-- to stop banking, so a floating bank always asks for another lab.  Never more than SINK_MAX.
function M.DesiredLabs(frame, res)
    local sDone, sJobs = Count("sink")
    local have = sDone + sJobs
    local sat, cap = M.SpineSaturated(res)
    SK.lastCap = cap
    local floating = res.metal >= math.max(K.SINK_FLOAT_MIN, K.SINK_FLOAT_FRAC * res.metalStorage)
    if floating then SK.floatSince = SK.floatSince or frame else SK.floatSince = nil end
    local floated = SK.floatSince ~= nil and frame - SK.floatSince >= K.SINK_FLOAT_FRAMES
    local fc = M.ForecastSurplus(frame, res)
    if have == 0 and K.SINK_START_FLOAT then
        if res.metal >= M.StartThreshold(res.metalStorage) or (fc and fc >= K.SINK_FORECAST_START) then SK.startSince = SK.startSince or frame
        else SK.startSince = nil end
        if not (SK.startSince and frame - SK.startSince >= K.SINK_START_FRAMES) then return 0 end
    elseif have == 0 and not sat then
        return 0
    end
    local want = math.max(have, 1)
    local inc = res.metalIncomeS or res.metalIncome or 0
    local absorb = M.LabAbsorb()
    if absorb and absorb > 0 then
        local surplus
        local pull = res.metalPullS or res.metalPull
        if K.SINK_SURPLUS_PULL and pull then surplus = math.max(0, inc - pull)
        else surplus = math.max(0, inc - (cap or 0)) end
        if fc then surplus = math.max(surplus, fc) end        -- SINK_FORECAST: the surplus that is coming
        want = math.max(want, have + math.ceil(surplus / (K.SINK_LAB_UTIL * absorb)) - (K.SINK_SURPLUS_PULL and pull and sJobs or 0))
    end
    if floated then want = math.max(want, have + 1) end
    return math.min(want, K.SINK_MAX)
end

-- ── the update ─────────────────────────────────────────────────────────────────────────────────────────

local function SendBuilder(id, J, lab)
    spGiveOrderToUnit(id, -lab.id, { J.x, J.y, J.z, J.facing }, {})
end

-- Where a flown con is set down: behind the lab spot (away from the ground lab's exit), within its build reach of the footprint.
local function ConDrop(J, lab)
    local ex = ({ [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } })[J.facing or 0] or { 0, 1 }
    local r = math.max(lab.xsize or 0, lab.zsize or 0) * 4 + 64
    return J.x - ex[1] * r, J.z - ex[2] * r
end

-- A con takes a waiting job (the con broker's "sinklab" job, or a borrowed ground con).  A ground con is flown to the spot when the lift can
-- (SINK_LIFT_CON): the build order goes out when it is set down, or after SINK_LIFT_CON_WAIT with no transport (it walks).
local function StartJob(J, id, frame, lab, ground)
    J.con, J.groundCon, J.since, J.tries = id, ground or nil, frame, J.tries + 1
    local flown = false
    if ground and LIFT and K.SINK_LIFT_CON then
        local x, z = ConDrop(J, lab)
        flown = LIFT.Carry(id, x, z, 100, function(uid, ok)
            if J.con == uid and not J.id then SendBuilder(uid, J, lab) end
            J.liftF = nil
        end)
        if flown then J.liftF = frame end
    end
    if not flown then SendBuilder(id, J, lab) end
    Spring.Echo(string.format("[SINK] %s %scon %d places the %s lab (%s) at spot %d (%d, %d), try %d%s", Clock(frame),
        ground and "spine " or "", id, J.kind or "sink", lab.name, J.spot, J.x, J.z, J.tries, flown and ", flown there" or ""))
end

-- the first waiting job (no con, no frame); air = true / false: only jobs whose lab an air con can / cannot place
local function WaitingJob(air)
    for _, J in ipairs(SK.jobs) do
        if not J.con and not J.id and (air == nil or AirCanPlace(J.kind) == air) then return J end
    end
    return nil
end

function M.Update(frame, res)
    local trans = E.trans()
    if not (trans and trans.CB and CB) or frame % 30 ~= 0 then return end
    local cb = trans.CB
    local lab = M.LabDef()
    if not lab then return end
    LEDGER.Register(WG, "sink", { energyPerMetal = M.EnergyRatio, primary = true })     -- the energy target (eco_ledger EnergyTarget): once the sink is wanted its unit sets it
    -- finished labs that died
    for id, L in pairs(SK.done) do
        if not spGetUnitDefID(id) then
            SK.done[id], SK.nDone = nil, SK.nDone - 1
            if trans.noConLabs then trans.noConLabs[id] = nil end
            Spring.Echo(string.format("[SINK] %s %s lab %d lost (%d left)", Clock(frame), L.kind or "sink", id, SK.nDone))
            Publish()
        end
    end
    -- the jobs
    local helperTaken = false
    for _, J in ipairs({ unpack(SK.jobs) }) do
        local jl = KindLabDef(J.kind) or lab
        if J.id and spGetUnitDefID(J.id) then
            -- the con and the helpers keep building the frame: an unfinished frame nobody builds decays.  Any of them that has
            -- gone idle (or was given something else) is told to repair it again.
            local function KeepBuilding(id)
                if not (id and spGetUnitDefID(id)) or (LIFT and LIFT.Busy(id)) then return end
                local q = Spring.GetUnitCommands(id, 1)
                local c = q and q[1]
                if not c or not ((c.id == CMD_REPAIR and c.params and c.params[1] == J.id) or c.id == -jl.id) then
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
                Spring.Echo(string.format("[SINK] %s %s lab frame %d (spot %d): %.0f%% built, %d helpers, re-told %d times",
                    Clock(frame), J.kind or "sink", J.id, J.spot, 100 * (prog or 0), nh, SK.retold or 0))
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
            Spring.Echo(string.format("[SINK] %s %s lab %d at spot %d lost before it finished (try %d)", Clock(frame), J.kind or "sink", J.id, J.spot, J.tries))
            if trans.noConLabs then trans.noConLabs[J.id] = nil end
            ReleaseCons(J)
            J.id, J.since = nil, nil
            if J.tries >= K.SINK_TRIES then SK.bad[J.spot] = frame; DropJob(J) end
        else
            if J.con and not spGetUnitDefID(J.con) then
                if LIFT then LIFT.Cancel(J.con) end
                J.con, J.liftF = nil, nil
            end
            if not J.con then
                -- waiting for a con.  Air labs: the con broker's "sinklab" job hands one over (below).  A ground lab: one of the
                -- spine's own cons, borrowed from the spine.
                if not AirCanPlace(J.kind) then
                    local id = E.BorrowCon and E.BorrowCon(jl.id)
                    if id then StartJob(J, id, frame, jl, true)
                    elseif frame - (SK.lastNoCon or -1e9) >= 1800 then
                        SK.lastNoCon = frame
                        Spring.Echo(string.format("[SINK] %s no spine con can place the %s yet", Clock(frame), jl.name))
                    end
                end
            elseif J.liftF then
                -- the con waits for its flight: still waiting (not in the air) after SINK_LIFT_CON_WAIT, it walks
                local inAir = Spring.GetUnitTransporter and Spring.GetUnitTransporter(J.con)
                if not (LIFT and LIFT.Busy(J.con)) then
                    J.liftF = nil
                elseif not inAir and frame - J.liftF > K.SINK_LIFT_CON_WAIT then
                    LIFT.Cancel(J.con)
                    J.liftF = nil
                    SendBuilder(J.con, J, jl)
                    Spring.Echo(string.format("[SINK] %s no transport for con %d after %ds: it walks to spot %d", Clock(frame), J.con, K.SINK_LIFT_CON_WAIT / 30, J.spot))
                end
            elseif frame - J.since > K.SINK_TIMEOUT then
                Spring.Echo(string.format("[SINK] %s spot %d (%d, %d) timed out", Clock(frame), J.spot, J.x, J.z))
                SK.bad[J.spot] = frame
                if LIFT then LIFT.Cancel(J.con) end
                ReleaseCons(J)
                DropJob(J)
            else
                local q = Spring.GetUnitCommands(J.con, 1)
                if (not q or #q == 0) and frame - J.since > 90 and not (LIFT and LIFT.Busy(J.con)) then SendBuilder(J.con, J, jl) end
            end
        end
    end
    -- more labs wanted: open jobs (spots) up to SINK_PARALLEL in flight.  Sink labs and decoy labs take turns while both are short.
    local want = M.DesiredLabs(frame, res)
    local wantD = M.DesiredDecoyLabs(res)
    while #SK.jobs < K.SINK_PARALLEL do
        local sD, sJ = Count("sink")
        local dD, dJ = Count("decoy")
        local needS, needD = sD + sJ < want, dD + dJ < wantD
        local kind
        if needD and (not needS or dD + dJ <= sD + sJ) then kind = "decoy" elseif needS then kind = "sink" else break end
        local x, y, z, facing, spot = FindSpot(frame, kind)
        if not x then
            if not SK.noSite then SK.noSite = true; Spring.Echo(string.format("[SINK] %s no free sink spot", Clock(frame))) end
            break
        end
        SK.jobs[#SK.jobs + 1] = { spot = spot, x = x, y = y, z = z, facing = facing, helpers = {}, tries = 0, kind = kind }
        local cap = SK.lastCap
        local kl = KindLabDef(kind)
        Spring.Echo(string.format("[SINK] %s spot %d (%d, %d) for %s lab #%d of %d wanted (%s -> %s): waiting for a con (income %.0f, spine can spend %s, bank %.0f / %.0f%s)",
            Clock(frame), spot, x, z, kind, (kind == "decoy" and dD + dJ or sD + sJ) + 1, kind == "decoy" and wantD or want, kl.name,
            kind == "decoy" and ((E and E.decoyDef) or ROLES.Get("decoy")) or K.SINK_UNIT, res.metalIncomeS or 0,
            cap and string.format("%.0f", cap) or "?", res.metal, res.metalStorage,
            kind == "decoy" and string.format(", decoys short %d", SK.decoyShort or 0) or ""))
    end
    PublishPlan()
    -- the con broker's job: one con per waiting lab an air con can place
    if not SK.job and WaitingJob(true) then
        SK.job = true
        if cb.byName and cb.byName["sinklab"] then CB.RemoveJob(cb, "sinklab") end     -- a second Init on the same broker must not assert
        CB.AddJob(cb, { name = "sinklab", section = "sink", prio = 95, tier = "any", useReserve = true,
            want = function() local n = 0; for _, J in ipairs(SK.jobs) do if not J.con and not J.id and AirCanPlace(J.kind) then n = n + 1 end end; return n end,
            canTake = function(id) local J = WaitingJob(true); return J ~= nil and CanPlace(id, J.kind) end,
            near = function() local J = WaitingJob(true); if J then return J.x, J.z end end,
            start = function(id, f)
                local J = WaitingJob(true)
                if not J then return false end
                StartJob(J, id, f, KindLabDef(J.kind) or lab, false)
                return true
            end })
    end
    if LIFT then
        local okL, errL = pcall(LIFT.Update, frame, M.Sites())
        if not okL then Spring.Echo("[SINK] lift error: " .. tostring(errL)) end
    end
end

function M.OnCreated(unitID, unitDefID, builderID, frame)
    for _, J in ipairs(SK.jobs) do
        local jl = KindLabDef(J.kind)
        if jl and unitDefID == jl.id and not J.id and J.con and J.con == builderID then
            J.id, J.frameF = unitID, frame
            local trans = E.trans()
            if trans then trans.noConLabs = trans.noConLabs or {}; trans.noConLabs[unitID] = true end
            Spring.Echo(string.format("[SINK] %s %s lab frame %d started (spot %d)", Clock(frame), J.kind or "sink", unitID, J.spot))
            return
        end
    end
end

function M.OnFinished(unitID, frame)
    if LIFT then LIFT.OnFinished(unitID, spGetUnitDefID(unitID)) end
    for _, J in ipairs(SK.jobs) do
        if J.id == unitID then
            SK.done[unitID], SK.nDone = { x = J.x, z = J.z, spot = J.spot, facing = J.facing, kind = J.kind or "sink" }, SK.nDone + 1
            ReleaseCons(J)
            DropJob(J)
            Publish()
            Spring.Echo(string.format("[SINK] %s %s lab %d finished at spot %d (%d standing, %d in flight), %.0fs after the frame started", Clock(frame),
                J.kind or "sink", unitID, J.spot, SK.nDone, #SK.jobs, (frame - (J.frameF or frame)) / 30))
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
