-- bar_framework/line_transition/radar_ring.lua
-- The radar ring (user 2026-10-31, close-spawn game c: "an attack at ~7:26 just comes into view but by that point it is too late to respond.
-- Send out two bot cons at ~5 min that build radar around the base").  At RADAR_RING_FRAME the line's bot lab gets RADAR_RING_CONS T1 bot cons
-- ordered at the head of its queue; the first that many it makes are the ring's (macro_runtime does not count them as line cons:
-- LT.RadarRingOwns), registered with the con broker under the owner "radarring" so no job, defense_crew or line takes them.  They build
-- RADAR_RING_N radar towers on a ring RADAR_RING_OUT outside our structures (the 90th-percentile radius round their centre), on bearings spread
-- round the base and starting with the enemy side; a tower that dies is built again.  When both cons are dead and a site is open, two more are
-- ordered (at most every RADAR_RING_RETRY frames).  Plain build orders (no placer session): a con with an empty queue is given the open site
-- nearest it.  Log rows: [LT] ... radar ring.
-- Part of line_transition (bar_framework/line_transition.lua installs it).  Options read (LT.CFG): RADAR_RING RADAR_RING_FRAME RADAR_RING_CONS
-- RADAR_RING_N RADAR_RING_OUT RADAR_RING_COVER RADAR_RING_RETRY

local M = {}
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local CB = VFS.Include("LuaUI/Widgets/bar_framework/con_broker.lua")

local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

