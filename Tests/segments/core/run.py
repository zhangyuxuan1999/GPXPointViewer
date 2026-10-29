#!/usr/bin/env python3
import pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[3]
out=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else "/private/tmp/gpxpv-segment-core")
out.mkdir(parents=True,exist_ok=True)
sources=["Tests/segments/core/main.swift","Tests/segments/core/Support.swift","GPXPointViewer/GPXParser.swift","GPXPointViewer/TrackData.swift","GPXPointViewer/GeoCompute.swift","GPXPointViewer/Colormaps.swift","GPXPointViewer/L10nSupport.swift","GPXPointViewer/GPXWriter.swift","GPXQuickLook/TrackShape.swift"]
cmd=["swiftc","-O","-module-cache-path",str(out/"module-cache"),"-o",str(out/"core-tests")]+sources
(out/"build-command.txt").write_text(repr(cmd)+"\n")
r=subprocess.run(cmd,cwd=root,capture_output=True)
(out/"build-result.json").write_text(__import__("json").dumps({"exit_code":r.returncode,"cwd":str(root)}));(out/"build.stdout").write_bytes(r.stdout);(out/"build.stderr").write_bytes(r.stderr)
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
if r.returncode: sys.exit(r.returncode)
r=subprocess.run([str(out/"core-tests")],cwd=root,capture_output=True)
(out/"test-result.json").write_text(__import__("json").dumps({"exit_code":r.returncode,"cwd":str(root)}));(out/"test.stdout").write_bytes(r.stdout);(out/"test.stderr").write_bytes(r.stderr)
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
if r.returncode: sys.exit(r.returncode)
preview=[sys.executable,"Tests/segments/core/preview/run.py",str(out/"preview")]
(out/"preview-command.json").write_text(__import__("json").dumps({"argv":preview,"cwd":str(root)}))
r=subprocess.run(preview,cwd=root,capture_output=True)
(out/"preview.stdout").write_bytes(r.stdout);(out/"preview.stderr").write_bytes(r.stderr)
(out/"preview-result.json").write_text(__import__("json").dumps({"exit_code":r.returncode}))
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
sys.exit(r.returncode)
