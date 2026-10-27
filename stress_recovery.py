"""stress_recovery.py -- does CORE rebuild what it loses?  (eco_sim, ~30 s a game, no enemy needed)

  python stress_recovery.py [--bot candidates/CORE] [--seeds 1] [--only spine_nanos,t1_cons] [--minutes 20] [--set line_transition.X=1 ...]

Each scenario is a Lua patch (eco_sim --patch) that destroys units at set frames with Spring.DestroyUnit(uid, attacker) -- an attacker id so the
bot sees "the enemy killed it" -- and logs a census row every 30 s.  This script prints, per scenario, the census around the kills so you can see
whether the counts come back and how long it takes.

Census classes: spine nanos (WG.Spine.State().nanos), grid nanos / grid mexes (farther than GRID_R from home), line nanos / line mexes (closer),
T1 cons (corck corcv corca), T2 cons (corack coracv coraca), labs (ground + air factories), nano total, metal income.
Kill selectors: spine_nano grid_nano line_nano grid_mex t1_con t2_con lab (a count, or "all").
"""
import argparse, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
M = 1800     # frames per minute

SCENARIOS = {
    "baseline":     [],
    "spine_nanos":  [(10 * M, "spine_nano", 8)],
    "grid_nanos":   [(10 * M, "grid_nano", 8)],
    "line_nanos":   [(10 * M, "line_nano", 6)],
    "grid_mexes":   [(10 * M, "grid_mex", 6)],
    "t1_cons":      [(10 * M, "t1_con", "all")],
    "t1_few":       [(10 * M, "t1_con", 12)],
    "t2_cons":      [(14 * M, "t2_con", "all")],
    "grid_dead":    [(12 * M, "grid_dead", 1), (14 * M, "grid_dead", 1)],
    "labs":         [(12 * M, "lab", 2)],
    "everything":   [(10 * M, "spine_nano", 8), (10 * M, "grid_nano", 8), (10 * M, "grid_mex", 6), (10 * M, "t1_con", "all"), (10 * M, "lab", 1)],
    "repeat":       [(f * M, "spine_nano", 4) for f in (9, 11, 13, 15)] + [(f * M, "grid_nano", 4) for f in (10, 12, 14, 16)],
}

LUA = r"""
local GRID_R = 900
local NANO, T1CON, T2CON = "cornanotc", { corck = 1, corcv = 1, corca = 1 }, { corack = 1, coracv = 1, coraca = 1 }
local LAB = { corlab = 1, corvp = 1, corap = 1, coralab = 1, coravp = 1, coraap = 1, corgant = 1 }
local function Home() local mb = WG.MetalBot or {}; return mb.homeX, mb.homeZ end
local function Far(uid)
    local hx, hz = Home(); local x, _, z = Spring.GetUnitPosition(uid)
    if not (hx and x) then return false end
    return (x - hx) ^ 2 + (z - hz) ^ 2 > GRID_R ^ 2
end
local function SpineSet()
    local out = {}
    local ok, ss = pcall(function() return WG.Spine and WG.Spine.State and WG.Spine.State() end)
    if ok and ss and ss.nanos then for uid in pairs(ss.nanos) do out[uid] = true end end
    return out
end
local function GridDead()
    -- everything within 260 elmos of the first far nano (nano, mexes, fusions, wind ...): a whole grid destroyed
    local out, c = {}, nil
    for _, uid in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and d.name == NANO and not Spring.GetUnitIsBeingBuilt(uid) and Far(uid) then c = { Spring.GetUnitPosition(uid) }; break end
    end
    if not c then return out end
    for _, uid in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
        local x, _, z = Spring.GetUnitPosition(uid)
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if x and d and not d.canMove and not Spring.GetUnitIsBeingBuilt(uid) and (x - c[1]) ^ 2 + (z - c[3]) ^ 2 < 260 ^ 2 then out[#out + 1] = uid end
    end
    return out
end
local function Select(kind)
    if kind == "grid_dead" then return GridDead() end
    local out, sp = {}, (kind == "spine_nano" or kind == "grid_nano" or kind == "line_nano") and SpineSet() or nil
    for _, uid in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and not Spring.GetUnitIsBeingBuilt(uid) then
            local n = d.name
            if (kind == "spine_nano" and n == NANO and sp[uid]) or (kind == "grid_nano" and n == NANO and not sp[uid] and Far(uid))
               or (kind == "line_nano" and n == NANO and not sp[uid] and not Far(uid)) or (kind == "grid_mex" and (n == "cormex" or n == "cormoho") and Far(uid))
               or (kind == "t1_con" and T1CON[n]) or (kind == "t2_con" and T2CON[n]) or (kind == "lab" and LAB[n]) then out[#out + 1] = uid end
        end
    end
    table.sort(out)
    return out
end
local function Census(frame)
    local c = { sn = 0, gn = 0, ln = 0, gm = 0, lm = 0, t1 = 0, t2 = 0, lab = 0 }
    local sp = SpineSet()
    for _, uid in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
        if d and not Spring.GetUnitIsBeingBuilt(uid) then
            local n = d.name
            if n == NANO then if sp[uid] then c.sn = c.sn + 1 elseif Far(uid) then c.gn = c.gn + 1 else c.ln = c.ln + 1 end
            elseif n == "cormex" or n == "cormoho" then if Far(uid) then c.gm = c.gm + 1 else c.lm = c.lm + 1 end
            elseif T1CON[n] then c.t1 = c.t1 + 1 elseif T2CON[n] then c.t2 = c.t2 + 1 elseif LAB[n] then c.lab = c.lab + 1 end
        end
    end
    local _, _, _, inc = Spring.GetTeamResources(Spring.GetMyTeamID(), "metal")
    Spring.Echo(string.format("[CENSUS] f=%d spineN=%d gridN=%d lineN=%d gridM=%d lineM=%d t1con=%d t2con=%d labs=%d inc=%.0f", frame, c.sn, c.gn, c.ln, c.gm, c.lm, c.t1, c.t2, c.lab, inc or 0))
end
local kills, ki, lastC = KILLS, 1, -1e9
local S = WG.Strategy
if not S then error("stress_recovery: no WG.Strategy") end
local origTick = S.Tick
S.Tick = function(self, frame, state)
    if frame - lastC >= 900 then lastC = frame; Census(frame) end
    while kills[ki] and frame >= kills[ki][1] do
        local list, want = Select(kills[ki][2]), kills[ki][3]
        local n = 0
        for _, uid in ipairs(list) do
            if want == "all" or n < want or kills[ki][2] == "grid_dead" then Spring.DestroyUnit(uid, 999999); n = n + 1 end
        end
        Spring.Echo(string.format("[STRESS] f=%d killed %d %s (of %d)", frame, n, kills[ki][2], #list))
        ki = ki + 1
    end
    return origTick(self, frame, state)
end
"""


