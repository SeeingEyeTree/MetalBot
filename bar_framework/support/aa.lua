-- bar_framework/support/aa.lua  (army_groups element: ground AA that walks with a group)
-- User 2026-10-30: "You want corsent (T2) or cormist (T1) as ground aa to support army groups ... when there are like 6 for a group it has
-- enough aa support and more do not need to be made."  The labs build the first pick any lab can make (flak truck once a T2 vehicle plant
-- stands, else the Lasher).
-- User 2026-10-31 (CORE_v4, vs DEFENCE_BOT's air): when_air = true -> the element is only on while WG.MetalBot.raidAir.active (enemy air-to-ground units
-- near a raid group, click_army AIR_PRESSURE), with n = n_t2 once a T2 vehicle plant stands (flak trucks: a full group is 6) else n_t1 (Lashers: 12);
-- min_frac = the next raid group does not leave before the pool holds that share of n (army_groups PoolShort, unit_runtime's click_army launchGate).
-- User 2026-11-01 ("Whistlers should always move commands not fight and they should set targets on air units first"), cfg MOVE = true (CORE_v4;
-- off = the first attempt above: FIGHT on a spiral BEHIND the group's centre, so the older bots' orders stay as they were):
--   * MOVE only, to a post: between the Quakers and the screen in a group with arty (arty centre + IN_ARTY along the axis), else BEHIND behind the core;
--   * every tick each unit gets SET_TARGET on the nearest enemy air unit inside TARGET_FRAC x its range (cancelled when none is near);
--   * far from its post and not at home: flown there (air_lift.lua), like the Quakers;
--   * n_arty / n_arty_air: while the arty element is on (WG.MetalBot.artyOn) and a T2 vehicle plant stands, every raid group gets n_arty flak trucks,
--     n_arty_air while raidAir is active -- whatever when_air says.  The picks are then flak trucks only (a Lasher in the pool goes back to the escort).
-- cfg: n, BEHIND, SPREAD, PICKS (role names, best first), MOVE, IN_ARTY, TARGET_FRAC, LIFT_DIST, HOME_R, n_arty, n_arty_air, when_air, n_t1, n_t2.
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "aa", ADOPT_OWNS = true, REJECT_POOL = true }
M.CFG = { N = 6, BEHIND = 300, SPREAD = 60, MOVE = false, PICKS = { "aa_flak_truck", "aa_t1_veh" }, IN_ARTY = 100, TARGET_FRAC = 1.1, LIFT_DIST = 2500,
          HOME_R = 1500, LIFT_PRIO = 8, LEAD_S = 3 }

local CMD_SET_TARGET, CMD_CANCEL_TARGET = 34923, 34924
local ENEMY_UNITS = (type(Spring.ENEMY_UNITS) == "number") and Spring.ENEMY_UNITS or -4     -- the area-query selector (eco_sim stubs it)
local targetOf = {}      -- [uid] = enemy uid it was told to target

local t2Plant = { f = -1e9, v = false }
local function T2Plant()
    local f = Spring.GetGameFrame()
    if f - t2Plant.f >= 90 then
        t2Plant.f, t2Plant.v = f, false
        local ud = UnitDefNames and UnitDefNames[ROLES.Get("lab_t2_veh")]
        if ud and Spring.GetTeamUnitsByDefs then
            for _, uid in ipairs(Spring.GetTeamUnitsByDefs(Spring.GetMyTeamID(), { ud.id }) or {}) do
                if not Spring.GetUnitIsBeingBuilt(uid) then t2Plant.v = true; break end
            end
        end
    end
    return t2Plant.v
end

function M.Gate(c, ctx)
    local mb = ctx.WG and ctx.WG.MetalBot
    local ra = mb and mb.raidAir
    local air = ra ~= nil and ra.active
    if c.n_arty and mb and (mb.artyOn or mb.stopOn) and T2Plant() then
        c.n = (air and c.n_arty_air) or c.n_arty
        c.PICKS = { "aa_flak_truck" }
        return true
    end
    if not c.when_air then return true end
    if not air then return false end
    c.n = (T2Plant() and c.n_t2) or c.n_t1 or c.n
    return true
end

