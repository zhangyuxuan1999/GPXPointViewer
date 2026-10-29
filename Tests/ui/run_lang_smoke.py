#!/usr/bin/env python3
"""四语冒烟：用 -AppleLanguages 启动测试副本，开文件→补点→批量窗口→修改记录窗口，截图到 perf/lang_<lang>_*.png，并打印 lang/windows。
用法：run_lang_smoke.py en|de|zh-Hant|zh-Hans"""
import ui, json, time, os, sys, subprocess, shutil
lang = sys.argv[1]
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
SP = os.path.dirname(os.path.abspath(__file__)); OUT = SP + "/perf"
os.makedirs(OUT, exist_ok=True)
subprocess.run(["pkill", "-f", SP + "/app.noindex/GPXPointViewer.app"], capture_output=True); time.sleep(1.5)
src = ui.app_source()
dst = SP + "/app.noindex/GPXPointViewer.app"; os.makedirs(os.path.dirname(dst), exist_ok=True)
if os.path.exists(dst): shutil.rmtree(dst)
shutil.copytree(src, dst, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, dst, "--args", "-AppleLanguages", f"({lang})"], check=True)
for _ in range(60):
    time.sleep(1)
    if "points" in ui.state(): break
print("lang:", ui.send(["lang"]).strip())
ui.send(["place 0", "front", f"open {C}/Garmin_Roma_Da.gpx"])
for _ in range(120):
    s = ui.state()
    if s.get("points") and not s.get("loading"): break
    time.sleep(0.5)
ui.send(["exit", "sleep 200", "fill", "sleep 1500", "select 0", "sleep 800"])
print("main:", ui.send([f"shotview {C}/lang_{lang}_main.png"]).strip()[:120])
ui.send(["batchplan", "sleep 800", "openbatch", "sleep 1500"])
print("windows:", ui.send(["windows"]).strip()[:400])
# 批量窗口：按 identifier 前缀 batchFill 的窗口截图（shotwin 按标题子串；标题随语言变，取 windows 输出里的标题）
import re
def title_for(scene):
    # windows 输出：`标题: x=.. y=.. w=.. h=.. id=batchFill-…` 以 " | " 分隔
    for ent in ui.send(["windows"]).strip().split(" || ")[0].split(" | "):
        if f"id={scene}" in ent:
            m = re.match(r"(.+?): x=", ent)
            if m: return m.group(1)
    return None
title = title_for("batchFill")
if title: print("batch shot:", ui.send([f"shotwin {title} {C}/lang_{lang}_batch.png"]).strip()[:120])
else: print("batch window title not found in:", ui.send(["windows"]).strip()[:300])
ui.send(["batchclose", "sleep 300", "review", "sleep 1500"])
title = title_for("changeReview")
if title: print("review shot:", ui.send([f"shotwin {title} {C}/lang_{lang}_review.png"]).strip()[:120])
ui.send(["exit"])
import glob
for f in glob.glob(f"{C}/lang_{lang}_*.png"): shutil.copy2(f, OUT)
print("done", lang, glob.glob(f"{OUT}/lang_{lang}_*.png"))
