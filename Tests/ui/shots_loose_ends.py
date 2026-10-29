#!/usr/bin/env python3
"""loose-ends（2026-10-28）截图：主窗口 960×800 补点模式下左面板最底一行不被底部操作条盖住。
用法：python3 Tests/ui/shots_loose_ends.py <zh-Hans|en|de>
自己起副本（app.noindex），离线（假引擎、autotripmap 0）。存 Tests/reports/loose_ends_shots/<name>.jpg（png 留容器里）。"""
import ui, time, os, sys, subprocess, shutil
lang = sys.argv[1] if len(sys.argv) > 1 else "zh-Hans"
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "Tests/reports/loose_ends_shots")
GPX = os.path.join(C, "Garmin_Roma_Da_copy.gpx")
DST = os.path.abspath(os.path.join(os.path.dirname(__file__), "app.noindex/GPXPointViewer.app"))
MAIN = {"zh-Hans": "GPX 点位查看器", "en": "GPX Point Viewer", "de": "GPX-Punktbetrachter"}
os.makedirs(OUT, exist_ok=True)
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
def shot(title, name):
    png = os.path.join(C, name + ".png")
    # 锁屏时 shotwin 全白：用视图树离屏渲染 shotviewwin（MapKit 底图可能是黑/空的，面板与覆盖层正常）
    cmd = "shotviewwin" if os.environ.get("GPXPV_SHOT_OFFSCREEN", "1") == "1" else "shotwin"
    print("   ", ui.send([f"{cmd} {title} {png}", "sleep 400"]).strip().replace("\n", " | "))
    if os.path.exists(png):
        jpg = os.path.join(OUT, f"{name}.jpg")
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1600", png, "--out", jpg], capture_output=True)
        print("    ->", jpg)

subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", f"({lang})"], check=True)
wait(lambda s: "points" in s, 40, 1)
title = MAIN.get(lang, MAIN["zh-Hans"])
try:
    ui.send(["autotripmap 0", "set showStats 1", "frame 240 60 960 800", "front", "crosscheck 0", "open " + GPX])
    wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "fakeroute all ok", "select 3", "sleep 400", "route car"])
    wait(lambda s: s.get("routeBusy") is None and s.get("route"), 60, 0.5)
    ui.send(["frame 240 60 960 800", "sleep 1500"])
    shot(title, f"main_fill_{lang}")
    # 单处交叉验证进行中（Valhalla 慢 6 s）：操作条上合成的一行进度
    ui.send(["fakeroute valhalla slow 6000", "routecross"])
    wait(lambda s: s.get("crossLegs") == [1, 0], 20, 0.25)
    shot(title, f"main_crossprogress_{lang}")
    wait(lambda s: s.get("routeBusy") is None, 30, 0.5)
finally:
    ui.send(["fakeroute all off", "crosscheck 0", "exit"])
