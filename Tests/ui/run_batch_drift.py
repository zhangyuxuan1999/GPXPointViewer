#!/usr/bin/env python3
"""批量（经济模式、两路引擎）全跑一遍：统计 ✓/⚠/✗、锚点外推处数、列出有疑点的处"""
import ui, json, time, os, datetime, sys
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
def st():
    for _ in range(6):
        s = ui.state()
        if "trips" in s: return s
        print("  state 返回异常，重试：", str(s)[:120]); time.sleep(2)
    return s
if len(sys.argv) > 1:
    ui.send(["place 0", "front", "open %s/%s" % (C, sys.argv[1])])
    for _ in range(120):
        s = st()
        if not s.get("loading") and s.get("points"): break
        time.sleep(0.5)
    ui.send(["exit", "sleep 300"])
s = st()
if not s.get("fillMode"): ui.send(["fill", "sleep 1500"])
s = st(); print(f"文件 {s['points']} 点 · 候选 {s['candidates']}（隧道群 {s.get('chains')}）· 过滤后 {s['filtered']} · 段 {len(s['trips'])}")
ui.send(["batchplan", "sleep 1000"])
t0 = time.time()
for _ in range(400):
    s = st()
    if not s.get("tripMapRunning"): break
    time.sleep(1)
print(f"地图判段用时 {time.time()-t0:.0f}s（判了 {sum(1 for t in s['trips'] if t['mapN'] > 0 or t['mapVerdict'])}/{len(s['trips'])} 段）；批次 {s['batch']['phase'] if s.get('batch') else None}，待取 {sum(1 for it in s['batch']['items'] if it['kind'] in ('road','rail')) if s.get('batch') else '?'} 处")
t1 = time.time()
print(ui.send(["batchrun"]))
for _ in range(900):
    s = st()
    b = s.get("batch")
    if b and b["phase"] == "preview": break
    time.sleep(1)
b = s["batch"]
items = b["items"]
done = [it for it in items if it["status"] == "done"]
warned = [it for it in done if it["warnings"] > 0]
failed = [it for it in items if it["status"].startswith("failed")]
shifted = [it for it in done if it["shiftA"] > 0 or it["shiftB"] > 0]
print(f"取草稿用时 {time.time()-t1:.0f}s · 请求 {b['requests']} · 完成 {len(done)} · 有疑点 {len(warned)} · 失败 {len(failed)} · 锚点外推 {len(shifted)} 处")
print("外推明细（shiftA/shiftB）：" + ", ".join(f"{it['shiftA']}/{it['shiftB']}" for it in shifted))
for it in warned: print("  ⚠", it["status"], it["method"], it["meters"], "m", "shift", it["shiftA"], it["shiftB"])
for it in failed[:10]: print("  ✗", it["status"][:120])
