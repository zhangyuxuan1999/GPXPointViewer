#!/usr/bin/env python3
"""Bounded summary-only smoke. Root executes once against a frozen GPXPV_APP archive.
Creates one unique copy/IO dir, owns its direct child process, preserves preference
bytes, never kills any pre-existing/formal app, and never uses public routing.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, plistlib, shutil, struct, subprocess, sys, time, uuid
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui

def screen_preflight(evidence):
    """Read NSWorkspace only; no Apple Events, screen wake or login interaction."""
    probe = (
        "ObjC.import('AppKit'); "
        "var app=$.NSWorkspace.sharedWorkspace.frontmostApplication; "
        "JSON.stringify({bundleIdentifier:ObjC.unwrap(app.bundleIdentifier)||'',"
        "name:ObjC.unwrap(app.localizedName)||''});"
    )
    argv=['/usr/bin/osascript','-l','JavaScript','-e',probe]
    record={'argv':argv,'status':'unknown','timeout_seconds':4}
    try:
        result=subprocess.run(argv,capture_output=True,text=True,timeout=4)
        record.update(exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr)
        if result.returncode==0:
            front=json.loads(result.stdout.strip());record['frontmost']=front
            locked=front.get('bundleIdentifier')=='com.apple.loginwindow' or front.get('name','').lower()=='loginwindow'
            record['status']='known_locked' if locked else 'not_known_locked'
    except subprocess.TimeoutExpired as error:
        def output(value): return value.decode(errors='replace') if isinstance(value,bytes) else value or ''
        record.update(status='query_timeout',stdout=output(error.stdout),stderr=output(error.stderr))
    except (OSError,ValueError) as error:
        record.update(status='query_unavailable',error=str(error))
    (evidence/'screen-preflight.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
    if record['status']=='known_locked':
        raise SystemExit('Visual capture blocked before app launch: loginwindow is frontmost. Unlock before screenshot-only recovery.')

def region_fixture(path):
    """Two nested rectangles, one long multilingual country and one subdivision."""
    names = [
        ("用于摘要布局检查的名称很长的示例国家与地区","A deliberately long example country and region name for summary layout",
         "Ein absichtlich sehr langer Beispielname eines Landes und Gebietes für die Zusammenfassung","用於摘要版面檢查的名稱很長的範例國家與地區"),
        ("示例行政区","Example administrative region","Beispiel eines Verwaltungsgebietes","範例行政區")]
    pool = bytearray(); offsets = []
    for group in names:
        current = []
        for name in group: current.append(len(pool)); pool.extend(name.encode()+b'\0')
        offsets.append(current)
    rings = [[(0,0),(0,2_000_000),(2_000_000,2_000_000),(2_000_000,0)]]*2
    out = bytearray(b'RGN1'+struct.pack('<IIIII',1,2,2,8,360*180))
    for i in range(2):
        out.extend(struct.pack('<HBH2sfffffIHIIII',i,i,0xFFFF if i==0 else 0,b'AA' if i==0 else b'  ',
                               100.0,0.0,0.0,2.0,2.0,i,1,*offsets[i]))
    for i in range(2): out.extend(struct.pack('<IIBffff',i*4,4,0,0,0,2,2))
    for ring in rings:
        for lat,lon in ring: out.extend(struct.pack('<ii',lat,lon))
    listing = []
    for y in range(180):
        for x in range(360):
            ids = [1,0] if 89 <= y <= 92 and 179 <= x <= 182 else []
            out.extend(struct.pack('<IH',len(listing),len(ids)));listing.extend(ids)
    out.extend(struct.pack('<I',len(listing)))
    for value in listing: out.extend(struct.pack('<H',value))
    out.extend(struct.pack('<I',len(pool)));out.extend(pool);path.write_bytes(out)

def fixture(path, count, untimed=False, start=None):
    start = start or datetime.datetime(2026,1,1,23,58,tzinfo=datetime.timezone.utc)
    points = []
    for i in range(count):
        stamp = start + datetime.timedelta(seconds=30*i+(2000 if i>=8 else 0))
        element = "" if untimed else "<time>"+stamp.isoformat().replace("+00:00","Z")+"</time>"
        points.append(f'<trkpt lat="0.5" lon="{0.5+i*0.0001:.6f}">{element}</trkpt>')
    path.write_text('<?xml version="1.0"?><gpx version="1.1" creator="summary smoke"><trk><trkseg>'+''.join(points)+'</trkseg></trk></gpx>')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence',type=Path,required=True)
    parser.add_argument('--language',choices=['zh-Hans','en','de','zh-Hant'],default='zh-Hans')
    parser.add_argument('--visual-only',action='store_true',help='Only fixture readiness and top/lower pixels; do not repeat functional checks')
    parser.add_argument('--visual-extras',action='store_true',help='With --visual-only in zh-Hans, also capture main chip and untimed state; zero functional checks')
    parser.add_argument('--layout-only',action='store_true',help='With --visual-only, capture only daily top and journey lower; zero functional checks')
    parser.add_argument('--fwdb',type=Path,help='Optional explicitly supplied existing archive to copy into fixture dir')
    args = parser.parse_args()
    if args.layout_only and not args.visual_only:
        parser.error('--layout-only requires --visual-only')
    if args.layout_only and args.visual_extras:
        parser.error('--layout-only is incompatible with --visual-extras')
    if args.visual_extras and not args.visual_only:
        parser.error('--visual-extras requires --visual-only')
    if args.visual_extras and args.language!='zh-Hans':
        parser.error('--visual-extras is reserved for zh-Hans; en/de use --visual-only')
    if not os.environ.get('GPXPV_APP'): raise SystemExit('Explicit GPXPV_APP is required')
    if os.environ.get('GPXPV_ALLOW_UNVERIFIED_BUILD'): raise SystemExit('Summary acceptance requires verified source/bundle manifest')
    provenance = ui.build_provenance(os.environ['GPXPV_APP'])
    # Historical full-suite/visual driver may only receive a separately prepared
    # test identity. Copying the formal bundle ID shares its sandbox preferences.
    bundle_id = plistlib.loads((Path(provenance['app'])/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    if not bundle_id.startswith('de.wayne.GPXPointViewer.test.') or os.environ.get('GPXPV_TEST_BUNDLE_ID') != bundle_id:
        raise SystemExit('Prepare an isolated signed test copy with Tools/archive_build.py --prepare-isolated-test-copy; set GPXPV_TEST_BUNDLE_ID to its actual unique ID.')
    evidence = args.evidence/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')+'-'+uuid.uuid4().hex[:8])
    evidence.mkdir(parents=True)
    (evidence/'build-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    (evidence/'execution-mode.json').write_text(json.dumps({'visual_only':args.visual_only,'visual_extras':args.visual_extras,'layout_only':args.layout_only,
        'functional_checks_planned':0 if args.visual_only else 12+(1 if args.fwdb else 0)},indent=2)+'\n')
    screen_preflight(evidence)
    sandbox = Path.home()/'Library/Containers'/bundle_id/'Data'
    work = sandbox/'tmp'/('summary-smoke-'+uuid.uuid4().hex)
    work.mkdir(parents=True);io=work/'io';io.mkdir();ui.IO=str(io)
    fixture(work/'A.gpx',12);fixture(work/'B.gpx',5);fixture(work/'untimed.gpx',3,True)
    fixture(work/'single-day.gpx',12,start=datetime.datetime(2026,1,2,12).astimezone().astimezone(datetime.timezone.utc))
    region_fixture(work/'regions.bin')
    (evidence/'fixture-manifest.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in work.iterdir() if p.is_file()},indent=2)+'\n')
    if args.fwdb:
        shutil.copytree(args.fwdb,work/'supplied.fwdb')
    copy = evidence/'app.noindex/GPXPointViewer.app';copy.parent.mkdir()
    shutil.copytree(provenance['app'],copy,symlinks=True)
    prefs = sandbox/'Library/Preferences'/(bundle_id+'.plist')
    before = prefs.read_bytes() if prefs.exists() else None
    if before is not None: (evidence/'preferences-before.plist').write_bytes(before)
    results=[];counter=0;proc=None
    def command(text):
        nonlocal counter
        counter+=1;out=ui.send([text],timeout=15)
        (evidence/f'{counter:03d}-hook.json').write_text(json.dumps({'command':text,'output':out},ensure_ascii=False,indent=2)+'\n')
        if out == 'TIMEOUT': raise RuntimeError('Hook timeout: '+text)
        return out
    def state(): return json.loads(command('summarystate').strip().splitlines()[-1])
    def image(name, main_window=False):
        path=work/name
        response=command(('shot ' if main_window else 'summaryshot ')+str(path))
        if not path.is_file() or path.stat().st_size==0:
            raise RuntimeError('Expected screenshot missing: '+name+'; '+response)
    def wait(predicate,timeout=35):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            value=state()
            if predicate(value):return value
            time.sleep(.2)
        raise RuntimeError('Summary state wait timed out')
    def check(name,ok):
        results.append({'name':name,'passed':bool(ok)})
        print(('PASS ' if ok else 'FAIL ')+name,flush=True)
    try:
        env=os.environ.copy();env.update(GPXPV_UITEST_DIR=str(io),GPXPV_REGIONS_BIN=str(work/'regions.bin'))
        argv=[str(copy/'Contents/MacOS/GPXPointViewer'),'-AppleLanguages',f'({args.language})','-NSQuitAlwaysKeepsWindows','NO']
        (evidence/'launch.json').write_text(json.dumps({'argv':argv,'injected_env':{k:env[k] for k in ['GPXPV_UITEST_DIR','GPXPV_REGIONS_BIN']}},indent=2)+'\n')
        stdout=(evidence/'app.stdout.txt').open('w');stderr=(evidence/'app.stderr.txt').open('w')
        proc=subprocess.Popen(argv,env=env,stdout=stdout,stderr=stderr)
        deadline=time.monotonic()+35
        while not (io/'out.txt').exists() and time.monotonic()<deadline:
            if proc.poll() is not None:raise RuntimeError('Owned app exited before readiness')
            response=ui.send(['state'],timeout=1)
            with (evidence/'launch-readiness.jsonl').open('a') as log:
                log.write(json.dumps({'command':'state','output':response})+'\n')
            if response!='TIMEOUT':break
        identity=json.loads(command('settingsstate').strip().splitlines()[-1])
        if identity['bundleID']!=bundle_id or Path(identity['home']).resolve()!=sandbox.resolve():
            raise RuntimeError('Actual test process is not using its isolated preference domain/container')
        command('autotripmap 0');command('faketiles 1');command('summary')
        if not args.visual_only:
            check('empty state is honest',not state()['ready'])
            # Regression for the legacy multi-day outer ContentView guard.
            command('open '+str(work/'single-day.gpx'));command('summaryzone UTC')
            wait(lambda s:s.get('ready') and s.get('totalPoints')==12)
            command('summarymap journey 0')
            chip=wait(lambda s:s.get('filterChipRendered'))
            check('single local day renders actual chip and keeps last point',chip['filterChip'] and chip['filterPoints']==8)
            image('single-day-main-chip.png',main_window=True)
            command('summaryfilter off')
            check('single-day chip clear restores full input',not state()['filterChip'] and state()['filterPoints']==12)
        command('open '+str(work/'A.gpx'));command('summaryzone UTC')
        one=wait(lambda s:s.get('ready') and s.get('totalPoints')==12)
        if not args.visual_only:
            check('daily and journey reports ready',len(one['days'])==2 and len(one['journeys'])==2)
        baseline=json.loads(command('state').strip().splitlines()[-1]).get('netRequests')
        command('summarysize 780 560')
        command('summaryscroll top');time.sleep(.3)
        image('daily-top.png')
        if not args.layout_only:
            command('summaryscroll lower');time.sleep(.3)
            image('daily-lower.png')
        command('summarytab journey');command('summarymode 0 water')
        if not args.visual_only:
            manual=state();check('manual mode shown without rebuild',manual['journeys'][0]['manual']=='water' and manual['builds']==one['builds'])
        if not args.layout_only:
            command('summaryscroll top');time.sleep(.3)
            image('journey-top.png')
        command('summaryscroll lower');time.sleep(.3)
        image('journey-lower.png')
        if args.visual_only:
            if args.visual_extras:
                # Display-only recovery: preserve the already-passed functional
                # evidence. Setup/readiness is not another assertion sequence.
                command('open '+str(work/'single-day.gpx'));command('summaryzone UTC')
                wait(lambda s:s.get('ready') and s.get('totalPoints')==12)
                command('summarymap journey 0')
                wait(lambda s:s.get('filterChipRendered'))
                image('single-day-main-chip.png',main_window=True)
                command('summaryfilter off')
                command('open '+str(work/'untimed.gpx'))
                wait(lambda s:s.get('ready') and s.get('undatedPoints')==3)
                image('untimed.png')
            print('VISUAL_ONLY functional_checks=0',flush=True)
            command('summaryclose')
            return 0
        command('summarymap journey 0');mapped=state()
        check('map chip and inclusive final point',mapped['filterChip'] and mapped['filterEnd']>mapped['journeys'][0]['end'] and mapped['filterPoints']==8)
        command('summaryfilter off');check('chip clear restores all points',not state()['filterChip'] and state()['filterPoints']==12)
        command('summarydisplay overlay');command('open '+str(work/'B.gpx'))
        wait(lambda s:len(s.get('sources',[]))==2 and s.get('ready'))
        command('summarysource 1');overlay=wait(lambda s:s.get('ready') and s.get('totalPoints')==5)
        check('overlay selects actual source and disables map',bool(overlay['mapDisabled']))
        command('summarydisplay compare');compared=wait(lambda s:s.get('ready') and s.get('totalPoints')==5)
        check('compare source remains independent',bool(compared['mapDisabled']))
        command('summaryclear');check('clear removes old report',not state()['ready'])
        command('open '+str(work/'untimed.gpx'));unknown=wait(lambda s:s.get('ready'))
        check('untimed state does not invent dates',unknown['undatedPoints']==3 and unknown['days']==[])
        image('untimed.png')
        if args.fwdb:
            command('open '+str(work/'supplied.fwdb'));archive=wait(lambda s:s.get('fwdb'))
            check('fwdb disables temporal summary',not archive['ready'])
        final=json.loads(command('state').strip().splitlines()[-1]).get('netRequests')
        check('summary did not request routing/geocoding',baseline==final)
        command('summaryclose')
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=8)
            except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=3)
        changed=(prefs.read_bytes() if prefs.exists() else None)!=before
        if before is None:
            if prefs.exists():prefs.unlink()
        else:
            prefs.parent.mkdir(parents=True,exist_ok=True)
            temp=prefs.with_name(prefs.name+'.summary-restore');temp.write_bytes(before);os.replace(temp,prefs)
        restored=(prefs.read_bytes() if prefs.exists() else None)==before
        for image in work.glob('*.png'):shutil.copy2(image,evidence/image.name)
        if (io/'log.txt').exists():shutil.copy2(io/'log.txt',evidence/'hook.log.txt')
        (evidence/'cleanup.json').write_text(json.dumps({'owned_pid':proc.pid if proc else None,'owned_process_exit':proc.poll() if proc else None,
            'preferences_changed':changed,'preferences_exact_bytes_restored':restored,'fixture_work':str(work),'no_formal_app_process_killed':True},indent=2)+'\n')
        (evidence/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
        (evidence/'execution-mode.json').write_text(json.dumps({'visual_only':args.visual_only,'visual_extras':args.visual_extras,'layout_only':args.layout_only,
            'functional_checks_executed':len(results)},indent=2)+'\n')
        print('EVIDENCE',evidence,flush=True)
        if not restored:raise RuntimeError('Preference bytes could not be restored')
    return 0 if args.visual_only or (results and all(x['passed'] for x in results)) else 1
if __name__=='__main__':sys.exit(main())
