#!/usr/bin/env python3
"""隧道口漂移 / 绕圈裁剪：单处模式对指定断档取 OSRM 草稿，看锚点外推、贴路、警告（不需要读 Documents）"""
import ui, json, time, os, sys, datetime
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
def wait_idle():
    for _ in range(80):
        s = ui.state()
        if not s.get("loading") and s.get("points"): return s
        time.sleep(0.5)
ui.send(["place 0", "front", "sleep 300"])
ui.send(["open %s/Garmin_Roma_Da.gpx" % C]); wait_idle()
ui.send(["fill", "sleep 800"])
ui.send(["routeinputs %s/ri.jsonl" % C])
rows = [json.loads(l) for l in open(C + "/ri.jsonl") if l.strip()]
def hhmm(tA): return datetime.datetime.fromtimestamp(tA).strftime("%H:%M")
targets = sys.argv[1].split(",") if len(sys.argv) > 1 else ["10:19", "07:48", "03:08", "09:22", "09:23"]
idx = {}
for r in rows:
    k = hhmm(r["tA"])
    if k in targets and k not in idx: idx[k] = r
print(f"{'时刻':6} {'ia':>6} {'ib':>6} | shiftA/B | snapA/B | 顶点 | 路长 | 警告 | 锚点后移核对 | 耗时")
for k in targets:
    r = idx.get(k)
    if not r: print(k, "没有这个断档"); continue
    i = r["i"]
    ui.send([f"select {i}", "sleep 600"])
    t0 = time.time()
    ui.send(["route car"])
    route = None; err = None
    for _ in range(240):
        s = ui.state()
        if s.get("routeBusy") is None and (s.get("route") or s.get("error")):
            route = s.get("route"); err = s.get("error"); break
        time.sleep(0.5)
    dt = time.time() - t0
    if not route: print(f"{k:6} {r['ia']:6} {r['ib']:6} | 失败: {err}"); continue
    s = ui.state()
    ok = s["anchorA"] == r["ia"] - route["shiftA"] and s["anchorB"] == r["ib"] + route["shiftB"]
    print(f"{k:6} {r['ia']:6} {r['ib']:6} | {route['shiftA']}/{route['shiftB']}      | {route['snapA']:>3}/{route['snapB']:<3} | {route['vertices']:>4} | {route['meters']:>5} | {route['warnings']:>2}   | {'ok' if ok else 'MISMATCH'} A={s['anchorA']} B={s['anchorB']} | {dt:.0f}s")
    for n in route.get("notes", []):
        if any(w in n for w in ("漂移", "靠到", "经过", "上下文（", "采用", "车道侧", "截断")): print("        · " + n[:170])
