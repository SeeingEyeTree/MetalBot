"""stress_stances.py -- try to BREAK the system with odd stance schedules (eco_sim, ~20 s a game).  It tests the code architecture
(spine swap, lab planner, line decoy labs, sink), not the strategy: a stance that loses the game is fine, a slot stuck for minutes,
a Lua error, a swallowed [SIM-ERR], a job that never ends or an assisting decoy count that is off is a finding.

  python stress_stances.py [--bot candidates/CORE_STD] [--seeds 1-2] [--only flap60,rapid15] [--minutes 20]

Each variant is a Lua patch (ecosim --patch) that drops the strategy's switch hook and drives WG.Strategy:Set on a schedule, and may
kill units (Spring.DestroyUnit, added to the sim API).  Output: one JSON row per variant/seed with the findings counted from the run log.
"""
import argparse, os, re, subprocess, sys, tempfile, json

ROOT = os.path.dirname(os.path.abspath(__file__))
T1, T2, SH = "standard_t1_defence", "standard_t2_defence", "shiva_push"
ALL = ["raid_open", "hold", "raid_late", SH, "pounder_hold", "mammoth_hold", T1, T2, "T1_raid", "T2_defense", "Late_game"]
SYN = {   # stances defined inline (stance_loader.Prepare tables)
    "syn_air": [("corcrwh", 1.0)],                                                    # nothing a candidate lab can build
    "syn_everything": [("corak", .1), ("corgator", .1), ("corbw", .1), ("corsumo", .15), ("corshiva", .15), ("correap", .15),
                       ("corcrwh", .1), ("corlevlr", .15)],                           # every lab type at once
    "syn_one_t1": [("corak", 1.0)],
    "syn_t1air": [("corbw", .5), ("corveng", .5)],                                    # T1 air lab only (two per block)
    "syn_t2air": [("corvamp", .6), ("corhurc", .4)],                                  # T2 air lab only (one per block)
    "syn_air_mix": [("corbw", .25), ("corvamp", .25), ("corgator", .25), ("correap", .25)],                                                   # a single T1 unit
}


def cycle(names, start, every, until=36000):
    out, f, i = [], start, 0
    while f < until:
        out.append((f, names[i % len(names)]))
        f += every
        i += 1
    return out


VARIANTS = {
    "baseline":   dict(sched=[]),      # the bot as it is (its own income switches)
    "flap60":     dict(sched=cycle([T1, T2, SH], 9000, 1800)),
    "rapid15":    dict(sched=cycle([T1, T2, SH], 9000, 450)),
    "allstances": dict(sched=cycle(ALL, 7200, 2400)),
    "reverse":    dict(sched=[(9000, T2), (13500, SH), (18000, T2), (22500, T1), (27000, SH), (31500, T1)]),
    "air_only":   dict(sched=[(9000, T2), (15000, "syn_air"), (24000, SH)]),
    "everything": dict(sched=[(9000, "syn_everything"), (18000, SH), (27000, "syn_everything")]),
    "one_t1":     dict(sched=[(9000, "syn_one_t1"), (16000, T2), (24000, SH)]),
    "air_t1":     dict(sched=[(9000, T2), (13000, "syn_t1air"), (20000, SH)]),
    "air_t2":     dict(sched=[(9000, T2), (13000, "syn_t2air"), (20000, SH)]),
    "air_mix":    dict(sched=[(9000, "syn_air_mix"), (18000, "syn_t1air"), (24000, "syn_t2air"), (30000, T2)]),
    "midswap":    dict(sched=[(14400, T2), (14400 + 150, SH), (14400 + 300, T1), (14400 + 450, T2)]),
    "kill_cons":  dict(sched=[(9000, T2), (18000, SH)], kill=[(f, "cons") for f in range(15000, 36000, 3000)]),
    "kill_labs":  dict(sched=[(9000, T2), (18000, SH)], kill=[(f, "labs") for f in range(16000, 36000, 4000)]),
}

LUA_TAIL = """local origTick = S.Tick
local si, ki = 1, 1
local KILL = { cons = { corack = true, corcv = true, corck = true },
               labs = { coravp = true, corvp = true, coralab = true, corgant = true, corlab = true } }
S.Tick = function(self, frame, state)
    while sched[si] and frame >= sched[si][1] do
        local name = sched[si][2]
        if self.stances[name] then self:Set(name, state) else Spring.Echo("[STRESS] no stance " .. name) end
        si = si + 1
    end
    while kills[ki] and frame >= kills[ki][1] do
        local set, n = KILL[kills[ki][2]], 0
        for _, uid in ipairs(Spring.GetTeamUnits(Spring.GetMyTeamID()) or {}) do
            local d = UnitDefs[Spring.GetUnitDefID(uid) or -1]
            if d and set[d.name] and not Spring.GetUnitIsBeingBuilt(uid) and n < 4 then Spring.DestroyUnit(uid); n = n + 1 end
        end
        Spring.Echo("[STRESS] killed " .. n .. " " .. kills[ki][2])
        ki = ki + 1
    end
    return origTick(self, frame, state)
end
"""


