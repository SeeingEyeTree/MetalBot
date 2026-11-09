-- bar_framework/defence/air_micro.lua  (Shuriken stuns, the Wasp split and AIR_PACK, moved out of raid_response.lua on 2026-11-08 unchanged)
-- raid_response answers raids with them; area_defence's air squad (defence/air.lua) uses the same code.
--
--   local AM = VFS.Include("LuaUI/Widgets/bar_framework/defence/air_micro.lua").New{
--       ARMY, UQ, EI, allyID, airPack = cfg.AIR_PACK (or nil), base = function() return x, z end,
--       groupOf = function(uid) return g end, role = "RESPOND" }   -- the group a unit answers (its fallback FIGHT point when nothing is near)
--   AM.STUN, AM.SPLIT_WASP                             -- the two splits (NAMES, R, HP_PER, NEED_*, target = { [uid] = enemy })
--   AM.AirPack(frame, ids, P, g) -> true when it gave the orders (hold at the rally, or focus fire on enemy AA)
--   AM.AssignStuns(frame, ids, P, cx, cz, opts)        -- one ATTACK target per unit.  opts (area_defence's air squad; raid_response passes none):
--       rank(eid) -> number   the targets with the lowest rank first (the distance to our eco: closest to the base first)
--       aaFirst               enemy AA (dedicated AA, + aaNames) before anything else (user 2026-11-08: "I saw them target gators before lasher")
--       stunCheck             a target is stunned when Spring.GetUnitIsStunned says so or its EMP (paralyze damage) is at its max health
--       spares(uid)           a unit left with no target -- every target stunned and kept by one Shuriken -- is handed back through this

local M = {}

function M.New(o)
    local ARMY, UQ = o.ARMY, o.UQ
    local ROLE = o.role or "RESPOND"         -- the army_broker role of the claims (area_defence: "DEF_AIR")
    local myAllyID = o.allyID
    local spGetUnitDefID, spGetUnitPosition = Spring.GetUnitDefID, Spring.GetUnitPosition
    local spGetUnitHealth, spGetUnitAllyTeam = Spring.GetUnitHealth, Spring.GetUnitAllyTeam
    local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
    local CMD_FIGHT = (CMD and CMD.FIGHT) or 16
    local CMD_MOVE_ = (CMD and CMD.MOVE) or 10
    local CMD_ATTACK_ = (CMD and CMD.ATTACK) or 20
    local AM = {}

    -- LINE_CLICK_v13 (user): Shuriken micro.  ~30 Shurikens all stunned the SAME unit.  Their weapon paralyses: stun a
    -- unit, leave ONE on it to keep it stunned, and send the rest to the next enemy that is still moving.  Each responding
    -- Shuriken gets an ATTACK on its own target: an unstunned target gets NEED Shurikens (2-6 by its health), a stunned
    -- one keeps a single keeper; the rest spread over the unstunned targets.  Assignments stick while they still fit.
    local STUN = { NAMES = { corbw = true }, R = 1200, HP_PER = 700, NEED_MIN = 2, NEED_MAX = 6, LOG_EVERY = 900,
             STUNS = true, tag = "stun", target = {}, logF = -1e9 }
    -- LINE_CLICK_v16 (user): the same split for Wasps.  No stun, so every target counts as still moving: NEED Wasps by its
    -- health, the spare spread round-robin over the targets.
    local SPLIT_WASP = { NAMES = { corape = true }, R = 1500, HP_PER = 900, NEED_MIN = 1, NEED_MAX = 8, LOG_EVERY = 900,
                   tag = "wasp", target = {}, logF = -1e9 }
    AM.STUN, AM.SPLIT_WASP = STUN, SPLIT_WASP

    -- AIR_PACK: Shurikens / Wasps answering a group fly together and shoot the AA first.  Returns true when it gave the orders (hold or AA focus fire)
    local PACK = {}
    function AM.AirPack(frame, ids, P, g)
        local A = o.airPack
        local baseX, baseZ = o.base()
        if not (A and g and baseX) then return false end
        local st = PACK[P.tag]
        if not st or frame - st.last > 900 then st = { since = frame, go = false }; PACK[P.tag] = st end
        st.last = frame
        local v = 0
        for _, uid in ipairs(ids) do
            local d = UnitDefs[spGetUnitDefID(uid) or -1]
            v = v + (d and ((d.metalCost or 0) + (d.energyCost or 0) / 70) or 0)
        end
        local aa, aaV = {}, 0
        local E = o.EI
        if E and E.Records then
            local r2 = (A.AA_R or 900) ^ 2
            for _, rec in pairs(E.Records()) do
                local c = rec.c
                if c and c.hitsAir and not c.air then
                    if frame - (rec.frame or -1e9) <= 1800 and (rec.x - g.x) ^ 2 + (rec.z - g.z) ^ 2 <= r2 then
                        aa[#aa + 1] = rec
                        aaV = aaV + (c.value or 0)
                    end
                end
            end
        end
        local waited = frame - st.since
        local strong = aaV <= 0 or v >= (A.AA_RATIO or 1.5) * aaV
        if not st.go then
            local ready = (#ids >= (A.MIN or 6) and strong) or waited >= ((aaV > 0 and not strong) and (A.AA_WAIT_S or 40) or (A.WAIT_S or 20)) * 30
            if ready then st.go = true end
        end
        if not st.go then
            local f = A.RALLY or 0.2
            local rx, rz = baseX + (g.x - baseX) * f, baseZ + (g.z - baseZ) * f
            for _, uid in ipairs(ids) do
                P.target[uid] = nil
                ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = ROLE, cmd = CMD_MOVE_, x = rx, z = rz }, frame)
            end
            return true
        end
        if #aa > 0 and strong then        -- focus fire on the AA, the one nearest the pack first
            local sx, sz, n = 0, 0, 0
            for _, uid in ipairs(ids) do
                local x, _, z = spGetUnitPosition(uid)
                if x then sx, sz, n = sx + x, sz + z, n + 1 end
            end
            if n > 0 then
                sx, sz = sx / n, sz / n
                local best, bd
                for _, rec in ipairs(aa) do
                    if spGetUnitDefID(rec.uid) then
                        local d = (rec.x - sx) ^ 2 + (rec.z - sz) ^ 2
                        if not bd or d < bd then best, bd = rec, d end
                    end
                end
                if best then
                    for _, uid in ipairs(ids) do
                        P.target[uid] = best.uid
                        ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = ROLE, cmd = CMD_ATTACK_, targetID = best.uid }, frame)
                    end
                    return true
                end
            end
        end
        return false
    end

    function AM.AssignStuns(frame, ids, P, cx, cz, opts)
        opts = opts or {}
        local rank = opts.rank
        P = P or STUN
        local stunTarget = P.target
        if #ids == 0 then return end
        -- the enemies near the stunners: mobile, visible, not dead
        local sx, sz = 0, 0
        for _, uid in ipairs(ids) do
            local x, _, z = spGetUnitPosition(uid)
            if x then sx, sz = sx + x, sz + z end
        end
        sx, sz = sx / #ids, sz / #ids
        -- a raid group's own spot: the pack looks for targets there, not at the middle of packs on different sides
        if cx then sx, sz = cx, cz end
        local targets, byId = {}, {}
        for _, eid in ipairs(spGetUnitsInCylinder(sx, sz, P.R) or {}) do
            local defID = spGetUnitDefID(eid)
            if defID and spGetUnitAllyTeam(eid) ~= myAllyID and UQ.is_mobile(defID) then
                local hp, mhp, para = spGetUnitHealth(eid)
                if hp and mhp and mhp > 0 then
                    local ud = UnitDefs[defID]
                    local v = ud and ((ud.metalCost or 0) + (ud.energyCost or 0) / 70) or 0
                    local stunned = P.STUNS and (para or 0) > mhp or false
                    if P.STUNS and opts.stunCheck then
                        stunned = (Spring.GetUnitIsStunned and Spring.GetUnitIsStunned(eid)) or (para or 0) >= mhp
                        stunned = stunned and true or false
                    end
                    local aa = opts.aaFirst and ((UQ.is_dedicated_aa and UQ.is_dedicated_aa(defID)) or (opts.aaNames and opts.aaNames[ud.name])) and true or false
                    local t = { id = eid, stunned = stunned, mhp = mhp, v = v, have = {}, r = rank and rank(eid) or nil, aa = aa }
                    if P.STUNS then
                        t.need = t.stunned and 1 or math.max(P.NEED_MIN, math.min(P.NEED_MAX, math.ceil(mhp / P.HP_PER)))
                    else
                        -- damage dealers: enough to kill what is LEFT of it (current health), then they move on
                        t.need = math.max(P.NEED_MIN, math.min(P.NEED_MAX, math.ceil(hp / P.HP_PER)))
                        t.score = v / t.need            -- value killed per Wasp committed
                    end
                    targets[#targets + 1] = t
                    byId[eid] = t
                end
            end
        end
        if #targets == 0 then      -- nothing to stun near them yet: fly at the intruders like everyone else
            for _, uid in ipairs(ids) do
                stunTarget[uid] = nil
                local g = o.groupOf(uid)
                if g then ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = ROLE, cmd = CMD_FIGHT, x = g.x, z = g.z }, frame) end
            end
            return
        end
        -- unstunned (still moving) first, then the most valuable
        table.sort(targets, function(a, b)
            if a.stunned ~= b.stunned then return not a.stunned end
            if a.aa ~= b.aa then return a.aa end                            -- (aaFirst: their AA first)
            if a.r and b.r and a.r ~= b.r then return a.r < b.r end       -- (rank: the closest to our base first)
            if a.score and b.score and a.score ~= b.score then return a.score > b.score end
            return a.v > b.v
        end)
        -- keep sticky assignments that still fit
        local free = {}
        for _, uid in ipairs(ids) do
            local t = byId[stunTarget[uid] or -1]
            if t and #t.have < t.need then t.have[#t.have + 1] = uid else free[#free + 1] = uid end
        end
        -- fill what is still needed, nearest stunner first
        for _, t in ipairs(targets) do
            if #free == 0 then break end
            local tx, _, tz = spGetUnitPosition(t.id)
            while #t.have < t.need and #free > 0 and tx do
                local bi, bd
                for i, uid in ipairs(free) do
                    local x, _, z = spGetUnitPosition(uid)
                    local d = x and ((x - tx) ^ 2 + (z - tz) ^ 2) or math.huge
                    if not bd or d < bd then bi, bd = i, d end
                end
                t.have[#t.have + 1] = table.remove(free, bi)
            end
        end
        -- spare stunners: round-robin over the unstunned targets (never pile onto a stunned one)
        local moving = {}
        for _, t in ipairs(targets) do if not t.stunned then moving[#moving + 1] = t end end
        local k = 0
        -- damage dealers pile the spare onto the best few kills (overkill only wastes seconds); stunners spread out
        if not P.STUNS then while #moving > 3 do table.remove(moving) end end
        while #free > 0 and #moving > 0 do
            k = k % #moving + 1
            local t = moving[k]
            t.have[#t.have + 1] = table.remove(free, 1)
        end
        -- spares: every target is stunned and has its keeper -- the rest go back (opts.spares), not onto a stunned unit
        if opts.spares then
            for _, uid in ipairs(free) do stunTarget[uid] = nil; opts.spares(uid) end
        end
        local nStun, nMove = 0, 0
        for _, t in ipairs(targets) do
            for _, uid in ipairs(t.have) do
                stunTarget[uid] = t.id
                ARMY.Claim(ARMY.PRIO.RESPOND, uid, { role = ROLE, cmd = CMD_ATTACK_, targetID = t.id }, frame)
            end
            if t.stunned then nStun = nStun + 1 else nMove = nMove + 1 end
        end
        if frame - P.logF >= P.LOG_EVERY then
            P.logF = frame
            local sec = math.floor(frame / 30)
            Spring.Echo(string.format("[UC/%s] %d:%02d %d units on %d targets (%d stunned, %d still moving)%s",
                P.tag, math.floor(sec / 60), sec % 60, #ids, #targets, nStun, nMove, (opts.spares and #free > 0) and (", " .. #free .. " handed back") or ""))
        end
    end

    return AM
end

return M
