-- bar_framework/defence/air.lua  (area_defence: the air responders -- Shurikens and Wasps; Dragons later)
-- They are a standing home force (lab_rules' home-guard air).  User 2026-11-08: "Just have shurikens go to stun anything within 1-2k elmos of the base
-- ... Air does not add to value it just goes in and stuns/kills everything" -- area_defence sends them all at the threat closest to the eco within
-- AIR_R, at once (no gathering, no AA hold).  There they split their targets (Shuriken stuns, the Wasp split: defence/air_micro.lua, raid_response's
-- code), the enemy closest to our eco first.  Idle, they orbit the area's centre with MOVE.  DRAGONS (default false): a hook, not wired yet.
--
--   local AIR = VFS.Include("LuaUI/Widgets/bar_framework/defence/air.lua").New{ cfg, ARMY, UQ, EI, allyID, centre = fn(areaId) -> x, z }
--   air.SetArea(uid, areaId | nil)  air.AreaOf(uid)  (nil = the main area; the proxy keeps its share of the air: area_defence PROXY_AIR_*)
--   air.Offer(uid, defID) -> bool   air.Free() -> { unitRec }   air.Take(uid, t)   air.Release(uid)   air.Mine(byId) -> { [tid] = { unitRec } }
--   air.Orders(frame, byId)   air.OnDestroyed(uid)   air.Owns(uid)   air.Count()

local M = {}

M.CFG = {
    NAMES     = { corbw = true, corape = true },     -- Shuriken, Wasp
    DRAGONS   = false,
    ORBIT_R   = 350,
    WORTH     = 1.0,      -- (logs only: air is not counted against a threat's need)
    AA_NAMES  = { cormist = true, corsent = true, coraak = true, corcrash = true, armsam = true, armyork = true, armaak = true, armjeth = true },   -- AA first, as well as UQ.is_dedicated_aa
}

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    local ARMY, UQ = o.ARMY, o.UQ
    local CMD_MOVE = 10
    local owner = {}            -- [uid] = { defID, threat = id | nil, spare = bool (on a threat but handed back this tick) }
    local spare = {}            -- [uid] = true: handed back by AssignStuns this tick
    local A = { cfg = C }
    local AM = VFS.Include("LuaUI/Widgets/bar_framework/defence/air_micro.lua").New{
        ARMY = ARMY, UQ = UQ, EI = o.EI, allyID = o.allyID, airPack = nil, role = "DEF_AIR",     -- (no AIR_PACK: they go in at once)
        base = function() return o.centre() end,
        groupOf = function(uid) local ow = owner[uid]; return ow and A.byId and A.byId[ow.threat] or nil end }

    local function Value(defID)
        local d = UnitDefs[defID]
        return d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0
    end

    function A.Offer(uid, defID)
        local d = UnitDefs[defID]
        if d and C.NAMES[d.name] then owner[uid] = { defID = defID }; return true end
        return false
    end
    function A.Owns(uid) return owner[uid] ~= nil end
    function A.SetArea(uid, id) local ow = owner[uid]; if ow and ow.area ~= id then ow.area = id; A.Release(uid) end end
    function A.AreaOf(uid) local ow = owner[uid]; return ow and ow.area end
    function A.OnDestroyed(uid) owner[uid] = nil; AM.STUN.target[uid] = nil; AM.SPLIT_WASP.target[uid] = nil end
    function A.Count() local n = 0; for _ in pairs(owner) do n = n + 1 end; return n end
    function A.Units() return owner end

    local function Rec(uid, ow)
        local x, _, z = Spring.GetUnitPosition(uid)
        if not x then return nil end
        return { uid = uid, defID = ow.defID, x = x, z = z, v = C.WORTH * Value(ow.defID),
                 sp = math.max(1, (UQ.max_speed and UQ.max_speed(ow.defID)) or 200) }
    end

    function A.Mine(byId)
        local mine = {}
        for uid, ow in pairs(owner) do
            if not Spring.GetUnitDefID(uid) then owner[uid] = nil
            elseif ow.threat and not byId[ow.threat] then A.Release(uid)
            elseif ow.threat then
                local u = Rec(uid, ow)
                if u then mine[ow.threat] = mine[ow.threat] or {}; table.insert(mine[ow.threat], u) end
            end
        end
        return mine
    end
    function A.Free()
        local out = {}
        for uid, ow in pairs(owner) do
            if not ow.threat and ARMY.RoleOf(uid) ~= "RETREAT" then local u = Rec(uid, ow); if u then out[#out + 1] = u end end
        end
        return out
    end
    function A.Take(uid, t) if owner[uid] then owner[uid].threat = t.id end end
    -- (the RESPOND claim is released too, once: a held RESPOND duty refused the HOME_GUARD orbit, so a freed unit kept its last order and sat idle)
    local function Unclaim(uid) if ARMY.RoleOf(uid) == "DEF_AIR" then ARMY.Release(uid) end end
    function A.Release(uid)
        local ow = owner[uid]
        if ow and ow.threat then ow.threat = nil; ow.spare = nil; Unclaim(uid) end
        AM.STUN.target[uid], AM.SPLIT_WASP.target[uid] = nil, nil
    end

    function A.Orders(frame, byId)
        A.byId = byId
        local per, idle = {}, {}
        spare = {}
        for uid, ow in pairs(owner) do
            if ow.threat and byId[ow.threat] then
                local nm = (UnitDefs[ow.defID] or {}).name or ""
                local P = AM.STUN.NAMES[nm] and AM.STUN or AM.SPLIT_WASP
                local key = ow.threat .. ":" .. P.tag
                per[key] = per[key] or { t = byId[ow.threat], P = P, ids = {} }
                table.insert(per[key].ids, uid)
            else
                idle[#idle + 1] = uid
            end
        end
        for _, e in pairs(per) do
            table.sort(e.ids)
            -- the enemy closest to our eco first (user 2026-11-08: "they should prioritize things closest to the base")
            local area = e.t.area
            local rank = area and function(eid)
                local x, _, z = Spring.GetUnitPosition(eid)
                return x and area.Dist(x, z) or 1e9
            end or nil
            -- user 2026-11-08: their AA first ("I saw them target gators before lasher"); stunned = EMP at max health (or the engine says so); one
            -- Shuriken stays on a stunned unit and the rest are handed back (they orbit home until something there needs a stun)
            AM.AssignStuns(frame, e.ids, e.P, e.t.x, e.t.z, { rank = rank, aaFirst = true, aaNames = C.AA_NAMES, stunCheck = true,
                spares = function(uid)
                    local ow = owner[uid]
                    if ow and not ow.spare then ow.spare = true; Unclaim(uid) end
                    spare[uid] = true
                end })
        end
        for uid, ow in pairs(owner) do
            if ow.spare and not spare[uid] then ow.spare = nil end                 -- given a target again this tick
            if spare[uid] then idle[#idle + 1] = uid end
        end
        local byArea = {}
        for _, uid in ipairs(idle) do
            local k = (owner[uid] and owner[uid].area) or "main"
            byArea[k] = byArea[k] or {}
            table.insert(byArea[k], uid)
        end
        for k, list in pairs(byArea) do
            local cx, cz = o.centre(k ~= "main" and k or nil)
            if cx then
                table.sort(list)
                for i, uid in ipairs(list) do
                    local a, r = i * 2.4, C.ORBIT_R * math.sqrt(i / math.max(1, #list))
                    -- MOVE, not FIGHT (game 4, 2026-11-08: idle Shurikens on a FIGHT orbit flew at whatever came near the base -- 138 lost to flak trucks, 0 kills);
                    -- they fight only when area_defence gives them a threat
                    ARMY.Claim(ARMY.PRIO.HOME_GUARD, uid, { role = "DEF_AIR", cmd = CMD_MOVE, x = cx + math.cos(a) * r, z = cz + math.sin(a) * r }, frame)
                end
            end
        end
    end

    return A
end

return M