local function Names(cfg)
    local out = {}
    for _, role in ipairs(cfg.PICKS or M.CFG.PICKS) do out[#out + 1] = ROLES.Get(role) end
    return out
end

function M.Picks(cfg) return Names(cfg) end

function M.Accept(defID, born, cfg)
    local d = UnitDefs[defID]
    if not d then return false end
    for _, n in ipairs(Names(cfg)) do if d.name == n then return true end end
    return false
end

-- GROUND_AA escorts (the old shared AA, unit_runtime) this element may take while short: unit_runtime's callback hands them over
function M.Adopt(ctx, cfg, need)
    if not ctx.TakeEscortAA then return nil end
    return ctx.TakeEscortAA(need, function(defID) return M.Accept(defID, nil, cfg) end)
end

local function AimAir(uid, defID, ctx)
    local x, _, z = Spring.GetUnitPosition(uid)
    if not x then return end
    local r = (ctx.UQ and ctx.UQ.max_weapon_range and ctx.UQ.max_weapon_range(defID)) or 700
    r = r * M.CFG.TARGET_FRAC
    local best, bd
    for _, eid in ipairs(Spring.GetUnitsInCylinder(x, z, r, ENEMY_UNITS) or {}) do
        local ed = Spring.GetUnitDefID(eid)
        local d = ed and UnitDefs[ed]
        if d and d.canFly then
            local ex, _, ez = Spring.GetUnitPosition(eid)
            local dd = ex and (ex - x) ^ 2 + (ez - z) ^ 2
            if dd and (not bd or dd < bd) then best, bd = eid, dd end
        end
    end
    if best then
        if targetOf[uid] ~= best then
            Spring.GiveOrderToUnit(uid, CMD_SET_TARGET, { best }, {})
            targetOf[uid] = best
        end
    elseif targetOf[uid] then
        Spring.GiveOrderToUnit(uid, CMD_CANCEL_TARGET, {}, {})
        targetOf[uid] = nil
    end
end

function M.Update(rec, units, cfg, frame, ctx)
    if not cfg.MOVE then
        local back = rec.id == 0 and 0 or -(cfg.BEHIND or 300)      -- the pool waits on the stage point
        for i, uid in ipairs(units) do
            local x, z = ctx.Spot(rec, back, i, cfg.SPREAD)
            ctx.Claim(uid, "SUP_AA", ctx.CMD_FIGHT, x, z, frame)
        end
        return
    end
    local LIFT = ctx.LIFT
    local bx, bz
    if rec.id == 0 then
        bx, bz = rec.cx, rec.cz                                   -- the pool waits on the stage point
    elseif rec.arty and (rec.arty.n or 0) > 0 then
        local a = cfg.IN_ARTY or M.CFG.IN_ARTY
        bx, bz = rec.arty.cx + (rec.dx or 0) * a, rec.arty.cz + (rec.dz or 0) * a
    else
        local b = cfg.BEHIND or M.CFG.BEHIND
        bx, bz = rec.cx - (rec.dx or 0) * b, rec.cz - (rec.dz or 0) * b
    end
    -- the post moves with what the AA follows (the core, or the Quakers): it leads by that velocity x LEAD_S, so the AA keeps moving instead of
    -- stopping on a post the core has already left (user 2026-11-01: groups crept, the AA waited on the core and the core on the AA)
    if rec.id ~= 0 then
        local vx, vz = rec.vx or 0, rec.vz or 0
        if rec.arty and (rec.arty.n or 0) > 0 then vx, vz = rec.arty.vx or 0, rec.arty.vz or 0 end
        local lead = cfg.LEAD_S or M.CFG.LEAD_S
        bx, bz = bx + vx * lead, bz + vz * lead
    end
    local home = true
    if rec.id ~= 0 and ctx.MM and ctx.MM.Ready and ctx.MM.Ready() then
        local hr = cfg.HOME_R or M.CFG.HOME_R
        if ctx.MM.BaseDist then home = ctx.MM.BaseDist(rec.cx, rec.cz) <= hr          -- near our eco buildings (as support/arty.lua)
        else
            local hx, hz = ctx.MM.Base()
            home = (rec.cx - hx) ^ 2 + (rec.cz - hz) ^ 2 <= hr * hr
        end
    end
    local liftD = cfg.LIFT_DIST or M.CFG.LIFT_DIST
    for i, uid in ipairs(units) do
        if LIFT and LIFT.Busy(uid) then
            -- in the air: the transport re-routes to where the group's AA belongs now (user 2026-11-02)
            if rec.id ~= 0 and rec.cx then
                LIFT.Request(uid, rec.cx - (rec.dx or 0) * 800, rec.cz - (rec.dz or 0) * 800, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, "aa g" .. rec.id)
            else
                LIFT.Request(uid, bx, bz, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, "aa pool")
            end
        else
            local defID = Spring.GetUnitDefID(uid)
            local x, z = bx + math.cos(i * 2.4) * (cfg.SPREAD or 60) * math.sqrt(i), bz + math.sin(i * 2.4) * (cfg.SPREAD or 60) * math.sqrt(i)
            if ctx.MM and ctx.MM.Clamp then x, z = ctx.MM.Clamp(x, z, 200) end
            local ux, _, uz = Spring.GetUnitPosition(uid)
            if ux and LIFT and not home and (ux - x) ^ 2 + (uz - z) ^ 2 > liftD * liftD then
                -- set down where the Quakers are set down: behind the core (the drop point is the arty element's)
                local dxp, dzp = rec.cx - (rec.dx or 0) * 800, rec.cz - (rec.dz or 0) * 800
                LIFT.Request(uid, dxp, dzp, cfg.LIFT_PRIO or M.CFG.LIFT_PRIO, "aa g" .. rec.id)
            elseif LIFT and LIFT.Waiting(uid) then
                LIFT.Cancel(uid)
            end
            if rec.id ~= 0 and ctx.ClaimPaced then ctx.ClaimPaced(uid, "SUP_AA", ctx.CMD_MOVE, x, z, frame)
            else ctx.Claim(uid, "SUP_AA", ctx.CMD_MOVE, x, z, frame) end
            if defID then AimAir(uid, defID, ctx) end
        end
    end
    for uid in pairs(targetOf) do if not Spring.GetUnitDefID(uid) then targetOf[uid] = nil end end
end

return M
