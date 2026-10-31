#!/usr/bin/env python3
"""Focused, offline N-20/N-26 product-source probe. Never starts the app."""
import hashlib
import json
import pathlib
import subprocess
import sys
import time
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = pathlib.Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=False)
FIXTURES = OUT / "fixtures"
FIXTURES.mkdir()
ALPHABET = "olhwjsktri"


def block_name(digits):
    return "abcd" + "".join(ALPHABET[int(c)] for c in digits) + "zz"


raw = bytearray(32768 + 515)
raw[0] = 1  # tile (0, 0) refers to the first stored tile (uint16 LE).
raw[32768] = 0x80  # its first cell only; independently known world key.
compressed = zlib.compress(raw)
cases = {
    "zero": ["0"],
    "max": ["262143"],
    "padded-zero": ["0" * 100],
    "padded-max": ["0" * 100 + "262143"],
    "out-of-world": ["262144"],
    "u64-overflow": ["18446744073709551616"],
    "long-nines": ["9" * 30],
    "mixed": ["1", "9" * 30, "262144"],
}
for case, numbers in cases.items():
    directory = FIXTURES / (case + ".fwdb") / "Sync"
    directory.mkdir(parents=True)
    for digits in numbers:
        (directory / block_name(digits)).write_bytes(compressed)
invalid = FIXTURES / "bad-cipher.fwdb" / "Sync"
invalid.mkdir(parents=True)
(invalid / "abcdxzz").write_bytes(compressed)

sources = [
    "Tests/probes/deepseek-core/main.swift",
    "Tests/segments/core/Support.swift",
    "GPXPointViewer/FogArchive.swift",
    "GPXPointViewer/GPXWriter.swift",
    "GPXPointViewer/GPXParser.swift",
    "GPXPointViewer/TrackData.swift",
    "GPXPointViewer/GeoCompute.swift",
    "GPXPointViewer/Colormaps.swift",
    "GPXPointViewer/L10nSupport.swift",
]
manifest = {
    source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest()
    for source in sources + ["Tests/probes/deepseek-core/run.py"]
}
(OUT / "source-hashes.json").write_text(json.dumps(manifest, indent=2) + "\n")
(OUT / "fixtures.json").write_text(json.dumps(cases, indent=2) + "\n")


def execute(label, argv):
    (OUT / (label + "-command.json")).write_text(
        json.dumps({"argv": argv, "cwd": str(ROOT)}, indent=2) + "\n"
    )
    started = time.monotonic()
    try:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=180)
        stdout, stderr, code = result.stdout, result.stderr, result.returncode
        timed_out = False
    except subprocess.TimeoutExpired as error:
        stdout, stderr, code = error.stdout or b"", error.stderr or b"", 124
        timed_out = True
    (OUT / (label + ".stdout")).write_bytes(stdout)
    (OUT / (label + ".stderr")).write_bytes(stderr)
    (OUT / (label + "-result.json")).write_text(
        json.dumps({"exit_code": code, "timed_out": timed_out,
                    "elapsed_seconds": time.monotonic() - started}, indent=2) + "\n"
    )
    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    if code:
        sys.exit(code)


execute("build", ["swiftc", "-O", "-module-cache-path", str(OUT / "module-cache"),
                  "-o", str(OUT / "core-probe")] + sources)
execute("test", [str(OUT / "core-probe"), str(FIXTURES), str(OUT)])
