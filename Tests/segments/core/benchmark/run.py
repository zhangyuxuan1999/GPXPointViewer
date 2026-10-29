import subprocess,pathlib,sys,json
root=pathlib.Path(__file__).resolve().parents[4]
run=pathlib.Path(sys.argv[1]);out=run/"artifacts"/(sys.argv[2] if len(sys.argv)>2 else "benchmark");out.mkdir(exist_ok=True)
for name in ["baseline","current"]:
 base=run/"artifacts/before" if name=="baseline" else root
 sources=[str(root/"Tests/segments/core/benchmark/main.swift"),str(root/"Tests/segments/core/Support.swift")]+[str(base/"GPXPointViewer"/s) for s in ["GPXParser.swift","TrackData.swift","GeoCompute.swift"]]+[str(root/"GPXPointViewer"/s) for s in ["Colormaps.swift","L10nSupport.swift"]]
 cmd=["swiftc","-O","-module-cache-path",str(out/"module-cache"),"-o",str(out/name)]+(["-DSEGMENT_TOPOLOGY"] if name=="current" else [])+sources
 (out/(name+"-command.json")).write_text(json.dumps(cmd,indent=2))
 r=subprocess.run(cmd,cwd=root,capture_output=True);(out/(name+"-build.stdout")).write_bytes(r.stdout);(out/(name+"-build.stderr")).write_bytes(r.stderr)
 if r.returncode:sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
 r=subprocess.run([str(out/name)],cwd=root,capture_output=True);(out/(name+".stdout")).write_bytes(r.stdout);(out/(name+".stderr")).write_bytes(r.stderr);(out/(name+"-exit.txt")).write_text(str(r.returncode));print(name);sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
 if r.returncode:sys.exit(r.returncode)
