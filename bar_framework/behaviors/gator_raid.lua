-- bar_framework/behaviors/gator_raid.lua
-- A NAME for what Incisors (corgator) do in the raid stances, so a stance, the machine editor and the logs say it (user 2026-10-28:
-- "create a named raid behaviour for gators and brutes just so it is easy to keep track of what they are doing").
--
-- It issues NO orders and claims nothing.  The orders come from the owners the army already has, one owner per kind of order:
--   click_army   raid groups: stage -> launch -> target (enemy build power / eco / commander) -> steer round enemy force (SURVIVE) -> dive a
--                hole or skirmish the target; batch reinforcements join the weakest group
--   raid_response a responder inside the base footprint is moved by `intercept` instead (the stance's behaviours come back afterwards)
--   unit_runtime  hurt units step back (UpdateRetreats / squad_retreat), the first ground units garrison the base
-- Its only job is attribution: a [BEH] row every `log_every` frames with how many units carry it and who is driving them.
-- The same file serves brute_raid.lua (the name differs, so a stance can tune or tell them apart).

local M = {
    name = "gator_raid",
    cfg = { log_every = 1800 },
    describes = "Incisor raid: click_army raid groups (steer round enemy force, hit build power / eco), raid_response intercepts raiders inside the base",
}

function M.Init(st) st.logF = -1e9 end

function M.Update(st, group, ctx, frame, host)
    local cfg = group.cfg
    if frame - st.logF >= cfg.log_every then
        st.logF = frame
        local drivers = {}
        for _, u in ipairs(group.list) do
            local role = (ctx and ctx.RoleOf and ctx.RoleOf(u.uid)) or "?"
            drivers[role] = (drivers[role] or 0) + 1
        end
        local parts = {}
        for role, n in pairs(drivers) do parts[#parts + 1] = role .. "=" .. n end
        table.sort(parts)
        Spring.Echo(string.format("[BEH] %d:%02d %s: %d units (%s)", math.floor(frame / 1800), math.floor(frame / 30) % 60,
            M.name, #group.list, table.concat(parts, " ")))
    end
    return nil
end

function M.Describe() return M.describes end

return M
