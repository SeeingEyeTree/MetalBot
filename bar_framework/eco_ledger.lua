-- bar_framework/eco_ledger.lua   (C3, 2026-10-16)
-- THE SPEND / ENERGY LEDGER: one place that answers the questions several systems used to answer separately --
--   * is the spine saturated (income >= SAT_FRAC x what its nanos can spend)?   (metal_sink.SpineSaturated and line_decoy each had their own)
--   * how many decoy commanders does the sink want?                              (lab_rules, DRAGON_ECO's lab_controller, line_decoy.DecoyShort)
--   * what energy:metal ratio should the economy aim at?                         (EP_RATIO vs the sink's EnergyRatio)
--   * how much of the unit cap is left?                                          (energy.lua x3, grid_core, line_transition)
-- Consumers REGISTER themselves on WG.EcoLedger (modules included with VFS.Include are separate instances, so the registry lives on WG):
--   Ledger.Register(WG, "spine", { capacity = function() return metalPerSecond end })
--   Ledger.Register(WG, "sink",  { energyPerMetal = function() return 14.1 end })
-- and the questions go through the functions below.  Thresholds are one table (Ledger.CFG); a caller may pass its own for one question
-- (the line decoy labs start later than the sink: DECOY_LINE_MIN_INCOME).
--
--   Ledger.Register(WG, name, spec) / Ledger.Unregister(WG, name)
--   Ledger.Capacity(WG, name)             -> number | nil     what a registered consumer can spend (m/s)
--   Ledger.Saturated(res, capacity[, o])  -> saturated, capacity   o = { satFrac, minIncome, fallbackIncome }
--   Ledger.Surplus(res, capacity)         -> income the capacity cannot spend
--   Ledger.EnergyTarget(WG[, override])   -> energy per metal to aim at | nil   (an explicit override wins; else the registered consumers' blend)
--   Ledger.CapLeft(teamID)                -> units left under the cap, cap, count | nil
--   Ledger.CapSlack(teamID, frac, absolute) -> min(absolute, frac x cap)
--   Ledger.DecoyDemand(income, room[, o]) -> decoys wanted  o = { spend, rate, min }

local M = {}

M.CFG = {
    SAT_FRAC         = 0.85,    -- saturated when income >= this share of the spine's spend capacity ...
    MIN_INCOME       = 500,     -- ... and never under this income (a few nanos early on make a tiny capacity)
    FALLBACK_INCOME  = 2000,    -- with no capacity figure: saturated from this income
    DECOY_SPEND      = 0.9,     -- decoys wanted = this share of income / one decoy's metal rate, at least DECOY_MIN, at most the room
    DECOY_METAL_RATE = 12.75,   -- metal/s one decoy puts into a Dragon
    DECOY_MIN        = 8,
}

-- ── registry ──────────────────────────────────────────────────────────────────────────────────────

local function Reg(WG, create)
    if not WG then return nil end
    if not WG.EcoLedger and create then WG.EcoLedger = { consumers = {} } end
    return WG.EcoLedger
end

function M.Register(WG, name, spec)
    local r = Reg(WG, true)
    if r then r.consumers[name] = spec end
end
function M.Unregister(WG, name)
    local r = Reg(WG)
    if r then r.consumers[name] = nil end
end
function M.Capacity(WG, name)
    local r = Reg(WG)
    local c = r and r.consumers[name]
    if not (c and c.capacity) then return nil end
    local ok, v = pcall(c.capacity)
    return ok and tonumber(v) or nil
end

-- ── saturation ────────────────────────────────────────────────────────────────────────────────────

local function Income(res) return (res and (res.metalIncomeS or res.metalIncome)) or 0 end

function M.Saturated(res, capacity, o)
    o = o or {}
    local inc = Income(res)
    local minInc = o.minIncome or M.CFG.MIN_INCOME
    if capacity and capacity > 0 then
        return inc >= minInc and inc >= (o.satFrac or M.CFG.SAT_FRAC) * capacity, capacity
    end
    return inc >= (o.fallbackIncome or M.CFG.FALLBACK_INCOME), capacity
end

function M.Surplus(res, capacity) return math.max(0, Income(res) - (capacity or 0)) end

-- ── energy ────────────────────────────────────────────────────────────────────────────────────────

-- The ratio of energy to metal the economy should aim at: an explicit override (EP_RATIO) wins; else the capacity-weighted blend of what the
-- registered consumers' units cost in energy per metal (one consumer = its own figure).  nil when nobody asks for one.
function M.EnergyTarget(WG, override)
    if override then return override end
    local r = Reg(WG)
    if not r then return nil end
    local sum, wsum, n = 0, 0, 0
    local names = {}
    for name in pairs(r.consumers) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local c = r.consumers[name]
        if c.energyPerMetal then
            local ok, v = pcall(c.energyPerMetal)
            v = ok and tonumber(v) or nil
            if v then
                local ok2, w = pcall(c.capacity or function() return 1 end)
                w = ok2 and tonumber(w) or 1
                if not w or w <= 0 then w = 1 end
                sum, wsum, n = sum + v * w, wsum + w, n + 1
            end
        end
    end
    if n == 0 then return nil end
    return sum / wsum
end

-- ── unit cap ──────────────────────────────────────────────────────────────────────────────────────

function M.CapLeft(teamID)
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(teamID)
    local cnt = Spring.GetTeamUnitCount and Spring.GetTeamUnitCount(teamID)
    if not (maxU and cnt) then return nil end
    return maxU - cnt, maxU, cnt
end

function M.CapSlack(teamID, frac, absolute)
    local maxU = Spring.GetTeamMaxUnits and Spring.GetTeamMaxUnits(teamID)
    if not maxU or maxU <= 0 then return absolute end
    return math.min(absolute, math.floor(maxU * frac))
end

-- ── decoys ────────────────────────────────────────────────────────────────────────────────────────

function M.DecoyDemand(income, room, o)
    o = o or {}
    local n = math.floor((o.spend or M.CFG.DECOY_SPEND) * (income or 0) / (o.rate or M.CFG.DECOY_METAL_RATE))
    return math.max(o.min or M.CFG.DECOY_MIN, math.min(room or 0, n))
end

return M