def patch_lua(kills):
    rows = ", ".join('{%d, "%s", %s}' % (f, k, ('"all"' if n == "all" else n)) for f, k, n in kills)
    return "local KILLS = {" + rows + "}\n" + LUA


CEN = re.compile(r"\[CENSUS\] f=(\d+) spineN=(\d+) gridN=(\d+) lineN=(\d+) gridM=(\d+) lineM=(\d+) t1con=(\d+) t2con=(\d+) labs=(\d+) inc=(\d+)")


def report(name, logpath, kills):
    txt = open(logpath, errors="ignore").read()
    rows = [tuple(int(x) for x in m.groups()) for m in CEN.finditer(txt)]
    errs = len(re.findall(r"SIM-ERR|Lua error|\[string", txt))
    print(f"\n== {name}   (sim errors: {errs})")
    for ln in re.findall(r"\[STRESS\] .*", txt):
        print("  " + ln)
    print("   min  spineN gridN lineN gridM lineM t1con t2con labs  inc")
    kf = [k[0] for k in kills]
    for r in rows:
        f = r[0]
        if f < 9 * M or (f // 900) % 2:
            continue
        mark = "  <- kill this interval" if any(0 <= f - k < 900 for k in kf) else ""
        print(f"  {f / M:5.1f}  {r[1]:6d} {r[2]:5d} {r[3]:5d} {r[4]:5d} {r[5]:5d} {r[6]:5d} {r[7]:5d} {r[8]:4d} {r[9]:4d}{mark}")
    for kw in ("RECOVER", "rebuilt", "REBUILD", "recover"):
        n = len(re.findall(kw, txt))
        if n:
            print(f"  log mentions '{kw}': {n}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bot", default="candidates/CORE")
    ap.add_argument("--seeds", default="1")
    ap.add_argument("--only", default="")
    ap.add_argument("--minutes", default="20")
    ap.add_argument("--set", action="append", default=[], help="eco_sim --set module.KEY=V (repeatable)")
    ap.add_argument("--tag", default="")
    a = ap.parse_args()
    names = [n for n in SCENARIOS if not a.only or n in a.only.split(",")]
    tmp = tempfile.mkdtemp(prefix="recov_")
    for n in names:
        pf = os.path.join(tmp, n + ".lua")
        open(pf, "w").write(patch_lua(SCENARIOS[n]))
        tag = "recov_" + (a.tag + "_" if a.tag else "") + n
        cmd = [sys.executable, os.path.join(ROOT, "eco_sim.py"), "run", "--bot", a.bot, "--tag", tag, "--seeds", a.seeds,
               "--no-vacuum", "--patch", pf, "--minutes", a.minutes]
        for s in a.set:
            cmd += ["--set", s]
        subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        rundir = os.path.join(ROOT, "ecosim", "runs", tag)
        subs = sorted(d for d in os.listdir(rundir) if d.startswith("s") and os.path.isdir(os.path.join(rundir, d))) or [""]
        for s in subs:
            report(n + (" " + s if s else ""), os.path.join(rundir, s, "log.txt"), SCENARIOS[n])
    return 0


if __name__ == "__main__":
    sys.exit(main())
