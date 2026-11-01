#!/usr/bin/env python3
import os, subprocess, sys, tempfile
root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
src = os.path.join(root, "GPXPointViewer")
files = ["GPXParser.swift", "TrackData.swift", "GeoCompute.swift", "Colormaps.swift", "L10nSupport.swift",
         "MetalPointRenderer.swift", "GapFill.swift", "RoadNetwork.swift", "RouteReplay.swift",
         "BatchFill.swift", "Heat3D.swift", "PixelGlobe.swift", "GPXWriter.swift", "FogArchive.swift",
         "FillPlausibility.swift"]
out = tempfile.mkdtemp(prefix="lodtest-")
exe = os.path.join(out, "lodtest")
cmd = ["swiftc", "-O", "-module-cache-path", os.path.join(out, "mc"), "-o", exe,
       os.path.join(root, "Tests/segments/lod/main.swift")] + [os.path.join(src, f) for f in files]
print("COMPILE", " ".join(cmd))
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode != 0:
    print(r.stderr[-4000:]); sys.exit(r.returncode)
r = subprocess.run([exe], capture_output=True, text=True)
print(r.stdout); print(r.stderr[-2000:]) if r.stderr else None
sys.exit(r.returncode)
