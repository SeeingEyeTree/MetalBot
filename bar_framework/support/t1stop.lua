-- bar_framework/support/t1stop.lua  (army_groups element: T1 "stopping power" -- Pounders that hold a sector of the base, for the home records)
-- User 2026-11-02 (CORE_v4 vs CORE_ROWS_ECO, which raids our side all game): "make a t1 stopping power group that is 12 pounders.  It is slowly created
-- when there is high raid pressure ie always having to defend something.  It does not join anything since the main groups need to be quick but it just
-- spreads out like maneuver defend part of the home guard.  It could make up to 3 t1 stopping power groups.  They need to be added relatively slowly
-- since the normal units are needed to defend but they can slowly create a good cover."
--   * pressure: every tick, is a real raid at our eco?  (raid_response's record: threat near the eco -- scouts count 0.1 -- >= PRESS_SHARE x income x
--     PRESS_S, never under PRESS_FLOOR).  An exponential average over PRESS_TAU_S; groups = 1 / 2 / 3 at PRESS_1 / PRESS_2 / PRESS_3 (never fewer
--     later: what is built stays);
--   * slowly: the want grows from a budget of SPEND_FRAC x income (one Pounder's metal at a time) while it is under n x groups (losses are replaced
--     within it); ordered at the "normal" lab tier
--     (cfg.tier), under the defence floor and the raid answers;
--   * army_groups makes one HOME record per group (kind "home", ids -1..-3): a sector of the base -- in front (along the axis to the foe), then the two
--     flanks -- at HOME_R from the eco footprint's centre.  The Pounders stand on a line across the sector (FIGHT: they shoot what comes); an enemy
--     within RESPOND_R of the sector is FIGHT-ed, never farther than LEASH from the sector centre.  Home records come first in the hand-out, so a
--     Tzar (stop element opted into "home") goes to a defending group before a raid group.
-- cfg: n, tier, PRESS_*, RAMP_S, HOME_R, SPACING, RESPOND_R, LEASH.
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")

local M = { name = "t1stop" }
-- SPEND_FRAC (user 2026-11-02: "1 every 20s is too slow and it also needed to be sized on spending, like not more than 5%"): a budget fills at SPEND_FRAC x
-- metal income; each Pounder the want grows by costs one Pounder's metal (500 m/s: one every ~9 s).  PRESS_1..3 lowered (game 10: the first group at 10:15).
M.CFG = { N = 12, tier = "normal", PRESS_SHARE = 0.1, PRESS_S = 20, PRESS_FLOOR = 200, PRESS_TAU_S = 180, PRESS_1 = 0.15, PRESS_2 = 0.30, PRESS_3 = 0.45,
          SPEND_FRAC = 0.05, SPACING = 110, RESPOND_R = 1400, LEASH = 700 }

local P = { avg = 0, f = nil, groups = 0, allow = 0, bank = 0, logF = -1e9 }

local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end

-- one pressure sample per call (army_groups calls Gate every Sync, 1 Hz)
local function Sample(c, ctx, f)
    local mb = ctx.WG and ctx.WG.MetalBot
    local rd = mb and mb.raid
    local _, _, _, inc = Spring.GetTeamResources(Spring.GetMyTeamID(), "metal")
    local min = math.max(c.PRESS_FLOOR or M.CFG.PRESS_FLOOR, (c.PRESS_SHARE or M.CFG.PRESS_SHARE) * (inc or 0) * (c.PRESS_S or M.CFG.PRESS_S))
    local on = rd ~= nil and f - (rd.frame or -1e9) <= 300 and (rd.home or rd.value or 0) >= min
    local dt = P.f and (f - P.f) / 30 or 0
    P.f = f
    if dt > 0 then
        local k = math.min(1, dt / (c.PRESS_TAU_S or M.CFG.PRESS_TAU_S))
        P.avg = P.avg + k * ((on and 1 or 0) - P.avg)
    end
end

