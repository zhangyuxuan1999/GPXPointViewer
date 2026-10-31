#!/usr/bin/env python3
"""Directed production Store tests. No app/window/network; same compilation emits stringsdata."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, signal, subprocess, uuid

p = argparse.ArgumentParser()
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--group', action='append', choices=['cache','sources','ownership','map','provenance','lifecycle','modeentry','navigation','navigation-continuation','navigation-chip'])
p.add_argument('--binary', type=Path, help='Reuse an existing compiled binary for unchanged-source directed rerun')
p.add_argument('--compile-only', action='store_true')
a = p.parse_args()
repo = Path(__file__).resolve().parents[3]
if a.binary:
    old_inputs = a.binary.parent/'inputs.json'
    old_binary_hash = a.binary.parent/'binary-sha256.json'
    if not a.binary.is_file() or not old_inputs.is_file() or not old_binary_hash.is_file():
        raise SystemExit('Binary reuse requires original inputs.json and binary-sha256.json; older evidence is not silently reassociated.')
    for entry in json.loads(old_inputs.read_text()):
        original = Path(entry['path'])
        if not original.is_file() or hashlib.sha256(original.read_bytes()).hexdigest()!=entry['sha256']:
            raise SystemExit('Binary reuse refused: source changed: '+str(original))
    if hashlib.sha256(a.binary.read_bytes()).hexdigest()!=json.loads(old_binary_hash.read_text())['sha256']:
        raise SystemExit('Binary reuse refused: binary content changed')
attempt = a.evidence / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ') + '-' + uuid.uuid4().hex[:8])
attempt.mkdir(parents=True)
source = attempt / 'compiled-source'; source.mkdir()
strings = attempt / 'stringsdata'; strings.mkdir()
manifest = []
sources = []
for path in sorted((repo/'GPXPointViewer').glob('*.swift')):
    original = path.read_bytes(); text = original.decode()
    transformations = []
    if path.name == 'GPXPointViewerApp.swift':
        text = text.replace('@main\n','',1); transformations.append('remove app @main only')
    if path.name == 'TrackStore.swift':
        text = text.replace('private(set) ', '').replace('private func ', 'func ').replace('private var ', 'var ')
        transformations.append('remove private(set), private func/private var for deterministic ownership gates and setup')
    target = source/path.name; target.write_text(text); sources.append(str(target))
    manifest.append({'path':str(path),'sha256':hashlib.sha256(original).hexdigest(),
                     'compiled_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'test_only_transformations':transformations})
test = source/'StoreRegression.swift'; test.write_bytes((Path(__file__).parent/'StoreRegression.swift').read_bytes())
manifest.append({'path':str(Path(__file__).parent/'StoreRegression.swift'),'sha256':hashlib.sha256(test.read_bytes()).hexdigest(),'test_only_transformations':[]})
(attempt/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
binary = a.binary or (attempt/'summary-store')
commands = []
if not a.binary:
    commands.append(('compile',['xcrun','swiftc','-whole-module-optimization','-parse-as-library',
        '-target','arm64-apple-macosx14.0','-module-cache-path',str(attempt/'module-cache'),
        '-module-name','SummaryStoreRegression','-emit-localized-strings','-emit-localized-strings-path',str(strings),
        *sources,str(test),'-o',str(binary)],600))
if not a.compile_only: commands.append(('run',[str(binary),*(a.group or [])],180))
for name, cmd, timeout in commands:
    (attempt/(name+'.command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
    with (attempt/(name+'.stdout.txt')).open('w') as out, (attempt/(name+'.stderr.txt')).open('w') as err:
        proc = subprocess.Popen(cmd,stdout=out,stderr=err,start_new_session=True)
        try: code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGTERM)
            try: proc.wait(timeout=0.5)
            except subprocess.TimeoutExpired: os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=2)
            code = 124
    (attempt/(name+'.result.json')).write_text(json.dumps({'exit_code':code,'command':cmd},indent=2)+'\n')
    print(json.dumps({'stage':name,'exit_code':code,'attempt':str(attempt),'binary':str(binary),'stringsdata':str(strings)}),flush=True)
    print((attempt/(name+'.stdout.txt')).read_text(),flush=True)
    if code:
        print((attempt/(name+'.stderr.txt')).read_text(),flush=True)
        raise SystemExit(code)
    if name=='compile':
        (attempt/'binary-sha256.json').write_text(json.dumps({'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()},indent=2)+'\n')
after = {x['path']:hashlib.sha256(Path(x['path']).read_bytes()).hexdigest()==x['sha256'] for x in manifest}
(attempt/'source-stability.json').write_text(json.dumps(after,indent=2)+'\n')
print('SOURCE_STABLE',all(after.values()),flush=True)
