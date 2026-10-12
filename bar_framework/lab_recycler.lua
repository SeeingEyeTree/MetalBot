-- bar_framework/lab_recycler.lua  (LINE_BOMB)
-- Re-uses the bomber labs' build power instead of building more.
--
-- The air cell (blueprints/general/T1Air.lua, spine.OpenAirCell) is 4 T1 aircraft plants with 12 nanos behind them.  Once
-- the raid is over the labs are reclaimed -- by the nanos, which stay -- and the same slots take T2 aircraft plants
-- (M.swap in the blueprint, spine.OpenSwapCell): the nanos that built bombers now feed the late-game air labs, and the
-- metal in the T1 labs comes back (Dragons, Hailstorms and the Late_game stance need a T2 plant).
--
--   idle -> clearing (queues emptied) -> reclaiming (nanos on the labs) -> placing (swap cell built) -> done
--
-- Generic enough for another swap: Init{ swap = layout } names what goes in the slots.  The recycler never touches a lab
-- outside the air cell.  Log rows are "[LR]".
--
-- plan = WG.BombPlan (phase_plan.View): `plan.recycle` starts it.

local M = {}

M.CFG = {
    DELAY         = 90,       -- frames after the plan says recycle before queues are cleared
    EVERY         = 30,
    NANO_REACH    = 420,      -- a nano this close to a lab reclaims it
    RECLAIM_MAX   = 2700,     -- frames before the reclaim is written off (placing goes ahead anyway)
    PLACE_MAX     = 7200,     -- frames the swap cell may take
    MIN_INCOME    = 120,      -- metal/s before the T2 labs are placed (2 x 2900 metal)
    SWAP_LABS     = true,     -- false = reclaim only
}

local SP, NANO
local swapLayout
local R = { state = "idle", since = 0, labs = {}, reclaimed = 0, swapCell = nil }

local function Alive(uid) return uid ~= nil and Spring.GetUnitDefID(uid) ~= nil end
local function Log(frame, fmtStr, ...)
    local sec = math.floor(frame / 30)
    Spring.Echo(string.format("[LR] %d:%02d " .. fmtStr, math.floor(sec / 60), sec % 60, ...))
end

function M.Init(o)
    SP, NANO, swapLayout = o.SP, o.NANO, o.swap
    for k, v in pairs(o.cfg or {}) do M.CFG[k] = v end
    R = { state = "idle", since = 0, labs = {}, reclaimed = 0, swapCell = nil }
end

function M.State() return R.state end
function M.Reclaimed() return R.reclaimed end

local function Go(frame, state, why)
    R.state, R.since = state, frame
    Log(frame, "%s%s", state, why and (" (" .. why .. ")") or "")
end

-- T1 labs of the air cell that still stand.
local function T1Labs()
    local labs, nanos = SP.AirUnits()
    local keep = {}
    for _, l in ipairs(labs) do
        if l.name == "corap" then keep[#keep + 1] = l end
    end
    return keep, nanos
end

function M.Update(frame, plan, income)
    if not (SP and NANO and plan) then return end
    if frame % M.CFG.EVERY ~= 0 then return end
    local K = M.CFG
    if R.state == "idle" then
        if not plan.recycle then return end
        if not SP.AirCell() then Go(frame, "done", "no air cell was opened"); return end
        R.start = R.start or frame
        if frame - R.start < K.DELAY then return end
        Go(frame, "clearing")
    end

    if R.state == "clearing" then
        local labs = T1Labs()
        for _, l in ipairs(labs) do Spring.GiveOrderToUnit(l.uid, 0, {}, {}) end       -- CMD.STOP empties a factory queue
        R.labCount = #labs
        Go(frame, "reclaiming", string.format("%d labs", #labs))
        return
    end

    if R.state == "reclaiming" then
        local labs, nanos = T1Labs()
        if #labs == 0 then
            Go(frame, K.SWAP_LABS and swapLayout and "placing" or "done", "labs gone")
            R.swapWait = true
            return
        end
        if frame - R.since > K.RECLAIM_MAX then
            Go(frame, K.SWAP_LABS and swapLayout and "placing" or "done", string.format("reclaim timed out, %d labs left", #labs))
            return
        end
        for _, l in ipairs(labs) do
            Spring.GiveOrderToUnit(l.uid, 0, {}, {})
            for _, n in ipairs(nanos) do
                local dx, dz = n.x - l.x, n.z - l.z
                if dx * dx + dz * dz <= K.NANO_REACH * K.NANO_REACH then
                    if NANO.Reclaim(NANO.PRIO.CLEAR, n.uid, l.uid) then R.reclaimed = R.reclaimed + 1 end
                end
            end
        end
        return
    end

    if R.state == "placing" then
        if not R.swapCell then
            if (income or 0) < K.MIN_INCOME then return end      -- the metal is back in the bank, but wait for the income
            local air = SP.AirCell()
            if not air then Go(frame, "done", "air cell gone"); return end
            R.swapCell = SP.OpenSwapCell(swapLayout, air.ax, air.az)
            if not R.swapCell then Go(frame, "done", "swap cell refused"); return end
            R.since = frame
            return
        end
        if R.swapCell.done then
            Go(frame, "done", "swap cell built")
        elseif frame - R.since > K.PLACE_MAX then
            Go(frame, "done", "swap cell timed out")
        end
    end
end

return M
