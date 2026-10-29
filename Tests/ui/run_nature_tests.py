#!/usr/bin/env python3
"""成因标签 / 路由输入导出 / 批量跳过稀疏（离线）"""
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
ui.send(['frame 1320 -740 1320 860', 'front', 'sleep 500'])
load('Garmin_Roma_Da.gpx'); ui.send(['fill', 'sleep 800'])
r = ui.send(['routeinputs %s/g_app.jsonl' % C]); print("   ", r)
ui.send(['select 0', 'sleep 1000']); s = ui.state()
check(s['nature'] == 'lol' and s['tau'] == 1.0, f"N1 Garmin 选中断档成因 = 失锁、τ=1（实际 {s['nature']} {s['tau']}）")
n = ui.send(['notes']); print("    notes:", str(n)[:600])
check('上下文' in str(n) and '行进方向' in str(n) and '匹配' in str(n) and '成因' in str(n), "N2 notes 含上下文/行进方向/匹配/成因")
load('stepLife2026.csv'); ui.send(['fill', 'sleep 1500']); s = ui.state(); print("   候选", s['candidates'])
r = ui.send(['routeinputs %s/p_app.jsonl' % C]); print("   ", r)
rows = [json.loads(l) for l in open(C + '/p_app.jsonl')]
sparse = [i for i, x in enumerate(rows) if x['nature'] == 'sparse']; print("   sparse", len(sparse), "lol", len(rows) - len(sparse), "auto rail", sum(1 for x in rows if x['auto'] == 'rail'))
if sparse:
    ui.send([f'select {sparse[0]}', 'sleep 1000']); s = ui.state()
    check(s['nature'] == 'sparse', f"N3 选中稀疏采样步后 state.nature = sparse（实际 {s['nature']}）")
ui.send(['batchplan', 'sleep 800']); s = ui.state(); items = s['batch']['items']
check(sum(1 for it in items if it['nature'] == 'sparse') == len(sparse), "N4 批量条目的 sparse 数与导出一致")
ui.send(['batchskipsparse', 'sleep 300']); s = ui.state(); items = s['batch']['items']
check(all(it['kind'] == 'skip' for it in items if it['nature'] == 'sparse'), "N5 batchskipsparse 后稀疏项全部 skip")
ui.send(['batchclose', 'sleep 300'])
print("FAILS:", fails or "none")
