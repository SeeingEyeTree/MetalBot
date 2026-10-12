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
}
M.CFG = CFG

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20

local MM, UQ, EI, ARMY
local combat, guards, bombersSet
local wing = { mode = "idle", t0 = 0, lastStrikeEnd = -1e9 }
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

function M.Init(o)
    MM, UQ, EI, ARMY = o.MM, o.UQ, o.EI, o.ARMY
    combat, guards, bombersSet = o.combat, o.guards, o.bombers
    for k, v in pairs(o.cfg or {}) do CFG[k] = v end
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
local function Station()
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
    local stx, stz = Station()

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
    if not tgt then
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
