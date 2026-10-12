-- bar_framework/behaviors/steer.lua
-- ARMY behaviour (ported from click_army's LegPoint + FlankPoint, the steering the LINE_CLICK attack groups used).
-- Steers the army AWAY from enemy armed units on its way to the shared target instead of marching into them:
--   1. FLANK waypoint: when the biggest recently seen enemy army cluster (>= min_frac of ours) sits on the straight path
--      (within `clear` of it, between us and the target, and not guarding the target itself), the army heads for a
--      waypoint `offset` beside the cluster.  The side is kept until the cluster is passed.
--   2. LEG: the next leg (`leg` elmos) is the heading, within about +-70 degrees of the line to the waypoint/target, with the
--      least enemy armed value near its end (plus a small penalty per radian turned).  The unit being attacked is not
--      counted (an armed target such as the commander would push every leg sideways).
-- It only claims units when a detour is needed (a flank waypoint, or a turned leg) and they are further than
-- `attack_switch` from the target; otherwise it returns nil and the next behaviour (attack_target) fights straight on.
-- Claimed units MOVE to the leg point (no stopping to shoot on the way) -- put it just before attack_target.
-- cfg: leg=1000 attack_switch=800 near_r=900 turn_penalty=0.15 clear=1800 offset=2800 min_frac=0.5
-- ctx needs: shared (pick_target)  Cluster(frame)->x,z,value  ArmedValueNear(frame,x,z,r,skipUid)  Clamp(x,z)  Log
local M = { name = "steer", cfg = { leg = 1000, attack_switch = 800, near_r = 900, turn_penalty = 0.15,
                                    clear = 1800, offset = 2800, min_frac = 0.5 } }

local ANGLES = { 0, 0.6, -0.6, 1.2, -1.2 }

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end

-- A waypoint beside the enemy army when the straight path to (tx,tz) runs into it, else nil.
local function FlankPoint(st, ctx, frame, cx, cz, tx, tz, value)
    local c = st.cfg
    local ax, az, av = ctx.Cluster(frame)
    if not ax or av < c.min_frac * value then st.side = nil; return nil end
    if Dist(ax, az, tx, tz) < c.clear then return nil end              -- it guards the target itself: no way round
    local dx, dz = tx - cx, tz - cz
    local L = math.sqrt(dx * dx + dz * dz)
    if L < 1 then return nil end
    local ux, uz = dx / L, dz / L
    local px, pz = ax - cx, az - cz
    local along = px * ux + pz * uz
    if along <= 0 or along >= L then st.side = nil; return nil end       -- behind us, or beyond the target
    local lat = -px * uz + pz * ux
    if math.abs(lat) >= c.clear then return nil end                      -- the path already clears it
    local side = st.side or ((lat >= 0) and -1 or 1)
    local wx, wz = ax - uz * side * c.offset, az + ux * side * c.offset
    local cwx, cwz = ctx.Clamp(wx, wz)
    if not st.side and Dist(cwx, cwz, wx, wz) > c.offset * 0.5 then      -- that side is off the map: the other one
        side = -side
        wx, wz = ax - uz * side * c.offset, az + ux * side * c.offset
        cwx, cwz = ctx.Clamp(wx, wz)
    end
    st.side = side
    return cwx, cwz, av
end

function M.Update(st, group, ctx, frame, host)
    local sh, c = ctx.shared, st.cfg
    if not sh.tx or #group.list == 0 then return nil end
    local sx, sz, value = 0, 0, 0
    for _, u in ipairs(group.list) do sx, sz, value = sx + u.x, sz + u.z, value + u.v end
    local cx, cz = sx / #group.list, sz / #group.list
    local d = Dist(cx, cz, sh.tx, sh.tz)
    if d <= c.attack_switch then return nil end
    local gx, gz = sh.tx, sh.tz
    local wx, wz, av = FlankPoint(st, ctx, frame, cx, cz, sh.tx, sh.tz, value)
    local flanking = wx ~= nil
    if flanking then gx, gz = wx, wz end
    local dx, dz = gx - cx, gz - cz
    local gd = math.sqrt(dx * dx + dz * dz)
    if gd < 1 then return nil end
    local step = math.min(c.leg, gd)
    dx, dz = dx / gd, dz / gd
    local bx, bz, bestCost, bestAng
    local skip = sh.target and sh.target.uid
    for _, ang in ipairs(ANGLES) do
        local cs, sn = math.cos(ang), math.sin(ang)
        local rx, rz = dx * cs - dz * sn, dx * sn + dz * cs
        local px, pz = ctx.Clamp(cx + rx * step, cz + rz * step)
        local cost = ctx.ArmedValueNear(frame, px, pz, c.near_r, skip) + math.abs(ang) * c.turn_penalty * value
        if not bestCost or cost < bestCost then bx, bz, bestCost, bestAng = px, pz, cost, ang end
    end
    if not flanking and bestAng == 0 then return nil end                  -- straight on is as good: let attack_target fight
    if flanking and frame - (st.logF or -1e9) >= 450 then
        st.logF = frame
        ctx.Log(frame, "steer: flanks the enemy army (av=%d vs ours %d) via (%d,%d)", av or 0, value, wx, wz)
    end
    for _, u in ipairs(group.list) do host:Order(frame, u.uid, 10, bx, bz) end
    return true
end

function M.Describe(cfg) return string.format("steers round enemy armed units: %d-elmo legs, flank waypoint %d beside an army on the path", cfg.leg, cfg.offset) end
return M
