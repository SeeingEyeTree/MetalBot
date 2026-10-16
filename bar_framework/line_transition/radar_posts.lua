-- bar_framework/line_transition/radar_posts.lua
-- Radar towers beside the maneuver plan's blobs (user, 2026-10-16: "the radar can be built near blobs by an air con").
-- Part of line_transition (bar_framework/line_transition.lua installs it).  The unit controller publishes the blob posts as
-- WG.MetalBot.blobs = { {x, z, n}, ... } (maneuver_defence.lua); a blob with no radar within RADAR_COVER gets one, RADAR_BACK elmos behind
-- its post toward the base, built by a free air con (the "radar" job, low priority: grids, labs and nanos come first).  The radar's
-- dots are what maneuver_defence counts as threats (BLIP_VALUE) and what the shadows go and look at, so groups are met early.
-- Without blobs (every other stance plan) the job wants nothing, so a bot that does not play the maneuver plan is not changed.
-- Options read (LT.CFG): RADAR_POSTS RADAR_NAMES RADAR_FRAME RADAR_COVER RADAR_BACK RADAR_AT_ONCE RADAR_MAX RADAR_RETRY

local M = {}

function M.Install(X)
    local CB, Clock = X.CB, X.Clock

    local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

    -- our radar towers (finished or not): { {x, z}, ... }, re-read every 60 frames
    local function Radars(T, frame)
        if T.radarListF and frame - T.radarListF < 60 then return T.radarList end
        local want = {}
        for _, name in ipairs(T.CFG.RADAR_NAMES) do
            local ud = UnitDefNames[name]
            if ud then want[ud.id] = true end
        end
        local out = {}
        for _, uid in ipairs(Spring.GetTeamUnits(T.teamID) or {}) do
            if want[Spring.GetUnitDefID(uid)] then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then out[#out + 1] = { x = x, z = z } end
            end
        end
        T.radarList, T.radarListF = out, frame
        return out
    end

    -- the blobs that still need a radar: { {x, z}, ... } (the build spot, behind the post toward the base)
    local function Unmet(T, frame)
        local C = T.CFG
        if not C.RADAR_POSTS or T.ecoPaused or frame < C.RADAR_FRAME then return {} end
        local mb = T.WG and T.WG.MetalBot
        local blobs = mb and mb.blobs
        if not blobs or #blobs == 0 then return {} end
        local radars = Radars(T, frame)
        if #radars >= C.RADAR_MAX then return {} end
        T.radarStarted = T.radarStarted or {}
        local out = {}
        for _, b in ipairs(blobs) do
            local covered = false
            for _, r in ipairs(radars) do if Dist(r.x, r.z, b.x, b.z) <= C.RADAR_COVER then covered = true; break end end
            for _, s in ipairs(T.radarStarted) do
                if frame - s.f < C.RADAR_RETRY and Dist(s.x, s.z, b.x, b.z) <= C.RADAR_COVER then covered = true; break end
            end
            if not covered then
                local x, z = b.x, b.z
                if mb.homeX then
                    local dx, dz = mb.homeX - b.x, mb.homeZ - b.z
                    local l = math.max(math.sqrt(dx * dx + dz * dz), 1)
                    x, z = b.x + dx / l * C.RADAR_BACK, b.z + dz / l * C.RADAR_BACK
                end
                out[#out + 1] = { x = x, z = z, bx = b.x, bz = b.z }
            end
        end
        return out
    end

    local function Active(sessions)
        local n = 0
        for _, st in ipairs(sessions) do if not st.done then n = n + 1 end end
        return n
    end

    -- the first free spot near the wanted one the engine accepts for this tower
    local function Spot(defID, x, z)
        local function ok(px, pz)
            return not Spring.TestBuildOrder or Spring.TestBuildOrder(defID, px, 0, pz, 0) ~= 0
        end
        if ok(x, z) then return x, z end
        for ring = 1, 2 do
            for k = 0, 7 do
                local a = k * math.pi / 4
                local px, pz = x + math.cos(a) * 110 * ring, z + math.sin(a) * 110 * ring
                if ok(px, pz) then return px, pz end
            end
        end
        return x, z
    end

    X.RadarUnmet = Unmet
    X.jobs = X.jobs or {}
    X.jobs.radar = function(T, cb)
        local sessions = {}
        CB.AddJob(cb, { name = "radar", section = "crew", prio = 35, tier = "t1", useReserve = false, urgent = false,
            sessions = sessions, paused = function() return T.ecoPaused end,
            want = function(frame)
                local n = #Unmet(T, frame or T.frame or 0)
                return math.max(0, math.min(n, T.CFG.RADAR_AT_ONCE - Active(sessions)))
            end,
            start = function(conID, frame)
                frame = frame or T.frame or 0
                local cdef = Spring.GetUnitDefID(conID)
                for _, name in ipairs(T.CFG.RADAR_NAMES) do
                    local ud = UnitDefNames[name]
                    if ud and T.BP.CanBuild(cdef, ud.id) then
                        local site = Unmet(T, frame)[1]
                        if not site then return false end
                        local x, z = Spot(ud.id, site.x, site.z)
                        T.radarStarted[#T.radarStarted + 1] = { x = site.bx, z = site.bz, f = frame }
                        T.radarListF = nil
                        Spring.Echo(string.format("[LT] %s %s beside the blob at (%d, %d): built at (%d, %d) by con %d", Clock(frame), name,
                            site.bx, site.bz, x, z, conID))
                        return T.BP.New({ layout = { { n = name, x = 0, z = 0, f = 0 } } }, conID, x, z, 0, {})
                    end
                end
                return false
            end })
    end
end

return M
