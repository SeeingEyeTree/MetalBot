-- bar_framework/behaviors/brute_raid.lua
-- The Brute (corraid) twin of gator_raid.lua: the same name-only attribution (no orders, claims nothing), so a stance and the logs say
-- "this is a Brute raid unit".  Brutes are tougher and slower (72 vs 85) than Incisors: the raid groups click_army forms from them are the
-- main body of the push stances, which hit enemy build power / eco and kite back rather than return home.  See gator_raid.lua.

local M = {
    name = "brute_raid",
    cfg = { log_every = 1800 },
    describes = "Brute raid: click_army raid groups (steer round enemy force, hit build power / eco; reinforcements join in batches)",
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
