-- bar_framework/support/rez.lua  (army_groups element: rez bots that work for one group)
-- User 2026-10-30: "It could also adopt rez bots to repair its units or to reclaim where it is fighting."  The rez bots stay rez_broker's
-- (the one owner of rez-bot orders); this element ADOPTS up to n of them per group (the rez floor in lab_rules builds what is missing: the
-- unmet want is added to its room) and registers one rez_broker job, "group" (prio GROUP_PRIO, above wreck 60, urgent), that only an adopted
-- bot takes: repair the most damaged unit of the group within REPAIR_R, else reclaim the best safe wreck within the group's reach, else
-- follow TRAIL elmos behind the group.  A bot in the pool (its group fell) is not adopted by any job here: rez_broker's own jobs run it.
-- cfg: n, TRAIL, REPAIR_R, GROUP_PRIO.
local M = { name = "rez" }
M.CFG = { N = 3, TRAIL = 350, REPAIR_R = 700, GROUP_PRIO = 70 }

local CMD_MOVE, CMD_REPAIR = 10, 40
local wreckBusy = {}

local function Hp(uid)
    local hp, mx = Spring.GetUnitHealth(uid)
    if hp and mx and mx > 0 then return hp / mx end
    return nil
end

function M.Init(ctx)
    wreckBusy = {}
    local RB, RC, MM = ctx.RB, ctx.RC, ctx.MM
    if not (RB and RC and RB.AddJob) then return end
    if RB.RemoveJob then RB.RemoveJob("group") end
    RB.AddJob{ name = "group", prio = M.CFG.GROUP_PRIO, urgent = true,
        find = function(bot)
            local rec = ctx.RecordOf(bot.uid)
            if rec and rec.id ~= 0 and rec.cx then return { gid = rec.id } end
        end,
        valid = function(bot, st)
            local rec = ctx.RecordOf(bot.uid)
            return rec ~= nil and rec.id == st.target.gid and rec.cx ~= nil
        end,
        claim = function(bot, st)
            local rec = ctx.RecordOf(bot.uid)
            local c = (rec.want and rec.want.rez) or M.CFG          -- this group kind's settings (army_groups fills in the defaults)
            -- repair: the most damaged friend near the group's centre
            local fid = RC.DamagedFriend(bot.uid, rec.cx, rec.cz)
            if fid then
                local fx, _, fz = Spring.GetUnitPosition(fid)
                if fx and (fx - rec.cx) ^ 2 + (fz - rec.cz) ^ 2 <= (c.REPAIR_R or M.CFG.REPAIR_R) ^ 2 and (Hp(fid) or 1) < 0.95 then
                    return { role = "REZ", cmd = CMD_REPAIR, targetID = fid }
                end
            end
            -- reclaim: a safe wreck where the group is fighting (kept while it lasts, so the order does not flip)
            local w = st.target.wreck
            if w and Spring.ValidFeatureID and not Spring.ValidFeatureID(w.fid) then
                if wreckBusy[w.fid] == bot.uid then wreckBusy[w.fid] = nil end
                w, st.target.wreck = nil, nil
            end
            if not w then
                local wid, cmd = RC.BestWreck(bot.frame, bot.uid, rec.cx, rec.cz, wreckBusy, true)
                if wid then w = { fid = wid, cmd = cmd }; st.target.wreck = w; wreckBusy[wid] = bot.uid end
            end
            if w then
                local maxUnits = Game and Game.maxUnits or 32000
                return { role = "REZ", cmd = w.cmd, targetID = w.fid + maxUnits }
            end
            -- follow behind the group
            local x, z = ctx.Spot(rec, -(c.TRAIL or M.CFG.TRAIL), bot.i, 80)
            return { role = "REZ", cmd = CMD_MOVE, x = x, z = z }
        end,
        drop = function(bot, st)
            local w = st.target and st.target.wreck
            if w and wreckBusy[w.fid] == bot.uid then wreckBusy[w.fid] = nil end
        end,
    }
end

-- Rez bots rez_broker runs (any that no element holds yet: army_groups skips the ones it owns).
function M.Adopt(ctx)
    local RC = ctx.RC
    if not (RC and RC.Members) then return {} end
    return RC.Members()
end

-- Orders come from the rez_broker job above.
function M.Update(rec, units, cfg, frame, ctx) end

return M
