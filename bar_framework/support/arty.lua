-- bar_framework/support/arty.lua  (army_groups element: a slow, heavy-hitting support unit that its raid group screens; also the base of support/stop.lua)
-- User 2026-11-01: "A half group is 5 quakers cormart.  5 is an important number since each does 420 alpha damage and a brute has 2k hp so it is a
-- one shot break point.  Quakers ... can only shoot in the 180 directly in front of them.  For the quaker control one of the most important parts is
-- that they are always firing.  The idea is that they are just always fighting commands towards the enemy and the normal units cover them ... The
-- goal of a group with arty support is not to raid but to always keep the quakers alive and shooting."  Not a stance: a one-time capability added
-- on top of whatever the stance builds, once income reaches `from_income` (latched: it stays on).
--   * the labs make n per group for `groups` raid groups (unit_runtime raises click_army MAX_GROUPS to `groups` while this is on); the unit's
--     lab (the T2 vehicle plant) is planned by the slot spine for the request (lab_orders.Wanted -> slot_spine.SetRequired);
--   * far from its post (the group's core minus BEHIND along its axis) and not at home, a unit is flown there (air_lift.lua; a Tzar needs a heavy
--     transport, the lift picks one that can carry it); its lift is re-asked every tick, so a transport in the air re-routes to where the group is now;
--   * the landed units stand in a line abreast across the group's axis and FIGHT a STEP ahead toward the group's target: they set the group's pace
--     (always moving: the screen chases them, click_army ESCORT), and take a short HOLD_STEP once the target is inside RANGE_FRAC of their range;
--   * one decision for the whole group: while click_army escorts them its posture (rec.posture "back": the threat at the Quakers is more than the screen
--     can hold) steps them back BACK elmos at a time, with the screen and the AA (user 2026-11-02: "they all need to be on the same page ... take steps
--     back to avoid fights instead of completely disengaging"); before the screen has formed, their own check (threat > DANGER_MULT x the group);
--   * TARGET = "density" (the Tzar, support/stop.lua): SET_TARGET on the enemy at the centre of the densest clump in range (DENSITY_R round it), the
--     closest of equal clumps, only where it hits more enemies than friends (FF_W per friend).
-- Publishes rec.arty = { cx, cz, vx, vz, n (landed), lift (waiting / in the air), total, range, home, danger } for click_army (army_groups -> CA.SetSupport).
-- cfg: n, groups, from_income, hold_s, UNIT (role), TARGET, DENSITY_R, FF_W, BEHIND, SPACING, STEP, HOLD_STEP, LIFT_DIST, HOME_R, DANGER_MULT, BACK, RANGE_FRAC.
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "arty", LABEL = "Quakers" }
-- STEP > army_broker's ORDER_MOVE_EPS (250): the FIGHT point is re-sent as the line moves (game 2026-11-01: a 220 step walked, stopped and waited for
-- the 10 s heartbeat -- the escorts crept ~1 km a minute).  LIFT_DIST 1800: the group moves on to its target and the units hop after it by air.
M.CFG = { N = 5, groups = 3, from_income = 300, hold_s = 20, UNIT = "arty_t2_veh", TARGET = nil, DENSITY_R = 250, FF_W = 1.5,
          BEHIND = 800, SPACING = 90, STEP = 600, LIFT_DIST = 1800, HOME_R = 1500,
          DANGER_MULT = 1.0, BACK = 300, RANGE_FRAC = 0.85, HOLD_STEP = 150, LIFT_PRIO = 10, HOME_RESPOND_R = 1400, HOME_LEASH = 700,
          HP_W = 2.0, STICK = 1.5 }

local CMD_SET_TARGET, CMD_CANCEL_TARGET = 34923, 34924
local ENEMY_UNITS = (type(Spring.ENEMY_UNITS) == "number") and Spring.ENEMY_UNITS or -4
local latch = { on = false, since = nil }
local targetOf = {}      -- [uid] = enemy uid set as its target (TARGET = "density")

local function UnitName(cfg) return ROLES.Get((cfg and cfg.UNIT) or M.CFG.UNIT) end

