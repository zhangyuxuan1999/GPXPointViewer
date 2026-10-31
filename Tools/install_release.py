#!/usr/bin/env python3
"""Check or install a sandboxed local Release, retaining a recoverable backup.

This never quits/launches apps, edits preferences, or signs any bundle. Before
--execute, save edits and quit GPXPointViewer normally. The explicit target flag
records the operator's existing installation authorization; it is not a prompt.
"""
import argparse
import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import sys
import uuid

from archive_build import (PROJECT, clear_new_bundle_metadata, copy_bundle, run_owned, sha256,
                           tree_manifest, utc_now, validate_bundle, write_json)

TARGET = Path("/Applications/GPXPointViewer.app")


def paths_overlap(first, second):
    first, second = Path(first).resolve(), Path(second).resolve()
    return first == second or first in second.parents or second in first.parents


def require_external_receipt(receipt_dir, *protected):
    receipt_dir = Path(receipt_dir).resolve()
    if any(paths_overlap(receipt_dir, path) for path in protected):
        raise ValueError("Receipt directory overlaps a protected source, target, staging or backup path")
    if any(path.suffix.lower() in (".app", ".appex") for path in (receipt_dir, *receipt_dir.parents)):
        raise ValueError("Receipt directory must be outside all app bundles")


def directory_identity(path):
    try:
        status = Path(path).stat()
        return {"device": status.st_dev, "inode": status.st_ino}
    except FileNotFoundError:
        return None


def atomic_swap(first, second):
    """One macOS same-volume exchange. Refuse rather than use two renames."""
    if sys.platform != "darwin":
        raise ValueError("Atomic replacement requires macOS renameatx_np(RENAME_SWAP)")
    function = ctypes.CDLL(None, use_errno=True).renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    # Values and ABI from the macOS SDK sys/fcntl.h and sys/stdio.h.
    if function(-2, os.fsencode(first), -2, os.fsencode(second), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(first) + " <-> " + str(second))
    return {"operation": "renameatx_np", "flags": ["RENAME_SWAP"], "first": str(first), "second": str(second)}


def write_receipt(path, receipt):
    # Publish complete phase records; a process interruption cannot leave a
    # partially truncated commit-prepared record in place of the previous one.
    path = Path(path)
    temporary = path.with_suffix(".tmp")
    write_json(temporary, receipt)
    with temporary.open("rb") as stream:
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def require_stopped(receipt):
    command = ["/bin/ps", "-axo", "pid=,comm=", "-ww"]
    result = run_owned(command, timeout=15, text=True)
    receipt.setdefault("process_checks", []).append({"argv": command, **result})
    if result["exit_code"] != 0 or not result["cleanup_complete"]:
        raise ValueError("Cannot confirm GPXPointViewer is stopped")
    running = []
    for line in result["stdout"].splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and Path(parts[1]).name == "GPXPointViewer":
            running.append({"pid": parts[0], "executable": parts[1]})
    if running:
        receipt["running_apps"] = running
        raise ValueError("Save edits and quit GPXPointViewer normally before installation")


