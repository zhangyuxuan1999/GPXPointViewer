#!/usr/bin/env python3
"""修改记录窗口回归：补一处 → 删一段 → 总览合成轨迹 → 详细取景/地名/前后翻 → 逐处还原 → 全部还原"""
import ui, json, time, os, sys
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
def wait_idle(timeout=40, until=None):
    """落地/删除/还原都是先 main.async 再后台重建：只看 loading 会抢在它开始之前返回，所以可给一个"达到条件"再认完成"""
    for _ in range(int(timeout / 0.5)):
        s = ui.state()
        if not s.get("loading") and s.get("points") and (until is None or until(s)): return s
        time.sleep(0.5)
    return ui.state()
def rstate():
    r = ui.send(["reviewstate"]); return json.loads(r.strip().splitlines()[-1])

ui.send(["place 0", "front", "sleep 300"])
ui.send(["open %s/Garmin_Roma_Da.gpx" % C]); s0 = wait_idle(); n0 = s0["points"]
check(n0 > 1000 and s0["changes"] == 0, f"T0 载入 {n0} 点，修改记录为空")

# 1. 补一处断档（替换区间内点）
ui.send(["fill", "select 0", "sleep 1500", "apply", "sleep 400", "confirm replace"]); s1 = wait_idle(until=lambda s: s["fills"] == 1)
rs = rstate()
check(s1["fills"] == 1 and s1["changes"] == 1 and len(rs["changes"]) == 1 and rs["changes"][0]["kind"] == "fill" and rs["changes"][0]["added"] > 0,
      f"T1 落地一处补点 → 1 条修改记录（+{rs['changes'][0]['added'] if rs['changes'] else '?'} −{rs['changes'][0]['removed'] if rs['changes'] else '?'}），点数 {n0}→{s1['points']}")
n1 = s1["points"]; added1 = rs["changes"][0]["added"]; removed1 = rs["changes"][0]["removed"]
check(n1 == n0 + added1 - removed1, "T1b 点数差 = 新增 − 替换")

# 2. 退出补点，圈选删除一段 50 点
ui.send(["exit", "sleep 300", "delete 5000 5050"]); s2 = wait_idle(until=lambda s: s["changes"] == 2)
rs = rstate()
kinds = [c["kind"] for c in rs["changes"]]
check(s2["changes"] == 2 and sorted(kinds) == ["deletion", "fill"] and s2["points"] == n1 - 50, f"T2 删 50 点 → 2 条记录 {kinds}，点数 {n1}→{s2['points']}")
check(s2["fills"] == 1, "T2b 删除后补点清单（增量导出）仍保留")
idel = kinds.index("deletion"); ifill = kinds.index("fill")

# 3. 打开窗口：总览合成轨迹 = 当前点 + 所有删掉的点
ui.send(["review", "sleep 2500"]); rs = rstate()
for _ in range(20):
    if not rs["building"] and rs["reviewPoints"] > 0: break
    time.sleep(0.5); rs = rstate()
check(rs["reviewPoints"] == s2["points"] + 50 + removed1, f"T3 合成轨迹 {rs['reviewPoints']} = 当前 {s2['points']} + 删掉 {50 + removed1}")
check(not rs["detail"] and rs["selected"] == -1, "T3b 初始为总览")

# 4. 详细：取景框住该处、地名到达、前后翻
ui.send([f"reviewselect {ifill}", "sleep 1800"]); rs = rstate()
c = rs["changes"][ifill]; vb = rs["visible"]; bb = c["bbox"]
inside = vb and vb[0] <= bb[0] and vb[1] <= bb[1] and vb[2] >= bb[2] and vb[3] >= bb[3]
check(rs["detail"] and rs["selected"] == ifill and inside, f"T4 详细页框住补点处 可见{vb} ⊇ 范围{bb}")
span = max((vb[2]-vb[0]) * 111000, (vb[3]-vb[1]) * 111000 * 0.7) if vb else 0
bspan = max((bb[2]-bb[0]) * 111000, (bb[3]-bb[1]) * 111000 * 0.7)
check(vb and span < max(bspan * 3.5, 600), f"T4b 没有缩得太远（可见约 {span:.0f} m，范围约 {bspan:.0f} m）")
place = None
for _ in range(30):
    rs = rstate(); place = rs["changes"][ifill]["place"]
    if place: break
    time.sleep(0.5)
check(bool(place) and "-" in (place or "") and "失败" not in (place or ""), f"T4c 地名三级：{place}")
ui.send(["reviewnext", "sleep 1200"]); rs = rstate()
check(rs["selected"] == min(ifill + 1, 1), f"T5 下一处 → 第 {rs['selected']}")
ui.send(["reviewprev", "sleep 600"]); rs = rstate()
check(rs["selected"] == max(ifill - 1, 0), f"T5b 上一处 → 第 {rs['selected']}")
ui.send([f"reviewselect {idel}", "sleep 1500"]); rs = rstate()
c = rs["changes"][idel]; vb = rs["visible"]; bb = c["bbox"]
inside = vb and vb[0] <= bb[0] and vb[1] <= bb[1] and vb[2] >= bb[2] and vb[3] >= bb[3]
check(inside, f"T5c 详细页框住删除处 可见{vb} ⊇ 范围{bb}")
ui.send(["shotwin 修改记录 %s/review_detail.png" % C, "shotviewwin 修改记录 %s/review_detail_view.png" % C])

# 5. 还原删除那一处：点数回到 n1，补点仍在，记录保留但标记已还原
ui.send([f"reviewrevert {idel}"]); s5 = wait_idle(until=lambda s: s["activeChanges"] == 1); rs = rstate()
check(s5["points"] == n1 and s5["changes"] == 2 and s5["activeChanges"] == 1 and rs["changes"][idel]["reverted"] and not rs["changes"][ifill]["reverted"],
      f"T6 还原删除 → 点数 {s5['points']}（期望 {n1}），记录 2 条 / 生效 1 条")
for _ in range(20):
    rs = rstate()
    if not rs["building"] and rs["reviewPoints"] == s5["points"] + removed1: break
    time.sleep(0.5)
check(rs["reviewPoints"] == s5["points"] + removed1, f"T6b 合成轨迹随之更新 {rs['reviewPoints']} = {s5['points']} + {removed1}")

# 6. 全部还原：回到原始点数，补点清单清空
ui.send(["reviewall"]); s6 = wait_idle(until=lambda s: s["activeChanges"] == 0); rs = rstate()
check(s6["points"] == n0 and s6["fills"] == 0 and s6["activeChanges"] == 0 and all(c["reverted"] for c in rs["changes"]),
      f"T7 全部还原 → 点数 {s6['points']}（原 {n0}），补点清单 {s6['fills']}，全部标记已还原")
ui.send(["reviewdetail off", "sleep 800", "shotwin 修改记录 %s/review_overview.png" % C, "shotviewwin 修改记录 %s/review_overview_view.png" % C])
print("FAILS:", fails if fails else "none")
sys.exit(1 if fails else 0)
