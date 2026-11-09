-- bar_framework/defence/build.lua  (area_defence: the construction squad -- a STUB)
-- User 2026-11-08: "The last is a construction system, it can get cons to build static defense.  Just have that be a stub for now."
-- It collects what the checklist would have built (static AA under air, an anti-nuke where a silo is seen ...) per area and logs it; it orders
-- nothing.  The interface is what a real one will keep: Want() each tick a need stands (a want not renewed for STALE frames is dropped), Wants()
-- for whoever builds them (con_broker's pools, later).
--
--   local B = VFS.Include("LuaUI/Widgets/bar_framework/defence/build.lua").New{ cfg }
--   B.Want(areaId, key, what, n, why)   B.Step(frame)   B.Wants() -> { [areaId .. ":" .. key] = { area, key, what, n, why, frame } }

local M = {}

M.CFG = { STALE = 450, LOG_EVERY = 1800 }

function M.New(o)
    local C = {}
    for k, v in pairs(M.CFG) do C[k] = v end
    for k, v in pairs((o and o.cfg) or {}) do C[k] = v end
    local B = {}
    local wants, logF = {}, -1e9

    function B.Want(areaId, key, what, n, why)
        local k = tostring(areaId) .. ":" .. key
        local w = wants[k] or { area = areaId, key = key, first = Spring.GetGameFrame() }
        w.what, w.n, w.why, w.frame = what, n, why, Spring.GetGameFrame()
        wants[k] = w
    end

    function B.Step(frame)
        for k, w in pairs(wants) do if frame - w.frame > C.STALE then wants[k] = nil end end
        if frame - logF < C.LOG_EVERY or not next(wants) then return end
        logF = frame
        local parts = {}
        for _, w in pairs(wants) do parts[#parts + 1] = string.format("%s wants %d %s (%s)", w.area, w.n or 0, w.what, w.why or w.key) end
        table.sort(parts)
        Spring.Echo(string.format("[DEF] %d:%02d build (stub, nothing ordered): %s", math.floor(frame / 1800), math.floor(frame / 30) % 60, table.concat(parts, "; ")))
    end

    function B.Wants() return wants end
    return B
end

return M
