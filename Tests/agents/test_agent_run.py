"""Run the real adapter against an offline CLI, preserving every run artifact."""
import json
import itertools
import os
from pathlib import Path
import signal
import selectors
import subprocess
import sys
import time
import unittest

from helpers import REPO, MOCK, RECORD, fresh_evidence, invoke, archive_evidence

CLI = REPO / "Tools/agents/agent_run.py"


class BackgroundResultProtocol(unittest.TestCase):
    """Protocol truth comes from explicit event identities, never report text."""
    def setUp(self):
        sys.path.insert(0, str(REPO / "Tools/agents"))
        from agent_run import DeepSeekStreamProtocol
        self.reducer = DeepSeekStreamProtocol
        self.evidence = fresh_evidence(self._testMethodName)
        self.case = 0

    def tearDown(self):
        archive_evidence(self.evidence)

    @staticmethod
    def init():
        return dict(type="system", subtype="init", session_id="background-session")

    @staticmethod
    def start(task="one"):
        return dict(type="system", subtype="task_started", session_id="background-session",
                    task_id=task, run_id="run-" + task, tool_use_id="tool-" + task,
                    is_backgrounded=True, task_type="local_bash")

    @staticmethod
    def notice(task="one", status="completed"):
        return dict(type="system", subtype="task_notification", session_id="background-session",
                    task_id=task, run_id="run-" + task, tool_use_id="tool-" + task, status=status)

    @staticmethod
    def result(index=0, task=None, **extra):
        event = dict(type="result", subtype="success", session_id="background-session", is_error=False,
                     terminal_reason="completed", result_index=index, uuid="result-" + str(index),
                     result="WAIT_REPORT" if index == 0 else "FINAL_REPORT_" + str(index),
                     total_cost_usd=0.125 if index == 0 else 1.25)
        if task:
            event["origin"] = dict(kind="task-notification", producer="session-task", runId="run-" + task)
        event.update(extra)
        return event

    def stream(self):
        return [self.init(), self.start(), self.result(), self.notice(), self.init(), self.result(1, "one")]

    def reduce(self, events, exit_code=0, **extra):
        self.case += 1
        reducer = self.reducer()
        for event in events:
            reducer.consume(event)
        evidence = dict(events=events, exit_code=exit_code, errors=reducer.errors,
                        status=reducer.classify(exit_code, **extra), **reducer.evidence())
        (self.evidence / (str(self.case) + ".json")).write_text(json.dumps(evidence, indent=2))
        return reducer, evidence

    def test_background_result_and_notification_races_are_valid(self):
        ordinary = self.stream()
        early = [self.init(), self.start(), self.notice(), self.result(), self.result(1, "one")]
        late_start = [self.init(), self.result(), self.start(), self.notice(), self.result(1, "one")]
        optional_tool = self.stream()
        optional_tool[1].pop("tool_use_id")
        optional_notice_tool = self.stream()
        optional_notice_tool[3].pop("tool_use_id")
        for events in [ordinary, early, late_start, optional_tool, optional_notice_tool]:
            with self.subTest(events=events):
                reducer, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "succeeded", evidence)
                self.assertEqual(evidence["errors"], [])
                self.assertEqual(reducer.final["result"], "FINAL_REPORT_1")
                self.assertEqual(evidence["background_tasks"][0]["notification_result_index"], 1)

    def test_several_background_turns_consume_each_notification_once(self):
        events = self.stream() + [self.start("two"), self.notice("two"), self.result(2, "two")]
        reducer, evidence = self.reduce(events)
        self.assertEqual(evidence["status"], "succeeded", evidence)
        self.assertEqual(evidence["result_count"], 3)
        self.assertEqual([t["notification_result_index"] for t in evidence["background_tasks"]], [1, 2])
        self.assertEqual(reducer.final["result"], "FINAL_REPORT_2")

    def test_foreground_tasks_are_recorded_without_creating_background_pending(self):
        foreground = self.start("foreground")
        foreground["is_backgrounded"] = False
        variants = [[self.init(), foreground, self.result()],
                    [self.init(), foreground, self.notice("foreground"), self.result()],
                    self.stream()[:1] + [foreground, self.notice("foreground")] + self.stream()[1:]]
        for events in variants:
            with self.subTest(events=events):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "succeeded", evidence)
                self.assertEqual(len(evidence["foreground_tasks"]), 1)
                self.assertEqual(evidence["background_incomplete"], [])
                self.assertIsNone(evidence["foreground_tasks"][0]["notification_result_index"])

    def test_foreground_notifications_cannot_authorize_continuations_or_skip_identity_checks(self):
        foreground = self.start("foreground")
        foreground["is_backgrounded"] = False
        variants = [[self.init(), foreground, self.result(), self.notice("foreground"), self.result(1, "foreground")],
                    [self.init(), foreground, self.notice("foreground"), self.notice("foreground"), self.result()]]
        for field in ["task_id", "run_id", "tool_use_id"]:
            notice = self.notice("foreground")
            notice[field] = "wrong-identity"
            variants.append([self.init(), foreground, notice, self.result()])
        for events in variants:
            with self.subTest(events=events):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "failed", evidence)
                self.assertTrue(evidence["errors"])

    def test_explicit_null_and_wrong_type_identity_fields_are_rejected(self):
        for field, value in [("session_id", None), ("uuid", None), ("result_index", None),
                             ("session_id", {}), ("uuid", 7), ("result_index", "0"), ("result_index", False)]:
            result = self.result()
            result[field] = value
            with self.subTest(field=field, value=value):
                _, evidence = self.reduce([self.init(), result])
                self.assertEqual(evidence["status"], "failed", evidence)
                self.assertTrue(evidence["errors"])

    def test_missing_background_flag_is_unqualified_and_cannot_authorize_followups(self):
        start = self.start("unqualified")
        start.pop("is_backgrounded")
        legacy = self.result()
        legacy.pop("uuid")
        legacy.pop("result_index")
        for events in [[self.init(), start, legacy], [self.init(), start, self.notice("unqualified"), legacy]]:
            with self.subTest(events=events):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "succeeded", evidence)
                self.assertEqual(len(evidence["unqualified_tasks"]), 1)
                self.assertEqual(evidence["foreground_tasks"], [])
                self.assertEqual(evidence["background_tasks"], [])
                self.assertEqual(evidence["background_incomplete"], [])
        events = [self.init(), start, self.result(), self.notice("unqualified"), self.result(1, "unqualified")]
        self.assertEqual(self.reduce(events)[1]["status"], "failed")
        for value in [None, 0, "false", []]:
            invalid = dict(start, is_backgrounded=value)
            with self.subTest(is_backgrounded=value):
                self.assertEqual(self.reduce([self.init(), invalid, legacy])[1]["status"], "failed")

    def test_optional_task_metadata_is_compatible_for_auxiliary_single_results(self):
        for flag in [False, "absent"]:
            for missing in itertools.product([False, True], repeat=5):
                start, notice = self.start("auxiliary"), self.notice("auxiliary")
                if flag == "absent":
                    start.pop("is_backgrounded")
                else:
                    start["is_backgrounded"] = flag
                for absent, event, field in zip(missing, [start, start, start, notice, notice],
                                                ["run_id", "task_type", "tool_use_id", "run_id", "tool_use_id"]):
                    if absent:
                        event.pop(field)
                with self.subTest(flag=flag, missing=missing):
                    _, evidence = self.reduce([self.init(), start, notice, self.result()])
                    self.assertEqual(evidence["status"], "succeeded", evidence)
                    self.assertEqual(evidence["errors"], [])
                    self.assertEqual(evidence["background_incomplete"], [])
                    task = (evidence["foreground_tasks"] + evidence["unqualified_tasks"])[0]
                    self.assertEqual(task["run_id"], start.get("run_id"))
                    self.assertEqual(task["notification_run_id"], notice.get("run_id"))
                    self.assertEqual(task["notification_match"], "weak" if missing[0] or missing[3] else "strong")

    def test_incomplete_explicit_background_metadata_keeps_eof_obligations_without_authority(self):
        for field, position in [("run_id", 1), ("task_type", 1), ("run_id", 3)]:
            events = self.stream()
            events[position].pop(field)
            with self.subTest(field=field, position=position):
                _, waiting = self.reduce(events[:4])
                self.assertEqual(waiting["status"], "unknown", waiting)
                self.assertEqual(waiting["errors"], [])
                self.assertTrue(waiting["background_incomplete"])
                _, continued = self.reduce(events)
                self.assertEqual(continued["status"], "failed", continued)
                self.assertTrue(continued["errors"])

    def test_task_optional_metadata_types_and_historical_ambiguity_remain_strict(self):
        for field in ["run_id", "task_type", "tool_use_id"]:
            for value in [None, "", 7, []]:
                start = self.start("auxiliary")
                start["is_backgrounded"] = False
                start[field] = value
                with self.subTest(field=field, value=value):
                    self.assertEqual(self.reduce([self.init(), start, self.result()])[1]["status"], "failed")
        first, second = self.start("reused"), self.start("reused")
        first["is_backgrounded"] = second["is_backgrounded"] = False
        second["run_id"] = "run-second"
        old_notice = self.notice("reused")
        ambiguous = self.notice("reused")
        ambiguous.pop("run_id")
        events = [self.init(), first, old_notice, second, ambiguous, self.result()]
        self.assertEqual(self.reduce(events)[1]["status"], "failed")
        start = self.start("no-run")
        start["is_backgrounded"] = False
        start.pop("run_id")
        notice = self.notice("no-run")
        notice.pop("run_id")
        self.assertEqual(self.reduce([self.init(), start, notice, notice, self.result()])[1]["status"], "failed")
        first, other = self.start(), self.start("different-task")
        other["run_id"] = first["run_id"]
        events = [self.init(), first, other, self.notice(), self.result(0, "one")]
        _, evidence = self.reduce(events)
        self.assertEqual(evidence["status"], "failed", evidence)
        self.assertIn("duplicate task identity", evidence["errors"])

    def test_distinct_auxiliary_starts_without_run_ids_do_not_collide(self):
        events = [self.init()]
        for name in ["first", "second"]:
            start, notice = self.start(name), self.notice(name)
            start["is_backgrounded"] = False
            start.pop("run_id")
            notice.pop("run_id")
            events += [start, notice]
        events.append(self.result())
        _, evidence = self.reduce(events)
        self.assertEqual(evidence["status"], "succeeded", evidence)
        self.assertEqual(len(evidence["foreground_tasks"]), 2)

    def test_unfinished_background_or_unreported_notification_is_unknown(self):
        for events in [self.stream()[:3], self.stream()[:4], self.stream() + [self.start("two")]]:
            with self.subTest(events=events):
                reducer, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "unknown", evidence)
                self.assertTrue(evidence["background_incomplete"])
                self.assertEqual(reducer.errors, [])

    def test_duplicate_unassociated_or_malformed_results_fail(self):
        variants = [[self.init(), self.result(), self.result(1)], self.stream() + [self.result(2, "one")]]
        for field, value in [("result_index", 0), ("result_index", 2), ("result_index", True),
                             ("uuid", "result-0"), ("uuid", None), ("session_id", None),
                             ("origin", None), ("origin", {"kind": "other"}),
                             ("origin", {"kind": "task-notification", "producer": "other", "runId": "run-one"}),
                             ("origin", {"kind": "task-notification", "producer": "session-task", "runId": "wrong"})]:
            events = self.stream()
            events[-1][field] = value
            variants.append(events)
        for field in ["result_index", "uuid", "session_id"]:
            events = self.stream()
            events[2].pop(field)
            variants.append(events)
        for events in variants:
            with self.subTest(events=events):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "failed", evidence)
                self.assertTrue(evidence["errors"])

    def test_session_identity_is_locked_across_all_event_types(self):
        for position in [1, 2, 3, 4, 5]:
            events = self.stream()
            events[position]["session_id"] = "unrelated-session"
            with self.subTest(position=position):
                reducer, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "failed", evidence)
                self.assertEqual(reducer.session_id, "background-session")
        events = self.stream()
        events.insert(2, dict(type="assistant", session_id="unrelated-session"))
        self.assertEqual(self.reduce(events)[1]["status"], "failed")

    def test_unmatched_duplicate_or_wrong_order_task_events_fail(self):
        variants = []
        for field, value in [("task_id", "wrong"), ("run_id", "wrong"), ("tool_use_id", "wrong"),
                             ("status", "running"), ("session_id", None)]:
            events = self.stream()
            events[3][field] = value
            variants.append(events)
        for field in ["task_id", "run_id", "session_id"]:
            events = self.stream()
            events[1].pop(field)
            variants.append(events)
        variants += [[self.init(), self.notice(), self.result()],
                     [self.init(), self.notice(), self.start(), self.result(), self.result(1, "one")],
                     self.stream()[:3] + [self.notice(), self.notice()] + self.stream()[4:],
                     [self.init(), self.start(), self.start()] + self.stream()[2:]]
        for events in variants:
            with self.subTest(events=events):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "failed", evidence)
                self.assertTrue(evidence["errors"])

    def test_unsuccessful_intermediate_results_cannot_be_washed_by_success(self):
        for changes in [dict(is_error=True), dict(subtype="error_during_execution"),
                        dict(api_error_status=503), dict(errors=["provider failure"]),
                        dict(subtype="error_max_turns", terminal_reason="max_turns", is_error=True),
                        dict(terminal_reason="cancelled"), dict(result=""), dict(result={"bad": "report"})]:
            events = self.stream()
            events[2].update(changes)
            with self.subTest(changes=changes):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "failed", evidence)
                self.assertTrue(evidence["errors"])

    def test_background_command_failures_are_distinct_from_provider_completion(self):
        for status in ["failed", "stopped"]:
            events = self.stream()
            events[3]["status"] = status
            with self.subTest(status=status):
                _, evidence = self.reduce(events)
                self.assertEqual(evidence["status"], "succeeded", evidence)
                self.assertEqual(evidence["background_task_failures"][0]["status"], status)

    def test_final_errors_limits_and_exit_codes_keep_existing_semantics(self):
        cases = [(dict(is_error=True), 0, "failed"), (dict(api_error_status=503), 0, "failed"),
                 (dict(subtype="error_max_turns", terminal_reason="max_turns", is_error=True), 1, "interrupted"),
                 (dict(subtype="error_max_turns", terminal_reason="max_turns", is_error=True, result=""), 1, "interrupted"),
                 (dict(subtype="error_max_budget_usd", is_error=True), 1, "interrupted"),
                 ({}, 17, "failed"), ({}, -15, "failed")]
        for changes, exit_code, expected in cases:
            events = self.stream()
            events[-1].update(changes)
            with self.subTest(changes=changes, exit_code=exit_code):
                self.assertEqual(self.reduce(events, exit_code)[1]["status"], expected)
        self.assertEqual(self.reduce(self.stream()[:3], interrupted=True)[1]["status"], "interrupted")

    def test_last_cumulative_cost_is_not_summed_and_legacy_single_result_is_valid(self):
        reducer, evidence = self.reduce(self.stream())
        self.assertEqual(reducer.final["total_cost_usd"], 1.25)
        self.assertEqual([r["total_cost_usd"] for r in evidence["turn_results"]], [0.125, 1.25])
        legacy = self.result()
        for field in ["result_index", "uuid", "session_id"]:
            legacy.pop(field)
        self.assertEqual(self.reduce([self.init(), dict(type="assistant"), legacy])[1]["status"], "succeeded")


