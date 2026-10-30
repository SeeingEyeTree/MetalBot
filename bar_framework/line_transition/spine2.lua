-- bar_framework/line_transition/spine2.lua
-- SECOND_SPINE (user 2026-10-27: "have cons that finish building their rows in the line start a second spine; build power in two places
-- prevents a critical failure if one dies" -- the replay was won until the only spine died and nothing could be spent on army).
--
-- WHEN   a line con finishes its lane (line_crew onLaneDone -> LT.OnLaneDone) and the first spine stands; not before SPINE2_MIN_FRAME.
--        Up to SPINE2_CONS such cons leave the line crew for the second spine (con_broker owner "spine2").
-- WHAT   a second instance of slot_spine.lua (the file runs fresh on every VFS.Include, so it has its own state), started on the enemy side
--        SPINE2_OFFSET elmos along the line from the first (grids keep off the enemy side, so nothing is there).  Its CFG is the first
--        spine's plus SPINE2_CFG.  It builds its own blocks and labs from the cons it was given.
-- SPLIT  each spine plans with its own part of the income (Spine2Split): SPINE2_FRAC / 1 - SPINE2_FRAC while both stand; the one that stands
--        alone plans with all of it, the dead one keeps SPINE2_FRAC so it can rebuild.
-- VIEW   WG.Spine becomes spine_set.lua (lab questions go to the owning spine, SetUnits / SetShare to both) and the strategy is re-installed on it.
-- Options read (LT.CFG): SECOND_SPINE SPINE2_CONS SPINE2_MIN_FRAME SPINE2_OFFSET SPINE2_FRAC SPINE2_CFG
-- Part of line_transition (bar_framework/line_transition.lua installs it).

local M = {}
local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")
local LEDGER = VFS.Include("LuaUI/Widgets/bar_framework/eco_ledger.lua")

function M.Install(X)
    local CB, Clock = X.CB, X.Clock

    -- does a spine stand (a lab or a nano of it is alive)?
    local function Standing(mod)
        local S = mod and mod.State and mod.State()
        if not S then return false end
        for uid in pairs(S.labs) do if Spring.GetUnitDefID(uid) then return true end end
        for uid in pairs(S.nanos) do if Spring.GetUnitDefID(uid) then return true end end
        return false
    end

    local function Scaled(res, w)
        local r = {}
        for k, v in pairs(res) do r[k] = v end
        r.metalIncome = (res.metalIncome or 0) * w
        if res.metalIncomeS then r.metalIncomeS = res.metalIncomeS * w end
        return r
    end

    -- the resources each spine plans with: (first, second or nil)
    X.Spine2Split = function(T, res)
        if not (T.spine2On and res) then return res, nil end
        local f2 = T.CFG.SPINE2_FRAC
        local a1, a2 = Standing(T.spineMod), Standing(T.spine2Mod)
        local w1, w2 = 1 - f2, f2
        if a1 and not a2 then w1 = 1 elseif a2 and not a1 then w2 = 1 end
        T.spineShare = { w1, w2 }
        return Scaled(res, w1), Scaled(res, w2)
    end

    X.Spine2LaneDone = function(T, laneID, conID)
        if not T.CFG.SECOND_SPINE then return end
        T.spine2Offers = T.spine2Offers or {}
        T.spine2Offers[#T.spine2Offers + 1] = { lane = laneID, id = conID }
    end

    local function Start(T, frame)
        local C, mod1 = T.CFG, T.spineMod
        if T.spine2On or T.spine2Failed or not (mod1 and T.spineBPs and T.spineBPs.T1) then return false end
        local mod2 = VFS.Include("LuaUI/Widgets/bar_framework/slot_spine.lua")
        for k, v in pairs(mod1.CFG) do mod2.CFG[k] = v end
        local ground = {}                                                -- ground labs only: no air cons for an air plant
        for _, name in ipairs(mod1.CFG.LAB_CANDIDATES or {}) do
            local d, air = UnitDefNames[name], false
            for _, o in ipairs(d and d.buildOptions or {}) do if UnitDefs[o] and UnitDefs[o].canFly then air = true end end
            if d and not air then ground[#ground + 1] = name end
        end
        mod2.CFG.LAB_CANDIDATES = ground
        for k, v in pairs(C.SPINE2_CFG or {}) do mod2.CFG[k] = v end
        -- candidate sites: the far side of the line first (SPINE2_SIDE "away": nearest to the line's middle first), then the enemy side beside the first spine
        local function Clear(g)
            local n2 = math.min(mod2.CFG.MAX_BLOCKS, 2 * mod2.CFG.STACK_HALF + 1)
            for n = 1, n2 do                                             -- every block it may open must clear the first spine's blocks and every grid
                local ax, az = mod2.CellAnchor(g.geo, g.baseX, g.baseZ, n)
                if T.OverlapsSpine(T, ax, az) then return false end
                for _, list in ipairs({ T.allAnchors or {}, T.pendingGrids or {}, T.gridCands or {} }) do
                    for _, a in ipairs(list) do
                        if a.anchorX and (a.anchorX - ax) ^ 2 + (a.anchorZ - az) ^ 2 < 600 ^ 2 then return false end
                    end
                end
            end
            return true
        end
        local best, bestD, behind
        if C.SPINE2_SIDE == "away" then
            for _, f in ipairs({ 0, 1 / 3, -1 / 3, 2 / 3, -2 / 3, 1, -1 }) do
                local g = X.SpineGeo(T, f * C.SPINE2_OFFSET, true)
                if g and Clear(g) then best, behind = g, true; break end
            end
        end
        if not best then
            for _, sgn in ipairs({ 1, -1 }) do
                local g = X.SpineGeo(T, sgn * C.SPINE2_OFFSET)
                if g and Clear(g) then
                    local ax, az = mod2.CellAnchor(g.geo, g.baseX, g.baseZ, 1)
                    local d = (ax - T.L.mapX / 2) ^ 2 + (az - T.L.mapZ / 2) ^ 2
                    if not bestD or d < bestD then best, bestD = g, d end
                end
            end
        end
        if not best then
            T.spine2Failed = true
            Spring.Echo("[LT] " .. Clock(frame) .. " second spine: no room; off")
            return false
        end
        for n = 1, 2 * mod2.CFG.STACK_HALF + 1 do
            local ax, az = mod2.CellAnchor(best.geo, best.baseX, best.baseZ, n)
            local lx, lz = mod2.LaneAnchor(best.geo, best.baseX, best.baseZ, n)
            T.spineBoxes[#T.spineBoxes + 1] = { x = ax, z = az }
            T.spineBoxes[#T.spineBoxes + 1] = { x = lx, z = lz }
        end
        local env = X.SpineEnv(T, best)
        env.logTag = "2"                                                 -- its log rows are [SLOT2]
        env.Expect = {}                                                  -- no host lab to wait for: it places its own
        env.TakeCon, env.ReturnCon, env.QueueAirCon = function() return nil end, function() end, function() end   -- ground only, no air cons
        mod2.Init(env)
        mod2.Start(frame)
        T.spine2Mod, T.spine2On = mod2, true
        local set = VFS.Include("LuaUI/Widgets/bar_framework/spine_set.lua").New(mod1, mod2)
        T.spineSet = set
        if T.WG then
            CH.Publish(T.WG, "Spine", set)
            local ST = T.WG.Strategy
            if ST and ST.InstallSlotSpine then ST:InstallSlotSpine(set) end
        end
        LEDGER.Register(T.WG, "spine", { capacity = function() return (set.SpendCapacity()) end })
        CB.AddPool(T.CB, "spine2-ground", {
            take  = function(owner, req) return mod2.PoolTake(owner, req) end,
            give  = function(uid, owner) mod2.PoolGive(uid, owner) end,
            count = function() return mod2.PoolCount() end })
        local c1x, c1z = mod2.CellAnchor(best.geo, best.baseX, best.baseZ, 1)
        Spring.Echo(string.format("[LT] %s SECOND SPINE (%s): cell 1 at (%d, %d), front (%d, %d)", Clock(frame), behind and "behind the line" or "enemy side", c1x, c1z, best.geo.dx, best.geo.dz))
        return true
    end

    -- every 30 frames: hand finished line cons to the second spine
    X.UpdateSpine2 = function(T, frame)
        local C = T.CFG
        if not C.SECOND_SPINE or frame % 30 ~= 0 or not T.spineOn or frame < C.SPINE2_MIN_FRAME then return end
        local offers = T.spine2Offers
        if not offers or #offers == 0 or T.spine2Failed then return end
        T.spine2Taken = T.spine2Taken or 0
        local keep = {}
        for _, o in ipairs(offers) do
            local id = o.id
            if not Spring.GetUnitDefID(id) or not T.LC.IsBuilder(T.crew, id) or T.crew.cmdr == id then
                -- gone, or no longer a line builder: forget the offer
            elseif T.spine2Taken >= C.SPINE2_CONS or T.spine2Failed then
                -- enough cons
            elseif not T.spine2On and not Start(T, frame) then
                -- no room: nothing to give it to
            else
                T.LC.Release(T.crew, id)
                CB.Release(T.CB, id, true)
                CB.Claim(T.CB, id, "spine2")
                T.spine2Mod.AdoptCon(id)
                T.spine2Taken = T.spine2Taken + 1
                Spring.Echo(string.format("[LT] %s second spine: con %d finished lane %d and joins it (%d of %d)", Clock(frame), id, o.lane, T.spine2Taken, C.SPINE2_CONS))
            end
        end
        T.spine2Offers = keep
    end
end

return M
