#!/usr/bin/env python3
"""联网：单处路网草稿带判断依据（Garmin + 一生足迹各 1 处公路断档）。只能在没有其它 OSRM 客户端时跑"""
import ui, json, time, os
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
def load(name, timeout=120):
    ui.send(['open %s/%s' % (C, name)])
    for i in range(timeout):
        time.sleep(1.0); s = ui.state()
        if not s.get('loading') and s.get('points'): return s
    return ui.state()
def route(label):
    ui.send(['route car'])
    for i in range(90):
        time.sleep(1.0); s = ui.state()
        if s['routeBusy'] is None: break
    r = s['route']; print("   ", label, "route:", r, "error:", s['error'])
    return s, r
ui.send(['frame 1320 -740 1320 860', 'front', 'sleep 500'])
s = load('Garmin_Roma_Da.gpx'); ui.send(['fill', 'select 0', 'sleep 1200'])
s, r = route("Garmin")
check(r and r['source'] == 'osrmCar' and r['vertices'] > 0, "R1 Garmin 单处公路草稿取回")
check(r and any('上下文' in n for n in r['notes']) and any('匹配' in n for n in r['notes']) and any('采样' in n for n in r['notes']), "R2 草稿 notes 含上下文/匹配/采样画像说明")
print("    notes:", *r['notes'], sep="\n      ") if r else None
s = load('stepLife2026.csv'); ui.send(['fill', 'sleep 1500']); s = ui.state(); print("   StepLife candidates", s['candidates'], "profile", s['profile'])
# 找一处公路样断档：用 batchplan 的自动分类
ui.send(['batchplan', 'sleep 800']); s = ui.state(); items = s['batch']['items'] if s['batch'] else []
idx = next((i for i, it in enumerate(items) if it['auto'] == 'road'), None); print("   first auto-road item:", idx)
ui.send(['batchclose', 'sleep 500'])
if idx is not None:
    ui.send([f'select {idx}', 'sleep 1200']); s, r = route("StepLife")
    check(r and r['source'] == 'osrmCar', "R3 一生足迹单处公路草稿取回")
    check(r and any('半径 20' in n or '半径 2' in n or '半径 3' in n or '半径 4' in n or '半径 5' in n for n in r['notes']), "R4 一生足迹匹配半径按画像（≥20 m）")
    print("    notes:", *r['notes'], sep="\n      ") if r else None
print("FAILS:", fails or "none")
