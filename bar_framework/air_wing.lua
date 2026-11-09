-- bar_framework/air_wing.lua  (LINE_CLICK_v16)
-- A standing air wing with two jobs, run apart from click_army's ground groups:
--
--   HUNT    The wing's fighters (dedicated AA that are not home guards) fly to where the enemy keeps its air constructors
--           and air units: a fresh sighting of an enemy flying builder first, else enemy armed air we outweigh, else a
--           SWEEP of the densest enemy economy (fighters on FIGHT shoot whatever flies near and give the bombers eyes).
--           A sortie ends when it is spent (value or health), timed out, or the target's area got too much AA.
--   STRIKE  The wing's bombers, with the fighters flying ahead as escort, hit the densest cluster of enemy economy and
--           build power -- ranked like click_army's targets, discounted by distance -- ONLY where the AA there (enemy_intel
--           ThreatAt "air") is under BOMB_AA_MAX x the wing's value: one pass that pays is the goal, not a trade ratio.
--           Then everyone goes home.
--
-- Units are claimed through army_broker with role "AIRWING" at RAID priority (above home guard / muster / line, below
-- retreat), so the wing is not recalled by the ground logic and endgame.Strike's home-holding does not take the bombers.
-- Log rows, all "[AW]": sorties, strikes, KILLs of builders/eco near a sortie, a once-a-minute total.

