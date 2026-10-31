#!/usr/bin/env python3
"""Offline attribution and suite probes. Never launches an app or xcodebuild."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


archive = load("archive_build", PROJECT / "Tools/archive_build.py")
sys.modules["archive_build"] = archive
builder = load("build_release", PROJECT / "Tools/build_release.py")
ui = load("probe_ui", PROJECT / "Tests/ui/ui.py")
SUITE = (PROJECT / "Tests/ui/run_suite.sh").read_text()
SUITE_PY = SUITE.split("<<'PY' 2>&1 | tee -a \"$OUT\"\n", 1)[1].rsplit("\nPY", 1)[0]


def keep_fixture(name, value):
    if os.environ.get("GPXPV_HARNESS_EVIDENCE"):
        folder = Path(os.environ["GPXPV_HARNESS_EVIDENCE"])
        folder.mkdir(parents=True, exist_ok=True)
        (folder / (name + ".json")).write_text(json.dumps(value, ensure_ascii=False, indent=2,
            default=lambda item: item.decode(errors="replace") if isinstance(item, bytes) else str(item)) + "\n")


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gpxpv-attribution-probe-")
        self.root = Path(self.temp.name)
        self.project = self.root / "project"
        for name in archive.INPUT_ROOTS:
            folder = self.project / name
            folder.mkdir(parents=True)
            (folder / "input.txt").write_text(name)
        self.app = self.root / "original/GPXPointViewer.app"
        exe = self.app / "Contents/MacOS/GPXPointViewer"
        exe.parent.mkdir(parents=True)
        exe.write_bytes(b"OFFLINE FIXTURE ONLY")
        self.source = archive.source_inputs(self.project)

    def tearDown(self):
        self.temp.cleanup()

    def attributed(self):
        return archive.archive_bundle(self.app, self.root / "verified", source=self.source,
                                      build={"exit_code": 0, "argv": ["OFFLINE FIXTURE"]}, project=self.project)[0]

    def test_verified_bundle_and_source_change_with_same_mtime(self):
        target = self.attributed()
        self.assertEqual(archive.validate_bundle(target, project=self.project)["source_sha256"], self.source["sha256"])
        source = self.project / "GPXPointViewer/input.txt"
        previous = source.stat()
        source.write_text("changed source at preserved mtime")
        os.utime(source, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, "Current build inputs differ"):
            archive.validate_bundle(target, project=self.project)

    def test_changed_nested_bundle_is_rejected(self):
        target = self.attributed()
        nested = target / "Contents/PlugIns/Preview.appex/Contents/MacOS/Preview"
        nested.parent.mkdir(parents=True)
        nested.write_bytes(b"changed nested extension")
        with self.assertRaisesRegex(ValueError, "Bundle contents differ"):
            archive.validate_bundle(target, project=self.project)

    def test_missing_and_historical_manifest_never_claim_current_source(self):
        with self.assertRaises(FileNotFoundError): archive.validate_bundle(self.app, project=self.project)
        historical, manifest = archive.archive_bundle(self.app, self.root / "historical")
        self.assertIsNone(manifest["source_inputs"])
        with self.assertRaisesRegex(ValueError, "Historical bundle"):
            archive.validate_bundle(historical, project=self.project)

    def test_archive_never_overwrites_and_refuses_failed_build(self):
        self.attributed()
        with self.assertRaises(FileExistsError): self.attributed()
        with self.assertRaisesRegex(ValueError, "Successful build"):
            archive.archive_bundle(self.app, self.root / "failed", source=self.source,
                                   build={"exit_code": 1}, project=self.project)

    def test_ui_requires_explicit_target_and_override_is_labelled(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(SystemExit, "GPXPV_APP"):
                ui.app_source()
        with patch.dict(os.environ, {"GPXPV_APP": str(self.app)}, clear=True):
            with self.assertRaises(SystemExit): ui.app_source()
        with patch.dict(os.environ, {"GPXPV_APP": str(self.app), "GPXPV_ALLOW_UNVERIFIED_BUILD": "1"}, clear=True):
            with contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(ui.app_source(), str(self.app.resolve()))
            self.assertIn("UNVERIFIED_EXPLICIT_OVERRIDE", output.getvalue())
            self.assertIn(archive.sha256(self.app / "Contents/MacOS/GPXPointViewer"), output.getvalue())

    def test_builder_captures_command_and_refuses_changed_source(self):
        build_calls = []
        def fake_build(command, **kwargs):
            build_calls.append(command)
            derived = Path(command[command.index("-derivedDataPath") + 1])
            exe = derived / "Build/Products/Release/GPXPointViewer.app/Contents/MacOS/GPXPointViewer"
            exe.parent.mkdir(parents=True)
            exe.write_bytes(b"OFFLINE FIXTURE OUTPUT")
            return {"exit_code": 0, "child_exit_code": 0, "stop_reason": None,
                    "cleanup_complete": True, "cleanup": [], "stdout": b"", "stderr": b""}
        real_archive = archive.archive_bundle
        def fake_archive(*args, **kwargs):
            return real_archive(*args, **kwargs, project=self.project)
        args = ["build_release.py", "--output-root", str(self.root / "builds"), "--arch", "arm64", "--no-sign"]
        with patch.object(builder, "PROJECT", self.project), patch.object(builder, "source_inputs", lambda: archive.source_inputs(self.project)), patch.object(builder, "archive_bundle", fake_archive), patch.object(builder, "run_owned", fake_build), patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(builder.main(), 0)
        self.assertEqual(len(build_calls), 1)
        self.assertIn("ARCHS=arm64", build_calls[0])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", build_calls[0])
        manifest = next((self.root / "builds").rglob("build-manifest.json"))
        self.assertEqual(json.loads(manifest.read_text())["build"]["exit_code"], 0)

        def changed_build(command, **kwargs):
            result = fake_build(command, **kwargs)
            (self.project / "GPXPointViewer/input.txt").write_text("changed during fake build")
            return result
        changed_root = self.root / "changed-builds"
        args[2] = str(changed_root)
        with patch.object(builder, "PROJECT", self.project), patch.object(builder, "source_inputs", lambda: archive.source_inputs(self.project)), patch.object(builder, "run_owned", changed_build), patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(builder.main(), 2)
        self.assertEqual(list(changed_root.rglob("build-manifest.json")), [])

    def run_mock_suite(self, *, startup_error=False, failures=False, cleanup_uncertain=False):
        folder = self.root / ("startup" if startup_error else "suite")
        folder.mkdir()
        calls = []
        def source():
            if startup_error: raise SystemExit("FIXTURE explicit build missing")
            return str(self.app)
        fake_ui = types.SimpleNamespace(app_source=source, build_provenance=lambda _: {"fixture": True},
                                        IO=str(folder / "io"), state=lambda: {"points": 0})
        def run(command, **kwargs):
            calls.append(command)
            script = command[-1]
            if script == "run_drift_tests.py": output, code = "DIAGNOSTIC ONLY\n", 0
            elif failures and script == "run_fill_tests.py": output, code = "FAILS: ['fixture failure']\n", 0
            elif failures and script == "run_region_tests.py": output, code = "FAILS: none\n", 7
            elif failures and script == "run_profile_tests.py": output, code = "missing summary\n", 0
            else: output, code = "FAILS: none\n", 0
            return subprocess.CompletedProcess(command, code, output)
        def owned(command, **kwargs):
            script = command[-1]
            if failures and script == "run_nature_tests.py":
                calls.append(command)
                return {"exit_code": 124, "child_exit_code": -9, "stop_reason": "timeout",
                        "stdout": "partial fixture\n", "stderr": "", "cleanup_complete": True,
                        "cleanup": [{"operation": "fixture-cleanup"}]}
            completed = run(command, **kwargs)
            return {"exit_code": completed.returncode, "child_exit_code": completed.returncode,
                    "stop_reason": None, "stdout": completed.stdout, "stderr": "",
                    "cleanup_complete": not cleanup_uncertain, "cleanup": []}
        fake_ui._archive = types.SimpleNamespace(run_owned=owned)
        argv = ["-", str(folder / "suite.log")]
        output = io.StringIO()
        with contextlib.chdir(folder), patch.dict(sys.modules, {"ui": fake_ui}), patch.object(subprocess, "run", run), patch.object(sys, "argv", argv), patch("time.sleep"), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(SystemExit) as stopped:
                exec(compile(SUITE_PY, str(PROJECT / "Tests/ui/run_suite.sh"), "exec"), {"__name__": "__main__"})
        result = json.loads((folder / "suite.json").read_text())
        keep_fixture("suite-" + result.get("stop_reason", result["status"]),
                     {"result": result, "exit_code": stopped.exception.code, "mocked_calls": calls, "stdout_stderr": output.getvalue()})
        return result, stopped.exception.code, calls

    def test_suite_records_real_exit_fail_summaries_timeout_and_diagnostic(self):
        result, code, calls = self.run_mock_suite(failures=True)
        self.assertEqual(code, 1)
        self.assertEqual(len(result["scripts"]), 12)
        by_script = {entry["script"]: entry for entry in result["scripts"]}
        self.assertEqual(by_script["run_fill_tests.py"]["status"], "failed")
        self.assertEqual(by_script["run_fill_tests.py"]["exit_code"], 0)
        self.assertEqual(by_script["run_region_tests.py"]["exit_code"], 7)
        self.assertEqual(by_script["run_profile_tests.py"]["status"], "missing-result")
        self.assertEqual(by_script["run_nature_tests.py"]["exit_code"], 124)
        self.assertEqual(by_script["run_drift_tests.py"]["status"], "diagnostic")
        self.assertIn("run_regions_stats_tests.py", result["separate_scripts"])

    def test_new_owned_timeout_records_signals_and_exact_child_exit(self):
        class Child:
            pid = 12345
            returncode = None
            stdout = stderr = None
            calls = 0
            def communicate(self, timeout):
                self.calls += 1
                if self.calls == 1: raise subprocess.TimeoutExpired(["OFFLINE"], timeout, output=b"partial")
                self.returncode = -9
                return b"partial complete", b"fixture stderr"
        child = Child()
        signals = []
        def killpg(pid, sig):
            signals.append((pid, sig))
            if sig == 0: raise ProcessLookupError(3, "fixture group gone")
        with patch.object(archive.subprocess, "Popen", return_value=child) as popen, patch.object(archive.os, "getpgid", return_value=child.pid), patch.object(archive.os, "getsid", return_value=child.pid), patch.object(archive.os, "killpg", killpg), patch.object(archive.time, "sleep"):
            result = archive.run_owned(["OFFLINE"], timeout=0.01, text=True)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertEqual(signals, [(12345, signal.SIGTERM), (12345, signal.SIGKILL), (12345, 0)])
        self.assertEqual((result["exit_code"], result["child_exit_code"], result["stop_reason"]), (124, -9, "timeout"))
        self.assertTrue(result["cleanup_complete"])
        self.assertEqual(result["stdout"], "partial complete")
        keep_fixture("owned-timeout", result)

    def test_new_owned_interruption_and_denied_cleanup_remain_unconfirmed(self):
        class Child:
            pid = 12346
            returncode = None
            stdout = stderr = None
            calls = 0
            def communicate(self, timeout):
                self.calls += 1
                if self.calls == 1: raise KeyboardInterrupt()
                self.returncode = -9
                return b"", b""
            def kill(self): pass
        child = Child()
        denied = PermissionError(1, "fixture permission denied")
        with patch.object(archive.subprocess, "Popen", return_value=child), patch.object(archive.os, "getpgid", side_effect=denied), patch.object(archive.os, "getsid", side_effect=denied), patch.object(archive.os, "killpg", side_effect=denied):
            result = archive.run_owned(["OFFLINE"], timeout=0.01)
        self.assertEqual((result["exit_code"], result["stop_reason"]), (130, "interrupted"))
        self.assertFalse(result["cleanup_complete"])
        self.assertTrue(any(item.get("operation") == "group-status" and item.get("errno") == 1 for item in result["cleanup"]))
        keep_fixture("owned-interrupted-denied", result)

    def test_new_builder_timeout_persists_cleanup_and_refuses_manifest(self):
        timeout_record = {"exit_code": 124, "child_exit_code": -9, "stop_reason": "timeout",
                          "cleanup_complete": False, "cleanup": [{"operation": "fixture-denied", "errno": 1}],
                          "owner": {"pid": 12345}, "stdout": b"", "stderr": b"partial fixture"}
        args = ["build_release.py", "--output-root", str(self.root / "timeout-builds")]
        with patch.object(builder, "PROJECT", self.project), patch.object(builder, "source_inputs", lambda: archive.source_inputs(self.project)), patch.object(builder, "run_owned", return_value=timeout_record), patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(builder.main(), 124)
        command = next((self.root / "timeout-builds").rglob("build-command.json"))
        record = json.loads(command.read_text())
        self.assertEqual(record["execution"]["child_exit_code"], -9)
        self.assertFalse(record["execution"]["cleanup_complete"])
        self.assertEqual(list((self.root / "timeout-builds").rglob("build-manifest.json")), [])
        keep_fixture("builder-timeout", {"record": record, "build_log": (command.parent / "build.log").read_text(), "manifest_count": 0})

    def test_new_suite_stops_after_timeout_or_unconfirmed_cleanup(self):
        result, code, calls = self.run_mock_suite(failures=True)
        self.assertEqual((code, result["stop_reason"]), (1, "timeout"))
        scripts = [entry["script"] for entry in result["scripts"]]
        self.assertEqual(scripts[-1], "run_nature_tests.py")
        self.assertNotIn("run_route_notes_tests.py", scripts)
        self.assertEqual(result["scripts"][-1]["execution"]["child_exit_code"], -9)
        # Use another temporary fixture folder for the independent cleanup case.
        (self.root / "suite").rename(self.root / "suite-timeout")
        result, code, calls = self.run_mock_suite(cleanup_uncertain=True)
        self.assertEqual((code, result["stop_reason"]), (1, "cleanup-unconfirmed"))
        self.assertEqual(len(result["scripts"]), 1)

    def test_suite_startup_failure_has_record_and_does_not_stop_or_copy_app(self):
        result, code, calls = self.run_mock_suite(startup_error=True)
        self.assertEqual((code, result["status"], calls), (1, "failed", []))
        self.assertIn("FIXTURE explicit build missing", result["error"])

    def test_suite_all_pass_is_distinct_from_diagnostic(self):
        result, code, _ = self.run_mock_suite()
        self.assertEqual((code, result["status"]), (0, "passed"))
        self.assertEqual(sum(item["status"] == "passed" for item in result["scripts"]), 24)
        self.assertEqual(sum(item["status"] == "diagnostic" for item in result["scripts"]), 1)

    def test_shell_unique_dated_log_directory_and_syntax(self):
        subprocess.run(["/bin/zsh", "-n", str(PROJECT / "Tests/ui/run_suite.sh")], check=True)
        prefix = SUITE.split("python3 -u -", 1)[0].replace('cd "$(dirname "$0")" || exit 1', 'cd ' + str(self.root) + ' || exit 1')
        outputs = [subprocess.run(["/bin/zsh", "-c", prefix], check=True, capture_output=True, text=True).stdout.strip() for _ in range(2)]
        self.assertNotEqual(outputs[0], outputs[1])
        self.assertTrue(all("suite_" in output and output.endswith("/suite.log") for output in outputs))


if __name__ == "__main__":
    unittest.main(verbosity=2)
