-- bar_framework/behaviors/bomber_run.lua
-- BOMBER behaviour (ported from click_army's UpdateBombers).  Assign it to bombers (click_army CFG.BOMBER_BEHAVIORS = { "bomber_run" },
-- which replaces the built-in bomber logic): once `min` bombers stand ready and `cooldown` frames have passed since the last
-- run, they ALL strike the best static target together: build power near an enemy lab first (ctx.Rank puts it first), then
-- the rest, skipping targets whose anti-air is worth more than `air_max` x the bombers.  `release_after` frames later the
-- order is released so the bombers fly home to their pads.  Not while the endgame commander hunt is on (ctx.Hunting).
-- cfg: min=8 cooldown=2700 air_max=0.5 release_after=150 candidates=8
-- ctx needs: Home() Rank(frame,x,z,k,value,avoid) AirThreatAt(frame,x,z) Alive(uid) Release(uid) Hunting() Log
local M = { name = "bomber_run", cfg = { min = 8, cooldown = 2700, air_max = 0.5, release_after = 150, candidates = 8 } }

local CMD_ATTACK = 20

function M.Init(st) st.lastF, st.released = -99999, true end

function M.Update(st, group, ctx, frame, host)
    local c = st.cfg
    if ctx.Hunting() then return nil end
    -- a finished run: let the bombers go home
    if not st.released and frame - st.lastF >= c.release_after then
        for _, u in ipairs(group.list) do ctx.Release(u.uid) end
        st.released = true
    end
    if not st.released then return true end                    -- the run is on: nothing else may order them
    if #group.list < c.min or frame - st.lastF < c.cooldown then return nil end
    local value = 0
    for _, u in ipairs(group.list) do value = value + u.v end
    local hx, hz = ctx.Home()
    local best
    for _, t in ipairs(ctx.Rank(frame, hx, hz, c.candidates, nil)) do
        if not t.mobile and (ctx.AirThreatAt(frame, t.x, t.z) or 0) <= c.air_max * value then best = t; break end
    end
    if not best then return nil end
    local tid = best.uid and ctx.Alive(best.uid) and best.uid or nil
    for _, u in ipairs(group.list) do host:Order(frame, u.uid, CMD_ATTACK, best.x, best.z, tid) end
    st.lastF, st.released = frame, false
    local d = best.defID and UnitDefs[best.defID]
    ctx.Log(frame, "bomber run: %d bombers -> %s%s at (%d,%d)", #group.list, best.labBP and "LAB-BP " or "", d and d.name or "?", best.x, best.z)
    return true
end

function M.Describe(cfg) return string.format("%d+ bombers strike together every %d frames, lab build power first", cfg.min, cfg.cooldown) end
return M