local M = {}
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")   -- Apply(): merge overrides + one [CFG] log row
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local CFG = {
    START_FRAME   = 7 * 60 * 30,
    EVERY         = 30,
    FIGHTER_MIN   = 6,        -- wing fighters before the wing flies at all (fewer stay with click_army's escort)
    BOMBER_MIN    = 5,
    CLUSTER_R     = 380,      -- targets this close together are one bombing point
    HUNT_AA_MAX   = 0.55,     -- a hunt spot may hold AA worth up to this x the wing fighters' value
    BOMB_AA_MAX   = 0.60,     -- a strike spot may hold AA worth up to this x (bombers + escort) value
    AIR_MARGIN    = 2.0,      -- engage enemy air only when our fighters outvalue it by this much
    FRESH_CON     = 600,      -- an enemy air constructor seen this recently is a hunt target (frames)
    FRESH_AIR     = 450,
    SORTIE_FRAMES = 1500,     -- a hunt sortie lasts at most this long
    RUN_FRAMES    = 1350,     -- a bomber run lasts at most this long
    BOMB_COOLDOWN = 1500,     -- frames between strikes (from the end of the last)
    REPICK        = 150,      -- frames between re-aiming a sortie
    SPENT_FRAC    = 0.55,     -- a sortie ends when this share of its start value is left
    HURT_HP       = 0.45,     -- ...or when the wing's average health is under this
    DIST_SCALE    = 6000,     -- a target this far away is worth half
    BP_WEIGHT     = 4, ECO_BONUS = 150, VALUE_WEIGHT = 0.15,
    STATION_FRAC  = 0.12,     -- idle wing waits this far along home -> foe
    MARGIN        = 300,
    -- AIR_TIMING (user 2026-10-25: "it sends out fighters randomly ... fighters should be kept at home, move behind the army to respond to
    -- enemy air, or go with a bombing run"): NO_SWEEP drops the sweeps over the enemy economy; HUNT_NEAR_R limits hunts to enemy air
    -- within this of our base or the wing's station (behind the army).  nil / false = the old wing.
    NO_SWEEP      = false,
    HUNT_NEAR_R   = nil,
    ESCORT_LEAD   = 350,      -- ESCORT: the fighters fly this far ahead of the proxy convoy's transports, toward the site
    -- PROXY GUARD (user 2026-11-09: "keep some figs closer to the proxy base. Have the figs with the convy stay around the base. You can just pull them from
    -- the main base. It does not need to keep them all. Keep figs at the proxy to defend and send more as needed, the aa helps but it can't be there at the
    -- start"): once the convoy is down and the proxy stands (WG.ProxyBase), PROXY_FIGHTERS wing fighters -- the nearest first, so the escort stays --
    -- FIGHT round it; more while enemy armed air is seen near it (PROXY_AIR_MARGIN x its value) or the proxy's crew is losing to air (x 2), up to
    -- PROXY_FIGHTERS_MAX.  The rest of the wing hunts / strikes / waits as before.
    -- (user, same day: "You need way more than 6 fighters. All the ones that came with the escort should stay. You want to keep them around the ring not
    -- circleling around": every escort fighter stays, at least PROXY_FIGHTERS, each on its own fixed post on a ring PROXY_ORBIT round the proxy)
    PROXY_FIGHTERS     = 20,
    PROXY_FIGHTERS_MAX = 60,
    PROXY_AIR_R        = 2500,   -- enemy air this close to the proxy counts
    PROXY_AIR_MARGIN   = 1.5,
    PROXY_AIR_AGE      = 900,    -- ... seen this recently (frames)
    PROXY_ORBIT        = 700,    -- the guard's posts: evenly round a ring this far from the proxy (each fighter FIGHTs its own post and stays there)
}
M.CFG = CFG

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20

local MM, UQ, EI, ARMY
local combat, guards, bombersSet
local wing = { mode = "idle", t0 = 0, lastStrikeEnd = -1e9 }
local stationFn = nil      -- o.station(frame) -> x, z: where the idle wing waits (RAID_BOT: click_army.FighterPost)
local convoyFn = nil       -- o.convoy() -> WG.ProxyConvoy (the proxy base's transports in flight) or nil
local proxyFn = nil        -- o.proxy() -> WG.ProxyBase (the proxy base) or nil: the PROXY GUARD
local requestFn = nil      -- o.request(key, spec) / o.request(key, nil) to drop: WG.LabOrders -- the guard's replacements
local totals = { sorties = 0, strikes = 0, builderKills = 0, ecoKills = 0, airKills = 0, lostFighters = 0, lostBombers = 0,
                 killValue = 0 }
local nextLog = 0

local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end
local function Log(frame, fmtStr, ...)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[AW] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
end

M.NIL_OPTIONS = { "ECO_BONUS", "VALUE_WEIGHT", "HUNT_NEAR_R" }   -- options whose default is nil on purpose (bot_config.lua does not warn about them)
function M.Init(o)
    MM, UQ, EI, ARMY = o.MM, o.UQ, o.EI, o.ARMY
    combat, guards, bombersSet = o.combat, o.guards, o.bombers
    stationFn = o.station
    convoyFn = o.convoy
    proxyFn = o.proxy
    requestFn = o.request
    BC.Apply("air_wing", CFG, o.cfg, o.label, M.NIL_OPTIONS)
    wing = { mode = "idle", t0 = 0, lastStrikeEnd = -1e9 }
    totals = { sorties = 0, strikes = 0, builderKills = 0, ecoKills = 0, airKills = 0, lostFighters = 0, lostBombers = 0,
               killValue = 0 }
    nextLog = 0
end

-- Queries ----------------------------------------------------------------------------------------------------
function M.Totals() return totals end
function M.Mode() return wing.mode end
function M.IsMember(uid) return wing.members ~= nil and wing.members[uid] == true end

-- Units ------------------------------------------------------------------------------------------------------
local function Free(uid)
    local role = ARMY.RoleOf(uid)
    return role == nil or role == "AIRWING" or role == "BLOB" or role == "LINE" or role == "MUSTER" or role == "HOME_GUARD"
end

-- Returns fighters, bombers: arrays of {uid, x, z, hp, v}.
local function Gather()
    local fighters, bombers = {}, {}
    local function add(list, uid, defID)
        local x, _, z = Spring.GetUnitPosition(uid)
        if not x then return end
        local hp, mhp = Spring.GetUnitHealth(uid)
        list[#list + 1] = { uid = uid, x = x, z = z, hp = (hp and mhp and mhp > 0) and hp / mhp or 1, v = Value(defID) }
    end
    for uid, defID in pairs(combat) do
        if UQ.is_air(defID) and UQ.is_dedicated_aa(defID) and Alive(uid) and not guards[uid] and Free(uid) then
            add(fighters, uid, defID)
        end
    end
    for uid in pairs(bombersSet) do
        local defID = Spring.GetUnitDefID(uid)
        if defID and Free(uid) then add(bombers, uid, defID) end
    end
    return fighters, bombers
end

local function SumV(list) local v = 0; for _, u in ipairs(list) do v = v + u.v end; return v end
local function AvgHp(list)
    if #list == 0 then return 1 end
    local s = 0
    for _, u in ipairs(list) do s = s + u.hp end
    return s / #list
end

local function Claim(frame, uid, cmd, x, z, targetID)
    ARMY.Claim(ARMY.PRIO.RAID, uid, { role = "AIRWING", cmd = cmd, x = x, z = z, targetID = targetID, opts = {} }, frame)
end

-- Targets ----------------------------------------------------------------------------------------------------
local function DamageValue(t)
    return (t.bp or 0) * CFG.BP_WEIGHT + (t.eco and CFG.ECO_BONUS or 0) + (t.value or 0) * CFG.VALUE_WEIGHT
end

-- The best bombing / sweeping point among STATIC enemy economy and build power, discounted by distance from home.
-- Returns {x, z, damage, aa} or nil.  `aaCap` is the most AA value allowed at the spot.
local function PickCluster(frame, aaCap)
    local hx, hz = MM.Home()
    local pts = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile then pts[#pts + 1] = t end
    end
    local best, bestScore
    for _, c in ipairs(pts) do
        local sum, sx, sz = 0, 0, 0
        for _, t in ipairs(pts) do
            if Dist(c.x, c.z, t.x, t.z) <= CFG.CLUSTER_R then
                local dv = DamageValue(t)
                sum, sx, sz = sum + dv, sx + t.x * dv, sz + t.z * dv
            end
        end
        if sum > 0 then
            local x, z = sx / sum, sz / sum
            local score = sum / (1 + Dist(hx, hz, x, z) / CFG.DIST_SCALE)
            if (not bestScore or score > bestScore) then
                local aa = EI.ThreatAt(frame, x, z, "air")
                if aa <= aaCap then best, bestScore = { x = x, z = z, damage = sum, aa = aa }, score end
            end
        end
    end
    return best
end

-- A fresh enemy flying constructor group, else enemy armed air we outweigh.  Returns {x, z, kind, v} or nil.
local function PickAirTarget(frame, fighterValue)
    local cons, airs = {}, {}
    for uid, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.air and c.mobile then
            local age = frame - rec.frame
            if c.builder and not c.factory and age <= CFG.FRESH_CON then cons[#cons + 1] = rec
            elseif c.armed and not c.scout and age <= CFG.FRESH_AIR then airs[#airs + 1] = rec end
        end
    end
    local function pick(list, minV)
        local best, bestV
        for _, a in ipairs(list) do
            local v = 0
            for _, b in ipairs(list) do
                if Dist(a.x, a.z, b.x, b.z) <= 900 then v = v + b.c.value end
            end
            if v >= minV and (not bestV or v > bestV) then
                if EI.ThreatAt(frame, a.x, a.z, "air") <= CFG.HUNT_AA_MAX * fighterValue then best, bestV = a, v end
            end
        end
        return best, bestV
    end
    local a, v = pick(cons, 1)
    if a then return { x = a.x, z = a.z, kind = "air-con", v = v } end
    a, v = pick(airs, 1)
    if a and fighterValue >= CFG.AIR_MARGIN * v then return { x = a.x, z = a.z, kind = "air", v = v } end
    return nil
end

-- Orders -----------------------------------------------------------------------------------------------------
local function Station(frame)
    if stationFn then
        local ok, x, z = pcall(stationFn, frame)
        if ok and x then return MM.Clamp(x, z, CFG.MARGIN) end
    end
    local x, z = MM.PointAt(CFG.STATION_FRAC * MM.Dist(), 0)
    return MM.Clamp(x, z, CFG.MARGIN)
end

local function Release(list)
    for _, u in ipairs(list) do
        if ARMY.RoleOf(u.uid) == "AIRWING" then ARMY.Release(u.uid) end
    end
end

local function GoHome(frame, list)
    local hx, hz = MM.Home()
    for _, u in ipairs(list) do Claim(frame, u.uid, CMD_MOVE, hx, hz) end
end

-- Update (every EVERY frames) --------------------------------------------------------------------------------
function M.Update(frame)
    if not (MM and UQ and EI and ARMY and MM.Ready()) then return end
    if frame < CFG.START_FRAME or frame % CFG.EVERY ~= 0 then return end
    local fighters, bombers = Gather()
    local fv, bv = SumV(fighters), SumV(bombers)
    wing.members = {}
    for _, u in ipairs(fighters) do wing.members[u.uid] = true end
    for _, u in ipairs(bombers) do wing.members[u.uid] = true end

    local fly = #fighters >= CFG.FIGHTER_MIN
    local stx, stz = Station(frame)

    -- ESCORT (user 2026-11-08, the proxy base: "The air trans should move as one group and be escorted by the fighters"): while the proxy's convoy
    -- (WG.ProxyConvoy, the macro side's sink_lift.lua) gathers or flies, every wing fighter (any number; a hunt is dropped, a strike keeps its own)
    -- FIGHTs a point ESCORT_LEAD ahead of the transports' centre, toward the site.
    local cv = convoyFn and convoyFn()
    if cv and cv.x and cv.tx and wing.mode ~= "strike" and #fighters > 0 then
        if wing.mode ~= "escort" then
            Log(frame, "ESCORT: %d fighters (%d) with the proxy convoy (%d transports, %s) at %d,%d -> %d,%d", #fighters, fv, cv.n or 0, tostring(cv.state), cv.x, cv.z, cv.tx, cv.tz)
            wing.mode, wing.t0 = "escort", frame
        end
        local dx, dz = cv.tx - cv.x, cv.tz - cv.z
        local d = math.sqrt(dx * dx + dz * dz)
        local k = (d > 1) and math.min(CFG.ESCORT_LEAD, d) / d or 0
        for _, u in ipairs(fighters) do Claim(frame, u.uid, CMD_FIGHT, cv.x + dx * k, cv.z + dz * k) end
        for _, u in ipairs(bombers) do Claim(frame, u.uid, CMD_MOVE, stx, stz) end
        return
    elseif wing.mode == "escort" then
        Log(frame, "ESCORT ends after %ds (the convoy is down): its %d fighters stay at the proxy", math.floor((frame - wing.t0) / 30), #fighters)
        wing.proxy = wing.proxy or {}
        for _, u in ipairs(fighters) do wing.proxy[u.uid] = true end              -- (the escort is the proxy's guard)
        wing.proxyBase = math.max(wing.proxyBase or 0, #fighters)                 -- (its strength: lost ones are replaced up to it)
        Release(fighters)
        wing.mode = "idle"
    end

    -- PROXY GUARD: some fighters stay at the proxy; they leave the wing's other jobs
    local PB = proxyFn and proxyFn()
    if PB and PB.x and PB.go and (PB.labID or PB.frameID or PB.state == "con") and #fighters > 0 then
        local ev = 0
        for _, rec in pairs(EI.Records()) do
            local c = rec.c
            if c.air and c.mobile and c.armed and not c.scout and frame - rec.frame <= CFG.PROXY_AIR_AGE and Dist(rec.x, rec.z, PB.x, PB.z) <= CFG.PROXY_AIR_R then
                ev = ev + (c.value or 0)
            end
        end
        local per = fv / #fighters
        -- (game 20, 2026-11-09: DEFENCE_BOT's air wore the guard from 32 to 3 and none came back -- the labs replace the losses: the guard asks for
        -- fighters up to its strength at landing, or what the enemy air there needs, whichever is more)
        local need = math.max(CFG.PROXY_FIGHTERS, wing.proxyBase or 0)
        if ev > 0 and per > 0 then need = math.max(need, math.ceil(CFG.PROXY_AIR_MARGIN * ev / per)) end
        need = math.min(need, math.max(CFG.PROXY_FIGHTERS_MAX, wing.proxyBase or 0))
        local old = wing.proxy or {}
        local nOld = 0
        for _, u in ipairs(fighters) do if old[u.uid] then nOld = nOld + 1 end end
        local want = math.max(CFG.PROXY_FIGHTERS, nOld)                          -- (all the escort stays)
        if ev > 0 and per > 0 then want = math.max(want, math.ceil(CFG.PROXY_AIR_MARGIN * ev / per)) end
        if PB.airHot then want = math.max(want, nOld + CFG.PROXY_FIGHTERS) end
        want = math.min(want, math.max(CFG.PROXY_FIGHTERS_MAX, nOld), #fighters)
        local keep, rest = {}, {}
        for _, u in ipairs(fighters) do if old[u.uid] then keep[#keep + 1] = u else rest[#rest + 1] = u end end
        table.sort(rest, function(a, b) return Dist(a.x, a.z, PB.x, PB.z) < Dist(b.x, b.z, PB.x, PB.z) end)
        while #keep < want and #rest > 0 do keep[#keep + 1] = table.remove(rest, 1) end
        while #keep > want do table.insert(rest, 1, table.remove(keep)) end
        wing.proxy = {}
        table.sort(keep, function(a, b) return a.uid < b.uid end)                 -- (stable posts: a fighter keeps its place on the ring)
        for i, u in ipairs(keep) do
            wing.proxy[u.uid] = true
            local a = (i - 1) * 2 * math.pi / #keep
            Claim(frame, u.uid, CMD_FIGHT, PB.x + math.cos(a) * CFG.PROXY_ORBIT, PB.z + math.sin(a) * CFG.PROXY_ORBIT)
        end
        if #keep ~= (wing.proxyN or 0) or want ~= (wing.proxyWant or 0) then
            Log(frame, "PROXY GUARD: %d fighters at the proxy %d,%d (want %d: enemy air there %d%s)", #keep, PB.x, PB.z, want, ev, PB.airHot and ", the crew losing to air" or "")
            wing.proxyN, wing.proxyWant = #keep, want
        end
        if requestFn then
            local short = need - #keep
            if short > 0 then
                requestFn("proxy:fighters", { picks = { ROLES.Get("fighter_t2"), ROLES.Get("fighter_t1") }, n = short, tier = "high", require = false })
                if frame - (wing.reqLogF or -1e9) >= 1800 then
                    wing.reqLogF = frame
                    Log(frame, "PROXY GUARD short %d fighters (%d of %d): asked of the labs", short, #keep, need)
                end
            else requestFn("proxy:fighters", nil) end
        end
        fighters, fv = rest, SumV(rest)
        fly = #fighters >= CFG.FIGHTER_MIN
    elseif wing.proxy then
        Log(frame, "PROXY GUARD ends (no proxy)")
        wing.proxy, wing.proxyN, wing.proxyWant, wing.proxyBase = nil, nil, nil, nil
        if requestFn then requestFn("proxy:fighters", nil) end
    end

    -- end of a sortie / run
    if wing.mode == "hunt" or wing.mode == "strike" then
        local age = frame - wing.t0
        local spent = (fv + bv) < CFG.SPENT_FRAC * wing.startValue
        local hurt = AvgHp(fighters) < CFG.HURT_HP and AvgHp(bombers) < CFG.HURT_HP
        local limit = (wing.mode == "strike") and CFG.RUN_FRAMES or CFG.SORTIE_FRAMES
        if age > limit or spent or hurt or (#fighters + #bombers) == 0 then
            Log(frame, "%s ends after %ds: %d fighters + %d bombers left of value %d (started %d)%s", wing.mode, math.floor(age / 30),
                #fighters, #bombers, fv + bv, wing.startValue, spent and " [spent]" or (hurt and " [hurt]" or ""))
            if wing.mode == "strike" then wing.lastStrikeEnd = frame end
            wing.mode = "returning"
            wing.t0 = frame
        end
    end
    if wing.mode == "returning" then
        GoHome(frame, fighters); GoHome(frame, bombers)
        if frame - wing.t0 > 450 then
            Release(fighters); Release(bombers)
            wing.mode = "idle"
        end
        return
    end

    -- STRIKE: bombers with the fighters ahead of them
    if wing.mode == "idle" and #bombers >= CFG.BOMBER_MIN and frame - wing.lastStrikeEnd >= CFG.BOMB_COOLDOWN then
        local cl = PickCluster(frame, CFG.BOMB_AA_MAX * (bv + fv))
        if cl then
            wing.mode, wing.t0, wing.startValue, wing.target = "strike", frame, fv + bv, cl
            totals.strikes = totals.strikes + 1
            Log(frame, "STRIKE %d: %d bombers + %d fighters -> (%d,%d) damage value %d, AA there %d vs wing %d",
                totals.strikes, #bombers, #fighters, cl.x, cl.z, cl.damage, cl.aa, fv + bv)
            for _, u in ipairs(fighters) do Claim(frame, u.uid, CMD_FIGHT, cl.x, cl.z) end
            for _, u in ipairs(bombers) do Claim(frame, u.uid, CMD_ATTACK, cl.x, cl.z) end
            return
        end
    end
    if wing.mode == "strike" then
        -- keep the orders fresh (broker re-issues only on a change or its heartbeat)
        local cl = wing.target
        for _, u in ipairs(fighters) do Claim(frame, u.uid, CMD_FIGHT, cl.x, cl.z) end
        for _, u in ipairs(bombers) do Claim(frame, u.uid, CMD_ATTACK, cl.x, cl.z) end
        return
    end

    -- HUNT: fighters alone
    if not fly then
        -- too few for a wing: give them back
        if wing.mode == "hunt" then wing.mode = "idle" end
        Release(fighters)
        for _, u in ipairs(bombers) do Claim(frame, u.uid, CMD_MOVE, stx, stz) end
        return
    end
    if wing.mode == "hunt" and frame - wing.lastPick < CFG.REPICK then
        for _, u in ipairs(fighters) do Claim(frame, u.uid, CMD_FIGHT, wing.target.x, wing.target.z) end
        return
    end
    local tgt = PickAirTarget(frame, fv)
    if tgt and CFG.HUNT_NEAR_R then                  -- only enemy air near our base or the station behind the army
        local hx, hz = MM.Home()
        local r2 = CFG.HUNT_NEAR_R * CFG.HUNT_NEAR_R
        if (tgt.x - hx) ^ 2 + (tgt.z - hz) ^ 2 > r2 and (tgt.x - stx) ^ 2 + (tgt.z - stz) ^ 2 > r2 then tgt = nil end
    end
    if not tgt and not CFG.NO_SWEEP then
        local cl = PickCluster(frame, CFG.HUNT_AA_MAX * fv)
        if cl then tgt = { x = cl.x, z = cl.z, kind = "sweep", v = cl.damage } end
    end
    if tgt then
        if wing.mode ~= "hunt" then
            wing.mode, wing.t0, wing.startValue = "hunt", frame, fv
            totals.sorties = totals.sorties + 1
            Log(frame, "HUNT %d (%s): %d fighters -> (%d,%d) value %d", totals.sorties, tgt.kind, #fighters, tgt.x, tgt.z, tgt.v)
        end
        wing.target, wing.lastPick = tgt, frame
        for _, u in ipairs(fighters) do Claim(frame, u.uid, CMD_FIGHT, tgt.x, tgt.z) end
        for _, u in ipairs(bombers) do Claim(frame, u.uid, CMD_MOVE, stx, stz) end
    else
        if wing.mode == "hunt" then wing.mode = "idle" end
        for _, u in ipairs(fighters) do Claim(frame, u.uid, CMD_FIGHT, stx, stz) end
        for _, u in ipairs(bombers) do Claim(frame, u.uid, CMD_MOVE, stx, stz) end
    end

    if frame >= nextLog then
        nextLog = frame + 1800
        Log(frame, "wing %s: %d fighters (%d) %d bombers (%d) | sorties %d strikes %d | killed builders %d eco %d air %d (value %d) | lost F %d B %d",
            wing.mode, #fighters, fv, #bombers, bv, totals.sorties, totals.strikes, totals.builderKills, totals.ecoKills,
            totals.airKills, totals.killValue, totals.lostFighters, totals.lostBombers)
    end
end

-- A unit died.  Credit enemy kills that happen near a sortie, count our losses.
function M.OnDestroyed(uid, defID, isMine, frame, x, z)
    if isMine then
        if wing.members and wing.members[uid] then
            if UQ.is_bomber(defID) then totals.lostBombers = totals.lostBombers + 1
            else totals.lostFighters = totals.lostFighters + 1 end
            wing.members[uid] = nil
        end
        return
    end
    if wing.mode == "idle" or not wing.target or not x then return end
    if Dist(x, z, wing.target.x, wing.target.z) > 2500 then return end
    local c = EI.Class(defID)
    if not c then return end
    if c.air and c.builder then totals.builderKills = totals.builderKills + 1
    elseif c.air and c.armed then totals.airKills = totals.airKills + 1
    elseif c.eco or c.bp > 0 or c.factory then totals.ecoKills = totals.ecoKills + 1
    else return end
    totals.killValue = totals.killValue + math.floor(c.value)
    Log(frame, "KILL %s value %d (builders %d, eco %d, air %d)", UnitDefs[defID].name, c.value, totals.builderKills,
        totals.ecoKills, totals.airKills)
end

return M
