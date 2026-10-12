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

return M
