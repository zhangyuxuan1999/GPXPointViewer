#!/usr/bin/env python3
"""New summary navigation and cross-process settings evidence only.

Accepts one frozen final archive; prepares a unique sandbox-signed test identity.
Never starts/kills the installed app or writes/restores its preference domain.
This driver is prepared by the implementation task and run only by the root's
separate UI acceptance task. Native field action + Return is automated; literal
year/month/day keyboard editing and pixel verdict remain explicit visual checks.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui
from run_summary_tests import region_fixture, screen_preflight


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def navigation_fixture(path):
    # An independent ten-year jump and one full journey across midnight.
    groups = [datetime.datetime(2016, 1, 1, 12, tzinfo=datetime.timezone.utc),
              datetime.datetime(2026, 10, 16, 23, 59, tzinfo=datetime.timezone.utc)]
    segments = []
    for start, count in zip(groups, [3, 8]):
        points = []
        for i in range(count):
            stamp = (start + datetime.timedelta(seconds=i * 30)).isoformat().replace('+00:00', 'Z')
            points.append(f'<trkpt lat="0.5" lon="{0.5+i*0.0001:.6f}"><time>{stamp}</time></trkpt>')
        segments.append('<trkseg>' + ''.join(points) + '</trkseg>')
    path.write_text('<?xml version="1.0"?><gpx version="1.1" creator="summary navigation"><trk>'
                    + ''.join(segments) + '</trk></gpx>')


class Session:
    def __init__(self, app, bundle_id, work, evidence):
        self.app, self.bundle_id, self.work, self.evidence = app, bundle_id, work, evidence
        self.io = work / 'io'
        self.io.mkdir()
        ui.IO = str(self.io)
        self.counter = 0
        self.proc = None
        self.processes = []
        self.handles = []

    def command(self, value):
        self.counter += 1
        result = ui.send([value], timeout=15)
        write_json(self.evidence / f'{self.counter:03d}-hook.json', {'command': value, 'output': result})
        if result == 'TIMEOUT':
            raise RuntimeError('Hook timeout: ' + value)
        return result

    def json(self, command):
        return json.loads(self.command(command).strip().splitlines()[-1])

    def start(self, stage, language=None):
        if self.proc is not None:
            raise RuntimeError('Previous test process must exit first')
        for name in ['cmd', 'cmd.tmp', 'out.txt']:
            (self.io / name).unlink(missing_ok=True)
        env = os.environ.copy()
        env.update(GPXPV_UITEST_DIR=str(self.io), GPXPV_TEST_BUNDLE_ID=self.bundle_id,
                   GPXPV_REGIONS_BIN=str(self.work / 'regions.bin'))
        argv = [str(self.app / 'Contents/MacOS/GPXPointViewer'), '-NSQuitAlwaysKeepsWindows', 'NO']
        if language:
            argv.extend(['-AppleLanguages', '(' + language + ')'])
        write_json(self.evidence / (stage + '-launch.json'), {'argv': argv,
            'injected_env': {k: env[k] for k in ['GPXPV_UITEST_DIR', 'GPXPV_TEST_BUNDLE_ID', 'GPXPV_REGIONS_BIN']}})
        out = (self.evidence / (stage + '.stdout.txt')).open('w')
        err = (self.evidence / (stage + '.stderr.txt')).open('w')
        self.handles.extend([out, err])
        self.proc = subprocess.Popen(argv, env=env, stdout=out, stderr=err)
        self.processes.append({'stage': stage, 'pid': self.proc.pid, 'argv': argv})
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError('Owned test app exited before readiness')
            response = ui.send(['settingsstate'], timeout=1)
            with (self.evidence / (stage + '-readiness.jsonl')).open('a') as log:
                log.write(json.dumps({'command': 'settingsstate', 'output': response}) + '\n')
            if response != 'TIMEOUT':
                state = json.loads(response.strip().splitlines()[-1])
                expected_home = self.work.parents[1]
                if state['bundleID'] != self.bundle_id or Path(state['home']).resolve() != expected_home.resolve():
                    raise RuntimeError('Actual process preference domain/home does not match unique sandbox identity')
                if not language and state['argumentLanguages'] is not None:
                    raise RuntimeError('Persistence process has an AppleLanguages argument override')
                write_json(self.evidence / (stage + '-identity.json'), state)
                self.command('autotripmap 0')
                self.command('faketiles 1')
                return state
        raise RuntimeError('Test app hook did not become ready')

    def stop(self):
        if self.proc is None:
            return
        record = self.processes[-1]
        if self.proc.poll() is None:
            self.command('testquit')
            try:
                self.proc.wait(timeout=12)
                record['normal_quit'] = True
            except subprocess.TimeoutExpired:
                record['normal_quit'] = False
                raise RuntimeError('Owned test app failed to quit normally')
        record['exit_code'] = self.proc.poll()
        if record['exit_code'] != 0:
            raise RuntimeError('Owned test app exited unsuccessfully')
        self.proc = None

    def cleanup(self):
        # The only fallback target is the Popen child started by this Session.
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
            self.processes[-1].update(normal_quit=False, exit_code=self.proc.poll(), failure_cleanup=True)
        for handle in self.handles:
            handle.close()
        if (self.io / 'log.txt').exists():
            shutil.copy2(self.io / 'log.txt', self.evidence / 'hook.log.txt')
        for png in self.work.glob('*.png'):
            shutil.copy2(png, self.evidence / png.name)
        write_json(self.evidence / 'cleanup.json', {'owned_processes': self.processes,
            'isolated_bundle_id': self.bundle_id, 'isolated_work': str(self.work),
            'formal_preference_domain_accessed': False, 'formal_app_process_touched': False,
            'isolated_domain_retained_for_evidence': True})

    def wait(self, predicate):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            state = self.json('summarystate')
            if predicate(state):
                return state
            time.sleep(.2)
        raise RuntimeError('Summary state wait timed out')

    def shot(self, name):
        path = self.work / name
        self.command('summaryshot ' + str(path))
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError('Missing screenshot: ' + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--mode', choices=['navigation', 'navigation-remaining', 'visual-only', 'persistence'], default='navigation')
    parser.add_argument('--language', choices=['zh-Hans', 'en', 'de'], default='zh-Hans')
    args = parser.parse_args()
    if not os.environ.get('GPXPV_APP') or os.environ.get('GPXPV_ALLOW_UNVERIFIED_BUILD'):
        raise SystemExit('Explicit verified final GPXPV_APP archive is required')
    provenance = ui.build_provenance(os.environ['GPXPV_APP'])
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    evidence = (args.evidence / (stamp + '-' + uuid.uuid4().hex[:8])).resolve()
    evidence.mkdir(parents=True)
    write_json(evidence / 'source-build-provenance.json', provenance)
    write_json(evidence / 'execution-mode.json', {'mode': args.mode, 'language': args.language,
        'old_summary_functional_suite_executed': False,
        'functional_checks_planned': 3 if args.mode == 'navigation-remaining' else (0 if args.mode == 'visual-only' else (4 if args.mode == 'persistence' else 6)),
        'inherited_first_three_navigation_and_settings_ABC': args.mode == 'navigation-remaining',
        'keyboard_typing_verdict': 'PENDING_MANUAL_NATIVE_DATE_FIELD_CHECK',
        'pixel_verdict': 'PENDING_MAIN_AGENT_PIXEL_REVIEW'})
    if args.mode != 'persistence':
        screen_preflight(evidence)
    repo = Path(__file__).resolve().parents[2]
    local_test_root = Path(tempfile.mkdtemp(prefix='GPXPointViewer-summary-navigation-', dir='/private/tmp')).resolve()
    isolated_destination = local_test_root / 'isolated-copy'
    write_json(evidence / 'isolated-copy-paths.json', {'destination': str(isolated_destination),
        'manifest': str(isolated_destination / 'build-manifest.json'),
        'retention': 'retained local private test copy; OS may purge temporary storage'})
    argv = [sys.executable, str(repo / 'Tools/archive_build.py'), provenance['app'],
            '--prepare-isolated-test-copy', '--destination', str(isolated_destination)]
    write_json(evidence / 'prepare.command.json', argv)
    prepared = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    (evidence / 'prepare.stdout.txt').write_text(prepared.stdout)
    (evidence / 'prepare.stderr.txt').write_text(prepared.stderr)
    write_json(evidence / 'prepare.result.json', {'exit_code': prepared.returncode})
    if prepared.returncode:
        raise SystemExit('Isolated signed copy preparation failed; original archive was not launched')
    result = json.loads(prepared.stdout)
    app, bundle_id = Path(result['app']), result['test_bundle_id']
    actual_id = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    if actual_id != bundle_id or not bundle_id.startswith('de.wayne.GPXPointViewer.test.'):
        raise RuntimeError('Prepared test copy bundle identity is not isolated')
    container = Path.home() / 'Library/Containers' / bundle_id
    if container.exists():
        raise RuntimeError('Unique test identity unexpectedly already has a sandbox')
    work = container / 'Data/tmp/summary-navigation'
    work.mkdir(parents=True)
    navigation_fixture(work / 'navigation.gpx')
    region_fixture(work / 'regions.bin')
    write_json(evidence / 'fixture-manifest.json', {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in work.iterdir() if p.is_file()})
    session, checks = Session(app, bundle_id, work, evidence), []
    completed = False

    def check(name, good):
        checks.append({'name': name, 'passed': bool(good)})
        print(('PASS ' if good else 'FAIL ') + name, flush=True)
        if not good:
            raise RuntimeError('Acceptance assertion failed: ' + name)

    def date_control(y, m, d):
        response = session.command(f'summarydatecontrol {y} {m} {d}')
        if response.strip() != 'summarydatecontrol':
            raise RuntimeError('Native NSDatePicker field not found/action not delivered: ' + response)
        # Exactly one Return while the native date field owns the editor. The
        # product bridge commits its field value and submits through its callback.
        session.command('summarykey return')
        return session.wait(lambda s: s['selectedDay'] == f'{y:04d}-{m:02d}-{d:02d}')

    try:
        if args.mode == 'persistence':
            first = session.start('A')
            check('A has unique actual sandbox and no language argument', first['argumentLanguages'] is None)
            session.command('persistsettings zh-Hans 1 7 13')
            write_json(evidence / 'A-saved.json', session.json('settingsstate'))
            session.stop()
            second = session.start('B')
            check('B reads saved language and idle values across process exit', second['storedLanguage'] == 'zh-Hans'
                  and second['launchLanguage'] == 'zh-Hans' and second['persistent']['AppleLanguages'] == ['zh-Hans']
                  and second['idleDisabled'] is True and second['idleGlobeSeconds'] == 7 and second['idleMapSeconds'] == 13)
            check('B actual bundle localization reflects saved language', second['preferredLocalizations'][0] == 'zh-Hans')
            session.command('persistsettings system 0 11 17')
            write_json(evidence / 'B-saved.json', session.json('settingsstate'))
            session.stop()
            third = session.start('C')
            check('C verifies language-key removal and explicit false persisted', third['storedLanguage'] == ''
                  and third['persistent']['AppleLanguages'] is None and third['persistent']['idleDisabled'] is False
                  and third['idleDisabled'] is False and third['idleGlobeSeconds'] == 11 and third['idleMapSeconds'] == 17)
            session.stop()
        elif args.mode == 'navigation-remaining':
            # Only the three checks that were not completed in the original UI
            # run. Main day/re-entry/all semantics and settings A/B/C are inherited.
            session.start('navigation-remaining', args.language)
            session.command('open ' + str(work / 'navigation.gpx'))
            session.command('summaryzone UTC')
            session.command('summary')
            ready = session.wait(lambda s: s['ready'] and s.get('totalPoints') == 11)
            builds = ready['builds']
            session.command('summarysize 780 560')
            session.shot('choose-date-return-header.png')
            old = date_control(2016, 1, 1)
            check('Native date field plus one Return jumps ten years', bool(old['currentDay']) and old['builds'] == builds)
            session.shot('ten-year-jump.png')
            empty = date_control(2015, 1, 1)
            check('Empty date stays selected without fallback', not empty['currentDay'] and empty['currentDayJourneys'] == []
                  and empty['builds'] == builds)
            session.shot('empty-day.png')
            before = date_control(2026, 10, 16)
            session.command('summarytab journey')
            session.command('summaryjourney 0')
            journey = session.json('summarystate')
            check('Day-specific journey retains full cross-midnight metrics', len(journey['currentDayJourneys']) == 1
                  and journey['currentJourney'] == before['currentDayJourneys'][0]
                  and journey['currentJourney']['end'] > before['currentDay']['end'])
            session.command('summaryscroll top')
            session.shot('cross-midnight-journey-top.png')
            session.command('summaryscroll lower')
            session.shot('cross-midnight-journey-lower.png')
            write_json(evidence / 'manual-native-keyboard-check.json', {'status': 'PENDING',
                'instructions': 'Root must type civil year/month/day segments in the actual native field and press one Return, with no Tab or click first. Confirm selectedDay is the typed date. Also edit a segment and press View without Return to verify pending editor flush. The automated native dateValue action is not literal keyboard evidence.'})
            session.stop()
        elif args.mode == 'visual-only':
            # Readiness and setup only. Functional assertions from the Chinese
            # navigation run are inherited, never repeated for each language.
            session.start('visual-only', args.language)
            session.command('open ' + str(work / 'navigation.gpx'))
            # Import is asynchronous. Applying the main date before publication
            # lets the import clear that filter, and an empty-source summary entry
            # correctly has no submitted day. Wait for this fixture before setup.
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                loaded = session.json('state')
                if loaded.get('loading') is False and loaded.get('points') == 11:
                    break
                time.sleep(.2)
            else:
                raise RuntimeError('Navigation fixture import did not complete before visual date setup')
            session.command('summarymaindate 2026 10 16 UTC')
            session.command('summary')
            session.wait(lambda s: s['ready'] and s['selectedDay'] == '2026-10-16')
            session.command('summarysize 780 560')
            session.shot('main-selected-16.png')
            session.command('summarymainall')
            session.command('summary')
            session.wait(lambda s: s['selectedDay'] == '')
            session.shot('choose-date.png')
            if args.language == 'zh-Hans':
                date_control(2016, 1, 1)
                session.shot('ten-year-jump.png')
                date_control(2015, 1, 1)
                session.shot('empty-day.png')
            date_control(2026, 10, 16)
            session.command('summarytab journey')
            session.command('summaryjourney 0')
            session.command('summaryscroll top')
            session.shot('cross-midnight-journey-top.png')
            if args.language == 'zh-Hans':
                session.command('summaryscroll lower')
                session.shot('cross-midnight-journey-lower.png')
            session.stop()
            print('VISUAL_ONLY functional_checks=0', flush=True)
        else:
            session.start('navigation', args.language)
            session.command('open ' + str(work / 'navigation.gpx'))
            session.command('summaryzone UTC')
            session.command('summarymaindate 2026 10 16 UTC')
            session.command('summary')
            first = session.wait(lambda s: s['ready'] and s['selectedDay'] == '2026-10-16')
            check('Main October 16 opens its actual daily row', bool(first['currentDay']) and first['list'] == 'day')
            session.command('summarysize 780 560')
            session.shot('main-selected-16.png')
            builds = first['builds']
            session.command('summarymaindate 2026 10 17 UTC')
            session.command('summary')
            second = session.wait(lambda s: s['selectedDay'] == '2026-10-17')
            check('Already-open window receives October 17 without day rebuild', bool(second['currentDay'])
                  and second['builds'] == builds and second['navigationRevision'] > first['navigationRevision'])
            session.command('summarymainall')
            session.command('summary')
            unselected = session.json('summarystate')
            check('All-data entry requires explicit date confirmation', unselected['selectedDay'] == '' and not unselected['currentDay'])
            session.shot('choose-date.png')
            old = date_control(2016, 1, 1)
            check('Native date field plus Return jumps ten years', bool(old['currentDay']) and old['builds'] == builds)
            session.shot('ten-year-jump.png')
            empty = date_control(2015, 1, 1)
            check('Empty date stays selected without fallback', not empty['currentDay'] and empty['currentDayJourneys'] == []
                  and empty['builds'] == builds)
            session.shot('empty-day.png')
            before = date_control(2026, 10, 16)
            session.command('summarytab journey')
            session.command('summaryjourney 0')
            journey = session.json('summarystate')
            check('Day-specific journey retains full cross-midnight metrics', len(journey['currentDayJourneys']) == 1
                  and journey['currentJourney'] == before['currentDayJourneys'][0]
                  and journey['currentJourney']['end'] > before['currentDay']['end'])
            session.command('summaryscroll top')
            session.shot('cross-midnight-journey-top.png')
            session.command('summaryscroll lower')
            session.shot('cross-midnight-journey-lower.png')
            write_json(evidence / 'manual-native-keyboard-check.json', {'status': 'PENDING',
                'instructions': 'With no date submitted, focus the native date field and type year/month/day segments using Tab, then Return. Confirm selectedDay equals typed civil date and no other-date row appears. Use summarydatefocus/summarykey for own-window event injection or direct computer use. A native dateValue action is not evidence of literal keyboard typing.'})
            session.stop()
        completed = True
    finally:
        session.cleanup()
        write_json(evidence / 'results.json', checks)
        write_json(evidence / 'execution-result.json', {'mode': args.mode, 'completed': completed,
            'functional_checks_executed': len(checks), 'functional_checks_failed': sum(not c['passed'] for c in checks),
            'pixel_verdict': 'PENDING_MAIN_AGENT_PIXEL_REVIEW'})
        print('EVIDENCE ' + str(evidence), flush=True)
    return 0 if completed and (args.mode == 'visual-only' or (checks and all(c['passed'] for c in checks))) else 1


if __name__ == '__main__':
    raise SystemExit(main())
