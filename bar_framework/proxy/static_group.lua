-- bar_framework/proxy/static_group.lua  (what the proxy's static build groups build next -- user 2026-11-08)
-- User: "there is a few t2 cons that build the static that is good but they need t1 vech cons helping them build to have more bp ... after 10 scorpions
-- swap over to build Persecutor and Bulwark.  Some more aa also needs to be mixed in, build some Birdshot and Screamers ... make sure that as the static
-- line advances a radar is added on so that the max range of a static is within radar range.  Persecutor has range 1.4k and radar is 3500 so the furthest
-- radar should be from a Persecutor is 2100 elmos ... A static build group would be 3 t2 cons and 8 t1 cons, and they keep getting added on and building."
-- The next item for a group's T2 con, proxy-wide counts (planned + standing):
--   1. the Shroud and the T2 radar (once each);
--   2. RADAR COVER: a Persecutor or Bulwark with no radar of ours within RADAR_COVER gets a T2 radar next to it (toward the lab);
--   AFTER THE RADARS, a Persecutor wanted behind a hot spot (crew.lua: front static lost twice in one place, user 2026-11-09: "pull back a little bit and
--      build perscuters insted of scorpians");
--   3. AA: Birdshot : Screamer FLAK_PER : 1, one AA per AA_EVERY ground defences (AA_EVERY_AIR while the proxy loses cons / buildings to air);
--   4. ground: Scorpions until SCORPIONS (none while a spot is hot), then Persecutor : Bulwark 1 : 1.  (SCORPIONS 5, user 2026-11-09: "The main way I would
--      see to break the proxy is heavy t3 units that is stoped best by Bulwarks, lower the threshold to 5 scorpians")
--
--   local SG = VFS.Include("LuaUI/Widgets/bar_framework/proxy/static_group.lua")
--   SG.Next(C, Count, items, { repl = { x, z } | nil, hot = bool, air = bool }) -> { what = role, kind = item kind, at = { x, z } | nil, repl = the repl given | nil }

local M = {}

M.CFG = { SCORPIONS = 5, AA_EVERY = 3, AA_EVERY_AIR = 1, FLAK_PER = 2, RADAR_COVER = 2100 }

local RADARS = { radar = true, radar_t2 = true, cover_radar = true }

-- a Persecutor / Bulwark (planned or standing) with no radar item of ours within RADAR_COVER: its position
local function Uncovered(items, R)
    for _, it in ipairs(items) do
        if it.kind == "grid_arty" or it.kind == "grid_bulwark" then
            local covered = false
            for _, r in ipairs(items) do
                if RADARS[r.kind] and (r.x - it.x) ^ 2 + (r.z - it.z) ^ 2 <= R * R then covered = true; break end
            end
            if not covered then return it end
        end
    end
    return nil
end

function M.Next(C, Count, items, st)
    st = st or {}
    if Count("jammer_t2") < 1 then return { what = "jammer_t2", kind = "jammer_t2" } end
    if Count("radar_t2") < 1 then return { what = "radar_t2", kind = "radar_t2" } end
    local u = Uncovered(items, C.RADAR_COVER)
    if u then return { what = "radar_t2", kind = "cover_radar", at = { u.x, u.z } } end
    if st.repl then return { what = "def_t2_arty", kind = "grid_arty", at = { st.repl.x, st.repl.z }, repl = st.repl } end
    local ground = Count("grid_pop") + Count("grid_arty") + Count("grid_bulwark")
    local aa = Count("grid_flak") + Count("grid_screamer")
    local every = st.air and (C.AA_EVERY_AIR or 1) or C.AA_EVERY
    if aa < math.floor(ground / every) + (st.air and 1 or 0) then
        if Count("grid_flak") < C.FLAK_PER * (Count("grid_screamer") + 1) then return { what = "aa_heavy", kind = "grid_flak" } end
        return { what = "aa_long", kind = "grid_screamer" }
    end
    if Count("grid_pop") < C.SCORPIONS and not st.hot then return { what = "def_t2_popup", kind = "grid_pop" } end
    if Count("grid_arty") <= Count("grid_bulwark") then return { what = "def_t2_arty", kind = "grid_arty" } end
    return { what = "def_t2_bulwark", kind = "grid_bulwark" }
end

return M
