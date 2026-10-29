#!/usr/bin/env python3
"""Rebuild the actual renderer and run a synthetic, windowless Metal regression.
Default reproduces frozen dependencies; --current-core selects the three live core files.
"""
import argparse,datetime,hashlib,json,subprocess,sys,tempfile,uuid
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--current-core',action='store_true')
parser.add_argument('--output',type=Path)
parser.add_argument('--build-only',action='store_true')
args=parser.parse_args()
tests=Path(__file__).resolve().parent
root=tests.parents[2]
if args.output:
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
else:
    out=Path(tempfile.mkdtemp(prefix='gpxpv-segment-render-',dir='/private/tmp'))
build=out/'build';build.mkdir()
core={'GPXParser.swift','TrackData.swift','GeoCompute.swift'}
deps=[root/'GPXPointViewer'/p.name if args.current_core and p.name in core else p for p in sorted((tests/'dependencies').glob('*.swift'))]
sources=[root/'GPXPointViewer/MetalPointRenderer.swift',tests/'main.swift',tests/'gpu-fixtures.swift',tests/'p3.swift',*deps]
manifest={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[root/'GPXPointViewer/Shaders.metal',tests/'fixtures/Shaders-before.metal']}
(out/'inputs.json').write_text(json.dumps({'core_mode':'current' if args.current_core else 'pinned','files':manifest},indent=2))
print('RESULT_DIR='+str(out),flush=True)
def execute(command,phase,timeout):
    print(phase.upper(),json.dumps([str(x) for x in command]),flush=True)
    start=datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        result=subprocess.run([str(x) for x in command],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
        code,stdout,stderr=result.returncode,result.stdout,result.stderr
    except subprocess.TimeoutExpired as exc:
        code,stdout,stderr=124,exc.stdout or b'',exc.stderr or b''
    (out/(phase+'-stdout.txt')).write_bytes(stdout);(out/(phase+'-stderr.txt')).write_bytes(stderr)
    record={'argv':[str(x) for x in command],'started_utc':start,'finished_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exit_code':code}
    (out/(phase+'-command.json')).write_text(json.dumps(record,indent=2))
    sys.stdout.buffer.write(stdout);sys.stderr.buffer.write(stderr)
    sys.stdout.flush();sys.stderr.flush()
    return code
command=['swiftc','-O','-D','GPXPV_SEGMENT_RENDER_TESTS','-D','GPXPV_METAL_COLOR_TESTS','-module-cache-path',build/'ModuleCache','-o',build/'segment-render',*sources]
code=execute(command,'compile',180)
if code or args.build_only:sys.exit(code)
command=[build/'segment-render',root/'GPXPointViewer/Shaders.metal',tests/'fixtures/Shaders-before.metal',out/'gpu-images']
code=execute(command,'gpu',30)
(out/'result.json').write_text(json.dumps({'exit_code':code,'gpu_available':code!=77,'passed':code==0,'core_mode':'current' if args.current_core else 'pinned'},indent=2))
sys.exit(code)
