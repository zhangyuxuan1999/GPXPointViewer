#!/usr/bin/env python3
"""Compile only the changed renderer and probe malformed columns, without app UI."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--gpu-only", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    dependencies = PROJECT / "Tests/segments/render/dependencies"
    sources = sorted(dependencies.glob("*.swift"))
    copied = out / "TrackData-test-only.swift"
    original = dependencies / "TrackData.swift"
    text = original.read_text()
    prefix, track = text.split("final class TrackData:", 1)
    mutations = ["rtcX", "rtcY", "unitX", "unitY", "unitZ", "liftF", "fileID", "lineBreakPrefix",
                 "fogBreakPrefix", "topology", "spatialOrder", "spatialKeys", "spatialFirsts"]
    for name in mutations:
        track = track.replace("let " + name + ":", "var " + name + ":")
    track = track.replace("private(set) var colors:", "var colors:")
    copied.write_text(prefix + "final class TrackData:" + track)
    source_inputs = sources + [PROJECT / "GPXPointViewer/MetalPointRenderer.swift",
                              PROJECT / "GPXPointViewer/Shaders.metal", HERE / "metal_contract.swift", Path(__file__)]
    manifest = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in source_inputs}
    (out / "inputs.json").write_text(json.dumps({"files": manifest,
        "test_only_transform": {"input": str(original), "output": str(copied), "sha256": hashlib.sha256(copied.read_bytes()).hexdigest(),
                                "changes": "TrackData column let -> var and colors private(set) removed for malformed fixtures only"}}, indent=2) + "\n")
    sources = [copied if path == original else path for path in sources]
    main_source = out / "main.swift"
    main_source.write_bytes((HERE / "metal_contract.swift").read_bytes())
    command = ["swiftc", "-O", "-D", "GPXPV_SEGMENT_RENDER_TESTS", "-module-cache-path", str(out / "ModuleCache"),
               "-o", str(out / "metal-contract"), str(PROJECT / "GPXPointViewer/MetalPointRenderer.swift"),
               str(main_source), *map(str, sources)]

    def execute(argv, label, timeout):
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        try:
            result = subprocess.run(argv, capture_output=True, timeout=timeout)
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = 124, error.stdout or b"", error.stderr or b""
        (out / (label + ".stdout.txt")).write_bytes(stdout)
        (out / (label + ".stderr.txt")).write_bytes(stderr)
        (out / (label + ".json")).write_text(json.dumps({"argv": argv, "started_utc": started,
            "finished_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "exit_code": code}, indent=2) + "\n")
        sys.stdout.buffer.write(stdout); sys.stderr.buffer.write(stderr)
        return code

    code = execute(command, "compile", 180)
    if code or args.build_only: return code
    command = [str(out / "metal-contract"), str(PROJECT / "GPXPointViewer/Shaders.metal"), str(out / "result.json")]
    if args.gpu_only: command.append("--gpu-only")
    return execute(command, "contract", 30)


if __name__ == "__main__":
    sys.exit(main())
