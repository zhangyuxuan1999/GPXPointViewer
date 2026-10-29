#!/usr/bin/env python3
"""Run actual production engine-label geometry against macOS font rectangles; no app/UI/API."""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys, datetime

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="New evidence directory; existing output is never overwritten")
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
source = root / "GPXPointViewer/ContentView.swift"
text = source.read_text()
start = text.index("extension TrackStore.FillOverlay {\n    struct EngineLabel:")
end = text.index("\n/// 补点覆盖层", start)
block = text[start:end]
display = text[text.index("ForEach(Array(TrackStore.FillOverlay.engineLabels(o.batchLines)"):]
assert ".font(Font(TrackStore.FillOverlay.engineLabelFont))" in display
assert ".frame(width: size.width, height: size.height)" in display
args.output.mkdir(parents=True, exist_ok=False)
(args.output / ".offline-fixture").write_text("Local font/geometry probe; no model service or app execution.\n")
stub = "import SwiftUI\nimport Foundation\nenum TrackStore { struct FillOverlay { struct BatchLine { var pts: [CGPoint]; var status: Int; var selected: Bool; var included: Bool } } }\n"
combined = stub + block + "\n" + Path(__file__).with_name("checks.swift").read_text()
swift = args.output / "production-checks.swift"
swift.write_text(combined)
command = ["swift", "-module-cache-path", str(args.output / "module-cache"), str(swift)]
(args.output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
meta = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "source": str(source),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "production_block_sha256": hashlib.sha256(block.encode()).hexdigest(),
        "checks_sha256": hashlib.sha256(Path(__file__).with_name("checks.swift").read_bytes()).hexdigest()}
(args.output / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
try:
    completed = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=90)
except subprocess.TimeoutExpired as error:
    (args.output / "timeout.json").write_text(json.dumps({"timeout_seconds": 90, "error": str(error)}, indent=2) + "\n")
    raise SystemExit(124)
(args.output / "stdout.json").write_text(completed.stdout)
(args.output / "stderr.txt").write_text(completed.stderr)
(args.output / "exit-code.json").write_text(json.dumps({"exit_code": completed.returncode}) + "\n")
print(completed.stdout, end="")
if completed.stderr:
    print(completed.stderr, file=sys.stderr, end="")
raise SystemExit(completed.returncode)
