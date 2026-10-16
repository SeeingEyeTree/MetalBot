-- bar_framework/dragon_lab.lua   (DRAGON_ECO, user 2026-10-14)
-- The Dragon lab(s): T2 air labs (coraap) in open ground in front of the slot spine that make Dragons forever.
-- From DRAGON_LAB_INCOME one T1 air con (the con broker's "dragonlab" job) places the frame; up to DRAGON_LAB_HELPERS free air cons
-- repair it while it is a frame; further labs are added while the metal bank keeps floating (DRAGON_FLOAT_*), up to DRAGON_LAB_MAX.
-- Published as WG.DragonLabs = { [id] = {id, x, z, ready, decoys} } (finished labs) and WG.DragonLab = the first of them; the lab
-- controller makes Dragons and decoy commanders there, the unit controller's Dragons wait in front of the first one.
-- line_transition never orders T2 cons from a Dragon lab (trans.noConLabs).
--eacape the system fast
-- USAGE (macro_controller)
--   local DLB = VFS.Include("LuaUI/Widgets/bar_framework/dragon_lab.lua")
--   DLB.Init{ cfg = CFG, CB = con_broker, SPINE = function() return SPINE end, trans = function() return trans end,
--             teamID = myTeamID, Clock = Clock }
--   DLB.Update(frame, res)   (every frame; acts every 30)   DLB.OnCreated(uid, defID, builderID, frame)   DLB.OnFinished(uid, frame)
--   DLB.OnDestroyed(uid, attackerID, attackerDefID, frame) (logging)
-- Log rows "[DL]".  Tests: tests/test_dragon_eco_bot.lua (the whole macro), tests/test_dragon_lab.lua.

local M = {}
local CH = VFS.Include("LuaUI/Widgets/bar_framework/wg_channels.lua")   -- typed WG access (bar_framework/wg_channels.lua)

M.CFG = {
    DRAGON_LAB_INCOME   = 2000,      -- smoothed metal income (m/s) that starts the first lab
    DRAGON_LAB_FRONT    = 700,       -- elmos past the spine's front-most block
    DRAGON_LAB_HELPERS  = 6,         -- free air cons (any tier) that assist the one T1 air con that places it (55 BP alone: ~10 min)
    DRAGON_LAB_TIMEOUT  = 150 * 30,  -- frames for the frame to appear before the site is given up
    DRAGON_LAB_MAX      = 10,
    DRAGON_FLOAT_FRAC   = 0.10,      -- one more lab while the metal bank has held max(DRAGON_FLOAT_MIN, FRAC x storage) ...
    DRAGON_FLOAT_MIN    = 3000,
    DRAGON_FLOAT_FRAMES = 20 * 30,   -- ... for this long
}

local Spring, UnitDefs, UnitDefNames, WG, Game, CMD = Spring, UnitDefs, UnitDefNames, WG, Game, CMD
local spGetUnitDefID    = Spring.GetUnitDefID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local CMD_REPAIR = (CMD and CMD.REPAIR) or 40

local E, K, CB = nil, M.CFG, nil
local DL = { tries = 0, helpers = {}, done = {}, nDone = 0 }
M.State = DL

local function Clock(frame) return E.Clock and E.Clock(frame) or string.format("%d:%02d", math.floor(frame / 1800), math.floor(frame / 30) % 60) end

function M.Init(env)
    E = env
    K = {}
    for k, v in pairs(M.CFG) do K[k] = (env.cfg and env.cfg[k] ~= nil) and env.cfg[k] or v end
    CB = env.CB
    DL = { tries = 0, helpers = {}, done = {}, nDone = 0 }
    M.State = DL
end

local function DragonLabSite()
    local geo, blocks = nil, nil
    local SPINE = E.SPINE()
    if SPINE and SPINE.Front then geo, blocks = SPINE.Front() end
    local d = UnitDefNames.coraap
    if not geo or not d or not blocks or #blocks == 0 then return nil end
    local mx, mz, front = 0, 0, -1e18
    for _, b in ipairs(blocks) do mx, mz = mx + b.x / #blocks, mz + b.z / #blocks end
    for _, b in ipairs(blocks) do front = math.max(front, (b.x - mx) * geo.dx + (b.z - mz) * geo.dz) end
    local cx, cz = mx + geo.dx * (front + K.DRAGON_LAB_FRONT), mz + geo.dz * (front + K.DRAGON_LAB_FRONT)
    local mapX, mapZ = (Game and Game.mapSizeX) or 8192, (Game and Game.mapSizeZ) or 8192
    for r = 0, 1200, 96 do
        local n = r == 0 and 1 or math.floor(2 * math.pi * r / 96)
        for k = 0, n - 1 do
            local a = 2 * math.pi * k / n
            local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
            x, z = math.floor(x / 16) * 16 + 8, math.floor(z / 16) * 16 + 8
            if x > 200 and z > 200 and x < mapX - 200 and z < mapZ - 200 then
                local y = Spring.GetGroundHeight(x, z) or 0
                -- the footprint must be buildable and no structure of ours within 260 (open ground, not the edge of a grid)
                local ok = Spring.TestBuildOrder(d.id, x, y, z, geo.facing or 0)
                if ok and ok > 0 then
                    local clear = true
                    for _, uid in ipairs(Spring.GetUnitsInCylinder(x, z, 260, E.teamID) or {}) do
                        local ud = UnitDefs[spGetUnitDefID(uid) or -1]
                        if ud and (ud.speed or 0) == 0 then clear = false; break end
                    end
                    if clear then return x, y, z, geo.facing or 0 end
                end
            end
        end
    end
    return nil
end

local function ReleaseDragonCons()
    local trans = E.trans()
    if not (trans and trans.CB and CB) then return end
    if DL.con then CB.Release(trans.CB, DL.con, false) end
    for id in pairs(DL.helpers) do CB.Release(trans.CB, id, true) end
    DL.con, DL.helpers = nil, {}
end

-- DRAGON_ECO (user 2026-10-14): at the switch to the T2 stance, the line's con bots (T1 bot cons: they can build coralab) leave

local function PublishDragonLabs()
    if not WG then return end
    local ids = {}
    for id in pairs(DL.done) do ids[#ids + 1] = id end
    table.sort(ids)
    if not WG.DragonLabs then CH.Publish(WG, "DragonLabs", {}) end
    for id in pairs(WG.DragonLabs) do if not DL.done[id] then WG.DragonLabs[id] = nil end end
    for _, id in ipairs(ids) do
        local L = DL.done[id]
        WG.DragonLabs[id] = WG.DragonLabs[id] or { id = id, x = L.x, z = L.z, ready = true, decoys = {} }
    end
    CH.Publish(WG, "DragonLab", ids[1] and WG.DragonLabs[ids[1]] or nil)
end


local function WantDragonLab(frame, res)
    if DL.nDone == 0 then return res.metalIncomeS >= K.DRAGON_LAB_INCOME end
    if DL.nDone >= K.DRAGON_LAB_MAX then return false end
    local floating = res.metal >= math.max(K.DRAGON_FLOAT_MIN, K.DRAGON_FLOAT_FRAC * res.metalStorage)
    if not floating then DL.floatSince = nil; return false end
    DL.floatSince = DL.floatSince or frame
    return frame - DL.floatSince >= K.DRAGON_FLOAT_FRAMES
end

function M.Update(frame, res)
    local trans = E.trans()
    if not (trans and trans.CB and CB) or frame % 30 ~= 0 then return end
    local cb = trans.CB
    -- finished labs that died
    for id in pairs(DL.done) do
        if not spGetUnitDefID(id) then
            DL.done[id], DL.nDone = nil, DL.nDone - 1
            if trans.noConLabs then trans.noConLabs[id] = nil end
            Spring.Echo(string.format("[DL] %s Dragon lab %d lost (%d left)", Clock(frame), id, DL.nDone))
            PublishDragonLabs()
        end
    end
    if DL.id and spGetUnitDefID(DL.id) then
        if not DL.ready then
            -- the con and the helpers keep building the frame: an unfinished frame nobody builds decays.  Any of them that has
            -- gone idle (or was given something else) is told to repair it again.
            local function KeepBuilding(id)
                if not (id and spGetUnitDefID(id)) then return end
                local q = Spring.GetUnitCommands(id, 1)
                local c = q and q[1]
                if not c or not ((c.id == CMD_REPAIR and c.params and c.params[1] == DL.id) or c.id == -UnitDefNames.coraap.id) then
                    spGiveOrderToUnit(id, CMD_REPAIR, { DL.id }, {})
                    DL.retold = (DL.retold or 0) + 1
                end
            end
            KeepBuilding(DL.con)
            for id in pairs(DL.helpers) do KeepBuilding(id) end
            if frame % 900 == 0 then
                local _, prog = Spring.GetUnitIsBeingBuilt(DL.id)
                local nh = 0
                for id in pairs(DL.helpers) do if spGetUnitDefID(id) then nh = nh + 1 end end
                Spring.Echo(string.format("[DL] %s Dragon lab frame %d: %.0f%% built, %d helpers, re-told %d times",
                    Clock(frame), DL.id, 100 * (prog or 0), nh, DL.retold or 0))
            end
            -- helpers: free air cons repair the frame until it finishes
            local n = 0
            for id in pairs(DL.helpers) do if spGetUnitDefID(id) then n = n + 1 else DL.helpers[id] = nil end end
            if n < K.DRAGON_LAB_HELPERS then
                -- any air con, free first, else one from a lower-priority helper job (the frame alone took ~4 min in eco_sim)
                local id = CB.Take(cb, "dragonlab", { kind = "air", near = { DL.x, DL.z }, useReserve = true, preempt = true })
                if id then
                    DL.helpers[id] = true
                    spGiveOrderToUnit(id, CMD_REPAIR, { DL.id }, {})
                end
            end
        end
        return
    end
    if DL.id then          -- the lab (or its frame) died: start over
        Spring.Echo(string.format("[DL] %s Dragon lab %d lost", Clock(frame), DL.id))
        if trans.noConLabs then trans.noConLabs[DL.id] = nil end
        ReleaseDragonCons()
        DL.id, DL.ready, DL.since, DL.site = nil, nil, nil, nil
    end
    if DL.con and not spGetUnitDefID(DL.con) then DL.con = nil end
    if not DL.con then
        if DL.tries >= 6 or not (DL.site or WantDragonLab(frame, res)) then return end
        local x, y, z, facing
        if DL.site then x, y, z, facing = DL.site.x, DL.site.y, DL.site.z, DL.site.facing     -- found once, kept while waiting
        else x, y, z, facing = DragonLabSite() end
        if not x then
            if not DL.noSite then DL.noSite = true; Spring.Echo(string.format("[DL] %s no site for the Dragon lab", Clock(frame))) end
            return
        end
        -- the con comes from the con broker's "dragonlab" job (registered below): a free T1 air con, else one taken from a
        -- lower-priority job, else the labs make one (an unmet job want counts in line_transition's air con shortfall)
        if not DL.site then
            DL.site = { x = x, y = y, z = z, facing = facing }
            Spring.Echo(string.format("[DL] %s site (%d, %d) for Dragon lab #%d: waiting for a T1 air con (income %.0f, bank %.0f / %.0f, try %d)",
                Clock(frame), x, z, DL.nDone + 1, res.metalIncomeS, res.metal, res.metalStorage, DL.tries + 1))
        end
        if not DL.job then
            DL.job = true
            CB.AddJob(cb, { name = "dragonlab", section = "dragon", prio = 95, tier = "t1", useReserve = true,
                want = function() return (DL.site and not DL.con and not DL.id) and 1 or 0 end,
                near = function() if DL.site then return DL.site.x, DL.site.z end end,
                start = function(id, f)
                    local st = DL.site
                    if not st then return false end
                    DL.con, DL.x, DL.y, DL.z, DL.facing, DL.since, DL.tries = id, st.x, st.y, st.z, st.facing, f, DL.tries + 1
                    spGiveOrderToUnit(id, -UnitDefNames.coraap.id, { st.x, st.y, st.z, st.facing }, {})
                    Spring.Echo(string.format("[DL] %s con %d places the Dragon lab at (%d, %d)", Clock(f), id, st.x, st.z))
                    return true
                end })
        end
        return
    end
    -- waiting for the frame: re-send if the con went idle, give the site up after DRAGON_LAB_TIMEOUT
    if frame - DL.since > K.DRAGON_LAB_TIMEOUT then
        Spring.Echo(string.format("[DL] %s site (%d, %d) timed out", Clock(frame), DL.x, DL.z))
        ReleaseDragonCons()
        DL.site = nil
        return
    end
    local q = Spring.GetUnitCommands(DL.con, 1)
    if (not q or #q == 0) and frame - DL.since > 90 then
        spGiveOrderToUnit(DL.con, -UnitDefNames.coraap.id, { DL.x, DL.y, DL.z, DL.facing }, {})
    end
end

function M.OnCreated(unitID, unitDefID, builderID, frame)
    if DL.id or not DL.con or builderID ~= DL.con then return end
    local d = UnitDefs[unitDefID]
    if not (d and d.name == "coraap") then return end
    DL.id = unitID
    local trans = E.trans()
    if trans then trans.noConLabs = trans.noConLabs or {}; trans.noConLabs[unitID] = true end
    Spring.Echo(string.format("[DL] %s Dragon lab frame %d started", Clock(frame), unitID))
end

function M.OnFinished(unitID, frame)
    if unitID ~= DL.id then return end
    DL.done[unitID], DL.nDone = { x = DL.x, z = DL.z }, DL.nDone + 1
    ReleaseDragonCons()
    -- the build job starts over for the next lab (WantDragonLab decides when)
    DL.id, DL.ready, DL.since, DL.site, DL.tries, DL.floatSince, DL.retold = nil, nil, nil, nil, 0, nil, 0
    PublishDragonLabs()
    Spring.Echo(string.format("[DL] %s Dragon lab %d finished (%d standing)", Clock(frame), unitID, DL.nDone))
end

function M.OnDestroyed(unitID, attackerID, attackerDefID, frame)
    if unitID ~= DL.id then return end
    local ad = attackerDefID and UnitDefs[attackerDefID]
    local _, prog = Spring.GetUnitIsBeingBuilt(unitID)
    Spring.Echo(string.format("[DL] %s Dragon lab %d destroyed by %s (attacker %s), %.0f%% built", Clock(frame), unitID,
        ad and ad.name or "nothing (decay / reclaim / self)", tostring(attackerID), 100 * (prog or 0)))
end

return M