function M.Gate(c, ctx)
    local f = Spring.GetGameFrame()
    Sample(c, ctx, f)
    local g = 0
    if P.avg >= (c.PRESS_1 or M.CFG.PRESS_1) then g = 1 end
    if P.avg >= (c.PRESS_2 or M.CFG.PRESS_2) then g = 2 end
    if P.avg >= (c.PRESS_3 or M.CFG.PRESS_3) then g = 3 end
    if g > P.groups then
        P.groups = g
        Spring.Echo(string.format("[SUP] %s t1stop: raid pressure %.2f -> %d home group(s) of %d Pounders", Clock(f), P.avg, g, c.n or M.CFG.N))
    end
    -- the ramp: a budget of SPEND_FRAC x income buys one more Pounder at a time
    local cap = (c.n or M.CFG.N) * P.groups
    local ud = UnitDefNames and UnitDefNames[ROLES.Get("pounder")]
    local cost = (ud and ud.metalCost) or 220
    local _, _, _, inc = Spring.GetTeamResources(Spring.GetMyTeamID(), "metal")
    if P.allow < cap then
        P.bank = P.bank + (c.SPEND_FRAC or M.CFG.SPEND_FRAC) * (inc or 0)     -- Gate runs once a second (army_groups Sync)
        while P.bank >= cost and P.allow < cap do P.allow, P.bank = P.allow + 1, P.bank - cost end
    else
        P.bank = 0
    end
    if f - P.logF >= 1800 and P.avg > 0.05 then
        P.logF = f
        Spring.Echo(string.format("[SUP] %s t1stop: raid pressure %.2f, %d group(s), %d / %d Pounders allowed", Clock(f), P.avg, P.groups, P.allow, cap))
    end
    return P.groups > 0
end

function M.HomeGroups() return P.groups end                -- army_groups: how many home records to keep
function M.WantTotal(c, slots) return math.min(P.allow, (c.n or M.CFG.N) * slots) end

function M.Picks() return { ROLES.Get("pounder") } end

function M.Accept(defID)
    local d = UnitDefs[defID]
    return d ~= nil and d.name == ROLES.Get("pounder")
end

-- the nearest raid group (raid_response's record) within RESPOND_R of the sector
local function Threat(rec, ctx, frame, r)
    local mb = ctx.WG and ctx.WG.MetalBot
    local rd = mb and mb.raid
    if not (rd and rd.groups and frame - (rd.frame or -1e9) <= 300) then return nil end
    local best, bd
    for _, g in ipairs(rd.groups) do
        local d = (g.x - rec.cx) ^ 2 + (g.z - rec.cz) ^ 2
        if d <= r * r and (not bd or d < bd) then best, bd = g, d end
    end
    return best
end

function M.Update(rec, units, cfg, frame, ctx)
    if rec.id == 0 then                                   -- the pool: to the stage (a home record takes them at once)
        for i, uid in ipairs(units) do
            local x, z = ctx.Spot(rec, 0, i, 80)
            ctx.Claim(uid, "SUP_T1STOP", ctx.CMD_MOVE, x, z, frame)
        end
        return
    end
    local n = #units
    local dx, dz = rec.dx or 0, rec.dz or 0
    local px, pz = -dz, dx
    local sp = cfg.SPACING or M.CFG.SPACING
    local t = Threat(rec, ctx, frame, cfg.RESPOND_R or M.CFG.RESPOND_R)
    local leash = cfg.LEASH or M.CFG.LEASH
    for i, uid in ipairs(units) do
        local off = (i - (n + 1) / 2) * sp
        local x, z = rec.cx + px * off, rec.cz + pz * off
        if t then
            -- toward the raid, the line kept: each Pounder goes its offset beside the raid point, never past LEASH from the sector centre
            local tx, tz = t.x + px * off * 0.5, t.z + pz * off * 0.5
            local d = math.sqrt((tx - rec.cx) ^ 2 + (tz - rec.cz) ^ 2)
            if d > leash then tx, tz = rec.cx + (tx - rec.cx) / d * leash, rec.cz + (tz - rec.cz) / d * leash end
            x, z = tx, tz
        end
        if ctx.MM and ctx.MM.Clamp then x, z = ctx.MM.Clamp(x, z, 150) end
        ctx.Claim(uid, "SUP_T1STOP", ctx.CMD_FIGHT, x, z, frame)
    end
end

return M
