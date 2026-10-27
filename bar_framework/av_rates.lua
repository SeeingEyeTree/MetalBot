-- bar_framework/av_rates.lua
-- Army-value (AV) derivatives, the rough "how fast is each side adding army" (user 2026-10-27: the bot pushed at 1.57x the SCOUTED enemy army while the enemy
-- reinforced constantly, and the bot was killing lots of units so the scouted value looked small).  Pure (no Spring): tests feed it numbers.
--   own_rate    d(our army value)/dt over the window, metal/s.  Net: production minus losses.
--   enemy_rate  the enemy's reinforcement rate, metal/s = d(scouted enemy value)/dt + (enemy value we killed in the window)/window,
--               never below 0.  Kills put back what the scouted value lost, so a side that is being killed and does not shrink is reinforcing.
--   Rates are nil until the window holds MIN_S seconds of samples.
--   proj_ratio  (own + own_rate x H) / (enemy + enemy_rate x H) at the horizon H seconds ahead (a push arrives and fights about then); nil without rates
--               or without a scouted enemy value.
--
--   local t = AV.New{ win_s = 60 }
--   AV.Sample(t, frame, ownValue, enemyValue)   about once a second
--   AV.NoteKill(t, frame, value)                an enemy armed unit we killed
--   AV.Rates(t, frame) -> { own, enemy }        (nil fields while there is not enough history)
--   AV.Project(own, enemy, rates, H) -> ratio

local M = {}

M.CFG = { WIN_S = 60, MIN_S = 25, HORIZON_S = 60 }

function M.New(o)
    o = o or {}
    return { win = (o.win_s or M.CFG.WIN_S) * 30, min = (o.min_s or M.CFG.MIN_S) * 30, samples = {}, kills = {} }
end

local function Trim(list, cutoff)
    local n = 0
    while n < #list and list[n + 1].f < cutoff do n = n + 1 end
    if n > 0 then
        local len = #list
        for i = 1, len - n do list[i] = list[i + n] end
        for i = len - n + 1, len do list[i] = nil end
    end
end

function M.Sample(t, frame, own, enemy)
    local s = t.samples
    s[#s + 1] = { f = frame, own = own or 0, enemy = enemy or 0 }
    Trim(s, frame - t.win)
end

function M.NoteKill(t, frame, value)
    local k = t.kills
    k[#k + 1] = { f = frame, v = value or 0 }
    Trim(k, frame - t.win)
end

function M.Rates(t, frame)
    local s = t.samples
    if #s < 2 then return {} end
    local a, b = s[1], s[#s]
    local dt = (b.f - a.f) / 30
    if b.f - a.f < t.min or dt <= 0 then return {} end
    local killed = 0
    for _, e in ipairs(t.kills) do if e.f >= a.f then killed = killed + e.v end end
    return { own = (b.own - a.own) / dt, enemy = math.max(0, (b.enemy - a.enemy + killed) / dt) }
end

-- projected ratio at the horizon; nil when the enemy is unknown (enemy <= 0) or there are no rates
function M.Project(own, enemy, rates, horizon_s)
    if not rates or rates.own == nil or rates.enemy == nil or (enemy or 0) <= 0 then return nil end
    local h = horizon_s or M.CFG.HORIZON_S
    local e = enemy + rates.enemy * h
    local o = math.max(0, (own or 0) + rates.own * h)
    return e > 0 and o / e or nil
end

return M