def install_bundle(app, *, authorized_target, receipt_dir, manifest_path=None, project=PROJECT):
    target = TARGET
    if Path(authorized_target).absolute() != target:
        raise ValueError("Authorization must explicitly name " + str(target))
    # Do not follow a redirected target or destination directory.
    if target.is_symlink() or target.parent.is_symlink() or target.parent.resolve() != target.parent:
        raise ValueError("Installation target must not be a symlink")
    app = Path(app).resolve()
    if paths_overlap(app, target):
        raise ValueError("Install from a separate validated archive")
    manifest_path = Path(manifest_path).resolve() if manifest_path else app.parent / "build-manifest.json"
    receipt_dir = Path(receipt_dir).resolve()
    suffix = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_" + uuid.uuid4().hex[:8]
    # Stage directly at the permanent backup location. After one exchange this
    # same path holds the complete old app; no second move is needed.
    stage_root = target.parent / ("GPXPointViewer-backup-" + suffix)
    stage = stage_root / target.name
    require_external_receipt(receipt_dir, app, target, stage_root, stage)
    receipt_dir.mkdir(parents=True, exist_ok=False)
    receipt_path = receipt_dir / "install-result.json"
    receipt = {"status": "preflight", "started_utc": utc_now(), "archive": str(app),
               "manifest": str(manifest_path), "target": str(target),
               "authorized_target": str(authorized_target), "backup": None}
    write_receipt(receipt_path, receipt)
    backup = None
    installed_new = commit_attempted = False
    before = old_identity = stage_identity = None
    lock = None
    try:
        receipt["provenance"] = validate_bundle(app, manifest_path, project=project, for_install=True,
                                                signing_evidence_path=receipt_dir / "preflight-signing.json")
        receipt["manifest_sha256"] = sha256(manifest_path)
        require_stopped(receipt)
        write_receipt(receipt_path, receipt)
        # Serialize only this install tool. No unrelated processes are touched.
        lock = (target.parent / ".GPXPointViewer.install.lock").open("a")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = tree_manifest(target) if target.exists() else None
        receipt["previous_bundle_files"] = before
        stage_root.mkdir(exist_ok=False)
        receipt["staging"] = str(stage)
        receipt["copy"] = copy_bundle(app, stage, evidence_path=receipt_dir / "copy-result.json")
        receipt["removed_staging_metadata"] = clear_new_bundle_metadata(stage, evidence_path=receipt_dir / "metadata-cleanup.json")
        receipt["staged_provenance"] = validate_bundle(stage, manifest_path, project=project, for_install=True,
                                                       signing_evidence_path=receipt_dir / "staged-signing.json")
        require_stopped(receipt)
        if (tree_manifest(target) if target.exists() else None) != before:
            raise ValueError("Installed bundle changed during staging; refusing replacement")
        if target.is_symlink():
            raise ValueError("Installation target became a symlink")
        old_identity, stage_identity = directory_identity(target), directory_identity(stage)
        receipt["commit_prepared"] = {"previous_target": old_identity, "new_staged_bundle": stage_identity,
                                       "operation": "RENAME_SWAP" if before is not None else "rename-new-install"}
        receipt["status"] = "commit-prepared"
        if before is not None:
            backup = stage
            receipt["commit_prepared"]["backup_after_exchange"] = str(backup)
        write_receipt(receipt_path, receipt)
        commit_attempted = True
        if before is not None:
            receipt["commit"] = atomic_swap(target, stage)
        else:
            stage.rename(target)
            receipt["commit"] = {"operation": "rename-new-install"}
        installed_new = True
        if backup is not None:
            receipt["backup"] = str(backup)
        receipt["status"] = "committed"
        write_receipt(receipt_path, receipt)
        if backup is not None and tree_manifest(backup) != before:
            raise ValueError("Backup contents differ from the previous installation")
        receipt["installed_provenance"] = validate_bundle(target, manifest_path, project=project, for_install=True,
                                                          signing_evidence_path=receipt_dir / "installed-signing.json")
        receipt["installed_bundle_files"] = tree_manifest(target)
        receipt["status"] = "installed"
        receipt["finished_utc"] = utc_now()
        write_receipt(receipt_path, receipt)
        if backup is None:
            stage_root.rmdir()
        return receipt
    except BaseException as error:
        receipt.update(status="failed", error=str(error), finished_utc=utc_now())
        # An interruption may occur just after the kernel exchange but before
        # the assignment above. Directory identities also detect that boundary.
        if commit_attempted and directory_identity(target) == stage_identity:
            installed_new = True
        try:
            if installed_new:
                if before is not None:
                    if directory_identity(stage) != old_identity:
                        raise ValueError("Cannot confirm old bundle identity for atomic rollback")
                    receipt["rollback"] = atomic_swap(target, stage)
                    receipt["backup"] = None
                    receipt["rollback_verified"] = tree_manifest(target) == before
                    if not receipt["rollback_verified"]:
                        raise ValueError("Restored bundle differs from the pre-install snapshot")
                else:
                    target.rename(stage)
                receipt["failed_new_bundle"] = str(stage)
        except BaseException as rollback_error:
            receipt["rollback_error"] = str(rollback_error)
        write_receipt(receipt_path, receipt)
        raise
    finally:
        if lock is not None:
            lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--execute", action="store_true", help="Perform the installation after validation")
    parser.add_argument("--authorized-target", type=Path, help="Explicitly record existing authorization for /Applications/GPXPointViewer.app")
    parser.add_argument("--receipt-dir", type=Path)
    args = parser.parse_args()
    if not args.execute:
        print(json.dumps(validate_bundle(args.app, args.manifest, for_install=True), ensure_ascii=False, indent=2))
        return 0
    if args.authorized_target is None:
        parser.error("--execute requires --authorized-target /Applications/GPXPointViewer.app")
    receipt_dir = args.receipt_dir or PROJECT / "Builds" / (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_install_" + uuid.uuid4().hex[:8])
    print("INSTALL_RECEIPT=" + str(receipt_dir.resolve() / "install-result.json"), flush=True)
    result = install_bundle(args.app, authorized_target=args.authorized_target,
                            receipt_dir=receipt_dir, manifest_path=args.manifest)
    print(json.dumps({key: result[key] for key in ("status", "target", "backup", "installed_provenance")}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
