"""Reproduce archived pre-fix defects without importing the live SDK runner.

These are evidence tests: they assert that the archived implementation exhibits
the defect, not that the current implementation should retain it.
"""
import ast
import datetime
import json
import subprocess
import tempfile
import types
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ARCHIVE = REPO / "Tools/agents/records/2026-10-28-remediation/runner-tests/inputs"


class LegacyEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ARCHIVE / "Tools/agents/api_run.py").read_text()
        cls.tree = ast.parse(cls.source)

    def test_provider_and_turn_errors_were_finished(self):
        main = next(n for n in self.tree.body if isinstance(n, ast.AsyncFunctionDef))
        call = next(n for n in ast.walk(main) if isinstance(n, ast.Call)
                    and isinstance(n.func, ast.Name) and n.func.id == "status"
                    and isinstance(n.args[0], ast.IfExp))
        expression = compile(ast.Expression(call.args[0]), "archived-status", "eval")
        observed = {}
        for reason in ["maximum turns reached", "provider error"]:
            final = types.SimpleNamespace(is_error=True, result=reason)
            observed[reason] = eval(expression, {}, {"err": None, "final": final})
        self.assertEqual(set(observed.values()), {"finished"}, observed)
        print("OLD_STATUS_DEFECT", json.dumps(observed))

    def test_parallel_ledger_updates_lose_completed_cost(self):
        spent_at_start = 5.42
        cost_a, cost_b = 14.2185, 19.9711
        actual_last_cumulative = spent_at_start + cost_b
        correct_cumulative = spent_at_start + cost_a + cost_b
        self.assertAlmostEqual(correct_cumulative - actual_last_cumulative, cost_a)
        self.assertIn("tot = spent + cost", self.source)
        print("OLD_LEDGER_DEFECT", json.dumps({"last": actual_last_cumulative,
              "recomputed": correct_cumulative, "lost": cost_a}))

    def test_missing_final_was_zero_cost(self):
        main = next(n for n in self.tree.body if isinstance(n, ast.AsyncFunctionDef))
        assignment = next(n for n in ast.walk(main) if isinstance(n, ast.Assign)
                          and any(isinstance(t, ast.Name) and t.id == "cost" for t in n.targets))
        value = eval(compile(ast.Expression(assignment.value), "archived-cost", "eval"), {}, {"final": None})
        self.assertEqual(value, 0.0)
        print("OLD_UNKNOWN_COST_DEFECT", value)

    def test_minute_names_collide_and_wrappers_swallow_errors(self):
        for name in ["Tests/run_deepseek.sh", "Tests/run_deepseek_dev.sh"]:
            source = (ARCHIVE / name).read_text()
            self.assertIn("|| true", source)
            self.assertIn("%Y%m%d_%H%M", source)
        stamp = datetime.datetime(2026, 10, 28, 12, 0, 17)
        first = stamp.strftime("%Y%m%d_%H%M") + "_same"
        second = (stamp + datetime.timedelta(seconds=12)).strftime("%Y%m%d_%H%M") + "_same"
        self.assertEqual(first, second)
        print("OLD_NAME_COLLISION", first)

    def test_default_git_diff_misses_untracked_and_staged(self):
        with tempfile.TemporaryDirectory(prefix="gpxpv-old-diff-") as d:
            root = Path(d)
            def git(*args):
                return subprocess.run(["git", "-C", d, *args], check=True,
                                      capture_output=True, text=True).stdout
            git("init", "-q")
            (root / "tracked.txt").write_text("baseline\n")
            git("add", "tracked.txt")
            git("-c", "user.email=offline@example.invalid", "-c", "user.name=Offline",
                "commit", "-qm", "fixture")
            (root / "tracked.txt").write_text("staged change\n")
            git("add", "tracked.txt")
            (root / "untracked.txt").write_text("untracked change\n")
            self.assertEqual(git("diff"), "")
            self.assertIn("untracked.txt", git("status", "--porcelain"))
            self.assertIn("staged change", git("diff", "--cached"))
            print("OLD_DIFF_DEFECT", "default diff empty despite staged and untracked changes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
