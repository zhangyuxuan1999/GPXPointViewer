#!/usr/bin/env python3
"""落地前审阅 / 落地提示 / 路网证据 / 审阅底图（假引擎，不联网）：
A 两路不一致（Valhalla 偏 30 m）→ 选两处 → 审阅预览：preview=true、项数、drafts 两份、等你选项不可勾、勾选切换联动批量 included
B 翻页 ‹ ›、底图切换钩子
C 落地 → toast 出现、批量窗口关闭、审阅切回真实修改记录、每条记录带 drafts/cross
结束 crosscheck 0、fakeroute all off。"""
import ui, json, time, os, sys, subprocess, shutil
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
subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
wait(lambda s: "points" in s, 40, 1)
try:
    ui.send(["autotripmap 0", "place 0", "front", "open %s/Garmin_Roma_Da_copy.gpx" % C]); wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "crosscheck 1", "fakeroute osrm ok", "fakeroute valhalla offset 30", "batchplan", "sleep 800"])
    wait(lambda s: not s.get("tripMapRunning"), 60, 0.5)
    ui.send(["batchall road", "batchrun"]); s = wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 240, 0.5)
    items = s["batch"]["items"]; road = [it for it in items if it["kind"] == "road"]
    idx = [i for i, it in enumerate(items) if it["status"] == "conflict:disagree"]
    check(len(idx) == len(road), f"A0 全部待选 {len(idx)}/{len(road)}")
    ui.send([f"batchpick {idx[0]} osrm", f"batchpick {idx[1]} valhalla", f"batchpick {idx[2]} straight"])
    s = st(); b = s["batch"]
    print("   ", ui.send(["batchreview", "sleep 1500"]).strip())
    r = rv(); s = st()
    check(r.get("preview") is True, f"A1 审阅窗口进入预览模式 preview={r.get('preview')}")
    n_items = len(r.get("changes", []))
    check(n_items == len(road), f"A2 预览项数 = 公路项数（{n_items} vs {len(road)}）")
    inc = [it for it in r["changes"] if it["included"]]; pend = [it for it in r["changes"] if it["pending"]]
    check(len(inc) == 3 and len(pend) == len(road) - 3, f"A3 勾选落地 3 处、等你选 {len(pend)} 处")
    two = [it for it in r["changes"] if len(it["drafts"]) == 2]
    check(len(two) >= len(road) - 1, f"A4 每处带两路草稿（{len(two)}/{len(road)}）；直线那处 drafts={[it['drafts'] for it in r['changes'] if it['straight']]}")
    check(all(it["cross"] == "disagree" for it in r["changes"] if not it["straight"]), "A5 cross=disagree")
    ready = wait(lambda s: True, 1)
    for _ in range(60):
        r = rv()
        if not r.get("building") and r.get("reviewPoints", -1) > 0: break
        time.sleep(0.5)
    check(r.get("reviewPoints", -1) > s["points"], f"A6 预览合成轨迹含将新增的点（{r.get('reviewPoints')} > {s['points']}）")
    # 勾选切换联动
    first_inc = [i for i, it in enumerate(r["changes"]) if it["included"]][0]
    print("   ", ui.send([f"reviewinclude {first_inc} 0"]).strip())
    r2 = rv(); s2 = st()
    check(not r2["changes"][first_inc]["included"] and s2["batch"]["included"] == 2, f"A7 预览里取消落地 → 批量 included 3→{s2['batch']['included']}")
    print("   ", ui.send([f"reviewinclude {first_inc} 1"]).strip())
    check(st()["batch"]["included"] == 3, "A8 再勾回 → included 3")
    pend_i = [i for i, it in enumerate(rv()["changes"]) if it["pending"]][0]
    ui.send([f"reviewinclude {pend_i} 1"]); check(not rv()["changes"][pend_i]["included"], "A9 等你选的项不能从预览勾选")
    # A10 直线那处：straight=true、source 空、两份草稿仍留着；都不补 → declined、不算等你选；主窗口「修改记录」入口退出预览、再进预览
    r = rv(); st_items = r["changes"]
    sitem = [it for it in st_items if it["straight"]]
    check(len(sitem) == 1 and sitem[0]["source"] == "" and len(sitem[0]["drafts"]) == 2 and sitem[0]["included"], f"A10 直线项 straight=true、source 空、drafts 两份：{sitem[:1]}")
    pend_item = [i for i, it in enumerate(items) if it["status"] == "conflict:disagree"][3]
    ui.send([f"batchpick {pend_item} none", "sleep 300"]); r = rv()
    dec = [it for it in r["changes"] if it["declined"]]
    check(len(dec) == 1 and not dec[0]["pending"] and not dec[0]["included"], f"A11 「都不补」→ declined、不算等你选、不落地：{dec[:1]}")
    print("   ", ui.send(["review"]).strip()); r = rv()
    check(r.get("preview") is False, f"A12 主窗口「修改记录」入口退出预览（preview={r.get('preview')}）")
    print("   ", ui.send(["batchreview", "sleep 800"]).strip()); r = rv()
    check(r.get("preview") is True and len(r["changes"]) == len(road), f"A13 再进预览（items {len(r['changes'])}）")
    # B 翻页 / 底图
    ui.send(["reviewselect 0", "sleep 400", "reviewnext", "sleep 300"]); r = rv()
    check(r["detail"] and r["selected"] == 1, f"B1 详细页翻到第 2 项（selected={r['selected']}）")
    ui.send(["reviewprev", "sleep 300"]); check(rv()["selected"] == 0, "B2 ‹ 回到第 1 项")
    print("   ", ui.send(["reviewmap hybrid light 0"]).strip()); r = rv()
    check(r["mapStyle"] == "混合" and r["light"] is False, f"B3 底图切换 mapStyle={r['mapStyle']} light={r['light']}")
    print("   ", ui.send([f"shotwin 修改记录 {C}/br_preview_hybrid.png", "reviewmap standard light 1", "sleep 1500", f"shotwin 修改记录 {C}/br_preview_light.png"]).strip().replace("\n", " | "))
    # C 落地
    fills0 = st()["fills"]
    ui.send(["reviewdetail off", "batchland"])
    s = wait(lambda s: s.get("batch") is None and s.get("fills", 0) >= fills0 + 3, 120, 0.5)
    check(s["fills"] == fills0 + 3, f"C1 落地 3 处（fills {fills0}→{s['fills']}）")
    check(s.get("toast") and "已落地 3 处" in s["toast"], f"C2 横幅提示：{s.get('toast')}")
    wins = ui.send(["windows"]).strip()
    check("批量补点" not in wins, f"C3 批量窗口已关闭（{wins[:160]}）")
    r = rv()
    check(r.get("preview") is False and len(r["changes"]) == 3, f"C4 审阅切回真实修改记录 preview={r.get('preview')} items={len(r['changes'])}")
    withd = [it for it in r["changes"] if len(it["drafts"]) >= 1]
    check(len(withd) == 3, f"C5 落地记录都带路网草稿（{len(withd)}/3；直线那处也留着）：{[it['drafts'] for it in r['changes']]}")
    sl = [it for it in r["changes"] if it["straight"]]
    check(len(sl) == 1 and sl[0]["source"] == "", f"C5b 直线落地的记录 straight=true、source 空：{sl[:1]}")
    ui.send(["reviewselect 0", "sleep 1500", f"shotwin 修改记录 {C}/br_changes_detail.png"])
    time.sleep(1)
    ui.send(["toastdismiss"]); check(st().get("toast") is None, "C6 横幅可关闭")
finally:
    print("   ", ui.send(["crosscheck 0", "fakeroute all off", "reviewmap standard light 1", "exit"]).strip().replace("\n", " | "))
    subprocess.run(["pkill", "-f", DST], capture_output=True)
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
