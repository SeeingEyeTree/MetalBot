-- bar_framework/area_defence.lua  (one owner for defending what we have built: areas, a threat checklist, four squads)
-- User 2026-11-08: "Right now there is air raid response, the pounder tzar screen and the normal army groups that all defend but don't talk to each
-- other.  I need to unify it ... you declare groups of buildings to defend and a radius to protect and it tries to protect that ... The idea is to
-- defend cost effectively to free up units to go attack."
--
-- Each tick (where raid_response's Dispatch runs: 1 Hz, more while units are in the clock's HIGH / FAST tier):
--   1. AREAS (defence/areas.lua): the main base = labs, eco and static builders within R_MAX 4000 of the spawn; more areas with AD.Declare (proxy bases).
--   2. THREATS (defence/threats.lua, cover_defence's model): enemy ground groups on our side, radar dots included, each pointing at an area member.
--   3. RAID PRESSURE per area (support/t1stop.lua's measure on the area's threats) -> how many walls stand at full size; the CHECKLIST
--      (defence/checklist.lua): ground raids, heavy ground, air-to-ground, nukes, long range -- what is short and who answers it.
--   4. ALLOCATION, most urgent threat first (slack = its time to its member - our nearest free unit's time to its post), need = COVER_MULT x value,
--      filled CHEAPEST FIRST: the WALL (defence/wall.lua: Pounders + Tzars standing on the front, they are there anyway), the AIR squad
--      (defence/air.lua: Shurikens, Wasps), then BORROWED ARMY (defence/army.lua: free units not in a click_army group).  Above KEEP_MULT x need the
--      army goes back first (farthest first); a threat that is gone hands its army units back (forward ones raid from there: click_army Adopt).
--   5. ORDERS: each squad orders its own units (MOVE only for the ground ones).  The construction squad (defence/build.lua) is a stub.
--   6. PUBLISH: mb.cover (as cover_defence did: the launch gate, home_quiet_s, the raid record's fight groups) and mb.defence (areas, walls,
--      checklist, the "do we need more units" signals below).
-- User 2026-11-08 ("some signal for if more units need to be built to defend ... it could stop unit production for 20 sec to sneak out some eco"):
--   built cover per threat = what is on it + free units that reach its post before it does -- NO new production.  mb.defence.margin = the worst
--   threat's built / need (99 with none), needUnits = margin < 1 (or enemy bombers in our half while the checklist's air row is short), coverS = how
--   long margin >= BURST_MARGIN with needUnits false.  Signals def_margin / def_need_units / def_cover_s / def_threats / def_covered (signals.lua);
--   machines/v4_rows_raid.lua's def_burst node stops unit production for 20 s on them.
--
--   local AD = VFS.Include("LuaUI/Widgets/bar_framework/area_defence.lua").New{ cfg = K.AREA_DEFENCE, ARMY, UQ, TM, EI, MM, CA, HOST, LIFT, WG,
--       combatUnits, musterPool, responding, teamID, allyID, giveBack = fn(uid, defID), homeAA = fn() -> value, count, label }
--   AD.Declare{ id, R_MAX, members = fn() -> ids }   AD.Step(frame)   AD.Publish(frame, mb)   AD.Offer(uid, defID) -> bool   AD.OnDestroyed(uid)
--   AD.Owns(uid)   AD.Units() -> { [uid] = defID }   AD.FightGroups()   AD.HomeAAWant()
-- Log rows: [DEF].

local BC = VFS.Include("LuaUI/Widgets/bar_framework/bot_config.lua")
local ROLES = VFS.Include("LuaUI/Widgets/bar_framework/roles.lua")
local function Part(name) return VFS.Include("LuaUI/Widgets/bar_framework/defence/" .. name .. ".lua") end
local AR, THm, DA, WLm, AIRm, CLm, BLm = Part("areas"), Part("threats"), Part("army"), Part("wall"), Part("air"), Part("checklist"), Part("build")

local M = {}

M.CFG = {
    R_MAX        = 4000,  -- the main area: buildings this close to the spawn
    PROXY_R      = 1200,  -- the proxy area (WG.ProxyBase): buildings this close to its spot (the spot itself counts from the moment it is chosen)
    PROXY_SIDE_R = 1800,  -- threats this close to the proxy count for it (not the main area's 3000: the enemy base is ~4000 away)
    PROXY_TZARS  = 2,     -- Tzars every proxy wall wants (the proxy's T2 lab makes them; they are never handed back)
    PROXY_AIR_FRAC = 0.33, -- this share of the air squad (at least PROXY_AIR_MIN) belongs to the proxy while it stands (user: "some of the shurikens should
    PROXY_AIR_MIN  = 4,    -- also get sent to the proxy base, since the main base can easily rebuild them")
    COVER_MULT   = 1.2,   -- defenders worth this x the threat
    KEEP_MULT    = 1.8,   -- above this x the need, defenders go back (army first, farthest first)
    WALL_WORTH   = 1.0,   -- the wall's value counts at this x its cost against a need
    WALLS_PER_THREAT = 2, -- a threat takes at most this many (3-Pounder) walls; the others keep covering their part of the front
    AIR_R        = 2000,  -- the air squad goes at the closest threat this close to the eco (user: "stun anything within 1-2k elmos of the base") ...
    AIR_SLACK    = 400,   -- ... and stays on it until it is AIR_R + this out
    -- raid pressure (support/t1stop.lua): a threat worth >= max(PRESS_FLOOR, PRESS_SHARE x income x PRESS_S) within PRESS_R of the area's eco
    -- is "on"; its exponential average over PRESS_TAU_S -> 1 / 2 / 3 walls at full size at PRESS_1 / 2 / 3, back down under PRESS_DOWN x those
    PRESS_SHARE  = 0.1, PRESS_S = 20, PRESS_FLOOR = 200, PRESS_TAU_S = 180, PRESS_1 = 0.15, PRESS_2 = 0.30, PRESS_3 = 0.45, PRESS_DOWN = 0.7,
    PRESS_R      = 1200,
    -- uncovered value that counts as a raid we cannot easily handle (pub.lastHardF -> signal home_quiet_s), as cover_defence
    HARD_SHARE   = 0.2, HARD_S = 20, HARD_FLOOR = 150,
    -- production in time counts for the launch gate only (cover_defence's PROD_* rule), never for the built-cover signals
    REINF_SPEED  = 90, PROD_FRAC = 0.8, PROD_R = 1500,
    BURST_MARGIN = 1.3,   -- def_cover_s counts while every threat's built cover is >= this x its need
    AIR_ALARM_S  = 30,    -- enemy bombers in our half this recently while the checklist's air row is short: needUnits
    TZAR_TIER    = "high",
    AA_TIER      = "normal",
    LOG_EVERY    = 150,
    -- the parts' own options (each part's CFG; a typo is logged)
    AREAS = nil, THREATS = nil, WALL = nil, AIR = nil, ARMY = nil, CHECKLIST = nil, BUILD = nil,
}
M.NIL_OPTIONS = { "AREAS", "THREATS", "WALL", "AIR", "ARMY", "CHECKLIST", "BUILD" }

local function Dist(ax, az, bx, bz) local dx, dz = ax - bx, az - bz; return math.sqrt(dx * dx + dz * dz) end
local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end

local function PartCfg(mod, name, given, label)
    local c = {}
    for k, v in pairs(mod.CFG) do c[k] = v end
    for k, v in pairs(given or {}) do
        if mod.CFG[k] == nil then Spring.Echo(string.format("[DEF] %s option '%s' is not a %s option (typo?)", label or "", tostring(k), name)) end
        c[k] = v
    end
    return c
end

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    BC.Apply("area_defence", C, o.cfg, o.label, M.NIL_OPTIONS)
    local ARMY, UQ, TM, EI, MM, CA = o.ARMY, o.UQ, o.TM, o.EI, o.MM, o.CA
    local WG = o.WG
    local responding = o.responding
    local myTeamID = o.teamID
    local AD = {}

    local areas = {}
    local function Areas() return areas end
    function AD.Declare(spec)
        local a = AR.New{ id = spec.id, R_MAX = spec.R_MAX, members = spec.members, anchor = spec.anchor, MM = MM, teamID = myTeamID,
                          anchorPoint = spec.anchorPoint, axis = spec.axis, SIDE_R = spec.SIDE_R, wall = spec.wall,
                          cfg = PartCfg(AR, "areas", C.AREAS, o.label) }
        areas[#areas + 1] = a
        Spring.Echo(string.format("[DEF] area %s declared (radius %d%s)", a.id, a.cfg.R_MAX, spec.members and ", own member list" or ", labs / eco / static builders"))
        return a
    end

    local TH = THm.New{ cfg = PartCfg(THm, "threats", C.THREATS, o.label), TM = TM, EI = EI, UQ = UQ, MM = MM, allyID = o.allyID, areas = Areas }
    TH.cfg.COVER_MULT = C.COVER_MULT
    local army = DA.New{ cfg = PartCfg(DA, "army", C.ARMY, o.label), ARMY = ARMY, UQ = UQ, MM = MM, CA = CA, combatUnits = o.combatUnits,
                         musterPool = o.musterPool, responding = responding, hist = TH.Hist }
    local LIFT = o.LIFT
    local wall = WLm.New{ cfg = PartCfg(WLm, "wall", C.WALL, o.label), ARMY = ARMY, UQ = UQ, MM = MM, LIFT = LIFT, HOST = o.HOST, WG = WG, teamID = myTeamID,
                          army = army, hist = TH.Hist, giveBack = o.giveBack }
    local air = AIRm.New{ cfg = PartCfg(AIRm, "air", C.AIR, o.label), ARMY = ARMY, UQ = UQ, EI = EI, allyID = o.allyID,
                          centre = function(id)
                              for _, a in ipairs(areas) do if id and a.id == id then return a.Centre() end end
                              local a = areas[1]; if a then return a.Centre() end; return MM.Base() end }
    local build = BLm.New{ cfg = PartCfg(BLm, "build", C.BUILD, o.label) }

    -- raid pressure per area
    local press = {}          -- [areaId] = { avg, f, groups }
    local function Pressure(id) local p = press[id]; if not p then return 0, 0 end; return p.avg, p.groups end
    local CL = CLm.New{ cfg = PartCfg(CLm, "checklist", C.CHECKLIST, o.label), EI = EI, UQ = UQ, teamID = myTeamID, areas = Areas, pressure = Pressure,
                        walls = wall.Summary, homeAA = o.homeAA, build = build }

    local st = { threats = {}, fight = {}, logF = -1e9, labs = {}, labF = -1e9, lastF = nil, coverSince = nil,
                 pub = { frame = 0, threats = 0, uncovered = 0, uncoveredValue = 0, covered = 0 }, def = nil, back = 0, raided = 0 }

    local function Value(defID)
        local d = UnitDefs[defID]
        return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
    end

    local function UpdatePressure(frame, threats, dt)
        local _, _, _, inc = Spring.GetTeamResources(myTeamID, "metal")
        local min = math.max(C.PRESS_FLOOR, C.PRESS_SHARE * (inc or 0) * C.PRESS_S)
        for _, a in ipairs(areas) do
            local p = press[a.id] or { avg = 0, groups = 0 }
            press[a.id] = p
            local v = 0
            for _, t in ipairs(threats) do if t.area == a and t.dEco <= C.PRESS_R then v = v + t.v end end
            if dt > 0 then
                local k = math.min(1, dt / C.PRESS_TAU_S)
                p.avg = p.avg + k * (((v >= min) and 1 or 0) - p.avg)
            end
            local up = 0
            if p.avg >= C.PRESS_1 then up = 1 end
            if p.avg >= C.PRESS_2 then up = 2 end
            if p.avg >= C.PRESS_3 then up = 3 end
            local thr = { C.PRESS_1, C.PRESS_2, C.PRESS_3 }
            local g = p.groups
            if up > g then g = up
            else while g > 0 and p.avg < C.PRESS_DOWN * thr[g] do g = g - 1 end end
            if g ~= p.groups then
                Spring.Echo(string.format("[DEF] %s area %s raid pressure %.2f: %d wall(s) at full size (was %d)", Clock(frame), a.id, p.avg, g, p.groups))
                p.groups = g
            end
        end
    end

    local function RefreshLabs(frame)
        if frame - st.labF < 300 then return end
        st.labF = frame
        local out = {}
        for _, uid in ipairs(Spring.GetTeamUnits(myTeamID) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and d.isFactory then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then out[#out + 1] = { x = x, z = z } end
            end
        end
        st.labs = out
    end
    local function ProdRate()
        local _, _, _, inc = Spring.GetTeamResources(myTeamID, "metal")
        local share = WG and WG.Strategy and WG.Strategy.Share and WG.Strategy:Share() or 0.5
        return (tonumber(inc) or 0) * (tonumber(share) or 0)
    end

    -- ── the tick ───────────────────────────────────────────────────────────────
    function AD.Step(frame)
        if not (MM and MM.Ready and MM.Ready() and TM and ARMY) then return end
        if #areas == 0 then AD.Declare{ id = "main", R_MAX = C.R_MAX } end
        -- PROXY (macro side proxy_base.lua, user 2026-11-08): the forward base is one more area while it stands (its lab, nanos and con's buildings
        -- within PROXY_R of its spot)
        -- (2026-11-08 later: the spot is defended from the moment it is chosen -- the anchor is a member -- with its front facing the enemy's build
        -- power from the spot, its own threat net, Tzars on every wall and nothing reclaimed)
        local PB = WG and WG.ProxyBase
        if PB and PB.x and not st.proxy then
            st.proxy = AD.Declare{ id = "proxy", R_MAX = C.PROXY_R, anchorPoint = true, SIDE_R = C.PROXY_SIDE_R, wall = { keep = true, tzars = C.PROXY_TZARS },
                anchor = function() local p = WG.ProxyBase; if p and p.x then return p.x, p.z end; return PB.x, PB.z end,
                axis = function()
                    local p, mb = WG.ProxyBase, WG.MetalBot
                    local bp = mb and mb.enemyBP
                    if not (p and p.x and bp and bp.x) then return nil end
                    local dx, dz = bp.x - p.x, bp.z - p.z
                    local d = math.sqrt(dx * dx + dz * dz)
                    if d < 1 then return nil end
                    return dx / d, dz / d
                end }
        elseif st.proxy and PB and PB.x and st.proxyKey ~= (PB.key or 0) then
            st.proxy.Refresh(frame, true)                                   -- a new spot (the proxy was placed again)
        elseif st.proxy and not (PB and PB.x) then
            for i = #areas, 1, -1 do if areas[i] == st.proxy then table.remove(areas, i) end end
            wall.DropArea(st.proxy.id)
            Spring.Echo(string.format("[DEF] %s area proxy dropped (the proxy base is gone)", Clock(frame)))
            st.proxy = nil
        end
        st.proxyKey = PB and PB.key or 0
        for _, a in ipairs(areas) do a.Refresh(frame) end
        local dt = st.lastF and (frame - st.lastF) / 30 or 0
        st.lastF = frame
        local threats = TH.Step(frame)
        local byId = {}
        for _, t in ipairs(threats) do byId[t.id] = t end
        -- the approach map learns where the threats come from
        if dt > 0 then
            for _, a in ipairs(areas) do a.Decay(dt) end
            for _, t in ipairs(threats) do if t.area then t.area.Note(t.x, t.z, t.v, dt) end end
        end
        UpdatePressure(frame, threats, dt)
        CL.Update(frame)
        -- a new wall unit joins the walls of the area nearest to it (a Pounder from the proxy's lab stays at the proxy)
        local function NearestArea(x, z)
            local best, bd
            for _, a in ipairs(areas) do
                if a.N() > 0 then local d = a.Dist(x, z); if not bd or d < bd then best, bd = a.id, d end end
            end
            return best
        end
        for _, a in ipairs(areas) do
            local _, g = Pressure(a.id)
            wall.Sync(frame, a, g, CL.TzarsOn(), NearestArea)
        end
        build.Step(frame)

        -- what stands on each threat now
        local airMine = air.Mine(byId)
        local armyMine, back, raided = army.Mine(byId, frame)
        st.back, st.raided = st.back + back, st.raided + raided
        if back > 0 then
            Spring.Echo(string.format("[DEF] %s handback: %d borrowed unit(s) back to the army (%d raid from where they stand)", Clock(frame), back, raided))
        end
        local wallsOn = {}
        for _, a in ipairs(areas) do
            for _, w in ipairs(wall.Walls(a.id)) do
                local t = w.threat and byId[w.threat]
                if t then wallsOn[t.id] = wallsOn[t.id] or {}; table.insert(wallsOn[t.id], w) else w.threat = nil end
            end
        end
        local function Have(t)
            local h, hw, ha, hm = 0, 0, 0, 0
            for _, w in ipairs(wallsOn[t.id] or {}) do hw = hw + C.WALL_WORTH * wall.Value(w) end
            for _, u in ipairs(airMine[t.id] or {}) do ha = ha + u.v end
            for _, u in ipairs(armyMine[t.id] or {}) do hm = hm + u.v end
            h = hw + hm                                  -- (air is not value: user 2026-11-08 "air does not add to value it just goes in and stuns")
            t.hWall, t.hAir, t.hArmy = hw, ha, hm
            return h
        end

        -- too much on one threat: the army goes back first (farthest first); a second wall last
        for _, t in ipairs(threats) do
            local have = Have(t)
            if have > C.KEEP_MULT * t.need then
                local function Shed(list, release)
                    table.sort(list, function(a, b) return Dist(a.x, a.z, t.x, t.z) > Dist(b.x, b.z, t.x, t.z) end)
                    while #list > 0 and have - list[1].v >= t.need do
                        have = have - list[1].v
                        release(list[1].uid)
                        table.remove(list, 1)
                    end
                end
                Shed(armyMine[t.id] or {}, army.Release)
                local ws = wallsOn[t.id] or {}
                while #ws > 1 and have - C.WALL_WORTH * wall.Value(ws[#ws]) >= t.need do
                    have = have - C.WALL_WORTH * wall.Value(ws[#ws])
                    wall.Assign(table.remove(ws), nil)
                end
            end
        end

        -- the free units: walls on no threat, the air squad's idle units, the army's free pool
        local pool = army.Pool(function(uid) return wall.Owns(uid) or air.Owns(uid) end)
        local airFree = air.Free()
        RefreshLabs(frame)
        local prodRate = ProdRate()
        for _, t in ipairs(threats) do
            t.have = Have(t)
            local best = math.huge
            for _, u in ipairs(pool) do best = math.min(best, Dist(u.x, u.z, t.px, t.pz) / u.sp) end
            for _, u in ipairs(airFree) do best = math.min(best, Dist(u.x, u.z, t.px, t.pz) / u.sp) end
            t.slack = (best < math.huge) and (t.tThreat - best) or -9999
            -- production in time (the launch gate only): cover_defence's rule
            local tLab = math.huge
            for _, l in ipairs(st.labs) do tLab = math.min(tLab, Dist(l.x, l.z, t.px, t.pz) / C.REINF_SPEED) end
            t.prodPot = (tLab * C.REINF_SPEED <= C.PROD_R and tLab < math.huge) and prodRate * C.PROD_FRAC * math.max(0, t.tThreat - tLab) or 0
        end
        table.sort(threats, function(a, b) return a.slack < b.slack end)
        local takenP, takenA, prodUsed = {}, {}, 0
        for _, t in ipairs(threats) do
            -- 1. walls (already assigned ones re-aim at the threat's path)
            for _, w in ipairs(wallsOn[t.id] or {}) do
                local bx, bz = wall.Reach(w, t)
                if bx then w.bx, w.bz = bx, bz end
            end
            if t.have < t.need and t.area and #(wallsOn[t.id] or {}) < C.WALLS_PER_THREAT then
                local cands = {}
                for _, w in ipairs(wall.Walls(t.area.id)) do
                    if not w.threat then
                        local bx, bz, eta, v = wall.Reach(w, t)
                        if bx and v > 0 then cands[#cands + 1] = { w = w, bx = bx, bz = bz, eta = eta, v = v } end
                    end
                end
                table.sort(cands, function(a, b) return a.eta < b.eta end)
                for _, c in ipairs(cands) do
                    if t.have >= t.need or #(wallsOn[t.id] or {}) >= C.WALLS_PER_THREAT then break end
                    wall.Assign(c.w, t, c.bx, c.bz)
                    wallsOn[t.id] = wallsOn[t.id] or {}
                    table.insert(wallsOn[t.id], c.w)
                    t.have = t.have + C.WALL_WORTH * c.v
                    t.hWall = (t.hWall or 0) + C.WALL_WORTH * c.v
                end
            end
            -- 2. borrowed army, by time to the post
            if t.have < t.need then
                local cands = {}
                for i, u in ipairs(pool) do if not takenP[i] then cands[#cands + 1] = { i = i, u = u, eta = Dist(u.x, u.z, t.px, t.pz) / u.sp } end end
                table.sort(cands, function(a, b) return a.eta < b.eta end)
                for _, c in ipairs(cands) do
                    if t.have >= t.need then break end
                    takenP[c.i] = true
                    army.Take(c.u.uid, t)
                    armyMine[t.id] = armyMine[t.id] or {}
                    table.insert(armyMine[t.id], c.u)
                    t.have, t.hArmy = t.have + c.u.v, (t.hArmy or 0) + c.u.v
                end
            end
        end

        -- 3. the AIR squad (user 2026-11-08, after game 7: "make it really simple.  Just have shurikens go to stun anything within 1-2k elmos of the base ...
        -- don't do value matching with them.  Air does not add to value it just goes in and stuns/kills everything.  The same amount of units go to
        -- defend, and air goes into stun"): every air unit goes to the threat closest to the eco that is within AIR_R of it (the one it is on keeps it
        -- until AIR_R + AIR_SLACK); none in range -> they orbit home.  No AA gate, no need, no gathering.
        -- (per area, 2026-11-08 later: the proxy keeps PROXY_AIR_FRAC of the air squad; each area's air goes at its own closest threat)
        local units = air.Units()
        if st.proxy and PB and PB.labID then              -- (once its lab stands: game 1, 2026-11-08, Shurikens orbiting an empty spot 4k from the enemy died one by one)
            local total, have, cands = 0, 0, {}
            for uid, ow in pairs(units) do
                total = total + 1
                if ow.area == "proxy" then have = have + 1 elseif not ow.threat then cands[#cands + 1] = uid end
            end
            local want = math.min(total, math.max(C.PROXY_AIR_MIN, math.floor(C.PROXY_AIR_FRAC * total + 0.5)))
            local px, pz = st.proxy.Centre()
            table.sort(cands, function(a, b)
                local ax, _, az = Spring.GetUnitPosition(a)
                local bx, _, bz = Spring.GetUnitPosition(b)
                return (ax and Dist(ax, az, px, pz) or 1e9) < (bx and Dist(bx, bz, px, pz) or 1e9) end)
            local moved = 0
            for _, uid in ipairs(cands) do
                if have >= want then break end
                air.SetArea(uid, "proxy"); have, moved = have + 1, moved + 1
            end
            if moved > 0 then Spring.Echo(string.format("[DEF] %s air: %d unit(s) to the proxy (%d of %d there)", Clock(frame), moved, have, total)) end
        else
            for uid, ow in pairs(units) do if ow.area then air.SetArea(uid, nil) end end
        end
        st.airTarget = st.airTarget or {}
        local targets = {}
        for _, a in ipairs(areas) do
            local target, td
            for _, t in ipairs(threats) do
                if (t.area or areas[1]) == a then
                    local r = C.AIR_R + ((t.id == st.airTarget[a.id]) and C.AIR_SLACK or 0)
                    if t.dEco <= r and (not td or t.dEco < td) then target, td = t, t.dEco end
                end
            end
            targets[a.id] = target
        end
        for _, t in ipairs(threats) do
            local tg = targets[(t.area or areas[1] or {}).id or "main"]
            t.airWhy = (t ~= tg) and (t.dEco > C.AIR_R and "far" or "closer raid") or nil
        end
        local nAir = {}
        for uid, ow in pairs(units) do
            if ARMY.RoleOf(uid) ~= "RETREAT" then
                local target = targets[ow.area or (areas[1] and areas[1].id) or "main"]
                if target then air.Take(uid, target); nAir[target.id] = (nAir[target.id] or 0) + 1 else air.Release(uid) end
            end
        end
        for _, a in ipairs(areas) do
            local target = targets[a.id]
            if (target and target.id) ~= st.airTarget[a.id] then
                if target then Spring.Echo(string.format("[DEF] %s air (%s): %d units to #%d at %d,%d (%.0f from the eco)", Clock(frame), a.id, nAir[target.id] or 0, target.id, target.x, target.z, target.dEco))
                elseif st.airTarget[a.id] then Spring.Echo(string.format("[DEF] %s air (%s): no raid within %d of the eco, home", Clock(frame), a.id, C.AIR_R)) end
                st.airTarget[a.id] = target and target.id or nil
            end
            if target then target.nAir = nAir[target.id] or 0 end
        end
        for _, t in ipairs(threats) do                         -- production in time, for the launch gate only (slack order)
            t.prodCover = math.max(0, math.min(t.prodPot - prodUsed, t.need - t.have))
            prodUsed = prodUsed + t.prodCover
        end

        -- built cover (no production): what is on it + free units that still reach its post in time
        -- (the main area's threats only: the proxy's are in def.proxy, so a fight at the proxy does not hold the main base's launches or eco bursts)
        local margin, pMargin, pThreats, pValue = 99, 99, 0, 0
        for _, t in ipairs(threats) do
            local spare = 0
            for i, u in ipairs(pool) do if not takenP[i] and Dist(u.x, u.z, t.px, t.pz) / u.sp <= t.tThreat then spare = spare + u.v end end
            t.built = t.have + spare
            if st.proxy and t.area == st.proxy then
                pMargin, pThreats, pValue = math.min(pMargin, t.built / math.max(1, t.need)), pThreats + 1, pValue + t.v
            else
                margin = math.min(margin, t.built / math.max(1, t.need))
            end
        end

        -- modes (from every ground defender on the threat) and orders
        local acfg = army.cfg
        for _, t in ipairs(threats) do
            local defs = {}
            for _, w in ipairs(wallsOn[t.id] or {}) do for _, u in ipairs(wall.Defenders(w)) do defs[#defs + 1] = u end end
            for _, u in ipairs(armyMine[t.id] or {}) do defs[#defs + 1] = u end
            DA.Mode(t, defs, acfg)
            DA.Push(t, t.have, frame, acfg)
        end
        wall.Orders(frame, byId)
        air.Orders(frame, byId)
        for _, t in ipairs(threats) do army.Orders(frame, t, armyMine[t.id] or {}) end

        -- the published state
        local unc, uncV, cov, fight, allV = 0, 0, 0, {}, 0
        for _, t in ipairs(threats) do
            allV = allV + t.v
            t.covered = t.have + (t.prodCover or 0) >= t.need
            if t.covered then cov = cov + 1 elseif not (st.proxy and t.area == st.proxy) then unc, uncV = unc + 1, uncV + t.v end
            if t.mode == "fight" then
                fight[#fight + 1] = { x = t.x, z = t.z, n = t.n, cost = t.v, threat = t.v, gnd = t.v, air = 0, channel = "ground",
                                      speed = t.speed, vx = t.vx, vz = t.vz, stillS = t.stillS }
            end
        end
        st.threats, st.fight = threats, fight
        if #threats > 0 then st.lastThreatF = frame end
        local _, _, _, inc = Spring.GetTeamResources(myTeamID, "metal")
        if uncV >= math.max(C.HARD_FLOOR, C.HARD_SHARE * (inc or 0) * C.HARD_S) then st.lastHardF = frame end
        st.pub = { frame = frame, value = allV, threats = #threats, uncovered = unc, uncoveredValue = uncV, covered = cov,
                   lastThreatF = st.lastThreatF, lastHardF = st.lastHardF }
        -- do we need more units?
        local mb = WG and WG.MetalBot
        local ar = mb and mb.airRaid
        local airRow = CL.Get("air_ground")
        local bombers = ar and ar.frame and frame - ar.frame <= C.AIR_ALARM_S * 30 and (ar.n or 0) > 0
        local needUnits = margin < 1 or (airRow ~= nil and airRow.short and bombers == true)
        local covered = margin >= C.BURST_MARGIN and not needUnits
        if covered then st.coverSince = st.coverSince or frame else st.coverSince = nil end
        local borrowed = 0
        for _, r in pairs(responding) do if r.def then borrowed = borrowed + 1 end end
        st.def = { frame = frame, margin = margin, needUnits = needUnits, covered = covered, coverS = st.coverSince and (frame - st.coverSince) / 30 or 0,
                   threats = #threats, borrowed = borrowed, handedBack = st.back, raided = st.raided, walls = wall.Summary(), air = air.Count(),
                   checklist = CL.Rows(), homeAAWant = CL.HomeAAWant(),
                   proxy = st.proxy and { margin = pMargin, threats = pThreats, value = pValue, wallShort = (function()
                       local short = 0                              -- Pounders the proxy's walls still want (its T1 lab makes cons once this is 0)
                       for _, w in ipairs(wall.Walls(st.proxy.id)) do short = short + math.max(0, (w.want or 0) - #w.units) end
                       return short end)() } or nil }

        -- the labs: the walls' Tzars, the base AA the checklist asks for
        local LO = WG and WG.LabOrders
        if LO then
            local room = wall.TzarRoom()
            if room > 0 then
                LO.Request("defence:wall_tzar", { picks = { ROLES.Get("heavy_t2_veh") }, tier = C.TZAR_TIER, n = function() return wall.TzarRoom() end })
            end
            local extra = CL.HomeAAWant()
            if extra > 0 and o.homeAA then
                local _, n, base = o.homeAA()
                local want = (base or 0) + extra
                if (n or 0) < want then
                    LO.Request("defence:aa", { picks = { ROLES.Get("aa_flak_truck"), ROLES.Get("aa_t1_veh") }, tier = C.AA_TIER, require = false,   -- (no lab planned for it)
                        n = function() local _, n2 = o.homeAA(); return math.max(0, want - (n2 or 0)) end })
                end
            end
        end

        if frame - st.logF >= C.LOG_EVERY and #threats > 0 then
            st.logF = frame
            for _, t in ipairs(threats) do
                local g = {}
                for name, k in pairs(t.guess) do g[#g + 1] = k .. "x " .. name end
                Spring.Echo(string.format("[DEF] %s #%d at %d,%d value %.0f (%d units%s%s) -> %s %d,%d %.0f away, %.0fs | wall %.0f + air %.0f (not counted) + army %.0f = %.0f / need %.0f"
                    .. " (built %.0f%s) %s | slack %.0fs | %s",
                    Clock(frame), t.id, t.x, t.z, t.v, t.n, t.dots > 0 and (", " .. t.dots .. " radar dots as " .. table.concat(g, " ")) or "",
                    ((t.aa or 0) > 0 and string.format(", AA %.0f", t.aa) or "") .. (t.airWhy and (", no air: " .. t.airWhy) or ""),
                    t.area and t.area.id or "-", t.ex, t.ez, t.dEco, t.tThreat, t.hWall or 0, t.hAir or 0, t.hArmy or 0, t.have, t.need, t.built or 0,
                    (t.prodCover or 0) > 0 and string.format(", production %.0f", t.prodCover) or "", t.covered and "covered" or "UNCOVERED",
                    t.slack, t.mode or "-"))
            end
            Spring.Echo(string.format("[DEF] %s margin %.2f%s%s, %d borrowed, air %d", Clock(frame), math.min(margin, 99), needUnits and ", NEED UNITS" or "",
                covered and string.format(", covered %ds", math.floor(st.def.coverS)) or "", borrowed, air.Count()))
        end
        if frame - (st.scoreF or -1e9) >= 1800 then
            st.scoreF = frame
            local sc = AD.Score()
            Spring.Echo(string.format("[DEF] %s score: wall killed %.0f lost %.0f | air killed %.0f lost %.0f | army killed %.0f lost %.0f | %d borrowed now, %d handed back (%d to raid)",
                Clock(frame), sc.wall.k, sc.wall.l, sc.air.k, sc.air.l, sc.army.k, sc.army.l, borrowed, st.back, st.raided))
        end
        st.def.score = AD.Score()
    end

    function AD.Publish(frame, mb)
        mb.cover = st.pub
        mb.defence = st.def
    end
    function AD.FightGroups() return st.fight end
    -- units made by the proxy's labs belong to the proxy's walls (UnitCreated has the builder; UnitFinished, where Offer runs, does not)
    local proxyBorn = {}
    function AD.NoteCreated(uid, defID, builderID)
        local PB = WG and WG.ProxyBase
        if PB and builderID and PB.labs and PB.labs[builderID] then proxyBorn[uid] = true end
    end
    function AD.Offer(uid, defID)
        local home = proxyBorn[uid] and st.proxy and "proxy" or nil
        proxyBorn[uid] = nil
        return wall.Offer(uid, defID, home) or air.Offer(uid, defID)
    end
    -- what each squad killed and lost (metal-eq), for the [DEF] score row and mb.defence.score
    local score = { wall = { k = 0, l = 0 }, air = { k = 0, l = 0 }, army = { k = 0, l = 0 } }
    local function Squad(uid)
        if wall.Owns(uid) and not wall.Reclaiming(uid) then return "wall" end
        if air.Owns(uid) then return "air" end
        local r = responding[uid]
        if r and r.def then return "army" end
        return nil
    end
    function AD.NoteKill(attackerID, defID)
        local sq = Squad(attackerID)
        if sq then score[sq].k = score[sq].k + Value(defID) end
    end
    function AD.OnDestroyed(uid, defID)
        local sq = Squad(uid)
        if sq and defID then score[sq].l = score[sq].l + Value(defID) end
        wall.OnDestroyed(uid); air.OnDestroyed(uid)
    end
    function AD.Score() return score end
    function AD.Owns(uid)
        if wall.Owns(uid) or air.Owns(uid) then return true end
        local r = responding[uid]
        return r ~= nil and r.def == true
    end
    function AD.Engaged(uid)          -- unit_clock FAST tier: a defender on a threat
        local r = responding[uid]
        if r and r.def then return true end
        local ow = wall.Units()[uid]
        if ow and ow.w and ow.w.threat then return true end
        local oa = air.Units()[uid]
        return oa ~= nil and oa.threat ~= nil
    end
    -- the squads' own units (not the borrowed army: those stay in combatUnits), for the army value
    function AD.Units()
        local out = {}
        for uid, ow in pairs(wall.Units()) do out[uid] = ow.defID end
        for uid, ow in pairs(air.Units()) do out[uid] = ow.defID end
        return out
    end
    function AD.HomeAAWant() return CL.HomeAAWant() end
    AD.wall, AD.air, AD.army, AD.checklist, AD.build = wall, air, army, CL, build
    return AD
end

return M
