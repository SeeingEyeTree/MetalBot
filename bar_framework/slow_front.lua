-- bar_framework/slow_front.lua
-- LINE_CLICK's SLOW GROUP, played the way the user plays it (human_control_logger.lua games of 2026-10-07):
-- Lashers (cormist) attack, Pounders (corlevlr) guard them, rez bots (cornecro) work behind them.
--
-- THE USER'S RULINGS
--   * AGGRESSIVE.  The Lashers ALWAYS carry a FIGHT order toward the enemy while nothing is in range: FIGHT is
--     attack-move, a unit stops when something is in its range, shoots, and walks on when it is dead.  They are never
--     "held" at a distance and never stand idle out of range.  (First real game of this module, 2026-10-07: a
--     standoff rule left them 1200 elmos from the enemy doing nothing - "not aggressive enough".)
--   * BACK OFF only when something is moving QUICKLY toward them (a charge).  Not for a slow or stationary enemy, not
--     because the enemy is "close".  Zero damage taken is NOT the goal: a unit that is firing is worth more than one
--     that is idle, and trading a few units is expected.
--   * MOVE to go BACK, FIGHT to go forward.  A FIGHT order will not walk a unit back while something is in its range,
--     so every retreat is a MOVE (and the next order is a FIGHT again).
--   * Pounders are not the front line.  They stay within ~PAD (200) of the Lashers, on the enemy side, only to SLOW
--     anything that dives the Lashers: an enemy within DIVE_R of a Lasher, or one charging them, is met by them.
--   * Rez bots reclaim BEHIND the Lashers and repair units.  They do not go ahead of the line.
--
-- GROUP    gather at a stage point (MOVE), leave together once LAUNCH_AV is there.  A group that falls under
--          SPENT_FRAC of its peak regroups at the stage.  Its CORE is the forward cluster (not the centroid of
--          everyone: new units at home dragged that back); reinforcements FIGHT to the core.
-- EACH PASS (every ~30 frames), from the armed enemies within SCAN_R of the Lashers (their own positions and
-- velocities, not a centroid):
--   a charge (enemies closing >= CHARGE_SPEED, able to hit within CHARGE_TTC s, worth >= CHARGE_MIN_FRAC of us)
--                                   -> MOVE back BACK_STEP away from them, Pounders meet them; then FIGHT again
--   an enemy in sight               -> FIGHT toward the nearest one
--   nothing in sight                -> FIGHT in legs toward the richest wreck field ahead (ending PAST it, so the rez
--                                      bots work behind the line), else the enemy base
--
-- Orders go straight to the engine (these units are this module's alone) with a per-unit de-dup, because the
-- army broker's 90-frame limit is too slow for a back-step.
-- Log rows, all "[SF]": launch, objective changes, back-offs, spent, a once-a-minute summary.

local M = {}

local CFG = {
    STAGE_FRAC    = 0.40,   -- the stage is this far along home->foe (the human gathered at ~45-50%)
    STAGE_SPACING = 60,
    STAGE_JOIN_R  = 1200,   -- "at the stage" = this close
    LAUNCH_AV     = 1500,   -- leave once this much value is at the stage (~7 Lashers/Pounders)
    FORCE_AV      = 4000,   -- ...whatever is still walking in
    BLIND_FRAME   = 12 * 60 * 30,   -- act on the mirror guess of the enemy start only after this long
    LEG           = 800,    -- advance this far at a time
    ARRIVE        = 150,    -- on the objective: stay and fight
    FIELD_OVERSHOOT = 250,  -- a wreck field: the Lashers stop this far PAST it (the rez bots work behind them)
    SPREAD_R      = 450,    -- a Lasher further than this from the core keeps only part of its offset
    CLUSTER_R     = 600,    -- a unit "has company" with 2 others this close...
    CORE_R        = 1200,   -- ...and the core is everyone this close to the most forward such unit
    SPENT_FRAC    = 0.25,   -- a group under this share of its peak value regroups
    SPENT_MIN_PEAK = 3000,
    STAND_OFF     = 2.0,    -- on the way to an objective, hold short of STATIC defences worth more than this x the group
    SCAN_R        = 1800,   -- enemies within this of the Lasher core are looked at
    -- the back-off: ONLY for something moving quickly toward the Lashers
    CHARGE_SPEED  = 55,     -- closing speed (elmos/s) along the line to the nearest Lasher that counts as "quickly"
    CHARGE_TTC    = 4,      -- ...and it can hit a Lasher within this many seconds (distance - its range) / closing
    CHARGE_MIN_FRAC = 0.1,  -- ...and the chargers are worth at least this share of the Lashers (one raider does not
                            --    send 40 Lashers running)
    BACK_STEP     = 400,    -- user: median back step ~400
    -- Pounders: a loose guard around the Lashers
    PAD           = 200,    -- elmos in front of the Lasher core, toward the enemy
    PAD_SPREAD    = 70,
    PAD_SPREAD_MAX = 450,
    DIVE_R        = 350,    -- an enemy this close to a Lasher is diving: the Pounders meet it
    INTERCEPT_MAX = 500,    -- ...but never go further than this from the Lashers to do it
    -- objective: wreck fields
    FIELD_SCAN_R  = 3500,   -- wrecks this close to the group are considered
    CELL          = 400,    -- wrecks are binned in cells of this size; a field is a 3x3 block of cells
    FIELD_MIN     = 300,    -- metal (+ rez bonus) a field needs to be worth a trip
    REZ_BONUS     = 0.3,    -- an armed unit that can be raised adds this share of its cost to the field
    DIST_SCALE    = 2500,   -- a field this far from the group is worth half
    BEHIND_MAX    = 600,    -- a field further than this BEHIND the group (toward home) is not considered
    FIELD_DEF_MAX = 1.5,    -- ground threat on the field above this x the group...
    FIELD_DEF_PEN = 0.25,   -- ...scores this share
    STICKY        = 1.3,    -- the current field scores this much more (no flip-flopping)
    OBJ_EVERY     = 150,
    BASE_R        = 1500,   -- structures this close together are one base
    -- crew: behind the Lashers
    RECLAIM_MIN   = 20,     -- metal in a wreck before the walk is worth it
    REZ_MIN_COST  = 80,
    WRECK_R       = 1300,   -- crew works wrecks this close to the Lasher core...
    AHEAD_MAX     = 100,    -- ...and no further than this IN FRONT of it (toward the enemy)
    SAFE_FRAC     = 0.5,    -- skip a wreck covered by more than this x the group's value of enemy guns
    SAFETY_CHECKS = 4,
    REPAIR_R      = 900,
    REPAIR_BELOW  = 0.9,
    SELF_RETREAT  = 0.4,
    -- REZ_BRAVE (2026-10-08, off by default; LINE_CLICK_v13): the user saw rez bots walk away from a unit under attack
    -- right next to them -- "they are useless if they are not doing their job; it is fine if they die".  With it on, a
    -- damaged unit in reach is repaired even with enemies near (a rez bot only walks back when it has no job or is
    -- itself nearly dead), ANY of our units counts (not only the slow group), and wrecks may be riskier.
    REZ_BRAVE     = false,
    BRAVE_RETREAT = 0.2,     -- REZ_BRAVE: own hp share below which a rez bot still steps back
    BOT_DANGER_R  = 450,    -- an enemy this close to a rez bot sends it back behind the line
    TRAIL         = 350,    -- the crew idles this far behind the Lasher core
    TRAIL_SPREAD  = 120,
    MARGIN        = 200,
    -- order de-dup
    REISSUE_EPS   = 100,    -- a new target this far from the last one is a new order
    REISSUE_GAP   = 30,     -- ...no sooner than this many frames after the last
    HEARTBEAT     = 450,
    LOG_EVERY     = 1800,
}
M.CFG = CFG

local CMD_MOVE, CMD_FIGHT, CMD_REPAIR, CMD_RECLAIM = 10, 16, 40, 90
local CMD_RESURRECT = (CMD and CMD.RESURRECT) or 125

local MM, UQ, EI, ARMY
local myAlly = 0

local units = {}      -- [uid] = "front" | "back"   (Pounders | Lashers)
local crew  = {}      -- [uid] = true               (rez bots)
local last  = {}      -- [uid] = { cmd, x, z, tid, f }  the last order we gave
local launched, peak = false, 0
local stageX, stageZ, stageFoeX, stageFoeZ, stageSrc
local obj                         -- { x, z, kind, score, since }
local wrecks, wrecksF = {}, -1e9  -- scan results
local busy = {}                   -- [featureID] = rez bot working it
local lastLog, pickF = -1e9, -1e9
local lastBackF, backHold = -1e9, 0
local lastKiteLog = -1e9
local stats = { advance = 0, kite = 0, stand = 0, rez = 0, reclaim = 0, repair = 0, dive = 0 }

local function Alive(uid) return Spring.GetUnitDefID(uid) ~= nil end
local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Log(frame, fmtStr, ...)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[SF] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
end
local function Value(defID)
    local d = defID and UnitDefs[defID]
    return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
end
local function Norm(x, z, fx, fz)
    local d = math.sqrt(x * x + z * z)
    if d < 1e-6 then return fx, fz end
    return x / d, z / d
end

function M.Init(o)
    MM, UQ, EI, ARMY = o.MM, o.UQ, o.EI, o.ARMY
    myAlly = o.allyID or (Spring.GetMyAllyTeamID and Spring.GetMyAllyTeamID()) or 0
    for k, v in pairs(o.cfg or {}) do CFG[k] = v end
    units, crew, last, busy, wrecks, obj = {}, {}, {}, {}, {}, nil
    launched, peak, wrecksF, lastLog, pickF = false, 0, -1e9, -1e9, -1e9
    lastBackF, backHold, lastKiteLog = -1e9, 0, -1e9
    stageX, stageZ, stageSrc = nil, nil, nil
    stats = { advance = 0, kite = 0, stand = 0, rez = 0, reclaim = 0, repair = 0, dive = 0 }
end

-- kind: "front" (Pounder), "back" (Lasher) or "rez"
function M.Add(uid, kind)
    if kind == "rez" then crew[uid] = true else units[uid] = kind end
end
function M.Remove(uid)
    units[uid], crew[uid], last[uid] = nil, nil, nil
    for fid, owner in pairs(busy) do if owner == uid then busy[fid] = nil end end
end
function M.Has(uid) return units[uid] ~= nil or crew[uid] ~= nil end
function M.Objective() return obj end
function M.Launched() return launched end
function M.Stats() return stats end
function M.Counts()
    local n, c = 0, 0
    for uid in pairs(units) do if Alive(uid) then n = n + 1 end end
    for uid in pairs(crew) do if Alive(uid) then c = c + 1 end end
    return n, c
end

-- One order, de-duplicated: the same command to (nearly) the same place is not repeated until the heartbeat.
local function Order(frame, uid, cmd, x, z, tid)
    local l = last[uid]
    if l and l.cmd == cmd and l.tid == tid then
        if frame - l.f < CFG.HEARTBEAT and (tid or Dist(x, z, l.x, l.z) <= CFG.REISSUE_EPS) then return false end
        if not tid and frame - l.f < CFG.REISSUE_GAP then return false end
    end
    if tid then
        Spring.GiveOrderToUnit(uid, cmd, { tid }, {})
    else
        Spring.GiveOrderToUnit(uid, cmd, { x, Spring.GetGroundHeight(x, z) or 0, z }, {})
    end
    last[uid] = { cmd = cmd, x = x, z = z, tid = tid, f = frame }
    return true
end

-- Stop where it stands and fire: a FIGHT order onto its own spot (kept while it stays near it).
local function Stand(frame, u)
    local l = last[u.uid]
    if l and l.cmd == CMD_FIGHT and not l.tid and Dist(u.x, u.z, l.x, l.z) <= CFG.REISSUE_EPS
       and frame - l.f < CFG.HEARTBEAT then
        return
    end
    Spring.GiveOrderToUnit(u.uid, CMD_FIGHT, { u.x, Spring.GetGroundHeight(u.x, u.z) or 0, u.z }, {})
    last[u.uid] = { cmd = CMD_FIGHT, x = u.x, z = u.z, f = frame }
end

-- ── Enemy knowledge ───────────────────────────────────────────────────────────

local function StaticNear(x, z, r)
    local v = 0
    for _, rec in pairs(EI.Records()) do
        local c = rec.c
        if c.armed and not c.scout and not c.mobile and Dist(rec.x, rec.z, x, z) <= r + (c.range or 0) then
            v = v + c.value
        end
    end
    return v
end

-- The armed enemies that can hit ground units within r of (x, z), each with its OWN position and range.
-- (Spring.GetUnitsInCylinder shows what the player can see; an unidentified blip has no def and is skipped.)
local function NearbyEnemies(x, z, r)
    local out = {}
    for _, uid in ipairs(UQ.enemies_near(x, z, r, myAlly)) do
        local defID = Spring.GetUnitDefID(uid)
        if defID and UQ.has_weapons(defID) and not UQ.is_air(defID) and UQ.can_hit_ground(defID)
           and not UQ.is_scout(defID) then
            local ex, _, ez = Spring.GetUnitPosition(uid)
            if ex then
                out[#out + 1] = { uid = uid, x = ex, z = ez, def = defID, range = UQ.max_weapon_range(defID),
                                  value = UQ.metal_cost(defID) or 0, mobile = UQ.is_mobile(defID) }
            end
        end
    end
    return out
end

-- ── Wrecks ────────────────────────────────────────────────────────────────────

-- Every wreck within FIELD_SCAN_R of (x, z): { fid, x, z, metal, rez = unit cost if worth raising else 0 }.
local function ScanWrecks(frame, x, z)
    wrecksF = frame
    wrecks = {}
    if not Spring.GetFeaturesInCylinder then return end
    for _, fid in ipairs(Spring.GetFeaturesInCylinder(x, z, CFG.FIELD_SCAN_R) or {}) do
        local fx, _, fz = Spring.GetFeaturePosition(fid)
        if fx then
            local metal = Spring.GetFeatureResources(fid) or 0
            local rez = 0
            local name = Spring.GetFeatureResurrect and Spring.GetFeatureResurrect(fid)
            local ud = name and name ~= "" and UnitDefNames and UnitDefNames[name]
            if ud and UQ.has_weapons(ud.id) and UQ.is_mobile(ud.id) and (ud.metalCost or 0) >= CFG.REZ_MIN_COST then
                rez = ud.metalCost
            end
            if metal >= CFG.RECLAIM_MIN or rez > 0 then
                wrecks[#wrecks + 1] = { fid = fid, x = fx, z = fz, metal = metal, rez = rez }
            end
        end
    end
end

-- The best 3x3-cell field.  Returns { x, z, raw, score } or nil.
local function PickField(frame, cx, cz, val)
    local bins = {}
    for _, w in ipairs(wrecks) do
        local kx, kz = math.floor(w.x / CFG.CELL), math.floor(w.z / CFG.CELL)
        local key = kx * 4096 + kz
        local b = bins[key]
        if not b then b = { kx = kx, kz = kz, s = 0, sx = 0, sz = 0 }; bins[key] = b end
        local s = w.metal + CFG.REZ_BONUS * w.rez
        b.s, b.sx, b.sz = b.s + s, b.sx + w.x * s, b.sz + w.z * s
    end
    local cand = {}
    for _, b in pairs(bins) do
        local s, sx, sz = 0, 0, 0
        for dx = -1, 1 do
            for dz = -1, 1 do
                local o = bins[(b.kx + dx) * 4096 + (b.kz + dz)]
                if o then s, sx, sz = s + o.s, sx + o.sx, sz + o.sz end
            end
        end
        if s >= CFG.FIELD_MIN then cand[#cand + 1] = { x = sx / s, z = sz / s, raw = s } end
    end
    local fwdG = MM.Forward(cx, cz)
    local ahead = {}
    for _, c in ipairs(cand) do
        if MM.Forward(c.x, c.z) >= fwdG - CFG.BEHIND_MAX then       -- never turn back for a field
            local score = c.raw / (1 + Dist(cx, cz, c.x, c.z) / CFG.DIST_SCALE)
            if obj and obj.kind == "field" and Dist(obj.x, obj.z, c.x, c.z) < CFG.CELL * 1.5 then
                score = score * CFG.STICKY
            end
            c.score = score
            ahead[#ahead + 1] = c
        end
    end
    cand = ahead
    table.sort(cand, function(a, b) return a.score > b.score end)
    local best
    for i = 1, math.min(#cand, 6) do
        local c = cand[i]
        local s = c.score
        if EI.ThreatAt(frame, c.x, c.z, "ground") > CFG.FIELD_DEF_MAX * val then s = s * CFG.FIELD_DEF_PEN end
        if not best or s > best.score then best = { x = c.x, z = c.z, raw = c.raw, score = s } end
    end
    return best
end

-- The densest cluster of standing enemy structures (their base), else the enemy start.
local function EnemyBase(frame)
    local pts = {}
    for _, t in ipairs(EI.RaidTargets(frame)) do
        if not t.mobile then pts[#pts + 1] = { t.x, t.z, math.max(1, t.value or 1) } end
    end
    local bestI, bestD = nil, -1
    for i, p in ipairs(pts) do
        local d = 0
        for _, q in ipairs(pts) do if Dist(p[1], p[2], q[1], q[2]) <= CFG.BASE_R then d = d + q[3] end end
        if d > bestD then bestI, bestD = i, d end
    end
    if bestI then
        local sx, sz, sv = 0, 0, 0
        for _, q in ipairs(pts) do
            if Dist(pts[bestI][1], pts[bestI][2], q[1], q[2]) <= CFG.BASE_R then
                sx, sz, sv = sx + q[1] * q[3], sz + q[2] * q[3], sv + q[3]
            end
        end
        return { x = sx / sv, z = sz / sv, raw = bestD }
    end
    local fx, fz = MM.Foe()
    return { x = fx, z = fz, raw = 0 }
end

local function PickObjective(frame, cx, cz, val)
    -- A wreck field on the way, else the enemy base.  (Enemies in sight are fought directly, see UpdateLashers; a
    -- "strongest cluster" objective jumped around every few seconds in the first real game.)
    local f = PickField(frame, cx, cz, val)
    local kind, o = "field", f
    if not o then o = EnemyBase(frame); kind = "base" end
    local x, z = MM.Clamp(o.x, o.z, CFG.MARGIN)
    if not obj or obj.kind ~= kind or Dist(obj.x, obj.z, x, z) > CFG.CELL then
        Log(frame, "objective: %s at (%d,%d), %dm from the group, worth %d", kind, x, z, Dist(cx, cz, x, z), o.raw or 0)
        obj = { kind = kind, since = frame }
    end
    obj.x, obj.z, obj.score = x, z, o.score or o.raw or 0
end

-- ── Group ─────────────────────────────────────────────────────────────────────

local function Members()
    local list = {}
    for uid, kind in pairs(units) do
        if Alive(uid) then
            local x, _, z = Spring.GetUnitPosition(uid)
            if x then
                local hp, mhp = Spring.GetUnitHealth(uid)
                local defID = Spring.GetUnitDefID(uid)
                list[#list + 1] = { uid = uid, kind = kind, x = x, z = z, v = Value(defID), def = defID,
                                    hp = (hp and mhp and mhp > 0) and hp / mhp or 1 }
            end
        else
            units[uid] = nil
        end
    end
    return list
end

local function Centroid(list)
    local sx, sz, sv = 0, 0, 0
    for _, u in ipairs(list) do sx, sz, sv = sx + u.x * u.v, sz + u.z * u.v, sv + u.v end
    if sv <= 0 then return nil end
    return sx / sv, sz / sv, sv
end

local GOLDEN = 2.399963
local function RingPos(i)
    local a, r = i * GOLDEN, CFG.STAGE_SPACING * math.sqrt(i)
    return MM.Clamp(stageX + math.cos(a) * r, stageZ + math.sin(a) * r, CFG.MARGIN)
end

-- Move every unit by (ux,uz)*step but keep its place in the formation: target = core + dir*step + its offset
-- from the core (a straggler is pulled to the core).
local function Translate(frame, list, cx, cz, ux, uz, step, cmd)
    local bx, bz = cx + ux * step, cz + uz * step
    for _, u in ipairs(list) do
        local ox, oz = u.x - cx, u.z - cz
        local od = math.sqrt(ox * ox + oz * oz)
        if od > CFG.SPREAD_R then ox, oz = ox / od * CFG.SPREAD_R * 0.5, oz / od * CFG.SPREAD_R * 0.5 end
        local x, z = MM.Clamp(bx + ox, bz + oz, CFG.MARGIN)
        Order(frame, u.uid, cmd, x, z)
    end
end

local function SpeedOf(list)
    local s = 1e9
    for _, u in ipairs(list) do
        local sp = UQ.max_speed(u.def) or 50
        if sp > 0 and sp < s then s = sp end
    end
    return s < 1e9 and s or 50
end

-- The velocity of an enemy in elmos/second (Spring reports elmos per frame).  Radar blips report 0.
local function VelocityOf(uid)
    if not Spring.GetUnitVelocity then return 0, 0 end
    local vx, _, vz = Spring.GetUnitVelocity(uid)
    return (vx or 0) * 30, (vz or 0) * 30
end

-- Enemies charging the Lashers: closing fast (>= CHARGE_SPEED along the line to the nearest Lasher) and able to hit
-- one within CHARGE_TTC seconds.  Returns the list and its total value.
local function Chargers(core, enemies)
    local out, value = {}, 0
    for _, e in ipairs(enemies) do
        if e.mobile then
            local best, bd
            for _, u in ipairs(core) do
                local d = Dist(u.x, u.z, e.x, e.z)
                if not bd or d < bd then best, bd = u, d end
            end
            if best and bd > 1 then
                local vx, vz = VelocityOf(e.uid)
                local closing = vx * (best.x - e.x) / bd + vz * (best.z - e.z) / bd
                if closing >= CFG.CHARGE_SPEED and (bd - e.range) <= closing * CFG.CHARGE_TTC then
                    out[#out + 1] = e
                    value = value + e.value
                    e.closing, e.dist = closing, bd
                end
            end
        end
    end
    return out, value
end

-- What the Lashers do this pass.  Returns the unit vector toward the enemy (for the Pounders and the crew), the
-- enemies in sight, the chargers and the state.
--   * DEFAULT: FIGHT toward the nearest enemy in sight, else toward the objective.  Always.  FIGHT is attack-move: a
--     unit stops when something is in its range, shoots, and walks on when it is dead.  Nothing is "held" or "stood".
--   * BACK OFF only when something is moving quickly toward them (a charge worth CHARGE_MIN_FRAC of the Lashers):
--     a MOVE away from it (a FIGHT would not walk back), then FIGHT forward again.  (user, 2026-10-07)
local function UpdateLashers(frame, lashers, cx, cz, val)
    local enemies = NearbyEnemies(cx, cz, CFG.SCAN_R + CFG.SPREAD_R)
    local dmin, dEnemy = 1e9, nil
    for _, e in ipairs(enemies) do
        for _, u in ipairs(lashers) do
            local d = Dist(u.x, u.z, e.x, e.z)
            if d < dmin then dmin, dEnemy = d, e end
        end
    end
    local ax, az = MM.Axis()
    local ux, uz = ax, az
    if dEnemy then ux, uz = Norm(dEnemy.x - cx, dEnemy.z - cz, ax, az) end

    local chargers, chargeValue = Chargers(lashers, enemies)
    local charging = #chargers > 0 and chargeValue >= CFG.CHARGE_MIN_FRAC * val
    local state = "advance"
    if charging then state = "back"
    elseif frame - lastBackF < backHold then state = "hold" end

    if state == "back" then
        -- away from the chargers' centre of mass
        local tx, tz, tw = 0, 0, 0
        for _, e in ipairs(chargers) do tx, tz, tw = tx + e.x * e.value, tz + e.z * e.value, tw + e.value end
        local bx, bz = Norm(cx - tx / tw, cz - tz / tw, -ax, -az)
        local step = CFG.BACK_STEP
        lastBackF = frame
        backHold = math.floor(step / SpeedOf(lashers) * 30 * 0.8)
        stats.kite = stats.kite + 1
        if frame - lastKiteLog >= 90 then
            lastKiteLog = frame
            local c = chargers[1]
            local ed = UnitDefs[c.def]
            Log(frame, "back off %dm: %d %s charging (closing %.0f/s, %dm away, value %d vs ours %d)",
                step, #chargers, ed and ed.name or "?", c.closing or 0, c.dist or 0, chargeValue, val)
        end
        Translate(frame, lashers, cx, cz, bx, bz, step, CMD_MOVE)
        ux, uz = -bx, -bz
    elseif state == "hold" then
        -- let the back step finish
    else
        local mx, mz, step
        if dEnemy then
            -- an enemy in sight: FIGHT toward it (up to its position; the units stop when it is in range)
            mx, mz = ux, uz
            step = math.min(CFG.LEG, math.max(dmin, CFG.ARRIVE))
        else
            if not obj or frame - pickF >= CFG.OBJ_EVERY then
                pickF = frame
                PickObjective(frame, cx, cz, val)
            end
            -- a wreck field: end up just PAST it, so the wrecks are behind the Lashers where the rez bots work
            local gx, gz = obj.x, obj.z
            if obj.kind == "field" then gx, gz = gx + ax * CFG.FIELD_OVERSHOOT, gz + az * CFG.FIELD_OVERSHOOT end
            local dx, dz = gx - cx, gz - cz
            local d = math.sqrt(dx * dx + dz * dz)
            step = (d > CFG.ARRIVE) and math.min(CFG.LEG, d - CFG.ARRIVE) or 0
            mx, mz = Norm(dx, dz, ax, az)                -- the way we MOVE; "front" (ux,uz) stays toward the enemy
            if step > 0 and StaticNear(cx + mx * step, cz + mz * step, 300) > CFG.STAND_OFF * val then step = 0 end
        end
        if step > 0 then
            Translate(frame, lashers, cx, cz, mx, mz, step, CMD_FIGHT)
            stats.advance = stats.advance + 1
        else
            for _, u in ipairs(lashers) do Stand(frame, u) end
            stats.stand = stats.stand + 1
        end
    end
    return ux, uz, enemies, chargers, state
end

-- Pounders: within PAD of the Lashers, on the enemy side.  They are there to SLOW anything that dives the Lashers:
-- an enemy within DIVE_R of a Lasher, or one charging them, is met by the Pounders (FIGHT toward it, no further than
-- INTERCEPT_MAX from the Lashers) while the Lashers back off.
local function UpdatePounders(frame, pounders, lashers, cx, cz, ux, uz, enemies, chargers)
    if #pounders == 0 then return end
    local px, pz = -uz, ux
    local threats = {}
    for _, e in ipairs(chargers or {}) do threats[#threats + 1] = e end
    for _, e in ipairs(enemies) do
        if e.mobile then
            for _, l in ipairs(lashers) do
                if Dist(l.x, l.z, e.x, e.z) <= CFG.DIVE_R then threats[#threats + 1] = e; break end
            end
        end
    end
    table.sort(pounders, function(a, b) return a.x * px + a.z * pz < b.x * px + b.z * pz end)
    local n = #pounders
    for i, u in ipairs(pounders) do
        local tx, tz
        local meet, bd
        for _, e in ipairs(threats) do
            local d = Dist(u.x, u.z, e.x, e.z)
            if not bd or d < bd then bd, meet = d, e end
        end
        if meet then
            -- meet it between the Lashers and the enemy, never far from the Lashers
            local dx, dz = meet.x - cx, meet.z - cz
            local d = math.sqrt(dx * dx + dz * dz)
            local k = (d > CFG.INTERCEPT_MAX and d > 1) and CFG.INTERCEPT_MAX / d or 1
            tx, tz = MM.Clamp(cx + dx * k, cz + dz * k, CFG.MARGIN)
            stats.dive = stats.dive + 1
            Order(frame, u.uid, CMD_FIGHT, tx, tz)
        else
            local off = math.max(-CFG.PAD_SPREAD_MAX, math.min(CFG.PAD_SPREAD_MAX, (i - 1 - (n - 1) / 2) * CFG.PAD_SPREAD))
            tx, tz = MM.Clamp(cx + ux * CFG.PAD + px * off, cz + uz * CFG.PAD + pz * off, CFG.MARGIN)
            local along = (tx - u.x) * ux + (tz - u.z) * uz
            if Dist(u.x, u.z, tx, tz) <= 90 then Stand(frame, u)
            elseif along < -80 then Order(frame, u.uid, CMD_MOVE, tx, tz)       -- behind it: MOVE (FIGHT would not walk back)
            else Order(frame, u.uid, CMD_FIGHT, tx, tz) end
        end
    end
end

-- The group's CORE is its forward cluster: the most advanced unit that has company (>= 2 others within CLUSTER_R),
-- and everyone within CORE_R of it.  A value-weighted centroid of ALL units is dragged back by the reinforcements
-- that have just left the factory (they trickle in), and the forward units were then sent home to meet it.
-- Returns core, far, cx, cz (the core's centroid).
local function ForwardCore(list)
    local best, bestF
    local need = math.min(2, #list - 1)
    for _, a in ipairs(list) do
        local n = 0
        for _, b in ipairs(list) do
            if a ~= b and Dist(a.x, a.z, b.x, b.z) <= CFG.CLUSTER_R then n = n + 1 end
        end
        if n >= need then
            local f = MM.Forward(a.x, a.z)
            if not bestF or f > bestF then best, bestF = a, f end
        end
    end
    local core, far = {}, {}
    if best then
        for _, u in ipairs(list) do
            if Dist(u.x, u.z, best.x, best.z) <= CFG.CORE_R then core[#core + 1] = u else far[#far + 1] = u end
        end
    else
        core = list
    end
    local cx, cz = Centroid(core)
    return core, far, cx, cz
end

local function UpdateGroup(frame, list)
    local gx, gz, total = Centroid(list)
    if not gx then launched, peak = false, 0; return nil end

    local foeKnown = MM.FoeSource() ~= "mirror" or frame >= CFG.BLIND_FRAME
    if not launched then
        local av = 0
        for _, u in ipairs(list) do
            if Dist(u.x, u.z, stageX, stageZ) <= CFG.STAGE_JOIN_R then av = av + u.v end
        end
        if foeKnown and (av >= CFG.LAUNCH_AV or av >= CFG.FORCE_AV) then
            launched, peak, obj = true, total, nil
            ScanWrecks(frame, gx, gz)             -- the first objective is picked on fresh information
            pickF = -1e9
            Log(frame, "slow group launches: %d units, value %d", #list, total)
        else
            table.sort(list, function(a, b) return a.uid < b.uid end)
            for i, u in ipairs(list) do
                local x, z = RingPos(i - 1)
                Order(frame, u.uid, CMD_MOVE, x, z)
            end
            return gx, gz, total, nil, nil, nil
        end
    end

    peak = math.max(peak, total)
    if peak >= CFG.SPENT_MIN_PEAK and total < CFG.SPENT_FRAC * peak then
        launched = false
        Log(frame, "slow group spent (%d of peak %d): regrouping at the stage", total, peak)
        return gx, gz, total, nil, nil, nil
    end

    local core, far, cx, cz = ForwardCore(list)
    local val = 0
    for _, u in ipairs(core) do val = val + u.v end
    local lashers, pounders = {}, {}
    for _, u in ipairs(core) do
        if u.kind == "front" then pounders[#pounders + 1] = u else lashers[#lashers + 1] = u end
    end
    -- the Lasher core is the reference; with no Lashers the Pounders act as the group
    if #lashers == 0 then lashers, pounders = pounders, {} end
    local lx, lz = Centroid(lashers)
    local ux, uz, enemies, chargers = UpdateLashers(frame, lashers, lx, lz, val)
    UpdatePounders(frame, pounders, lashers, lx, lz, ux, uz, enemies, chargers)
    -- reinforcements and stragglers: FIGHT to the core
    for _, u in ipairs(far) do Order(frame, u.uid, CMD_FIGHT, lx, lz) end
    return lx, lz, val, ux, uz, enemies
end

-- ── Rez crew: behind the Lashers ──────────────────────────────────────────────

local function DamagedFriend(uid, x, z)
    local best, bestScore = nil, 0
    if CFG.REZ_BRAVE then
        -- any of our units in reach (fast groups, guards, builders), not only the slow group
        local team = Spring.GetMyTeamID and Spring.GetMyTeamID()
        for _, fid in ipairs(Spring.GetUnitsInCylinder(x, z, CFG.REPAIR_R, team) or {}) do
            if fid ~= uid and not Spring.GetUnitIsBeingBuilt(fid) then
                local hp, mhp = Spring.GetUnitHealth(fid)
                if hp and mhp and mhp > 0 and hp / mhp < CFG.REPAIR_BELOW then
                    local missing = (1 - hp / mhp) * Value(Spring.GetUnitDefID(fid))
                    if missing > bestScore then best, bestScore = fid, missing end
                end
            end
        end
        return best
    end
    for fid in pairs(units) do
        local fx, _, fz = Spring.GetUnitPosition(fid)
        if fx and Dist(fx, fz, x, z) <= CFG.REPAIR_R then
            local hp, mhp = Spring.GetUnitHealth(fid)
            if hp and mhp and mhp > 0 and hp / mhp < CFG.REPAIR_BELOW then
                local missing = (1 - hp / mhp) * Value(Spring.GetUnitDefID(fid))
                if missing > bestScore then best, bestScore = fid, missing end
            end
        end
    end
    return best
end

-- Best wreck for this bot among those NOT AHEAD of the Lashers: raising an armed unit beats reclaiming.
local function BestWreck(frame, uid, x, z, cx, cz, ux, uz, val)
    local cand = {}
    for _, w in ipairs(wrecks) do
        if (not busy[w.fid] or busy[w.fid] == uid)
           and (not Spring.ValidFeatureID or Spring.ValidFeatureID(w.fid))
           and Dist(w.x, w.z, cx, cz) <= CFG.WRECK_R
           and (w.x - cx) * ux + (w.z - cz) * uz <= CFG.AHEAD_MAX then
            local worth = (w.rez > 0) and w.rez or 0.8 * w.metal
            cand[#cand + 1] = { w = w, s = worth / (1 + Dist(x, z, w.x, w.z) / 500) }
        end
    end
    table.sort(cand, function(a, b) return a.s > b.s end)
    for i = 1, math.min(#cand, CFG.SAFETY_CHECKS) do
        local w = cand[i].w
        if EI.ThreatAt(frame, w.x, w.z, "ground") <= CFG.SAFE_FRAC * val then
            return w, (w.rez > 0) and CMD_RESURRECT or CMD_RECLAIM
        end
    end
    return nil
end

local function UpdateCrew(frame, cx, cz, val, ux, uz, enemies)
    for fid, owner in pairs(busy) do
        if not crew[owner] or not Alive(owner) then busy[fid] = nil end
    end
    local ids = {}
    for uid in pairs(crew) do
        if Alive(uid) then ids[#ids + 1] = uid else crew[uid] = nil; last[uid] = nil end
    end
    table.sort(ids)
    if #ids == 0 then return end
    local ax, az = MM.Axis()
    if not ux then ux, uz = ax, az end
    local px, pz = -uz, ux
    local gx, gz = cx or stageX, cz or stageZ
    local tx, tz = gx - ux * CFG.TRAIL, gz - uz * CFG.TRAIL
    local maxUnits = Game and Game.maxUnits or 32000
    for i, uid in ipairs(ids) do
        for fid, owner in pairs(busy) do if owner == uid then busy[fid] = nil end end
        local x, _, z = Spring.GetUnitPosition(uid)
        local hp, mhp = Spring.GetUnitHealth(uid)
        if x and hp and mhp and mhp > 0 then
            local k = (i - 1) - (#ids - 1) / 2
            local wx, wz = MM.Clamp(tx + px * k * CFG.TRAIL_SPREAD, tz + pz * k * CFG.TRAIL_SPREAD, CFG.MARGIN)
            local danger = false
            for _, e in ipairs(enemies or {}) do
                if Dist(x, z, e.x, e.z) <= math.max(CFG.BOT_DANGER_R, e.range + 100) then danger = true; break end
            end
            local friend = CFG.REZ_BRAVE and hp / mhp >= CFG.BRAVE_RETREAT and DamagedFriend(uid, x, z) or nil
            if not friend and (hp / mhp < (CFG.REZ_BRAVE and CFG.BRAVE_RETREAT or CFG.SELF_RETREAT)
                               or (danger and not CFG.REZ_BRAVE)) then
                Order(frame, uid, CMD_MOVE, wx, wz)
            else
                friend = friend or DamagedFriend(uid, x, z)
                if friend then
                    if Order(frame, uid, CMD_REPAIR, nil, nil, friend) then stats.repair = stats.repair + 1 end
                else
                    local w, cmd
                    if launched and cx then w, cmd = BestWreck(frame, uid, x, z, cx, cz, ux, uz, val or 0) end
                    if w then
                        busy[w.fid] = uid
                        if Order(frame, uid, cmd, nil, nil, w.fid + maxUnits) then
                            if cmd == CMD_RESURRECT then stats.rez = stats.rez + 1 else stats.reclaim = stats.reclaim + 1 end
                        end
                    else
                        Order(frame, uid, CMD_MOVE, wx, wz)
                    end
                end
            end
        end
    end
end

-- ── Entry point ───────────────────────────────────────────────────────────────

function M.Update(frame)
    if not (MM and ARMY and EI and MM.Ready()) then return end
    local fx, fz = MM.Foe()
    local src = MM.FoeSource()
    if not stageX or Dist(fx, fz, stageFoeX or 0, stageFoeZ or 0) > 300 or src ~= stageSrc then
        stageFoeX, stageFoeZ, stageSrc = fx, fz, src
        stageX, stageZ = MM.PointAt(CFG.STAGE_FRAC * MM.Dist(), 0)
        stageX, stageZ = MM.Clamp(stageX, stageZ, CFG.MARGIN)
    end

    local list = Members()
    local cx, cz, val, ux, uz, enemies
    if #list > 0 then
        if frame - wrecksF >= CFG.OBJ_EVERY then
            local sx, sz = Centroid(list)
            ScanWrecks(frame, sx or stageX, sz or stageZ)
        end
        cx, cz, val, ux, uz, enemies = UpdateGroup(frame, list)
    else
        launched, peak = false, 0
        if frame - wrecksF >= CFG.OBJ_EVERY then ScanWrecks(frame, stageX, stageZ) end
    end
    UpdateCrew(frame, cx, cz, val, ux, uz, enemies)

    if frame - lastLog >= CFG.LOG_EVERY and (#list > 0 or next(crew)) then
        lastLog = frame
        local n, c = M.Counts()
        Log(frame, "slow group: %d units, %d rez bots, %s, objective %s | passes advance=%d backoff=%d stand=%d meet=%d | crew rez=%d reclaim=%d repair=%d | %d wrecks seen",
            n, c, launched and "out" or "staging", obj and string.format("%s (%d,%d)", obj.kind, obj.x, obj.z) or "-",
            stats.advance, stats.kite, stats.stand, stats.dive, stats.rez, stats.reclaim, stats.repair, #wrecks)
    end
end

return M