def patch_lua(v):
    L = ["local S = WG.Strategy", "if not S then error('stress: no WG.Strategy') end", "S.hooks.switch = nil",
         "local SL = S.loader"]
    for name, units in SYN.items():
        us = ", ".join('{ n = "%s", share = %s }' % (n, sh) for n, sh in units)
        L.append('do local st = SL.Prepare({ name = "%s", plan = { army = "raid" }, units = { %s } }); '
                 'if st then st.name = "%s"; S.stances["%s"] = st end end' % (name, us, name, name))
    for n in ALL:
        L.append('if not S.stances["%s"] then local st = SL.Load("%s"); if st then st.name = "%s"; S.stances["%s"] = st end end'
                 % (n, n, n, n))
    L.append("local sched, kills = {" + ", ".join("{%d, '%s'}" % (f, n) for f, n in v.get("sched", [])) + "}, {" +
             ", ".join("{%d, '%s'}" % (f, w) for f, w in v.get("kill", [])) + "}")
    L.append(LUA_TAIL)
    return "\n".join(L) + "\n"


def analyse(logpath):
    txt = open(logpath, errors="ignore").read()
    f = {}
    f["sim_err"] = len(re.findall(r"SIM-ERR", txt))
    f["not_built"] = len(re.findall(r"not built \(placer", txt))
    f["aborted"] = len(re.findall(r"line decoy lab .* aborted", txt))
    f["swaps"] = len(re.findall(r"swap: wave 1,", txt))
    f["stances"] = len(re.findall(r"\[STRAT\] stance", txt))
    f["decoy_labs"] = len(re.findall(r"LINE DECOY LAB finished", txt))
    long_jobs = set()
    for m in re.finditer(r"job (lab|clear) slot (\d+) (\w+) running (\d+)s", txt):
        if int(m.group(4)) >= 300:
            long_jobs.add((m.group(1), m.group(2)))
    f["stuck_jobs"] = len(long_jobs)
    rows = re.findall(r"\[SLOT\] [\d:]+ +blocks .*slots (.*)", txt)
    if rows:
        st = [x.split(":")[1].split("/")[0] for x in rows[-1].split() if ":" in x]
        f["slots_end"] = "%dL %dB %dC %dF" % (st.count("lab"), st.count("build"), st.count("clear"), st.count("free"))
    f["killed"] = sum(int(x) for x in re.findall(r"\[STRESS\] killed (\d+)", txt))
    f["no_stance"] = len(re.findall(r"\[STRESS\] no stance", txt))
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bot", default="candidates/CORE_STD")
    ap.add_argument("--seeds", default="1-2")
    ap.add_argument("--only", default="")
    ap.add_argument("--minutes", default="20")
    a = ap.parse_args()
    names = [n for n in VARIANTS if not a.only or n in a.only.split(",")]
    tmp = tempfile.mkdtemp(prefix="stress_")
    for n in names:
        pf = os.path.join(tmp, n + ".lua")
        open(pf, "w").write(patch_lua(VARIANTS[n]))
        tag = "stress_" + n
        cmd = [sys.executable, os.path.join(ROOT, "eco_sim.py"), "run", "--bot", a.bot, "--tag", tag, "--seeds", a.seeds,
               "--no-vacuum", "--sink", "--patch", pf, "--minutes", a.minutes]
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True).stdout
        inc = re.search(r"20:(\d+)", out.split("income (avg", 1)[-1]) if "income (avg" in out else re.search(r"%s: n=\d+ .*20:(\d+)" % tag, out)
        rundir = os.path.join(ROOT, "ecosim", "runs", tag)
        subs = sorted(d for d in os.listdir(rundir) if d.startswith("s") and os.path.isdir(os.path.join(rundir, d))) or [""]
        for s in subs:
            f = analyse(os.path.join(rundir, s, "log.txt"))
            f["variant"], f["seed"] = n, s or "s1"
            print(json.dumps(f), flush=True)
        print("  %-11s mean income@20 %s" % (n, inc.group(1) if inc else "?"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
