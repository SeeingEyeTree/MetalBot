-- bar_framework/support/scout.lua  (army_groups element: constant scouting ahead of a group)
-- User 2026-10-30: "Constant scouting would be calling for an air scout to fly over an area at a set frequency."  No units of its own: every
-- every_s seconds the group asks scout_net for a scout run (SN.RequestScout, kind KIND, until it arrives) over its target, else AHEAD elmos
-- in front of its centre.  The request has a per-group key, so a repeat call refreshes the same request instead of piling up.
-- cfg: every_s, AHEAD, KIND ("scout" | "hawk" | "any": which units scout_net may send), TTL_S.
local M = { name = "scout", NoUnits = true }
M.CFG = { N = 0, every_s = 30, AHEAD = 1500, KIND = "scout", TTL_S = 25 }

local nextAt = {}      -- [record id] = frame of the next call

function M.Init() nextAt = {} end

function M.Update(rec, units, cfg, frame, ctx)
    if rec.id == 0 or not ctx.SN then return end
    if frame < (nextAt[rec.id] or 0) then return end
    nextAt[rec.id] = frame + math.floor((cfg.every_s or 30) * 30)
    local x, z
    if rec.target and rec.target.x then x, z = rec.target.x, rec.target.z
    else x, z = ctx.Spot(rec, cfg.AHEAD or 1500, 0, 0) end
    ctx.SN.RequestScout(x, z, { key = "sup:" .. rec.id, kind = cfg.KIND or "scout", untilMode = "arrive",
                                ttl = math.floor((cfg.TTL_S or 25) * 30), by = "support" })
end

return M
