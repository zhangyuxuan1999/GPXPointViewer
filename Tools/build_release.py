#!/usr/bin/env python3
"""Build Release into a unique project Builds directory and archive attribution.

Example: python3 Tools/build_release.py --arch arm64
Default: use Xcode's existing per-target local signing and sandbox entitlements.
--no-sign is for explicit development/diagnosis only; its archive cannot be installed.
No installation or app launch is performed. Failed/inconsistent builds are retained.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

from archive_build import PROJECT, archive_bundle, preserve_archive_zip, run_owned, source_inputs, utc_now, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=PROJECT / "Builds")
    parser.add_argument("--arch", choices=("arm64", "x86_64"))
    parser.add_argument("--no-sign", action="store_true", help="Development/diagnosis only: unsigned output is not installable")
    parser.add_argument("--no-icloud-coordination", action="store_true",
                        help="Disable iCloud coordinated reads for this xcodebuild process only; no global defaults changes")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    run = args.output_root.resolve() / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_release_" + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    before = source_inputs()
    write_json(run / "inputs-before.json", before)
    # Documents may be managed by FileProvider, which can add FinderInfo to
    # newly created bundles before Xcode signs them. Keep intermediate products
    # in a unique private local directory; persistent evidence/archive stay here.
    local_staging = Path(tempfile.mkdtemp(prefix="GPXPointViewer-" + run.name + "-", dir="/private/tmp")).resolve()
    derived_data = local_staging / "DerivedData"
    command = ["xcodebuild", "-project", str(PROJECT / "GPXPointViewer.xcodeproj"),
               "-scheme", "GPXPointViewer", "-configuration", "Release",
               "-destination", "generic/platform=macOS", "-derivedDataPath", str(derived_data),
               "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"]
    if args.arch:
        command += ["ARCHS=" + args.arch, "ONLY_ACTIVE_ARCH=NO"]
    if args.no_sign:
        command += ["CODE_SIGNING_ALLOWED=NO"]
    if args.no_icloud_coordination:
        command += ["-SynchronizeWithICloud=NO"]
    command += ["build"]
    record = {"argv": command, "cwd": str(PROJECT), "started_utc": utc_now(),
              "configuration": "Release", "requested_arch": args.arch,
              "requested_no_sign": args.no_sign,
              "signing_policy": "development-unsigned" if args.no_sign else "sandboxed-local",
              "code_sign_inject_base_entitlements": False,
              "local_staging_path": str(local_staging), "derived_data_path": str(derived_data),
              "runnable_archive_directory": str(local_staging / "archive"),
              "durable_archive_directory": str(run / "archive"),
              "intermediates_retention": "retained-without-automatic-cleanup; OS temporary storage may be purged",
              "timeout_seconds": args.timeout,
              "requested_no_icloud_coordination": args.no_icloud_coordination}
    print("BUILD_DIR=" + str(run), flush=True)
    print("DERIVED_DATA=" + str(derived_data), flush=True)
    write_json(run / "build-command.json", record)
    with (run / "build.log").open("wb") as log:
        execution = run_owned(command, cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        if execution["stderr"]:
            log.write(execution["stderr"])
        code = execution["exit_code"]
    record["execution"] = {key: value for key, value in execution.items() if key not in ("stdout", "stderr")}
    record.update(finished_utc=utc_now(), exit_code=code)
    write_json(run / "build-command.json", record)
    after = source_inputs()
    write_json(run / "inputs-after.json", after)
    if code:
        print("Build failed; see " + str(run / "build.log"), file=sys.stderr)
        return code if code > 0 else 1
    if not execution["cleanup_complete"]:
        print("Build process group cleanup is unconfirmed; attribution refused: " + str(run), file=sys.stderr)
        return 3
    if before != after:
        print("Build inputs changed during build; attribution refused: " + str(run), file=sys.stderr)
        return 2
    app = derived_data / "Build/Products/Release/GPXPointViewer.app"
    target, manifest = archive_bundle(app, local_staging / "archive", source=before, build=record,
                                      signing_policy=record["signing_policy"])
    durable = preserve_archive_zip(target, run / "archive")
    # Keep the build log and both input snapshots beside the archive's manifest.
    print(json.dumps({"app": str(target), "manifest": str(target.parent / "build-manifest.json"),
                      "durable_zip": durable["durable_zip"], "durable_manifest": durable["durable_manifest"],
                      "executable_sha256": manifest["executable_sha256"],
                      "source_sha256": before["sha256"],
                      "signing_policy": manifest["signing"]["policy"],
                      "installable": manifest["signing"]["installable"]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
