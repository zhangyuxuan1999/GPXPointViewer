#!/usr/bin/env python3
"""范围圈选/反选、只补公路、批量速度（最后一项联网：3 处公路）"""
import ui, json, time, os, re
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
data = open(C + '/Garmin_Roma_Da.gpx').read()
pts = re.findall(r'<trkpt lat="([^"]+)" lon="([^"]+)"', data)
la, lo = float(pts[1674][0]), float(pts[1674][1]); lb, lob = float(pts[1680][0]), float(pts[1680][1])
ui.send(['open %s/Garmin_Roma_Da.gpx' % C])
for i in range(30):
    time.sleep(1); s = ui.state()
    if not s.get('loading') and s.get('points'): break
ui.send(['fill', 'sleep 800']); s = ui.state(); print("   candidates", s['candidates'], "filtered", s['filtered'], "roadOnly", s['roadOnly'])
box = f"{min(la,lb)-0.01},{min(lo,lob)-0.01};{min(la,lb)-0.01},{max(lo,lob)+0.01};{max(la,lb)+0.01},{max(lo,lob)+0.01};{max(la,lb)+0.01},{min(lo,lob)-0.01}"
r = ui.send(['region ' + box]); print("   ", r); s = ui.state()
check(s['region'] == 4 and 1 <= s['filtered'] <= 3, f"G1 圈选 gap0 周围 → 只剩 {s['filtered']} 处")
n_in = s['filtered']
ui.send(['regioninvert 1']); s = ui.state()
check(s['filtered'] == s['candidates'] - n_in, f"G2 反选 → {s['filtered']} 处")
ui.send(['regioninvert 0', 'batchplan', 'sleep 500']); s = ui.state(); b = s['batch']
check(b and len(b['items']) == n_in, f"G3 批量只对圈内 {len(b['items']) if b else None} 处分类")
ui.send(['batchclose', 'region clear']); s = ui.state()
check(s['region'] == 0 and s['filtered'] == s['candidates'], "G4 清除范围后恢复全部")
ui.send(['roadonly 1', 'batchplan', 'sleep 500']); s = ui.state(); items = s['batch']['items']
check(all(it['kind'] == 'skip' for it in items if it['auto'] == 'rail') and s['roadOnly'], "G5 只补公路：疑似铁路默认跳过")
ui.send(['batchall skip'])
for i in range(3): ui.send([f'batchkind {i} road'])
t0 = time.time(); ui.send(['batchrun'])
for i in range(120):
    time.sleep(0.5); s = ui.state(); b = s['batch']
    if b['phase'] == 'preview': break
dt = time.time() - t0
print(f"   3 处公路用时 {dt:.1f} s，请求 {b['requests']}，依据 {[it['method'] for it in b['items'][:3]]}")
check(dt < 15 and all(it['status'].startswith('done') for it in b['items'][:3]), "G6 批量 3 处 <15 s（上下文优先）")
ui.send(['batchclose'])
print("FAILS:", fails or "none")
