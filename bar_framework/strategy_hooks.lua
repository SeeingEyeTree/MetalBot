-- bar_framework/strategy_hooks.lua
-- Ready-made hooks for strategy.lua (army_share / weights / switch).  A hook is `function(state, strat)`; these are
-- factories that return one, so a bot picks and tunes them in its config instead of writing code.

local M = {}

-- The army share spine.lua's policies gave LINE_CLICK_v16: nothing before `start`, `floor` after, lifted to the
-- threat level while the unit controller sees one (held `hold` frames after the last sighting), 1 near the unit cap.
function M.v16_share(o)
    o = o or {}
    local start, floor, hold = o.start or 5400, o.floor or 0.20, o.hold or 900
    local rush, build, seen = o.rush or 1.0, o.build or 0.6, o.seen or 0.5
    local capSlack = o.cap_slack or 150
    local level, lastF = 0, -1e9
    return function(state)
        local f = state.frame or 0
        local share = f < start and 0 or floor
        local sig = 0
        if state.urgency == "rush" then sig = rush
        elseif state.urgency == "build" then sig = build
        elseif #(state.threats or {}) > 0 then sig = seen end
        if sig > 0 then
            if sig >= level or f - lastF > hold then level = sig end
            lastF = f
        elseif f - lastF > hold then
            level = 0
        end
        share = math.max(share, level)
        if state.cap and state.units and (state.cap - state.units) <= capSlack then share = 1 end
        return share
    end
end

-- Rough metal value of the army a competent opponent has by game minute (linear between points); only used, scaled by
-- `expect`, as a floor under what we have scouted, so an unscouted enemy is not read as no enemy.
local EXPECTED_ENEMY = { {3, 300}, {5, 1500}, {8, 5000}, {12, 14000}, {20, 40000}, {30, 90000} }
local function ExpectedEnemy(minute)
    local pts = EXPECTED_ENEMY
    if minute <= pts[1][1] then return pts[1][2] * minute / pts[1][1] end
    for i = 2, #pts do
        if minute <= pts[i][1] then
            local a, b = pts[i - 1], pts[i]
            return a[2] + (b[2] - a[2]) * (minute - a[1]) / (b[1] - a[1])
        end
    end
    return pts[#pts][2]
end

-- v16_share (without its threat lifts) plus a "keep up with the enemy" rule, for games against people (two bots using it would chase each other's
-- share up).  From `start` the share rises as our army value (state.armyValue) falls short of
-- ratio x max(scouted enemy army value, expect x the time curve): base + shortfall / (income x horizon), so 1.0 once we are a
-- minute of income short, back to the base once we match.  Metal and energy both floating -> 1.0 (spend it all).  Smoothed: it rises at once, falls at `fall`/s.
--   o.ratio 1.1, o.expect 0.5, o.horizon 60 (s of income), o.lead 1.5 + o.ahead_floor 0.05 (share when ahead), o.fall 0.02, o.float 0.9 (fill), o.log true; the rest goes to v16_share.
function M.match_enemy(o)
    o = o or {}
    local base0 = M.v16_share(o)
    -- Threat sightings do not lift the share here (v16_share raises it to 0.5-1.0 on any contact): with the slot spine a
    -- share of 1 sizes nanos for all of income, which starved the mex grids while our army was already ahead.  Being
    -- behind the scouted enemy lifts it below; raids are answered by the lab controller's defence floor, not the share.
    local function base(state)
        local st = setmetatable({ urgency = "none", threats = {} }, { __index = state })
        return base0(st)
    end
    local ratio, expect, fall, floatFill = o.ratio or 1.1, o.expect or 0.5, o.fall or 0.02, o.float or 0.9
    local lead, aheadFloor = o.lead or 1.5, o.ahead_floor or 0.05   -- army >= lead x target -> share ahead_floor
    local horizon = o.horizon or 60     -- seconds of income that a shortfall may cost before the share is 1
    local start = o.start or 5400
    local cur, lastLog = 0, -1e9
    return function(state)
        local f = state.frame or 0
        local share = base(state)
        if f >= start and state.armyValue then
            local known = (state.enemyGround or 0) + (state.enemyAir or 0)
            local enemy = math.max(known, expect * ExpectedEnemy(f / 1800))
            local target = ratio * enemy
            -- the shortfall in seconds of income: a 165-metal gap at 3:00 (income ~40) is a few seconds of eco, not "no army"
            local want = 0
            local inc = math.max((state.metal and state.metal.income) or 0, 20)
            if target > state.armyValue then
                want = math.min(1, share + (target - state.armyValue) / (inc * horizon))
            elseif state.armyValue >= lead * target and share <= (o.floor or 0.20) + 1e-9 then
                share = aheadFloor      -- well ahead of what we have scouted: eco gets the rest
            end
            if state.metal and state.energy and state.metal.fill >= floatFill and state.energy.fill >= floatFill then
                want = 1
            end
            cur = want >= cur and want or math.max(want, cur - fall)
            share = math.max(share, cur)
            if o.log ~= false and f - lastLog >= 300 then
                lastLog = f
                Spring.Echo(string.format("[SHARE] f=%d own=%.0f enemy=%.0f (known %.0f) target=%.0f share=%.2f",
                    f, state.armyValue, enemy, known, target, share))
            end
        end
        return share
    end
end

-- Tilt the mix toward anti-air once enemy air shows up: unit names in `aa` are multiplied by `mult` while the enemy's
-- air value is at least `frac` of what we know of its army.
function M.aa_weights(o)
    local aa, frac, mult = o.aa or {}, o.frac or 0.25, o.mult or 3
    return function(state)
        if (state.enemyAirShare or 0) < frac then return nil end
        local w = {}
        for _, n in ipairs(aa) do w[n] = mult end
        return w
    end
end

-- switch hook: once the unit cap is filling (capFrac >= cap_frac, not before `minute`), take the stance `late` for the rest of the game.
-- With the cap nearly full every slot should hold the most value (bigger, costlier units: stances/Late_game.lua), not cheap T1 bodies.
--   hooks = { switch = H.cap_switch{ late = "Late_game", cap_frac = 0.75, minute = 12 } }   (the stance must be in strategy.stances)
function M.cap_switch(o)
    o = o or {}
    local late, capFrac, minute = o.late or "Late_game", o.cap_frac or 0.75, o.minute or 12
    local on = false
    return function(state)
        if not on and (state.minute or 0) >= minute and (state.capFrac or 0) >= capFrac then
            on = true
            Spring.Echo(string.format("[STRAT] unit cap %.0f%% full at %.1f min: switching to stance %s",
                100 * (state.capFrac or 0), state.minute or 0, late))
        end
        if on then return late end
    end
end

return M
