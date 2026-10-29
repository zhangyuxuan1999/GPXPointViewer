#!/usr/bin/env python3
"""悬停不再重算整个 ContentView：发 60 次 hover 发布，body 求值次数应不增加（旧版每次 +1）"""
import ui, json, time, os, sys
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
def wait_idle():
    for _ in range(80):
        s = ui.state()
        if not s.get("loading") and s.get("points"): return s
        time.sleep(0.5)
ui.send(["place 0", "front", "sleep 300"])
ui.send(["open %s/Garmin_Roma_Da.gpx" % C]); s = wait_idle()
ui.send(["sleep 1500"])
fails = []
def check(c, l):
    print(("    ok   " if c else "    FAIL ") + l)
    if not c: fails.append(l)
for mode, cmds in (("普通", []), ("补点", ["fill", "sleep 1200"])):
    if cmds: ui.send(cmds)
    ui.send(["sleep 800"]); b0 = ui.state()["bodyEvals"]
    cmds = []
    for i in range(60):
        cmds.append(f"hover {1000 + i * 7} {400 + (i % 20) * 9} {300 + (i % 7) * 11}")
        cmds.append("sleep 15")
    cmds.append("hover 0 -100 -100"); cmds.append("sleep 300")
    t0 = time.time(); ui.send(cmds, timeout=60); dt = time.time() - t0
    b1 = ui.state()["bodyEvals"]
    check(b1 - b0 <= 2, f"{mode}模式：60 次悬停发布 → ContentView body 求值 +{b1 - b0}（期望 ≤2；{dt:.1f}s）")
    hv = ui.state()["hover"]
    check(hv is not None and hv["index"] == 0, f"{mode}模式：悬停状态仍然到达（最后一次 index={hv and hv['index']}）")
ui.send(["exit"])
print("FAILS:", fails if fails else "none")
sys.exit(1 if fails else 0)
