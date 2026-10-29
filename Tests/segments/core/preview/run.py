import pathlib,subprocess,sys,json
root=pathlib.Path(__file__).resolve().parents[4]
out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
baseline="--baseline" in sys.argv
cmd=["swiftc","-O","-module-cache-path",str(out/"module-cache"),"-o",str(out/"preview-tests")]+([] if baseline else ["-DPREVIEW_PLAN"])+["Tests/segments/core/preview/main.swift","GPXQuickLook/TrackShape.swift"]
for name,argv in [("build",cmd),("pixels",[str(out/"preview-tests"),str(out)])]:
 (out/(name+"-command.json")).write_text(json.dumps({"argv":argv,"cwd":str(root)},indent=2));r=subprocess.run(argv,cwd=root,capture_output=True);(out/(name+".stdout")).write_bytes(r.stdout);(out/(name+".stderr")).write_bytes(r.stderr);(out/(name+"-result.json")).write_text(json.dumps({"exit_code":r.returncode}));sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr)
 if r.returncode:sys.exit(r.returncode)
