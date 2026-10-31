#!/usr/bin/env python3
"""Archive a bundle with hashes; source attribution is issued by build_release.py.

Historical/manual archives deliberately do not claim to match today's sources.
No command in this module installs or launches an app.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import signal
import subprocess
import tempfile
import time
import uuid
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
INPUT_ROOTS = ("GPXPointViewer", "GPXQuickLook", "GPXThumbnail", "GPXPointViewer.xcodeproj")
SIGNING_TARGETS = (
    (".", "de.wayne.GPXPointViewer", "GPXPointViewer", "GPXPointViewer/GPXPointViewer.entitlements"),
    ("Contents/PlugIns/GPXQuickLook.appex", "de.wayne.GPXPointViewer.GPXQuickLook", "GPXQuickLook", "GPXQuickLook/GPXQuickLook.entitlements"),
    ("Contents/PlugIns/GPXThumbnail.appex", "de.wayne.GPXPointViewer.GPXThumbnail", "GPXThumbnail", "GPXThumbnail/GPXThumbnail.entitlements"),
)
PRODUCTION_ID = SIGNING_TARGETS[0][1]
TEST_ASSOCIATION = "isolated-test-copy-derived-from-verified-build"


def test_signing_targets(bundle_id):
    if not isinstance(bundle_id, str) or not re.fullmatch(re.escape(PRODUCTION_ID) + r"\.test\.[a-z0-9][a-z0-9-]{7,63}", bundle_id):
        raise ValueError("Use a unique isolated bundle ID under " + PRODUCTION_ID + ".test.<unique-slug>")
    return tuple((relative, bundle_id + identifier[len(PRODUCTION_ID):], executable, entitlements)
                 for relative, identifier, executable, entitlements in SIGNING_TARGETS)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_manifest(root, exclude=()):
    root = Path(root)
    files = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if any(part in exclude for part in relative.parts):
            continue
        if path.is_symlink():
            files[relative.as_posix()] = {"symlink": str(path.readlink())}
        elif path.is_file():
            files[relative.as_posix()] = {"sha256": sha256(path), "bytes": path.stat().st_size}
    return files


def source_inputs(project=PROJECT):
    files = {}
    for name in INPUT_ROOTS:
        root = Path(project) / name
        if not root.is_dir():
            raise ValueError("Missing build input directory: " + str(root))
        for path, entry in tree_manifest(root, ("xcuserdata", ".DS_Store", "__pycache__")).items():
            files[name + "/" + path] = entry
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {"roots": list(INPUT_ROOTS), "files": files,
            "sha256": hashlib.sha256(encoded).hexdigest()}


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def run_owned(command, *, timeout, cwd=None, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=False):
    """Run one direct child in its own session; bound stop and pipe draining.

    Never signal a reaped/reused PID or any group other than this child's
    independently observed session/group. A detached descendant is not claimed
    as cleaned; callers must stop scheduling work when cleanup is uncertain.
    """
    started = utc_now()
    try:
        child = subprocess.Popen(command, cwd=cwd, stdout=stdout, stderr=stderr,
                                 text=text, start_new_session=True)
    except OSError as error:
        return {"exit_code": 127, "child_exit_code": None, "stop_reason": "spawn-error",
                "stdout": "" if text else b"", "stderr": str(error) if text else str(error).encode(),
                "cleanup_complete": True, "cleanup": [], "started_utc": started, "finished_utc": utc_now()}
    owner = {"pid": child.pid, "pgid": None, "sid": None, "started_utc": started}
    events = []
    try:
        owner.update(pgid=os.getpgid(child.pid), sid=os.getsid(child.pid))
    except OSError as error:
        events.append({"operation": "owner", "error": type(error).__name__, "errno": error.errno})
    stop = None
    output = error_output = None
    try:
        output, error_output = child.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        stop = "timeout" if isinstance(error, subprocess.TimeoutExpired) else "interrupted"
        output = getattr(error, "output", None)
        error_output = getattr(error, "stderr", None)

        def signal_group(sig):
            try:
                # returncode=None means our direct child has not been reaped by
                # Popen. Keep it unreaped until all group signals are sent.
                if (child.returncode is not None or owner["pgid"] != child.pid or owner["sid"] != child.pid
                        or os.getpgid(child.pid) != child.pid or os.getsid(child.pid) != child.pid):
                    events.append({"operation": "signal-group", "signal": sig, "status": "ownership-unconfirmed"})
                    return False
                os.killpg(child.pid, sig)
                events.append({"operation": "signal-group", "signal": sig, "status": "sent"})
                return True
            except OSError as signal_error:
                events.append({"operation": "signal-group", "signal": sig,
                               "error": type(signal_error).__name__, "errno": signal_error.errno})
                return False

        term_sent = signal_group(signal.SIGTERM)
        if term_sent:
            time.sleep(0.2)
        kill_sent = signal_group(signal.SIGKILL)
        if not kill_sent and child.returncode is None:
            # A Popen handle is still our own direct, unreaped child. This does
            # not claim to stop descendants whose group could not be verified.
            try:
                child.kill()
                events.append({"operation": "kill-direct-child", "status": "sent"})
            except OSError as kill_error:
                events.append({"operation": "kill-direct-child", "error": type(kill_error).__name__, "errno": kill_error.errno})
        try:
            output, error_output = child.communicate(timeout=0.5)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as drain_error:
            output = getattr(drain_error, "output", None) or output
            error_output = getattr(drain_error, "stderr", None) or error_output
            events.append({"operation": "drain", "status": "incomplete"})
            for stream in (child.stdout, child.stderr):
                if stream is not None:
                    stream.close()
    group_absent = False
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        group_absent = True
    except OSError as error:
        events.append({"operation": "group-status", "error": type(error).__name__, "errno": error.errno})
    clean = group_absent and child.returncode is not None
    if not clean:
        events.append({"operation": "group-status", "status": "cleanup-unconfirmed"})

    def normalize(value):
        if value is None: return "" if text else b""
        return value.decode(errors="replace") if text and isinstance(value, bytes) else value
    return {"exit_code": 124 if stop == "timeout" else 130 if stop == "interrupted" else child.returncode,
            "child_exit_code": child.returncode, "stop_reason": stop,
            "stdout": normalize(output), "stderr": normalize(error_output),
            "cleanup_complete": clean, "cleanup": events, "owner": owner,
            "started_utc": started, "finished_utc": utc_now()}


def clear_new_bundle_metadata(app, *, evidence_path=None):
    """Remove codesign-forbidden copy metadata only from a newly created copy.

    Never call this on an installed app, an input archive, or an old backup.
    File content and existing signatures are unchanged; quarantine is preserved.
    """
    removed = []
    read_command = ["/usr/bin/xattr", "-r", "-s", str(app)]
    before = run_owned(read_command, timeout=30, text=True)
    evidence = [{"argv": read_command, **before}]
    if evidence_path:
        write_json(evidence_path, evidence)
    if before["exit_code"] != 0 or not before["cleanup_complete"]:
        raise ValueError("Cannot inspect new bundle metadata: " + str(app) + "\n" + before["stderr"])
    for name in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
        # Darwin Python does not expose os.listxattr. -s ensures a copied
        # symlink cannot redirect the recursive operation outside this copy.
        if name not in before["stdout"]:
            continue
        delete_command = ["/usr/bin/xattr", "-r", "-s", "-d", name, str(app)]
        deletion = run_owned(delete_command, timeout=30, text=True)
        evidence.append({"argv": delete_command, **deletion})
        if evidence_path:
            write_json(evidence_path, evidence)
        if deletion["exit_code"] != 0 or not deletion["cleanup_complete"]:
            raise ValueError("Cannot clear new bundle metadata: " + str(app) + "\n" + deletion["stderr"])
        removed.append({"attribute": name, "before_names": before["stdout"],
                        "read": {"argv": read_command, **before},
                        "delete": {"argv": delete_command, **deletion}})
    return removed


def copy_bundle(app, target, *, evidence_path=None):
    """Copy to a fresh location, preserving macOS metadata including quarantine."""
    target = Path(target)
    if target.exists() or target.is_symlink():
        raise ValueError("Bundle copy destination already exists: " + str(target))
    command = ["/usr/bin/ditto", "--rsrc", "--extattr", str(app), str(target)]
    result = run_owned(command, timeout=120, text=True)
    if evidence_path:
        write_json(evidence_path, {"argv": command, **result})
    if result["exit_code"] != 0 or not result["cleanup_complete"]:
        raise ValueError("Bundle copy failed: " + str(target) + "\n" + result["stderr"])
    return {"argv": command, **result}


def verify_sandbox_signatures(app, *, project=PROJECT, evidence_path=None, test_bundle_id=None):
    """Inspect each target independently; do not re-sign or use --deep."""
    app = Path(app).resolve()
    expected_extensions = {relative for relative, *_ in SIGNING_TARGETS if relative != "."}
    actual_extensions = {path.relative_to(app).as_posix() for path in app.rglob("*.appex")}
    if actual_extensions != expected_extensions:
        raise ValueError("Missing or unexpected app extensions: " + str(sorted(actual_extensions)))
    bundles = {}
    evidence = {"started_utc": utc_now(), "app": str(app), "checks": []}
    targets = test_signing_targets(test_bundle_id) if test_bundle_id is not None else SIGNING_TARGETS
    for relative, identifier, executable, entitlement_file in targets:
        target = app / relative
        if target.is_symlink() or not target.is_dir():
            raise ValueError("Signing target must be a real bundle: " + str(target))
        info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable:
            raise ValueError("Unexpected bundle identity: " + str(target))
        binary = target / "Contents/MacOS" / executable
        if binary.is_symlink() or not binary.is_file():
            raise ValueError("Missing or symlinked executable: " + str(binary))
        checks = []
        for options in (("--verify", "--strict", "--verbose=2"),
                        ("--display", "--verbose=4"), ("--display", "--entitlements", ":-")):
            command = ["/usr/bin/codesign", *options, str(target)]
            result = run_owned(command, timeout=30, text=True)
            checks.append({"argv": command, **result})
            evidence["checks"].append({"argv": command, **result})
            if evidence_path:
                write_json(evidence_path, evidence)
            if result["exit_code"] != 0 or not result["cleanup_complete"]:
                raise ValueError("Signature check failed: " + str(target) + "\n" + result["stderr"])
        details = checks[1]["stdout"] + "\n" + checks[1]["stderr"]
        fields = dict(line.split("=", 1) for line in details.splitlines() if "=" in line)
        if fields.get("Identifier") != identifier:
            raise ValueError("Signature identifier differs from bundle identity: " + str(target))
        try:
            entitlements = plistlib.loads(checks[2]["stdout"].encode())
        except (ValueError, plistlib.InvalidFileException) as error:
            raise ValueError("Missing or invalid signed entitlements: " + str(target)) from error
        expected = plistlib.loads((Path(project) / entitlement_file).read_bytes())
        security = {key: value for key, value in entitlements.items() if key.startswith("com.apple.security.")}
        if entitlements.get("com.apple.security.app-sandbox") is not True or security != expected:
            raise ValueError("Signed security entitlements differ from this target's source: " + str(target))
        if not fields.get("CDHash"):
            raise ValueError("Signature has no CDHash: " + str(target))
        bundles[relative] = {"identifier": identifier, "entitlements": entitlements,
                             "cdhash": fields["CDHash"], "signature": fields.get("Signature"),
                             "team_identifier": fields.get("TeamIdentifier"), "checks": checks}
    return {"verified_utc": utc_now(), "bundles": bundles}


def signature_identity(evidence):
    return {name: {key: value for key, value in target.items() if key != "checks"}
            for name, target in evidence["bundles"].items()}


def changed_bundle_files(before, after):
    return {name: {"before": before.get(name), "after": after.get(name)}
            for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)}


def compare_executable_payloads(app, parent_directory, parent_manifest, *, evidence_path=None):
    """Compare complete executables after removing signatures on disposable copies.

    codesign handles every slice of universal Mach-O files. No payload byte or
    load-command range is excluded by this tool, and no input is modified.
    """
    evidence = {"method": "codesign-remove-signature-then-complete-byte-comparison", "executables": {}}
    with tempfile.TemporaryDirectory(prefix="gpxpv-payload-proof-") as temporary:
        temporary = Path(temporary)
        for relative, _, executable, _ in SIGNING_TARGETS:
            prefix = "" if relative == "." else relative + "/"
            binary_relative = prefix + "Contents/MacOS/" + executable
            original = Path(parent_directory) / "parent-executables" / executable
            if original.is_symlink() or sha256(original) != parent_manifest["bundle_files"][binary_relative]["sha256"]:
                raise ValueError("Parent executable snapshot differs from its build manifest: " + executable)
            current = Path(app) / binary_relative
            item = {"parent_sha256": sha256(original), "derived_sha256": sha256(current), "checks": []}
            evidence["executables"][binary_relative] = item
            stripped = []
            for label, source in (("parent", original), ("derived", current)):
                proof = temporary / (executable + "-" + label)
                proof.write_bytes(source.read_bytes())
                command = ["/usr/bin/codesign", "--remove-signature", str(proof)]
                result = run_owned(command, timeout=30, text=True)
                item["checks"].append({"argv": command, **result})
                if evidence_path:
                    write_json(evidence_path, evidence)
                if result["exit_code"] != 0 or not result["cleanup_complete"]:
                    raise ValueError("Cannot compare unsigned executable payload: " + executable + "\n" + result["stderr"])
                stripped.append(proof.read_bytes())
                item[label + "_payload_sha256"] = sha256(proof)
            item["payloads_equal"] = stripped[0] == stripped[1]
            if evidence_path:
                write_json(evidence_path, evidence)
            if not item["payloads_equal"]:
                raise ValueError("Isolated test executable changes non-signature payload: " + executable)
    return evidence


def validate_test_copy(app, manifest, manifest_path, *, project):
    isolated = manifest.get("test_copy", {})
    targets = test_signing_targets(isolated.get("bundle_id"))
    parent_path = manifest_path.parent / "parent-build-manifest.json"
    if sha256(parent_path) != isolated.get("parent_manifest_sha256"):
        raise ValueError("Isolated test copy parent manifest changed")
    parent = json.loads(parent_path.read_text())
    if (parent.get("source_association") != "build-completed-between-identical-input-snapshots"
            or parent.get("signing", {}).get("policy") != "sandboxed-local"
            or parent.get("signing", {}).get("installable") is not True
            or parent.get("source_inputs") != manifest.get("source_inputs")
            or parent.get("build") != manifest.get("build")):
        raise ValueError("Isolated test copy has no verified parent build attribution")
    changes = changed_bundle_files(parent["bundle_files"], manifest["bundle_files"])
    allowed = set()
    for relative, identifier, executable, _ in targets:
        prefix = "" if relative == "." else relative + "/"
        info_relative = prefix + "Contents/Info.plist"
        allowed.update((info_relative, prefix + "Contents/MacOS/" + executable,
                        prefix + "Contents/_CodeSignature/CodeResources"))
        original = manifest_path.parent / "parent-info" / (executable + ".plist")
        if sha256(original) != parent["bundle_files"][info_relative]["sha256"]:
            raise ValueError("Isolated test copy original Info.plist snapshot changed")
        info = plistlib.loads(original.read_bytes())
        info["CFBundleIdentifier"] = identifier
        if plistlib.loads((app / info_relative).read_bytes()) != info:
            raise ValueError("Isolated test copy changes more than CFBundleIdentifier")
    if not changes.keys() <= allowed or changes != isolated.get("bundle_changes"):
        raise ValueError("Isolated test copy changes exceed Info.plist and signature scope")
    signing = manifest.get("signing", {})
    if signing.get("policy") != "isolated-sandbox-test" or signing.get("installable") is not False:
        raise ValueError("Isolated test copy must not be marked installable")
    actual = verify_sandbox_signatures(app, project=project, test_bundle_id=isolated["bundle_id"])
    if signature_identity(actual) != signature_identity(signing):
        raise ValueError("Actual isolated test signature differs from manifest")
    return compare_executable_payloads(app, manifest_path.parent, parent)


def prepare_isolated_test_copy(app, destination, *, test_bundle_id=None, manifest_path=None, project=PROJECT):
    """Derive a test-only identity without modifying or launching the archive."""
    app = Path(app).resolve()
    destination = Path(destination).resolve()
    if destination == app or app in destination.parents:
        raise ValueError("Test copy destination must be outside its input bundle")
    bundle_id = test_bundle_id or (PRODUCTION_ID + ".test.t" + datetime.datetime.now(
        datetime.timezone.utc).strftime("%Y%m%dt%H%M%Sz") + "-" + uuid.uuid4().hex[:12])
    targets = test_signing_targets(bundle_id)
    # A reused ID would inherit earlier test settings. Only check these new-ID
    # paths for existence; never read or modify any user's preference contents.
    if ((Path.home() / "Library/Containers" / bundle_id).exists()
            or (Path.home() / "Library/Preferences" / (bundle_id + ".plist")).exists()):
        raise ValueError("Isolated test bundle ID has already been used; choose a new ID")
    manifest_path = Path(manifest_path).resolve() if manifest_path else app.parent / "build-manifest.json"
    parent = json.loads(manifest_path.read_text())
    validate_bundle(app, manifest_path, project=project, for_install=True)
    destination.mkdir(parents=True, exist_ok=False)
    (destination / "parent-build-manifest.json").write_bytes(manifest_path.read_bytes())
    (destination / "parent-info").mkdir()
    (destination / "parent-executables").mkdir()
    target = destination / "GPXPointViewer.app"
    copy_result = copy_bundle(app, target, evidence_path=destination / "copy-result.json")
    removed = clear_new_bundle_metadata(target, evidence_path=destination / "metadata-cleanup.json")
    for relative, identifier, executable, _ in targets:
        info_path = target / relative / "Contents/Info.plist"
        original = info_path.read_bytes()
        (destination / "parent-info" / (executable + ".plist")).write_bytes(original)
        (destination / "parent-executables" / executable).write_bytes(
            (app / relative / "Contents/MacOS" / executable).read_bytes())
        info = plistlib.loads(original)
        info["CFBundleIdentifier"] = identifier
        info_path.write_bytes(plistlib.dumps(info))
    sign_commands = []
    # Two extensions first, then the enclosing app, with their own privileges.
    for relative, _, _, entitlement_file in (*targets[1:], targets[0]):
        command = ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime",
                   "--timestamp=none", "--generate-entitlement-der", "--entitlements",
                   str(Path(project) / entitlement_file), str(target / relative)]
        result = run_owned(command, timeout=30, text=True)
        sign_commands.append({"argv": command, **result})
        write_json(destination / "test-signing-commands.json", sign_commands)
        if result["exit_code"] != 0 or not result["cleanup_complete"]:
            raise ValueError("Isolated test copy signing failed: " + str(target / relative) + "\n" + result["stderr"])
    signing = verify_sandbox_signatures(target, project=project, test_bundle_id=bundle_id,
                                        evidence_path=destination / "test-signing-checks.json")
    signing.update(policy="isolated-sandbox-test", installable=False, removed_archive_metadata=removed)
    payload_proof = compare_executable_payloads(target, destination, parent,
                                               evidence_path=destination / "test-executable-payload-proof.json")
    files = tree_manifest(target)
    if tree_manifest(app) != parent["bundle_files"] or sha256(manifest_path) != sha256(destination / "parent-build-manifest.json"):
        raise ValueError("Input archive changed while preparing isolated test copy")
    manifest = {"schema_version": 1, "created_utc": utc_now(), "app": target.name,
                "original_app": str(app), "source_association": TEST_ASSOCIATION,
                "source_inputs": parent["source_inputs"], "build": parent["build"],
                "bundle_files": files, "executable_sha256": sha256(target / "Contents/MacOS/GPXPointViewer"),
                "copy": copy_result, "signing": signing,
                "test_copy": {"bundle_id": bundle_id, "parent_manifest_sha256": sha256(manifest_path),
                              "parent_app": str(app), "executable_payload_proof": payload_proof,
                              "bundle_changes": changed_bundle_files(parent["bundle_files"], files)}}
    write_json(destination / "build-manifest.json", manifest)
    return target, manifest


def archive_bundle(app, destination, *, source=None, build=None, project=PROJECT, signing_policy=None):
    app = Path(app).resolve()
    if not (app / "Contents/MacOS/GPXPointViewer").is_file():
        raise ValueError("Not a GPXPointViewer app: " + str(app))
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    before = tree_manifest(app)
    target = destination / "GPXPointViewer.app"
    copy_result = copy_bundle(app, target, evidence_path=destination / "copy-result.json")
    removed_metadata = clear_new_bundle_metadata(target, evidence_path=destination / "metadata-cleanup.json")
    if tree_manifest(target) != before:
        raise ValueError("Archived bundle differs from its source; archive retained for diagnosis")
    association = "historical-unverified-source"
    if source is not None:
        if not build or build.get("exit_code") != 0 or source != source_inputs(project):
            raise ValueError("Successful build with unchanged source inputs is required")
        association = "build-completed-between-identical-input-snapshots"
    signing = {"policy": signing_policy or "historical-unknown", "installable": False,
               "removed_archive_metadata": removed_metadata}
    if signing_policy == "sandboxed-local":
        signing.update(verify_sandbox_signatures(target, project=project,
                                                evidence_path=destination / "signing-checks.json"), installable=True)
    elif signing_policy not in (None, "development-unsigned"):
        raise ValueError("Unknown signing policy: " + str(signing_policy))
    manifest = {"schema_version": 1, "created_utc": utc_now(), "app": target.name,
                "original_app": str(app), "source_association": association,
                "source_inputs": source, "build": build, "bundle_files": before,
                "executable_sha256": sha256(target / "Contents/MacOS/GPXPointViewer"),
                "copy": copy_result, "signing": signing}
    write_json(destination / "build-manifest.json", manifest)
    return target, manifest


def preserve_archive_zip(app, destination, *, project=PROJECT):
    """Keep a durable ZIP/evidence in the project, with the runnable app local."""
    app, destination = Path(app).resolve(), Path(destination).resolve()
    if app == destination or app in destination.parents or destination in app.parents:
        raise ValueError("Durable archive directory must be separate from the runnable bundle")
    provenance = validate_bundle(app, project=project)
    manifest = json.loads((app.parent / "build-manifest.json").read_text())
    destination.mkdir(parents=True, exist_ok=False)
    for name in ("build-manifest.json", "signing-checks.json", "copy-result.json", "metadata-cleanup.json"):
        source = app.parent / name
        if source.is_file():
            (destination / name).write_bytes(source.read_bytes())
    archive = destination / (app.name + ".zip")
    command = ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", "--rsrc", "--extattr", str(app), str(archive)]
    result = run_owned(command, timeout=120, text=True)
    write_json(destination / "zip-command.json", {"argv": command, **result})
    if result["exit_code"] != 0 or not result["cleanup_complete"]:
        raise ValueError("Durable archive ZIP creation failed: " + result["stderr"])
    seen, listing = set(), []
    with zipfile.ZipFile(archive) as zipped:
        for member in zipped.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts or member.filename in seen:
                raise ValueError("Unsafe or duplicate durable ZIP member: " + member.filename)
            seen.add(member.filename)
            listing.append({"name": member.filename, "bytes": member.file_size})
            if not path.parts or path.parts[0] not in (app.name, "__MACOSX"):
                raise ValueError("Unexpected ZIP root: " + member.filename)
            if member.is_dir() or path.parts[0] == "__MACOSX":
                continue
            relative = PurePosixPath(*path.parts[1:]).as_posix()
            expected = manifest["bundle_files"].get(relative)
            if expected is None:
                raise ValueError("Unexpected ZIP bundle file: " + relative)
            is_symlink = (member.external_attr >> 16) & 0o170000 == 0o120000
            if is_symlink != ("symlink" in expected):
                raise ValueError("ZIP file type differs from manifest: " + relative)
            if "symlink" in expected:
                if zipped.read(member).decode() != expected["symlink"]:
                    raise ValueError("ZIP symlink differs from manifest: " + relative)
            else:
                digest = hashlib.sha256()
                with zipped.open(member) as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                if digest.hexdigest() != expected["sha256"] or member.file_size != expected["bytes"]:
                    raise ValueError("ZIP file differs from manifest: " + relative)
    expected_members = {app.name + "/" + name for name in manifest["bundle_files"]}
    if not expected_members <= seen:
        raise ValueError("Durable ZIP is missing bundle files")
    receipt = {"created_utc": utc_now(), "app": str(app), "manifest": str(app.parent / "build-manifest.json"),
               "durable_zip": str(archive), "durable_manifest": str(destination / "build-manifest.json"),
               "zip_sha256": sha256(archive), "zip_bytes": archive.stat().st_size,
               "artifact_recovery": manifest.get("artifact_recovery"),
               "provenance": provenance, "members": listing,
               "retention": "Runnable local paths may be OS-purged; restore ZIP only into a new non-synced local directory"}
    write_json(destination / "archive-receipt.json", receipt)
    return receipt


def validate_bundle(app, manifest_path=None, *, project=PROJECT, for_install=False, signing_evidence_path=None):
    app = Path(app).resolve()
    manifest_path = Path(manifest_path).resolve() if manifest_path else app.parent / "build-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema_version") != 1 or manifest.get("app") != app.name:
        raise ValueError("Unsupported or mismatched build manifest: " + str(manifest_path))
    if manifest.get("bundle_files") != tree_manifest(app):
        raise ValueError("Bundle contents differ from build manifest: " + str(app))
    association = manifest.get("source_association")
    if association not in ("build-completed-between-identical-input-snapshots", TEST_ASSOCIATION):
        raise ValueError("Historical bundle has no current-source build attribution")
    if not manifest.get("build") or manifest["build"].get("exit_code") != 0:
        raise ValueError("Manifest does not record a successful build")
    if manifest.get("source_inputs") != source_inputs(project):
        raise ValueError("Current build inputs differ from the archived build; rebuild before testing")
    if manifest.get("executable_sha256") != sha256(app / "Contents/MacOS/GPXPointViewer"):
        raise ValueError("Executable hash differs from the build manifest")
    if association == TEST_ASSOCIATION:
        if for_install:
            raise ValueError("Isolated test copies cannot be installed as the production app")
        payload_proof = validate_test_copy(app, manifest, manifest_path, project=project)
    if for_install:
        signing = manifest.get("signing", {})
        if signing.get("policy") != "sandboxed-local" or signing.get("installable") is not True:
            raise ValueError("Installation requires an explicitly verified sandboxed-local archive; --no-sign and historical archives are not installable")
        actual = verify_sandbox_signatures(app, project=project, evidence_path=signing_evidence_path)
        if signature_identity(actual) != signature_identity(signing):
            raise ValueError("Actual signing identity differs from the build manifest")
    return {"manifest": str(manifest_path), "app": str(app),
            "executable_sha256": manifest["executable_sha256"],
            "source_sha256": manifest["source_inputs"]["sha256"],
            "source_association": manifest["source_association"],
            **({"test_bundle_id": manifest["test_copy"]["bundle_id"], "test_executable_payload_proof": payload_proof}
               if association == TEST_ASSOCIATION else {})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--for-install", action="store_true", help="Also require recorded and actual sandbox signatures for all three targets")
    parser.add_argument("--prepare-isolated-test-copy", action="store_true", help="Derive a sandboxed unique-ID test copy from a verified installable archive; never launches it")
    parser.add_argument("--test-bundle-id", help="Unique de.wayne.GPXPointViewer.test.<slug>, generated when omitted")
    args = parser.parse_args()
    if args.prepare_isolated_test_copy:
        if not args.destination or args.validate or args.for_install:
            parser.error("--prepare-isolated-test-copy requires --destination and cannot be combined with validation flags")
        target, manifest = prepare_isolated_test_copy(args.app, args.destination,
            test_bundle_id=args.test_bundle_id, manifest_path=args.manifest)
        print(json.dumps({"app": str(target), "manifest": str(target.parent / "build-manifest.json"),
                          "test_bundle_id": manifest["test_copy"]["bundle_id"],
                          "source_association": manifest["source_association"]}, ensure_ascii=False, indent=2))
    elif args.validate or args.for_install:
        print(json.dumps(validate_bundle(args.app, args.manifest, for_install=args.for_install), ensure_ascii=False, indent=2))
    else:
        destination = args.destination or PROJECT / "Builds" / (
            datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_historical_" + uuid.uuid4().hex[:8])
        target, manifest = archive_bundle(args.app, destination)
        print(json.dumps({"app": str(target), "manifest": str(target.parent / "build-manifest.json"),
                          "source_association": manifest["source_association"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
