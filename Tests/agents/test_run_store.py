"""Offline black-box invariants for the durable run store and budget ledger."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Tools/agents"))
from run_store import BudgetLedger, RunStore, classify_result, reconcile_legacy, redact
from agent_run import status_payload
from helpers import RECORD, fresh_evidence, init_repo, sha256, archive_evidence


def reserve_worker(args):
    path, config, run_id, amount = args
    try:
        BudgetLedger(path, config).reserve(run_id, amount)
        return {"run": run_id, "reserved": amount}
    except ValueError as exc:
        return {"run": run_id, "error": str(exc)}


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.evidence = fresh_evidence(self._testMethodName)
        self.cwd = self.evidence / "workspace"
        self.cwd.mkdir()
        self.task = self.evidence / "task.md"
        self.task.write_text("Offline invariant test. No network or API.\n")

    def tearDown(self):
        archive_evidence(self.evidence)

    def create(self, **kwargs):
        return RunStore.create(self.evidence / "records", "quoted\"name\\with\nnewline",
                               self.task, cwd=self.cwd, watch=kwargs.pop("watch", ["."]),
                               provider="codex-native", model="gpt-6.1-sol", effort="ultra",
                               **kwargs)

    def test_same_name_parallel_creates_are_unique(self):
        def create(_):
            return str(self.create().path)
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            paths = list(pool.map(create, range(24)))
        self.assertEqual(len(set(paths)), 24)
        for path in paths:
            self.assertTrue((Path(path) / "task.md").read_text().strip())
            self.assertTrue((Path(path) / "events.jsonl").read_text().strip())
        (self.evidence / "paths.json").write_text(json.dumps(paths, indent=2))

    def test_native_registration_and_acceptance_are_separate(self):
        run = self.create()
        run.bind(agent_id="native-test-id", session_id="native-session")
        self.assertEqual(run.effective_status()["status"], "running")
        result = run.finish({"provider_status": "succeeded", "acceptance_status": "pending"}, output="review me")
        self.assertEqual(result["provider_status"], "succeeded")
        self.assertEqual(result["verification_status"], "not_run")
        self.assertIsNone(result["cost_usd"])
        self.assertEqual(result["session_id"], "native-session")
        with self.assertRaises(FileExistsError):
            run.finish({"provider_status": "succeeded", "acceptance_status": "passed"})

    def test_independent_verification_preserves_execution_result(self):
        run = self.create()
        run.finish({"provider_status": "succeeded", "acceptance_status": "pending"}, output="mock provider report")
        original = (run.path / "result.json").read_bytes()
        evidence = self.evidence / "verification-output.txt"
        evidence.write_text("Assertions passed: synthetic independent check\n")
        receipt = run.verify("passed", evidence, "independent mock assertion")
        self.assertEqual(receipt["verification_status"], "passed")
        self.assertEqual((run.path / "result.json").read_bytes(), original)
        self.assertEqual(run.effective_status()["verification_status"], "passed")
        run.verify("failed", evidence, "follow-up check failed")
        self.assertEqual((run.path / "result.json").read_bytes(), original)
        self.assertEqual(run.effective_status()["status"], "failed")

    def test_failed_execution_cannot_receive_passed_verification(self):
        run = self.create()
        run.finish({"provider_status": "failed"}, output="failed provider report")
        evidence = self.evidence / "verification-output.txt"
        evidence.write_text("synthetic output\n")
        with self.assertRaises(ValueError):
            run.verify("passed", evidence)

    def test_finalize_preexisting_identical_native_output(self):
        run = self.create()
        report = "Native agent already wrote this complete report.\n"
        output = run.path / "output.md"
        output.write_text(report)
        original = output.read_bytes()
        result = run.finish({"provider_status": "succeeded", "acceptance_status": "pending"}, output=report)
        self.assertEqual(result["provider_status"], "succeeded")
        self.assertEqual(output.read_bytes(), original)
        final = (run.path / "result.json").read_bytes()
        with self.assertRaises(FileExistsError):
            run.finish({"provider_status": "succeeded"}, output=report)
        self.assertEqual((run.path / "result.json").read_bytes(), final)

    def test_conflicting_preexisting_output_is_preserved(self):
        run = self.create()
        output = run.path / "output.md"
        output.write_text("Existing native report that must be retained.\n")
        original = output.read_bytes()
        with self.assertRaises((FileExistsError, ValueError)):
            run.finish({"provider_status": "succeeded"}, output="Different proposed report.\n")
        self.assertEqual(output.read_bytes(), original)
        self.assertFalse((run.path / "result.json").exists())

    def test_dead_process_and_reused_identity_are_unknown(self):
        run = self.create()
        run.bind(pid=99999999)
        self.assertEqual(run.effective_status()["status"], "unknown")
        run = self.create()
        run.bind(pid=os.getpid())
        self.assertEqual(run.effective_status()["status"], "running", "live owner PID/start identity was not recognized")
        meta = json.loads((run.path / "meta.json").read_text())
        meta["process_identity"] = "different process start identity"
        (run.path / "meta.json").write_text(json.dumps(meta))
        self.assertEqual(run.effective_status()["status"], "unknown")

    def test_stale_native_agent_is_unknown(self):
        run = self.create()
        run.bind(agent_id="native-test-id")
        status_path = run.path / "status.json"
        status = json.loads(status_path.read_text())
        status["last_activity"] = "2000-01-01T00:00:00+00:00"
        status_path.write_text(json.dumps(status))
        self.assertEqual(run.effective_status()["status"], "unknown")

    def test_project_status_skips_marked_fixture_but_explicit_root_can_inspect(self):
        parent = self.evidence / "global-records"
        fixture = parent / "archived-fixture"
        fixture.mkdir(parents=True)
        (fixture / ".offline-fixture").write_text("offline synthetic fixture\n")
        records = fixture / "records"
        run = RunStore.create(records, "fixture-status-case", self.task, cwd=self.cwd,
                              watch=[], provider="codex-native", model="gpt-6.1-sol", effort="ultra")
        run.bind(agent_id="synthetic-fixture-agent")
        parent_payload = status_payload(parent, self.evidence / "no-history")
        self.assertEqual(parent_payload["records"], [])
        self.assertEqual(parent_payload["running"], 0)
        explicit_payload = status_payload(records, self.evidence / "no-history")
        self.assertEqual(explicit_payload["running"], 1)
        self.assertEqual(explicit_payload["records"][0]["name"], "fixture-status-case")

    def test_long_tool_inputs_and_results_are_durable(self):
        run = self.create()
        body = "BEGIN" + "ordinary-data-" * 20000 + "END"
        run.event("tool_use", name="Read", input={"file_path": "fixture", "body": body})
        run.event("tool_result", tool_use_id="call-1", content=body)
        events = [json.loads(line) for line in (run.path / "events.jsonl").read_text().splitlines()]
        self.assertEqual(events[-2]["input"]["body"], body)
        self.assertEqual(events[-1]["content"], body)
        self.assertEqual(RunStore(run.path).meta["requested_model"], "gpt-6.1-sol")

    def test_redaction_preserves_ordinary_data(self):
        value = {"api_key": "synthetic-test-key", "authorization": "synthetic-auth",
                 "author": "ordinary author retained", "usage": {"input_tokens": 123},
                 "serialized": json.dumps({"api_key": "synthetic-json-secret", "ordinary": "KEEP_JSON",
                                           "nested": [{"password": "synthetic-nested-password"}]}),
                 "text": "Bearer synthetic-test-bearer\nordinary_data=KEEP_ME"}
        result = redact(value)
        self.assertNotIn("synthetic-test-key", json.dumps(result))
        self.assertNotIn("synthetic-test-bearer", json.dumps(result))
        self.assertNotIn("synthetic-json-secret", json.dumps(result))
        self.assertNotIn("synthetic-nested-password", json.dumps(result))
        self.assertEqual(json.loads(result["serialized"])["ordinary"], "KEEP_JSON")
        self.assertEqual(result["author"], "ordinary author retained")
        self.assertEqual(result["usage"], {"input_tokens": 123})
        self.assertIn("ordinary_data=KEEP_ME", result["text"])

    def test_snapshot_restores_tracked_untracked_staged_binary_and_deletion(self):
        git = init_repo(self.cwd)
        (self.cwd / "ordinary-link").symlink_to("tracked.txt")
        run = self.create(allow_write=["tracked.txt", "untracked.txt", "deleted.txt", "new.txt", "binary.dat"])
        original = {p.name: p.read_bytes() for p in self.cwd.iterdir() if p.is_file() and not p.is_symlink()}
        run.snapshot("before")
        (self.cwd / "tracked.txt").write_text("changed after\n")
        (self.cwd / "untracked.txt").write_text("changed untracked\n")
        (self.cwd / "deleted.txt").unlink()
        (self.cwd / "new.txt").write_text("new after\n")
        (self.cwd / "binary.dat").write_bytes(b"\x00changed\xff")
        changes = run.snapshot("after")
        self.assertEqual(changes["added"], ["new.txt"])
        self.assertEqual(changes["deleted"], ["deleted.txt"])
        self.assertEqual(set(changes["modified"]), {"binary.dat", "tracked.txt", "untracked.txt"})
        self.assertEqual(changes["out_of_scope"], [])
        before = run.path / "snapshots/before"
        manifest = json.loads((before / "manifest.json").read_text())["files"]
        restored = self.evidence / "restored"
        restored.mkdir()
        for path, info in manifest.items():
            dest = restored / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            if info["kind"] == "file":
                shutil.copy2(before / "files" / path, dest)
                self.assertEqual(sha256(dest), info["sha256"])
            else:
                dest.symlink_to(info["target"])
        self.assertEqual({name: (restored / name).read_bytes() for name in original}, original)
        self.assertTrue((restored / "ordinary-link").is_symlink())
        self.assertIn("already staged", (before / "staged.txt").read_text())
        self.assertIn("untracked.txt", (before / "untracked.txt").read_text())
        self.assertEqual(git("diff", "--cached", "--name-only"), "tracked.txt\n")

    def test_snapshot_detects_out_of_scope_changes(self):
        (self.cwd / "one.txt").write_text("before")
        run = self.create(allow_write=[])
        run.snapshot("before")
        (self.cwd / "one.txt").write_text("after")
        self.assertEqual(run.snapshot("after")["out_of_scope"], ["one.txt"])

    def test_explicit_workspace_root_write_scope_covers_descendants(self):
        (self.cwd / "one.txt").write_text("before")
        run = self.create(allow_write=["."])
        run.snapshot("before")
        (self.cwd / "one.txt").write_text("after")
        self.assertEqual(run.snapshot("after")["out_of_scope"], [])

    def test_snapshot_detects_permission_and_symlink_target_changes(self):
        (self.cwd / "script.sh").write_text("#!/bin/sh\nexit 0\n")
        os.chmod(self.cwd / "script.sh", 0o644)
        (self.cwd / "link").symlink_to("script.sh")
        run = self.create(allow_write=["script.sh", "link"])
        run.snapshot("before")
        os.chmod(self.cwd / "script.sh", 0o755)
        (self.cwd / "link").unlink()
        (self.cwd / "link").symlink_to("missing-new-target")
        changes = run.snapshot("after")
        self.assertEqual(changes["modified"], ["link", "script.sh"])
        self.assertEqual(changes["out_of_scope"], [])

    def test_absolute_and_parent_scope_escape_are_rejected(self):
        for path in ["../outside", str(self.evidence / "outside")]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.create(watch=[path])

    def test_snapshot_does_not_follow_symlink_ancestor_outside_scope(self):
        outside = self.evidence / "outside"
        outside.mkdir()
        (outside / "private.txt").write_text("synthetic outside-of-workspace canary")
        (self.cwd / "escape").symlink_to(outside, target_is_directory=True)
        try:
            run = self.create(watch=["escape/private.txt"])
            snapshot = run.snapshot("before")
        except ValueError:
            return
        self.assertNotIn("escape/private.txt", snapshot["files"], "snapshot copied a file through an out-of-scope symlink ancestor")

    def test_snapshot_revalidates_parent_after_registration(self):
        outside = self.evidence / "outside"
        outside.mkdir()
        (outside / "private.txt").write_text("synthetic outside-of-workspace canary")
        inside = self.cwd / "safe"
        inside.mkdir()
        (inside / "private.txt").write_text("original inside data")
        run = self.create(watch=["safe/private.txt"])
        (inside / "private.txt").unlink()
        inside.rmdir()
        inside.symlink_to(outside, target_is_directory=True)
        try:
            snapshot = run.snapshot("before")
        except ValueError:
            return
        self.assertNotIn("safe/private.txt", snapshot["files"], "changed symlink ancestor escaped after registration")


class BudgetCase(unittest.TestCase):
    def setUp(self):
        self.evidence = fresh_evidence(self._testMethodName)
        self.config = {"capacity_usd": 10, "source": "synthetic offline fixture"}
        self.path = self.evidence / "budget.json"

    def tearDown(self):
        archive_evidence(self.evidence)

    def test_parallel_reservations_do_not_reuse_capacity(self):
        args = [(str(self.path), self.config, "run-" + str(i), 3) for i in range(12)]
        with concurrent.futures.ProcessPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(reserve_worker, args))
        (self.evidence / "results.json").write_text(json.dumps(results, indent=2))
        self.assertEqual(sum(r.get("reserved", 0) for r in results), 9)
        state = json.loads(self.path.read_text())
        self.assertEqual(len(state["runs"]), 3)

    def test_unknown_cost_keeps_budget_reserved_and_conflicting_settle_rejected(self):
        ledger = BudgetLedger(self.path, self.config)
        ledger.reserve("unknown", 8)
        row = ledger.settle("unknown", None)
        self.assertIsNone(row["cost_usd"])
        with self.assertRaises(ValueError):
            ledger.reserve("next", 3)
        with self.assertRaises(ValueError):
            ledger.settle("unknown", 0)

    def test_unknown_cost_freezes_automatic_usd_domain(self):
        ledger = BudgetLedger(self.path, self.config)
        ledger.reserve("unknown", 2)
        ledger.settle("unknown", None)
        with self.assertRaises(ValueError):
            ledger.reserve("small-next", 1)

    def test_identical_settlement_is_idempotent(self):
        ledger = BudgetLedger(self.path, self.config)
        ledger.reserve("one", 4)
        first = ledger.settle("one", 1.25)
        second = ledger.settle("one", 1.25)
        self.assertEqual(first, second)
        state = json.loads(self.path.read_text())
        self.assertEqual(len(state["runs"]), 1)
        self.assertEqual(state["runs"]["one"]["cost_usd"], 1.25)
        with self.assertRaises(ValueError):
            ledger.settle("one", 1.5)

    def test_corrupt_existing_ledger_must_not_reset_capacity(self):
        ledger = BudgetLedger(self.path, self.config)
        ledger.reserve("prior", 8)
        self.path.write_text('{"runs": corrupt')
        with self.assertRaises((ValueError, RuntimeError, json.JSONDecodeError)):
            ledger.reserve("next", 8)

    def test_reconciliation_preserves_original_and_counts_unknown_rows(self):
        original = Path(__file__).parent / "fixtures/legacy_ledger.md"
        before = original.read_bytes()
        result = reconcile_legacy(original)
        self.assertAlmostEqual(result["known_total_usd"], 34.1896)
        self.assertGreaterEqual(len(result["unknown_costs"]), 1, "explicit unknown historical row was silently discarded")
        self.assertEqual(len(result["rows"]), 3)
        self.assertEqual(original.read_bytes(), before)
        self.assertEqual(result["source_sha256"], hashlib.sha256(before).hexdigest())
        (self.evidence / "reconciliation.json").write_text(json.dumps(result, indent=2))


class ClassificationCase(unittest.TestCase):
    def test_structured_limits_survive_positive_nonzero_exit(self):
        for subtype, reason in [("error_max_turns", "max_turns"), ("error_max_budget_usd", "max_budget_usd")]:
            final = {"type": "result", "subtype": subtype, "terminal_reason": reason,
                     "is_error": True, "errors": ["Reached configured limit"], "result": ""}
            for code in (0, 1):
                with self.subTest(subtype=subtype, exit_code=code):
                    self.assertEqual(classify_result(final, code), "interrupted")
        self.assertEqual(classify_result({"type": "result", "terminal_reason": "budget"}, 1), "interrupted")

    def test_limits_do_not_mask_protocol_api_or_signal_failures(self):
        final = {"type": "result", "subtype": "error_max_turns", "terminal_reason": "max_turns",
                 "is_error": True, "errors": ["Reached maximum number of turns (30)"]}
        for error in ("runner exception", ["invalid/non-object JSON on stdout"]):
            with self.subTest(error=error):
                self.assertEqual(classify_result(final, 1, error=error), "failed")
        self.assertEqual(classify_result({**final, "api_error_status": 503}, 1), "failed")
        self.assertEqual(classify_result(final, -15), "failed")
        self.assertEqual(classify_result(final, None), "failed")
        self.assertEqual(classify_result(None, 1), "failed")
        self.assertEqual(classify_result(None, 0), "unknown")
        success = {"type": "result", "subtype": "success", "is_error": False, "terminal_reason": "completed"}
        self.assertEqual(classify_result(success, 17), "failed")
        self.assertEqual(classify_result(final, 1, interrupted=True), "interrupted")

    def test_structured_failures_are_not_success(self):
        success = {"type": "result", "subtype": "success", "is_error": False, "terminal_reason": "completed"}
        self.assertEqual(classify_result(success), "succeeded")
        cases = [None, {**success, "is_error": True}, {**success, "subtype": "error_max_turns"},
                 {**success, "subtype": "error_max_budget_usd"}, {**success, "api_error_status": 503},
                 {**success, "errors": ["provider failed"]}]
        for case in cases:
            with self.subTest(case=case):
                self.assertNotEqual(classify_result(case), "succeeded")
        self.assertNotEqual(classify_result(success, exit_code=17), "succeeded")
        self.assertEqual(classify_result(success, interrupted=True), "interrupted")


if __name__ == "__main__":
    unittest.main(verbosity=2)
