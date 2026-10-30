-- tests/engine/transport_fixture/transport_test.lua -- engine test for bar_framework/air_transport.lua (run by tests/engine/transport_test.py).
-- Loaded for both teams by single_client.py (the per-team shim); only team 0 acts.  The single-client host has `cheat` on, so it spawns
-- with /give, then moves each load ~1200 elmos east with AT.Move (force: the engine decides; AT.CanCarry is logged beside it) and reports:
--   [TT] case <key> ...   [TT] job <key> started / carrying / DONE | FAILED (why)   [TT] case <key> OK | WRONG   [TT] RESULT pass=<n> fail=<n>
-- Cases (game data, units/*.lua: corvalk transportmass 750; cornanotc mass 700, corck light, corhllt mass 10200; corseah has no
-- transportmass, so the engine default 100000):
--   valk_nano   corvalk lifts cornanotc         -> done
--   valk_con    corvalk lifts corck             -> done
--   valk_hllt   corvalk on corhllt              -> refused (CanCarry false, and the engine drops the load order)
--   seah_hllt   corseah (T2 transport) on corhllt -> done
function widget:GetInfo()
    return { name = "Transport Test", desc = "air_transport.lua engine test", layer = 0, enabled = true }
end

local AT = VFS.Include("LuaUI/Widgets/bar_framework/air_transport.lua")
local TEAM = 0
local SPAWN_F, START_F, END_F = 90, 240, 240 + 75 * 30
local X0, Z0, DX = 3000, 2600, 1200
local CASES = {
    { key = "valk_nano", load = "cornanotc", tr = "corvalk", expect = "done" },
    { key = "valk_con",  load = "corck",     tr = "corvalk", expect = "done" },
    { key = "valk_hllt", load = "corhllt",   tr = "corvalk", expect = "refused" },
    { key = "seah_hllt", load = "corhllt",   tr = "corseah", expect = "done" },
}
local mine = Spring.GetMyTeamID() == TEAM
local byKey, pass, fail, decided, reported = {}, 0, 0, 0, false

local function Echo(fmt, ...) Spring.Echo(string.format("[TT] " .. fmt, ...)) end

local function Give(name, x, z)
    Spring.SendCommands(string.format("give 1 %s %d @%d,%d,%d", name, TEAM, x, Spring.GetGroundHeight(x, z) or 0, z))
end

local function Find(name, x, z)
    local best, bd
    for _, uid in ipairs(Spring.GetTeamUnits(TEAM) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and d.name == name then
            local ux, _, uz = Spring.GetUnitPosition(uid)
            local dd = (ux - x) ^ 2 + (uz - z) ^ 2
            if dd < 200 * 200 and (not bd or dd < bd) then best, bd = uid, dd end
        end
    end
    return best
end

local function Verdict(c, outcome, detail)
    decided = decided + 1
    local ok = (outcome == c.expect)
    if ok then pass = pass + 1 else fail = fail + 1 end
    Echo("case %s %s: expected %s, got %s%s", c.key, ok and "OK" or "WRONG", c.expect, outcome, detail and (" -- " .. detail) or "")
end

function widget:GameFrame(f)
    if not mine then return end
    if f == SPAWN_F then
        for i, c in ipairs(CASES) do
            c.z = Z0 + (i - 1) * 500
            Give(c.load, X0, c.z)
            Give(c.tr, X0 - 300, c.z)
        end
        Echo("spawn orders sent")
    elseif f == START_F then
        for _, c in ipairs(CASES) do
            local unit, tr = Find(c.load, X0, c.z), Find(c.tr, X0 - 300, c.z)
            if not (unit and tr) then
                Verdict(c, "missing", string.format("spawn: %s=%s %s=%s", c.load, tostring(unit), c.tr, tostring(tr)))
            else
                local ux, _, uz = Spring.GetUnitPosition(unit)
                c.canCarry, c.why = AT.CanCarry(Spring.GetUnitDefID(tr), Spring.GetUnitDefID(unit))
                Echo("case %s: %s=%d at (%d, %d), %s=%d; CanCarry %s %s", c.key, c.load, unit, ux, uz, c.tr, tr, tostring(c.canCarry), c.why or "")
                local job, why = AT.Move(tr, unit, ux + DX, uz, f, { timeout = 70 * 30, force = true })
                if job then
                    job.case = c
                    byKey[c.key] = job
                    Echo("job %s started: transport %d -> (%d, %d)", c.key, tr, ux + DX, uz)
                else
                    Verdict(c, "not started", tostring(why))
                end
            end
        end
    elseif f > START_F then
        for key, job in pairs(byKey) do
            if job.state == "carrying" and not job.said then
                job.said = true
                Echo("job %s carrying after %.1f s", key, (f - job.startF) / 30)
            end
        end
        for _, job in ipairs(AT.Update(f)) do
            local c = job.case
            local x, _, z = Spring.GetUnitPosition(job.unit)
            if job.state == "done" then
                Echo("job %s DONE after %.1f s: set down at (%d, %d), target (%d, %d)", c.key, (f - job.startF) / 30, x or -1, z or -1, job.x, job.z)
                Verdict(c, "done")
            else
                Echo("job %s FAILED: %s (unit at %s, %s)", c.key, tostring(job.why), tostring(x and math.floor(x)), tostring(z and math.floor(z)))
                -- "refused" = the def check said no AND the engine would not load it either
                Verdict(c, (c.canCarry == false and job.why == "the transport dropped the load order") and "refused" or "failed", job.why)
            end
        end
        if not reported and (f >= END_F or decided >= #CASES) then
            reported = true
            Echo("RESULT pass=%d fail=%d", pass, fail)
        end
    end
end
