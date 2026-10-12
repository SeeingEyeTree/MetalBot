"""Stance files: seed stances are valid, and the editor's Lua export (run in node) loads in lupa."""
import glob, json, os, re, shutil, subprocess, sys, unittest
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class StanceTests(unittest.TestCase):
    def units(self):
        p = os.path.join(ROOT, "stance_editor", "units.json")
        if not os.path.exists(p):
            self.skipTest("run extract_unit_data.py first")
        return {u["name"] for u in json.load(open(p))}

    def test_seed_stances(self):
        names = self.units()
        for f in glob.glob(os.path.join(ROOT, "stances", "*.json")):
            j = json.load(open(f))
            self.assertAlmostEqual(sum(u["share"] for u in j["units"]), 1.0, delta=0.01, msg=f)
            for u in j["units"]:
                self.assertIn(u["n"], names, f)

    def export(self, extra_js=""):
        node = shutil.which("node")
        if not node:
            self.skipTest("node not installed")
        html = open(os.path.join(ROOT, "stance_editor.html"), encoding="utf8").read()
        js = re.search(r"<script>(.*)</script>", html, re.S).group(1)
        js = js.replace("init();\n", "")  # no DOM here: define functions only
        seed = os.path.join(ROOT, "stances", "light_raid.json").replace("\\", "/")
        units = os.path.join(ROOT, "stance_editor", "units.json").replace("\\", "/")
        harness = """
const fs=require('fs');
const stub=()=>({addEventListener(){},classList:{add(){},remove(){}},append(){},style:{},value:'',set innerHTML(v){},get innerHTML(){return ''}});
global.document={getElementById:stub,addEventListener(){},createElement:stub,body:stub()};
global.localStorage={getItem(){return null},setItem(){}};
%s
UNITS=JSON.parse(fs.readFileSync('%s','utf8'));BY={};UNITS.forEach(u=>BY[u.name]=u);
const j=JSON.parse(fs.readFileSync('%s','utf8'));
st={name:j.name,intent:j.notes.intent,control:j.notes.control,share:j.notes.share,units:j.units.map(u=>({n:u.n,pct:u.share*100,locked:false,note:u.note,beh:u.beh||'',ov:u.ov||''}))};
%s
process.stdout.write(toLua());
""" % (js, units, seed, extra_js)
        out = subprocess.run([node, "-e", harness], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        return LuaRuntime().execute(out.stdout)

    def test_lua_export(self):
        M = self.export()
        self.assertEqual(M.name, "light_raid")
        us = list(M.units.values())
        self.assertEqual(len(us), 6)
        self.assertAlmostEqual(sum(u.ratio for u in us), 1.0, delta=0.01)
        self.assertAlmostEqual(sum(u.share for u in us), 1.0, delta=0.01)
        self.assertIsNone(us[0].behaviors)

    def test_behaviors_export(self):
        M = self.export("st.units[0].beh='kite, advance';st.units[0].ov='kite.step=400, kite.mobile_only=false, stun.tag=x';")
        u = list(M.units.values())[0]
        self.assertEqual(list(u.behaviors.values()), ["kite", "advance"])
        self.assertEqual(u.cfg.kite.step, 400)
        self.assertFalse(u.cfg.kite.mobile_only)
        self.assertEqual(u.cfg.stun.tag, "x")


if __name__ == "__main__":
    unittest.main()
