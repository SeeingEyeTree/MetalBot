-- bar_framework/proxy_base.lua  (macro side: a forward base -- user 2026-11-08)
-- User (the proof of concept): "give it a better plan when raiding is not working ... when it is clear that raiding is not working it swaps to trying to hold
-- a proxy base 4k elmos away from enemy bp near labs.  It should try to make it near the edge/side of the map so it needs to defend less sides."
-- User (same day, after the first game -- the lab died at 11:22 to ~30 Incisors with no wall and 543 metal of army there): "It should come in one wave and
-- the normal ground army should create the beach head.  When the proxy signal comes in 2 of the army groups should stop raiding and be pulled in as
-- defenders for the area where the base will be ... The t1 lab in the proxy base should just make pounders, to create a wall for itself.  It can ignore
-- the stance, its job is to build the best things to stay alive.  It needs to quickly scale bp ... I think air trans 8 and then just build more.  The air
-- trans should move as one group and be escorted by the fighters."
--
--   WHEN   the raids trade badly (signals' bad_trade rule on mb.trade: lost >= 1000 and killed < 0.5 x lost, or 2+ bad group ends) for HOLD_S, after
--          MIN_FRAME; or at FORCE_FRAME (a test).  Latched: one proxy, re-placed up to TRIES times if its lab dies.
--   WHERE  a point PROXY_D (4000) from the enemy's build power (mb.enemyBP, the unit controller: its labs and static builders), within EDGE of a map
--          edge (the corners and sides need fewer sides held), the one closest to our spawn, where the lab can be built (TestBuildOrder); the lab's
--          exit faces the middle of the map.
--   STATES (WG.ProxyBase.state)
--     "beachhead"  the spot is published: the unit side's PROXY_ARMY sends raid groups there (click_army PROXY: clear it, hold a line) and
--                  area_defence defends it as an area.  It waits until they are there and the ground has been clear CLEAR_S (mb.proxyArmy), at most
--                  BEACH_WAIT_S; with no proxy army on the unit side (nothing published for NO_ARMY_S) it goes at once.
--     "con"        GO: NANOS nano-column nanos and a GROUND CON borrowed from the spine come by the sink's lift (sink_lift.lua: the proxy is a site of
--                  kind "proxy"), with CONVOY all in one escorted wave (sink_lift CONVOY, air_wing ESCORT) round the map's edge (edge_route.lua: "hug the
--                  side of the map so there is less chance they get spotted").  The landed con places a JAMMER (the Castro) and then the LAB (a T1 vehicle
--                  plant) -- user 2026-11-08: "build a jammer (castro and shroud) first then lab then radar.  t1 then t2".  No air cons ("air cons can be
--                  killed much more easily. Just don't use air cons"): the borrow is retried until it works.
--     "hold"       the lab stands: the CREW (proxy/crew.lua) -- the landed con and the labs' cons -- builds the core (nanos, Twin Guards, Thistles, the T2
--                  lab, the bot lab), then static build groups, the Basilisk blocks and the T3 lab; the labs make what the crew says (lab_rules
--                  "proxy-lab"), never the stance's units.
--   HOLD   published as WG.ProxyBase = { x, z, key, labID, frameID, state, con, go, labs = { [labID] = "t1" | "t2" }, want = { [labID] = unit name },
--          static = T2 defences standing, lrpc = Basilisks standing }.
--
--   PX.Init{ cfg = CFG.PROXY, CB = con_broker module, trans = fn -> line_transition state, teamID, Clock, WG }
--   PX.Update(frame)  (every 30 frames)   PX.Sites() -> sink_lift sites   PX.OnCreated(uid, defID, builderID, frame)   PX.OnFinished(uid, frame)
--   PX.OnFromFactory(uid, defID, factID, frame)   PX.OnDestroyed(uid, frame)
-- Log rows [PROXY].

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local AT = VFS.Include("LuaUI/Widgets/bar_framework/air_transport.lua")
local ER = VFS.Include("LuaUI/Widgets/bar_framework/edge_route.lua")

local M = {}

