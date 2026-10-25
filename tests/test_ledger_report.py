"""tests/test_ledger_report.py -- ledger_report.py on hand-written [LED] rows (the format ledger_logger.lua writes)."""
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import ledger_report as LR  # noqa: E402

CAT0 = " ".join("lost_%s=0 killed_%s=0" % (c, c) for c in LR.CATS)

LINES = [
    "[t=00:01:00][f=0000900] [LED] spend f=900 t=0:30 m_inc=1000 m_pull=1000 m_bank=0.10 e_inc=2000 e_pull=1900 e_fill=0.5 cap=100/3000 labs_busy=2 labs_idle=0 cons_idle=0 nano_idle=0 bp_use=0.95 to_army_ground=600 to_army_air=0 to_bp=100 to_eco=300 to_defence=0 to_commander=0 to_other=0 explained=1000 unexplained=0 why=spending",
    "[LED] spend f=1800 t=1:00 m_inc=2000 m_pull=500 m_bank=0.90 e_inc=2000 e_pull=500 e_fill=0.9 cap=100/3000 labs_busy=0 labs_idle=3 cons_idle=1 nano_idle=2 bp_use=0.20 to_army_ground=300 to_army_air=0 to_bp=0 to_eco=100 to_defence=0 to_commander=0 to_other=0 explained=400 unexplained=100 why=idle_labs",
    "[LED] spend f=2700 t=1:30 m_inc=2000 m_pull=500 m_bank=0.95 e_inc=2000 e_pull=500 e_fill=0.9 cap=3000/3000 labs_busy=0 labs_idle=0 cons_idle=0 nano_idle=0 bp_use=0.20 to_army_ground=300 to_army_air=0 to_bp=0 to_eco=100 to_defence=0 to_commander=0 to_other=0 explained=400 unexplained=100 why=unit_cap",
    "[LED] fight f=3000 t=1:40 dur=20 x=3000 z=3000 n_lost=40 n_killed=10 lost=20000 killed=8000 ratio=0.40 lost_army=20000 killed_army=3000 lost_eco=0 killed_eco=2000 lost_bp=0 killed_bp=3000 lost_defence=0 killed_defence=0 lost_commander=0 killed_commander=0 lost_other=0 killed_other=0 top_lost=corgator:30 top_killed=armnanotc:3,armmex:4",
    "[LED] fight f=4000 t=2:13 dur=5 x=100 z=200 n_lost=2 n_killed=20 lost=1000 killed=9000 ratio=9.00 lost_army=1000 killed_army=9000 lost_eco=0 killed_eco=0 lost_bp=0 killed_bp=0 lost_defence=0 killed_defence=0 lost_commander=0 killed_commander=0 lost_other=0 killed_other=0 top_lost=corgator:2 top_killed=armflea:20",
    "[LED] scout f=3000 t=1:40 lead_s=12 seen_d=4000 seen_by=radar unit=armflea n=3 surprise=0",
    "[LED] scout f=6000 t=3:20 lead_s=0 seen_d=1500 seen_by=los unit=corgator n=5 surprise=1",
    "<T1> [LED] scout f=1 t=0:00 lead_s=99 seen_d=1 seen_by=los unit=x n=1 surprise=0",
    "some other line",
]


class LedgerReport(unittest.TestCase):
    def test_parse(self):
        d = LR.parse_lines(LINES)
        self.assertEqual(len(d["spend"]), 3)
        self.assertEqual(len(d["fight"]), 2)
        self.assertEqual(len(d["scout"]), 3)
        self.assertEqual(d["spend"][0]["m_inc"], 1000)
        self.assertEqual(d["spend"][1]["why"], "idle_labs")
        self.assertEqual(d["spend"][0]["t"], 30)
        self.assertEqual(d["fight"][0]["top_killed"], "armnanotc:3,armmex:4")

    def test_team_filter(self):
        d = LR.parse_lines(LINES, team=1)
        self.assertEqual(len(d["scout"]), 1)
        self.assertEqual(d["spend"], [])

    def test_spend_summary(self):
        s = LR.summarize_spend(LR.parse_lines(LINES)["spend"])
        self.assertEqual(s["rows"], 3)
        # unspent = (2000-500) x 30 s on the idle_labs row and again on the unit_cap row
        self.assertAlmostEqual(s["unspent_by_reason"]["idle_labs"], 1500 * 30)
        self.assertAlmostEqual(s["unspent_by_reason"]["unit_cap"], 1500 * 30)
        self.assertNotIn("spending", s["unspent_by_reason"])
        self.assertAlmostEqual(s["unspent"], 3000 * 30)
        self.assertEqual(s["idle_lab_rows"], 1)
        self.assertEqual(s["peak_bank"], 0.95)

    def test_fight_summary(self):
        d = LR.parse_lines(LINES)
        f = LR.summarize_fight(d["fight"])
        self.assertEqual(f["fights"], 2)
        self.assertEqual(f["lost"]["army"], 21000)
        self.assertEqual(f["killed"]["army"], 12000)
        self.assertEqual(f["future_killed"], 5000)           # their eco 2000 + bp 3000
        self.assertAlmostEqual(f["ratio"], 17000 / 21000)
        self.assertEqual(f["biggest"][0]["lost"], 20000)
        self.assertEqual(dict(f["most_killed"])["armflea"], 20)

    def test_scout_summary(self):
        s = LR.summarize_scout(LR.parse_lines(LINES)["scout"][:2])
        self.assertEqual(s["waves"], 2)
        self.assertEqual(s["surprises"], 1)
        self.assertEqual(s["median_lead_s"], 6)
        self.assertEqual(s["first_wave_lead_s"], 12)

    def test_gaps_and_text(self):
        d = LR.parse_lines(LINES)
        s = LR.summarize(d)
        self.assertTrue(s["gaps"])
        self.assertIn("unspent income", s["gaps"][0])          # 90k unspent is the biggest
        txt = LR.text_report("x", d, s)
        for word in ("SPEND", "FIGHT", "SCOUT", "GAPS", "unit_cap", "idle_labs"):
            self.assertIn(word, txt)

    def test_empty(self):
        s = LR.summarize(LR.parse_lines(["nothing here"]))
        self.assertIsNone(s["spend"])
        self.assertEqual(s["gaps"], [])
        self.assertIn("no rows", LR.text_report("e", LR.parse_lines([]), s))

    def test_value_rows_fallback(self):
        v = "[LED] value f=1800 t=1:00 " + CAT0.replace("lost_army=0", "lost_army=500")
        d = LR.parse_lines([v])
        f = LR.summarize_fight([], d["value"])
        self.assertEqual(f["lost"]["army"], 500)


if __name__ == "__main__":
    unittest.main()
