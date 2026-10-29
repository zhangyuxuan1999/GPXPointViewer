#!/usr/bin/env python3
"""批量「单处卡片」缩窗 / 修改记录「在主地图上看」（假引擎，不联网；自己起副本，约 2 分钟）：
K1 精确模式假引擎跑到 preview → batchcompact 1：state.batch.windowSize 宽 ≤ 600、高 ≤ 420；batchcompact 0：恢复进入前尺寸
K1c 先把批量窗口拉大到 1130×990（用户截图的尺寸）再折叠：仍缩成卡片；展开恢复 1130×990
K1d 折叠时关掉批量窗口 → compact=false；重开 → 进入前的大尺寸
K3 主窗口候选列表点一处（select）：预览阶段 → 选中批次里那处并折叠；批量列表展开时不在批量流程（无批次）则不碰
K2 batchreview → reviewselect 3 → reviewgoto：reviewstate.mainMapCenter 距该处 < 2 km、mainMapSpanKm < 10
截图：card_compact.png（批量窗口卡片）、card_review_goto.png（修改记录详细页，含「在主地图上看」）。
结束 batchcompact 0、crosscheck 0、fakeroute all off、reviewmap standard light 1。"""
import ui, json, time, os, sys, subprocess, shutil, math
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
DST = os.path.abspath(os.path.join(os.path.dirname(__file__), "app.noindex/GPXPointViewer.app"))
fails = []
def check(c, l):
    print(("    ok   " if c else "    FAIL ") + l)
    if not c: fails.append(l)
def st():
    for _ in range(6):
        s = ui.state()
        if "points" in s: return s
        time.sleep(1)
    return s
def rv():
    r = ui.send(["reviewstate"]).strip().splitlines()[-1]
    try: return json.loads(r)
    except Exception: return {"raw": r}
def wait(pred, n=120, dt=0.5):
    for _ in range(n):
        s = st()
        if pred(s): return s
        time.sleep(dt)
    return st()
def wsize(s): return (s.get("batch") or {}).get("windowSize")
def near(a, b, tol=3): return a and b and abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol
def km(la1, lo1, la2, lo2):
    p1, p2 = math.radians(la1), math.radians(la2); dp = p2 - p1; dl = math.radians(lo2 - lo1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(h))
subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
wait(lambda s: "points" in s, 40, 1)
try:
    ui.send(["autotripmap 0", "place 0", "front", "open %s/Garmin_Roma_Da_copy.gpx" % C]); wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500"])
    # K3a 没有批次：主列表点一处只选断档，不出现批量状态
    ui.send(["select 1", "sleep 300"]); s = st()
    check(s.get("batch") is None, "K3a 无批次时主列表点一处不碰批量（batch=null）")
    ui.send(["crosscheck 1", "fakeroute all ok", "batchplan", "sleep 800"])
    wait(lambda s: not s.get("tripMapRunning"), 60, 0.5)
    ui.send(["batchall road", "batchrun"]); s = wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 240, 0.5)
    check(s.get("batch") and s["batch"]["phase"] == "preview", f"K0 假引擎跑到 preview（{(s.get('batch') or {}).get('phase')}）")
    ui.send(["openbatch", "sleep 1500"]); s = st()
    size0 = wsize(s)
    print("    批量窗口初始尺寸", size0, "compact", s["batch"]["compact"])
    # K1
    ui.send(["batchcompact 1", "sleep 1800"]); s = st(); sz = wsize(s)
    print("   ", s["batch"].get("dock"))
    check(s["batch"]["compact"] and sz and sz[0] <= 600 and sz[1] <= 420, f"K1a 折叠 → 窗口缩成卡片 {sz}（≤600×420）")
    ui.send([f"shotwin 批量补点 {C}/card_compact.png"])
    ui.send(["batchcompact 0", "sleep 1500"]); s = st(); sz = wsize(s)
    check(not s["batch"]["compact"] and near(sz, size0), f"K1b 展开 → 恢复 {sz} vs {size0}")
    # K1c 大窗口（用户截图 1130×990）也照样缩
    print("   ", ui.send(["movewin 批量补点 120 60"]).strip())
    big = None
    r = ui.send(["resizewin 批量补点 1130 990", "sleep 800"]).strip(); print("   ", r.replace("\n", " | "))
    s = st(); big = wsize(s)
    ui.send(["batchcompact 1", "sleep 1800"]); s = st(); sz = wsize(s)
    check(sz and sz[0] <= 600 and sz[1] <= 420, f"K1c 大窗口 {big} 折叠 → {sz}")
    ui.send(["batchcompact 0", "sleep 1500"]); s = st(); sz = wsize(s)
    check(near(sz, big), f"K1c' 展开 → 恢复大窗口 {sz} vs {big}")
    # K1d 折叠时关窗 → 退出折叠；重开是进入前的尺寸
    ui.send(["batchcompact 1", "sleep 1500", "closebatchwin", "sleep 1000"]); s = st()
    check(not s["batch"]["compact"] and wsize(s) is None, f"K1d 折叠中关窗 → compact={s['batch']['compact']} windowSize={wsize(s)}")
    ui.send(["openbatch", "sleep 1500"]); s = st(); sz = wsize(s)
    check(near(sz, big, 6), f"K1d' 重开 → {sz}（关窗前进入折叠时 {big}）")
    # K3b 预览阶段：主窗口候选列表点一处 → 选中批次里那处并折叠
    sel0 = s["batch"]["selected"]
    ui.send(["select 4", "sleep 1800"]); s = st(); sz = wsize(s)
    check(s["batch"]["compact"] and s["batch"]["selected"] != sel0 and sz and sz[0] <= 600, f"K3b 预览中主列表点一处 → 选中 {s['batch']['selected']}、折叠 {sz}")
    ui.send(["batchcompact 0", "sleep 1200"])
    # K2 修改记录「在主地图上看」
    print("   ", ui.send(["batchreview", "sleep 1500"]).strip())
    ui.send(["reviewselect 3", "sleep 800"]); r0 = rv()
    print("   ", ui.send(["reviewgoto", "sleep 2500"]).strip())
    r = rv(); it = r["changes"][3] if len(r.get("changes", [])) > 3 else None
    c = r.get("mainMapCenter"); span = r.get("mainMapSpanKm")
    d = km(c[0], c[1], it["lat"], it["lon"]) if c and it else 999
    check(c is not None and d < 2.0, f"K2a 主地图中心距第 4 处 {d:.2f} km（中心 {c}，该处 {it and (it['lat'], it['lon'])}；之前 {r0.get('mainMapCenter')}）")
    check(span is not None and span < 10, f"K2b 主地图宽 {span} km < 10")
    check(r.get("detail") and r.get("selected") == 3, f"K2c 修改记录仍在详细页第 4 处（selected={r.get('selected')}）")
    ui.send(["reviewnext", "sleep 300"]); check(rv().get("selected") == 4, "K2d goto 之后仍能 ‹ › 翻页")
    ui.send(["reviewprev", "sleep 1500", f"shotwin 修改记录 {C}/card_review_goto.png"])
    print("    wins:", ui.send(["windows"]).strip()[:400])
finally:
    print("   ", ui.send(["batchcompact 0", "crosscheck 0", "fakeroute all off", "reviewmap standard light 1"]).strip().replace("\n", " | "))
    if os.environ.get("KEEP") != "1":
        ui.send(["exit"]); subprocess.run(["pkill", "-f", DST], capture_output=True)
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
