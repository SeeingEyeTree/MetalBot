-- bar_framework/proxy/crew.lua  (macro side: the proxy base's builders -- user 2026-11-08)
-- User: "If the base does get up it needs to start quickly scaling bp making pounders and tzars to defend.  This is also where I want to add in static ...
-- quickly get up a t2 lab to make tzars, and then swap over to t2 static.  Scorpion and Persecutor ... the main goal a t2 con with nanos around it
-- building rows of Basilisk."  And the ramp (same day, after the 30-minute game): "Add in t1 vech cons to help build static if more pounders are not
-- needed ... A static build group would be 3 t2 cons and 8 t1 cons, and they keep getting added on and building ... blocks of 64 nanos and then calamities
-- ... a t3 lab ... it just builds Behemoth ... Don't control the nanos except for setting them high prio ... Just don't use air cons."
--
-- The crew = the proxy's ground cons (the convoy's con and what the proxy labs make; owner "proxy" in the con broker).  Every con has a ROLE:
--   core        (T1) the CORE list (BUILD): Castro, radar, nanos, Twin Guards, Thistles, the T2 lab, the bot lab, more T1 static.  Each takes the first short
--               item it can build (counting planned, being built, standing).
--   g1..g4      a STATIC BUILD GROUP (static_group.lua): GROUP_T2 T2 cons and GROUP_T1 T1 cons on ONE item at a time (user: "one group was 3 t2 cons and
--               8 t1 cons all working on the same thing.  So one t2 cons places the blueprint and all the others guard it"): the group's first T2 con
--               places the next static item (Shroud, T2 radar, radar cover, AA, Scorpions, then Persecutors / Bulwarks) on the grid toward the enemy, the
--               rest GUARD it.  Group 1 starts with the T2 lab; one more (up to GROUPS_MAX) whenever every group is full and we are not metal-stalled.
--   block       (T1, BLOCK_CREW) the Basilisk blocks' nanos (lrpc_block.lua: two 8 x 8 squares a block), at fixed spots.
--   gun         (T2, one) the guns, ONE AT A TIME, from the start (not after the nanos): Basilisks round the block's edge, then -- after CALAMITY_AFTER
--               Basilisks -- Calamities in the block's two Calamity squares.  A new block once the current one's slots are full (MAX_BLOCKS).
--   t3lab / t3  (T2 one / T1 T3_CREW) the T3 labs and their 96 nanos each (t3_block.lua, the user's blueprint): a second / third (T3_MAX) once the last
--               one's nanos are mostly up (user: "add more t3 labs don't have it just be the one").
-- All of them start together once the T2 lab stands (user's choice: "all three in parallel").  A con whose work is done gets a new role.
-- The labs make what the crew says (lab_rules' "proxy-lab" want through WG.ProxyBase.want): the T1 lab FIRST_POUNDERS Pounders, then Pounders while the
-- proxy's walls are short (area_defence: mb.defence.proxy.wallShort), else T1 cons up to what the roles want, else Pounders; the T2 lab T2 cons up to what
-- the roles want, then Tzars; the T3 lab Behemoths (the unit side moves them toward the enemy); the bot lab REZ rez bots.
-- The proxy's nanos are NOT ordered (BAR's own nano behaviour builds what is near); they, the cons and the labs get HIGH builder priority.
--
--   local CR = VFS.Include("LuaUI/Widgets/bar_framework/proxy/crew.lua").New{ cfg, CB, trans = fn -> line_transition state, teamID, Clock, WG }
--   CR.Update(frame, S)          every 30 frames while the lab stands; S = proxy_base's state { x, z, facing, labID, ax, az (toward the enemy) }
--   CR.AddCon(uid)   CR.AddLab(uid, kind)   CR.Adopt(uid, kind)   CR.OnCreated(uid, defID, builderID, frame)   CR.OnFinished(uid, frame)
--   CR.OnDestroyed(uid, frame)   CR.Labs() -> { [labID] = "t1" | "t2" | "bot" | "t3" }   CR.Wants() -> { [labID] = unit name }   CR.Standing(kind)
--   CR.Release()   CR.Summary() -> string
-- Log rows [PROXY] crew.

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local DC = VFS.Include("LuaUI/Widgets/bar_framework/defense_crew.lua")
local SG = VFS.Include("LuaUI/Widgets/bar_framework/proxy/static_group.lua")
local LB = VFS.Include("LuaUI/Widgets/bar_framework/proxy/lrpc_block.lua")
local T3B = VFS.Include("LuaUI/Widgets/bar_framework/proxy/t3_block.lua")

local M = {}

M.CFG = {
    FIRST_POUNDERS = 2,      -- the T1 lab's first units
    CORE_CONS      = 4,      -- T1 cons before the T2 lab stands (all core)
    CORE_T1        = 2,      -- ... and on the core list after it
    GROUP_T2       = 3,      -- a static build group: 3 T2 cons ...
    GROUP_T1       = 8,      -- ... and 8 T1 cons guarding them
    GROUPS_MAX     = 4,
    GROUP_ADD_S    = 60,     -- at least this long between new groups
    BLOCK_CREW     = 4,      -- T1 cons on the Basilisk blocks' nanos
    T3_CREW        = 4,      -- T1 cons on the T3 lab's nanos
    T3_MAX         = 3,      -- T3 labs (each with its 96 nanos)
    CALAMITY_AFTER = 15,     -- Basilisks before the Calamities ...
    CAL_BLOCK_FRAME = 20 * 60 * 30,   -- ... and the Calamity blocks (128 nanos each) not before this (user 2026-11-08: "wait much later to build the blocks
                             -- for the Calamity"; the Basilisks stand round the T3 blocks' nanos)
    HIGH_EVERY     = 2,      -- every this-many-th proxy nano gets HIGH builder priority (user: "it starved the bots whole eco ... only half the nanos")
    MAX_BLOCKS     = 4,
    REZ            = 6,      -- rez bots the bot lab keeps
    SCOUT_EVERY_S  = 30,     -- the air lab's scouts: one this often
    -- static_group.lua's mix
    SCORPIONS = 10, AA_EVERY = 5, FLAK_PER = 2, RADAR_COVER = 2100,
    -- the CORE list (T1 cons), first short item first: { what = role, kind = what it counts as (default what), n = how many of that kind in all,
    -- income / orAfterS = held until our income is that or the lab has stood that long; upTo = { kind, frac }: short only while its count is under
    -- frac x that kind's + 1 -- a mix }.  User 2026-11-08: "build a jammer (castro and shroud) first then lab then radar.  t1 then t2 ... adds a t1 bot lab
    -- after the t2 vech to make rez bots" (the Shroud and the T2 radar are the static groups' first items)
    BUILD = {
        { key = "jam1",   what = "jammer_t1",    n = 1 },                        -- (the convoy's con puts it up before the lab: rebuilt if lost)
        { key = "radar1", what = "radar",        n = 1 },
        { key = "nano1",  what = "nano",         n = 4 },
        { key = "hllt1",  what = "hllt",         n = 4 },
        { key = "aa1",    what = "aa_light",     n = 2 },
        { key = "t2lab",  what = "lab_t2_veh",   n = 1, income = 60, orAfterS = 150 },
        { key = "botlab", what = "lab_t1_bot",   n = 1 },                        -- (rez bots)
        -- an air lab once the guns come on line (user 2026-11-08: "add in a t2 air lab that makes a scout every 30 seconds to get vision in the proxy
        -- base after the lrpcs start coming on line" -- a ground con cannot build the T2 air plant, so it is the T1 one: a Finch every SCOUT_EVERY_S)
        { key = "airlab", what = "lab_t1_air",   n = 1, afterLrpc = true },
        { key = "nano2",  what = "nano",         n = 10 },
        { key = "hllt2",  what = "hllt",         n = 8 },
        { key = "aa2",    what = "aa_light",     n = 4 },
        { key = "ghllt",  what = "hllt",         kind = "grid_hllt", n = 40 },
        { key = "gaa",    what = "aa_light",     kind = "grid_aa", n = 12, upTo = { kind = "grid_hllt", frac = 0.3 } },
        -- nanos in the static grid (user 2026-11-08: "mix a few nanos into the static grid, they can help build repair and reclaim"): one per 4 defences
        { key = "gnano",  what = "nano",         kind = "grid_nano", n = 30, upTo = { kinds = { "grid_pop", "grid_arty", "grid_bulwark", "grid_hllt" }, frac = 0.25 } },
    },
    GRID           = 130,    -- the static grid's spacing
    GRID_LAT       = 900,    -- ... it reaches this far to each side of the enemy axis
    -- where each kind stands, from the lab: r = distance range, arc = half-width (radians) round the bearing, side = "front" (toward the enemy) | "back";
    -- grid = rows across the enemy axis from f0 to f1 out (the line advances: nearest row first); near = round a given point (the radar cover)
    PLACE = {
        nano       = { r0 = 300, r1 = 460, side = "back",  arc = 2.0 },
        hllt       = { r0 = 330, r1 = 430, side = "front", arc = 1.4 },
        aa_light   = { r0 = 220, r1 = 320, side = "front", arc = 1.6 },
        lab_t2_veh = { r0 = 420, r1 = 680, side = "back",  arc = 1.4 },
        jammer_t1  = { r0 = 300, r1 = 520, side = "back",  arc = 1.2 },
        radar      = { r0 = 300, r1 = 520, side = "back",  arc = 1.6 },
        jammer_t2  = { r0 = 320, r1 = 560, side = "back",  arc = 1.6 },
        radar_t2   = { r0 = 320, r1 = 560, side = "back",  arc = 1.8 },
        lab_t1_bot = { r0 = 420, r1 = 720, side = "back",  arc = 1.6 },
        lab_t1_air = { r0 = 420, r1 = 760, side = "back",  arc = 1.8 },
        cover_radar = { near = true, r0 = 150, r1 = 450 },
        grid_hllt  = { grid = true, f0 = 450, f1 = 1300 },
        grid_aa    = { grid = true, f0 = 300, f1 = 1000 },
        grid_pop   = { grid = true, f0 = 450, f1 = 2400 },
        grid_bulwark = { grid = true, f0 = 450, f1 = 2400 },
        grid_arty  = { grid = true, f0 = 250, f1 = 2200 },
        grid_flak  = { grid = true, f0 = 250, f1 = 1800 },
        grid_screamer = { grid = true, f0 = 200, f1 = 1600 },
        grid_nano  = { grid = true, f0 = 300, f1 = 2200 },
    },
    EXIT_CLEAR     = 90,     -- nothing stands within this of the lab's exit lane (lateral), up to EXIT_LEN in front of it
    EXIT_LEN       = 500,
    SPACING        = 70,     -- spot candidates this far apart along a ring
    ORDER_TIMEOUT  = 25 * 30, -- a build order with no frame after this is dropped (the spot is remembered as bad)
    HIGH_PRIORITY  = true,
    LOG_EVERY      = 1800,
}

local CMD_GUARD, CMD_REPAIR = 25, 40

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do
        if M.CFG[k] == nil then Spring.Echo("[PROXY] crew option '" .. tostring(k) .. "' is not a crew option (typo?)") end
        C[k] = v
    end
    local CR = { cfg = C }
    local cons = {}          -- [uid] = { since, item, role, t2 }
    local items = {}         -- list of { key, what, kind, defID, x, z, facing, con, orderF, frameID, uid }
    local labs = {}          -- [labID] = "t1" | "t2" | "bot" | "t3"
    local made = {}          -- [labID] = { [defID] = n }  units each proxy lab made
    local bad = {}           -- [cell key] = true: spots a build failed on
    local rez = {}           -- [uid] = true: the bot lab's rez bots
    local highAt = {}        -- [uid] = frame of the second HIGH order
    local blocks = {}        -- the Basilisk blocks: { x, z, nanos, cal, bas = { {x, z, skipUntil} } }
    local t3s = {}           -- the T3 blocks: { x, z, facing, nanos }
    local t3TryF = -1e9
    local groupsWanted, groupAddF = 0, -1e9
    local logF, startF = -1e9, nil
    local stats = { built = {}, lost = {} }

    local function Clock(f) return o.Clock and o.Clock(f) or string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end
    local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
    local function Def(role) return UnitDefNames[ROLES.Get(role) or role] end
    local function CanBuild(uid, defID)
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        for _, b in ipairs((d and d.buildOptions) or {}) do if b == defID then return true end end
        return false
    end
    local function IsT2(uid) local d = Def("con_t2_veh"); return d ~= nil and Spring.GetUnitDefID(uid) == d.id end

    local function Count(kind)
        local n = 0
        for _, it in ipairs(items) do if it.kind == kind then n = n + 1 end end
        return n
    end
    local function Standing(kind)
        local n = 0
        for _, it in ipairs(items) do if it.kind == kind and it.uid then n = n + 1 end end
        return n
    end
    CR.Standing = Standing

    -- the proxy's build power gets HIGH builder priority (user 2026-11-08: "make sure the nanos that are part of the proxy base are high prio ... give
    -- all of the proxy bp first dibs on metal"); sent again a second later (BAR's Builder Priority widget sets new builders LOW in its UnitFinished)
    local nanoHigh = 0
    local function High(uid, frame)
        local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD
        Spring.GiveOrderToUnit(uid, (gc and gc.PRIORITY) or 34571, { 1 }, {})
        highAt[uid] = (frame or Spring.GetGameFrame()) + 30
    end

    function CR.Labs() return labs end
    function CR.AddLab(labID, kind)
        labs[labID] = kind
        made[labID] = made[labID] or {}
        if not Spring.GetUnitIsBeingBuilt(labID) then High(labID) end
    end
    -- a building of ours the crew did not order (the jammer the convoy's con put up before the lab): it counts as one of `kind`
    function CR.Adopt(uid, kind)
        local x, _, z = Spring.GetUnitPosition(uid)
        if not x then return end
        local fin = not Spring.GetUnitIsBeingBuilt(uid)
        items[#items + 1] = { key = kind, what = kind, kind = kind, defID = Spring.GetUnitDefID(uid), x = x, z = z, orderF = Spring.GetGameFrame(),
                              frameID = uid, uid = fin and uid or nil }
    end

    function CR.AddCon(uid, frame)
        if cons[uid] or not Alive(uid) then return end
        cons[uid] = { since = frame or Spring.GetGameFrame(), t2 = IsT2(uid) }
        if C.HIGH_PRIORITY then High(uid, frame) end
        Spring.Echo(string.format("[PROXY] %s crew: con %d (%s) joins", Clock(frame or 0), uid, (UnitDefs[Spring.GetUnitDefID(uid) or -1] or {}).name or "?"))
    end

    -- ── fixed spots (the blocks' nanos, the T3 lab) ──
    local function ItemAt(x, z, kind)
        for _, it in ipairs(items) do if it.kind == kind and (it.x - x) ^ 2 + (it.z - z) ^ 2 < 400 then return it end end
        return nil
    end
    local function FirstFree(list, defID, kind, frame, facing)
        for _, p in ipairs(list) do
            if frame >= (p.skipUntil or 0) and not ItemAt(p.x, p.z, kind) then
                local y = Spring.GetGroundHeight(p.x, p.z) or 0
                if (Spring.TestBuildOrder(defID, p.x, y, p.z, facing or 0) or 0) > 0 then return p end
                p.skipUntil = frame + 1800                               -- (something stands there: looked at again in a minute)
            end
        end
        return nil
    end
    local function Missing(list, kind, frame)
        local n = 0
        for _, p in ipairs(list or {}) do if frame >= (p.skipUntil or 0) and not ItemAt(p.x, p.z, kind) then n = n + 1 end end
        return n
    end

    -- ── spots ──
    local function Cell(x, z) return math.floor(x / 48) .. ":" .. math.floor(z / 48) end
    local function InExit(S, x, z)
        if not S.labID then return false end
        local ex = ({ [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } })[S.facing or 0] or { 0, 1 }
        local dx, dz = x - S.x, z - S.z
        local fwd, lat = dx * ex[1] + dz * ex[2], math.abs(dx * ex[2] - dz * ex[1])
        return fwd > 0 and fwd < C.EXIT_LEN and lat < C.EXIT_CLEAR
    end
    local function Taken(x, z, r)
        for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.z - z) ^ 2 < r * r then return true end end
        return false
    end
    -- the Basilisk blocks and the T3 block are kept free of everything else ("the nano block is the main thing that should be protected")
    local function Reserved(x, z, pad)
        pad = pad or 0
        for _, b in ipairs(blocks) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (LB.R + pad) ^ 2 then return true end end
        for _, t in ipairs(t3s) do if (t.x - x) ^ 2 + (t.z - z) ^ 2 < (T3B.R + 60 + pad) ^ 2 then return true end end
        return false
    end
    local function Free(S, x, z, r)
        return x > 64 and z > 64 and x < Game.mapSizeX - 64 and z < Game.mapSizeZ - 64 and not bad[Cell(x, z)] and not InExit(S, x, z) and not Taken(x, z, r)
    end

    -- the spot for `kind` round the lab (P.near: round `at`): rings r0..r1, bearings from the side's axis outward (alternating); grid kinds: rows across
    -- the enemy axis, nearest row first, the middle of a row first.  Clear of the exit, our other items and the reserved blocks.
    local function Spot(S, kind, defID, at)
        local P = C.PLACE[kind] or C.PLACE.nano
        local d = UnitDefs[defID]
        local half = d and math.max(d.xsize or 2, d.zsize or 2) * 4 or 16
        local facing = S.facing or 0
        local function Try(x, z, r)
            if Free(S, x, z, r) and not Reserved(x, z, half) then
                local y = Spring.GetGroundHeight(x, z) or 0
                local t = Spring.TestBuildOrder(defID, x, y, z, facing)
                if t and t > 0 then return x, y, z end
            end
        end
        if P.grid then
            local ax, az = S.ax or 1, S.az or 0
            local px, pz = -az, ax
            for f = P.f0, P.f1, C.GRID do
                for k = 0, 2 * math.floor(C.GRID_LAT / C.GRID) do
                    local l = ((k % 2 == 1) and 1 or -1) * math.ceil(k / 2) * C.GRID
                    local x, y, z = Try(S.x + ax * f + px * l, S.z + az * f + pz * l, half + 30)
                    if x then return x, y, z, facing end
                end
            end
            return nil
        end
        local ox, oz = S.x, S.z
        local base = math.atan2(S.az or 0, S.ax or 1)
        if P.side == "back" then base = base + math.pi end
        local arc = P.arc or math.pi
        if P.near and at then
            ox, oz = at[1], at[2]
            base = math.atan2(S.z - oz, S.x - ox)                       -- (toward the lab first: behind the defence it covers)
        end
        for r = P.r0, P.r1, 48 do
            local steps = math.max(1, math.floor(arc * math.max(r, 48) / C.SPACING))
            for k = 0, 2 * steps do
                local off = (k % 2 == 1) and math.ceil(k / 2) or -math.ceil(k / 2)
                local a = base + off * arc / steps
                local x, y, z = Try(ox + math.cos(a) * r, oz + math.sin(a) * r, half + 40)
                if x then return x, y, z, facing end
            end
        end
        local x, y, z = DC.FindSite(defID, ox, oz, math.max(P.r0, 60), P.r1 + 200, base, bad)   -- (defense_crew's ring search as a last resort)
        if x and not InExit(S, x, z) and not Reserved(x, z, half) then return x, y, z, 0 end
        return nil
    end

    local function OrderAt(frame, uid, spec, x, y, z, facing)
        local it = { key = spec.key or spec.kind, what = spec.what, kind = spec.kind, defID = spec.defID, x = x, z = z, facing = facing or 0, con = uid, orderF = frame }
        items[#items + 1] = it
        cons[uid].item = it
        Spring.GiveOrderToUnit(uid, -spec.defID, { x, y or Spring.GetGroundHeight(x, z) or 0, z, facing or 0 }, {})
        return true
    end

    local noSpot = {}        -- [key] = frame until which an item that found no spot is passed over (the next one in the list is tried)
    local function NoSpot(frame, key, name, S)
        noSpot[key] = frame + 600
        if frame - (CR.noSpotF or -1e9) >= 900 then
            CR.noSpotF = frame
            Spring.Echo(string.format("[PROXY] %s crew: no spot for a %s round %d,%d", Clock(frame), name, S.x, S.z))
        end
    end

    -- ── the core list ──
    local function NextItem(frame, uid)
        local _, _, _, inc = Spring.GetTeamResources(o.teamID, "metal")
        for _, b in ipairs(C.BUILD) do
            local d = Def(b.what)
            local kind = b.kind or b.what
            local mixOk = true
            if b.upTo then
                local base = 0
                for _, k in ipairs(b.upTo.kinds or { b.upTo.kind }) do base = base + Count(k) end
                mixOk = Count(kind) < b.upTo.frac * base + 1
            end
            if d and Count(kind) < b.n and CanBuild(uid, d.id) and frame >= (noSpot[b.key] or 0) and mixOk and not (b.afterLrpc and Standing("lrpc") == 0) then
                local gated = b.income and (inc or 0) < b.income and not (b.orAfterS and startF and frame - startF >= b.orAfterS * 30)
                if not gated then return b, d end
            end
        end
        return nil
    end
    local function CoreWork(frame, S, uid)
        local b, d = NextItem(frame, uid)
        while b do
            local x, y, z, facing = Spot(S, b.kind or b.what, d.id)
            if x then return OrderAt(frame, uid, { key = b.key, what = b.what, kind = b.kind or b.what, defID = d.id }, x, y, z, facing) end
            NoSpot(frame, b.key, d.name, S)
            b, d = NextItem(frame, uid)
        end
        return false
    end

    -- ── the static groups' T2 cons ──
    local function GroupWork(frame, S, uid)
        local n = SG.Next(C, Count, items)
        local d = n and Def(n.what)
        if not (d and CanBuild(uid, d.id)) or frame < (noSpot[n.kind] or 0) then return false end
        local x, y, z, facing = Spot(S, n.kind, d.id, n.at)
        if x then return OrderAt(frame, uid, { key = n.kind, what = n.what, kind = n.kind, defID = d.id }, x, y, z, facing) end
        NoSpot(frame, n.kind, d.name, S)
        return false
    end

    -- ── the Basilisk blocks ──
    local function BlockOk(S)
        return function(x, z)
            if (x - S.x) ^ 2 + (z - S.z) ^ 2 < 600 * 600 then return false end
            for _, b in ipairs(blocks) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (2 * LB.R - 120) ^ 2 then return false end end
            for _, t in ipairs(t3s) do if (t.x - x) ^ 2 + (t.z - z) ^ 2 < (LB.R + T3B.R) ^ 2 then return false end end
            local nd = Def("nano")
            local good = 0
            for _, c in ipairs({ { 0, 0 }, { -LB.HALF, -LB.HALF }, { LB.HALF, -LB.HALF }, { -LB.HALF, LB.HALF }, { LB.HALF, LB.HALF } }) do
                local px, pz = x + c[1], z + c[2]
                if nd and (Spring.TestBuildOrder(nd.id, px, Spring.GetGroundHeight(px, pz) or 0, pz, 0) or 0) > 0 then good = good + 1 end
            end
            return good >= 4
        end
    end
    local function AddBlock(frame, S)
        if #blocks >= C.MAX_BLOCKS then return false end
        local x, z = LB.Centre(S, #blocks + 1, BlockOk(S))
        if not x then
            if frame - (CR.noBlockF or -1e9) >= 1800 then CR.noBlockF = frame; Spring.Echo(string.format("[PROXY] %s crew: no room for Basilisk block %d", Clock(frame), #blocks + 1)) end
            return false
        end
        local b = { x = x, z = z, nanos = LB.Nanos(x, z), cal = LB.Calamities(x, z), bas = LB.Basilisks(x, z, S.ax or 1, S.az or 0) }
        blocks[#blocks + 1] = b
        Spring.Echo(string.format("[PROXY] %s crew: Basilisk block %d at %d,%d (%d nanos, %d Basilisk and %d Calamity spots)", Clock(frame), #blocks, x, z,
            #b.nanos, #b.bas, #b.cal))
        return true
    end
    local function BlockMissing(frame)
        local n = 0
        for _, b in ipairs(blocks) do n = n + Missing(b.nanos, "block_nano", frame) end
        return n
    end
    local function BlockNanoWork(frame, uid)
        local nd = Def("nano")
        if not (nd and CanBuild(uid, nd.id)) then return false end
        for _, b in ipairs(blocks) do
            local p = FirstFree(b.nanos, nd.id, "block_nano", frame)
            if p then return OrderAt(frame, uid, { what = "nano", kind = "block_nano", defID = nd.id }, p.x, nil, p.z, 0) end
        end
        return false
    end
    local function StandingNear(kind, x, z, r)
        local n = 0
        for _, it in ipairs(items) do if it.kind == kind and it.uid and (it.x - x) ^ 2 + (it.z - z) ^ 2 <= r * r then n = n + 1 end end
        return n
    end
    -- the gun con: one gun at a time, from the start (user: "The Basilisk can start being built before the nano block finishes"): Basilisks round the
    -- blocks' edges, then Calamities in their squares; a new block once the current kind has no spot left (and the last block's nanos are mostly up)
    local function GunWork(frame, S, uid)
        local cal = Count("lrpc") >= C.CALAMITY_AFTER
        local role, kind = cal and "lrpc_t3" or "lrpc", cal and "calamity" or "lrpc"
        local d = Def(role)
        if not (d and CanBuild(uid, d.id)) then return false end
        local lists = {}
        if cal then for _, blk in ipairs(blocks) do lists[#lists + 1] = blk.cal end
        else
            for _, t in ipairs(t3s) do if t.bas then lists[#lists + 1] = t.bas end end
            for _, blk in ipairs(blocks) do lists[#lists + 1] = blk.bas end
        end
        for _, list in ipairs(lists) do
            local p = FirstFree(list, d.id, kind, frame)
            if p then return OrderAt(frame, uid, { what = role, kind = kind, defID = d.id }, p.x, nil, p.z, 0) end
        end
        -- the Calamity phase with no square free: the next block (once the last one's nanos are mostly up)
        if cal and frame >= C.CAL_BLOCK_FRAME then
            local last = blocks[#blocks]
            if not last or StandingNear("block_nano", last.x, last.z, LB.R) >= 0.75 * #last.nanos then AddBlock(frame, S) end
        end
        return false
    end

    -- how far the static stands out from the lab toward the enemy (the proxy groups hold their line in front of it: unit side PROXY_ARMY)
    function CR.Front(S)
        local f = 0
        local ax, az = S.ax or 1, S.az or 0
        for _, it in ipairs(items) do
            if it.uid and (it.kind == "grid_pop" or it.kind == "grid_arty" or it.kind == "grid_bulwark" or it.kind == "grid_hllt") then
                f = math.max(f, (it.x - S.x) * ax + (it.z - S.z) * az)
            end
        end
        return f
    end

    -- ── the T3 lab ──
    local function T3Plan(frame, S)
        if #t3s >= C.T3_MAX or frame - t3TryF < 1800 then return end
        local last = t3s[#t3s]
        if last and Missing(last.nanos, "t3_nano", frame) > 0.15 * #last.nanos then return end      -- (the next one once the last one is mostly up)
        t3TryF = frame
        local t = T3B.Place(S, Def("lab_t3"), Def("nano"), function(x, z, r)
            if (x - S.x) ^ 2 + (z - S.z) ^ 2 < (r + 250) ^ 2 then return false end
            for _, b in ipairs(blocks) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (r + LB.R) ^ 2 then return false end end
            for _, o2 in ipairs(t3s) do if (o2.x - x) ^ 2 + (o2.z - z) ^ 2 < (2 * r) ^ 2 then return false end end
            for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.z - z) ^ 2 < r * r then return false end end
            return true
        end)
        if t then
            -- the Basilisk ring round its nanos (user 2026-11-08: "build the first Basilisk around the t3 block of nanos"): 344 out on each side but
            -- the lab's exit side (16-elmo grid: 8 mod 16 for a Basilisk)
            local dirs = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }
            local ex = dirs[t.facing] or { 1, 0 }
            t.bas = {}
            for _, sd in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                if not (sd[1] == ex[1] and sd[2] == ex[2]) then
                    for k = -312, 312, 96 do t.bas[#t.bas + 1] = { x = t.x + sd[1] * 344 + (-sd[2]) * k, z = t.z + sd[2] * 344 + sd[1] * k } end
                end
            end
            t3s[#t3s + 1] = t
            Spring.Echo(string.format("[PROXY] %s crew: T3 lab block %d at %d,%d (exit facing %d, %d nanos)", Clock(frame), #t3s, t.x, t.z, t.facing, #t.nanos))
        else
            Spring.Echo(string.format("[PROXY] %s crew: no room for T3 lab block %d yet", Clock(frame), #t3s + 1))
        end
    end
    local function T3LabNeeded()
        for _, t in ipairs(t3s) do if not ItemAt(t.x, t.z, "lab_t3") then return t end end
        return nil
    end
    local function T3NanosMissing(frame)
        local n = 0
        for _, t in ipairs(t3s) do n = n + Missing(t.nanos, "t3_nano", frame) end
        return n
    end
    local function T3LabWork(frame, uid)
        local d = Def("lab_t3")
        local t = T3LabNeeded()
        if not (t and d and CanBuild(uid, d.id)) then return false end
        return OrderAt(frame, uid, { what = "lab_t3", kind = "lab_t3", defID = d.id }, t.x, nil, t.z, t.facing)
    end
    local function T3NanoWork(frame, uid)
        local nd = Def("nano")
        if not (nd and CanBuild(uid, nd.id)) then return false end
        for _, t in ipairs(t3s) do
            local p = FirstFree(t.nanos, nd.id, "t3_nano", frame)
            if p then return OrderAt(frame, uid, { what = "nano", kind = "t3_nano", defID = nd.id }, p.x, nil, p.z, 0) end
        end
        return false
    end

    -- ── roles ──
    local function T2LabUp()
        for lid, kind in pairs(labs) do if kind == "t2" and Alive(lid) and not Spring.GetUnitIsBeingBuilt(lid) then return true end end
        return false
    end
    local function RoleCount()
        local n = { t1 = 0, t2 = 0 }
        for _, c in pairs(cons) do
            if c.role then n[c.role] = (n[c.role] or 0) + 1 end
            if c.t2 then n.t2 = n.t2 + 1 else n.t1 = n.t1 + 1 end
        end
        return n
    end
    local function GroupMembers(g, t2)
        local out = {}
        for uid, c in pairs(cons) do if c.role == g and (c.t2 == t2) then out[#out + 1] = uid end end
        table.sort(out)
        return out
    end
    local function Stalled()
        local cur, stor, pull, inc = Spring.GetTeamResources(o.teamID, "metal")
        return (cur or 0) < 0.05 * (stor or 1) and (pull or 0) > 1.02 * (inc or 0)
    end
    local function UpdateGroups(frame)
        if not T2LabUp() then return end
        if groupsWanted == 0 then
            groupsWanted, groupAddF = 1, frame
            Spring.Echo(string.format("[PROXY] %s crew: static build group 1 (%d T2 + %d T1 cons)", Clock(frame), C.GROUP_T2, C.GROUP_T1))
            return
        end
        if groupsWanted >= C.GROUPS_MAX or frame - groupAddF < C.GROUP_ADD_S * 30 or Stalled() then return end
        for g = 1, groupsWanted do
            local key = "g" .. g
            if #GroupMembers(key, true) < C.GROUP_T2 or #GroupMembers(key, false) < C.GROUP_T1 then return end
            for _, uid in ipairs(GroupMembers(key, true)) do if not cons[uid].item then return end end
        end
        groupsWanted, groupAddF = groupsWanted + 1, frame
        Spring.Echo(string.format("[PROXY] %s crew: static build group %d (every group full and building, metal not stalled)", Clock(frame), groupsWanted))
    end
    -- a con with no role gets the first one that wants it
    local function Assign(frame, uid, c)
        local n = RoleCount()
        local up = T2LabUp()
        local function GroupShort(t2)
            local best, bn
            for g = 1, groupsWanted do
                local k = #GroupMembers("g" .. g, t2)
                if k < (t2 and C.GROUP_T2 or C.GROUP_T1) and (not bn or k < bn) then best, bn = "g" .. g, k end
            end
            return best
        end
        if c.t2 then
            if groupsWanted >= 1 and #GroupMembers("g1", true) == 0 then c.role = "g1"
            elseif T3LabNeeded() and (n.t3lab or 0) == 0 then c.role = "t3lab"
            elseif (#blocks > 0 or #t3s > 0) and (n.gun or 0) == 0 then c.role = "gun"
            else c.role = GroupShort(true) or (groupsWanted >= 1 and ("g" .. (uid % groupsWanted + 1))) or "core" end
        else
            if not up or (n.core or 0) < C.CORE_T1 then c.role = "core"
            elseif BlockMissing(frame) > 0 and (n.block or 0) < C.BLOCK_CREW then c.role = "block"
            elseif T3NanosMissing(frame) > 0 and (n.t3 or 0) < C.T3_CREW then c.role = "t3"
            else c.role = GroupShort(false) or "core" end
        end
    end

    -- the units the proxy's labs make (lab_rules' "proxy-lab" want reads it through WG.ProxyBase.want)
    function CR.Wants(frame)
        frame = frame or Spring.GetGameFrame()
        local out = {}
        local n = RoleCount()
        local up = T2LabUp()
        local mb = o.WG and o.WG.MetalBot
        local wallShort = (mb and mb.defence and mb.defence.proxy and mb.defence.proxy.wallShort) or 0
        local t1Want = up and (C.CORE_T1 + (BlockMissing(frame) > 0 and C.BLOCK_CREW or 0) + ((T3NanosMissing(frame) > 0) and C.T3_CREW or 0)
                              + C.GROUP_T1 * groupsWanted) or C.CORE_CONS
        local t2Want = C.GROUP_T2 * groupsWanted + ((Standing("lab_t3") < C.T3_MAX) and 1 or 0) + ((#blocks > 0 or #t3s > 0) and 1 or 0)
        for labID, kind in pairs(labs) do
            if Alive(labID) and not Spring.GetUnitIsBeingBuilt(labID) then
                local m = made[labID] or {}
                local function N(role) local d = Def(role); return d and (m[d.id] or 0) or 0 end
                if kind == "bot" then
                    local k = 0
                    for uid in pairs(rez) do if Alive(uid) then k = k + 1 else rez[uid] = nil end end
                    if k < C.REZ then out[labID] = ROLES.Get("rez_bot") end
                elseif kind == "t1" then
                    -- (game 9, 2026-11-08: the walls always wanted Pounders and the lab made nothing else -- 8 T1 cons all game, no block nanos.  While
                    -- the walls are short and the roles want cons, one con per 2 Pounders)
                    local conDef = Def("con_t1_veh")
                    local sinceCon = N("pounder") - (m.poundersAtCon or 0)
                    if N("pounder") < C.FIRST_POUNDERS then out[labID] = ROLES.Get("pounder")
                    elseif n.t1 < t1Want and (wallShort == 0 or sinceCon >= 2) then
                        out[labID] = ROLES.Get("con_t1_veh")
                        if conDef and (m[conDef.id] or 0) ~= (m.consSeen or 0) then m.consSeen, m.poundersAtCon = m[conDef.id] or 0, N("pounder") end
                    else out[labID] = ROLES.Get("pounder") end
                elseif kind == "t2" then
                    if n.t2 < t2Want then out[labID] = ROLES.Get("con_t2_veh") else out[labID] = ROLES.Get("heavy_t2_veh") end
                elseif kind == "t3" then
                    out[labID] = ROLES.Get("heavy_t3")
                elseif kind == "air" then
                    if frame - (m.scoutF or -1e9) >= C.SCOUT_EVERY_S * 30 then out[labID] = ROLES.Get("scout_air") end
                end
            end
        end
        return out
    end

    function CR.Update(frame, S)
        if not (S and S.x and S.labID and Alive(S.labID)) then return end
        startF = startF or frame
        -- dead cons / items out; stale orders dropped
        for uid in pairs(cons) do if not Alive(uid) then cons[uid] = nil end end
        for i = #items, 1, -1 do
            local it = items[i]
            local gone = (it.uid and not Alive(it.uid)) or (it.frameID and not it.uid and not Alive(it.frameID))
            local stale = not it.frameID and not it.uid and (frame - it.orderF > C.ORDER_TIMEOUT or not (it.con and Alive(it.con)))
            if gone or stale then
                if stale then bad[Cell(it.x, it.z)] = true end
                if it.con and cons[it.con] and cons[it.con].item == it then cons[it.con].item = nil end
                if gone then stats.lost[it.kind] = (stats.lost[it.kind] or 0) + 1 end
                table.remove(items, i)
            end
        end
        for _, it in ipairs(items) do                           -- a frame whose con died: another con finishes it
            if it.frameID and not it.uid and not (it.con and Alive(it.con) and cons[it.con] and cons[it.con].item == it) then it.con = nil end
        end
        for uid, f in pairs(highAt) do                                   -- the second HIGH order
            if frame >= f then
                if Alive(uid) then local gc = Game and Game.CustomCommands and Game.CustomCommands.GameCMD; Spring.GiveOrderToUnit(uid, (gc and gc.PRIORITY) or 34571, { 1 }, {}) end
                highAt[uid] = nil
            end
        end
        -- the ramp: groups, the first Basilisk block, the T3 lab -- all once the T2 lab stands
        UpdateGroups(frame)
        if T2LabUp() then
            if #blocks == 0 and Count("lrpc") >= C.CALAMITY_AFTER and frame >= C.CAL_BLOCK_FRAME then AddBlock(frame, S) end
            T3Plan(frame, S)
        end
        -- the block / T3 nano crews short: a group's T1 con moves to them (game 9, 2026-11-08: every T1 con had a group role before the blocks were planned,
        -- and no block nano was ever built)
        do
            local n = RoleCount()
            local function Steal(role)
                for g = groupsWanted, 1, -1 do
                    local t1s = GroupMembers("g" .. g, false)
                    if #t1s > 0 then cons[t1s[#t1s]].role, cons[t1s[#t1s]].item = role, nil; return true end
                end
                return false
            end
            if BlockMissing(frame) > 0 and (n.block or 0) < C.BLOCK_CREW then Steal("block") end
            if T3NanosMissing(frame) > 0 and (n.t3 or 0) < C.T3_CREW then Steal("t3") end
        end
        -- a T3 lab wanted and no con on it: a group's T2 con that is not its leader takes it (eco_sim 2026-11-08: 3 T3 blocks of nanos, 1 lab --
        -- every T2 con had a role and the T2 lab's count was met)
        if T3LabNeeded() and (RoleCount().t3lab or 0) == 0 then
            for g = 1, groupsWanted do
                local t2s = GroupMembers("g" .. g, true)
                if #t2s > 1 then cons[t2s[#t2s]].role, cons[t2s[#t2s]].item = "t3lab", nil; break end
            end
        end
        -- the cons
        for uid, c in pairs(cons) do
            if not c.role then Assign(frame, uid, c) end
            -- (not "is its queue empty": BAR's auto-repair widget gives every idle builder an order, so in game 1 (2026-11-08) the crew's cons never
            -- looked idle and built nothing; the crew orders its cons whenever they have no item of the crew's, whatever else they are doing)
            local q = Spring.GetUnitCommands(uid, 1)
            local h = q and q[1]
            local function Is(id, p1) return h ~= nil and h.id == id and (p1 == nil or (h.params ~= nil and h.params[1] == p1)) end
            local it = c.item
            if it and it.uid then c.item, it = nil, nil end                           -- built
            if it and it.frameID then
                if Alive(it.frameID) then
                    if not (Is(CMD_REPAIR, it.frameID) or Is(-it.defID)) then Spring.GiveOrderToUnit(uid, CMD_REPAIR, { it.frameID }, {}) end
                else c.item, it = nil, nil end
            elseif it then
                -- ordered, no frame yet: the build order must be at the head of its queue (re-sent when something replaced it; dropped after 5 s, the spot remembered)
                if not Is(-it.defID) then
                    if frame - it.orderF > 150 then
                        bad[Cell(it.x, it.z)] = true
                        for i = #items, 1, -1 do if items[i] == it then table.remove(items, i) end end
                        c.item, it = nil, nil
                    elseif frame - (it.resentF or it.orderF) >= 30 then
                        Spring.GiveOrderToUnit(uid, -it.defID, { it.x, Spring.GetGroundHeight(it.x, it.z) or 0, it.z, it.facing or 0 }, {})
                        it.resentF = frame
                    end
                end
            end
            if not c.item then
                local role = c.role
                local done
                if role == "core" then
                    done = CoreWork(frame, S, uid)
                    -- (the cons made before the T2 lab are all core: once the core list has nothing for them, all but CORE_T1 go to the groups / blocks / T3)
                    if not done and T2LabUp() and (RoleCount().core or 0) > C.CORE_T1 then c.role = nil end
                elseif role == "block" then done = BlockNanoWork(frame, uid); if not done then c.role = nil end
                elseif role == "t3" then done = T3NanoWork(frame, uid); if not done then c.role = nil end
                elseif role == "t3lab" then done = T3LabWork(frame, uid); if not done then c.role = nil end
                elseif role == "gun" then done = GunWork(frame, S, uid)
                elseif role and role:sub(1, 1) == "g" then
                    -- the group's first T2 con places the next item; every other con of the group guards it (all on one thing)
                    local t2s = GroupMembers(role, true)
                    local leader = t2s[1]
                    if uid == leader then done = GroupWork(frame, S, uid)
                    elseif leader then
                        if not Is(CMD_GUARD, leader) then Spring.GiveOrderToUnit(uid, CMD_GUARD, { leader }, {}) end
                        done = true
                    else
                        done = CoreWork(frame, S, uid)
                    end
                end
                if not done then
                    -- an unfinished frame of ours (one with no con first), else guard the lab
                    local best, bd
                    local ux, _, uz = Spring.GetUnitPosition(uid)
                    for _, o2 in ipairs(items) do
                        if o2.frameID and not o2.uid and Alive(o2.frameID) and ux and CanBuild(uid, o2.defID) then
                            local dd = (o2.x - ux) ^ 2 + (o2.z - uz) ^ 2
                            if not o2.con then dd = dd - 1e12 end
                            if not bd or dd < bd then best, bd = o2, dd end
                        end
                    end
                    if best then
                        if not best.con then best.con, c.item = uid, best end
                        if not Is(CMD_REPAIR, best.frameID) then Spring.GiveOrderToUnit(uid, CMD_REPAIR, { best.frameID }, {}) end
                    elseif not Is(CMD_GUARD, S.labID) then
                        Spring.GiveOrderToUnit(uid, CMD_GUARD, { S.labID }, {})
                    end
                end
            end
        end
        if frame - logF >= C.LOG_EVERY then
            logF = frame
            Spring.Echo(string.format("[PROXY] %s crew: %s", Clock(frame), CR.Summary()))
        end
    end

    function CR.OnCreated(uid, defID, builderID, frame)
        if builderID and labs[builderID] then
            local m = made[builderID]
            m[defID] = (m[defID] or 0) + 1
            if labs[builderID] == "bot" then rez[uid] = true end
            if labs[builderID] == "air" then m.scoutF = frame end
            return
        end
        if not (builderID and cons[builderID]) then return end
        for _, it in ipairs(items) do
            if not it.frameID and it.defID == defID and it.con == builderID then
                it.frameID = uid
                if it.what == "lab_t2_veh" then
                    CR.AddLab(uid, "t2")
                    Spring.Echo(string.format("[PROXY] %s crew: T2 vehicle lab frame %d at %d,%d", Clock(frame), uid, it.x, it.z))
                elseif it.what == "lab_t1_bot" then
                    CR.AddLab(uid, "bot")
                    Spring.Echo(string.format("[PROXY] %s crew: bot lab frame %d at %d,%d (rez bots)", Clock(frame), uid, it.x, it.z))
                elseif it.what == "lab_t1_air" then
                    CR.AddLab(uid, "air")
                    Spring.Echo(string.format("[PROXY] %s crew: air lab frame %d at %d,%d (a scout every %ds)", Clock(frame), uid, it.x, it.z, C.SCOUT_EVERY_S))
                elseif it.what == "lab_t3" then
                    CR.AddLab(uid, "t3")
                    Spring.Echo(string.format("[PROXY] %s crew: T3 lab frame %d at %d,%d (Behemoths)", Clock(frame), uid, it.x, it.z))
                end
                return
            end
        end
    end

    function CR.OnFinished(uid, frame)
        for _, it in ipairs(items) do
            if it.frameID == uid then
                it.uid = uid
                stats.built[it.kind] = (stats.built[it.kind] or 0) + 1
                -- (the nanos are not ordered: BAR's own nano behaviour builds what is near; every HIGH_EVERY-th one is HIGH -- all of them starved the eco)
                if it.what == "nano" then
                    nanoHigh = nanoHigh + 1
                    if nanoHigh % C.HIGH_EVERY == 0 then High(uid, frame) end
                elseif labs[uid] then High(uid, frame) end
                if it.what == "lab_t2_veh" or it.what == "lab_t3" then
                    Spring.Echo(string.format("[PROXY] %s crew: %s %d up (%.1f min after the proxy lab)", Clock(frame), it.what == "lab_t3" and "T3 lab" or "T2 vehicle lab",
                        uid, (frame - (startF or frame)) / 1800))
                elseif it.kind == "lrpc" or it.kind == "calamity" then
                    Spring.Echo(string.format("[PROXY] %s crew: %s %d up (%d standing)", Clock(frame), it.kind == "lrpc" and "Basilisk" or "Calamity", uid, Standing(it.kind)))
                end
                return
            end
        end
    end

    function CR.OnDestroyed(uid, frame)
        cons[uid] = nil
        if labs[uid] then labs[uid], made[uid] = nil, nil end
    end

    -- the proxy is lost: the cons go back to the broker (free)
    function CR.Release()
        local T = o.trans and o.trans()
        for uid in pairs(cons) do if T and T.CB and o.CB then o.CB.Release(T.CB, uid, false) end end
        cons, items, labs, made, startF, rez, highAt = {}, {}, {}, {}, nil, {}, {}
        blocks, t3s, t3TryF, groupsWanted, groupAddF = {}, {}, -1e9, 0, -1e9
    end

    function CR.Summary()
        local n = RoleCount()
        local roles = {}
        for _, r in ipairs({ "core", "g1", "g2", "g3", "g4", "block", "gun", "t3lab", "t3" }) do if (n[r] or 0) > 0 then roles[#roles + 1] = r .. " " .. n[r] end end
        local parts = {}
        for _, w in ipairs({ "jammer_t1", "radar", "nano", "hllt", "aa_light", "lab_t2_veh", "lab_t1_bot", "lab_t1_air", "jammer_t2", "radar_t2", "cover_radar", "grid_pop",
                             "grid_arty", "grid_bulwark", "grid_flak", "grid_screamer", "block_nano", "lrpc", "calamity", "lab_t3", "t3_nano", "grid_hllt", "grid_aa" }) do
            local c = Count(w)
            if c > 0 then parts[#parts + 1] = string.format("%s %d/%d", w, Standing(w), c) end
        end
        local lost = {}
        for w, k in pairs(stats.lost) do lost[#lost + 1] = w .. " " .. k end
        return string.format("%d T1 + %d T2 cons (%s), %d group(s), %d block(s), %d T3 block(s); standing/planned %s; lost %s", n.t1, n.t2, table.concat(roles, ", "),
            groupsWanted, #blocks, #t3s, table.concat(parts, ", "), #lost > 0 and table.concat(lost, ", ") or "none")
    end

    return CR
end

return M
