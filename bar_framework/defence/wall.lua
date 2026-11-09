-- bar_framework/defence/wall.lua  (area_defence: the Pounder + Tzar wall, "stopping power" that holds an area's front)
-- User 2026-11-08: "Main thing I am looking at making the pounder wall more effective."  What the old home records (support/t1stop.lua) did
-- wrong in the 2026-11-02 games: 36 Pounders, 0 lost, 23 kills -- they stood 1300 from the eco's centre, BEHIND the eco they were to protect, FIGHTed
-- inside a 700 leash and never met a raid.  Here:
--   * WHERE: the walls stand on the area's FRONT (defence/areas.lua: the arc the enemy comes from, learnt from the threats it saw, the enemy axis
--     before that), at the area's EDGE member in their direction plus OUT -- in front of the eco, a line across the approach.  MOVE orders only.
--   * SMALL WALLS (user 2026-11-08, after the first games: "They were moving around as one big group.  3 pounders is enough to slow down a push by a
--     lot ... split the pounders up into groups of 3 or so to get better coverage"): every wall is N (3) Pounders, the walls spread evenly over the
--     front; a threat takes at most area_defence's WALLS_PER_THREAT of them, the others keep their posts.
--   * HOW MANY (user: "I am a bit worried about how many pounders would get made"): the Pounders come from the stance (12 Incisors : 1, 10 Brutes : 1).
--     The want is a FLOOR that covers the whole front (one wall per FRONT_W of the front's edge) plus PRESS_WALLS more walls per raid-pressure level
--     (PRESS_1..3, t1stop's measure on this area's threats); new Pounders fill the walls one at a time, the busiest direction first.  The want falls
--     again as the pressure decays.  Pounders over the want, idle for IDLE_S, are RECLAIMED (user: "for testing just have them get reclaimed if there are too
--     many"): they walk to the nearest nano and the macro side's nanos reclaim them (WG.DefenceReclaim, home_defence.lua).  A surplus Tzar goes
--     back to the raid groups' stop pool (the giveBack callback).
--   * BLOCK: a wall takes a threat whose path it can reach before the threat reaches its member (MeetingPoint, or the post in front of the member;
--     ETA <= the threat's + SLACK_S, within LEASH of the wall's post, inside the area's R_MAX) and MOVEs as a line across it; in contact each
--     Pounder runs at one enemy (ChasePoint) but never more than CHASE_R past the block point (riot tanks win close and cannot catch raiders).
--   * TZARS (off: TZARS = 0, user 2026-11-08 "don't use tzars for the wall for right now") stand BEHIND the line and keep the density SET_TARGET (support/arty.lua AimDensity); one farther than LIFT_DIST from its wall is flown
--     there (air_lift: a heavy transport).
--
--   local WL = VFS.Include("LuaUI/Widgets/bar_framework/defence/wall.lua").New{ cfg, ARMY, UQ, MM, LIFT, HOST, WG, teamID, army = <defence/army.lua instance>,
--                                                                              hist = TH.Hist, giveBack = fn(uid, defID) }
--   wall.Offer(uid, defID, home) -> bool (home: an area id the unit belongs to -- the proxy's own Pounders / Tzars)   wall.Sync(frame, area, pressureGroups, tzarsOn)   wall.Walls(areaId)   wall.Candidates(t)
--   wall.Assign(w, t)   wall.Orders(frame, threatsById)   wall.OnDestroyed(uid)   wall.Owns(uid)   wall.Summary()

local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local DA = VFS.Include("LuaUI/Widgets/bar_framework/defence/army.lua")

local M = {}

M.CFG = {
    N          = 3,       -- Pounders in a wall (user: "3 pounders is enough to slow down a push by a lot")
    FRONT_W    = 700,     -- one floor wall per this much of the front's edge (elmos of arc)
    FLOOR_MAX  = 8,
    PRESS_WALLS = 2,      -- more walls per raid-pressure level (0..3)
    GROUPS_MAX = 12,      -- walls in an area at most
    TZARS      = 0,       -- Tzars per pressure wall (once tzarsOn); 0 = the wall takes no Tzars
    OUT        = 450,     -- the post: this far out from the area's edge member in the wall's direction
    SPACING    = 110,     -- between Pounders on the line
    BEHIND     = 150,     -- the Tzars stand this far behind the line
    SLACK_S    = 6,       -- a wall takes a threat it reaches no more than this much later than the threat reaches its member
    LEASH      = 1200,    -- ...whose block point is within this of the wall's post
    CHASE_R    = 400,     -- in contact, a Pounder runs at its enemy but no more than this past the block point
    ENGAGE_R   = 650,
    IDLE_S     = 120,     -- a wall over its want with no threat for this long: its extra Pounders are surplus
    SURPLUS_PER_MIN = 4,  -- at most this many Pounders sent to be reclaimed a minute
    RESERVE    = 3,       -- Pounders kept over the walls' total want before any is reclaimed (the front grows with the base: eco_sim 2026-11-08 reclaimed
                          -- 6 at 9:00-11:00 and had 3 empty walls at 19:00)
    RECLAIM_OFF = 70,     -- a surplus Pounder stands this far from the nano that reclaims it
    LIFT_DIST  = 1800,
    LIFT_PRIO  = 10,
    LOG_EVERY  = 900,
}

local CMD_MOVE = 10
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    local ARMY, UQ, MM, LIFT, HOST, WG = o.ARMY, o.UQ, o.MM, o.LIFT, o.HOST, o.WG
    local army = o.army
    local ART = VFS.Include("LuaUI/Widgets/bar_framework/support/arty.lua")    -- its own instance: the Tzars' density targets
    local W = {}
    local pounder, tzar = ROLES.Get("pounder"), ROLES.Get("heavy_t2_veh")
    local walls = {}          -- [areaId] = { wall, ... } sorted by angle; wall = { id, angle, x, z, want, wantT, units = {}, tzars = {}, threat, idleF }
    local owner = {}          -- [uid] = { kind = "p" | "t", w = wall | nil, defID }
    local reclaim = {}        -- [uid] = { x, z, nano, frame }  surplus Pounders walking to a nano
    local sentF = {}          -- frames surplus was sent (SURPLUS_PER_MIN)
    local nextId, logF = 1, -1e9
    local stats = { reclaimed = 0, sent = 0, kills = 0 }

    local function Value(defID)
        local d = UnitDefs[defID]
        return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
    end
    local function Speed(defID) return (UQ.max_speed and UQ.max_speed(defID)) or ((UnitDefs[defID] or {}).speed or 0) end
    local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end

    function W.Owns(uid) return owner[uid] ~= nil end
    function W.Reclaiming(uid) return reclaim[uid] ~= nil end

    -- the nearest of our nanos (static builders that are not labs) to a unit, refreshed every 150 frames
    local nanos, nanoF = {}, -1e9
    function W.NearestNano(uid)
        local f = Spring.GetGameFrame()
        if f - nanoF >= 150 then
            nanoF, nanos = f, {}
            for _, id in ipairs(Spring.GetTeamUnits(o.teamID) or {}) do
                local d = UnitDefs[Spring.GetUnitDefID(id) or -1]
                if d and not d.isFactory and (d.speed or 0) == 0 and (d.buildSpeed or 0) > 0 and (d.buildDistance or 0) > 0 and not Spring.GetUnitIsBeingBuilt(id) then
                    local x, _, z = Spring.GetUnitPosition(id)
                    if x then nanos[#nanos + 1] = { uid = id, x = x, z = z } end
                end
            end
        end
        local x, _, z = Spring.GetUnitPosition(uid)
        if not x then return nil end
        local best, bd
        for _, nn in ipairs(nanos) do
            if Spring.GetUnitDefID(nn.uid) then
                local d = Dist(x, z, nn.x, nn.z)
                if not bd or d < bd then best, bd = nn, d end
            end
        end
        return best
    end

    -- (the walls of a "keep" area -- the proxy -- take only their own lab's Tzars (Offer's home): they neither ask the labs for Tzars nor take the main
    -- base's.  Game 1, 2026-11-08: the proxy walls' want of 2 each made the main T2 labs build "wall Tzars"; with no home they joined the nearest
    -- area's walls -- the main base's, which want none -- and 14 + 8 of them stood idle behind two walls from 13:00 to the end)
    local function Counted(w) return not (w.area and w.area.wall and w.area.wall.keep) end
    local function TzarWant(list) local n = 0; for _, w in ipairs(list or {}) do if Counted(w) then n = n + (w.wantT or 0) end end; return n end
    local function TzarHave() local n = 0; for _, ow in pairs(owner) do if ow.kind == "t" and not ow.home then n = n + 1 end end; return n end
    local allWalls = function() local out = {}; for _, l in pairs(walls) do for _, w in ipairs(l) do out[#out + 1] = w end end; return out end

    -- a finished Pounder: always the wall's (the stance makes them for it); a Tzar: while the walls want more
    function W.Offer(uid, defID, home)
        local d = UnitDefs[defID]
        if not d then return false end
        if d.name == pounder then
            owner[uid] = { kind = "p", defID = defID, home = home }
            return true
        end
        if d.name == tzar and (home or TzarHave() < TzarWant(allWalls())) then     -- (the proxy's own Tzars always: its T2 lab makes them for its walls)
            owner[uid] = { kind = "t", defID = defID, home = home }
            return true
        end
        return false
    end

    function W.OnDestroyed(uid)
        local ow = owner[uid]
        if reclaim[uid] then stats.reclaimed = stats.reclaimed + 1 end
        owner[uid], reclaim[uid] = nil, nil
        if WG and WG.DefenceReclaim then WG.DefenceReclaim[uid] = nil end
        if ow and ow.w then
            local l = ow.kind == "t" and ow.w.tzars or ow.w.units
            for i = #l, 1, -1 do if l[i] == uid then table.remove(l, i) end end
        end
        if army and army.Forget then army.Forget(uid) end
    end

    local function Detach(uid)
        local ow = owner[uid]
        if not (ow and ow.w) then return end
        local l = ow.kind == "t" and ow.w.tzars or ow.w.units
        for i = #l, 1, -1 do if l[i] == uid then table.remove(l, i) end end
        ow.w = nil
    end
    local function Attach(uid, w)
        Detach(uid)
        local ow = owner[uid]
        ow.w = w
        local l = ow.kind == "t" and w.tzars or w.units
        l[#l + 1] = uid
    end

    -- the wall's slots on the area's front: n walls evenly over the front arc (one: the busiest bin of the arc), each at the edge member + OUT
    local function Slots(area, n)
        local fr = area.Front()
        local out = {}
        local span = fr.amax - fr.amin
        for i = 1, n do
            local ang
            if n == 1 then
                local best, bw = fr.axis, -1
                local bins = #fr.w
                for b = 1, bins do
                    local a = area.BinAngle(b)
                    local rel = math.atan2(math.sin(a - fr.axis), math.cos(a - fr.axis))
                    if rel >= fr.amin - fr.axis and rel <= fr.amax - fr.axis and fr.w[b] > bw then best, bw = a, fr.w[b] end
                end
                ang = best
            else
                ang = fr.amin + (i - 0.5) / n * span
            end
            local ex, ez = area.EdgeAt(ang)
            local x, z = ex + math.cos(ang) * C.OUT, ez + math.sin(ang) * C.OUT
            if MM and MM.Clamp then x, z = MM.Clamp(x, z, 200) end
            out[i] = { angle = ang, x = x, z = z }
        end
        return out, fr
    end

    local function FloorCount(area, fr)
        local _, _, r = area.EdgeAt(fr.axis)
        local len = (fr.amax - fr.amin) * math.max(r or 0, area.Radius(), 500)
        return math.max(1, math.min(C.FLOOR_MAX, math.ceil(len / C.FRONT_W)))
    end

    -- once a second: the area's walls (count, posts, wants), new units into the walls most short, rebalance, surplus to reclaim
    -- an area that is gone (the proxy base lost): its units are free for the other areas' walls
    function W.DropArea(id)
        for _, w in ipairs(walls[id] or {}) do
            for _, uid in ipairs(w.units) do if owner[uid] then owner[uid].w = nil end end
            for _, uid in ipairs(w.tzars) do if owner[uid] then owner[uid].w = nil end end
        end
        for uid, ow in pairs(owner) do
            if ow.home == id then
                ow.home = nil
                if ow.kind == "t" then                                  -- the area's own Tzars go to the raid groups (not to idle behind a main wall)
                    owner[uid] = nil
                    if ARMY.RoleOf(uid) == "DEF_WALL" then ARMY.Release(uid) end
                    if o.giveBack then o.giveBack(uid, ow.defID) end
                end
            end
        end
        walls[id] = nil
    end

    -- nearestArea(x, z) -> area id (optional): a unit with no wall joins only the walls of the area nearest to it
    function W.Sync(frame, area, pressureGroups, tzarsOn, nearestArea)
        if not (area and area.N() > 0) then return end
        local list = walls[area.id] or {}
        walls[area.id] = list
        local _, fr = Slots(area, 1)
        -- the floor never shrinks (game 4, 2026-11-08: the front narrowed onto one busy direction, the floor fell 2 -> 1 and 11 Pounders stood in one wall
        -- while 30-Incisor raids came round the flanks)
        list.floorMax = math.max(list.floorMax or 0, FloorCount(area, fr))
        local floor = list.floorMax
        local wantWalls = math.min(C.GROUPS_MAX, floor + (pressureGroups or 0) * C.PRESS_WALLS)
        -- ... and there are always enough walls for every Pounder to stand in a group of N (no wall holds more: "split the pounders up into groups of 3")
        -- (this area's Pounders only: those on its walls, and the free ones that would join it.  Game 2, 2026-11-08: the count of all of them, 32, gave the
        -- proxy 12 walls, and its own Pounders stood one or none to a wall)
        local function Mine(uid, ow)
            if ow.w then return ow.w.area == area end
            if ow.home then return ow.home == area.id end
            if not nearestArea then return true end
            local x, _, z = Spring.GetUnitPosition(uid)
            return x == nil or nearestArea(x, z) == area.id
        end
        local haveP = 0
        for uid, ow in pairs(owner) do if ow.kind == "p" and not reclaim[uid] and Alive(uid) and Mine(uid, ow) then haveP = haveP + 1 end end
        local n = math.min(C.GROUPS_MAX, math.max(wantWalls, math.ceil(haveP / C.N)))
        local slots = Slots(area, n)
        -- keep wall identity: the walls stay sorted by angle, extra walls are added / the last ones removed (their units go to the others)
        while #list < n do list[#list + 1] = { id = nextId, units = {}, tzars = {}, idleF = frame, area = area }; nextId = nextId + 1 end
        while #list > n do
            local w = table.remove(list)
            for _, uid in ipairs(w.units) do owner[uid].w = nil end
            for _, uid in ipairs(w.tzars) do owner[uid].w = nil end
            Spring.Echo(string.format("[DEF] %s wall %d (%s) folded: %d Pounders, %d Tzars to the other walls", Clock(frame), w.id, area.id, #w.units, #w.tzars))
        end
        for i, w in ipairs(list) do w.angle, w.x, w.z = slots[i].angle, slots[i].x, slots[i].z end
        -- wants: every wall N Pounders (Tzars only with TZARS > 0: the busiest walls under pressure)
        local order = {}
        for _, w in ipairs(list) do w.want, w.wantT = C.N, 0; order[#order + 1] = w end
        table.sort(order, function(a, b)
            local ta, tb = area.Traffic(a.angle), area.Traffic(b.angle)
            if ta ~= tb then return ta > tb end
            return a.id < b.id end)
        if C.TZARS > 0 and tzarsOn then
            for i = 1, math.min((pressureGroups or 0) * C.PRESS_WALLS, #order) do order[i].wantT = C.TZARS end
        end
        local keep = area.wall and area.wall.keep                    -- (the proxy: every wall takes its Tzars, nothing is reclaimed or handed back)
        if area.wall and (area.wall.tzars or 0) > 0 then for _, w in ipairs(order) do w.wantT = math.max(w.wantT, area.wall.tzars) end end
        -- the first wall (busiest direction first) still short of its want; nil when every wall is full
        local function FirstShort(kind)
            for _, w in ipairs(order) do
                local have, want = kind == "t" and #w.tzars or #w.units, kind == "t" and w.wantT or w.want
                if have < want then return w end
            end
        end
        -- units with no wall (new, or from a folded wall): fill the walls one at a time, the busiest first; every wall full -> the
        -- nearest (the unit is surplus there and is reclaimed once that wall has been idle IDLE_S)
        for uid, ow in pairs(owner) do
            if not Alive(uid) then W.OnDestroyed(uid)
            elseif not ow.w and not reclaim[uid] and ((ow.home and ow.home == area.id) or (not ow.home and (not nearestArea or (function()
                    local x, _, z = Spring.GetUnitPosition(uid)
                    return x == nil or nearestArea(x, z) == area.id end)()))) then
                local best = FirstShort(ow.kind)
                if not best then
                    local x, _, z = Spring.GetUnitPosition(uid)
                    local bd
                    for _, w in ipairs(list) do
                        local d = x and Dist(x, z, w.x, w.z) or 0
                        if not bd or d < bd then best, bd = w, d end
                    end
                end
                if best then Attach(uid, best) end
            end
        end
        -- rebalance: an idle wall over its want gives the unit nearest a wall under its want to it (one a tick)
        for _, kind in ipairs({ "p", "t" }) do
            local short, over
            local fs = FirstShort(kind)
            if fs then short = { w = fs } end
            for _, w in ipairs(list) do
                local have, want = kind == "t" and #w.tzars or #w.units, kind == "t" and w.wantT or w.want
                if have > want and not w.threat and (not over or have - want > over.d) then over = { w = w, d = have - want } end
            end
            -- the raids moved: a quiet idle wall gives a Pounder to a short wall that sees more than twice its traffic (the flanks fill once they are hit)
            if short and not over and kind == "p" then
                local ts = area.Traffic(short.w.angle)
                for _, w in ipairs(list) do
                    if w ~= short.w and #w.units > 0 and not w.threat and area.Traffic(w.angle) * 2 < ts
                       and (not over or area.Traffic(w.angle) < area.Traffic(over.w.angle)) then over = { w = w, d = 1 } end
                end
            end
            if short and over then
                local l = kind == "t" and over.w.tzars or over.w.units
                local far, fd                                  -- (the nearest to the short wall)
                for _, uid in ipairs(l) do
                    local x, _, z = Spring.GetUnitPosition(uid)
                    local d = x and Dist(x, z, short.w.x, short.w.z) or 0
                    if not fd or d < fd then far, fd = uid, d end
                end
                if far then Attach(far, short.w) end
            end
        end
        -- surplus: what is still over the want on a wall idle for IDLE_S (Pounders: reclaimed; Tzars: back to the raid groups)
        local recent = {}
        for _, f in ipairs(sentF) do if frame - f < 1800 then recent[#recent + 1] = f end end
        sentF = recent
        -- surplus: Pounders over the WANTED walls' N each (walls past wantWalls exist only so no wall holds more than N), RESERVE kept; taken from the
        -- least busy wall idle for IDLE_S, the one farthest from its post.  Tzars over a wall's want go back at once once it is idle.
        local spare = keep and 0 or (haveP - wantWalls * C.N)
        local byQuiet = {}
        for _, w in ipairs(list) do
            if w.threat then w.idleF = frame end
            local idle = not keep and frame - (w.idleF or frame) >= C.IDLE_S * 30
            if idle then
                while #w.tzars > w.wantT do
                    local uid = table.remove(w.tzars)
                    local ow = owner[uid]
                    owner[uid] = nil
                    if ARMY.RoleOf(uid) == "DEF_WALL" then ARMY.Release(uid) end
                    Spring.Echo(string.format("[DEF] %s wall %d: surplus Tzar %d handed back", Clock(frame), w.id, uid))
                    if o.giveBack then o.giveBack(uid, ow.defID) end
                end
                if #w.units > 0 then byQuiet[#byQuiet + 1] = w end
            end
        end
        table.sort(byQuiet, function(a, b)
            local ta, tb = area.Traffic(a.angle), area.Traffic(b.angle)
            if ta ~= tb then return ta < tb end
            return a.id > b.id end)
        local qi = 1
        while spare > C.RESERVE and #sentF < C.SURPLUS_PER_MIN and byQuiet[qi] do
            local w = byQuiet[qi]
            if #w.units == 0 then qi = qi + 1
            else
                local bi, bd
                for i, uid in ipairs(w.units) do
                    local x, _, z = Spring.GetUnitPosition(uid)
                    local d = x and Dist(x, z, w.x, w.z) or 0
                    if not bd or d > bd then bi, bd = i, d end
                end
                local uid = w.units[bi]
                local nano = W.NearestNano and W.NearestNano(uid)
                if not nano then break end                      -- nothing to reclaim it: it stays
                table.remove(w.units, bi)
                owner[uid].w = nil
                reclaim[uid] = { nano = nano.uid, x = nano.x, z = nano.z, frame = frame }
                sentF[#sentF + 1] = frame
                spare = spare - 1
                stats.sent = stats.sent + 1
                Spring.Echo(string.format("[DEF] %s %d Pounders over the %d wanted walls (+%d kept): Pounder %d of quiet wall %d (idle %ds) to nano %d for reclaim",
                    Clock(frame), spare + 1 + C.RESERVE, wantWalls, C.RESERVE, uid, w.id, math.floor((frame - w.idleF) / 30), nano.uid))
            end
        end
        if frame - (list.logF or -1e9) >= C.LOG_EVERY then           -- (per area: one shared timer never logged the proxy's walls)
            list.logF = frame
            local parts = {}
            for _, w in ipairs(list) do
                parts[#parts + 1] = string.format("#%d %d/%d P %d/%d T at %d,%d (%s)", w.id, #w.units, w.want, #w.tzars, w.wantT, w.x, w.z,
                    w.threat and ("on threat " .. w.threat) or "post")
            end
            local nr = 0
            for _ in pairs(reclaim) do nr = nr + 1 end
            Spring.Echo(string.format("[DEF] %s walls %s: floor %d, pressure %d, wanted %d, %d Pounders%s | %s | reclaiming %d (sent %d, done %d)", Clock(frame), area.id, floor,
                pressureGroups or 0, wantWalls, haveP, tzarsOn and ", Tzars on" or "", table.concat(parts, "; "), nr, stats.sent, stats.reclaimed))
        end
    end

    function W.Walls(areaId) return walls[areaId] or {} end

    local function WallState(w)
        local sx, sz, n, v, sp = 0, 0, 0, 0, math.huge
        for _, l in ipairs({ w.units, w.tzars }) do
            for _, uid in ipairs(l) do
                local x, _, z = Spring.GetUnitPosition(uid)
                if x and not (LIFT and LIFT.Busy(uid)) then
                    local defID = owner[uid].defID
                    sx, sz, n = sx + x, sz + z, n + 1
                    v = v + Value(defID)
                    sp = math.min(sp, math.max(1, Speed(defID)))
                end
            end
        end
        if n == 0 then return nil end
        return sx / n, sz / n, v, (sp < math.huge) and sp or 40
    end
    W.Value = function(w) local _, _, v = WallState(w); return v or 0 end

    -- can this wall get in front of the threat in time?  -> block point, eta (s), value
    function W.Reach(w, t)
        local cx, cz, v, sp = WallState(w)
        if not cx then return nil end
        local bx, bz, eta
        if t.mode == "cut" or (t.speed or 0) >= 14 then
            local mx, mz, s = DA.MeetingPoint(army.cfg, t, cx, cz, sp)
            if mx then bx, bz, eta = mx, mz, s end
        end
        if not bx then bx, bz = t.px, t.pz; eta = Dist(cx, cz, bx, bz) / sp end
        if eta > t.tThreat + C.SLACK_S then return nil end
        if Dist(bx, bz, w.x, w.z) > C.LEASH then return nil end
        local area = w.area
        if area and area.cfg and area.Anchor then
            local hx, hz = area.Anchor()
            if hx and Dist(bx, bz, hx, hz) > area.cfg.R_MAX then return nil end
        end
        return bx, bz, eta, v
    end

    function W.Assign(w, t, bx, bz) w.threat, w.bx, w.bz = t and t.id or nil, bx, bz end

    function W.Defenders(w)
        local out = {}
        for _, l in ipairs({ w.units, w.tzars }) do
            for _, uid in ipairs(l) do
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then out[#out + 1] = { uid = uid, x = x, z = z, v = Value(owner[uid].defID) } end
            end
        end
        return out
    end

    local function Claim(frame, uid, cmd, x, z, prio)
        if HOST and HOST:IsHeld(uid, frame) then return end
        if prio == ARMY.PRIO.RESPOND then army.Claim(frame, uid, cmd, x, z, "DEF_WALL")
        else ARMY.Claim(prio, uid, { role = "DEF_WALL", cmd = cmd, x = x, z = z }, frame) end
    end

    local function Tzars(frame, w, bx, bz, ux, uz, prio)
        local n = #w.tzars
        local px, pz = -uz, ux
        local focus
        for i, uid in ipairs(w.tzars) do
            local off = (i - (n + 1) / 2) * C.SPACING * 1.5
            local x, z = bx - ux * C.BEHIND + px * off, bz - uz * C.BEHIND + pz * off
            if MM and MM.Clamp then x, z = MM.Clamp(x, z, 150) end
            local ux0, _, uz0 = Spring.GetUnitPosition(uid)
            local far = ux0 and Dist(ux0, uz0, x, z) > C.LIFT_DIST
            if LIFT and (LIFT.Busy(uid) or far) then
                LIFT.Request(uid, x, z, C.LIFT_PRIO, "wall " .. w.id)
                if not LIFT.Busy(uid) then Claim(frame, uid, CMD_MOVE, x, z, prio) end
            else
                if LIFT and LIFT.Waiting(uid) then LIFT.Cancel(uid) end
                Claim(frame, uid, CMD_MOVE, x, z, prio)
                focus = ART.AimDensity(uid, ART.Range(owner[uid].defID, { UQ = UQ }), {}, focus)
            end
        end
    end

    -- a line of Pounders across (ux, uz) through (bx, bz), neighbours kept
    local function Line(frame, w, bx, bz, ux, uz, prio)
        local qx, qz = -uz, ux
        local list = {}
        for _, uid in ipairs(w.units) do
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then list[#list + 1] = { uid = uid, s = x * qx + z * qz } end
        end
        table.sort(list, function(a, b) return a.s < b.s end)
        local n = #list
        for i, e in ipairs(list) do
            local off = (i - (n + 1) / 2) * C.SPACING
            local x, z = bx + qx * off, bz + qz * off
            if MM and MM.Clamp then x, z = MM.Clamp(x, z, 100) end
            Claim(frame, e.uid, CMD_MOVE, x, z, prio)
        end
    end

    local chaseOf = {}
    function W.Orders(frame, byId)
        for _, w in ipairs(allWalls()) do
            local t = w.threat and byId[w.threat] or nil
            if not t then w.threat = nil end
            if not t then
                -- the post: a line across the wall's direction, Tzars behind it
                local ux, uz = math.cos(w.angle or 0), math.sin(w.angle or 0)
                Line(frame, w, w.x, w.z, ux, uz, ARMY.PRIO.HOME_GUARD)
                Tzars(frame, w, w.x, w.z, ux, uz, ARMY.PRIO.HOME_GUARD)
            else
                local bx, bz = w.bx or t.px, w.bz or t.pz
                local cx, cz = WallState(w)
                local contact = cx and Dist(cx, cz, t.x, t.z) <= C.ENGAGE_R
                if t.mode == "fight" and contact then
                    -- each Pounder runs at one enemy of the threat, never more than CHASE_R past the block point
                    local tgts = {}
                    for _, eid in ipairs(t.ids) do
                        local ex, _, ez = Spring.GetUnitPosition(eid)
                        if ex then local h = o.hist(eid); tgts[#tgts + 1] = { id = eid, x = ex, z = ez, vx = h and h.vx or 0, vz = h and h.vz or 0 } end
                    end
                    for _, uid in ipairs(w.units) do
                        local x, _, z = Spring.GetUnitPosition(uid)
                        if x then
                            local e
                            for _, c in ipairs(tgts) do if c.id == chaseOf[uid] then e = c end end
                            if not e then
                                local bd
                                for _, c in ipairs(tgts) do local d = Dist(x, z, c.x, c.z); if not bd or d < bd then e, bd = c, d end end
                            end
                            local mx, mz = t.x, t.z
                            if e then
                                chaseOf[uid] = e.id
                                mx, mz = DA.ChasePoint(army.cfg, x, z, math.max(1, Speed(owner[uid].defID)), e.x, e.z, e.vx, e.vz)
                            end
                            local d = Dist(mx, mz, bx, bz)
                            if d > C.CHASE_R then mx, mz = bx + (mx - bx) / d * C.CHASE_R, bz + (mz - bz) / d * C.CHASE_R end
                            if MM and MM.Clamp then mx, mz = MM.Clamp(mx, mz, 50) end
                            Claim(frame, uid, CMD_MOVE, mx, mz, ARMY.PRIO.RESPOND)
                        end
                    end
                else
                    Line(frame, w, bx, bz, t.ux, t.uz, ARMY.PRIO.RESPOND)
                end
                Tzars(frame, w, bx, bz, t.ux, t.uz, ARMY.PRIO.RESPOND)
            end
        end
        -- surplus Pounders walk to their nano; the macro side's nanos reclaim them (home_defence.lua reads WG.DefenceReclaim)
        if WG then WG.DefenceReclaim = WG.DefenceReclaim or {} end
        for uid, r in pairs(reclaim) do
            if not Alive(uid) then reclaim[uid] = nil
            else
                local x, _, z = Spring.GetUnitPosition(uid)
                local tx, tz = r.x, r.z
                if x then
                    local d = Dist(x, z, r.x, r.z)
                    if d > 1 then tx, tz = r.x + (x - r.x) / d * C.RECLAIM_OFF, r.z + (z - r.z) / d * C.RECLAIM_OFF end
                end
                Claim(frame, uid, CMD_MOVE, tx, tz, ARMY.PRIO.HOME_GUARD)
                if WG then WG.DefenceReclaim[uid] = { x = tx, z = tz, frame = frame, nano = r.nano } end
            end
        end
        for uid in pairs(chaseOf) do if not owner[uid] then chaseOf[uid] = nil end end
    end

    function W.Summary()
        local s = { walls = 0, pounders = 0, tzars = 0, want = 0, wantT = 0, reclaiming = 0, sent = stats.sent, reclaimed = stats.reclaimed, onThreat = 0 }
        for _, w in ipairs(allWalls()) do
            s.walls, s.pounders, s.tzars, s.want, s.wantT = s.walls + 1, s.pounders + #w.units, s.tzars + #w.tzars, s.want + w.want, s.wantT + w.wantT
            if w.threat then s.onThreat = s.onThreat + 1 end
        end
        for _ in pairs(reclaim) do s.reclaiming = s.reclaiming + 1 end
        return s
    end
    function W.TzarRoom() return math.max(0, TzarWant(allWalls()) - TzarHave()) end
    function W.Units() return owner end
    return W
end

return M
