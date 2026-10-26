"""tests/test_unit_report.py -- unit_report.py on hand-written [STATS] rows (single-mode tags, killer types, self-destructs)."""
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import unit_report as UR  # noqa: E402

LINES = [
    # team 0 builds 2 Sheldons, team 1 builds 3 Gators -- logged by both teams' widgets in single mode
    "<T0> [STATS] built frame=100 team=0 def=cormort mv=400 nc[0]=1 nc[1]=0",
    "<T1> [STATS] built frame=100 team=0 def=cormort mv=400 nc[0]=1 nc[1]=0",
    "<T0> [STATS] built frame=110 team=0 def=cormort mv=400 nc[0]=2 nc[1]=0",
    "<T1> [STATS] built frame=110 team=0 def=cormort mv=400 nc[0]=2 nc[1]=0",
    "<T1> [STATS] built frame=120 team=1 def=corgator mv=120 nc[0]=2 nc[1]=1",
    "<T1> [STATS] built frame=121 team=1 def=corgator mv=120 nc[0]=2 nc[1]=2",
    "<T1> [STATS] built frame=122 team=1 def=corgator mv=120 nc[0]=2 nc[1]=3",
    # a Sheldon kills two Gators; a Gator kills a Sheldon (each row twice: both logs)
    "<T1> [STATS] destroyed frame=500 team=1 def=corgator mv=120 attacker_team=0 attacker_def=cormort",
    "<T0> [STATS] destroyed frame=500 team=1 def=corgator mv=120 attacker_team=0 attacker_def=cormort",
    "<T1> [STATS] destroyed frame=510 team=1 def=corgator mv=120 attacker_team=0 attacker_def=cormort",
    "<T0> [STATS] destroyed frame=510 team=1 def=corgator mv=120 attacker_team=0 attacker_def=cormort",
    "<T0> [STATS] destroyed frame=520 team=0 def=cormort mv=400 attacker_team=1 attacker_def=corgator",
    "<T1> [STATS] destroyed frame=520 team=0 def=cormort mv=400 attacker_team=1 attacker_def=corgator",
    # the end-of-match self-destruct and a row after --until do not count
    "<T1> [STATS] destroyed frame=45100 team=1 def=corgator mv=120 attacker_team=-1 attacker_def=-",
    "<T0> [STATS] destroyed frame=600 team=0 def=cormort mv=400 attacker_team=-1 attacker_def=-",
    # an old-format row (no killer type) still counts as a loss
    "<T1> [STATS] destroyed frame=700 team=1 def=corgator mv=120 attacker_team=0",
    "noise",
]


class UnitReport(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".txt")
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(LINES) + "\n")

    def tearDown(self):
        os.remove(self.path)

    def test_counts(self):
        s = UR.parse(self.path, 45000)
        sh, ga = s[0]["cormort"], s[1]["corgator"]
        self.assertEqual(sh["built"], 2)          # once per event, not once per log
        self.assertEqual(sh["lost"], 1)           # the self-destruct is not a loss
        self.assertEqual(sh["kills"], 2)
        self.assertEqual(sh["killV"], 240)
        self.assertEqual(ga["built"], 3)
        self.assertEqual(ga["lost"], 3)           # two by Sheldons + the old-format row; not the one after --until
        self.assertEqual(ga["kills"], 1)
        self.assertEqual(ga["killV"], 400)

    def test_report_prints(self):
        import io
        buf = io.StringIO()
        UR.report(UR.parse(self.path, 45000), [0, 1], 1, out=buf)
        out = buf.getvalue()
        self.assertIn("cormort", out)
        self.assertIn("0.30", out)                # 240 killed / 800 built


if __name__ == "__main__":
    unittest.main()
