#!/usr/bin/env python3
"""区间内贴路点保留：手机数据里挑隧道群候选，取草稿、应用，看确认框里的保留数与落地后修改记录的删除数；Garmin 一律全替换"""
import ui, json, time, os, sys
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(c, l):
    print(("    ok   " if c else "    FAIL ") + l)
    if not c: fails.append(l)
def wait_idle(until=None):
    for _ in range(120):
        s = ui.state()
        if not s.get("loading") and s.get("points") and (until is None or until(s)): return s
        time.sleep(0.5)
    return ui.state()
def rstate():
    return json.loads(ui.send(["reviewstate"]).strip().splitlines()[-1])
ui.send(["place 0", "front", "open %s/2026.csv" % C]); wait_idle()
ui.send(["fill", "sleep 1500"])
chains = ui.send(["chains"]).strip().splitlines()[-1].split()
print("隧道群候选：", chains[:12])
tried = 0; kept_total = 0; removed_total = 0
for ch in chains[:6]:
    i = int(ch.split(":")[0]); inner = int(ch.split("inner")[1])
    print("   ", ui.send([f"select {i}", "sleep 500"]).strip().replace("\n", " | "), ui.state()["anchorA"], ui.state()["anchorB"], "rc", ui.state()["removeCount"])
    print("   ", ui.send(["route car"]).strip())
    for _ in range(240):
        s = ui.state()
        if s.get("routeBusy") is None and (s.get("route") or s.get("error")): break
        time.sleep(0.5)
    if not s.get("route"): print(f"  #{i} 路网失败：{s.get('error')}"); continue
    r = ui.send(["apply", "sleep 400"]); s = ui.state(); print("    apply →", r.strip().replace("\n", " | "), "| A", s["anchorA"], "B", s["anchorB"], "vertices", s["vertexCount"], "route", s["route"] is not None, "err", s["error"])
    keep = s.get("promptKeep", -1); rc = s["removeCount"]
    print(f"  #{i} 群内点 {inner} → 区间内 {rc} 点，确认框：保留 {keep} 个贴路点")
    before = ui.state()["points"]
    ui.send(["confirm replace"]); s2 = wait_idle(until=lambda s: s["changes"] > 0 and s["points"] != before)
    rs = rstate(); c = rs["changes"][-1]
    print(f"       落地：+{c['added']} −{c['removed']}（区间内 {rc}，保留 {rc - c['removed']}）")
    check(c["removed"] == rc - keep, f"#{i} 删掉数 = 区间内 − 保留（{c['removed']} = {rc} − {keep}）")
    tried += 1; kept_total += keep; removed_total += c["removed"]
    ui.send(["reviewall"]); wait_idle(until=lambda s: s["activeChanges"] == 0)
    ui.send(["fill", "sleep 800"])
check(tried >= 3, f"T 至少试了 3 处（{tried}）")
print(f"合计：保留 {kept_total} 个贴路点、删掉 {removed_total} 个飘点")
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
