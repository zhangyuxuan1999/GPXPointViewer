#!/usr/bin/env python3
"""落地前自检界面 / 界面待办四项的截图（2026-10-27 Opus；不判通过/失败，看图）。
用法：python3 Tests/ui/shots_plausibility_ui.py <zh-Hans|en|de> [main|batch|all]
- main：主窗口 frame 240 60 960 800、补点模式、选一处取假路网 → shotwin 主窗口（底行按钮、性能面板与候选面板、状态行徽标）
- batch（只中文）：假引擎 offset 30 跑到 preview → 批量窗口（风险列 + 「只看要看一眼的」）、单处卡片（徽标 popover 打开）、修改记录详细页（自检一行）
自己起副本（app.noindex），离线（假引擎、autotripmap 0、副本默认假瓦片）。截图存 Tests/reports/plausibility_ui_shots/，并转 jpg。"""
import ui, json, time, os, sys, subprocess, shutil
lang = sys.argv[1] if len(sys.argv) > 1 else "zh-Hans"
what = sys.argv[2] if len(sys.argv) > 2 else "all"
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "Tests/reports/plausibility_ui_shots")
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
    r = ui.send([f"shotwin {title} {png}", "sleep 400"]).strip()
    print("   ", r.replace("\n", " | "))
    if os.path.exists(png):
        jpg = os.path.join(OUT, f"{name}.jpg")
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1600", png, "--out", jpg], capture_output=True)
        shutil.copyfile(png, os.path.join(OUT, f"{name}.png"))
        print("    ->", jpg)

subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", f"({lang})"], check=True)
wait(lambda s: "points" in s, 40, 1)
print("   ", ui.send(["windows"]).strip())
title = MAIN.get(lang, MAIN["zh-Hans"])
try:
    print("   ", ui.send(["autotripmap 0", "set showStats 1", "frame 240 60 960 800", "front", "riskthreshold off", "crosscheck 0", "open " + GPX]).strip().replace("\n", " | "))
    wait(lambda s: not s.get("loading") and s.get("points"), 120)
    if what in ("main", "all"):
        ui.send(["exit", "sleep 800", "frame 240 60 960 800", "sleep 1200"])
        shot(title, f"main_normal_{lang}")      # 普通模式：控制面板底行（导出/图片/删除点/补点）
    ui.send(["exit", "sleep 300", "fill", "sleep 1500"])
    if what in ("main", "all"):
        ui.send(["fakeroute all offset 30", "select 3", "sleep 400", "route car"])
        wait(lambda s: s.get("routeBusy") is None and s.get("route"), 60, 0.5)
        print("    route risk:", (st().get("route") or {}).get("riskLevel"))
        ui.send(["frame 240 60 960 800", "sleep 1500"])
        shot(title, f"main_fill_{lang}")
        ui.send(["undo", "undo", "sleep 300"])
    if what in ("batch", "all") and lang == "zh-Hans":
        ui.send(["fakeroute valhalla offset 30", "routecache clear", "batchclose", "sleep 300", "batchplan", "sleep 800", "batchall road", "sleep 200", "batchrun"])
        wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 300, 0.5)
        ui.send(["openbatch", "sleep 1500", "resizewin 批量补点 1130 900", "sleep 800"])
        shot("批量补点", "batch_table_zh-Hans")
        ui.send(["batchriskonly 1", "sleep 800"])
        shot("批量补点", "batch_riskonly_zh-Hans")
        ui.send(["batchriskonly 0"])
        s = st(); hi = [it for it in s["batch"]["items"] if it["riskLevel"] == "high"]
        idx = s["batch"]["items"].index(hi[0]) if hi else 0
        ui.send([f"batchselect {idx}", "sleep 300", "batchcompact 1", "sleep 2000"])
        print("    card:", {k: st()["batch"].get(k) for k in ("windowSize", "cardContentHeight")})
        shot("批量补点", "batch_card_zh-Hans")
        ui.send(["riskpopover 1", "sleep 1000"])
        # popover 是独立的小窗：shotwin 标题前加 "+" 连同本 app 的 popover 一起截（不截别的 app、不用整屏截图）
        shot("+批量补点", "batch_card_popover_zh-Hans")
        ui.send(["riskpopover 0", "batchcompact 0", "sleep 1200", "batchreview", "sleep 1500", f"reviewselect {idx}", "sleep 1500"])
        shot("修改记录", "review_detail_zh-Hans")
        # 原因多于 3 条的一处（折叠进「说明…」）
        r = json.loads(ui.send(["reviewstate"]).strip().splitlines()[-1])
        many = [c["i"] for c in r.get("changes", []) if len(c.get("riskReasons") or []) > 3]
        print("    reasons>3:", many[:5])
        if many:
            ui.send([f"reviewselect {many[0]}", "sleep 1500"])
            shot("修改记录", "review_detail_many_zh-Hans")
finally:
    print("   ", ui.send(["batchriskonly 0", "batchcompact 0", "reviewfollow 0", "crosscheck 0", "fakeroute all off", "riskthreshold off", "exit"]).strip().replace("\n", " | "))