class AgentCLI(unittest.TestCase):
    def setUp(self):
        self.evidence = fresh_evidence(self._testMethodName)
        self.cwd = self.evidence / "workspace"
        self.cwd.mkdir()
        (self.cwd / "source.txt").write_text("original watched content\n")
        self.task = self.evidence / "task.md"
        self.task.write_text("Offline fixture. Do not use API or network. Return the mock report.\n")
        self.records = self.evidence / "records"

    def tearDown(self):
        archive_evidence(self.evidence)

    def command(self, action="deepseek", name="same-name", *extra):
        return [sys.executable, str(CLI), action, name, str(self.task),
                "--records-root", str(self.records), "--cwd", str(self.cwd), "--watch", ".",
                *( ["--cli", str(MOCK), "--max-turns", "4", "--timeout", "4"]
                  if action == "deepseek" else ["--model", "gpt-6.1-sol", "--effort", "ultra"] ),
                *extra]

    def runs(self):
        return sorted(p.parent for p in self.records.glob("*/meta.json"))

    def execute(self, scenario, *extra, expected_code=None):
        evidence = self.evidence / scenario
        evidence.mkdir()
        proc = invoke(self.command("deepseek", "same-name", *extra),
                      env={"MOCK_SCENARIO": scenario}, evidence=evidence, timeout=15)
        runs = self.runs()
        self.assertTrue(runs, proc.stdout + proc.stderr)
        run = runs[-1]
        self.assertTrue((run / "result.json").exists(), proc.stdout + proc.stderr)
        result = json.loads((run / "result.json").read_text())
        if expected_code is not None:
            self.assertEqual(proc.returncode, expected_code, result)
        return proc, run, result

    def execute_stream(self, label, events, exit_code=0):
        """Only forward saved events; no event can execute a tool or use an API."""
        case = self.evidence / label
        case.mkdir()
        stream = case / "stream.jsonl"
        stream.write_text("".join(json.dumps(event) + "\n" for event in events))
        cli = case / "forward_stream.py"
        cli.write_text("#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
                       "sys.stdout.buffer.write(Path(__file__).with_name('stream.jsonl').read_bytes())\n"
                       "sys.stdout.buffer.flush()\nraise SystemExit(" + str(exit_code) + ")\n")
        cli.chmod(0o755)
        proc = invoke(self.command("deepseek", label, "--cli", str(cli)), evidence=case)
        run = self.runs()[-1]
        return proc, run, json.loads((run / "result.json").read_text())

    def test_background_continuation_uses_last_report_and_preserves_task_outcomes(self):
        fixture = BackgroundResultProtocol()
        for status in ["completed", "failed", "stopped"]:
            events = fixture.stream()
            events[3]["status"] = status
            with self.subTest(task_status=status):
                proc, run, result = self.execute_stream(status, events)
                self.assertEqual(proc.returncode, 0, result)
                self.assertEqual(result["provider_status"], "succeeded")
                self.assertEqual(result["acceptance_status"], "pending")
                self.assertEqual(result["verification_status"], "not_run")
                self.assertEqual(result["result_count"], 2)
                self.assertEqual(result["protocol_errors"], [])
                self.assertEqual(result["background_incomplete"], [])
                self.assertEqual(result["background_tasks"][0]["status"], status)
                self.assertEqual(bool(result["background_task_failures"]), status != "completed")
                self.assertEqual((run / "output.md").read_text(), "FINAL_REPORT_1")
                self.assertIsNone(result["cost_usd"])
                self.assertEqual(result["cli_reported_cost_usd"], 1.25)
                self.assertTrue((run / "snapshots/after/manifest.json").exists())

    def test_foreground_telemetry_preserves_single_and_background_completion(self):
        fixture = BackgroundResultProtocol()
        foreground = fixture.start("foreground")
        foreground["is_backgrounded"] = False
        prefix = [fixture.init(), foreground, fixture.notice("foreground")]
        for label, events in [("foreground-single", prefix + [fixture.result()]),
                              ("foreground-and-background", prefix + fixture.stream()[1:])]:
            with self.subTest(label=label):
                proc, run, result = self.execute_stream(label, events)
                self.assertEqual(proc.returncode, 0, result)
                self.assertEqual(result["provider_status"], "succeeded")
                self.assertEqual(result["acceptance_status"], "pending")
                self.assertEqual(len(result["foreground_tasks"]), 1)
                self.assertEqual(result["foreground_tasks"][0]["status"], "completed")
                self.assertEqual(result["protocol_errors"], [])
                self.assertEqual(result["background_incomplete"], [])

    def test_unqualified_tasks_keep_legacy_single_compatibility_without_background_authority(self):
        fixture = BackgroundResultProtocol()
        start = fixture.start("unqualified")
        start.pop("is_backgrounded")
        legacy = fixture.result()
        legacy.pop("uuid")
        legacy.pop("result_index")
        cases = [("unqualified-single", [fixture.init(), start, fixture.notice("unqualified"), legacy], 0),
                 ("unqualified-cannot-wake", [fixture.init(), start, fixture.result(), fixture.notice("unqualified"),
                                             fixture.result(1, "unqualified")], 1)]
        for label, events, expected_code in cases:
            with self.subTest(label=label):
                proc, _, result = self.execute_stream(label, events)
                self.assertEqual(proc.returncode, expected_code, result)
                self.assertEqual(result["provider_status"], "succeeded" if expected_code == 0 else "failed")
                self.assertEqual(len(result["unqualified_tasks"]), 1)
                self.assertEqual(result["foreground_tasks"], [])
                self.assertEqual(result["background_tasks"], [])
                self.assertEqual(result["background_incomplete"], [])
                self.assertEqual(bool(result["protocol_errors"]), expected_code != 0)

    def test_optional_auxiliary_metadata_is_preserved_by_the_real_runner(self):
        fixture = BackgroundResultProtocol()
        for label, flag in [("auxiliary-foreground", False), ("auxiliary-unqualified", None),
                            ("incomplete-explicit-background", True)]:
            start, notice = fixture.start(label), fixture.notice(label)
            for field in ["run_id", "task_type", "tool_use_id"]:
                start.pop(field)
            for field in ["run_id", "tool_use_id"]:
                notice.pop(field)
            if flag is None:
                start.pop("is_backgrounded")
            else:
                start["is_backgrounded"] = flag
            with self.subTest(label=label):
                proc, _, result = self.execute_stream(label, [fixture.init(), start, notice, fixture.result()])
                self.assertEqual(proc.returncode, 1 if flag is True else 0, result)
                self.assertEqual(result["provider_status"], "unknown" if flag is True else "succeeded")
                self.assertEqual(result["protocol_errors"], [])
                self.assertEqual(bool(result["background_incomplete"]), flag is True)

    def test_invalid_and_unfinished_background_streams_never_succeed(self):
        fixture = BackgroundResultProtocol()
        variants = [("pending-task", fixture.stream()[:3], "unknown"),
                    ("missing-followup", fixture.stream()[:4], "unknown"),
                    ("unassociated", [fixture.init(), fixture.result(), fixture.result(1)], "failed")]
        crossed = fixture.stream()
        crossed[-1]["session_id"] = "unrelated-session"
        variants.append(("crossed-session", crossed, "failed"))
        error_then_success = fixture.stream()
        error_then_success[2]["is_error"] = True
        variants.append(("washed-error", error_then_success, "failed"))
        for label, events, expected in variants:
            with self.subTest(label=label):
                proc, run, result = self.execute_stream(label, events)
                self.assertEqual(proc.returncode, 1, result)
                self.assertEqual(result["runner_exit_code"], 1)
                self.assertEqual(result["provider_status"], expected)
                self.assertEqual(result["session_id"], "background-session")
                self.assertEqual(json.loads((run / "meta.json").read_text())["session_id"], "background-session")
                self.assertEqual(bool(result["protocol_errors"]), expected == "failed")
                self.assertEqual(bool(result["background_incomplete"]), expected == "unknown")
                self.assertIsNone(result["cost_usd"])
                self.assertTrue((run / "snapshots/after/manifest.json").exists())

    def test_success_and_normal_stderr_are_provider_success(self):
        for scenario in ["success", "stderr"]:
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario, expected_code=0)
                self.assertEqual(result["provider_status"], "succeeded")
                self.assertEqual(result["acceptance_status"], "pending")
                self.assertEqual(result["provider_status"], "succeeded")
                self.assertEqual(result["verification_status"], "not_run")
                self.assertEqual((run / "output.md").read_text().strip(), "OFFLINE_EXPECTED_OUTPUT")
                self.assertIsNone(result["cost_usd"])
                self.assertEqual(result["cli_reported_cost_usd"], 0.125)
                self.assertEqual(result["session_id"], "offline-session-123")

    def test_error_final_nonzero_blank_and_bad_json_never_succeed(self):
        for scenario in ["provider", "is-error", "bad-json", "blank-output", "invalid-output", "missing-error-flag", "exit-error", "late-nonzero"]:
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario)
                self.assertNotEqual(proc.returncode, 0, result)
                self.assertNotEqual(result["provider_status"], "succeeded", result)

    def test_no_final_is_unknown(self):
        proc, run, result = self.execute("no-final")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(result["provider_status"], "unknown")
        self.assertIsNone(result["cost_usd"])

    def test_turn_and_budget_caps_are_interrupted(self):
        for scenario in ["turns", "budget"]:
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(result["provider_status"], "interrupted")

    def test_nonzero_structured_limit_finals_are_interrupted_with_real_exit(self):
        for scenario in ("turns-nonzero", "budget-nonzero"):
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario, expected_code=1)
                self.assertEqual(result["provider_status"], "interrupted")
                self.assertEqual(result["exit_code"], 1)
                self.assertEqual(result["runner_exit_code"], proc.returncode)
                self.assertEqual(result["acceptance_status"], "pending")
                self.assertEqual(result["verification_status"], "not_run")
                self.assertTrue((run / "snapshots/after/manifest.json").exists())
                self.assertTrue((run / "output.md").read_text().strip())
                self.assertIsNone(result["cost_usd"])
                self.assertTrue(result["errors"])

    def test_nonzero_limits_do_not_mask_bad_protocol_or_ordinary_failures(self):
        for scenario in ("turns-nonzero-protocol", "late-nonzero", "provider", "exit-error", "blank-output", "signal"):
            with self.subTest(scenario=scenario):
                proc, run, result = self.execute(scenario)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(result["provider_status"], "failed")
                if scenario == "turns-nonzero-protocol":
                    self.assertTrue(result["protocol_errors"])
                    self.assertEqual(result["subtype"], "error_max_turns")

    def test_timeout_finalizes_and_reaps_child(self):
        proc, run, result = self.execute("timeout", "--timeout", "0.5")
        self.assertEqual(proc.returncode, 124, result)
        self.assertEqual(result["provider_status"], "interrupted")
        child = json.loads((run / "meta.json").read_text())["child_pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)
        transcript = (run / "transcript.jsonl").read_text()
        self.assertIn("tool_result", transcript)
        self.assertIn("_END_NORMAL", transcript)

    def test_redacted_transcript_keeps_full_normal_tool_result(self):
        proc, run, result = self.execute("secret", expected_code=0)
        text = "\n".join(p.read_text(errors="replace") for p in run.iterdir()
                         if p.is_file() and p.suffix in {".json", ".jsonl", ".md", ".log"})
        for canary in ["synthetic-secret-123456789", "synthetic-key-123456789",
                       "synthetic-nested-credential", "synthetic-stderr-credential"]:
            self.assertNotIn(canary, text)
        events = [json.loads(line) for line in (run / "transcript.jsonl").read_text().splitlines()]
        tool_result = next(e for e in events if e.get("type") == "user")
        body = tool_result["message"]["content"][0]["content"]
        self.assertEqual(body, "BEGIN_NORMAL_" + "abcdef0123456789" * 12000 + "_END_NORMAL")
        self.assertIn("COMPLETE_KEEP_THIS", text)

    def test_watched_write_outside_allowed_paths_fails(self):
        proc, run, result = self.execute("scope-write")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["out_of_scope_changes"], ["source.txt"])
        self.assertEqual((self.cwd / "source.txt").read_text(), "mock changed watched source\n")

    def test_bounded_unknown_cost_runs_can_continue_as_new_attempts(self):
        first = self.execute("unknown-cost", expected_code=0)[1]
        second_evidence = self.evidence / "second-bounded-call"
        second_evidence.mkdir()
        proc = invoke(self.command(), env={"MOCK_SCENARIO": "unknown-cost"}, evidence=second_evidence)
        self.assertEqual(proc.returncode, 0)
        runs = self.runs()
        self.assertEqual(len(runs), 2)
        self.assertNotEqual(runs[0], runs[1])
        for run in runs:
            result = json.loads((run / "result.json").read_text())
            self.assertIsNone(result["cost_usd"])
            meta = json.loads((run / "meta.json").read_text())
            self.assertEqual(meta["max_turns"], 4)
            self.assertEqual(meta["timeout_seconds"], 4)

    def test_context_recovery_is_new_run_and_reads_previous_progress(self):
        _, first, first_result = self.execute("success", expected_code=0)
        with (first / "progress.md").open("a") as handle:
            handle.write("\nOLD_COMPLETED_WORK_CANARY: verify artifacts before continuing.\n")
        old_result = (first / "result.json").read_bytes()
        old_output = (first / "output.md").read_bytes()
        plan = self.evidence / "recovery-plan.md"
        plan.write_text("Completed: initial mock report. Remaining: review only. No side effects may be replayed.\n")
        case = self.evidence / "recovery"
        case.mkdir()
        proc = invoke(self.command("deepseek", "resume-case", "--resume", str(first),
                                   "--resume-mode", "context", "--recovery-plan", str(plan)),
                      env={"MOCK_SCENARIO": "success"}, evidence=case)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        runs = self.runs()
        self.assertEqual(len(runs), 2)
        second = runs[-1]
        self.assertNotEqual(first, second)
        meta = json.loads((second / "meta.json").read_text())
        self.assertEqual(meta["parent_run"], str(first))
        prompt = (second / "prompt.md").read_text()
        self.assertIn("OLD_COMPLETED_WORK_CANARY", prompt)
        self.assertIn("Previous task.md", prompt)
        self.assertIn("Previous result.json", prompt)
        self.assertIn("No side effects may be replayed", prompt)
        self.assertEqual((first / "result.json").read_bytes(), old_result)
        self.assertEqual((first / "output.md").read_bytes(), old_output)

    def test_native_cli_json_and_nonzero_acceptance(self):
        init = invoke(self.command("init", 'quote"slash\\line\nname'), evidence=self.evidence)
        self.assertEqual(init.returncode, 0, init.stderr)
        run = Path(json.loads(init.stdout)["run_dir"])
        bind = invoke([sys.executable, CLI, "bind", run, "--agent-id", "synthetic-native"],
                      evidence=fresh_evidence("bind-command"))
        self.assertEqual(bind.returncode, 0)
        status = invoke([sys.executable, CLI, "status", "--json", "--records-root", self.records,
                         "--history-root", self.evidence / "no-history"],
                        evidence=fresh_evidence("status-command"))
        payload = json.loads(status.stdout)
        self.assertEqual(payload["running"], 1)
        self.assertEqual(payload["records"][0]["name"], 'quote"slash\\line\nname')
        report = self.evidence / "report.md"
        report.write_text("provider ran; product validation failed")
        finish = invoke([sys.executable, CLI, "finish", run, "--provider-status", "succeeded",
                         "--acceptance", "failed", "--output", report, "--exit-code", "0"],
                        evidence=fresh_evidence("finish-command"))
        self.assertNotEqual(finish.returncode, 0)
        result = json.loads((run / "result.json").read_text())
        self.assertEqual(result["provider_status"], "succeeded")
        self.assertEqual(result["acceptance_status"], "failed")
        self.assertEqual(result["status"], "failed")

    def test_native_finish_can_read_its_own_preexisting_output(self):
        init = invoke(self.command("init", "native-prewritten-report"), evidence=self.evidence)
        self.assertEqual(init.returncode, 0, init.stderr)
        run = Path(json.loads(init.stdout)["run_dir"])
        output = run / "output.md"
        output.write_text("Complete native report already saved before finalization.\n")
        original = output.read_bytes()
        finish = invoke([sys.executable, CLI, "finish", run, "--provider-status", "succeeded",
                         "--acceptance", "pending", "--output", output, "--exit-code", "0"],
                        evidence=fresh_evidence("native-prewritten-finish"))
        self.assertEqual(finish.returncode, 0, finish.stderr)
        self.assertEqual(output.read_bytes(), original)
        self.assertEqual(json.loads((run / "result.json").read_text())["provider_status"], "succeeded")

    def test_stream_is_durable_before_runner_kill_and_status_is_unknown(self):
        command = self.command("deepseek", "kill-case", "--timeout", "10")
        env = os.environ.copy()
        env["MOCK_SCENARIO"] = "kill-parent"
        with (self.evidence / "stdout.txt").open("w") as stdout, (self.evidence / "stderr.txt").open("w") as stderr:
            process = subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr)
            child = None
            try:
                deadline = time.monotonic() + 5
                run = None
                while time.monotonic() < deadline:
                    runs = self.runs()
                    if runs:
                        run = runs[0]
                        transcript = run / "transcript.jsonl"
                        if transcript.exists() and "tool_result" in transcript.read_text():
                            break
                    time.sleep(0.02)
                self.assertIsNotNone(run)
                self.assertIsNone(process.poll(), "fixture terminated before streaming assertion")
                self.assertIn("_END_NORMAL", (run / "transcript.jsonl").read_text())
                child = json.loads((run / "meta.json").read_text())["child_pid"]
                process.kill()
                process.wait(timeout=5)
                status = invoke([sys.executable, CLI, "status", "--json", "--records-root", self.records,
                                 "--history-root", self.evidence / "no-history"],
                                evidence=fresh_evidence("killed-status"))
                payload = json.loads(status.stdout)
                self.assertEqual(payload["running"], 0)
                self.assertEqual(payload["records"][0]["state"], "unknown")
                self.assertTrue((run / "events.jsonl").exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if child:
                    try:
                        os.killpg(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                entry = {"argv": command, "environment_overrides": {"MOCK_SCENARIO": "kill-parent"},
                         "exit_code": process.returncode, "stdout": str(self.evidence / "stdout.txt"),
                         "stderr": str(self.evidence / "stderr.txt"), "runner_kill": "SIGKILL",
                         "cleanup_child_process_group": child}
                (self.evidence / "command.json").write_text(json.dumps(entry, indent=2))
                with (RECORD / "journal.jsonl").open("a") as handle:
                    handle.write(json.dumps(entry) + "\n")

    def test_term_finalizes_and_terminates_child_group(self):
        command = self.command("deepseek", "term-case", "--timeout", "10")
        env = os.environ.copy()
        env["MOCK_SCENARIO"] = "kill-parent"
        with (self.evidence / "stdout.txt").open("w") as stdout, (self.evidence / "stderr.txt").open("w") as stderr:
            process = subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr)
            child = None
            try:
                deadline = time.monotonic() + 5
                run = None
                while time.monotonic() < deadline:
                    runs = self.runs()
                    if runs:
                        run = runs[0]
                        transcript = run / "transcript.jsonl"
                        if transcript.exists() and "tool_result" in transcript.read_text():
                            break
                    time.sleep(0.02)
                self.assertIsNotNone(run)
                child = json.loads((run / "meta.json").read_text())["child_pid"]
                process.terminate()
                process.wait(timeout=6)
                self.assertNotEqual(process.returncode, 0)
                result = json.loads((run / "result.json").read_text())
                self.assertEqual(result["provider_status"], "interrupted")
                self.assertIn("signal_", result["runner_terminal_reason"])
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
                self.assertIn("tool_result", (run / "transcript.jsonl").read_text())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if child:
                    try:
                        os.killpg(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                entry = {"argv": command, "environment_overrides": {"MOCK_SCENARIO": "kill-parent"},
                         "exit_code": process.returncode, "stdout": str(self.evidence / "stdout.txt"),
                         "stderr": str(self.evidence / "stderr.txt"), "runner_signal": "SIGTERM"}
                (self.evidence / "command.json").write_text(json.dumps(entry, indent=2))
                with (RECORD / "journal.jsonl").open("a") as handle:
                    handle.write(json.dumps(entry) + "\n")

    def test_deepseek_shell_wrappers_propagate_nonzero(self):
        for wrapper in ["run_deepseek.sh", "run_deepseek_dev.sh"]:
            with self.subTest(wrapper=wrapper):
                # command()[5:] starts --records-root after name/task.
                args = self.command()[5:]
                if wrapper == "run_deepseek_dev.sh":
                    args += ["--allow-write", "source.txt"]
                evidence = self.evidence / wrapper
                evidence.mkdir()
                process = invoke([REPO / "Tests" / wrapper, self.task, *args],
                                 env={"MOCK_SCENARIO": "provider"}, evidence=evidence)
                self.assertNotEqual(process.returncode, 0)
                runs = self.runs()
                self.assertTrue(runs, process.stderr)
                result = json.loads((runs[-1] / "result.json").read_text())
                self.assertEqual(result["provider_status"], "failed")

    def test_child_receives_exact_run_path_and_semantic_progress_survives(self):
        self.records.mkdir()
        sibling = self.records / "unrelated-run"
        sibling.mkdir()
        sentinel = sibling / "progress.md"
        sentinel.write_text("UNRELATED_RUN_UNCHANGED")
        proc, run, result = self.execute("run-path", expected_code=0)
        child = json.loads((run / "artifacts/child-run-path.json").read_text())
        self.assertEqual(child["run_dir"], str(run))
        self.assertIn("MOCK_SEMANTIC_PROGRESS", (run / "progress.md").read_text())
        self.assertEqual(sentinel.read_text(), "UNRELATED_RUN_UNCHANGED")
        self.assertEqual(result["out_of_scope_changes"], [])
        command = json.loads((run / "command.json").read_text())
        combined = "\n".join(command)
        self.assertIn(str(run / "progress.md"), combined)
        self.assertIn(str(run / "artifacts"), combined)

    def test_run_dir_is_printed_live_before_child_finishes(self):
        command = self.command("deepseek", "live-path", "--timeout", "10")
        env = os.environ.copy()
        env["MOCK_SCENARIO"] = "run-path-live"
        with (self.evidence / "stderr.txt").open("w") as stderr:
            process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=stderr)
            output = b""
            try:
                selector = selectors.DefaultSelector()
                selector.register(process.stdout, selectors.EVENT_READ)
                ready = selector.select(timeout=3)
                self.assertTrue(ready, "RUN_DIR was not available before child finished")
                output = os.read(process.stdout.fileno(), 65536)
                selector.close()
                self.assertIn(b"RUN_DIR=", output)
                self.assertIsNone(process.poll())
                run = Path(output.decode().split("RUN_DIR=", 1)[1].splitlines()[0])
                deadline = time.monotonic() + 2
                while not (run / "artifacts/child-run-path.json").exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue((run / "artifacts/child-run-path.json").exists())
                process.terminate()
                rest, _ = process.communicate(timeout=6)
                output += rest
                result = json.loads((run / "result.json").read_text())
                self.assertEqual(result["provider_status"], "interrupted")
                self.assertIn("MOCK_SEMANTIC_PROGRESS", (run / "progress.md").read_text())
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        rest, _ = process.communicate(timeout=6)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        rest, _ = process.communicate(timeout=5)
                    output += rest
                (self.evidence / "stdout.txt").write_bytes(output)
                entry = {"argv": command, "environment_overrides": {"MOCK_SCENARIO": "run-path-live"},
                         "exit_code": process.returncode, "stdout": str(self.evidence / "stdout.txt"),
                         "stderr": str(self.evidence / "stderr.txt"), "runner_signal": "SIGTERM after live RUN_DIR assertion"}
                (self.evidence / "command.json").write_text(json.dumps(entry, indent=2))
                with (RECORD / "journal.jsonl").open("a") as handle:
                    handle.write(json.dumps(entry) + "\n")


    def test_own_write_permissions_use_exact_edit_rules_and_absolute_anchor(self):
        # Official CLI contract: Write(path) never matches file operations;
        # Edit(path) authorizes Write without exposing the Edit tool itself.
        from types import SimpleNamespace
        sys.path.insert(0, str(REPO / "Tools/agents"))
        from agent_run import tool_configuration
        paths = [("inside", self.cwd / "Tools/agents/records/batch/this-run"),
                 ("outside", self.evidence / "records/this-run")]
        for label, path in paths:
            with self.subTest(location=label):
                tools, allowed = tool_configuration(
                    SimpleNamespace(cwd=self.cwd, allow_command=[], allow_write=[]),
                    SimpleNamespace(path=path))
                prefix = ("Tools/agents/records/batch/this-run" if label == "inside"
                          else "/" + path.as_posix())
                self.assertEqual(tools, ["Read", "Glob", "Grep", "Write"])
                self.assertEqual(allowed, ["Read", "Glob", "Grep",
                                          f"Edit({prefix}/progress.md)",
                                          f"Edit({prefix}/artifacts/**)"])
                self.assertNotIn("Edit", allowed)
                self.assertNotIn("Write", allowed)
                self.assertFalse(any(rule.startswith("Write(") for rule in allowed))
                self.assertFalse(any("Edit(Tools/agents/records/**)" == rule for rule in allowed))
                (self.evidence / f"permissions-{label}.json").write_text(
                    json.dumps({"tools": tools, "allowed": allowed}, indent=2))


if __name__ == "__main__":
    unittest.main(verbosity=2)
