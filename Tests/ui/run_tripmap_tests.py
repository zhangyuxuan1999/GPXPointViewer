#!/usr/bin/env python3
"""按行程用地图判断公路/铁路（联网，单客户端）"""
import ui, json, time, os
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
ui.send(['open %s/Garmin_Roma_Da_copy.gpx' % C])
for i in range(30):
    time.sleep(1); s = ui.state()
    if not s.get('loading') and s.get('points'): break
ui.send(['fill', 'sleep 800']); t0 = time.time(); print("   ", ui.send(['tripmap']))
for i in range(240):
    time.sleep(1); s = ui.state()
    if not s['tripMapRunning']: break
print(f"   用时 {time.time()-t0:.0f} s")
for t in s['trips']: print("   ", t)
print(ui.send(['tripsamples']))
trips = s['trips']
bus = [t for t in trips if t['v95'] <= 115 and t['gaps'] >= 5]
train = [t for t in trips if t['v95'] >= 150]
check(bus and all(t['mapVerdict'] == 'road' for t in bus), f"M1 大巴段（v95≤115，{len(bus)} 段）地图判公路")
check(train and all(t['mapVerdict'] == 'rail' and t['kind'] == 'rail' for t in train), f"M2 火车段（v95≥150，{len(train)} 段）地图判铁路")
check(not any(t['mapVerdict'] == 'road' and t['v95'] >= 150 for t in trips), "M3 没有 v95≥150 的段被判成公路")
print("FAILS:", fails or "none")
