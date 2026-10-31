#!/usr/bin/env python3
"""Offline fixtures: no Xcode, real codesign, apps, preferences or /Applications."""
import json
import io
from pathlib import Path
import plistlib
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Tools"))
import archive_build as archive
import install_release as install
import build_release as build
from contextlib import redirect_stdout


class ReleaseInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project"
        for name in archive.INPUT_ROOTS:
            (self.project / name).mkdir(parents=True)
        self.entitlements = {}
        self.app = self.root / "built/GPXPointViewer.app"
        for relative, identifier, executable, entitlement_file in archive.SIGNING_TARGETS:
            expected = {"com.apple.security.app-sandbox": True}
            if relative == ".":
                expected.update({"com.apple.security.network.client": True,
                                 "com.apple.security.files.user-selected.read-write": True})
            self.entitlements[executable] = expected
            (self.project / entitlement_file).write_bytes(plistlib.dumps(expected))
            target = self.app / relative
            (target / "Contents/MacOS").mkdir(parents=True)
            (target / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": executable}))
            (target / "Contents/MacOS" / executable).write_bytes((executable + " fixture").encode())
        self.target = self.root / "Applications/GPXPointViewer.app"
        self.target.parent.mkdir()
        self.addCleanup(patch.stopall)
        patch.object(install, "TARGET", self.target).start()
        self.real_run = archive.run_owned
        self.codesign = patch.object(archive, "run_owned", side_effect=self.fake_codesign).start()

    def fake_codesign(self, command, **kwargs):
        if command[0] != "/usr/bin/codesign":
            return self.real_run(command, **kwargs)
        self.assertEqual(command[0], "/usr/bin/codesign")
        self.assertNotIn("--deep", command)
        if "--remove-signature" in command:
            proof = Path(command[-1])
            proof.write_bytes(proof.read_bytes().split(b"\nsigned:", 1)[0])
            return {"exit_code": 0, "cleanup_complete": True, "stdout": "", "stderr": "fixture signature removed"}
        name = "GPXPointViewer" if command[-1].endswith(".app") else Path(command[-1]).stem
        target = Path(command[-1])
        identifier = plistlib.loads((target / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        if "--force" in command:
            expected_file = next(entitlements for _, _, executable, entitlements in archive.SIGNING_TARGETS if executable == name)
            self.assertEqual(Path(command[command.index("--entitlements") + 1]), self.project / expected_file)
            binary = target / "Contents/MacOS" / name
            binary.write_bytes(binary.read_bytes() + b"\nsigned:" + identifier.encode())
            return {"exit_code": 0, "cleanup_complete": True, "stdout": "", "stderr": "fixture signed"}
        if "--entitlements" in command:
            stdout = plistlib.dumps(self.entitlements[name]).decode()
            stderr = ""
        else:
            stdout = ""
            stderr = "Identifier=" + identifier + "\nCDHash=" + archive.sha256(target / "Contents/MacOS" / name) + "\nSignature=adhoc\nTeamIdentifier=not set\n"
        return {"exit_code": 0, "cleanup_complete": True, "stdout": stdout, "stderr": stderr}

    def make_archive(self, policy="sandboxed-local"):
        return archive.archive_bundle(self.app, self.root / "archive", project=self.project,
                                      source=archive.source_inputs(self.project), build={"exit_code": 0},
                                      signing_policy=policy)

    def test_signed_three_target_archive_and_validation(self):
        app, manifest = self.make_archive()
        self.assertTrue(manifest["signing"]["installable"])
        self.assertEqual(len(manifest["signing"]["bundles"]), 3)
        self.assertTrue((app.parent / "signing-checks.json").is_file())
        archive.validate_bundle(app, project=self.project, for_install=True)

    def test_unsigned_and_legacy_manifests_refused_only_for_install(self):
        app, manifest = self.make_archive("development-unsigned")
        archive.validate_bundle(app, project=self.project)
        with self.assertRaisesRegex(ValueError, "not installable"):
            archive.validate_bundle(app, project=self.project, for_install=True)
        manifest.pop("signing")
        archive.write_json(app.parent / "build-manifest.json", manifest)
        archive.validate_bundle(app, project=self.project)
        with self.assertRaisesRegex(ValueError, "not installable"):
            archive.validate_bundle(app, project=self.project, for_install=True)
        self.assertFalse(any(call.args[0][0] == "/usr/bin/codesign" for call in self.codesign.call_args_list))

    def test_missing_main_sandbox_is_rejected(self):
        self.entitlements["GPXPointViewer"].pop("com.apple.security.app-sandbox")
        with self.assertRaisesRegex(ValueError, "security entitlements differ"):
            self.make_archive()
        evidence = json.loads((self.root / "archive/signing-checks.json").read_text())
        self.assertEqual(len(evidence["checks"]), 3)

    def test_main_entitlements_cannot_be_reused_for_extension(self):
        self.entitlements["GPXQuickLook"] = self.entitlements["GPXPointViewer"].copy()
        with self.assertRaisesRegex(ValueError, "security entitlements differ"):
            self.make_archive()

    def test_strict_failure_is_recorded(self):
        self.codesign.side_effect = lambda command, **kwargs: ({"exit_code": 1, "cleanup_complete": True,
                "stdout": "", "stderr": "invalid resource signature"} if command[0] == "/usr/bin/codesign"
                else self.real_run(command, **kwargs))
        with self.assertRaisesRegex(ValueError, "Signature check failed"):
            self.make_archive()
        evidence = json.loads((self.root / "archive/signing-checks.json").read_text())
        self.assertEqual(evidence["checks"][0]["exit_code"], 1)
        self.assertFalse((self.root / "archive/build-manifest.json").exists())

    def test_bundle_identifier_and_unexpected_extension_rejected(self):
        info = self.app / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "wrong.id", "CFBundleExecutable": "GPXPointViewer"}))
        with self.assertRaisesRegex(ValueError, "bundle identity"):
            archive.verify_sandbox_signatures(self.app, project=self.project)
        (self.app / "Contents/PlugIns/Other.appex").mkdir()
        with self.assertRaisesRegex(ValueError, "unexpected app extensions"):
            archive.verify_sandbox_signatures(self.app, project=self.project)

    def test_changed_source_and_binary_refuse_install(self):
        app, _ = self.make_archive()
        product = app / "Contents/MacOS/GPXPointViewer"
        original = product.read_bytes()
        product.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "contents differ"):
            archive.validate_bundle(app, project=self.project, for_install=True)
        product.write_bytes(original)
        (self.project / "GPXPointViewer/New.swift").write_text("changed source")
        with self.assertRaisesRegex(ValueError, "inputs differ"):
            archive.validate_bundle(app, project=self.project, for_install=True)

    @unittest.skipUnless(sys.platform == "darwin", "FinderInfo fixture is macOS-specific")
    def test_only_new_archive_metadata_is_cleaned(self):
        name = "com.apple.FinderInfo"
        for path in (self.app, self.app / "Contents/MacOS/GPXPointViewer"):
            subprocess.run(["/usr/bin/xattr", "-w", "-x", name, "01" + "00" * 31, str(path)], check=True)
        app, manifest = self.make_archive()
        self.assertIn(name, subprocess.check_output(["/usr/bin/xattr", str(self.app)], text=True))
        self.assertNotIn(name, subprocess.check_output(["/usr/bin/xattr", str(app)], text=True))
        self.assertEqual(len(manifest["signing"]["removed_archive_metadata"]), 1)
        self.assertIn("Contents/MacOS/GPXPointViewer", manifest["signing"]["removed_archive_metadata"][0]["before_names"])

    def test_running_application_blocks_install(self):
        app, _ = self.make_archive()
        with patch.object(install, "run_owned", return_value={"exit_code": 0, "cleanup_complete": True,
                          "stdout": "23 /Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer\n", "stderr": ""}):
            with self.assertRaisesRegex(ValueError, "quit GPXPointViewer normally"):
                install.install_bundle(app, authorized_target=self.target, receipt_dir=self.root / "receipt", project=self.project)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.iterdir()), [])

    def test_install_preserves_backup_and_validates_destination(self):
        app, _ = self.make_archive()
        self.target.mkdir()
        (self.target / "old-data").write_bytes(b"old app fixture")
        before = archive.tree_manifest(self.target)
        with patch.object(install, "require_stopped"):
            result = install.install_bundle(app, authorized_target=self.target, receipt_dir=self.root / "receipt", project=self.project)
        self.assertEqual(result["status"], "installed")
        self.assertEqual(archive.tree_manifest(Path(result["backup"])), before)
        self.assertEqual(archive.tree_manifest(self.target), archive.tree_manifest(app))
        self.assertEqual(result["installed_provenance"]["executable_sha256"], archive.sha256(self.target / "Contents/MacOS/GPXPointViewer"))

    def test_post_install_failure_rolls_back_without_deleting_failed_app(self):
        app, _ = self.make_archive()
        self.target.mkdir()
        (self.target / "old-data").write_bytes(b"old app fixture")
        before = archive.tree_manifest(self.target)

        def validate(path, *args, **kwargs):
            if Path(path) == self.target:
                raise ValueError("injected post-install validation failure")
            return archive.validate_bundle(path, *args, **kwargs)

        with patch.object(install, "require_stopped"), patch.object(install, "validate_bundle", side_effect=validate):
            with self.assertRaisesRegex(ValueError, "injected"):
                install.install_bundle(app, authorized_target=self.target, receipt_dir=self.root / "receipt", project=self.project)
        self.assertEqual(archive.tree_manifest(self.target), before)
        result = json.loads((self.root / "receipt/install-result.json").read_text())
        self.assertTrue(result["rollback_verified"])
        self.assertTrue(Path(result["failed_new_bundle"]).is_dir())

    def test_explicit_wrong_target_refused_before_mutation(self):
        with self.assertRaisesRegex(ValueError, "Authorization must explicitly name"):
            install.install_bundle(self.app, authorized_target=self.root / "wrong.app",
                                   receipt_dir=self.root / "receipt", project=self.project)
        self.assertFalse((self.root / "receipt").exists())

    def test_isolated_copy_preserves_parent_and_signs_inside_out(self):
        app, _ = self.make_archive()
        parent_files = archive.tree_manifest(app)
        parent_manifest = (app.parent / "build-manifest.json").read_bytes()
        bundle_id = archive.PRODUCTION_ID + ".test.fixture-unique-a1"
        copy, manifest = archive.prepare_isolated_test_copy(app, self.root / "test-copy",
                                                          test_bundle_id=bundle_id, project=self.project)
        self.assertEqual(archive.tree_manifest(app), parent_files)
        self.assertEqual((app.parent / "build-manifest.json").read_bytes(), parent_manifest)
        self.assertEqual(manifest["source_association"], archive.TEST_ASSOCIATION)
        self.assertFalse(manifest["signing"]["installable"])
        provenance = archive.validate_bundle(copy, project=self.project)
        self.assertEqual(provenance["test_bundle_id"], bundle_id)
        sign_commands = [call.args[0] for call in self.codesign.call_args_list if "--force" in call.args[0]]
        self.assertEqual([Path(command[-1]).name for command in sign_commands],
                         ["GPXQuickLook.appex", "GPXThumbnail.appex", "GPXPointViewer.app"])
        for relative, identifier, _, _ in archive.test_signing_targets(bundle_id):
            info = plistlib.loads((copy / relative / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], identifier)
            self.assertNotEqual(identifier, archive.PRODUCTION_ID)
        with self.assertRaisesRegex(ValueError, "cannot be installed"):
            archive.validate_bundle(copy, project=self.project, for_install=True)

    def test_isolated_copy_rejects_production_id_and_unsigned_parent(self):
        for invalid in (archive.PRODUCTION_ID, "other.test.fixture1", archive.PRODUCTION_ID + ".test.short"):
            with self.assertRaisesRegex(ValueError, "unique isolated bundle ID"):
                archive.prepare_isolated_test_copy(self.app, self.root / "test-copy", test_bundle_id=invalid, project=self.project)
            self.assertFalse((self.root / "test-copy").exists())
        app, _ = self.make_archive("development-unsigned")
        with self.assertRaisesRegex(ValueError, "not installable"):
            archive.prepare_isolated_test_copy(app, self.root / "test-copy",
                test_bundle_id=archive.PRODUCTION_ID + ".test.fixture-unique-a1", project=self.project)
        self.assertFalse((self.root / "test-copy").exists())

    def test_isolated_copy_rejects_unrelated_changes_even_with_updated_file_hashes(self):
        app, _ = self.make_archive()
        copy, manifest = archive.prepare_isolated_test_copy(app, self.root / "test-copy",
            test_bundle_id=archive.PRODUCTION_ID + ".test.fixture-unique-a1", project=self.project)
        (copy / "Contents/UnexpectedResource").write_text("unauthorized derivative change")
        manifest["bundle_files"] = archive.tree_manifest(copy)
        manifest["test_copy"]["bundle_changes"] = archive.changed_bundle_files(
            json.loads((copy.parent / "parent-build-manifest.json").read_text())["bundle_files"], manifest["bundle_files"])
        archive.write_json(copy.parent / "build-manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "changes exceed"):
            archive.validate_bundle(copy, project=self.project)

    def test_isolated_copy_rejects_parent_evidence_tampering(self):
        app, _ = self.make_archive()
        copy, manifest = archive.prepare_isolated_test_copy(app, self.root / "test-copy",
            test_bundle_id=archive.PRODUCTION_ID + ".test.fixture-unique-a1", project=self.project)
        (copy.parent / "parent-build-manifest.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "parent manifest changed"):
            archive.validate_bundle(copy, project=self.project)

    def test_review_f1_signature_only_changes_have_equal_complete_payload(self):
        app, _ = self.make_archive()
        copy, manifest = archive.prepare_isolated_test_copy(app, self.root / "test-copy",
            test_bundle_id=archive.PRODUCTION_ID + ".test.review-f1-unique", project=self.project)
        proof = manifest["test_copy"]["executable_payload_proof"]
        self.assertEqual(len(proof["executables"]), 3)
        for value in proof["executables"].values():
            self.assertNotEqual(value["parent_sha256"], value["derived_sha256"])
            self.assertEqual(value["parent_payload_sha256"], value["derived_payload_sha256"])
            self.assertTrue(value["payloads_equal"])
        self.assertEqual(archive.validate_bundle(copy, project=self.project)["test_bundle_id"],
                         manifest["test_copy"]["bundle_id"])

    def test_review_f1_resigned_code_change_rejected_with_self_consistent_manifest(self):
        app, _ = self.make_archive()
        copy, manifest = archive.prepare_isolated_test_copy(app, self.root / "test-copy",
            test_bundle_id=archive.PRODUCTION_ID + ".test.review-f1-unique", project=self.project)
        binary = copy / "Contents/MacOS/GPXPointViewer"
        binary.write_bytes(binary.read_bytes().replace(b"fixture", b"fiXture", 1))
        sign = json.loads((copy.parent / "test-signing-commands.json").read_text())[-1]["argv"]
        self.assertEqual(archive.run_owned(sign, timeout=30, text=True)["exit_code"], 0)
        manifest["bundle_files"] = archive.tree_manifest(copy)
        manifest["executable_sha256"] = archive.sha256(binary)
        parent = json.loads((copy.parent / "parent-build-manifest.json").read_text())
        manifest["test_copy"]["bundle_changes"] = archive.changed_bundle_files(parent["bundle_files"], manifest["bundle_files"])
        actual = archive.verify_sandbox_signatures(copy, project=self.project,
                                                  test_bundle_id=manifest["test_copy"]["bundle_id"])
        manifest["signing"].update(actual)
        archive.write_json(copy.parent / "build-manifest.json", manifest)
        with self.assertRaisesRegex(ValueError, "changes non-signature payload"):
            archive.validate_bundle(copy, project=self.project)

    def test_review_f1_parent_executable_snapshot_is_hash_bound(self):
        app, _ = self.make_archive()
        copy, _ = archive.prepare_isolated_test_copy(app, self.root / "test-copy",
            test_bundle_id=archive.PRODUCTION_ID + ".test.review-f1-unique", project=self.project)
        (copy.parent / "parent-executables/GPXPointViewer").write_bytes(b"substituted parent payload")
        with self.assertRaisesRegex(ValueError, "Parent executable snapshot differs"):
            archive.validate_bundle(copy, project=self.project)

    def test_review_f2_kernel_swap_preserves_both_complete_directories(self):
        self.target.mkdir()
        (self.target / "marker").write_text("old")
        staged = self.root / "stage"
        staged.mkdir()
        (staged / "marker").write_text("new")
        result = install.atomic_swap(self.target, staged)
        self.assertEqual(result["flags"], ["RENAME_SWAP"])
        self.assertEqual((self.target / "marker").read_text(), "new")
        self.assertEqual((staged / "marker").read_text(), "old")

    def test_review_f2_failure_just_after_swap_detects_commit_and_rolls_back_atomically(self):
        app, _ = self.make_archive()
        self.target.mkdir()
        (self.target / "old-data").write_bytes(b"previous complete fixture")
        previous = archive.tree_manifest(self.target)
        actual_swap = install.atomic_swap
        calls = []

        def fail_after_first_swap(first, second):
            self.assertTrue(self.target.is_dir())
            result = actual_swap(first, second)
            self.assertTrue(self.target.is_dir())
            calls.append(result)
            if len(calls) == 1:
                raise RuntimeError("injected interruption after kernel exchange")
            return result

        with patch.object(install, "require_stopped"), patch.object(install, "atomic_swap", side_effect=fail_after_first_swap):
            with self.assertRaisesRegex(RuntimeError, "after kernel exchange"):
                install.install_bundle(app, authorized_target=self.target, receipt_dir=self.root / "receipt", project=self.project)
        self.assertEqual(archive.tree_manifest(self.target), previous)
        self.assertEqual(len(calls), 2)
        receipt = json.loads((self.root / "receipt/install-result.json").read_text())
        self.assertTrue(receipt["rollback_verified"])
        self.assertTrue(Path(receipt["failed_new_bundle"]).is_dir())

    def test_review_f2_process_exit_after_kernel_swap_keeps_target_and_backup(self):
        self.target.mkdir()
        (self.target / "marker").write_text("old")
        staged = self.root / "stage"
        staged.mkdir()
        (staged / "marker").write_text("new")
        code = "import sys,os;sys.path.insert(0,sys.argv[1]);import install_release;install_release.atomic_swap(sys.argv[2],sys.argv[3]);os._exit(73)"
        result = subprocess.run([sys.executable, "-c", code, str(Path(install.__file__).parent), str(self.target), str(staged)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual((self.target / "marker").read_text(), "new")
        self.assertEqual((staged / "marker").read_text(), "old")

    def test_review_f2_unsupported_swap_refuses_without_removing_target(self):
        app, _ = self.make_archive()
        self.target.mkdir()
        (self.target / "old-data").write_bytes(b"previous complete fixture")
        previous = archive.tree_manifest(self.target)
        with patch.object(install, "require_stopped"), patch.object(install, "atomic_swap", side_effect=OSError("swap unsupported")):
            with self.assertRaisesRegex(OSError, "swap unsupported"):
                install.install_bundle(app, authorized_target=self.target, receipt_dir=self.root / "receipt", project=self.project)
        self.assertEqual(archive.tree_manifest(self.target), previous)
        receipt = json.loads((self.root / "receipt/install-result.json").read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertIsNone(receipt["backup"])
        self.assertEqual(receipt["commit_prepared"]["operation"], "RENAME_SWAP")

    def test_review_f3_receipts_inside_source_or_target_refused_before_any_write(self):
        app, _ = self.make_archive()
        self.target.mkdir()
        (self.target / "old-data").write_bytes(b"untouched old fixture")
        original_source, original_target = archive.tree_manifest(app), archive.tree_manifest(self.target)
        aliases = self.root / "source-alias"
        aliases.symlink_to(app, target_is_directory=True)
        for receipt in (app / "Receipts/new", self.target / "Receipts/new", aliases / "Receipts/new",
                        app.parent, self.target.parent):
            with self.subTest(receipt=str(receipt)), self.assertRaisesRegex(ValueError, "Receipt directory overlaps"):
                install.install_bundle(app, authorized_target=self.target, receipt_dir=receipt, project=self.project)
            self.assertEqual(archive.tree_manifest(app), original_source)
            self.assertEqual(archive.tree_manifest(self.target), original_target)
        self.assertFalse((app / "Receipts").exists())
        self.assertFalse((self.target / "Receipts").exists())
        self.assertFalse((self.target.parent / ".GPXPointViewer.install.lock").exists())

    def test_review_f3_staging_backup_and_other_bundle_receipt_paths_refused(self):
        stage_root = self.root / "Applications/GPXPointViewer-backup-fixture"
        stage = stage_root / "GPXPointViewer.app"
        for receipt in (stage / "Receipts/new", stage_root / "receipts", stage_root.parent,
                        self.root / "Other.app/Receipts/new"):
            existed = receipt.exists()
            with self.subTest(receipt=str(receipt)), self.assertRaisesRegex(ValueError, "Receipt directory"):
                install.require_external_receipt(receipt, self.app, self.target, stage_root, stage)
            self.assertEqual(receipt.exists(), existed)

    def test_staging_local_derived_data_argv_and_record(self):
        persistent = self.root / "persistent-builds"
        actual_mkdtemp = tempfile.mkdtemp
        requested = []
        build_commands = []
        archived_sources = []

        def temporary_staging(*, prefix, dir):
            requested.append({"prefix": prefix, "dir": dir})
            return actual_mkdtemp(prefix=prefix, dir=self.root)

        def fake_build(command, **kwargs):
            build_commands.append(command)
            derived = Path(command[command.index("-derivedDataPath") + 1])
            (derived / "Build/Products/Release/GPXPointViewer.app").mkdir(parents=True)
            return {"exit_code": 0, "cleanup_complete": True, "stdout": b"", "stderr": b""}

        def fake_archive(app, destination, **kwargs):
            archived_sources.append(Path(app))
            return destination / "GPXPointViewer.app", {"executable_sha256": "fixture", "signing": {
                "policy": kwargs["signing_policy"], "installable": True}}

        with patch.object(sys, "argv", ["build_release.py", "--output-root", str(persistent), "--arch", "arm64"]), \
                patch.object(build.tempfile, "mkdtemp", side_effect=temporary_staging), \
                patch.object(build, "source_inputs", return_value={"sha256": "fixture-inputs"}), \
                patch.object(build, "run_owned", side_effect=fake_build), \
                patch.object(build, "archive_bundle", side_effect=fake_archive), \
                patch.object(build, "preserve_archive_zip", return_value={"durable_zip": "fixture.zip", "durable_manifest": "fixture.json"}), \
                redirect_stdout(io.StringIO()):
            self.assertEqual(build.main(), 0)
        run = next(persistent.iterdir())
        record = json.loads((run / "build-command.json").read_text())
        derived = Path(record["derived_data_path"])
        self.assertEqual(requested[0]["dir"], "/private/tmp")
        self.assertTrue(requested[0]["prefix"].startswith("GPXPointViewer-" + run.name + "-"))
        self.assertNotIn(run, derived.parents)
        self.assertEqual(build_commands[0][build_commands[0].index("-derivedDataPath") + 1], str(derived))
        self.assertEqual(archived_sources, [derived / "Build/Products/Release/GPXPointViewer.app"])
        self.assertTrue(derived.exists(), "Intermediate output must not be automatically cleaned")
        self.assertEqual(record["local_staging_path"], str(derived.parent))
        self.assertEqual(record["signing_policy"], "sandboxed-local")
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", record["argv"])
        self.assertIn("without-automatic-cleanup", record["intermediates_retention"])

    def test_release_disables_injected_base_entitlements_in_actual_command(self):
        persistent = self.root / "persistent-builds"
        actual_mkdtemp = tempfile.mkdtemp
        with patch.object(sys, "argv", ["build_release.py", "--output-root", str(persistent)]), \
                patch.object(build.tempfile, "mkdtemp", side_effect=lambda **kwargs: actual_mkdtemp(prefix=kwargs["prefix"], dir=self.root)), \
                patch.object(build, "source_inputs", return_value={"sha256": "fixture-inputs"}), \
                patch.object(build, "run_owned", return_value={"exit_code": 65, "cleanup_complete": True, "stdout": b"", "stderr": b""}), \
                patch.object(build, "archive_bundle") as archive_mock, \
                patch.object(sys, "stderr", io.StringIO()), redirect_stdout(io.StringIO()):
            build.main()
        record = json.loads((next(persistent.iterdir()) / "build-command.json").read_text())
        self.assertEqual((record["argv"].count("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"),
                          record["code_sign_inject_base_entitlements"], archive_mock.called), (1, False, False))

    def test_stable_artifact_zip_preserves_bundle_bytes_and_separates_runnable_path(self):
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "binary-link").symlink_to("../MacOS/GPXPointViewer")
        app, manifest = archive.archive_bundle(self.app, self.root / "local/archive", project=self.project,
            source=archive.source_inputs(self.project), build={"exit_code": 0}, signing_policy="sandboxed-local")
        durable = self.root / "project-record/archive"
        receipt = archive.preserve_archive_zip(app, durable, project=self.project)
        self.assertFalse((durable / "GPXPointViewer.app").exists())
        self.assertEqual((durable / "build-manifest.json").read_bytes(), (app.parent / "build-manifest.json").read_bytes())
        self.assertEqual(receipt["zip_sha256"], archive.sha256(receipt["durable_zip"]))
        self.assertEqual(archive.tree_manifest(app), manifest["bundle_files"])
        self.assertTrue(any(item["name"].endswith("/binary-link") for item in receipt["members"]))
        command = json.loads((durable / "zip-command.json").read_text())
        self.assertEqual(command["exit_code"], 0)
        self.assertIn("--keepParent", command["argv"])
        self.assertEqual(receipt["app"], str(app))

    def test_stable_build_prints_local_app_and_project_zip(self):
        persistent = self.root / "persistent-builds"
        actual_mkdtemp = tempfile.mkdtemp
        captured = io.StringIO()

        def fake_archive(app, destination, **kwargs):
            return destination / "GPXPointViewer.app", {"executable_sha256": "fixture", "signing": {
                "policy": kwargs["signing_policy"], "installable": True}}

        def fake_zip(app, destination):
            return {"durable_zip": str(destination / "GPXPointViewer.app.zip"),
                    "durable_manifest": str(destination / "build-manifest.json")}

        with patch.object(sys, "argv", ["build_release.py", "--output-root", str(persistent)]), \
                patch.object(build.tempfile, "mkdtemp", side_effect=lambda **kwargs: actual_mkdtemp(prefix=kwargs["prefix"], dir=self.root)), \
                patch.object(build, "source_inputs", return_value={"sha256": "fixture-inputs"}), \
                patch.object(build, "run_owned", return_value={"exit_code": 0, "cleanup_complete": True, "stdout": b"", "stderr": b""}), \
                patch.object(build, "archive_bundle", side_effect=fake_archive), \
                patch.object(build, "preserve_archive_zip", side_effect=fake_zip), redirect_stdout(captured):
            self.assertEqual(build.main(), 0)
        printed = json.loads(captured.getvalue()[captured.getvalue().index('{'):])
        run = next(persistent.iterdir())
        record = json.loads((run / "build-command.json").read_text())
        self.assertEqual(Path(printed["app"]).parent, Path(record["local_staging_path"]) / "archive")
        self.assertEqual(printed["manifest"], str(Path(printed["app"]).parent / "build-manifest.json"))
        self.assertEqual(Path(printed["durable_zip"]).parent, run / "archive")
        self.assertEqual(Path(printed["durable_manifest"]).parent, run / "archive")
        self.assertNotIn(run, Path(printed["app"]).parents)


if __name__ == "__main__":
    unittest.main()
