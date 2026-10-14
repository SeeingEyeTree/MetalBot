-- bar_framework/bomb_run.lua  (LINE_BOMB)
-- Flies the T1 bombing run from stances/T1_bombing_run.lua:
--   "The fighters should fight ahead of the bombers to clear out any enemy fighters and scout for targets.  The bombers
--    should spread their bombs on mexes and wind, about 4 per target area, so if 2 of them die the target still dies.
--    Hit as much of the eco as possible while making sure it dies when hit."
--
-- RALLY   bombers and fighters wait at home (no orders: they idle on the pads / over the labs).  Launch when LAUNCH_MIN
--         bombers are up, or LAUNCH_FLOOR of them once the raid has waited LAUNCH_WAIT frames, AND a target exists.
-- STRIKE  every tick: enemy economy (mex, wind, nanos, labs...) is grouped into bombing points (CLUSTER_R); the top
--         K = bombers / PER_TARGET points get PER_TARGET bombers each (an ATTACK on the point; the broker re-states it
--         every heartbeat, which sends the next pass).  Points that are flattened drop out and their bombers move to the
--         next best.  Fighters FIGHT at the best point (they arrive first: they are faster).
--         A point is only chosen where the enemy AA (enemy_intel ThreatAt "air") is under AA_MAX x the wave's value.
-- RETURN  the wave ends when it is spent (SPENT_FRAC of its value left), timed out, or out of targets; survivors go home and
--         rally for the next wave (RELAUNCH_MIN).
--
-- Orders go through army_broker (role "BOMBRUN" at RAID priority).  Log rows are "[BR]".  Nothing here builds anything.

local M = {}
local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")   -- Apply(): merge overrides + one [CFG] log row

M.CFG = {
    EVERY         = 30,
    LAUNCH_MIN    = 20,       -- bombers up before the first wave goes
    LAUNCH_FLOOR  = 12,       -- ...or this many once the raid has waited LAUNCH_WAIT
    LAUNCH_WAIT   = 2700,     -- frames (90 s) after the plan says BOMB
    RELAUNCH_MIN  = 10,
    COOLDOWN      = 450,
    FIGHTER_MIN   = 3,        -- fighters that fly with the wave (fewer stay home)
    PER_TARGET    = 4,        -- bombers on each bombing point
    MAX_POINTS    = 8,
    CLUSTER_R     = 200,      -- eco this close together is one bombing point (bomb AOE is 168)
    POINT_SEP     = 320,      -- two chosen points are at least this far apart
    AA_MAX        = 0.60,     -- AA value allowed at a point, x the wave's value
    SPENT_FRAC    = 0.35,
    RUN_FRAMES    = 4500,
    RETURN_FRAMES = 450,
    DIST_SCALE    = 6000,
    BP_WEIGHT     = 4, ECO_BONUS = 150, VALUE_WEIGHT = 0.15,
    MIN_POINT     = 60,       -- a point worth less than this is not worth a pass
    SCOUT_FIGHTERS = 2,       -- fighters sent over the enemy economy before launch, to give the bombers eyes
    MARGIN        = 300,
    MIN_LAUNCH_DAMAGE = 700,  -- known damage value over all bombing points before a wave leaves
    LAUNCH_BLIND  = 1800,
    COMMIT_AA     = 1.6,      -- a wave in flight tolerates this x AA_MAX (it is committed)
    NO_TARGET_GRACE = 900,    -- frames a wave keeps its last points when the intel finds none
}
local CFG = M.CFG

local CMD_MOVE, CMD_FIGHT, CMD_ATTACK = 10, 16, 20

local MM, UQ, EI, ARMY
local bombersSet, combat, guards
local S = nil

local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end
local function Log(frame, fmtStr, ...)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[BR] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
end

local function Fresh()
    return { mode = "rally", t0 = 0, lastEnd = -1e9, waves = 0, wave = nil, bombStart = nil,
             lostBombers = 0, lostFighters = 0, kills = 0, killValue = 0, points = {}, assign = {}, scouts = {} }
