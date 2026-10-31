#!/usr/bin/env python3
"""Playback area-reveal prototype harness (DeepSeek 2026-10-31, branch fix/playback-area-reveal).

Builds the real Playback/PlaybackReveal sources with a synthetic interleaved
two-city track and checks that:
  * the old global-time reveal already draws most of city B when the camera arrives;
  * the per-area reveal draws almost nothing of B at arrival and everything at the end.
No product code is modified by running this.
"""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/gpxpv-segment-playback")
out.mkdir(parents=True, exist_ok=True)
sources = [
    "Tests/segments/playback/main.swift",
    "GPXPointViewer/PlaybackReveal.swift",
    "GPXPointViewer/Playback.swift",
    "GPXPointViewer/GPXParser.swift",
    "GPXPointViewer/TrackData.swift",
    "GPXPointViewer/GeoCompute.swift",
    "GPXPointViewer/Colormaps.swift",
    "GPXPointViewer/MetalPointRenderer.swift",
    "GPXPointViewer/L10nSupport.swift",
    "GPXPointViewer/GapFill.swift",
    "GPXPointViewer/RoadNetwork.swift",
    "GPXPointViewer/RouteReplay.swift",
    "GPXPointViewer/BatchFill.swift",
    "GPXPointViewer/Heat3D.swift",
    "GPXPointViewer/PixelGlobe.swift",
    "GPXPointViewer/GPXWriter.swift",
    "GPXPointViewer/FogArchive.swift",
    "GPXPointViewer/FillPlausibility.swift",
]
cmd = ["swiftc", "-O", "-module-cache-path", str(out / "module-cache"), "-o", str(out / "playback-tests")] + sources
(out / "build-command.txt").write_text(repr(cmd) + "\n")
r = subprocess.run(cmd, cwd=root, capture_output=True)
(out / "build.stdout").write_bytes(r.stdout)
(out / "build.stderr").write_bytes(r.stderr)
if r.returncode:
    sys.stderr.write(r.stderr.decode("utf-8", "replace"))
    sys.exit(r.returncode)
r = subprocess.run([str(out / "playback-tests")], cwd=root, capture_output=True)
(out / "test.stdout").write_bytes(r.stdout)
(out / "test.stderr").write_bytes(r.stderr)
sys.stdout.write(r.stdout.decode("utf-8", "replace"))
sys.stderr.write(r.stderr.decode("utf-8", "replace"))
sys.exit(r.returncode)
