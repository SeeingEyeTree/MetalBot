-- bar_framework/unit_clock.lua
-- Per-unit command frequency.  Every unit has a TIER (how often its orders may go out) and a fixed PHASE (which frame of
-- the period it is sent on), so
--   * quiet units (scouts, home guards with no enemy near) are sent at 0.5 Hz, normal ones at 1 Hz, and units that are
--     raiding / responding / have an enemy near at 2 Hz -- they answer faster when it matters;
--   * the orders no longer all fall on the one frame where `frame % 30 == 0`: unit u goes out on the frames where
--     (frame - phase(u)) % period == 0, and phases are spread over 60 frames by the unit id.
--
--   local CLK = VFS.Include("LuaUI/Widgets/bar_framework/unit_clock.lua")
--   CLK.Due(uid, frame)                     -- true on this unit's frames (its tier's period, its phase)
--   CLK.SetTier(uid, CLK.HIGH)              -- or let Classify decide:
--   CLK.Classify(uid, { scout = true, raiding = false, urgent = false, enemyNear = false }, frame)
--   CLK.BuildEnemyIndex(contacts, frame)    -- once per planning tick; then CLK.EnemyNear(x, z) for any point
--   CLK.AnyHigh()                           -- is any unit in the HIGH tier (the caller may plan faster then)
--
-- army_broker.lua uses it (ARMY.SetClock) to hold a non-urgent order until the unit's own frame and to scale the order
-- rate limit by tier.  Units never classified are NORMAL.

local M = {}

M.LOW, M.NORMAL, M.HIGH, M.FAST = 1, 2, 3, 4
M.PERIOD = { [1] = 60, [2] = 30, [3] = 15, [4] = 10 }    -- frames between sends: 0.5 Hz, 1 Hz, 2 Hz, 3 Hz
M.FAST_HOLD = 60          -- frames a unit stays FAST after the last trigger (raiders and raid defenders with an enemy near, army_broker SetFastFn)
M.HIGH_HOLD = 90          -- frames a unit stays HIGH after the last trigger (no flapping at the edge of a threat)
M.ENEMY_R   = 1200        -- an enemy contact this close makes a unit "enemy near"
M.CONTACT_MAX_AGE = 300   -- frames; older contacts are not counted
M.PHASES    = 60

local tier, highUntil, fastUntil = {}, {}, {}
local nHigh, nFast = 0, 0

-- The unit's slot: its id spread over PHASES frames (consecutive ids land on different frames).
function M.Phase(uid) return (uid * 7) % M.PHASES end

function M.Tier(uid) return tier[uid] or M.NORMAL end
function M.Period(uid) return M.PERIOD[tier[uid] or M.NORMAL] end

local function Set(uid, t)
    local old = tier[uid] or M.NORMAL
    if old == t then return end
    if old >= M.HIGH then nHigh = nHigh - 1 end              -- FAST counts as HIGH for AnyHigh (the half-step planning pass)
    if t >= M.HIGH then nHigh = nHigh + 1 end
    if old == M.FAST then nFast = nFast - 1 end
    if t == M.FAST then nFast = nFast + 1 end
    tier[uid] = (t ~= M.NORMAL) and t or nil
end
function M.SetTier(uid, t) Set(uid, t) end

function M.Forget(uid)
    if (tier[uid] or 0) >= M.HIGH then nHigh = nHigh - 1 end
    if tier[uid] == M.FAST then nFast = nFast - 1 end
    tier[uid], highUntil[uid], fastUntil[uid] = nil, nil, nil
end

-- True on this unit's frames.
function M.Due(uid, frame)
    return (frame - M.Phase(uid)) % M.PERIOD[tier[uid] or M.NORMAL] == 0
end

-- Frames until the unit's next send (0 = now).
function M.Wait(uid, frame)
    local p = M.PERIOD[tier[uid] or M.NORMAL]
    return (M.Phase(uid) - frame) % p
end

function M.AnyHigh() return nHigh > 0 end
function M.CountHigh() return nHigh end
function M.AnyFast() return nFast > 0 end
function M.CountFast() return nFast end

-- info: scout (a scouting duty), raiding (a raid / commit / escape group), urgent (retreat, respond), enemyNear.
-- HIGH for raiding, urgent or an enemy near (held HIGH_HOLD frames); LOW for a scout or an idle guard with no enemy near;
-- else NORMAL.
function M.Classify(uid, info, frame)
    if info.raiding or info.urgent or info.enemyNear then highUntil[uid] = frame + M.HIGH_HOLD end
    if info.fast then fastUntil[uid] = frame + M.FAST_HOLD end
    if (fastUntil[uid] or -1) >= frame then Set(uid, M.FAST)
    elseif (highUntil[uid] or -1) >= frame then Set(uid, M.HIGH)
    elseif info.scout or info.quiet then Set(uid, M.LOW)
    else Set(uid, M.NORMAL) end
    return tier[uid] or M.NORMAL
end

-- ── enemy proximity: a coarse grid over the recent contacts ──────────────────────────────────────────────────────────
local grid, CELL = {}, 600

function M.BuildEnemyIndex(contacts, frame)
    grid = {}
    CELL = math.max(200, M.ENEMY_R / 2)
    for _, c in pairs(contacts or {}) do
        if c.x and frame - (c.frame or frame) <= M.CONTACT_MAX_AGE then
            local k = math.floor(c.x / CELL) .. ":" .. math.floor(c.z / CELL)
            local b = grid[k]
            if not b then b = {}; grid[k] = b end
            b[#b + 1] = c
        end
    end
end

function M.EnemyNear(x, z, r)
    r = r or M.ENEMY_R
    local r2, reach = r * r, math.ceil(r / CELL)
    local cx, cz = math.floor(x / CELL), math.floor(z / CELL)
    for i = cx - reach, cx + reach do
        for j = cz - reach, cz + reach do
            local b = grid[i .. ":" .. j]
            if b then
                for _, c in ipairs(b) do
                    if (c.x - x) ^ 2 + (c.z - z) ^ 2 <= r2 then return true end
                end
            end
        end
    end
    return false
end

function M.Reset() tier, highUntil, fastUntil, grid, nHigh, nFast = {}, {}, {}, {}, 0, 0 end

return M
