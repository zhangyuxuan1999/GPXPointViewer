#!/usr/bin/env python3
"""精确模式在线验证（真实 OSRM + Valhalla；只由 Claude 跑一次，公共服务一次只能有一个客户端）：
Garmin_Roma_Da_copy.gpx，只选约 16 处自动判为公路的断档，精确模式取草稿，统计一致/不一致/没比对，列出每处的两路长度、依据、分歧段。
用法：run_crosscheck_online.py [n=16]。结束 crosscheck 0。"""
import ui, json, time, os, sys, subprocess, shutil
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
DST = os.path.abspath(os.path.join(os.path.dirname(__file__), "app.noindex/GPXPointViewer.app"))
N = int(sys.argv[1]) if len(sys.argv) > 1 else 16
def st():
    for _ in range(6):
        s = ui.state()
        if "points" in s: return s
        time.sleep(1)
    return s
def wait(pred, n=120, dt=0.5):
    for _ in range(n):
        s = st()
        if pred(s): return s
        time.sleep(dt)
    return st()
subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST], check=True)
wait(lambda s: "points" in s, 40, 1)
try:
    ui.send(["place 0", "front", "open %s/Garmin_Roma_Da_copy.gpx" % C]); wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "crosscheck 1", "fakeroute all off", "batchplan", "sleep 1000"])
    s = wait(lambda s: not s.get("tripMapRunning"), 240, 1)
    items = s["batch"]["items"]
    roads = [i for i, it in enumerate(items) if it["auto"] == "road" or it["kind"] == "road"][:N]
    ui.send(["batchall skip"] + [f"batchkind {i} road" for i in roads] + ["sleep 300"])
    s = st(); print(f"候选 {len(items)} · 选 {len(roads)} 处公路做精确模式：{roads}")
    t0 = time.time(); print("   ", ui.send(["batchrun"]).strip())
    last = ""
    for _ in range(900):
        s = st(); b = s.get("batch")
        if b and b["phase"] == "preview": break
        if b and b["progress"] != last: last = b["progress"]; print("   ", f"{time.time()-t0:5.0f}s", last[:140])
        time.sleep(1)
    b = s["batch"]; items = b["items"]
    work = [it for it in items if it["kind"] == "road"]
    print(f"用时 {time.time()-t0:.0f}s · 请求 {b['requests']} {b['requestsByHost']} · counts {b['counts']} · 停用提示 {b['engineDisabled']}")
    for it in work:
        routes = " / ".join(f"{r['engine']} {r['meters']} m {r['method']} w{r['warnings']} s{r['shiftA']}/{r['shiftB']}" for r in it["routes"])
        print(f"  {it['status'][:20]:20s} cross={it['cross']:10s} adopted={it['source']:12s} {it['meters']:>6} m  diverge={it['diverge']} maxDev={it['maxDev']} | {routes}")
    # 对不一致的，截图留档（主地图 + 卡片）
    for k, it in enumerate([it for it in items if it["status"] == "conflict:disagree"][:4]):
        i = items.index(it)
        ui.send([f"batchselect {i}", "sleep 1500", f"shotwin GPX {C}/xc_conflict_{k}.png"])
        print(f"  截图 xc_conflict_{k}.png ← 第 {i} 项")
    ui.send(["batchclose"])
finally:
    print("   ", ui.send(["crosscheck 0", "exit"]).strip().replace("\n", " | "))
    subprocess.run(["pkill", "-f", DST], capture_output=True)
