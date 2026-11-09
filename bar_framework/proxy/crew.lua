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
--   gp          the PERIMETER group (PERIM_T2 T2 + PERIM_T1 T1 cons, once group 1 is full): the same static mix, but on a ring round everything the proxy
--               has or has planned (the T3 blocks and Calamity blocks to come too), the biggest gap first (user 2026-11-09: "focus the most static builders
--               where the fighting is ... but it should slowly create a group to build along the whole perimeter, make sure it would include the planned
--               buildings, the extra t3 labs and calamities").  With the ring closed it builds on the front grid.
-- All of them start together once the T2 lab stands (user's choice: "all three in parallel").  A con whose work is done gets a new role.
-- Front static that dies twice in one place (the frame killed, or the group's con killed on it) makes a HOT spot (user 2026-11-09: "if it tries to place a
-- building and it dies twice it should pull back a little bit and build persecutors instead of scorpians"): no grid spot at or past it for HOT_S, a
-- Persecutor PULL back toward the lab, and no more Scorpions while a spot is hot.
-- The T3 labs' exit lanes run EXIT_LEN_T3 out with nothing built in them (user: "make sure there is a t2 lab sized hole for them to walk out of").
-- THE STATIC GRID IS SLOTS (user 2026-11-09: "I like the idea it works like the line with slots and you just fill the slots, that should also mean the cons
-- run back and forth less ... it should also fill in a whole row before going to the next one"): rows across the enemy axis GRID apart from SLOT_F0 out,
-- each GRID wide out to GRID_LAT each side; every grid item takes the first free slot in snake order (row 1 left to right, row 2 right to left, ...), so a
-- row is full before the next starts.  A slot whose ground is blocked is looked at again a minute later.
-- AA: one per AA_EVERY ground defences, one per AA_EVERY_AIR while air killed AIR_LOSSES of the proxy's cons / buildings in the last AIR_WINDOW_S.
-- The T2 vehicle lab, the air lab and the bot lab with the core's 14 nanos come from the user's blueprint (blueprints/general/proxy_labs.lua: a column of
-- labs, exits on +x, a ring of nanos), turned to the T1 lab's facing with the T1 lab at one end of the column; without room for it, the old row.
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
    SCORPIONS = 5, AA_EVERY = 3, FLAK_PER = 2, RADAR_COVER = 2100,    -- (AA_EVERY 3, user 2026-11-09: "you will need to add more aa in the static grid")
    AA_EVERY_AIR = 1, AIR_LOSSES = 2, AIR_WINDOW_S = 180,             -- ("If cons are dying to air it should build more aa")
    FLAK_TRUCKS  = 6,        -- ... and the T2 lab makes flak trucks (up to this many standing) ahead of cons / Tzars ("have the t2 lab make flack if needed")
    SLOT_F0        = 300,    -- the first slot row this far out from the lab    -- (5 Scorpions, user 2026-11-09: "heavy t3 units ... stoped best by Bulwarks")
    -- a hot spot: HOT_FAILS front static attempts lost within HOT_R; for HOT_S no grid spot within HOT_R across and from PULL behind it outward, and a
    -- Persecutor PULL back from it toward the lab
    HOT_FAILS = 2, HOT_R = 300, HOT_S = 360, PULL = 300,
    -- the perimeter group: PERIM_T2 + PERIM_T1 cons once group 1 is full (or PERIM_AFTER_S after it was started); a slot every PERIM_STEP on a ring
    -- PERIM_PAD outside everything the proxy has or plans (PLAN_BLOCKS Calamity blocks and every T3 block to come planned ahead)
    PERIM_T2 = 2, PERIM_T1 = 4, PERIM_AFTER_S = 240, PERIM_PAD = 300, PERIM_STEP = 380, PLAN_BLOCKS = 2,
    PLAN_R = 2400,           -- ... planned only this near the lab (game 13, 2026-11-09: a Calamity block planned 3300 out stretched the ring there; the cons died on the way)
    PERIM_NEAR_W = 0.3,      -- a slot's score: its gap to the nearest defence - this x its distance from the lab (the near holes first)
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
        { key = "nano2",  what = "nano",         n = 14 },                       -- (the labs blueprint's 14)
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
        pull_back  = { near = true, r0 = 0, r1 = 260, arc = math.pi },     -- the Persecutor behind a hot spot
        perim      = { near = true, r0 = 0, r1 = 220, arc = math.pi },     -- round a perimeter slot
    },
    EXIT_CLEAR     = 90,     -- nothing stands within this of the lab's exit lane (lateral), up to EXIT_LEN in front of it
    EXIT_LEN       = 500,
    EXIT_LEN_T3    = 3000,   -- a T3 lab's lane: the Behemoths walk out through the static
    T3_LANE_CHECK  = 1400,   -- a new T3 block wants its lane free of what stands this far out (else it is placed anyway)
    LAB_GAP        = 240,    -- the proxy's labs stand in a row beside the T1 lab, this far apart
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
    local futT3, futBlocks, planF = {}, {}, -1e9   -- the T3 blocks and Calamity blocks to come (kept free; the perimeter wraps them)
    local fails, hots, repl = {}, {}, {}           -- lost front static attempts { x, z, f }; hot spots { x, z, f }; Persecutors wanted { x, z }
    local perimOn, perimSlots, perimF = false, {}, -1e9
    local lastS = nil
    local labLost = {}                             -- [cell] = lab frames killed there
    local slots, slotKey = nil, nil                -- the static grid's slots, in fill order { x, z, f, row, skipUntil }
    local airLoss = {}                             -- frames the proxy lost a con / building to an air unit
    local labBP, labBPTried = nil, false
    local flak = {}                                -- [uid] = true: the T2 labs' flak trucks           -- the labs blueprint placed: { [lab kind] = { x, z, facing, r }, nanos = { { x, z } } }
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
    -- inside the exit lane of one of the proxy's labs: the T1 lab, the crew's labs, the T3 labs (user 2026-11-08: "The bot lab some times gets built in a
    -- way that it blocks the exit of the t2 vech lab ... No tzars got out from it")
    local DIRS = { [0] = { 0, 1 }, [1] = { 1, 0 }, [2] = { 0, -1 }, [3] = { -1, 0 } }
    local LAB_KINDS = { lab_t2_veh = true, lab_t1_bot = true, lab_t1_air = true, lab_t3 = true }
    local function InLane(lx, lz, facing, x, z, wide, len)
        local ex = DIRS[facing or 0] or DIRS[0]
        local dx, dz = x - lx, z - lz
        local fwd, lat = dx * ex[1] + dz * ex[2], math.abs(dx * ex[2] - dz * ex[1])
        return fwd > 0 and fwd < (len or C.EXIT_LEN) and lat < (wide or C.EXIT_CLEAR)
    end
    local function InExit(S, x, z)
        if S.labID and InLane(S.x, S.z, S.facing, x, z) then return true end
        for _, it in ipairs(items) do
            if LAB_KINDS[it.kind] and InLane(it.x, it.z, it.facing, x, z, C.EXIT_CLEAR + 40) then return true end
        end
        if labBP then
            for kind, l in pairs(labBP) do
                if kind ~= "nanos" and kind ~= "lab_t1_air" and InLane(l.x, l.z, l.facing, x, z, C.EXIT_CLEAR + 40) then return true end
            end
        end
        -- (the T3 labs, planned ones too: a long lane, the Behemoths' way out through the static)
        for _, t in ipairs(t3s) do if InLane(t.x, t.z, t.facing, x, z, C.EXIT_CLEAR + 40, C.EXIT_LEN_T3) then return true end end
        for _, t in ipairs(futT3) do if InLane(t.x, t.z, t.facing, x, z, C.EXIT_CLEAR + 40, C.EXIT_LEN_T3) then return true end end
        return false
    end
    local function Taken(x, z, r)
        for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.z - z) ^ 2 < r * r then return true end end
        return false
    end
    -- the Basilisk blocks and the T3 block are kept free of everything else ("the nano block is the main thing that should be protected")
    -- inside the labs blueprint's ground (a spot not standing yet): kept for it (user 2026-11-09, game 20: "The t2 lab did not get built since there were
    -- units in the way and twin gaurds were built in it spot.  Make sure you keep the area for buildings clear")
    local function InBP(x, z, pad)
        if not labBP then return false end
        pad = pad or 0
        for kind, l in pairs(labBP) do
            if kind ~= "nanos" then
                local it = ItemAt(l.x, l.z, kind)
                if not (it and it.uid) and (l.x - x) ^ 2 + (l.z - z) ^ 2 < (l.r * 1.5 + pad) ^ 2 then return true end
            end
        end
        for _, n in ipairs(labBP.nanos) do
            local it = ItemAt(n.x, n.z, "nano")
            if not (it and it.uid) and (n.x - x) ^ 2 + (n.z - z) ^ 2 < (n.r + 8 + pad) ^ 2 then return true end
        end
        return false
    end
    local function Reserved(x, z, pad)
        pad = pad or 0
        if InBP(x, z, pad) then return true end
        for _, b in ipairs(blocks) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (LB.R + pad) ^ 2 then return true end end
        for _, b in ipairs(futBlocks) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (LB.R + pad) ^ 2 then return true end end
        for _, t in ipairs(t3s) do if (t.x - x) ^ 2 + (t.z - z) ^ 2 < (T3B.R + 60 + pad) ^ 2 then return true end end
        for _, t in ipairs(futT3) do if (t.x - x) ^ 2 + (t.z - z) ^ 2 < (T3B.R + 60 + pad) ^ 2 then return true end end
        return false
    end
    -- a hot spot ahead: inside HOT_R across the enemy axis of one and no more than PULL behind it
    local function Hot(S, x, z, frame)
        local ax, az = S.ax or 1, S.az or 0
        local f, l = (x - S.x) * ax + (z - S.z) * az, (x - S.x) * -az + (z - S.z) * ax
        for _, h in ipairs(hots) do
            if frame - h.f < C.HOT_S * 30 then
                local hf, hl = (h.x - S.x) * ax + (h.z - S.z) * az, (h.x - S.x) * -az + (h.z - S.z) * ax
                if math.abs(l - hl) < C.HOT_R and f > hf - C.PULL + 60 then return true end
            end
        end
        return false
    end
    local function AnyHot(frame)
        for _, h in ipairs(hots) do if frame - h.f < C.HOT_S * 30 then return true end end
        return false
    end
    local function AirHot(frame)
        local n = 0
        for _, f in ipairs(airLoss) do if frame - f < C.AIR_WINDOW_S * 30 then n = n + 1 end end
        return n >= C.AIR_LOSSES
    end
    local function Free(S, x, z, r)
        return x > 64 and z > 64 and x < Game.mapSizeX - 64 and z < Game.mapSizeZ - 64 and not bad[Cell(x, z)] and not InExit(S, x, z) and not Taken(x, z, r)
    end

    -- ── the labs blueprint ──
    local BP_KIND = {}                                                   -- blueprint unit name -> the crew's kind
    for _, k in ipairs({ "lab_t2_veh", "lab_t1_air", "lab_t1_bot" }) do local nm = ROLES.Get(k); if nm then BP_KIND[nm] = k end end
    local bpLayout
    local function BPRot(x, z, k) for _ = 1, k % 4 do x, z = z, -x end return x, z end
    local function PlanLabBP(S)
        if labBPTried then return labBP end
        labBPTried = true
        if bpLayout == nil then
            local ok, bp = pcall(VFS.Include, "LuaUI/Widgets/blueprints/general/proxy_labs.lua")
            bpLayout = (ok and bp and bp.layout) or false
            if not bpLayout then Spring.Echo("[PROXY] crew: blueprints/general/proxy_labs.lua not found: " .. tostring(bp)) end
        end
        if not bpLayout then return nil end
        local facing = S.facing or 0
        local k = (facing - 1) % 4                                       -- (the blueprint's exits are on +x, facing 1)
        -- the T1 lab at either end of the lab column (x = -88): below the bottom nano row or above the top one, slid along the column until the block clears
        -- what stands round the T1 lab (the convoy's ring of nanos: eco_sim 2026-11-09, no room right beside it) -- the nearest first, so the ring's nanos
        -- reach the near labs too
        local tzs = {}
        for j = 0, 12 do tzs[#tzs + 1] = -192 - 32 * j; tzs[#tzs + 1] = 336 + 32 * j end
        for _, tz in ipairs(tzs) do
            local ox, oz = BPRot(-88, tz, k)
            -- (the origin on the 16-elmo build grid, so every piece stands exactly where the blueprint draws it: eco_sim 2026-11-09, the T1 lab is 0 mod 16
            -- and the column 8 mod 16, so the whole block sat 8 off the grid, each piece snapped its own way and the nanos took the air lab's ground)
            local cx, cz = math.floor((S.x - ox) / 16 + 0.5) * 16, math.floor((S.z - oz) / 16 + 0.5) * 16
            local plan, good = { nanos = {} }, true
            for _, e in ipairs(bpLayout) do
                local dx, dz = BPRot(e.x, e.z, k)
                local x, z = cx + dx, cz + dz
                local d = UnitDefNames[e.n]
                local f = (BP_KIND[e.n] == "lab_t1_air") and ((0 + k) % 4) or facing          -- (the air lab as drawn; the ground labs face the T1 lab's way)
                if not (d and x > 64 and z > 64 and x < Game.mapSizeX - 64 and z < Game.mapSizeZ - 64
                        and (Spring.TestBuildOrder(d.id, x, Spring.GetGroundHeight(x, z) or 0, z, f) or 0) > 0) then good = false; break end
                local r = math.max(d.xsize or 2, d.zsize or 2) * 4
                if BP_KIND[e.n] then plan[BP_KIND[e.n]] = { x = x, z = z, facing = f, r = r }
                else plan.nanos[#plan.nanos + 1] = { x = x, z = z, r = r } end
            end
            if good then
                labBP = plan
                Spring.Echo(string.format("[PROXY] crew: labs blueprint at %d,%d (T1 lab at its %s end, facing %d): T2 lab %d,%d, air lab %d,%d, bot lab %d,%d, %d nanos",
                    cx, cz, tz < 0 and "bot lab's" or "air lab's", facing, plan.lab_t2_veh.x, plan.lab_t2_veh.z, plan.lab_t1_air.x, plan.lab_t1_air.z,
                    plan.lab_t1_bot.x, plan.lab_t1_bot.z, #plan.nanos))
                return labBP
            end
        end
        Spring.Echo(string.format("[PROXY] crew: no room for the labs blueprint round %d,%d: labs in a row, nanos in a ring", S.x, S.z))
        return nil
    end

    -- ── the yard: our ground units standing on a blueprint spot not built yet are moved off it (its builder excepted) ──
    local function ClearYard(frame)
        if not labBP or frame % 90 ~= 0 then return end
        local spots = {}
        for kind, l in pairs(labBP) do
            if kind ~= "nanos" then
                local it = ItemAt(l.x, l.z, kind)
                if not (it and it.frameID) then spots[#spots + 1] = { x = l.x, z = l.z, r = l.r * 1.25 + 40, builder = it and it.con } end
            end
        end
        for _, n in ipairs(labBP.nanos) do
            local it = ItemAt(n.x, n.z, "nano")
            if not (it and it.frameID) then spots[#spots + 1] = { x = n.x, z = n.z, r = n.r + 32, builder = it and it.con } end
        end
        local moved = 0
        for _, sp in ipairs(spots) do
            for _, uid in ipairs(Spring.GetUnitsInCylinder(sp.x, sp.z, sp.r, o.teamID) or {}) do
                local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
                if d and (d.speed or 0) > 0 and not d.canFly and uid ~= sp.builder then
                    local ux, _, uz = Spring.GetUnitPosition(uid)
                    if ux then
                        local dx, dz = ux - sp.x, uz - sp.z
                        local dd = math.sqrt(dx * dx + dz * dz)
                        if dd < 1 then dx, dz, dd = 1, 0, 1 end
                        local out = sp.r + 120
                        local tx, tz = sp.x + dx / dd * out, sp.z + dz / dd * out
                        Spring.GiveOrderToUnit(uid, CMD and CMD.MOVE or 10, { tx, Spring.GetGroundHeight(tx, tz) or 0, tz }, {})
                        moved = moved + 1
                    end
                end
            end
        end
        if moved > 0 and frame - (CR.yardLogF or -1e9) >= 1800 then
            CR.yardLogF = frame
            Spring.Echo(string.format("[PROXY] %s crew: %d unit(s) moved off the labs blueprint's spots", Clock(frame), moved))
        end
    end
    -- the spots kept clear, for the unit side (WG.ProxyBase.keepOut): { { x, z, r }, ... }
    function CR.KeepOut()
        local out = {}
        if not labBP then return out end
        for kind, l in pairs(labBP) do
            if kind ~= "nanos" then
                local it = ItemAt(l.x, l.z, kind)
                if not (it and it.uid) then out[#out + 1] = { x = l.x, z = l.z, r = l.r * 1.25 + 40 } end
            end
        end
        return out
    end

    -- ── the static grid's slots: rows across the enemy axis, filled one row at a time (snake order: the cons walk along a row) ──
    local function Slots(S)
        local key = string.format("%d:%d:%.2f:%.2f", S.x, S.z, S.ax or 1, S.az or 0)
        if slots and slotKey == key then return slots end
        slots, slotKey = {}, key
        local ax, az = S.ax or 1, S.az or 0
        local px, pz = -az, ax
        local n = math.floor(C.GRID_LAT / C.GRID)
        local row = 0
        for f = C.SLOT_F0, 2400, C.GRID do
            row = row + 1
            for j = -n, n do
                local l = ((row % 2 == 1) and j or -j) * C.GRID
                slots[#slots + 1] = { x = S.x + ax * f + px * l, z = S.z + az * f + pz * l, f = f, row = row }
            end
        end
        return slots
    end

    -- the spot for `kind` round the lab (P.near: round `at`): rings r0..r1, bearings from the side's axis outward (alternating); grid kinds: rows across
    -- the enemy axis, nearest row first, the middle of a row first.  Clear of the exit, our other items and the reserved blocks.
    local function Spot(S, kind, defID, at, P2)
        local P = P2 or C.PLACE[kind] or C.PLACE.nano
        local d = UnitDefs[defID]
        local half = d and math.max(d.xsize or 2, d.zsize or 2) * 4 or 16
        local facing = S.facing or 0
        local function Try(x, z, r)
            if Free(S, x, z, r) and not Reserved(x, z, half) and not InBP(x, z, half) then
                local y = Spring.GetGroundHeight(x, z) or 0
                local t = Spring.TestBuildOrder(defID, x, y, z, facing)
                if t and t > 0 then return x, y, z end
            end
        end
        -- the labs blueprint: its labs and nanos at their spots
        local frame0 = Spring.GetGameFrame()
        local bp = (LAB_KINDS[kind] and kind ~= "lab_t3" or kind == "nano") and PlanLabBP(S)
        if bp then
            local list = kind == "nano" and bp.nanos or { bp[kind] }
            for _, l in ipairs(list) do
                if l and not ItemAt(l.x, l.z, kind) and not bad[Cell(l.x, l.z)] then
                    local y = Spring.GetGroundHeight(l.x, l.z) or 0
                    if (Spring.TestBuildOrder(defID, l.x, y, l.z, l.facing or 0) or 0) > 0 then return l.x, y, l.z, l.facing or 0 end
                end
            end
            -- (the spot taken or given up: the row beside the T1 lab -- game 19, 2026-11-09, the blueprint's T2 lab spot went bad and the proxy never got a
            -- T2 lab; a nano with the blueprint's ring full: round the lab as before)
            if kind ~= "nano" and frame0 - (CR.bpFallF or -1e9) >= 1800 then
                CR.bpFallF = frame0
                Spring.Echo(string.format("[PROXY] %s crew: the labs blueprint's %s spot is not buildable: the row beside the T1 lab", Clock(frame0), kind))
            end
        end
        -- a lab: in a ROW beside the T1 lab, across its exit, facing the same way (no exit faces another lab); its own exit lane free of our items
        if LAB_KINDS[kind] and kind ~= "lab_t3" then
            local ex = DIRS[facing] or DIRS[0]
            local px, pz = -ex[2], ex[1]
            for k = 1, 6 do
                for _, sgn in ipairs({ 1, -1 }) do
                    local off = sgn * k * C.LAB_GAP
                    local x, z = math.floor((S.x + px * off) / 16 + 0.5) * 16, math.floor((S.z + pz * off) / 16 + 0.5) * 16
                    local laneFree = true
                    for _, it in ipairs(items) do if InLane(x, z, facing, it.x, it.z, C.EXIT_CLEAR + 40) then laneFree = false; break end end
                    if laneFree then
                        local rx, ry, rz = Try(x, z, half + 24)
                        if rx then return rx, ry, rz, facing end
                    end
                end
            end
            return nil
        end
        if P.grid then
            -- the first free slot (a whole row before the next), out to this kind's reach
            local frame = Spring.GetGameFrame()
            for _, sl in ipairs(Slots(S)) do
                if sl.f <= P.f1 and frame >= (sl.skipUntil or 0) and not Hot(S, sl.x, sl.z, frame) then
                    if Free(S, sl.x, sl.z, half + 30) and not Reserved(sl.x, sl.z, half) and not InBP(sl.x, sl.z, half) then
                        local y = Spring.GetGroundHeight(sl.x, sl.z) or 0
                        if (Spring.TestBuildOrder(defID, sl.x, y, sl.z, facing) or 0) > 0 then return sl.x, y, sl.z, facing end
                        if not Taken(sl.x, sl.z, half + 30) then sl.skipUntil = frame + 1800 end     -- (blocked ground: again in a minute)
                    end
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
        local it = { key = spec.key or spec.kind, what = spec.what, kind = spec.kind, defID = spec.defID, x = x, z = z, facing = facing or 0, con = uid, orderF = frame,
                     perim = spec.perim }
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
        local n = SG.Next(C, Count, items, { repl = repl[1], hot = AnyHot(frame), air = AirHot(frame) })
        local d = n and Def(n.what)
        if not (d and CanBuild(uid, d.id)) or (frame < (noSpot[n.kind] or 0) and not n.repl) then return false end
        local x, y, z, facing = Spot(S, n.kind, d.id, n.at, n.repl and C.PLACE.pull_back or nil)
        if n.repl then table.remove(repl, 1) end                          -- (one try: no room behind it, the grid's own rows go on)
        if x then return OrderAt(frame, uid, { key = n.kind, what = n.what, kind = n.kind, defID = d.id }, x, y, z, facing) end
        if not n.repl then NoSpot(frame, n.kind, d.name, S) end
        return false
    end

    -- ── front static lost twice in one place: a hot spot ──
    local function Fail(it, frame)
        if it.failed or it.uid or not (C.PLACE[it.kind] and C.PLACE[it.kind].grid) then return end
        it.failed = true
        fails[#fails + 1] = { x = it.x, z = it.z, f = frame }
        local sx, sz, k = 0, 0, 0
        for _, fl in ipairs(fails) do
            if frame - fl.f < C.HOT_S * 30 and (fl.x - it.x) ^ 2 + (fl.z - it.z) ^ 2 <= C.HOT_R ^ 2 then sx, sz, k = sx + fl.x, sz + fl.z, k + 1 end
        end
        if k < C.HOT_FAILS then return end
        local hx, hz = sx / k, sz / k
        for _, h in ipairs(hots) do
            if frame - h.f < C.HOT_S * 30 and (h.x - hx) ^ 2 + (h.z - hz) ^ 2 <= C.HOT_R ^ 2 then h.f = frame; return end   -- (still hot: kept on)
        end
        hots[#hots + 1] = { x = hx, z = hz, f = frame }
        local S = lastS
        local px, pz = hx, hz
        if S then
            local dx, dz = S.x - hx, S.z - hz
            local dd = math.max(1, math.sqrt(dx * dx + dz * dz))
            local pull = math.max(0, math.min(C.PULL, dd - 100))
            px, pz = hx + dx / dd * pull, hz + dz / dd * pull
        end
        repl[#repl + 1] = { x = px, z = pz }
        Spring.Echo(string.format("[PROXY] %s crew: HOT spot at %d,%d (%d static attempts lost there): pulling back, a Persecutor at %d,%d, no Scorpions for %ds",
            Clock(frame), hx, hz, k, px, pz, C.HOT_S))
    end

    -- ── the perimeter: a ring round everything the proxy has and plans ──
    local DEF_CLASS = { grid_pop = "g", grid_arty = "g", grid_bulwark = "g", grid_hllt = "g", hllt = "g",
                        grid_flak = "a", grid_screamer = "a", grid_aa = "a", aa_light = "a" }
    local function PerimRing(S, frame)
        if frame - perimF < 1800 and #perimSlots > 0 then return perimSlots end
        perimF = frame
        local discs = { { S.x, S.z, 200 } }
        for _, it in ipairs(items) do
            local P = C.PLACE[it.kind]
            if not it.perim and not (P and P.grid) and it.kind ~= "cover_radar" then discs[#discs + 1] = { it.x, it.z, LAB_KINDS[it.kind] and 140 or 60 } end
        end
        for _, l in ipairs({ t3s, futT3 }) do for _, t in ipairs(l) do discs[#discs + 1] = { t.x, t.z, T3B.R } end end
        for _, l in ipairs({ blocks, futBlocks }) do for _, b in ipairs(l) do discs[#discs + 1] = { b.x, b.z, LB.R } end end
        local cx, cz = 0, 0
        for _, dsk in ipairs(discs) do cx, cz = cx + dsk[1], cz + dsk[2] end
        cx, cz = cx / #discs, cz / #discs
        local pts = {}
        for k = 0, 63 do
            local a = k * math.pi / 32
            local ux, uz = math.cos(a), math.sin(a)
            local h = 0
            for _, dsk in ipairs(discs) do h = math.max(h, (dsk[1] - cx) * ux + (dsk[2] - cz) * uz + dsk[3]) end
            pts[#pts + 1] = { x = cx + ux * (h + C.PERIM_PAD), z = cz + uz * (h + C.PERIM_PAD) }
        end
        local slots = { pts[1] }
        for i = 2, #pts do
            local l = slots[#slots]
            if (pts[i].x - l.x) ^ 2 + (pts[i].z - l.z) ^ 2 >= C.PERIM_STEP ^ 2 and (pts[i].x - slots[1].x) ^ 2 + (pts[i].z - slots[1].z) ^ 2 >= (0.6 * C.PERIM_STEP) ^ 2 then
                slots[#slots + 1] = pts[i]
            end
        end
        for _, sl in ipairs(slots) do                                    -- (skip marks carry over from the last ring)
            for _, o2 in ipairs(perimSlots) do if (o2.x - sl.x) ^ 2 + (o2.z - sl.z) ^ 2 < 100 ^ 2 then sl.skipUntil = o2.skipUntil end end
        end
        perimSlots = slots
        return slots
    end
    local function PerimWork(frame, S, uid)
        local n = SG.Next(C, Count, items, { repl = repl[1], hot = AnyHot(frame), air = AirHot(frame) })
        local cls = n and DEF_CLASS[n.kind]
        if not cls or n.at then return false end                         -- (radars, the Persecutor behind a hot spot: placed as the front groups place them)
        local d = Def(n.what)
        if not (d and CanBuild(uid, d.id)) then return false end
        local half = math.max(d.xsize or 2, d.zsize or 2) * 4
        local best, bg, bs
        for _, sl in ipairs(PerimRing(S, frame)) do
            local x, z = sl.x, sl.z
            if frame >= (sl.skipUntil or 0) and x > 96 and z > 96 and x < Game.mapSizeX - 96 and z < Game.mapSizeZ - 96 and not InExit(S, x, z) and not Reserved(x, z, half)
                    and not Hot(S, x, z, frame) then
                local g = 1e18
                for _, it in ipairs(items) do
                    if DEF_CLASS[it.kind] == cls then g = math.min(g, (it.x - x) ^ 2 + (it.z - z) ^ 2) end
                end
                g = math.sqrt(g)
                local sc = g - C.PERIM_NEAR_W * math.sqrt((x - S.x) ^ 2 + (z - S.z) ^ 2)
                if g >= 0.6 * C.PERIM_STEP and (not bs or sc > bs) then best, bg, bs = sl, g, sc end
            end
        end
        if not best then return false end                               -- (the ring is closed: the front)
        local x, y, z, facing = Spot(S, n.kind, d.id, { best.x, best.z }, C.PLACE.perim)
        if x then return OrderAt(frame, uid, { key = n.kind, what = n.what, kind = n.kind, defID = d.id, perim = true }, x, y, z, facing) end
        best.skipUntil = frame + 1800
        return false
    end

    -- ── the Basilisk blocks ──
    local function BlockOk(S)
        return function(x, z)
            if (x - S.x) ^ 2 + (z - S.z) ^ 2 < 600 * 600 then return false end
            for _, l in ipairs({ blocks, futBlocks }) do for _, b in ipairs(l) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (2 * LB.R - 120) ^ 2 then return false end end end
            for _, l in ipairs({ t3s, futT3 }) do
                for _, t in ipairs(l) do
                    if (t.x - x) ^ 2 + (t.z - z) ^ 2 < (LB.R + T3B.R) ^ 2 or InLane(t.x, t.z, t.facing, x, z, LB.R + C.EXIT_CLEAR, C.EXIT_LEN_T3) then return false end
                end
            end
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
        local x, z
        local fb = table.remove(futBlocks, 1)                            -- (the planned one, the perimeter is built round it)
        if fb and BlockOk(S)(fb.x, fb.z) then x, z = fb.x, fb.z else x, z = LB.Centre(S, #blocks + 1, BlockOk(S)) end
        perimF = -1e9
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
            if it.uid and not it.perim and (it.kind == "grid_pop" or it.kind == "grid_arty" or it.kind == "grid_bulwark" or it.kind == "grid_hllt") then
                f = math.max(f, (it.x - S.x) * ax + (it.z - S.z) * az)
            end
        end
        return f
    end

    -- ── the T3 lab ──
    -- the room a T3 block needs: away from the lab, the blocks and the other T3 blocks (planned ones too) and our items; with `lane`, its exit lane free
    -- of what stands there out to T3_LANE_CHECK (user 2026-11-09: "make sure there is an exit for the behmoths")
    local function T3Clear(S, lane)
        local facing = T3B.Facing(S)
        return function(x, z, r)
            if (x - S.x) ^ 2 + (z - S.z) ^ 2 < (r + 250) ^ 2 then return false end
            for _, l in ipairs({ blocks, futBlocks }) do for _, b in ipairs(l) do if (b.x - x) ^ 2 + (b.z - z) ^ 2 < (r + LB.R) ^ 2 then return false end end end
            for _, l in ipairs({ t3s, futT3 }) do for _, o2 in ipairs(l) do if (o2.x - x) ^ 2 + (o2.z - z) ^ 2 < (2 * r) ^ 2 then return false end end end
            for _, it in ipairs(items) do if (it.x - x) ^ 2 + (it.z - z) ^ 2 < r * r then return false end end
            if lane then
                if InLane(x, z, facing, S.x, S.z, C.EXIT_CLEAR + 100, C.T3_LANE_CHECK) then return false end
                for _, it in ipairs(items) do if InLane(x, z, facing, it.x, it.z, C.EXIT_CLEAR + 40, C.T3_LANE_CHECK) then return false end end
            end
            return true
        end
    end
    local function T3Find(S, near)
        local function W(f) return near and function(x, z, r) return near(x, z) and f(x, z, r) end or f end
        return T3B.Place(S, Def("lab_t3"), Def("nano"), W(T3Clear(S, true))) or T3B.Place(S, Def("lab_t3"), Def("nano"), W(T3Clear(S, false)))
    end
    -- the Basilisk ring round a T3 block's nanos (user 2026-11-08: "build the first Basilisk around the t3 block of nanos"): 344 out on each side but the
    -- lab's exit side (16-elmo grid: 8 mod 16 for a Basilisk)
    local function T3Ring(t)
        local ex = DIRS[t.facing] or { 1, 0 }
        t.bas = {}
        for _, sd in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if not (sd[1] == ex[1] and sd[2] == ex[2]) then
                for k = -312, 312, 96 do t.bas[#t.bas + 1] = { x = t.x + sd[1] * 344 + (-sd[2]) * k, z = t.z + sd[2] * 344 + sd[1] * k } end
            end
        end
    end
    local function T3Plan(frame, S)
        if #t3s >= C.T3_MAX or frame - t3TryF < 1800 then return end
        local last = t3s[#t3s]
        if last and Missing(last.nanos, "t3_nano", frame) > 0.15 * #last.nanos then return end      -- (the next one once the last one is mostly up)
        t3TryF = frame
        local t = table.remove(futT3, 1)                                   -- (the planned one, still clear: the perimeter is built round it)
        if t then
            local ld = Def("lab_t3")
            if not (T3Clear(S, false)(t.x, t.z, T3B.R) and ld and (Spring.TestBuildOrder(ld.id, t.x, Spring.GetGroundHeight(t.x, t.z) or 0, t.z, t.facing) or 0) > 0) then t = nil end
        end
        t = t or T3Find(S)
        if t then
            T3Ring(t)
            t3s[#t3s + 1] = t
            perimF = -1e9
            Spring.Echo(string.format("[PROXY] %s crew: T3 lab block %d at %d,%d (exit facing %d, %d nanos)", Clock(frame), #t3s, t.x, t.z, t.facing, #t.nanos))
        else
            Spring.Echo(string.format("[PROXY] %s crew: no room for T3 lab block %d yet", Clock(frame), #t3s + 1))
        end
    end
    -- the T3 blocks and Calamity blocks to come, planned ahead: kept free of other things, inside the perimeter (every 2 minutes, up to T3_MAX / PLAN_BLOCKS)
    local function Replan(frame, S)
        if frame - planF < 3600 then return end
        planF = frame
        local added = {}
        local function Near(x, z) return (x - S.x) ^ 2 + (z - S.z) ^ 2 <= C.PLAN_R ^ 2 end
        while #t3s + #futT3 < C.T3_MAX do
            local t = T3Find(S, Near)
            if not t then break end
            futT3[#futT3 + 1] = t
            added[#added + 1] = string.format("T3 block at %d,%d", t.x, t.z)
        end
        while #blocks + #futBlocks < math.min(C.PLAN_BLOCKS, C.MAX_BLOCKS) do
            local ok = BlockOk(S)
            local x, z = LB.Centre(S, #blocks + #futBlocks + 1, function(x2, z2) return Near(x2, z2) and ok(x2, z2) end)
            if not x then break end
            futBlocks[#futBlocks + 1] = { x = x, z = z }
            added[#added + 1] = string.format("Calamity block at %d,%d", x, z)
        end
        if #added > 0 then
            perimF = -1e9
            Spring.Echo(string.format("[PROXY] %s crew: planned ahead (kept free, inside the perimeter): %s", Clock(frame), table.concat(added, "; ")))
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
            elseif perimOn and #GroupMembers("gp", true) < C.PERIM_T2 then c.role = "gp"
            else c.role = GroupShort(true) or (groupsWanted >= 1 and ("g" .. (uid % groupsWanted + 1))) or "core" end
        else
            if not up or (n.core or 0) < C.CORE_T1 then c.role = "core"
            elseif BlockMissing(frame) > 0 and (n.block or 0) < C.BLOCK_CREW then c.role = "block"
            elseif T3NanosMissing(frame) > 0 and (n.t3 or 0) < C.T3_CREW then c.role = "t3"
            elseif perimOn and #GroupMembers("gp", false) < C.PERIM_T1 then c.role = "gp"
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
                              + C.GROUP_T1 * groupsWanted + (perimOn and C.PERIM_T1 or 0)) or C.CORE_CONS
        local t2Want = C.GROUP_T2 * groupsWanted + ((Standing("lab_t3") < C.T3_MAX) and 1 or 0) + ((#blocks > 0 or #t3s > 0) and 1 or 0)
                       + (perimOn and C.PERIM_T2 or 0)
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
                    local nf = 0
                    for uid in pairs(flak) do if Alive(uid) then nf = nf + 1 else flak[uid] = nil end end
                    if AirHot(frame) and nf < C.FLAK_TRUCKS then out[labID] = ROLES.Get("aa_flak_truck")
                    elseif n.t2 < t2Want then out[labID] = ROLES.Get("con_t2_veh") else out[labID] = ROLES.Get("heavy_t2_veh") end
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
        lastS = S
        if not labBPTried then PlanLabBP(S) end                          -- (first: before the core's radar / nanos take its ground)
        ClearYard(frame)
        -- dead cons / items out; stale orders dropped
        for uid in pairs(cons) do if not Alive(uid) then cons[uid] = nil end end
        for i = #items, 1, -1 do
            local it = items[i]
            local gone = (it.uid and not Alive(it.uid)) or (it.frameID and not it.uid and not Alive(it.frameID))
            local stale = not it.frameID and not it.uid and (frame - it.orderF > C.ORDER_TIMEOUT or not (it.con and Alive(it.con)))
            if gone or stale then
                if stale then bad[Cell(it.x, it.z)] = true end
                if (gone and not it.uid) or (stale and not (it.con and Alive(it.con))) then Fail(it, frame) end   -- (its frame killed / its con killed)
                -- a lab frame killed twice on one spot: the spot is given up, the row's next one is used (game 14, close spawns, 2026-11-09: the T2 lab's
                -- frame was killed 6 times on the side toward the enemy and never stood)
                if gone and not it.uid and LAB_KINDS[it.kind] and it.kind ~= "lab_t3" then
                    local key = Cell(it.x, it.z)
                    labLost[key] = (labLost[key] or 0) + 1
                    if labLost[key] >= 2 then
                        bad[key] = true
                        Spring.Echo(string.format("[PROXY] %s crew: %s frame killed twice at %d,%d: that spot is given up", Clock(frame), it.what, it.x, it.z))
                    end
                end
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
            if #t3s > 0 then Replan(frame, S) end
        end
        if not perimOn and groupsWanted >= 1 and ((#GroupMembers("g1", true) >= C.GROUP_T2 and #GroupMembers("g1", false) >= C.GROUP_T1)
                or frame - groupAddF >= C.PERIM_AFTER_S * 30 or groupsWanted >= 2) then
            perimOn = true
            Spring.Echo(string.format("[PROXY] %s crew: perimeter group on (%d T2 + %d T1 cons)", Clock(frame), C.PERIM_T2, C.PERIM_T1))
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
            local took = false
            for g = 1, groupsWanted do
                local t2s = GroupMembers("g" .. g, true)
                if #t2s > 1 then cons[t2s[#t2s]].role, cons[t2s[#t2s]].item = "t3lab", nil; took = true; break end
            end
            -- (no group with a spare T2 con -- the T2 lab blocked, game 12, 2026-11-08: the second T3 block's nanos stood with no lab -- any T2 con with no
            -- item takes it: the gun con, a group's leader)
            if not took then
                for uid, c in pairs(cons) do
                    if c.t2 and not c.item and (c.role == "gun" or (c.role and c.role:sub(1, 1) == "g")) then c.role = "t3lab"; break end
                end
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
                    if uid == leader then done = (role == "gp" and PerimWork(frame, S, uid)) or GroupWork(frame, S, uid)
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
            local fd = Def("aa_flak_truck")
            if fd and defID == fd.id then flak[uid] = true end
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

    function CR.OnDestroyed(uid, frame, attackerDefID)
        local c = cons[uid]
        local ad = attackerDefID and UnitDefs[attackerDefID]
        if ad and ad.canFly then
            local ours = c ~= nil
            if not ours then for _, it in ipairs(items) do if it.uid == uid or it.frameID == uid then ours = true; break end end end
            if ours then
                frame = frame or Spring.GetGameFrame()
                local was = AirHot(frame)
                airLoss[#airLoss + 1] = frame
                if not was and AirHot(frame) then
                    Spring.Echo(string.format("[PROXY] %s crew: losing cons / buildings to air (%d in %ds): one AA per %d ground defences", Clock(frame), #airLoss, C.AIR_WINDOW_S, C.AA_EVERY_AIR))
                end
            end
        end
        if c and c.role and c.role:sub(1, 1) == "g" then
            local it = c.item
            if not it then local lead = GroupMembers(c.role, true)[1]; it = lead and cons[lead] and cons[lead].item end
            if it then Fail(it, frame or Spring.GetGameFrame()) end
        end
        cons[uid] = nil
        if labs[uid] then labs[uid], made[uid] = nil, nil end
    end

    -- the proxy is lost: the cons go back to the broker (free)
    function CR.AirHot(frame) return AirHot(frame or Spring.GetGameFrame()) end

    function CR.Release()
        local T = o.trans and o.trans()
        for uid in pairs(cons) do if T and T.CB and o.CB then o.CB.Release(T.CB, uid, false) end end
        cons, items, labs, made, startF, rez, highAt = {}, {}, {}, {}, nil, {}, {}
        blocks, t3s, t3TryF, groupsWanted, groupAddF = {}, {}, -1e9, 0, -1e9
        futT3, futBlocks, planF, fails, hots, repl, perimOn, perimSlots, perimF = {}, {}, -1e9, {}, {}, {}, false, {}, -1e9
        slots, slotKey, airLoss, labBP, labBPTried = nil, nil, {}, nil, false
    end

    function CR.Summary()
        local n = RoleCount()
        local roles = {}
        for _, r in ipairs({ "core", "g1", "g2", "g3", "g4", "gp", "block", "gun", "t3lab", "t3" }) do if (n[r] or 0) > 0 then roles[#roles + 1] = r .. " " .. n[r] end end
        local parts = {}
        for _, w in ipairs({ "jammer_t1", "radar", "nano", "hllt", "aa_light", "lab_t2_veh", "lab_t1_bot", "lab_t1_air", "jammer_t2", "radar_t2", "cover_radar", "grid_pop",
                             "grid_arty", "grid_bulwark", "grid_flak", "grid_screamer", "block_nano", "lrpc", "calamity", "lab_t3", "t3_nano", "grid_hllt", "grid_aa" }) do
            local c = Count(w)
            if c > 0 then parts[#parts + 1] = string.format("%s %d/%d", w, Standing(w), c) end
        end
        local lost = {}
        for w, k in pairs(stats.lost) do lost[#lost + 1] = w .. " " .. k end
        local np = 0
        for _, it in ipairs(items) do if it.perim and it.uid then np = np + 1 end end
        local rowsFull = 0
        if slots and lastS then
            local byRow = {}
            for _, sl in ipairs(slots) do
                local r = byRow[sl.row] or { n = 0, full = 0 }
                byRow[sl.row] = r
                r.n = r.n + 1
                local off = sl.x < 64 or sl.z < 64 or sl.x > Game.mapSizeX - 64 or sl.z > Game.mapSizeZ - 64
                if off or Taken(sl.x, sl.z, 40) or InExit(lastS, sl.x, sl.z) or Reserved(sl.x, sl.z, 0) or InBP(sl.x, sl.z, 0)
                   or (sl.skipUntil or 0) > Spring.GetGameFrame() or Hot(lastS, sl.x, sl.z, Spring.GetGameFrame()) then r.full = r.full + 1 end
            end
            for i = 1, #byRow do if byRow[i] and byRow[i].full >= byRow[i].n then rowsFull = i else break end end
        end
        return string.format("%d T1 + %d T2 cons (%s), %d group(s), %d block(s), %d T3 block(s) (+%d T3 / %d Calamity planned); perimeter %d standing on %d slots; "
            .. "hot spots %d, front attempts lost %d, air hot %s; %d slot rows full; standing/planned %s; lost %s", n.t1, n.t2, table.concat(roles, ", "),
            groupsWanted, #blocks, #t3s, #futT3, #futBlocks, np, #perimSlots, #hots, #fails, tostring(AirHot(Spring.GetGameFrame())), rowsFull, table.concat(parts, ", "), #lost > 0 and table.concat(lost, ", ") or "none")
    end

    return CR
end

return M