M.CFG = {
    PROXY_D    = 4000,           -- elmos from the enemy's build power
    D_TOL      = 600,            -- ... give or take
    EDGE       = 700,            -- at most this far from a map edge ...
    EDGE_MIN   = 250,            -- ... and at least this
    STEP       = 256,            -- the candidate grid
    MIN_FRAME  = 8 * 60 * 30,    -- no proxy before this
    HOLD_S     = 45,             -- the raids have traded badly this long
    FORCE_FRAME = nil,           -- (test) start at this frame whatever the trade
    NANOS      = 4,              -- nanos the lift flies in
    CONVOY     = false,          -- ... all at once, in one escorted wave (sink_lift CONVOY)
    BEACH      = false,          -- wait for the beachhead (the unit side's PROXY_ARMY) before the con and the nanos go
    BEACH_WAIT_S = 150,          -- ... at most this long
    CLEAR_S    = 10,             -- ... a proxy group at the spot and nothing there for this long
    JAM_D      = 330,            -- the jammer stands this far behind the lab
    STAGE_D    = 2500,           -- the proxy groups wait this far short of the spot (on the edge route, with the convoy) until GO
    SCOUTS     = 0,              -- T2 air scouts (Condors) kept while the proxy has guns (the unit side's LRPC flies them over the enemy in waves)
    LAB_SEARCH = 480,            -- the lab's spot: the chosen one, else the first buildable one within this of it
    LAB_STUCK_S = 20,            -- ... a spot where the con's order made no frame for this long (at the spot) is given up for the next
    GROUND_CON = false,          -- the lab's builder: a ground con borrowed from the spine and flown in with the convoy (needs CONVOY; without it nothing
                                 -- builds the lab -- the air-con builder of the first versions is gone)
    NO_ARMY_S  = 20,             -- no mb.proxyArmy this long after the start: no proxy army, go at once
    CREW       = nil,            -- the crew's options (proxy/crew.lua M.CFG); nil = no crew (the con only guards the lab)
    LAB        = "lab_t1_veh",   -- role of the lab it builds
    TRIES      = 3,
    TIMEOUT    = 150 * 30,       -- frames for the lab frame to appear before the spot is given up
    CON_PRIO   = 97,             -- the con broker job's priority (the sink's lab job is 95)
}

local E, K = {}, {}
local S = { on = false, badSince = nil, tries = 0 }
local CR = nil               -- the crew (proxy/crew.lua), when CREW is set
local CMD_REPAIR, CMD_GUARD = 40, 25

local function Clock(f) return E.Clock and E.Clock(f) or string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function LabDef() return UnitDefNames[ROLES.Get(K.LAB) or K.LAB] end

function M.Init(env)
    E = env or {}
    K = {}
    for k, v in pairs(M.CFG) do K[k] = v end
    for k, v in pairs(type(E.cfg) == "table" and E.cfg or {}) do
        if M.CFG[k] == nil and k ~= "FORCE_FRAME" and k ~= "CREW" then Spring.Echo("[PROXY] option '" .. tostring(k) .. "' is not a proxy_base option (typo?)") end
        K[k] = v
    end
    S = { on = false, badSince = nil, tries = 0 }
    CR = nil
    if K.CREW then
        local CRm = VFS.Include("LuaUI/Widgets/bar_framework/proxy/crew.lua")
        CR = CRm.New{ cfg = type(K.CREW) == "table" and K.CREW or nil, CB = E.CB, trans = E.trans, teamID = E.teamID, Clock = E.Clock, WG = E.WG }
    end
end

local function Publish()
    if not E.WG then return end
    if not S.x then E.WG.ProxyBase = nil; return end
    local labs = {}
    if CR then for id, kind in pairs(CR.Labs()) do labs[id] = kind end end
    if S.labID then labs[S.labID] = "t1" end
    E.WG.ProxyBase = { x = S.x, z = S.z, key = S.tries, labID = S.labID, frameID = S.frameID, state = S.state, con = S.con, go = S.go,
                       stage = S.stageX and { x = S.stageX, z = S.stageZ } or nil,
                       labs = labs, want = CR and CR.Wants() or nil,
                       static = CR and (CR.Standing("grid_pop") + CR.Standing("grid_arty") + CR.Standing("grid_bulwark")) or 0, lrpc = CR and CR.Standing("lrpc") or 0,
                       calamity = CR and CR.Standing("calamity") or 0, front = CR and CR.Front(S) or 0 }
end

