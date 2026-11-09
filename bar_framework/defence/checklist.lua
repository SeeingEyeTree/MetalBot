-- bar_framework/defence/checklist.lua  (area_defence: what the enemy has that we have to cover)
-- User 2026-11-08: "It should keep track of the types of threats the enemy has.  Just kind of a check list of things it needs to try and cover.  So
-- seen lots of air needs to build up aa, seen lots of ground good ground defense, nukes make sure there is an [anti-nuke] ... That is not complete,
-- I just want that kind of feature."  One row per kind of threat: what we have seen of it (`level`), what covering it takes (`want`), what we have
-- (`have`), `short` = want > have, and `answer` = who acts on it.  A new kind is one more entry in M.ROWS.
--
--   local CL = VFS.Include("LuaUI/Widgets/bar_framework/defence/checklist.lua").New{ cfg, EI, UQ, teamID, areas = fn(), pressure = fn(areaId) -> avg, groups,
--       walls = fn() -> summary, homeAA = fn() -> value, build = <defence/build.lua instance> }
--   CL.Update(frame) -> rows   CL.Rows()   CL.Get(key)   CL.TzarsOn()   CL.HomeAAWant() -> extra ground AA units the base screen should hold

local M = {}

M.CFG = {
    EVERY        = 150,    -- frames between updates
    LOG_EVERY    = 1800,
    MEMORY       = 9000,   -- a mobile enemy counts this long after it was last seen (enemy_intel's memory)
    HEAVY_MIN    = 1500,   -- enemy T2+ armed ground value that turns the walls' Tzars on ...
    TZAR_INCOME  = 300,    -- ... or our metal income held >= this for TZAR_HOLD_S (support/stop.lua's gate)
    TZAR_HOLD_S  = 20,
    AIR_MULT     = 0.5,    -- home AA worth this x the enemy's air-to-ground value
    AIR_MIN      = 300,    -- enemy air-to-ground value below this: no extra AA
    AA_UNIT_V    = 300,    -- metal-eq one more ground AA unit is worth (Lasher ~250, flak truck ~600)
    AA_EXTRA_MAX = 8,      -- the most extra AA the checklist asks the base screen for
    LONG_RANGE   = 2500,   -- an enemy static weapon with this much range is long-range artillery (LRPC)
}

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs(o.cfg or {}) do C[k] = v end
    local EI = o.EI
    local CL = {}
    local rows, byKey, lastF, logF = {}, {}, -1e9, -1e9
    local tzarSince, tzarOn, aaWant = nil, false, 0
    local antiDefs

    local function Clock(f) return string.format("%d:%02d", math.floor(f / 1800), math.floor(f / 30) % 60) end

    -- our anti-nukes (static or mobile): { x, z, r }
    local function OurAntiNukes()
        if not antiDefs then
            antiDefs = {}
            for id, d in pairs(UnitDefs) do
                for _, w in ipairs(d.weapons or {}) do
                    local wd = w.weaponDef and WeaponDefs and WeaponDefs[w.weaponDef]
                    if wd and wd.interceptor and wd.interceptor ~= 0 then antiDefs[id] = wd.coverageRange or wd.range or 2000 end
                end
            end
        end
        local out = {}
        for _, uid in ipairs(Spring.GetTeamUnits(o.teamID) or {}) do
            local r = antiDefs[Spring.GetUnitDefID(uid) or -1]
            if r and not Spring.GetUnitIsBeingBuilt(uid) then
                local x, _, z = Spring.GetUnitPosition(uid)
                if x then out[#out + 1] = { x = x, z = z, r = r } end
            end
        end
        return out
    end

    local function Row(key, level, want, have, answer, note)
        local r = { key = key, level = level, want = want, have = have, short = want > have, answer = answer, note = note }
        local prev = byKey[key]
        r.since = (prev and prev.short == r.short) and prev.since or Spring.GetGameFrame()
        rows[#rows + 1], byKey[key] = r, r
        return r
    end

    function CL.Update(frame)
        if frame - lastF < C.EVERY then return rows end
        lastF = frame
        local old = byKey
        rows, byKey = {}, {}
        for k, v in pairs(old) do byKey[k] = v end          -- for `since`; replaced below
        -- the enemy, from what we remember
        local heavy, airGnd, fast, longRange, silos = 0, 0, 0, 0, 0
        for _, rec in pairs(EI and EI.Records and EI.Records() or {}) do
            local c = rec.c
            if c and c.armed and not c.commander then
                local fresh = frame - (rec.frame or -1e9) <= C.MEMORY
                if c.mobile and fresh then
                    if c.air and c.hitsGnd and not c.aaOnly then airGnd = airGnd + c.value
                    elseif not c.air and not c.scout then
                        if c.tech >= 2 then heavy = heavy + c.value end
                        local d = UnitDefs[rec.defID]
                        if d and (d.speed or 0) >= 70 then fast = fast + c.value end
                    end
                elseif not c.mobile and (c.range or 0) >= C.LONG_RANGE and not c.silo then
                    longRange = longRange + 1
                end
            end
            if c and c.silo then silos = silos + 1 end
        end
        local main = o.areas()[1]
        local avg, groups = 0, 0
        if main then avg, groups = o.pressure(main.id) end
        local ws = o.walls()
        -- 1. ground raids: the walls (count from raid pressure)
        Row("ground_raid", avg, groups, ws.onThreat > 0 and groups or math.min(groups, ws.walls), "wall",
            string.format("pressure %.2f, fast enemy ground %.0f; walls %d, Pounders %d / %d", avg, fast, ws.walls, ws.pounders, ws.want))
        -- 2. heavy ground: Tzars in the walls (or our own income says T2 is here)
        local _, _, _, inc = Spring.GetTeamResources(o.teamID, "metal")
        if (inc or 0) >= C.TZAR_INCOME then tzarSince = tzarSince or frame else tzarSince = nil end
        if heavy >= C.HEAVY_MIN or (tzarSince and frame - tzarSince >= C.TZAR_HOLD_S * 30) then tzarOn = true end
        Row("ground_heavy", heavy, ws.wantT, ws.tzars, "wall Tzars", tzarOn and "Tzars on" or "Tzars off")
        -- 3. air that hits the ground: more ground AA in the base screen (and a static AA want for the construction stub)
        local aaHave = o.homeAA and o.homeAA() or 0
        local aaNeed = airGnd >= C.AIR_MIN and C.AIR_MULT * airGnd or 0
        local short = math.max(0, aaNeed - aaHave)
        aaWant = math.min(C.AA_EXTRA_MAX, math.ceil(short / C.AA_UNIT_V))
        Row("air_ground", airGnd, aaNeed, aaHave, "base AA screen", string.format("+%d AA asked", aaWant))
        if o.build and short > 0 and main then o.build.Want(main.id, "air_ground", "static_aa", math.ceil(short / C.AA_UNIT_V), "enemy air-to-ground " .. math.floor(airGnd)) end
        -- 4. nukes: an anti-nuke covering each area's centre
        local covered, areas = 0, 0
        if silos > 0 then
            local anti = OurAntiNukes()
            for _, a in ipairs(o.areas()) do
                if a.N() > 0 then
                    areas = areas + 1
                    local cx, cz = a.Centre()
                    local ok = false
                    for _, an in ipairs(anti) do if (an.x - cx) ^ 2 + (an.z - cz) ^ 2 <= an.r * an.r then ok = true; break end end
                    if ok then covered = covered + 1 elseif o.build then o.build.Want(a.id, "nuke", "antinuke", 1, silos .. " enemy silo(s)") end
                end
            end
        end
        Row("nuke", silos, silos > 0 and areas or 0, covered, "build (stub); defense_crew / capstones build them now")
        -- 5. long-range artillery: noted only
        Row("long_range", longRange, 0, 0, "none yet", longRange > 0 and (longRange .. " enemy LRPC-class structures seen") or nil)
        if frame - logF >= C.LOG_EVERY then
            logF = frame
            local parts = {}
            for _, r in ipairs(rows) do
                parts[#parts + 1] = string.format("%s %s (seen %.0f, want %.0f, have %.0f%s)", r.key, r.short and "SHORT" or "ok", r.level or 0, r.want or 0, r.have or 0,
                    r.note and (", " .. r.note) or "")
            end
            Spring.Echo("[DEF] " .. Clock(frame) .. " checklist: " .. table.concat(parts, " | "))
        end
        return rows
    end

    function CL.Rows() return rows end
    function CL.Get(key) return byKey[key] end
    function CL.TzarsOn() return tzarOn end
    function CL.HomeAAWant() return aaWant end
    return CL
end

return M