end

M.NIL_OPTIONS = { "ECO_BONUS", "VALUE_WEIGHT" }   -- options whose default is nil on purpose (bot_config.lua does not warn about them)
function M.Init(o)
    MM, UQ, EI, ARMY = o.MM, o.UQ, o.EI, o.ARMY
    bombersSet, combat, guards = o.bombers, o.combat, o.guards or {}
    BC.Apply("bomb_run", CFG, o.cfg, o.label, M.NIL_OPTIONS)
    S = Fresh()
end

function M.Mode() return S and S.mode or "rally" end
function M.Waves() return S and S.waves or 0 end
function M.Status() return S end

-- Units ------------------------------------------------------------------------------------------------------
local function Free(uid)
    local role = ARMY.RoleOf(uid)
    return role == nil or role == "BOMBRUN" or role == "AIRWING" or role == "LINE" or role == "MUSTER" or role == "HOME_GUARD" or role == "BLOB"
end

-- fighters, bombers: arrays of {uid, x, z, hp, v}
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

local function Claim(frame, uid, cmd, x, z)
    ARMY.Claim(ARMY.PRIO.RAID, uid, { role = "BOMBRUN", cmd = cmd, x = x, z = z, opts = {} }, frame)
end

-- Targets ----------------------------------------------------------------------------------------------------
local function DamageValue(t)
    return (t.bp or 0) * CFG.BP_WEIGHT + (t.eco and CFG.ECO_BONUS or 0) + (t.value or 0) * CFG.VALUE_WEIGHT
end

