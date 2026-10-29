#!/usr/bin/env python3
"""精确模式（两路交叉验证）离线回归：用钩子 fakeroute 假引擎，不联网。
启动测试副本（Tests/ui/app.noindex），打开 Garmin_Roma_Da_copy.gpx，全部按公路，分别跑：
  A 两路一致（都 ok）→ 全部 done、cross=agree、routes 两份、普通模式不受影响
  B Valhalla 偏 25 m → 全部 conflict:disagree、draft 为空、不勾选；batchpick osrm/valhalla/straight/none 四种；batchuncheck 不碰手选；batchnextconflict 轮转；落地只落已选的
  C Valhalla fail → unverified；batchacceptunverified 全部采用
  D 两路都 fail → 引擎停用提示、公路项「服务连不上，已停止」
  E 单处 routecross：一致 / 不一致 + routeswap
  2026-10-28 加：B15/B16 分歧线引擎名标签（lineLabels）选中时 ≥2、缩到 3000 km 为 0；
  R1–R3 只有一路结果的 batchrecross <i>/all（请求 +2/处、Valhalla 恢复后变一致、非 unverified 不动）；E5/E6 单处两路进度合成一行
结束一律 crosscheck 0、fakeroute all off、crosstol off、riskthreshold off（设置与 /Applications 的 app 共用）。"""
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
def wait(pred, n=120, dt=0.5):
    for _ in range(n):
        s = st()
        if pred(s): return s
        time.sleep(dt)
    return st()
def launch():
    subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
    shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
    subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST], check=True)
    wait(lambda s: "points" in s, 40, 1)
def batch_items():
    s = st(); return s["batch"]["items"], s["batch"]
def plan_all_road():
    ui.send(["batchclose", "sleep 300", "batchplan", "sleep 800"])
    wait(lambda s: not s.get("tripMapRunning"), 60, 0.5)
    ui.send(["batchall road", "sleep 300"])
def run_to_preview():
    print("   ", ui.send(["batchrun"]).strip())
    return wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 240, 0.5)
