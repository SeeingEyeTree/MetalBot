"""eco_limit_sim.py -- how fast can the economy scale?  A fluid model with the real unit numbers.

    python eco_limit_sim.py                 # optimise a build schedule, print the best path and the limit
    python eco_limit_sim.py --eta 0.5 --cap 3000 --target 6400 --evals 4000
    python eco_limit_sim.py --check         # play the "bench-like" fixed schedule: does the model track the real bench?

State starts at 4:00 of the eco bench (23 T1 mex, 22 wind, 6 nano, 4 cons, ~56 m/s, bank 1.7k/1.7k).
Assets (cor, from the installed BAR unit defs; see /tmp dump in eco_scaling notes):
    mex1   50m 500e 1870bt   +S1 m/s (S1 = 2.2 measured), upkeep 3e
    moho  640m 8100e 14100bt  4x the extraction of a mex1 (retrofit: replaces a mex1), upkeep 20e
    wind   43m  175e  1680bt  +25 e/s
    fus  3600m 22000e 59000bt +850 e/s
    afus 9700m 48000e 329200bt +3000 e/s
    nano1 230m 3200e  5300bt  +200 bp          nano2 840m 12800e 21000bt +600 bp
    con   115m 2200e  5200bt  +55 bp (air con; also needs a slot)
Build power spends cost/buildtime per build-power-second on each asset, all scaled by the stall factor
min(metal available / needed, energy available / needed).  ETA is the share of nominal build power that is
actually useful (assist range, travel, idle cons): the bench's measured value is 0.3-1.0.
The schedule is open loop: shares of useful build power per asset type at 8 anchor times (linear in between),
found by (1+lambda) evolution.  It is a LIMIT: no latency, no placement failures, no enemy.
"""
import argparse
import math
import random

S1 = 2.2           # metal per T1 mex (measured in the bench)
A = {              # name: (metal, energy, buildtime)
    "mex1": (50, 500, 1870), "moho": (640, 8100, 14100), "wind": (43, 175, 1680), "fus": (3600, 22000, 59000),
    "afus": (9700, 48000, 329200), "nano1": (230, 3200, 5300), "nano2": (840, 12800, 21000), "con": (115, 2200, 5200),
}
TYPES = list(A)
BP = {"nano1": 200, "nano2": 600, "con": 55}
DT = 2.0


def start():
    return dict(M=1700.0, E=1700.0, mex1=23.0, moho=0.0, wind=22.0, fus=0.0, afus=0.0, nano1=6.0, nano2=0.0, con=4.0)


def simulate(sched, eta=0.5, cap=3000, smax=1800, horizon=2700, record=False, targets=(400, 800, 1600, 3200, 6400, 12800)):
    """sched[k][i]: weight of asset type i at anchor k (8 anchors over the horizon).  Returns (times to targets, path)."""
    s = start()
    n_anchor = len(sched)
    hit = {}
    path = []
    t = 0.0
    while t < horizon:
        # income
        mex_inc = (s["mex1"] + 4.0 * s["moho"]) * S1 + 2.0
        e_inc = s["wind"] * 25.0 + s["fus"] * 850.0 + s["afus"] * 3000.0 + 30.0
        upkeep = s["mex1"] * 3.0 + s["moho"] * 20.0
        # energy first goes to the mex upkeep: below it the mexes are throttled
        sat = 1.0 if (e_inc + s["E"] / DT) >= upkeep else max(0.05, (e_inc + s["E"] / DT) / upkeep)
        m_inc = mex_inc * sat
        for x in targets:
            if x not in hit and m_inc >= x:
                hit[x] = t
        # weights at this time (linear between anchors), then limits
        u = min(t / horizon, 1.0) * (n_anchor - 1)
        k = min(int(u), n_anchor - 2)
        f = u - k
        w = {}
        units = s["mex1"] + s["moho"] + s["wind"] + s["fus"] + s["afus"] + s["nano1"] + s["nano2"] + s["con"] + 1
        for i, name in enumerate(TYPES):
            w[name] = max(0.0, sched[k][i] * (1 - f) + sched[k + 1][i] * f)
        if units >= cap - 1:                    # no free slot: only slot-neutral builds (moho retrofits)
            for name in ("mex1", "wind", "fus", "afus", "nano1", "nano2", "con"):
                w[name] = 0.0
        if s["mex1"] + s["moho"] >= smax:
            w["mex1"] = 0.0
        if s["moho"] >= s["mex1"] + s["moho"] - 0.01:
            w["moho"] = 0.0
        tot = sum(w.values())
        bp_nom = 300.0 + s["nano1"] * BP["nano1"] + s["nano2"] * BP["nano2"] + s["con"] * BP["con"]
        if tot <= 0:
            B = 0.0
        else:
            B = bp_nom * eta
        need_m = need_e = 0.0
        rate = {}
        for name in TYPES:
            if w[name] > 0 and tot > 0:
                m, e, bt = A[name]
                r = B * w[name] / tot / bt            # items per second at full supply
                rate[name] = r
                need_m += r * m
                need_e += r * e
        avail_m = s["M"] + m_inc * DT
        avail_e = max(s["E"] + (e_inc - upkeep * sat) * DT, 0.0)
        fm = 1.0 if need_m * DT <= 1e-9 else min(1.0, avail_m / (need_m * DT))
        fe = 1.0 if need_e * DT <= 1e-9 else min(1.0, avail_e / (need_e * DT))
        stall = min(fm, fe)
        s["M"] = max(0.0, avail_m - need_m * stall * DT)
        s["E"] = max(0.0, s["E"] + (e_inc - upkeep * sat) * DT - need_e * stall * DT)
        for name, r in rate.items():
            d = r * stall * DT
            if name == "moho":
                d = min(d, s["mex1"] - 1e-9 if s["mex1"] > 0 else 0)
                s["mex1"] -= d
            s[name] += d
        if record and int(t) % 60 == 0:
            path.append((t, m_inc, e_inc, B, s["M"], s["E"], units, dict(s)))
        t += DT
    return hit, path, m_inc


