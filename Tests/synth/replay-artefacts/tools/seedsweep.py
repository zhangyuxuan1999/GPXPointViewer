# Robustness probe (not part of the family's checks): regenerate a scenario with seeds 7919*1..N, run
# ../../runner/synthrunner on each, print one tuple per seed. Usage: python3 -I seedsweep.py <a|a2|g|b|b2|c|c2|d|e|e2|f|h|i|j> [N]
# Temporary data goes to tools/tmp and is deleted afterwards (check.py would otherwise pick it up).
import json, math, os, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
FAM = os.path.dirname(HERE)
sys.path.insert(0, FAM)
import gen
RUNNER = os.path.join(os.path.dirname(FAM), 'runner', 'synthrunner')
TMP = os.path.join(HERE, 'tmp')
os.makedirs(TMP, exist_ok=True)
os.chdir(TMP)

def run(fn):
    out = subprocess.run([RUNNER, fn], capture_output=True, text=True).stdout
    return json.loads(out.strip().splitlines()[-1])

def iou(a0, a1, b0, b1):
    inter = max(0, min(a1, b1) - max(a0, b0)); uni = max(a1, b1) - min(a0, b0)
    return inter / uni if uni > 0 else 0

def best(r, a, b):
    return max([iou(a, b, c['tA'], c['tB']) for c in r['jitter']] or [0])

car = gen.Path(46.8000, 9.8000, math.radians(30), [(0.60, 900.0, 0.0), (0.30, 300.0, 1.0)], 40000.0)
rail = gen.Path(31.0000, 119.8000, math.radians(10), [(0.20, 3500.0, 0.0), (0.10, 1300.0, 2.0)], 80000.0)
which = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20
res = []
for seed in range(1, N + 1):
    t0 = gen.epoch(2026, 7, 4, 9, 0)
    if which == 'c':
        recs, m = gen.phone_segments(seed * 7919, t0, car, 200.0, lambda k: 25.0 + 2.0 * math.sin(k / 60.0),
                                     [('live', 300, {}), ('pp', 120, {'offB': 1000.0, 'runs': (1, 3)}), ('live', 300, {})])
        gen.write_csv('x.csv', recs); r = run('x.csv'); a, b = m['seg'][1][1], m['seg'][1][2]
        res.append((len(r['jitter']), round(best(r, a, b), 2)))
    elif which in ('b', 'b2'):
        recs, m = gen.phone_interleave(seed * 7919, t0, identical=(which == 'b'))
        gen.write_csv('x.csv', recs); r = run('x.csv')
        res.append((r['replays'], m['E'], len(r['jitter']), round(best(r, m['T1'], m['T2']), 2)))
    elif which in ('a', 'a2', 'g'):
        recs, m = gen.explore_sweep(seed * 7919, t0, 'triangle' if which != 'a2' else 'sawtooth', perturb=(which != 'a'))
        gen.write_gpx('x.gpx', 'Garmin Explore', 'x', recs); r = run('x.gpx')
        res.append((r['replays'], r['gaps'], len(r['jitter']), round(best(r, m['T_loss'], m['T_resume']), 2),
                    min([c['tA'] for c in r['jitter']] or [0]) - m['T_loss']))
    elif which in ('e', 'e2'):
        recs, m = gen.device_outlier(seed * 7919, t0, 'side' if which == 'e' else 'behind')
        gen.write_gpx('x.gpx', 'eTrex 32x', 'x', recs); r = run('x.gpx')
        res.append((len(r['jitter']), round(best(r, m['T_out'] - 1, m['T_out'] + 1), 2)))
    elif which == 'd':
        recs, m = gen.phone_cochem(seed * 7919, t0)
        gen.write_csv('x.csv', recs); r = run('x.csv')
        res.append((len(r['jitter']), [c['tA'] - m['T_snap'] for c in r['jitter']], r['gaps'], r['replays']))
    elif which == 'f':
        recs, m = gen.phone_station(seed * 7919, t0)
        gen.write_csv('x.csv', recs); r = run('x.csv')
        res.append((r['replays'], len(r['jitter']), r['gaps'], m['max_step_m']))
    elif which == 'h':
        recs, m = gen.phone_sweep_10s(seed * 7919, t0)
        gen.write_csv('x.csv', recs); r = run('x.csv')
        res.append((r['replays'], m['R'], len(r['jitter']), r['gaps']))
    elif which == 'i':
        recs, m = gen.phone_segments(seed * 7919, t0, car, 300.0, lambda k: 25.0 + 1.5 * math.sin(k / 50.0),
                                     [('live', 300, {}), ('hole', 40, {}),
                                      ('pp', 90, {'offB': -800.0, 'runs': (1, 3), 'first': 'P'}), ('live', 300, {})])
        gen.write_csv('x.csv', recs); r = run('x.csv'); a, b = m['seg'][2][1], m['seg'][2][2]
        res.append((r['gaps'], len(r['jitter']), round(best(r, a, b), 2), r['candidates']))
    elif which == 'j':
        recs, m = gen.phone_segments(seed * 7919, t0, rail, 500.0, lambda k: 30.0 + 2.0 * math.sin(k / 70.0),
                                     [('live', 300, {}), ('pp', 1200, {'offB': 1200.0, 'runs': (1, 4)}), ('live', 300, {})])
        gen.write_csv('x.csv', recs); r = run('x.csv'); a, b = m['seg'][1][1], m['seg'][1][2]
        cov = sum(max(0, min(b, c['tB']) - max(a, c['tA'])) for c in r['jitter'])
        out_of = [c for c in r['jitter'] if c['tA'] < a - 10 or c['tA'] > b + 30]
        res.append((len(r['jitter']), round(cov / (b - a), 2), len(out_of), r['gaps'], r['replays']))
    elif which == 'c2':
        recs, m = gen.phone_segments(seed * 7919, t0, car, 200.0, lambda k: 25.0 + 2.0 * math.sin(k / 60.0),
                                     [('live', 300, {}), ('pp', 120, {'offB': 1000.0, 'runs': (1, 3), 'identical': True}), ('live', 300, {})])
        gen.write_csv('x.csv', recs); r = run('x.csv'); a, b = m['seg'][1][1], m['seg'][1][2]
        out_of = [c for c in r['jitter'] if c['tA'] < a - 10 or c['tA'] > b + 30]
        res.append((r['replays'], len(r['jitter']), round(best(r, a, b), 2), len(out_of)))
print(which, res)
os.chdir(HERE)
shutil.rmtree(TMP, ignore_errors=True)
