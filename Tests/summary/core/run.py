#!/usr/bin/env python3
"""Production-engine only: unique logs, immutable inputs, per-case filtering."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time
import uuid
from fixtures import create

ROOT = Path(__file__).resolve().parents[3]
SOURCES = ['GPXPointViewer/RegionIndex.swift', 'GPXPointViewer/JourneySummary.swift',
           'Tests/summary/core/main.swift']
INPUTS = SOURCES + ['Tests/summary/core/run.py', 'Tests/summary/core/fixtures.py']


def hashes():
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in INPUTS}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--binary', type=Path, help='Reuse binary only when its input manifest exactly matches.')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('cases', nargs='*')
    args = parser.parse_args()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    output = args.output_root.resolve() / (stamp + '_' + uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    before = hashes()
    (output / 'input-sha256.json').write_text(json.dumps(before, indent=2) + '\n')
    for name in INPUTS:
        target = output / 'source' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
    result = {'directory': str(output), 'inputSHA256': before, 'environment': {
        'platform': platform.platform(), 'machine': platform.machine(), 'python': platform.python_version()}, 'commands': []}
    def command(label, argv, env=None):
        started = time.monotonic()
        with (output / (label + '.stdout.log')).open('wb') as stdout, (output / (label + '.stderr.log')).open('wb') as stderr:
            process = subprocess.run(argv, cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=300)
        receipt = {'label': label, 'argv': list(map(str, argv)), 'exitCode': process.returncode,
                   'wallSeconds': time.monotonic() - started}
        result['commands'].append(receipt)
        print(json.dumps(receipt), flush=True)
        return process.returncode
    command('compiler-version', ['swiftc', '--version'])
    if args.binary:
        binary = args.binary.resolve()
        recorded = json.loads((binary.parent / 'input-sha256.json').read_text())
        if before != recorded:
            raise SystemExit('Refusing stale binary: source/test input manifest changed')
        result['reusedBinary'] = str(binary)
    else:
        binary = output / 'summary-probe'
        code = command('compile', ['swiftc', '-O', '-module-cache-path', str(output / 'module-cache'), '-o', str(binary)] + [str(ROOT / name) for name in SOURCES])
        if code:
            result.update(status='compile-failed', exitCode=code)
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            print('ARTIFACT=' + str(output)); return code
    result['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    fixture = output / 'nested-regions.bin'
    create(fixture)
    result['fixtureSHA256'] = hashlib.sha256(fixture.read_bytes()).hexdigest()
    code = 0
    if not args.build_only:
        env = dict(os.environ, SUMMARY_REGION_FIXTURE=str(fixture))
        code = command('cases', [str(binary)] + args.cases, env=env)
        records = []
        for line in (output / 'cases.stdout.log').read_text().splitlines():
            records.append(json.loads(line))
        result['cases'] = records
        result['passed'] = sum(row.get('status') == 'passed' for row in records)
        result['failed'] = sum(row.get('status') == 'failed' for row in records)
    after = hashes()
    result['inputSHA256After'] = after
    if before != after:
        code = code or 3
        result['inputChangedDuringRun'] = True
    result.update(status='passed' if code == 0 else 'failed', exitCode=code)
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('ARTIFACT=' + str(output)); print('BINARY=' + str(binary))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
