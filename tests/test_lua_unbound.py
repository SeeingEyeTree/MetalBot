"""Split Lua modules bind every name they use from their parent (tests/check_lua_unbound.py)."""
import os, subprocess, sys, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class UnboundTests(unittest.TestCase):
    def test_line_transition_modules(self):
        r = subprocess.run([sys.executable, os.path.join("tests", "check_lua_unbound.py"), os.path.join("bar_framework", "line_transition"),
                            "--names", "StartSpine,CMD_REPAIR"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
