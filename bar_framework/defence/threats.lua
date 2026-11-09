-- bar_framework/defence/threats.lua  (area_defence: enemy ground groups that can reach an area we defend)
-- cover_defence.lua's threat model (2026-10-30, user's game review A-D), made area-aware: contacts on our side (radar dots typed by speed and
-- worth UNKNOWN_MULT x the guess, scouts at SCOUT_WEIGHT) are clustered, carried over from tick to tick (TRACK_R: a threat keeps its id, its
-- line push and its defenders), and each one gets the AREA and the member it points at (nearest in the cone of its heading), how soon it gets
-- there (tThreat) and the post in front of it (px, pz: LINE_OFF out, pushed out while it does not attack).
--
--   local TH = VFS.Include("LuaUI/Widgets/bar_framework/defence/threats.lua").New{ cfg, TM, EI, UQ, MM, allyID, areas = fn() -> { area, ... } }
--   TH.Step(frame) -> threats, gone      TH.Hist(eid) -> { x, z, vx, vz, f }

local M = {}

M.CFG = {
    TTL         = 450,    -- frames a sighting is acted on once out of sight
    CLUSTER_R   = 700,    -- contacts this close are one threat
    TRACK_R     = 1000,   -- a threat this close to last tick's is the same one
    SIDE_R      = 3000,   -- a threat on our half of the map, or this close to an area, is ours to answer
    UNKNOWN_MULT = 1.25,  -- a radar dot is worth this x its guessed type
    SCOUT_WEIGHT = 0.1,   -- a seen scout counts at this x its cost
    MIN_VALUE   = 120,    -- a threat worth less than this gets no cover (a lone scout)
    COVER_MULT  = 1.2,    -- defenders must be worth this x the threat
    CONE_COS    = 0.5,    -- a moving threat points at the member inside +-60 degrees of its heading
    LINE_OFF    = 400,    -- the defence line stands this far out from the threatened member
    CONTACT_GAP = 350,    -- a pushed line stops this short of the threat
    STILL       = 14,     -- elmos/s: slower than this = not moving
    NONSPEC_AA  = 0.35,   -- a unit that can shoot air but is not dedicated AA counts this x its value as the threat's AA (enemy_intel's rule)
    -- ... except these, which count 0 (user 2026-11-08: "count incisors as zero.  They can shoot air but not well and if there are ground targets they
    -- will shoot that before the air anyway")
    ZERO_AA     = { corgator = true },
}

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Norm(x, z) local d = math.sqrt(x * x + z * z); if d < 1e-6 then return 0, 0, 0 end; return x / d, z / d, d end

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    local TM, EI, UQ, MM = o.TM, o.EI, o.UQ, o.MM
    local myAllyID = o.allyID
    local TH = { cfg = C }
    local hist, old, nextId = {}, {}, 1

    local function Value(defID)
        local d = UnitDefs[defID]
        return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
    end
    local function Speed(defID) return (UQ.max_speed and UQ.max_speed(defID)) or ((UnitDefs[defID] or {}).speed or 0) end
    local function IsGround(defID) local d = UnitDefs[defID]; return d ~= nil and not d.canFly end

    local function Track(id, x, z, f)
        local h = hist[id]
        if not h then h = { x = x, z = z, f = f, vx = 0, vz = 0, still = f }; hist[id] = h; return h end
        if f > h.f then
            local dt = (f - h.f) / 30
            local vx, vz = (x - h.x) / dt, (z - h.z) / dt
            if dt > 12 then vx, vz = 0, 0 end
            h.vx, h.vz = 0.5 * h.vx + 0.5 * vx, 0.5 * h.vz + 0.5 * vz
            h.x, h.z, h.f = x, z, f
            if math.sqrt(h.vx * h.vx + h.vz * h.vz) >= C.STILL then h.still = f end
        end
        return h
    end
    function TH.Hist(eid) return hist[eid] end

    local function NearAnArea(x, z)
        for _, a in ipairs(o.areas()) do if a.N() > 0 and a.Dist(x, z) <= (a.cfg.SIDE_R or C.SIDE_R) then return true end end
        return false
    end

    local function Cluster(frame)
        local groups = {}
        local recs = EI and EI.Records and EI.Records() or {}
        local los, gh = Spring.IsPosInLos, Spring.GetGroundHeight
        for cid, c in pairs(TM.Contacts()) do
            local age = frame - c.frame
            if age <= C.TTL and not c.air then
                local defID = c.defID or (recs[cid] and recs[cid].defID)
                local v, sp, dot, guess
                if defID then
                    if UQ.is_mobile(defID) and IsGround(defID) then
                        v, sp = Value(defID), Speed(defID)
                        if UQ.is_scout and UQ.is_scout(defID) then v = v * C.SCOUT_WEIGHT end
                    end
                elseif EI and EI.GuessType then
                    local g = EI.GuessType(cid)
                    if g then v, sp, dot, guess = g.value * C.UNKNOWN_MULT, g.speed, true, g.name end
                end
                local gone = v and age > (TM.SCAN_PERIOD or 150) * 1.5 and los and los(c.x, gh(c.x, c.z) or 0, c.z, myAllyID)
                local ours = v and not gone and MM.Ready() and (MM.IsOurHalf(c.x, c.z) or NearAnArea(c.x, c.z))
                if ours and v > 0 then
                    local h = Track(cid, c.x, c.z, c.frame)
                    local g
                    for _, o2 in ipairs(groups) do
                        if (o2.x - c.x) ^ 2 + (o2.z - c.z) ^ 2 <= C.CLUSTER_R ^ 2 then g = o2; break end
                    end
                    if not g then
                        g = { x = c.x, z = c.z, n = 0, v = 0, dots = 0, wvx = 0, wvz = 0, wsp = 0, stillS = 1e9, guess = {}, ids = {}, fast = 0, aa = 0 }
                        groups[#groups + 1] = g
                    end
                    local n = g.n + 1
                    g.x, g.z = (g.x * g.n + c.x) / n, (g.z * g.n + c.z) / n
                    g.n, g.v = n, g.v + v
                    g.ids[#g.ids + 1] = cid
                    g.wvx, g.wvz, g.wsp = g.wvx + h.vx * v, g.wvz + h.vz * v, g.wsp + (sp or 0) * v
                    g.stillS = math.min(g.stillS, (frame - h.still) / 30)
                    if (sp or 0) >= 70 then g.fast = g.fast + v end         -- raiders (checklist ground_raid)
                    -- what in it shoots air (game 2026-11-08: the enemy's raid groups brought Lashers / flak trucks and killed 242 of our Shurikens)
                    -- (dedicated AA in full, anything else that can shoot up at NONSPEC_AA: game 3, every Brute / Incisor raid counted as all-AA and
                    -- blocked the air squad everywhere -- enemy_intel's NONSPECIALIST_AA rule)
                    if defID and UQ.can_hit_air and UQ.can_hit_air(defID) and not C.ZERO_AA[UnitDefs[defID].name] then
                        g.aa = g.aa + Value(defID) * ((UQ.is_dedicated_aa and UQ.is_dedicated_aa(defID)) and 1 or C.NONSPEC_AA)
                    end
                    if defID and (tonumber((UnitDefs[defID].customParams or {}).techlevel) or 1) >= 2 then g.heavy = (g.heavy or 0) + v end
                    if dot then g.dots = g.dots + 1; g.guess[guess or "?"] = (g.guess[guess or "?"] or 0) + 1 end
                end
            end
        end
        for id, h in pairs(hist) do if frame - h.f > 2 * C.TTL then hist[id] = nil end end
        local out = {}
        for _, g in ipairs(groups) do
            if g.v >= C.MIN_VALUE then
                g.vx, g.vz = g.wvx / g.v, g.wvz / g.v
                g.speed = math.sqrt(g.vx * g.vx + g.vz * g.vz)
                g.typeSpeed = g.wsp / g.v
                out[#out + 1] = g
            end
        end
        return out
    end

    -- carry each threat's state over from last tick: the nearest old one within TRACK_R
    local function Match(groups)
        local used, out = {}, {}
        for _, g in ipairs(groups) do
            local best, bd
            for i, t in ipairs(old) do
                if not used[i] then
                    local d = Dist(g.x, g.z, t.x, t.z)
                    if d <= C.TRACK_R and (not bd or d < bd) then best, bd = i, d end
                end
            end
            if best then
                used[best] = true
                local t = old[best]
                g.id, g.pushD, g.pushF, g.mode, g.bornF = t.id, t.pushD, t.pushF, t.mode, t.bornF
            else
                g.id = nextId
                nextId = nextId + 1
            end
            out[#out + 1] = g
        end
        local gone = {}
        for i, t in ipairs(old) do if not used[i] then gone[t.id] = t end end
        return out, gone
    end

    -- which area and member each threat can hit, and when
    local function Assess(t)
        local moving = t.speed >= C.STILL
        local best
        for _, a in ipairs(o.areas()) do
            if a.N() > 0 then
                local ex, ez, d
                if moving then ex, ez, d = a.NearestInCone(t.x, t.z, t.vx, t.vz, C.CONE_COS) end
                if not ex then ex, ez, d = a.NearestInCone(t.x, t.z, 0, 0, -2) end
                if ex and (not best or d < best.d) then best = { a = a, ex = ex, ez = ez, d = d } end
            end
        end
        if not best then
            local ex, ez = MM.Base()
            best = { a = nil, ex = ex, ez = ez, d = ex and Dist(t.x, t.z, ex, ez) or 0 }
        end
        t.area, t.ex, t.ez, t.dEco = best.a, best.ex, best.ez, best.d
        t.ux, t.uz = Norm(t.x - t.ex, t.z - t.ez)
        if t.ux == 0 and t.uz == 0 then local ax, az = MM.Axis(); t.ux, t.uz = ax or 1, az or 0 end
        t.closing = -(t.vx * t.ux + t.vz * t.uz)
        t.tThreat = t.dEco / math.max(30, moving and math.max(t.speed, 0.6 * t.typeSpeed) or t.typeSpeed)
        t.pushD = t.pushD or C.LINE_OFF
        local maxPush = math.max(C.LINE_OFF, t.dEco - C.CONTACT_GAP)
        if t.pushD > maxPush then t.pushD = maxPush end
        t.px, t.pz = MM.Clamp(t.ex + t.ux * t.pushD, t.ez + t.uz * t.pushD, 100)
        t.need = C.COVER_MULT * t.v
    end

    function TH.Step(frame)
        local threats, gone = Match(Cluster(frame))
        for _, t in ipairs(threats) do t.bornF = t.bornF or frame; Assess(t) end
        old = threats
        return threats, gone
    end

    return TH
end

return M
