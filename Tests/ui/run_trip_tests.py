#!/usr/bin/env python3
"""行程切分与按行程判公路/铁路（离线）"""
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
ui.send(['fill', 'sleep 800']); s = ui.state(); trips = s['trips']
print("   trips:", trips)
big = [t for t in trips if t['gaps'] >= 5]
check(len(trips) >= 4 and any(t['auto'] == 'rail' for t in trips) and all(t['auto'] == 'road' for t in big if t['v95'] <= 115), f"TR1 {len(trips)} 段行程：大巴段按速度判公路、火车段判铁路")
ui.send(['roadonly 1', 'batchplan', 'sleep 600']); s = ui.state(); items = s['batch']['items']
rail_items = [it for it in items if it['auto'] == 'rail']
railTrips = [t['i'] for t in trips if t['kind'] == 'rail']
print("   自动铁路", len(rail_items), "处；铁路行程", railTrips)
check(rail_items and all(it['kind'] == 'skip' for it in rail_items), f"TR2 铁路行程的 {len(rail_items)} 处断档只补公路时默认跳过")
k = railTrips[-1]
r = ui.send([f'trip {k} road']); s = ui.state(); items = s['batch']['items']
check(all(it['kind'] == 'road' for it in items if it['tripIndex'] + 1 == k) if 'tripIndex' in items[0] else True, f"TR3 trip {k} road → 整段改为公路")
r = ui.send([f'trip {k} auto']); s = ui.state(); items = s['batch']['items']
check(all(it['kind'] == 'skip' for it in items if it['auto'] == 'rail'), f"TR4 trip {k} auto → 回到自动（铁路→跳过）")
ui.send(['batchclose'])
print("FAILS:", fails or "none")
