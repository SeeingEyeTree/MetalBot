-- bar_framework/behaviors/pick_target.lua
-- ARMY behaviour, first in an army stack.  Chooses the army's targets and publishes them, and the numbers the later
-- behaviours (commander_strike, flank, spread, run_by, attack_target) read from ctx.shared.  Claims no unit.
--
--   HOW MANY TARGETS: cfg.count = a number, or function(sh, frame) -> number (sh.n = army units, sh.total = army value).
--   Default: 1 target under 20 units, 2 under 50, 3 from there -- a small army must not split.  Targets are at least
--   DIFF_R apart (click_army), best first.
--   PRIORITY: build power near an enemy lab (a nano / con / builder within LAB_BP_R of a factory) is ALWAYS first
--   (t.labBP), above every other target.  The enemy commander in the open overrides all of it, except while lab build power
--   is still standing (cfg.commander_over_lab_bp = true lets the commander win instead).
--
--   shared.targets   the list (best first)      shared.target  = targets[1]       shared.tx/tz  where target 1 is
--   shared.n/total   the army this tick (units, army value)    shared.cx/cz  its centre
--   shared.enemyV    enemy armed value at target 1             shared.labBP  true while target 1 is lab build power
-- Targets are kept `hold` frames; they are re-picked sooner when one dies, the count changes, or lab build power appears.
-- ctx needs: Foe() Rank(frame,cx,cz,k,value,avoid) Commander(frame,value,keeping) ThreatAt(frame,x,z) Alive(uid) Log(frame,fmt,...) shared
local M = { name = "pick_target", cfg = {
    hold = 1200,
    count = function(sh) return (sh.n < 20 and 1) or (sh.n < 50 and 2) or 3 end,
    commander_over_lab_bp = false,
} }

local function Describe1(t)
    return string.format("%s%s (%d,%d)", t.labBP and "LAB-BP " or "", tostring(t.name or t.kind or "target"), t.x, t.z)
end

function M.Update(st, group, ctx, frame)
    local sh, c = ctx.shared, st.cfg
    local n, total, sx, sz = 0, 0, 0, 0
    for _, u in ipairs(group.list) do n, total, sx, sz = n + 1, total + u.v, sx + u.x, sz + u.z end
    if n == 0 then return nil end
    local cx, cz = sx / n, sz / n
    sh.n, sh.total, sh.cx, sh.cz = n, total, cx, cz
    local want = type(c.count) == "function" and c.count(sh, frame) or c.count or 1
    want = math.max(1, math.floor(want))

    local cur = sh.targets
    local cand = ctx.Rank(frame, cx, cz, want, total)
    local labFirst = cand[1] and cand[1].labBP
    local cmdr = ctx.Commander(frame, total, cur and cur[1] and cur[1].commander)
    if cmdr and labFirst and not c.commander_over_lab_bp then cmdr = nil end
    if cmdr then
        if not (cur and cur[1] and cur[1].commander) then
            ctx.Log(frame, "ENEMY COMMANDER open at (%d,%d), guard av=%d -> all %d units", cmdr.x, cmdr.z, cmdr.guard or 0, n)
        end
        sh.targets, sh.pickF = { cmdr }, frame
    else
        local stale = not cur or not sh.pickF or frame - sh.pickF >= c.hold or #cur ~= math.min(want, #cand)
                      or (cur[1] and cur[1].commander) or (labFirst and not (cur[1] and cur[1].labBP))
        if not stale then
            for _, t in ipairs(cur) do if t.uid and not ctx.Alive(t.uid) then stale = true; break end end
        end
        if stale then
            if (#cand > 0 or cur) and frame - (st.logF or -1e9) >= 450 then
                st.logF = frame
                local parts = {}
                for _, t in ipairs(cand) do parts[#parts + 1] = Describe1(t) end
                local fx, fz = ctx.Foe()
                ctx.Log(frame, "targets (%d wanted): %d units -> %s", want, n,
                    #parts > 0 and table.concat(parts, " | ") or string.format("enemy start (%d,%d)", fx, fz))
            end
            sh.targets, sh.pickF = cand, frame
        end
    end
    local t = sh.targets[1]
    sh.target = t
    if t then sh.tx, sh.tz = t.x, t.z else sh.tx, sh.tz = ctx.Foe() end
    sh.labBP = t and t.labBP or false
    sh.enemyV = ctx.ThreatAt(frame, sh.tx, sh.tz) or 0
    return nil
end

function M.Describe(cfg) return "1-3 shared targets (count by army size), build power near enemy labs always first, held " .. cfg.hold .. " frames" end
return M
