"""Exercise the real SDK adapter with a fake module and synthetic auth canary."""
import json
import os
import signal
import time
from pathlib import Path
import sys
import unittest

from helpers import REPO, fresh_evidence, invoke, archive_evidence

API = REPO / "Tools/agents/api_run.py"
MOCK_SDK = Path(__file__).parent / "fixtures/mock_sdk"
MOCK_BINS = Path(__file__).parent / "fixtures/mock_bins"


class SDKAdapter(unittest.TestCase):
    def setUp(self):
        self.evidence = fresh_evidence(self._testMethodName)
        self.cwd = self.evidence / "workspace"
        self.cwd.mkdir()
        self.task = self.evidence / "task.md"
        self.task.write_text("Offline SDK fixture only. No transport.\n")
        self.config = self.evidence / "config.json"
        self.config.write_text(json.dumps({"capacity_usd": 10, "source": "offline synthetic fixture"}))
        self.records = self.evidence / "records"

    def tearDown(self):
        archive_evidence(self.evidence)

    def execute(self, scenario, *extra, wrapper=False):
        case = self.evidence / scenario
        case.mkdir()
        command = ([str(REPO / "Tools/agents/api_run.sh")] if wrapper else [sys.executable, str(API)])
        command += ["sdk-test", str(self.task), "--model", "fixture-model", "--budget", "2",
                    "--budget-config", str(self.config), "--ledger", str(case / "budget.json"),
                    "--records-root", str(self.records), "--cwd", str(self.cwd), "--watch", ".",
                    "--max-turns", "4", "--timeout", "3", *extra]
        # This public string is not a credential. It ensures the adapter never
        # reaches its keychain fallback; the mock SDK cannot use any transport.
        env = {"PYTHONPATH": str(MOCK_SDK.resolve()), "SDK_SCENARIO": scenario,
               "ANTHROPIC_API_KEY": "PUBLIC_SYNTHETIC_OFFLINE_CANARY_NOT_A_KEY",
               "SDK_KEYCHAIN_MARKER": str(case / "unexpected-keychain.txt"),
               "SDK_DESCENDANT_PID_FILE": str(case / "descendant.pid"),
               "PATH": str(MOCK_BINS.resolve()) + os.pathsep + os.environ.get("PATH", os.defpath)}
        proc = invoke(command, env=env, evidence=case, timeout=12)
        runs = sorted(self.records.glob("*/result.json"))
        self.assertTrue(runs, proc.stdout + proc.stderr)
        run = runs[-1].parent
        result = json.loads((run / "result.json").read_text())
        self.assertFalse((case / "unexpected-keychain.txt").exists())
        return proc, run, result

    def test_sdk_success_preserves_user_tool_result_without_reasoning(self):
        proc, run, result = self.execute("success")
        self.assertEqual(proc.returncode, 0, result)
        self.assertEqual(result["provider_status"], "succeeded")
        self.assertEqual(result["verification_status"], "not_run")
        self.assertEqual(result["cost_usd"], 0.25)
        self.assertIsNone(result["actual_billed_cost_usd"])
        self.assertEqual((run / "output.md").read_text(), "OFFLINE_SDK_EXPECTED_OUTPUT")
        events = [json.loads(line) for line in (run / "transcript.jsonl").read_text().splitlines()]
        tool = next(e for e in events if e["message_class"] == "UserMessage")
        self.assertEqual(tool["content"][0]["content"], "SDK_NORMAL_BEGIN_" + "0123456789abcdef" * 12000 + "_SDK_NORMAL_END")
        self.assertNotIn("synthetic-private-reasoning-canary", (run / "transcript.jsonl").read_text())

    def test_sdk_provider_exception_blank_and_missing_final_fail(self):
        for scenario, expected in [("provider", "failed"), ("exception", "failed"),
                                   ("blank-output", "failed"), ("no-final", "unknown")]:
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario)
                self.assertNotEqual(proc.returncode, 0, result)
                self.assertEqual(result["provider_status"], expected)
                if scenario in {"exception", "no-final"}:
                    self.assertIsNone(result["cost_usd"])
                self.assertNotIn("synthetic-sdk-secret", (run / "events.jsonl").read_text())

    def test_sdk_turn_budget_and_timeout_are_interrupted(self):
        for scenario in ["turns", "budget", "timeout"]:
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario, "--timeout", "0.2")
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(result["provider_status"], "interrupted", result)

    def test_unknown_cost_holds_sdk_reservation(self):
        proc, run, result = self.execute("unknown-cost")
        self.assertEqual(proc.returncode, 0)
        self.assertIsNone(result["cost_usd"])
        ledger = json.loads(Path(result["budget_ledger"]).read_text())
        row = next(iter(ledger["runs"].values()))
        self.assertEqual(row["status"], "unknown_cost_hold")
        self.assertEqual(row["reserved_usd"], 2)

    def test_sdk_stderr_is_durable_redacted_and_not_failure(self):
        proc, run, result = self.execute("stderr")
        self.assertEqual(proc.returncode, 0, result)
        stderr = (run / "stderr.log").read_text()
        self.assertIn("KEEP_DIAGNOSTIC", stderr)
        self.assertNotIn("synthetic-sdk-stderr-credential", stderr)
        self.assertNotIn("synthetic-sdk-stderr-credential", (run / "events.jsonl").read_text())

    def test_sdk_timeout_terminates_descendant_process(self):
        child = None
        try:
            proc, run, result = self.execute("timeout-spawn", "--timeout", "0.8")
            self.assertEqual(result["provider_status"], "interrupted", result)
            self.assertNotEqual(proc.returncode, 0)
            pid_file = self.evidence / "timeout-spawn/descendant.pid"
            self.assertTrue(pid_file.exists(), "SDK never reached the descendant-spawn fixture")
            child = int(pid_file.read_text())
            absent = False
            for _ in range(20):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    absent = True
                    break
                time.sleep(0.02)
            (self.evidence / "descendant-final-state.txt").write_text(
                json.dumps({"pid": child, "absent_by_signal_zero": absent}))
            self.assertTrue(absent, "SDK timeout left a live or unreaped descendant PID " + str(child))
        finally:
            if child:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_api_shell_help_does_not_read_keychain(self):
        marker = self.evidence / "unexpected-keychain.txt"
        proc = invoke([REPO / "Tools/agents/api_run.sh", "--help"], evidence=self.evidence,
                      env={"SDK_KEYCHAIN_MARKER": str(marker),
                           "PATH": str(MOCK_BINS.resolve()) + os.pathsep + os.environ.get("PATH", os.defpath)})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--budget-config", proc.stdout)
        self.assertFalse(marker.exists())

    def test_api_shell_propagates_mock_sdk_failure(self):
        proc, run, result = self.execute("provider", wrapper=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(result["provider_status"], "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
