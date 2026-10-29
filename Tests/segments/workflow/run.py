#!/usr/bin/env python3
"""Compile current complete product Swift into an offline command-line test main.
Only @main and private access are changed in archived test copies. Algorithms are
compiled in full, not reimplemented. No NSApplication, app launch or route network.
"""
from pathlib import Path
import argparse,tempfile,datetime,uuid,subprocess,os,signal,json,hashlib
parser=argparse.ArgumentParser();parser.add_argument('--source-dir',type=Path,required=True);parser.add_argument('--evidence',type=Path,required=True);parser.add_argument('--repository',type=Path,required=True);a=parser.parse_args()
a.evidence.mkdir(parents=True,exist_ok=True)
work=Path(tempfile.mkdtemp(prefix='gpxpv-workflow-',dir='/private/tmp'));attempt=a.evidence/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')+'-'+uuid.uuid4().hex[:8]);attempt.mkdir()
copy=attempt/'compiled-source';copy.mkdir();sources=[];manifest={}
for path in sorted(a.source_dir.glob('*.swift')):
 text=path.read_text();manifest[path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
 if path.name=='GPXPointViewerApp.swift':text=text.replace('@main\n','',1)
 if path.name in {'TrackStore.swift','UITestHook.swift'}:text=text.replace('private func ','func ').replace('private weak var store:','weak var store:')
 target=copy/path.name;target.write_text(text);sources.append(target)
legacy=(a.source_dir/'GapFill.swift').read_text();a0=legacy.index('enum StaleRetime {');b0=legacy.index('enum GapSplice {',a0);wr=legacy.index('extension StaleRetime {');legacyText=legacy[a0:b0]+legacy[wr:];legacyText=legacyText.replace('StaleRetime','LegacyStaleRetime')
legacyText=legacyText.replace('            let nextIndex = kept.last?.index ?? ib\n            let meters = GeoMath.haversine(track.lat[k], track.lon[k], track.lat[nextIndex], track.lon[nextIndex])\n            if GapDetector.isBreakStep(dt: nextT - t, meters: meters) { break }\n','')
legacyFile=copy/'LegacyRetime.swift';legacyFile.write_text('import Foundation\nimport CoreLocation\n'+legacyText);sources.append(legacyFile)
manifest['test-main']=hashlib.sha256((Path(__file__).parent/'WorkflowRegression.swift').read_bytes()).hexdigest()
(attempt/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
test=copy/'WorkflowRegression.swift';test.write_bytes((Path(__file__).parent/'WorkflowRegression.swift').read_bytes())
cmd=['xcrun','swiftc','-whole-module-optimization','-target','arm64-apple-macosx14.0','-module-cache-path',str(a.source_dir.parent/'.b-module-cache'),'-module-name','WorkflowRegression',*[str(s) for s in sources],str(test),'-o',str(work/'workflow-regression')]
for label,args in [('compile',cmd),('run',[str(work/'workflow-regression'),str(attempt/'fixtures'),str(a.repository)])]:
 p=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try:out,err=p.communicate(timeout=300 if label=='compile' else 180);code=p.returncode
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM)
  try:out,err=p.communicate(timeout=3)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate()
  code=124
 for channel,text in [('stdout',out),('stderr',err)]: (attempt/(label+'.'+channel+'.txt')).write_text(text)
 (attempt/(label+'.result.json')).write_text(json.dumps({'command':args,'exit_code':code,'work_dir':str(work)},indent=2)+'\n')
 print(json.dumps({'stage':label,'exit_code':code,'evidence':str(attempt)},ensure_ascii=False),flush=True)
 if code:print((out+err)[-12000:]);raise SystemExit(code)
 if label=='run':print(out)
print('source hashes unchanged:',all(hashlib.sha256((a.source_dir/name).read_bytes()).hexdigest()==h for name,h in manifest.items() if name!='test-main'))
