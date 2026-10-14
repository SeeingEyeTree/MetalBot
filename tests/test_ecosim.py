"""Physics checks for the economy simulator's engine (ecosim/world.lua): build time, reach, stalls, extraction, the moho
upgrade, factory queues, reclaim, order lag.  Runs world.lua directly (no bot).  python tests/test_ecosim.py"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import lupa.luajit21 as L  # noqa: E402

lua = L.LuaRuntime(unpack_returned_tuples=True)
root = ROOT.replace("\\", "/") + "/"
lua.execute(f'''
P = dofile("{root}ecosim/physics.lua")
P.ORDER_LAG, P.ORDER_JITTER, P.START_MOVE_FRAMES, P.ARRIVE_FRAMES = 1, 0, 0, 0
D = dofile("{root}ecosim/unitdefs.lua")
function Fresh()
    W = dofile("{root}ecosim/world.lua")
    local byId, byName = {{}}, {{}}
    for _, d in pairs(D.units) do byId[d.id] = d; byName[d.name] = d end
    W.Init(P, byId); W.defsByName = byName; W.myTeam = 0
    W.callin = function() end
    W.teams[0].metal, W.teams[0].energy = 1e6, 1e6
    W.teams[0].unitStorM, W.teams[0].unitStorE = 1e7, 1e7
    W.teams[0].mStor, W.teams[0].eStor = 1e7, 1e7
    return W
end
function Run(frames) for f = 1, frames do W.frame = W.frame + 1; W.ApplyOrders(W.frame); if W.frame % P.STEP == 0 then W.Step(P.STEP) end end end
function Def(n) return W.defsByName[n].id end
function FindDef(n) for id, u in pairs(W.units) do if u.d.name == n then return u end end end
function Count(n) local c = 0; for _, u in pairs(W.units) do if u.d.name == n and u.built then c = c + 1 end end; return c end
''')
G = lua.globals()
fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
    if not ok:
        fails.append(name)


# 1. a nano (200 BP) builds a wind (buildTime 1680) in 8.4 s
G.Fresh()
nano = G.W.Spawn("cornanotc", 0, 1000, 1000)
G.W.GiveOrder(nano.id, -G.Def("corwin"), lua.table(1100, 0, 1000, 0), lua.table())
G.Run(30 * 8)
check("nano builds a wind: not done at 8.0 s", G.Count("corwin") == 0)
G.Run(30 * 1)
check("nano builds a wind: done by 9.0 s", G.Count("corwin") == 1)

# 2. a static builder drops an order out of reach (buildDistance 400 + radius)
G.Fresh()
nano = G.W.Spawn("cornanotc", 0, 1000, 1000)
G.W.GiveOrder(nano.id, -G.Def("corwin"), lua.table(1600, 0, 1000, 0), lua.table())
G.Run(60)
check("static builder drops an out-of-reach build", len(list(nano.cmds.keys())) == 0 and G.Count("corwin") == 0)

# 3. stall: no metal, no income -> a low-priority builder does not progress
G.Fresh()
G.W.teams[0].metal = 0
nano = G.W.Spawn("cornanotc", 0, 1000, 1000)
G.W.GiveOrder(nano.id, -G.Def("cormex"), lua.table(1100, 0, 1000, 0), lua.table())
G.Run(300)
f = G.FindDef("cormex")
check("stalled builder makes no progress", f is not None and f.progress == 0, f and f.progress)

# 4. extraction: an isolated cormex yields 2.37, a moho placed on it replaces it (refund) and yields 9.48
G.Fresh()
nano = G.W.Spawn("cornanotc", 0, 1000, 1000)
G.W.GiveOrder(nano.id, -G.Def("cormex"), lua.table(1104, 0, 1000, 0), lua.table())
G.Run(30 * 12)
check("cormex yields 2.37 m/s", abs(G.W.teams[0].mexInc - 2.37) < 0.01, G.W.teams[0].mexInc)
mex = G.FindDef("cormex")
tb = G.W.TestBuild(G.Def("cormoho"), mex.x, mex.z, 0)
check("moho may be placed on a finished mex (Mex Upgrade Reclaimer)", (tb[0] if isinstance(tb, tuple) else tb) != 0)
m0 = G.W.teams[0].metal
G.W.GiveOrder(nano.id, -G.Def("cormoho"), lua.table(mex.x, 0, mex.z, 0), lua.table())
G.Run(30 * 30)
check("mex keeps extracting while the moho is built", abs(G.W.teams[0].mexInc - 2.37) < 0.01, G.W.teams[0].mexInc)
G.Run(30 * 50)
check("moho done, mex gone", G.Count("cormoho") == 1 and G.Count("cormex") == 0)
check("moho yields 9.48 m/s", abs(G.W.teams[0].mexInc - 9.48) < 0.01, G.W.teams[0].mexInc)
tb = G.W.TestBuild(G.Def("corwin"), mex.x, mex.z, 0)
check("a wind may NOT be placed on the moho", (tb[0] if isinstance(tb, tuple) else tb) == 0)

# 5. factory queue: an air lab (150 BP) builds an air con (buildTime 5200) in ~34.7 s
G.Fresh()
lab = G.W.Spawn("corap", 0, 2000, 2000)
G.W.GiveOrder(lab.id, -G.Def("corca"), lua.table(), lua.table())
G.Run(30 * 34)
check("factory: con not out at 34 s", G.Count("corca") == 0)
G.Run(30 * 2)
check("factory: con out by 36 s", G.Count("corca") == 1)

# 6. reclaim: a nano reclaims a wind and gets its metal back
G.Fresh()
nano = G.W.Spawn("cornanotc", 0, 1000, 1000)
wind = G.W.Spawn("corwin", 0, 1100, 1000)
m0 = G.W.teams[0].metal
G.W.GiveOrder(nano.id, 90, lua.table(wind.id), lua.table())
G.Run(30 * 10)
check("reclaim removes the wind and refunds its metal", G.Count("corwin") == 0 and G.W.teams[0].metal - m0 >= 42,
      G.W.teams[0].metal - m0)

# 7. order lag keeps a unit's orders in sequence (STOP then build, same frame)
G.Fresh()
G.P.ORDER_LAG, G.P.ORDER_JITTER = 20, 10
com = G.W.Spawn("corcom", 0, 1000, 1000)
for i in range(20):
    G.W.GiveOrder(com.id, 0, lua.table(), lua.table())
    G.W.GiveOrder(com.id, -G.Def("corwin"), lua.table(1080, 0, 1000 + 64 * (i % 3), 0), lua.table())
    G.Run(5)
G.Run(60)
check("orders to one unit apply in the order given", len(list(com.cmds.keys())) > 0 or G.Count("corwin") > 0)

print(f"\n{'FAILED ' + str(len(fails)) if fails else 'all passed'}")
sys.exit(1 if fails else 0)
