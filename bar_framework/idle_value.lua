-- bar_framework/idle_value.lua  (2026-10-29)
-- IDLE VALUE: is the army doing anything?  User 2026-10-29, the BM_akumar6 game: "if a unit is built it kills your own eco, so it needs
-- to create some kind of problem for the enemy, by attacking or defending; otherwise you just killed your own eco for no gain.  When a
-- unit group is not within 15 seconds of a comparable amount of enemy value it loses value."  (The bot had a 7x army lead at 11:00, with
-- 61-118 Pounders standing at home, and lost on eco.)
--
-- A unit is ENGAGED when the enemy value within its reach (speed x REACH_S seconds of travel, at least MIN_R) is at least COMPARABLE x our
-- own army value inside the same radius (so a group is judged as a group, not unit by unit).  Enemy value = armed units AND the eco /
-- build power a unit could hit: standing next to an enemy mex field is a threat, standing at home is not.
-- An idle unit's worth decays with time constant TAU_S (eco pays for itself in ~40 s, so a unit idle for ~80 s should have been eco):
--   effective value = cost x exp(-idle_s / TAU_S);  the value lost that way accumulates as `wasted` (metal-equivalent, like a loss).
-- An engaged unit is worth its full cost again (the past idling stays in `wasted`).
-- Pure (no Spring): the caller passes the units.  Used by unit_runtime (signals army_idle_frac / army_value_eff / army_wasted) and
-- ledger_logger.lua ([LED] spend: idle= wasted=).
--
--   local IV = VFS.Include("LuaUI/Widgets/bar_framework/idle_value.lua")
--   local t = IV.New()                                   -- or IV.New{ REACH_S = 15, ... }
--   local r = IV.Update(t, frame, own, enemy)            -- every ~2 s
--     own   = { { id =, x =, z =, v = cost, speed = elmos/s }, ... }     our army units
--     enemy = { { x =, z =, v = value }, ... }                             enemy units / structures we know of
--     r     = { value, eff, idleValue, idleFrac, wasted, n, idleN }

local M = {}

M.CFG = { REACH_S = 15, MIN_R = 500, MAX_R = 2500, COMPARABLE = 0.25, TAU_S = 80, CELL = 512 }

function M.New(cfg)
    local c = {}
    for k, v in pairs(M.CFG) do c[k] = v end
    for k, v in pairs(cfg or {}) do c[k] = v end
    return { cfg = c, idleSince = {}, lastF = nil, wasted = 0, last = nil }
end

-- grid of points (x, z, v) for radius sums
local function Grid(list, cell)
    local g = {}
    for _, p in ipairs(list) do
        local k = math.floor(p.x / cell) .. ":" .. math.floor(p.z / cell)
        local b = g[k]
        if not b then b = {}; g[k] = b end
        b[#b + 1] = p
    end
    return g
end

local function SumNear(g, cell, x, z, r)
    local s, r2 = 0, r * r
    local x0, x1 = math.floor((x - r) / cell), math.floor((x + r) / cell)
    local z0, z1 = math.floor((z - r) / cell), math.floor((z + r) / cell)
    for i = x0, x1 do
        for j = z0, z1 do
            local b = g[i .. ":" .. j]
            if b then
                for _, p in ipairs(b) do
                    local dx, dz = p.x - x, p.z - z
                    if dx * dx + dz * dz <= r2 then s = s + (p.v or 0) end
                end
            end
        end
    end
    return s
end

function M.Update(t, frame, own, enemy)
    local C = t.cfg
    local dt = t.lastF and math.max(0, (frame - t.lastF) / 30) or 0
    t.lastF = frame
    local og, eg = Grid(own, C.CELL), Grid(enemy or {}, C.CELL)
    local value, eff, idleValue, n, idleN = 0, 0, 0, 0, 0
    local seen = {}
    for _, u in ipairs(own) do
        local id, v = u.id, u.v or 0
        seen[id] = true
        n, value = n + 1, value + v
        local r = math.max(C.MIN_R, math.min(C.MAX_R, (u.speed or 0) * C.REACH_S))
        local ours = SumNear(og, C.CELL, u.x, u.z, r)
        local theirs = SumNear(eg, C.CELL, u.x, u.z, r)
        if theirs > 0 and theirs >= C.COMPARABLE * ours then
            t.idleSince[id] = nil
            eff = eff + v
        else
            local since = t.idleSince[id]
            if not since then since = frame; t.idleSince[id] = frame end
            local idleS = (frame - since) / 30
            local e = v * math.exp(-idleS / C.TAU_S)
            eff, idleValue, idleN = eff + e, idleValue + v, idleN + 1
            -- value lost to idling over this step: the drop of exp() between the last update and now
            if dt > 0 then
                local before = v * math.exp(-math.max(0, idleS - dt) / C.TAU_S)
                t.wasted = t.wasted + math.max(0, before - e)
            end
        end
    end
    for id in pairs(t.idleSince) do if not seen[id] then t.idleSince[id] = nil end end
    local r = { value = value, eff = eff, idleValue = idleValue, idleFrac = value > 0 and idleValue / value or 0,
                wasted = t.wasted, n = n, idleN = idleN }
    t.last = r
    return r
end

return M