-- on once metal income has stayed >= from_income for hold_s (then for good)
function M.Gate(c, ctx)
    if latch.on then return true end
    local f = Spring.GetGameFrame()
    local _, _, _, inc = Spring.GetTeamResources(Spring.GetMyTeamID(), "metal")
    if (inc or 0) >= (c.from_income or M.CFG.from_income) then
        latch.since = latch.since or f
        if f - latch.since >= 30 * (c.hold_s or M.CFG.hold_s) then
            latch.on = true
            local mb = ctx.WG and ctx.WG.MetalBot
            if mb then mb[M.name .. "On"] = true end      -- mb.artyOn / mb.stopOn (support/aa.lua sizes, air_lift's standing transports)
            Spring.Echo(string.format("[SUP] %s %s ON: income %.0f >= %.0f for %d s (%d %s x %d groups)", ctx.Clock(f), M.name, inc,
                c.from_income or M.CFG.from_income, c.hold_s or M.CFG.hold_s, c.n or M.CFG.N, UnitName(c), c.groups or M.CFG.groups))
        end
    else
        latch.since = nil
    end
    return latch.on
end

function M.On() return latch.on end

function M.Picks(cfg) return { UnitName(cfg) } end

function M.Accept(defID, born, cfg)
    local d = UnitDefs[defID]
    return d ~= nil and d.name == UnitName(cfg)
end

local function Range(defID, ctx)
    local r = ctx.UQ and ctx.UQ.max_weapon_range and ctx.UQ.max_weapon_range(defID)
    return (r and r > 0) and r or 1000
end

-- near our eco buildings (map_model BaseDist: the nearest eco footprint cell; game 5, 2026-11-01: the distance to MM.Base(), the footprint's centre,
-- called a spot 1.1 km from the spawn "away")
local function Home(ctx, x, z, r)
    local MM = ctx.MM
    if not (MM and MM.Ready and MM.Ready()) then return true end
    if MM.BaseDist then return MM.BaseDist(x, z) <= r end
    local bx, bz = MM.Base()
    return (x - bx) ^ 2 + (z - bz) ^ 2 <= r * r
end

-- TARGET = "density" (user 2026-11-02, the Tzar's 292 aoe): the enemy ground unit in range with the most enemies within DENSITY_R of it, less FF_W per
-- friendly unit there ("fine to hit friendly units but it should be hitting more enemies"), the closer of two equal clumps first.
local myAlly
-- user 2026-11-02: "have a bias for low unit hp.  They are swapping where they are shooting a lot so they are not killing things; if they shoot the same
-- group they can kill it outright": + HP_W x (1 - hp fraction); the current target (`keep`) is kept unless another scores STICK x better (+1); the
-- line's units share one target (AimDensity: the first unit's pick, for every unit it is in range of).
local function Score(eid, x, z, range, dr, ffw, hpw)
    local ex, _, ez = Spring.GetUnitPosition(eid)
    if not ex then return nil end
    local nE, nF = 0, 0
    for _, o in ipairs(Spring.GetUnitsInCylinder(ex, ez, dr) or {}) do
        local od = Spring.GetUnitDefID(o)
        if od and not UnitDefs[od].canFly then
            if Spring.GetUnitAllyTeam(o) == myAlly then nF = nF + 1 else nE = nE + 1 end
        end
    end
    if nE <= nF then return nil end
    local hp, maxHp = Spring.GetUnitHealth(eid)
    local hpFrac = (hp and maxHp and maxHp > 0) and hp / maxHp or 1
    local dist = math.sqrt((ex - x) ^ 2 + (ez - z) ^ 2)
    return nE - ffw * nF - 0.5 * dist / range + hpw * (1 - hpFrac)
end

local function DensityTarget(uid, range, cfg, keep)
    myAlly = myAlly or Spring.GetMyAllyTeamID()
    local x, _, z = Spring.GetUnitPosition(uid)
    if not x then return nil end
    local dr = cfg.DENSITY_R or M.CFG.DENSITY_R
    local ffw = cfg.FF_W or M.CFG.FF_W
    local hpw = cfg.HP_W or M.CFG.HP_W
    local best, bestS
    for _, eid in ipairs(Spring.GetUnitsInCylinder(x, z, range, ENEMY_UNITS) or {}) do
        local ed = Spring.GetUnitDefID(eid)
        local d = ed and UnitDefs[ed]
        if d and not d.canFly then
            local s = Score(eid, x, z, range, dr, ffw, hpw)
            if s and (not bestS or s > bestS) then best, bestS = eid, s end
        end
    end
    -- sticky: the current target stays while it is in range and still a clump, unless the best is clearly better
    if keep and keep ~= best and Spring.GetUnitDefID(keep) then
        local kx, _, kz = Spring.GetUnitPosition(keep)
        if kx and (kx - x) ^ 2 + (kz - z) ^ 2 <= range * range then
            local ks = Score(keep, x, z, range, dr, ffw, hpw)
            if ks and not (bestS and bestS > (cfg.STICK or M.CFG.STICK) * ks + 1) then return keep end
        end
    end
    return best
end

-- t: a target the line already picked this tick (focus fire); used when in range of this unit
local function AimDensity(uid, range, cfg, t)
    if t then
        local x, _, z = Spring.GetUnitPosition(uid)
        local tx, _, tz = Spring.GetUnitPosition(t)
        if not (x and tx and (tx - x) ^ 2 + (tz - z) ^ 2 <= range * range) then t = nil end
    end
    t = t or DensityTarget(uid, range, cfg, targetOf[uid])
    if t then
        if targetOf[uid] ~= t then
            Spring.GiveOrderToUnit(uid, CMD_SET_TARGET, { t }, {})
            targetOf[uid] = t
        end
    elseif targetOf[uid] then
        Spring.GiveOrderToUnit(uid, CMD_CANCEL_TARGET, {}, {})
        targetOf[uid] = nil
    end
    return t
end

-- area_defence's wall (defence/wall.lua) keeps its Tzars on the same density target
M.AimDensity, M.Range = AimDensity, Range

function M.Update(rec, units, cfg, frame, ctx)
    local LIFT = ctx.LIFT
    local key = M.name .. " g" .. rec.id
    if rec.id == 0 then                                   -- the pool waits on the stage (a group out takes it at once: army_groups' hand-out)
        for i, uid in ipairs(units) do
            local x, z = ctx.Spot(rec, 0, i, 80)
            if LIFT and LIFT.Busy(uid) then LIFT.Request(uid, x, z, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, M.name .. " pool")   -- in the air: home
            else ctx.Claim(uid, "SUP_ARTY", ctx.CMD_MOVE, x, z, frame) end
        end
        return
    end
    -- a HOME record (support/t1stop.lua's defending groups; user 2026-11-02: "had tzars prio going to a group that is defending"): hold the sector on a
    -- line, FIGHT a raid that comes within HOME_RESPOND_R (never farther than HOME_LEASH from the sector), keep the density target; no lift, no march
    if rec.kind == "home" then
        local mb = ctx.WG and ctx.WG.MetalBot
        local rd = mb and mb.raid
        local t
        if rd and rd.groups and frame - (rd.frame or -1e9) <= 300 then
            local r2, bd = (cfg.HOME_RESPOND_R or M.CFG.HOME_RESPOND_R) ^ 2, nil
            for _, g in ipairs(rd.groups) do
                local d = (g.x - rec.cx) ^ 2 + (g.z - rec.cz) ^ 2
                if d <= r2 and (not bd or d < bd) then t, bd = g, d end
            end
        end
        local hdx, hdz = rec.dx or 0, rec.dz or 0
        local px, pz = -hdz, hdx
        local n, sp = #units, cfg.SPACING or M.CFG.SPACING
        local leash = cfg.HOME_LEASH or M.CFG.HOME_LEASH
        local density = (cfg.TARGET or M.CFG.TARGET) == "density"
        local focus
        for i, uid in ipairs(units) do
            local off = (i - (n + 1) / 2) * sp
            local x, z = rec.cx + px * off, rec.cz + pz * off
            if t then
                local d = math.sqrt((t.x - rec.cx) ^ 2 + (t.z - rec.cz) ^ 2)
                x, z = t.x, t.z
                if d > leash then x, z = rec.cx + (t.x - rec.cx) / d * leash, rec.cz + (t.z - rec.cz) / d * leash end
                x, z = x + px * off, z + pz * off
            end
            if ctx.MM and ctx.MM.Clamp then x, z = ctx.MM.Clamp(x, z, 150) end
            if LIFT and LIFT.Busy(uid) then LIFT.Request(uid, x, z, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, key)
            else
                if LIFT and LIFT.Waiting(uid) then LIFT.Cancel(uid) end
                ctx.Claim(uid, "SUP_ARTY", ctx.CMD_FIGHT, x, z, frame)
                if density then focus = AimDensity(uid, Range(Spring.GetUnitDefID(uid), ctx), cfg, focus) end
            end
        end
        return
    end
    local dx, dz = rec.dx or 0, rec.dz or 0
    local behind = cfg.BEHIND or M.CFG.BEHIND
    local postX, postZ = rec.cx - dx * behind, rec.cz - dz * behind
    if ctx.MM and ctx.MM.Clamp then postX, postZ = ctx.MM.Clamp(postX, postZ, 200) end
    local atHome = Home(ctx, rec.cx, rec.cz, cfg.HOME_R or M.CFG.HOME_R)
    local liftD = cfg.LIFT_DIST or M.CFG.LIFT_DIST
    local landed, lifting = {}, 0
    local sx, sz, range = 0, 0, nil
    for _, uid in ipairs(units) do
        local x, _, z = Spring.GetUnitPosition(uid)
        if LIFT and LIFT.Busy(uid) then
            lifting = lifting + 1
            -- user 2026-11-02 (~13:00: Quakers set down outside the enemy base while their group pulled back): the transport re-routes to the post now
            LIFT.Request(uid, postX, postZ, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, key)
        elseif x then
            local far = (x - postX) ^ 2 + (z - postZ) ^ 2 > liftD * liftD
            if far and LIFT and not atHome then
                LIFT.Request(uid, postX, postZ, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, key)
                lifting = lifting + 1
                ctx.Claim(uid, "SUP_ARTY", ctx.CMD_MOVE, postX, postZ, frame)     -- walk toward it until a transport comes
            else
                if LIFT and LIFT.Waiting(uid) then LIFT.Cancel(uid) end
                landed[#landed + 1] = uid
                sx, sz = sx + x, sz + z
                range = range or Range(Spring.GetUnitDefID(uid), ctx)
            end
        end
    end
    local n = #landed
    if n == 0 then
        rec.arty = { n = 0, lift = lifting, total = #units }
        return
    end
    local cx, cz = sx / n, sz / n
    range = range or 1000
    -- user 2026-11-01: "make sure that when possible quakers are fight commanded towards the enemy and only pull back if the screen can't protect
    -- them".  The units are the slowest part, so they set the pace: they always FIGHT a STEP ahead (never wait for the screen -- the screen is
    -- faster and keeps up by chasing their moving position, click_army ESCORT); with the target inside RANGE_FRAC of their range the step is short
    -- (HOLD_STEP: still a FIGHT toward it, they keep firing).  Pulling back is the GROUP's decision while it escorts them (rec.posture, click_army:
    -- the threat at the line against the screen, with hysteresis), so the screen, these units and the AA step back together.
    local step = cfg.STEP or M.CFG.STEP
    local tgt = rec.target
    if tgt and tgt.x and (tgt.x - cx) ^ 2 + (tgt.z - cz) ^ 2 <= (range * (cfg.RANGE_FRAC or M.CFG.RANGE_FRAC)) ^ 2 then step = cfg.HOLD_STEP or M.CFG.HOLD_STEP end
    local danger = false
    if rec.posture then
        danger = rec.posture == "back"
    elseif ctx.EI and ctx.EI.ThreatAt then
        danger = ctx.EI.ThreatAt(frame, cx, cz, "ground") > (cfg.DANGER_MULT or M.CFG.DANGER_MULT) * math.max(1, rec.value or 0)
    end
    -- the line's velocity (elmos/s, per tick): the screen leads the units by it (click_army ESCORT)
    local vx, vz = 0, 0
    local pv = rec.artyPrev
    if pv and frame > pv.f then
        local dt = (frame - pv.f) / 30
        vx, vz = (cx - pv.cx) / dt, (cz - pv.cz) / dt
        local v = math.sqrt(vx * vx + vz * vz)
        local vmax = 90
        if v > vmax then vx, vz = vx / v * vmax, vz / v * vmax end
    end
    rec.artyPrev = { cx = cx, cz = cz, f = frame }
    local px, pz = -dz, dx                                 -- across the axis
    local sp = cfg.SPACING or M.CFG.SPACING
    local density = (cfg.TARGET or M.CFG.TARGET) == "density"
    local focus
    for i, uid in ipairs(landed) do
        local off = (i - (n + 1) / 2) * sp
        local x, z = cx + px * off, cz + pz * off
        local cmd = ctx.CMD_FIGHT
        if danger then
            x, z = x - dx * (cfg.BACK or M.CFG.BACK), z - dz * (cfg.BACK or M.CFG.BACK)
            cmd = ctx.CMD_MOVE
        else
            x, z = x + dx * step, z + dz * step
        end
        if ctx.MM and ctx.MM.Clamp then x, z = ctx.MM.Clamp(x, z, 150) end
        ctx.Claim(uid, "SUP_ARTY", cmd, x, z, frame)
        if density then focus = AimDensity(uid, range, cfg, focus) end
    end
    for uid in pairs(targetOf) do if not Spring.GetUnitDefID(uid) then targetOf[uid] = nil end end
    -- home: the units stand near our base (a group that just launched from the stage): click_army does not escort them there -- the group
    -- raids out and the units are flown to it once it is LIFT_DIST away (game 2026-11-01: escorts crept across the map at Quaker pace from home)
    rec.arty = { cx = cx, cz = cz, n = n, lift = lifting, total = #units, range = range, danger = danger, vx = vx, vz = vz,
                 home = Home(ctx, cx, cz, cfg.HOME_R or M.CFG.HOME_R) }
end

return M