-- Bombing points: value-weighted cluster centres of STATIC enemy economy, best first, at least POINT_SEP apart, each
-- under the AA cap.  Returns { {x, z, damage, aa, score}, ... } (at most `want`).
function M.Points(frame, want, aaCap)
    local hx, hz = MM.Home()
    local pts = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile then pts[#pts + 1] = t end
    end
    local cands = {}
    for _, c in ipairs(pts) do
        local sum, sx, sz = 0, 0, 0
        for _, t in ipairs(pts) do
            if Dist(c.x, c.z, t.x, t.z) <= CFG.CLUSTER_R then
                local dv = DamageValue(t)
                sum, sx, sz = sum + dv, sx + t.x * dv, sz + t.z * dv
            end
        end
        if sum >= CFG.MIN_POINT then
            local x, z = sx / sum, sz / sum
            local aa = EI.ThreatAt(frame, x, z, "air")
            if aa <= aaCap then
                cands[#cands + 1] = { x = x, z = z, damage = sum, aa = aa,
                                      score = sum / (1 + Dist(hx, hz, x, z) / CFG.DIST_SCALE) / (1 + aa / math.max(aaCap, 1)) }
            end
        end
    end
    table.sort(cands, function(a, b) return a.score > b.score end)
    local out = {}
    for _, c in ipairs(cands) do
        local ok = true
        for _, o in ipairs(out) do
            if Dist(o.x, o.z, c.x, c.z) < CFG.POINT_SEP then ok = false; break end
        end
        if ok then out[#out + 1] = c end
        if #out >= want then break end
    end
    return out
end

-- Spread n bombers over the points, PER_TARGET each, the rest on the best points.  Sticky: a bomber keeps the point it
-- had when one is still in the list within CLUSTER_R.  Returns uid -> point index.
local function Assign(bombers, points)
    local counts, out = {}, {}
    for i = 1, #points do counts[i] = 0 end
    local pending = {}
    for _, b in ipairs(bombers) do
        local old = S.assign[b.uid]
        local keep
        if old then
            for i, p in ipairs(points) do
                if Dist(old.x, old.z, p.x, p.z) <= CFG.CLUSTER_R and counts[i] < CFG.PER_TARGET * 1.5 then keep = i; break end
            end
        end
        if keep then out[b.uid] = keep; counts[keep] = counts[keep] + 1 else pending[#pending + 1] = b end
    end
    for _, b in ipairs(pending) do
        local best, bestC
        for i = 1, #points do
            local c = counts[i]
            -- fill each point to PER_TARGET (best first) before stacking more on the best ones
            local key = (c < CFG.PER_TARGET) and (c * 100 + i) or (1e6 + c * 100 + i)
            if not bestC or key < bestC then best, bestC = i, key end
        end
        if best then out[b.uid] = best; counts[best] = counts[best] + 1 end
    end
    return out
end

local function Station()
    local x, z = MM.PointAt(0.10 * MM.Dist(), 0)
    return MM.Clamp(x, z, CFG.MARGIN)
end

local function GoHome(frame, list)
    local hx, hz = MM.Home()
    for _, u in ipairs(list) do Claim(frame, u.uid, CMD_MOVE, hx, hz) end
end

local function Release(list)
    for _, u in ipairs(list) do
        if ARMY.RoleOf(u.uid) == "BOMBRUN" then ARMY.Release(u.uid) end
    end
end

local function EndWave(frame, why, fighters, bombers)
    Log(frame, "wave %d ends after %ds (%s): %d bombers + %d fighters left", S.waves, math.floor((frame - S.t0) / 30), why,
        #bombers, #fighters)
    S.mode, S.t0, S.lastEnd, S.assign, S.noPts = "return", frame, frame, {}, nil
end

-- Update (every EVERY frames) --------------------------------------------------------------------------------
-- plan = WG.BombPlan (phase_plan.View) or nil.
function M.Update(frame, plan)
    if not (S and MM and UQ and EI and ARMY and MM.Ready()) then return end
    if frame % CFG.EVERY ~= 0 then return end
    local fighters, bombers = Gather()
    local fv, bv = SumV(fighters), SumV(bombers)

    if plan and plan.bomb and not S.bombStart then S.bombStart = frame end

    if S.mode == "return" then
        GoHome(frame, fighters); GoHome(frame, bombers)
        if frame - S.t0 > CFG.RETURN_FRAMES then
            Release(fighters); Release(bombers)
            S.mode = "rally"
        end
        return
    end

    if S.mode == "strike" then
        local wave = S.wave
        local age = frame - S.t0
        local now = fv + bv
        local why
        if #bombers == 0 then why = "no bombers"
        elseif now < CFG.SPENT_FRAC * wave.startValue then why = "spent"
        elseif age > CFG.RUN_FRAMES then why = "time" end
        local pts
        if not why then
            -- The AA cap is fixed by the wave as launched: a wave that loses its escorts on the way must not decide the
            -- targets became too dangerous and turn back before it has dropped anything (first real run: 6 fighters shot down,
            -- cap fell, "no targets", 14 bombers went home having bombed nothing).
            local aaCap = CFG.AA_MAX * wave.startValue * CFG.COMMIT_AA
            pts = M.Points(frame, math.max(1, math.min(CFG.MAX_POINTS, math.floor(#bombers / CFG.PER_TARGET + 0.5))), aaCap)
            if #pts == 0 and #(S.points or {}) > 0 and (S.noPts or frame) - frame > -CFG.NO_TARGET_GRACE then
                S.noPts = S.noPts or frame
                pts = S.points            -- keep bombing where we were going; the picture may just have flickered
            elseif #pts == 0 then why = "no targets"
            else S.noPts = nil end
        end
        if why then EndWave(frame, why, fighters, bombers); GoHome(frame, fighters); GoHome(frame, bombers); return end
        local who = Assign(bombers, pts)
        S.assign = {}
        for _, b in ipairs(bombers) do
            local i = who[b.uid]
            local p = pts[i]
            if p then
                S.assign[b.uid] = p
                Claim(frame, b.uid, CMD_ATTACK, p.x, p.z)
            end
        end
        S.points = pts
        local lead = pts[1]
        for _, f in ipairs(fighters) do Claim(frame, f.uid, CMD_FIGHT, lead.x, lead.z) end
        if frame >= (S.nextLog or 0) then
            S.nextLog = frame + 600
            Log(frame, "wave %d: %d bombers on %d points (best (%d,%d) damage %d aa %d), %d fighters | lost B %d F %d | killed %d (value %d)",
                S.waves, #bombers, #pts, lead.x, lead.z, lead.damage, lead.aa, #fighters, S.lostBombers, S.lostFighters,
                S.kills, S.killValue)
        end
        return
    end

    -- RALLY -----------------------------------------------------------------------------------------------
    local stx, stz = Station()
    local active = plan and (plan.bomb or S.waves > 0)
    if not active then
        -- not our moment (or the raid was dropped): leave the units to everyone else
        Release(fighters); Release(bombers)
        return
    end
    for _, b in ipairs(bombers) do Claim(frame, b.uid, CMD_MOVE, stx, stz) end

    -- eyes: a couple of fighters over the enemy economy until the bombers know where to go
    local pts = M.Points(frame, CFG.MAX_POINTS, CFG.AA_MAX * math.max(bv + fv, 1))
    local fx, fz = MM.Foe()
    for i, f in ipairs(fighters) do
        if #pts == 0 and i <= CFG.SCOUT_FIGHTERS and fx then
            Claim(frame, f.uid, CMD_MOVE, fx, fz)
        else
            Claim(frame, f.uid, CMD_FIGHT, stx, stz)
        end
    end

    local need = (S.waves == 0) and CFG.LAUNCH_MIN or CFG.RELAUNCH_MIN
    if S.waves == 0 and S.bombStart and frame - S.bombStart >= CFG.LAUNCH_WAIT then need = CFG.LAUNCH_FLOOR end
    -- a wave that leaves blind (run 3: one 156-damage point known, 30 bombers flew, the eco was found on the way) waits for
    -- intel: the fighters over the enemy economy find it; after LAUNCH_BLIND frames more it goes anyway
    local dmg = 0
    for _, p in ipairs(pts) do dmg = dmg + p.damage end
    local blind = dmg < CFG.MIN_LAUNCH_DAMAGE and not (S.bombStart and frame - S.bombStart >= CFG.LAUNCH_WAIT + CFG.LAUNCH_BLIND)
    if #bombers >= need and frame - S.lastEnd >= CFG.COOLDOWN and #pts > 0 and not blind then
        S.waves = S.waves + 1
        S.mode, S.t0, S.wave = "strike", frame, { startValue = fv + bv, bombers = #bombers, fighters = #fighters }
        S.nextLog = 0
        Log(frame, "LAUNCH wave %d: %d bombers (%d value) + %d fighters; %d bombing points, best (%d,%d) damage %d aa %d",
            S.waves, #bombers, bv, #fighters, #pts, pts[1].x, pts[1].z, pts[1].damage, pts[1].aa)
        for _, f in ipairs(fighters) do Claim(frame, f.uid, CMD_FIGHT, pts[1].x, pts[1].z) end
        local who = Assign(bombers, pts)
        for _, b in ipairs(bombers) do
            local p = pts[who[b.uid]]
            if p then S.assign[b.uid] = p; Claim(frame, b.uid, CMD_ATTACK, p.x, p.z) end
        end
    end
end

-- A unit died.  Count our losses; credit enemy economy killed near a bombing point.
function M.OnDestroyed(uid, defID, isMine, frame, x, z)
    if not S then return end
    if isMine then
        if UQ.is_bomber(defID) then S.lostBombers = S.lostBombers + 1
        elseif UQ.is_air(defID) and UQ.is_dedicated_aa(defID) then S.lostFighters = S.lostFighters + 1 end
        S.assign[uid] = nil
        return
    end
    if S.mode ~= "strike" or not x then return end
    for _, p in ipairs(S.points or {}) do
        if Dist(x, z, p.x, p.z) <= CFG.CLUSTER_R * 1.5 then
            local c = EI.Class(defID)
            if c and (c.eco or c.bp > 0 or c.factory or c.builder) then
                S.kills = S.kills + 1
                S.killValue = S.killValue + math.floor(c.value)
            end
            return
        end
    end
end

return M
