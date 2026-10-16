"""No new unit-name literals in bar_framework/ (tests/check_role_names.py)."""
import os, subprocess, sys, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class RoleNameTests(unittest.TestCase):
    def test_no_new_literals(self):
        r = subprocess.run([sys.executable, os.path.join("tests", "check_role_names.py")], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
