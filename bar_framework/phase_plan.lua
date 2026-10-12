-- bar_framework/phase_plan.lua  (LINE_BOMB)
-- The game plan as a state machine: T1 defense -> T1 bombing run -> T2 defense -> late game.
--
--   DEF1  stance T1_defense.  From PREP_FROM the macro builds the bomber labs + nanos (the pre-built build power), so
--         the army does not have to be bought in a burst later.
--   BOMB  stance T1_bombing_run: the bomber labs spend as fast as they can on bombers + escort fighters (bomb_run.lua
--         flies them).  Ground labs keep their defence stance, and the ground share is NOT raised: "if the ground can
--         hold, adding more units does not help".
--   DEF2  stance T2_defense.  The bomber labs are reclaimed (lab_recycler.lua) and their slots re-used for T2 air labs.
--   LATE  stance Late_game, from LATE_FROM or when income is large enough that the retrofits cannot spend it.
--
-- One widget (the macro controller) owns the state and publishes it as WG.BombPlan; everyone else reads that table.
-- This module has no Spring calls, so tests can drive it with plain numbers.
--
-- sig = { airLabs = bomber labs standing, bombersAlive, bombersBuilt (ever ordered), launched (strikes sent), income }

local M = {}

M.CFG = {
    PREP_FROM     = 4 * 60 * 30 + 30 * 30,   -- open the bomber lab cell (4:30; the grids take the metal first, 2nd real run had 2 labs by 10:00)
    BOMB_FROM     = 7 * 60 * 30 + 30 * 30,   -- the bomber labs start on bombers (7:30); the wave goes when it is big enough
    BOMB_LATEST   = 11 * 60 * 30,            -- the labs are not ready by now: drop the raid
    BOMB_END      = 13 * 60 * 30,  -- the bombing stance is over by now whatever happened
    MIN_AIR_LABS  = 2,                       -- bomber labs standing before BOMB starts
    BOMB_TARGET   = 30,                      -- bombers wanted in the first wave
    BOMB_TOTAL    = 50,                      -- most bombers ordered in the whole run (rebuilds after losses)
    SPENT_ALIVE   = 4,                       -- BOMB ends when this few bombers are left after the target was built
    LATE_FROM     = 16 * 60 * 30,
    LATE_INCOME   = 1500,                    -- m/s: late game even before LATE_FROM
    STANCE        = { DEF1 = "T1_defense", BOMB = "T1_bombing_run", DEF2 = "T2_defense", LATE = "Late_game" },
    -- Share of income the SPINE (ground labs) spends in each phase.  The bombers are paid for by their own labs, not
    -- by this number.
    GROUND_SHARE  = { DEF1 = 0.20, BOMB = 0.20, DEF2 = 0.20, LATE = 1.0 },
}

function M.New(cfg)
    local P = { phase = "DEF1", since = 0, cfg = {}, log = {}, skipped = false }
    for k, v in pairs(M.CFG) do P.cfg[k] = v end
    for k, v in pairs(cfg or {}) do P.cfg[k] = v end
    return P
end

local function Go(P, frame, phase, why)
    P.log[#P.log + 1] = { frame = frame, from = P.phase, to = phase, why = why }
    P.phase, P.since, P.why = phase, frame, why
    if M.OnChange then M.OnChange(P, frame, phase, why) end
end

function M.Update(P, frame, sig)
    local K = P.cfg
    sig = sig or {}
    local ph = P.phase
    if ph == "DEF1" then
        if frame >= K.BOMB_FROM and (sig.airLabs or 0) >= K.MIN_AIR_LABS then
            Go(P, frame, "BOMB", string.format("%d bomber labs standing", sig.airLabs))
        elseif frame >= K.BOMB_LATEST then
            P.skipped = true
            Go(P, frame, "DEF2", "bomber labs not ready, raid dropped")
        end
    elseif ph == "BOMB" then
        local built = sig.bombersBuilt or 0
        if frame >= K.BOMB_END then
            Go(P, frame, "DEF2", "time")
        elseif built >= K.BOMB_TARGET and (sig.bombersAlive or 0) <= K.SPENT_ALIVE and (sig.launched or 0) > 0 then
            Go(P, frame, "DEF2", string.format("raid spent (%d built, %d left)", built, sig.bombersAlive or 0))
        end
    elseif ph == "DEF2" then
        if frame >= K.LATE_FROM or (sig.income or 0) >= K.LATE_INCOME then
            Go(P, frame, "LATE", frame >= K.LATE_FROM and "time" or "income")
        end
    end
    return P.phase
end

-- Everything a reader needs, as one table (what the macro puts in WG.BombPlan).
function M.View(P, frame)
    local K = P.cfg
    local ph = P.phase
    return {
        phase        = ph,
        since        = P.since,
        stance       = K.STANCE[ph],
        -- every lab that is not a bomber lab keeps to the defence stance while the bombers are built
        groundStance = K.STANCE[ph == "BOMB" and "DEF1" or ph],
        groundShare  = K.GROUND_SHARE[ph],
        -- the bomber lab cell is wanted from PREP_FROM until the raid is over or dropped
        prep         = ph == "DEF1" and frame >= K.PREP_FROM and not P.skipped,
        bomb         = ph == "BOMB",
        bombTarget   = K.BOMB_TARGET,
        bombTotal    = K.BOMB_TOTAL,
        -- true once the raid is over: the bomber labs are for the recycler
        recycle      = ph == "DEF2" or ph == "LATE",
        skipped      = P.skipped,
    }
end

return M