-- the bad_trade rule (bar_framework/signals.lua) on the unit controller's trade summary
local function BadTrade()
    local mb = E.WG and E.WG.MetalBot
    local t = mb and mb.trade
    if not t then return false end
    return ((t.lost or 0) >= 1000 and (t.ratio or 1) < 0.5) or (t.badEnds or 0) >= 2
end

local function FindSpot(frame)
    local mb = E.WG and E.WG.MetalBot
    local bp = mb and mb.enemyBP
    local hx, hz = mb and mb.homeX, mb and mb.homeZ
    local lab = LabDef()
    if not (bp and hx and lab) then return nil, "no enemy build power seen yet" end
    local mx, mz = Game.mapSizeX, Game.mapSizeZ
    local cands = {}
    for x = K.STEP / 2, mx, K.STEP do
        for z = K.STEP / 2, mz, K.STEP do
            local e = math.min(x, z, mx - x, mz - z)
            if e >= K.EDGE_MIN and e <= K.EDGE then
                local d = math.sqrt((x - bp.x) ^ 2 + (z - bp.z) ^ 2)
                if math.abs(d - K.PROXY_D) <= K.D_TOL then
                    cands[#cands + 1] = { x = x, z = z, s = math.sqrt((x - hx) ^ 2 + (z - hz) ^ 2) + 2 * math.abs(d - K.PROXY_D), d = d }
                end
            end
        end
    end
    table.sort(cands, function(a, b) return a.s < b.s end)
    for _, c in ipairs(cands) do
        -- the exit faces the middle of the map
        local dx, dz = mx / 2 - c.x, mz / 2 - c.z
        local facing = (math.abs(dx) > math.abs(dz)) and (dx > 0 and 1 or 3) or (dz > 0 and 0 or 2)
        local y = Spring.GetGroundHeight(c.x, c.z) or 0
        local t = Spring.TestBuildOrder(lab.id, c.x, y, c.z, facing)
        if t and t > 0 then return { x = c.x, y = y, z = c.z, facing = facing, d = c.d, bp = bp } end
    end
    return nil, string.format("no buildable spot %d +- %d from the enemy's build power (%d,%d) within %d of an edge (%d candidates)",
        K.PROXY_D, K.D_TOL, bp.x, bp.z, K.EDGE, #cands)
end


local function SendBuild(id)
    local lab = LabDef()
    if lab and S.x then Spring.GiveOrderToUnit(id, -lab.id, { S.x, S.y, S.z, S.facing }, {}) end
end

-- the jammer's spot: JAM_D behind the lab (away from the enemy), clear of the lab and its nano ring
local function JamSpot()
    local d = UnitDefNames[ROLES.Get("jammer_t1") or ""]
    if not (d and S.x) then return nil end
    local bx, bz = -(S.ax or 1), -(S.az or 0)
    for r = K.JAM_D, K.JAM_D + 240, 48 do
        for k = 0, 8 do
            local a = math.atan2(bz, bx) + ((k % 2 == 1) and 1 or -1) * math.ceil(k / 2) * 0.25
            local x, z = S.x + math.cos(a) * r, S.z + math.sin(a) * r
            local y = Spring.GetGroundHeight(x, z) or 0
            if (Spring.TestBuildOrder(d.id, x, y, z, 0) or 0) > 0 then return d, x, y, z end
        end
    end
    return nil
end

-- the con's way to the spot (when it is not flown in): round the map's edge (edge_route), the way that stays clear of the enemy's build power
local function Route(x, z)
    local mb = E.WG and E.WG.MetalBot
    local bp = mb and mb.enemyBP
    return ER.Route(x, z, S.x, S.z, { avoid = bp and bp.x and { x = bp.x, z = bp.z } or nil })
end
local function Moves(id, pts, shiftFirst)
    local first = not shiftFirst
    for _, p in ipairs(pts) do
        Spring.GiveOrderToUnit(id, 10, { p.x, Spring.GetGroundHeight(p.x, p.z) or 0, p.z }, first and {} or { "shift" })
        first = false
    end
    return not first
end
-- GO: the jammer (unless it stands), then the lab, flown round the edge from where the con is
-- the lab's spot (user 2026-11-08, game 5: "let the lab have more than one spot it can be built in.  Putting nanos down can be strange some times" -- the
-- landed nanos took the spot and the con stood 150 s): the chosen spot while it is buildable, else the first buildable one on rings out to LAB_SEARCH
-- round it (16-elmo grid), never one marked bad (an order that made no frame there)
local function LabSpot()
    local lab = LabDef()
    if not (lab and S.x) then return nil end
    S.badLab = S.badLab or {}
    local function Ok(x, z)
        if S.badLab[math.floor(x / 16) .. ":" .. math.floor(z / 16)] then return false end
        return (Spring.TestBuildOrder(lab.id, x, Spring.GetGroundHeight(x, z) or 0, z, S.facing) or 0) > 0
    end
    if S.labX and Ok(S.labX, S.labZ) then return S.labX, S.labZ end
    for r = 0, K.LAB_SEARCH, 48 do
        local n = (r == 0) and 1 or 16
        for k = 0, n - 1 do
            local a = (S.ax and math.atan2(-S.az, -S.ax) or 0) + k * 2 * math.pi / n    -- (behind the spot first: away from the enemy)
            local x, z = math.floor((S.x + math.cos(a) * r) / 16 + 0.5) * 16, math.floor((S.z + math.sin(a) * r) / 16 + 0.5) * 16
            if Ok(x, z) then
                if S.labX and (S.labX ~= x or S.labZ ~= z) then Spring.Echo(string.format("[PROXY] %s the lab moves to %d,%d (%.0f from the spot)", Clock(Spring.GetGameFrame()), x, z, r)) end
                S.labX, S.labZ = x, z
                return x, z
            end
        end
    end
    return nil
end

local function SendOpening(id)
    local lab = LabDef()
    if not (lab and S.x) then return end
    local x, _, z = Spring.GetUnitPosition(id)
    local queued = false
    if x and (x - S.x) ^ 2 + (z - S.z) ^ 2 > 900 * 900 then
        local pts = Route(x, z)
        table.remove(pts)                                                   -- (the spot itself: the builds go there)
        queued = Moves(id, pts)
    end
    if not (S.jamID and Alive(S.jamID)) then
        local jd, jx, jy, jz = JamSpot()
        if jd then Spring.GiveOrderToUnit(id, -jd.id, { jx, jy, jz, 0 }, queued and { "shift" } or {}); queued = true end
    end
    local lx, lz = LabSpot()
    if not lx then
        if Spring.GetGameFrame() - (S.noLabF or -1e9) >= 900 then S.noLabF = Spring.GetGameFrame(); Spring.Echo(string.format("[PROXY] %s no buildable lab spot within %d of %d,%d", Clock(S.noLabF), K.LAB_SEARCH, S.x, S.z)) end
        return
    end
    Spring.GiveOrderToUnit(id, -lab.id, { lx, Spring.GetGroundHeight(lx, lz) or 0, lz, S.facing }, queued and { "shift" } or {})
end

local function ReleaseCon()
    local T = E.trans and E.trans()
    if S.con and T and T.CB and E.CB then E.CB.Release(T.CB, S.con, false) end
    S.con = nil
end

-- the spot -> the enemy's build power (the crew builds its static on that side)
local function Axis()
    local mb = E.WG and E.WG.MetalBot
    local bp = mb and mb.enemyBP
    if bp and bp.x and S.x then
        local dx, dz = bp.x - S.x, bp.z - S.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1 then S.ax, S.az = dx / d, dz / d end
    end
    S.ax, S.az = S.ax or 1, S.az or 0
end


-- the borrowed ground con goes back to the spine (one that landed is the crew's: CR.Release frees it)
local function GiveBackGround()
    local T = E.trans and E.trans()
    if S.gcon and T and T.CB and E.CB and E.CB.GiveBack then
        if S.con == S.gcon then S.con = nil end
        E.CB.GiveBack(T.CB, S.gcon, "proxy")
    end
    S.gcon = nil
end

-- GROUND_CON (game 3, 2026-11-08: the air cons flew the long edge route alone; the one that waited 2500 short of the spot was lost before GO and the next
-- was still 5k out when the lab timed out -- no lab in 3 tries): a ground con from the spine rides in the convoy, under its escort
local function GroundCon(frame)
    if not (K.GROUND_CON and K.CONVOY) then return end
    local T = E.trans and E.trans()
    -- the landed con died before the lab frame went up: another one is borrowed and flown in
    if S.gconLanded and not S.frameID and not S.labID and not (S.con and Alive(S.con)) then
        S.gconLanded, S.gcon, S.con = nil, nil, nil
        Spring.Echo(string.format("[PROXY] %s the proxy's con died before the lab went up: another one is flown in", Clock(frame)))
    end
    if S.gconLanded then return end
    if S.gcon and not Alive(S.gcon) then
        S.gcon = nil
        Spring.Echo(string.format("[PROXY] %s the ground con died before it landed: another one is borrowed", Clock(frame)))
    end
    if S.gcon then
        -- landed: it is the lab's builder now
        local x, _, z = Spring.GetUnitPosition(S.gcon)
        local carried = Spring.GetUnitTransporter and Spring.GetUnitTransporter(S.gcon)
        if x and not carried and S.go and (x - S.x) ^ 2 + (z - S.z) ^ 2 <= 500 * 500 then
            S.gconLanded, S.con, S.conF, S.since = true, S.gcon, frame, frame
            SendOpening(S.con)
            Spring.Echo(string.format("[PROXY] %s ground con %d landed with the convoy: it places the jammer and the lab", Clock(frame), S.con))
        end
        return
    end
    -- (no air con as a fallback, user 2026-11-08: "air cons can be killed much more easily. Just don't use air cons": the borrow is retried)
    if frame - (S.gconTryF or -1e9) < 150 then return end
    S.gconTryF = frame
    local lab, td = LabDef(), UnitDefNames[ROLES.Get("transport_air") or ""]
    local uid = T and T.CB and E.CB and E.CB.TakeAny and lab and E.CB.TakeAny(T.CB, "proxy", { defID = lab.id, kind = "ground", near = { S.x, S.z } })
    if uid and td and not AT.CanCarry(td.id, Spring.GetUnitDefID(uid)) then
        E.CB.GiveBack(T.CB, uid, "proxy")
        Spring.Echo(string.format("[PROXY] %s the light transport cannot lift a %s: trying again", Clock(frame), (UnitDefs[Spring.GetUnitDefID(uid)] or {}).name or "?"))
        uid = nil
    end
    if uid then
        S.gcon = uid
        local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD
        Spring.GiveOrderToUnit(uid, (gc and gc.PRIORITY) or 34571, { 1 }, {})
        Spring.Echo(string.format("[PROXY] %s ground con %d (%s) borrowed from the spine: it rides in with the convoy", Clock(frame), uid, (UnitDefs[Spring.GetUnitDefID(uid)] or {}).name or "?"))
    elseif frame - (S.gconLogF or -1e9) >= 1800 then
        S.gconLogF = frame
        Spring.Echo(string.format("[PROXY] %s no ground con to borrow yet: trying again", Clock(frame)))
    end
end

local function Lost(frame, why)
    Spring.Echo(string.format("[PROXY] %s %s (try %d of %d)", Clock(frame), why, S.tries, K.TRIES))
    if S.gcon and Alive(S.gcon) then GiveBackGround() end
    ReleaseCon()
    if CR then CR.Release() end
    S.on, S.x, S.state, S.labID, S.frameID, S.go, S.jamID = false, nil, nil, nil, nil, nil, nil
    S.gcon, S.gconLanded = nil, nil
    S.badSince = nil
end

local function Start(frame, why)
    local sp, err = FindSpot(frame)
    if not sp then
        if frame - (S.noSpotF or -1e9) >= 1800 then S.noSpotF = frame; Spring.Echo(string.format("[PROXY] %s wanted (%s) but %s", Clock(frame), why, err)) end
        return
    end
    S.on, S.since = true, frame
    S.x, S.y, S.z, S.facing = sp.x, sp.y, sp.z, sp.facing
    S.tries = S.tries + 1
    S.ax, S.az = nil, nil
    Axis()
    S.state, S.go = K.BEACH and "beachhead" or "con", not K.BEACH
    S.gcon, S.gconLanded, S.gconTryF = nil, nil, nil
    S.labX, S.labZ, S.badLab = nil, nil, {}
    -- the STAGE (user 2026-11-08: "it sends out the group to clear the area at ~9 min but the trans don't arrive until 12 min.  The bot saw the units
    -- grouping up out side its base ... keep the ground units that are going to help the proxy further out ... synced up with when the trans come in"):
    -- STAGE_D short of the spot on the edge route from our base -- where the convoy gathers too; the proxy groups wait there until GO
    do
        local mb = E.WG and E.WG.MetalBot
        local hx, hz = (mb and mb.homeX) or S.x, (mb and mb.homeZ) or S.z
        S.stageX, S.stageZ = ER.Back(Route(hx, hz), hx, hz, K.STAGE_D)
    end
    Spring.Echo(string.format("[PROXY] %s %s: proxy base at %d,%d (%.0f from the enemy's build power at %d,%d, %d from the map edge), try %d%s",
        Clock(frame), why, sp.x, sp.z, sp.d, sp.bp.x, sp.bp.z, math.min(sp.x, sp.z, Game.mapSizeX - sp.x, Game.mapSizeZ - sp.z), S.tries,
        K.BEACH and string.format(": beachhead first (at most %ds)", K.BEACH_WAIT_S) or ""))
    Publish()
end

-- the beachhead: the proxy groups are at the spot and it has been clear CLEAR_S, or it waited long enough
local function Beachhead(frame)
    local mb = E.WG and E.WG.MetalBot
    local pa = mb and mb.proxyArmy
    local why
    -- GO: the proxy groups are at the stage AND the convoy is loaded and at its rally point (then the groups move onto the spot and the transports land at
    -- once: nothing is telegraphed by a group standing on the spot for minutes, and the nanos are not in the air waiting)
    local cv = E.WG and E.WG.ProxyConvoy
    local convoyReady = not K.CONVOY or (cv and cv.key == 1000 + S.tries and cv.state == "rally" and (cv.atRally or 0) >= math.max(1, math.floor(0.75 * (cv.n or 1))))
    if pa and pa.key == S.tries then
        S.armySeen = true
        if pa.arrived and convoyReady then
            why = string.format("%d proxy group(s), %d units worth %.0f, at the stage and the convoy at its rally point", pa.groups or 0, pa.n or 0, pa.value or 0)
        end
    end
    if not why and frame - S.since >= K.BEACH_WAIT_S * 30 then
        why = pa and string.format("waited %ds (%d group(s) %s, clear %ds)", K.BEACH_WAIT_S, pa.groups or 0, pa.arrived and "there" or "not there yet", math.floor(pa.clearS or 0))
                 or string.format("waited %ds", K.BEACH_WAIT_S)
    end
    if not why and not S.armySeen and frame - S.since >= K.NO_ARMY_S * 30 then why = "no proxy army on the unit side" end
    if why then
        S.state, S.go, S.since = "con", true, frame
        Spring.Echo(string.format("[PROXY] %s GO after %ds of beachhead: %s", Clock(frame), math.floor((frame - (S.beachF or frame)) / 30), why))
    end
end

function M.Update(frame)
    if frame % 30 ~= 0 then return end
    local T = E.trans and E.trans()
    local cb = T and T.CB
    if not (cb and E.CB) then return end
    -- the trigger
    if not S.on and S.tries < K.TRIES then
        local bad = BadTrade()
        if bad then S.badSince = S.badSince or frame else S.badSince = nil end
        if K.FORCE_FRAME and frame >= K.FORCE_FRAME then Start(frame, "forced (test)")
        elseif frame >= K.MIN_FRAME and S.badSince and frame - S.badSince >= K.HOLD_S * 30 then Start(frame, "raids trading badly") end
        if S.on then S.beachF = frame end
    end
    -- (the air-con job of the first versions is gone: the lab's builder is the ground con the convoy carries; an old job of that name is dropped)
    if not S.job then
        S.job = true
        if cb.byName and cb.byName["proxy"] then E.CB.RemoveJob(cb, "proxy") end
    end
    if not S.on then return end
    Axis()
    GroundCon(frame)
    if S.state == "beachhead" then Beachhead(frame); Publish(); return end
    if S.con and not Alive(S.con) then S.con, S.since = nil, frame end          -- (the timeout counts from the last setback: game 1, a frame
    if S.state == "con" then                                                    -- killed at 13:10 was "timed out" 44 s later from the 11:23 start)
        if S.frameID and not Alive(S.frameID) then S.frameID, S.since = nil, frame end
        if S.con and not S.frameID then
            local q = Spring.GetUnitCommands(S.con, 8)
            local lab = LabDef()
            local has = false
            for _, c in ipairs(q or {}) do if lab and c.id == -lab.id then has = true end end
            if not has and frame - (S.conF or frame) > 30 then SendOpening(S.con); S.conF = frame end
            -- the order stands but no frame comes (the con at the spot LAB_STUCK_S): that spot is bad, the next one
            -- (counted only while the lab order is at the head of its queue: the jammer comes first)
            local cx, _, cz = Spring.GetUnitPosition(S.con)
            local head = q and q[1] and lab and q[1].id == -lab.id
            if head and cx and S.labX and (cx - S.labX) ^ 2 + (cz - S.labZ) ^ 2 < 600 * 600 then S.labHeadF = S.labHeadF or frame else S.labHeadF = nil end
            if S.labHeadF and frame - S.labHeadF > K.LAB_STUCK_S * 30 then
                S.labHeadF = nil
                S.badLab = S.badLab or {}
                S.badLab[math.floor(S.labX / 16) .. ":" .. math.floor(S.labZ / 16)] = true
                Spring.Echo(string.format("[PROXY] %s no lab frame at %d,%d after %ds at the spot: another spot", Clock(frame), S.labX, S.labZ, K.LAB_STUCK_S))
                S.labX = nil
                SendOpening(S.con); S.conF = frame
            end
        elseif S.con and S.frameID then
            local q = Spring.GetUnitCommands(S.con, 1)
            local c = q and q[1]
            if not (c and c.id == CMD_REPAIR and c.params and c.params[1] == S.frameID) then Spring.GiveOrderToUnit(S.con, CMD_REPAIR, { S.frameID }, {}) end
        end
        -- (the timeout counts only while a builder is at the spot: game 3, 2026-11-08, it ran out while an air con was still 5k out on the edge route)
        local cx, _, cz
        if S.con then cx, _, cz = Spring.GetUnitPosition(S.con) end
        if not cx or (cx - S.x) ^ 2 + (cz - S.z) ^ 2 > 800 * 800 then S.since = frame end
        if not S.frameID and frame - S.since > K.TIMEOUT then
            Spring.Echo(string.format("[PROXY] %s no lab frame at %d,%d after %ds: given up (try %d of %d)", Clock(frame), S.x, S.z, K.TIMEOUT / 30, S.tries, K.TRIES))
            if not S.gconLanded then GiveBackGround() end
            ReleaseCon()
            S.on, S.x, S.state, S.go = false, nil, nil, nil
            Publish()
        end
    elseif S.state == "hold" then
        -- SCOUTS (user 2026-11-08: "there was not great scouting before hand so the lrpcs did not know what to shoot.  Have a wave of 10 t2 air scouts
        -- every 90 seconds"): while the proxy has guns, SCOUTS Condors are kept (the unit side flies them over the enemy's build power in waves)
        if CR and K.SCOUTS > 0 and CR.Standing("lrpc") + CR.Standing("calamity") > 0 and E.WG and E.WG.LabOrders and E.WG.LabOrders.Request then
            local sd = UnitDefNames[ROLES.Get("radar_plane") or ""]
            if sd then
                local have = 0
                for _, uid in ipairs(Spring.GetTeamUnits(E.teamID) or {}) do if Spring.GetUnitDefID(uid) == sd.id then have = have + 1 end end
                if have < K.SCOUTS then
                    E.WG.LabOrders.Request("proxy:scouts", { picks = { sd.name }, n = K.SCOUTS - have, tier = "high", require = false })
                end
            end
        end
        if not Alive(S.labID) then
            Lost(frame, string.format("the proxy lab %d is lost", S.labID or -1))
        elseif CR then
            CR.Update(frame, S)
        elseif S.con then
            local q = Spring.GetUnitCommands(S.con, 1)
            if not q or #q == 0 then Spring.GiveOrderToUnit(S.con, CMD_GUARD, { S.labID }, {}) end   -- the con stays: it helps the lab
        end
        if S.labID and frame % 1800 == 0 then
            Spring.Echo(string.format("[PROXY] %s holding the proxy at %d,%d: lab %d, con %s%s", Clock(frame), S.x, S.z, S.labID, tostring(S.con),
                CR and (" | " .. CR.Summary()) or ""))
        end
    end
    Publish()
end

-- the sink lift's site: the nanos come once the beachhead holds (they build the frame with the con); key 1000 + try, so a new spot gets new nano spots.
-- A convoy site is there from the start (go = false): the lift orders its transports during the beachhead, so the wave is ready at GO.
function M.Sites()
    if not (S.on and S.x and (S.go or K.CONVOY)) then return {} end
    -- (frameID: the lab's frame, or before it the jammer's)
    local jamFrame = S.jamID and Alive(S.jamID) and Spring.GetUnitIsBeingBuilt(S.jamID) and S.jamID or nil
    return { { key = 1000 + S.tries, x = S.x, z = S.z, facing = S.facing, kind = "proxy", frameID = S.frameID or jamFrame, labID = S.labID, decoys = 0,
               lab = LabDef(), want = K.NANOS, convoy = K.CONVOY and { go = S.go == true } or nil,
               carry = (S.gcon and not S.gconLanded and Alive(S.gcon)) and { S.gcon } or nil,
               avoid = (function() local mb = E.WG and E.WG.MetalBot; local bp = mb and mb.enemyBP; return bp and bp.x and { x = bp.x, z = bp.z } or nil end)() } }
end

function M.OnCreated(uid, defID, builderID, frame)
    local lab = LabDef()
    local jd = UnitDefNames[ROLES.Get("jammer_t1") or ""]
    if S.on and jd and defID == jd.id and builderID and builderID == S.con then
        S.jamID = uid
        Spring.Echo(string.format("[PROXY] %s jammer %d started by the proxy con", Clock(frame), uid))
    end
    if S.on and S.state == "con" and lab and defID == lab.id and builderID == S.con then
        S.frameID = uid
        local T = E.trans and E.trans()
        if T then T.noConLabs = T.noConLabs or {}; T.noConLabs[uid] = true end
        Spring.Echo(string.format("[PROXY] %s lab frame %d started at %d,%d", Clock(frame), uid, S.x, S.z))
        Publish()
    end
    if CR and S.on then CR.OnCreated(uid, defID, builderID, frame) end
end

function M.OnFinished(uid, frame)
    if S.on and uid == S.frameID then
        S.labID, S.state = uid, "hold"
        local lx, _, lz = Spring.GetUnitPosition(uid)               -- (the lab may stand off the chosen spot: the base is where it is)
        if lx then S.x, S.z, S.y = lx, lz, Spring.GetGroundHeight(lx, lz) or S.y end
        Spring.Echo(string.format("[PROXY] %s proxy lab %d finished at %d,%d (%.1f min after the start)", Clock(frame), uid, S.x, S.z, (frame - S.since) / 1800))
        if CR then
            CR.AddLab(uid, "t1")
            if S.con and Alive(S.con) then CR.AddCon(S.con, frame) end            -- the con that placed it: the crew's first builder
            if S.jamID and Alive(S.jamID) then CR.Adopt(S.jamID, "jammer_t1") end
        end
        Publish()
    end
    if CR and S.on then
        CR.OnFinished(uid, frame)
        local T = E.trans and E.trans()
        if T and CR.Labs()[uid] then T.noConLabs = T.noConLabs or {}; T.noConLabs[uid] = true end   -- (the T2 lab: no air cons from it either)
    end
end

-- a con from one of the proxy's labs is the crew's (owner "proxy" in the con broker: no other job takes it)
function M.OnFromFactory(uid, defID, factID, frame)
    if not (CR and S.on and factID and CR.Labs()[factID]) then return end
    local d = UnitDefs[defID]
    if d and d.isBuilder and (d.speed or 0) > 0 and not d.canFly then
        local T = E.trans and E.trans()
        if T and T.CB and E.CB then E.CB.Add(T.CB, uid, defID); E.CB.Claim(T.CB, uid, "proxy") end
        CR.AddCon(uid, frame)
    end
end

function M.OnDestroyed(uid, frame)
    if uid == S.con then S.con = nil end
    if CR then CR.OnDestroyed(uid, frame) end
end

function M.State() return S end
return M
