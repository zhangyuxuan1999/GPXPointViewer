#!/usr/bin/env python3
"""批量两路并行（OSRM + Valhalla）速度与结果（联网）"""
import ui, json, time, os
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
ui.send(['open %s/Garmin_Roma_Da.gpx' % C])
for i in range(30):
    time.sleep(1); s = ui.state()
    if not s.get('loading') and s.get('points'): break
ui.send(['fill', 'batchplan', 'sleep 500', 'batchall skip'])
for i in range(8): ui.send([f'batchkind {i} road'])
t0 = time.time(); ui.send(['batchrun'])
for i in range(240):
    time.sleep(0.5); s = ui.state(); b = s['batch']
    if b['phase'] == 'preview': break
dt = time.time() - t0; items = b['items'][:8]
print(f"   8 处公路用时 {dt:.1f} s，请求 {b['requests']}；依据 {[it['method'] for it in items]}；状态 {[it['status'][:4] for it in items]}")
check(all(it['status'].startswith('done') for it in items), "P1 8 处全部成功")
check(dt < 20, f"P2 8 处 <20 s（两路并行，实际 {dt:.1f} s）")
ui.send(['batchclose'])
print("FAILS:", fails or "none")
