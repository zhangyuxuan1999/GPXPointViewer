#!/usr/bin/env python3
"""网络状况横幅：注入失败 → state.network 出现、批量窗口/补点条/修改记录里有横幅；注入成功 → 清掉"""
import ui, json, time, os, sys
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(c, l):
    print(("    ok   " if c else "    FAIL ") + l)
    if not c: fails.append(l)
def wait_idle():
    for _ in range(80):
        s = ui.state()
        if not s.get("loading") and s.get("points"): return s
        time.sleep(0.5)
ui.send(["place 0", "front", "sleep 300"])
ui.send(["open %s/Garmin_Roma_Da.gpx" % C]); wait_idle()
s = ui.state(); check(s["network"] is None and s["offline"] is False, f"N0 正常时无横幅（offline={s['offline']}）")
ui.send(["netfail 3", "sleep 400"]); s = ui.state()
check(s["network"] is not None and "网络不好" in (s["network"] or ""), f"N1 注入 3 次失败 → 横幅：{s['network']}")
ui.send(["fill", "sleep 500", "openbatch", "sleep 800", "batchplan", "sleep 1500", f"shotwin 批量补点 {C}/s_net_batch.png", f"shotwin GPX {C}/s_net_main.png"])
ui.send(["netok 6", "sleep 400"]); s = ui.state()
check(s["network"] is None, f"N2 之后 6 次成功 → 横幅消失（{s['network']}）")
ui.send(["batchclose", "exit"])
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