function M.Install(X)
    local Clock = X.Clock

    local function State(T)
        T.rr = T.rr or { cons = {}, mine = {}, pending = 0, orderedF = nil, lab = nil, sites = nil, siteF = -1e9, logF = -1e9, built = 0 }
        return T.rr
    end

    -- our radar towers (any static unit with a radar this big) and the structure footprint: centre + 90th-percentile radius
    local function Survey(T)
        local radarDef = UnitDefNames[ROLES.Get("radar")]
        local minR = radarDef and (radarDef.radarRadius or radarDef.radarDistance or 1500) * 0.8 or 1500
        local radars, pts = {}, {}
        for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and not d.canMove then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then
                    pts[#pts + 1] = { x = x, z = z }
                    if (d.radarRadius or d.radarDistance or 0) >= minR then radars[#radars + 1] = { x = x, z = z } end
                end
            end
        end
        return radars, pts
    end

    -- the ring's sites: RADAR_RING_N bearings round the structures' centre, the first toward the enemy
    local function Sites(T, pts)
        local C = T.CFG
        if #pts == 0 then return nil end
        local cx, cz = 0, 0
        for _, p in ipairs(pts) do cx, cz = cx + p.x, cz + p.z end
        cx, cz = cx / #pts, cz / #pts
        local ds = {}
        for i, p in ipairs(pts) do ds[i] = Dist(p.x, p.z, cx, cz) end
        table.sort(ds)
        local R = ds[math.max(1, math.ceil(#ds * 0.9))] + C.RADAR_RING_OUT
        local mb = T.WG and T.WG.MetalBot
        local ax, az = (mb and mb.axisX) or 1, (mb and mb.axisZ) or 0
        local a0 = math.atan2(az, ax)
        local mx, mz = Game.mapSizeX, Game.mapSizeZ
        local out = {}
        for k = 0, C.RADAR_RING_N - 1 do
            -- 0, +1, -1, +2, -2 ... steps of 360/N: the enemy side first
            local step = math.ceil(k / 2) * ((k % 2 == 1) and 1 or -1)
            local a = a0 + step * 2 * math.pi / C.RADAR_RING_N
            local x = math.max(200, math.min(mx - 200, cx + math.cos(a) * R))
            local z = math.max(200, math.min(mz - 200, cz + math.sin(a) * R))
            out[#out + 1] = { x = x, z = z }
        end
        return out
    end

    -- a legal spot near (x, z) for the tower
    local function Spot(defID, x, z)
        local function ok(px, pz)
            local y = Spring.GetGroundHeight(px, pz) or 0
            return Spring.TestBuildOrder(defID, px, y, pz, 0) ~= 0
        end
        if ok(x, z) then return x, z end
        for ring = 1, 3 do
            for k = 0, 7 do
                local a = k * math.pi / 4
                local px, pz = x + math.cos(a) * 96 * ring, z + math.sin(a) * 96 * ring
                if ok(px, pz) then return px, pz end
            end
        end
        return nil
    end

    -- the lab that makes the cons: one of ours that can build a T1 bot con (the line's starter lab first: the lowest id)
    local function BotLab(T, conDef)
        local best
        for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and d.isFactory and T.BP.CanBuild(Spring.GetUnitDefID(uid), conDef.id) then
                local _, _, _, _, bp = Spring.GetUnitHealth(uid)
                if (not bp or bp >= 1) and (not best or uid < best) then best = uid end
            end
        end
        return best
    end

    local function UpdateRadarRing(T, frame, res)
        local C = T.CFG
        if not C.RADAR_RING or frame < C.RADAR_RING_FRAME then return end
        local S = State(T)
        local conDef, radarDef = UnitDefNames[ROLES.Get("con_t1_bot")], UnitDefNames[ROLES.Get("radar")]
        if not (conDef and radarDef) then return end
        if frame - S.siteF < 150 then return end
        S.siteF = frame
        local radars, pts = Survey(T)
        S.sites = Sites(T, pts) or S.sites
        if not S.sites then return end
        -- open sites: no tower of ours within RADAR_RING_COVER
        local open = {}
        for _, s in ipairs(S.sites) do
            local covered = false
            for _, r in ipairs(radars) do if Dist(r.x, r.z, s.x, s.z) <= C.RADAR_RING_COVER then covered = true; break end end
            if not covered then open[#open + 1] = s end
        end
        if S.pending > 0 and S.orderedF and frame - S.orderedF > 3600 then S.pending = 0 end   -- an order that never came out (lab lost)
        -- cons alive
        local alive = {}
        for uid in pairs(S.cons) do if Spring.GetUnitDefID(uid) then alive[#alive + 1] = uid else S.cons[uid] = nil end end
        -- order the cons: once at the start, again when every one is dead and a site is open
        if #alive == 0 and S.pending <= 0 and #open > 0 and (not S.orderedF or frame - S.orderedF >= C.RADAR_RING_RETRY) then
            local lab = BotLab(T, conDef)
            if lab then
                for _ = 1, C.RADAR_RING_CONS do CB.OrderCon(T.WG, lab, conDef.id, frame, true) end
                S.lab, S.pending, S.orderedF = lab, C.RADAR_RING_CONS, frame
                Spring.Echo(string.format("[LT] %s radar ring: %d %s ordered from lab %d for %d sites", Clock(frame), C.RADAR_RING_CONS,
                    conDef.name, lab, #open))
            elseif frame - S.logF >= 1800 then
                S.logF = frame
                Spring.Echo("[LT] " .. Clock(frame) .. " radar ring: no lab of ours can build " .. conDef.name .. " yet")
            end
        end
        -- an idle con takes the open site nearest it (two cons never take the same site)
        local taken = {}
        for _, uid in ipairs(alive) do
            local q = Spring.GetUnitCommands(uid, 1)
            local busy = q and #q > 0
            local x, _, z = Spring.GetUnitPosition(uid)
            if not busy and x then
                local best, bd
                for i, s in ipairs(open) do
                    if not taken[i] then
                        local d = Dist(x, z, s.x, s.z)
                        if not bd or d < bd then best, bd = i, d end
                    end
                end
                if best then
                    taken[best] = true
                    local s = open[best]
                    local sx, sz = Spot(radarDef.id, s.x, s.z)
                    if sx then
                        Spring.GiveOrderToUnit(uid, -radarDef.id, { sx, Spring.GetGroundHeight(sx, sz) or 0, sz, 0 }, {})
                        S.built = S.built + 1
                        Spring.Echo(string.format("[LT] %s radar ring: con %d builds %s at (%d, %d) (%d of %d sites open)", Clock(frame), uid,
                            radarDef.name, sx, sz, #open, #S.sites))
                    end
                end
            end
        end
    end

    -- a bot con the ring ordered: the next RADAR_RING_CONS that lab makes are the ring's (macro_runtime skips them: RadarRingOwns)
    local function Created(T, unitID, defID, builderID)
        local S = T.rr
        if not S or S.pending <= 0 or builderID ~= S.lab then return end
        local conDef = UnitDefNames[ROLES.Get("con_t1_bot")]
        if not conDef or defID ~= conDef.id then return end
        S.pending = S.pending - 1
        S.mine[unitID] = true
        S.cons[unitID] = true
    end

    local function Finished(T, unitID)
        local S = T.rr
        if not (S and S.mine[unitID]) then return end
        X.LT.AdoptCon(T, unitID, "radarring")          -- the broker knows it, and that it is taken
        Spring.Echo(string.format("[LT] %s radar ring: con %d out", Clock(T.frame or 0), unitID))
    end

    X.UpdateRadarRing, X.RadarRingCreated, X.RadarRingFinished = UpdateRadarRing, Created, Finished
    X.RadarRingOwns = function(T, unitID) return T.rr ~= nil and T.rr.mine[unitID] == true end
end

return M