def score(hit, m_end, target, horizon):
    if target in hit:
        return hit[target]
    return horizon + 1000.0 * max(0.0, math.log(target / max(m_end, 1.0)))


def random_sched(n=8):
    return [[random.random() ** 2 for _ in TYPES] for _ in range(n)]


def mutate(sc, sigma):
    return [[max(0.0, x + random.gauss(0, sigma) * (0.3 + x)) if random.random() < 0.4 else x for x in row] for row in sc]


def optimise(eta, cap, smax, target, evals, horizon, seed=1):
    random.seed(seed)
    best, best_s = None, 1e18
    pop = []
    for _ in range(40):
        sc = random_sched()
        hit, _, m = simulate(sc, eta, cap, smax, horizon)
        pop.append((score(hit, m, target, horizon), sc))
    pop.sort(key=lambda p: p[0])
    n = 40
    while n < evals:
        parents = pop[:8]
        sigma = 0.35 * (1 - n / evals) + 0.05
        for _ in range(32):
            p = random.choice(parents)[1]
            c = mutate(p, sigma)
            hit, _, m = simulate(c, eta, cap, smax, horizon)
            pop.append((score(hit, m, target, horizon), c))
            n += 1
        pop.sort(key=lambda p: p[0])
        pop = pop[:40]
    return pop[0]


def bench_like():
    """T1 grids with winds and nanos, retrofits late: roughly what the bench does (not optimised)."""
    #        mex1 moho wind fus afus nano1 nano2 con
    early = [0.35, 0.0, 0.30, 0.0, 0.0, 0.25, 0.0, 0.10]
    mid = [0.30, 0.10, 0.30, 0.0, 0.0, 0.20, 0.0, 0.10]
    late = [0.10, 0.45, 0.10, 0.15, 0.0, 0.10, 0.0, 0.10]
    return [early, early, mid, mid, mid, late, late, late]


def show(sc, eta, cap, smax, horizon, label):
    hit, path, m = simulate(sc, eta, cap, smax, horizon, record=True)
    print("\n%s  (eta %.2f, cap %d, spots %d)" % (label, eta, cap, smax))
    print("  minutes to income: " + "  ".join("%d m/s: %s" % (x, "%.1f" % (4 + hit[x] / 60) if x in hit else "-") for x in (400, 800, 1600, 3200, 6400, 12800)))
    print("  clock   m/s     e/s     bp(eff)  bank M / E       units  mex1  moho  wind  fus afus nano1 nano2 con")
    for t, mi, ei, B, M, E, units, s in path:
        if int(t) % 180 == 0:
            print("  %5.1f %7.0f %8.0f %9.0f %7.0f %7.0f  %6.0f %5.0f %5.0f %5.0f %4.0f %4.0f %5.0f %5.0f %4.0f" % (
                4 + t / 60, mi, ei, B, M, E, units, s["mex1"], s["moho"], s["wind"], s["fus"], s["afus"], s["nano1"], s["nano2"], s["con"]))
    return hit, m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eta", type=float, default=0.5)
    ap.add_argument("--cap", type=int, default=3000)
    ap.add_argument("--spots", type=int, default=1800)
    ap.add_argument("--target", type=float, default=6400)
    ap.add_argument("--evals", type=int, default=3000)
    ap.add_argument("--horizon", type=float, default=2700)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    if a.check:
        show(bench_like(), a.eta, a.cap, a.spots, a.horizon, "bench-like fixed schedule")
        return
    sc_s, sc = optimise(a.eta, a.cap, a.spots, a.target, a.evals, a.horizon, a.seed)
    show(sc, a.eta, a.cap, a.spots, a.horizon, "optimised for %d m/s" % a.target)
    print("\n  schedule (rows = 8 anchors over %d s; columns %s):" % (a.horizon, " ".join(TYPES)))
    for row in sc:
        tot = sum(row) or 1
        print("   " + " ".join("%5.2f" % (x / tot) for x in row))


if __name__ == "__main__":
    main()