try:
    launch()
    ui.send(["autotripmap 0", "place 0", "front", "open %s/Garmin_Roma_Da_copy.gpx" % C])   # 不自动查 Overpass 判段：整条链路不出网
    wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500"])
    s = st(); print(f"文件 {s['points']} 点 · 候选 {s['candidates']}")
    # riskthreshold 100：落地前自检（2026-10-27）会把 high 的项默认不勾选，这里只测交叉验证逻辑，先把门槛抬到没有 high
    print("   ", ui.send(["crosscheck 1", "fakeroute all ok", "riskthreshold 100"]).strip().replace("\n", " | "))

    # ---- A 两路一致 ----
    plan_all_road(); s = run_to_preview()
    items, b = batch_items(); road = [it for it in items if it["kind"] == "road"]
    agree = [it for it in road if it["cross"] == "agree"]
    check(b["crossCheck"] is True, "A0 state.batch.crossCheck = true")
    check(len(road) > 10, f"A1 公路项 {len(road)} 处")
    check(len(agree) == len(road) and all(it["status"] == "done" and it["include"] for it in road), f"A2 全部 done+agree+勾选（agree {len(agree)}/{len(road)}）")
    check(all(len(it["routes"]) == 2 for it in road), "A3 每处 routes 两份")
    check(b["counts"]["agree"] == len(road) and b["counts"]["disagree"] == 0 and b["counts"]["unverified"] == 0, f"A4 counts {b['counts']}")
    check(all(it["source"] == "osrmCar" for it in road), "A5 一致时默认采用 OSRM（警告/偏移相同）")
    check(b["engineDisabled"] is None, "A6 无停用提示")
    r = ui.send(["batchswap 0", "state"]).strip().splitlines()
    items, b = batch_items()
    check(items[0]["source"] == "valhallaCar" and items[0]["picked"] is True and items[0]["include"], f"A7 改用另一条 → source={items[0]['source']} picked={items[0]['picked']}")

    # ---- B 两路不一致 ----
    print("   ", ui.send(["fakeroute valhalla offset 25"]).strip())
    plan_all_road(); s = run_to_preview()
    items, b = batch_items(); road = [it for it in items if it["kind"] == "road"]
    dis = [it for it in road if it["status"] == "conflict:disagree"]
    check(len(dis) == len(road), f"B1 全部 conflict:disagree（{len(dis)}/{len(road)}）")
    check(all(it["meters"] == -1 and not it["include"] and len(it["routes"]) == 2 for it in dis), "B2 待选项 draft 为空、不勾选、routes 两份")
    check(all(it["cross"] == "disagree" and (it["diverge"] or 0) > 40 for it in dis), f"B3 cross=disagree、分歧段 >40 m（首项 {dis[0]['diverge']}）")
    check(b["included"] == 0 and b["counts"]["disagree"] == len(road), f"B4 included=0 counts={b['counts']}")
    check(b["lines"] >= 2 * len(road), f"B5 覆盖层两路都画（lines {b['lines']} ≥ {2*len(road)}）")
    idx = [i for i, it in enumerate(items) if it["status"] == "conflict:disagree"]
    i0, i1, i2, i3 = idx[0], idx[1], idx[2], idx[3]
    print("   ", ui.send([f"batchpick {i0} osrm", f"batchpick {i1} valhalla", f"batchpick {i2} straight", f"batchpick {i3} none"]).strip().replace("\n", " | "))
    items, b = batch_items()
    check(items[i0]["status"] == "done" and items[i0]["source"] == "osrmCar" and items[i0]["include"] and items[i0]["picked"], f"B6 选 OSRM → {items[i0]['status']} {items[i0]['source']}")
    check(items[i1]["status"] == "done" and items[i1]["source"] == "valhallaCar" and items[i1]["include"], f"B7 选 Valhalla → {items[i1]['source']}")
    check(items[i2]["status"] == "done" and items[i2]["straight"] and items[i2]["include"] and items[i2]["meters"] == -1, "B8 选直线 → useStraight、落地")
    check(items[i3]["status"] == "conflict:disagree" and items[i3]["declined"] and not items[i3]["include"] and items[i3]["picked"], f"B9 都不补 → 仍待选但 declined（{items[i3]['status']} declined={items[i3]['declined']}）")
    check(b["included"] == 3 and b["counts"]["disagree"] == len(road) - 4 and b["counts"]["pending"] == len(road) - 4 and b["counts"]["declined"] == 1, f"B10 included=3 counts={b['counts']}")
    # 都不补可改选；已选定的也可改选
    ui.send([f"batchpick {i3} osrm", f"batchpick {i0} valhalla"]); items, b = batch_items()
    check(items[i3]["status"] == "done" and items[i3]["source"] == "osrmCar" and not items[i3]["declined"] and items[i3]["include"], "B9b 「都不补」后改选 OSRM → done")
    check(items[i0]["status"] == "done" and items[i0]["source"] == "valhallaCar" and items[i0]["include"], "B9c 已选 OSRM 的改选 Valhalla → done valhallaCar")
    ui.send([f"batchpick {i3} none"]); items, b = batch_items()
    check(items[i3]["status"] == "conflict:disagree" and items[i3]["declined"] and b["included"] == 3, "B9d 选定后再「都不补」→ 回到待选、不落地")
    before = b["included"]
    ui.send(["batchuncheck"]); items, b = batch_items()
    check(b["included"] == before, f"B11 「取消勾选直接」不碰手选的（included {b['included']}）")
    # 一致项的两份草稿都带说明：改用另一条后 notes/warnings 不丢（用 A 场景的 agree 项检查需要重跑；这里只验证 routes 两份都在）
    check(all(len(it["routes"]) == 2 for it in items if it["status"] == "conflict:disagree"), "B11b 待选项两份草稿都保留")
    # 对待选项的勾选/直线开关无效
    ui.send([f"batchdeleteonly {items[idx[4]]['id']} 1"]); items, b = batch_items()
    check(items[idx[4]]["status"] == "conflict:disagree" and not items[idx[4]]["include"], "B12 待选项不受只删点开关影响")
    r1 = ui.send(["batchnextconflict"]).strip(); r2 = ui.send(["batchnextconflict"]).strip()
    check("selected=" in r1 and r1 != r2, f"B13 下一处要选 轮转：{r1} → {r2}")
    # 分歧线上标引擎名（2026-10-28）：选中的待选项飞过去后两条蓝线都有标签；缩到 3000 km 看不清时隐藏
    s = wait(lambda s: (s["batch"].get("lineLabels") or 0) >= 2, 30, 0.5); b = s["batch"]
    check((b.get("lineLabels") or 0) >= 2, f"B15 选中待选项后 lineLabels {b.get('lineLabels')} ≥ 2（lines {b['lines']}）")
    ui.send(["mapgoto 45 11 3000", "sleep 1500"]); b = st()["batch"]
    check(b.get("lineLabels") == 0 and b["lines"] >= 2, f"B16 缩到 3000 km：lineLabels {b.get('lineLabels')} = 0（lines {b['lines']} 仍画）")
    fills_before = st()["fills"]
    ui.send(["batchland"])
    # 落地是 main.async 再后台重建：batch 置空抢在 fills 更新之前，要等 fills 计数（见记忆 run_review_tests 的坑）
    s = wait(lambda s: s.get("batch") is None and s.get("fills", 0) >= fills_before + 3, 120, 0.5)
    check(s["fills"] == fills_before + 3, f"B14 落地只落已选的 3 处（fills {fills_before} → {s['fills']}）")

    # ---- C 只有一路 ----
    print("   ", ui.send(["fakeroute valhalla fail"]).strip())
    plan_all_road(); s = run_to_preview()
    items, b = batch_items(); road = [it for it in items if it["kind"] == "road"]
    unv = [it for it in road if it["status"] == "conflict:unverified"]
    check(len(unv) == len(road) and all(len(it["routes"]) == 1 and it["cross"] == "unverified" for it in unv), f"C1 全部 unverified（{len(unv)}/{len(road)}）")
    check(b["engineDisabled"] is not None and "Valhalla" in b["engineDisabled"], f"C2 停用提示：{b['engineDisabled']}")
    # 「只有一路结果」一键重新比对（2026-10-28）：Valhalla 恢复后重比这一处 → 两路各 1 个请求、变成一致
    i0 = next(i for i, it in enumerate(items) if it["status"] == "conflict:unverified")
    req0 = b["requests"]
    print("   ", ui.send(["fakeroute valhalla ok"]).strip())
    r = ui.send([f"batchrecross {i0}"]).strip().splitlines()[-1]
    s = wait(lambda s: s["batch"]["items"][i0]["status"] not in ("running", "conflict:unverified"), 60, 0.5)
    b = s["batch"]; it = b["items"][i0]
    check("started=true" in r and b["requests"] == req0 + 2 and it["status"] == "done" and it["cross"] == "agree" and len(it["routes"]) == 2,
          f"R1 batchrecross {i0}：{r} → requests {req0}→{b['requests']} status={it['status']} cross={it['cross']}")
    r = ui.send([f"batchrecross {i0}"]).strip().splitlines()[-1]
    check("started=false" in r, f"R2 已不是 unverified 的项不重取：{r}")
    print("   ", ui.send(["fakeroute valhalla fail"]).strip())
    b = st()["batch"]; n_unv = b["counts"]["unverified"]; req1 = b["requests"]
    r = ui.send(["batchrecross all"]).strip().splitlines()[-1]
    s = wait(lambda s: not any(x["status"] == "running" for x in s["batch"]["items"]) and s["batch"]["requests"] >= req1 + 2 * n_unv, 120, 0.5)
    b = s["batch"]
    check(f"started={n_unv}" in r and b["requests"] == req1 + 2 * n_unv and b["counts"]["unverified"] == n_unv and b["items"][i0]["status"] == "done",
          f"R3 batchrecross all：{r} requests {req1}→{b['requests']}（+{2*n_unv}）unverified {b['counts']['unverified']}，已一致的那处不动")
    ui.send(["batchacceptunverified"]); items, b = batch_items()
    check(b["counts"]["unverified"] == 0 and all(it["status"] == "done" and it["include"] and it["source"] == "osrmCar" for it in items if it["kind"] == "road"), "C3 全部采用唯一结果")

    # ---- D 两路都连不上 ----
    print("   ", ui.send(["fakeroute all fail"]).strip())
    plan_all_road(); s = run_to_preview()
    items, b = batch_items(); road = [it for it in items if it["kind"] == "road"]
    failed = [it for it in road if it["status"].startswith("failed")]
    check(len(failed) == len(road), f"D1 全部失败（{len(failed)}/{len(road)}）")
    check(b["engineDisabled"] is not None and "两路" in b["engineDisabled"], f"D2 两路停用提示：{b['engineDisabled']}")
    check(sum(1 for it in failed if "已停止" in it["status"]) >= len(road) - 6, f"D3 停用后其余标「已停止」（{sum(1 for it in failed if '已停止' in it['status'])}）")

    # ---- 普通模式不受影响 ----
    print("   ", ui.send(["crosscheck 0", "fakeroute all ok"]).strip().replace("\n", " | "))
    plan_all_road(); s = run_to_preview()
    items, b = batch_items(); road = [it for it in items if it["kind"] == "road"]
    check(b["crossCheck"] is False and all(it["status"] == "done" and it["cross"] == "none" and len(it["routes"]) == 0 for it in road), "N1 普通模式：done、无比对、routes 空")
    srcs = {it["source"] for it in road}
    check(srcs == {"osrmCar", "valhallaCar"}, f"N2 普通模式两路分活 {srcs}")
    ui.send(["batchclose", "sleep 300"])

    # ---- E 单处交叉验证 ----
    ui.send(["fakeroute all ok", "select 0", "sleep 500"])
    r = ui.send(["routecross"]).strip(); s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 40, 0.5)
    check(s["route"] is not None and s["cross"] and s["cross"]["agree"] is True, f"E1 单处一致：{s.get('cross')}")
    ui.send(["fakeroute valhalla offset 25", "routecross"]); s = wait(lambda s: s.get("routeBusy") is None and s.get("cross") and not s["cross"]["agree"], 40, 0.5)
    check(s["cross"] and s["cross"]["agree"] is False and s["cross"]["shown"] == "osrmCar" and s["route"]["warnings"] >= 1, f"E2 单处不一致：{s.get('cross')} warnings={s['route']['warnings']}")
    r = ui.send(["routeswap"]).strip(); s = st()
    check("valhallaCar" in r and s["route"]["source"] == "valhallaCar", f"E3 换看 → {r} route.source={s['route']['source']}")
    r = ui.send(["routeswap"]).strip(); s = st()
    check(s["route"]["source"] == "osrmCar", "E4 再换回 OSRM")
    # 单处两路进度合成一行（2026-10-28）：Valhalla 慢 4 s → 中途「OSRM ✓ · Valhalla 取路中…」，结束后清空
    ui.send(["fakeroute all ok", "fakeroute valhalla slow 4000", "routecross"])
    s = wait(lambda s: s.get("crossLegs") == [1, 0], 20, 0.25)
    prog = s.get("routeProgress") or ""
    check(s.get("routeBusy") is not None and prog.startswith("OSRM ✓ · Valhalla") and "\n" not in prog and prog.count(" · ") == 1,
          f"E5 合并进度行：{prog!r} crossLegs={s.get('crossLegs')}")
    s = wait(lambda s: s.get("routeBusy") is None, 40, 0.5)
    check(s.get("routeProgress") is None and s.get("cross") and s["cross"]["agree"] is True, f"E6 取完进度清空、两路一致：{s.get('routeProgress')} {s.get('cross')}")
finally:
    print("   ", ui.send(["crosscheck 0", "fakeroute all off", "crosstol off", "riskthreshold off", "exit"]).strip().replace("\n", " | "))
    subprocess.run(["pkill", "-f", DST], capture_output=True)
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
