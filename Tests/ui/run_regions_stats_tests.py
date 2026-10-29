#!/usr/bin/env python3
"""地区统计（RegionIndex / RegionStats / 「地区统计」窗口）回归。

数据：合成边界 Tests/synth/regions_synthetic.bin（两个假国家，见 Tools/build_regions.py build_synthetic：
  阿尔法国 AA = 经 0–2° 纬 0–2°，下设 甲州（经 0–1°，再分 甲一市 纬 0–1 / 甲二市 纬 1–2）与 乙州（经 1–2°）；
  贝塔国 BB = 经 2–4° 纬 0–2°，下设 丙州 = 整个国家但中间挖了一个洞（经 2.5–3.5° 纬 0.5–1.5°，洞里只归贝塔国）），
合成轨迹由本脚本生成（已知落点与日期），真实 .fwdb 用 data/2026.fwdb（合成边界下全部未归属，验存档口径与空结果路径）。
自己启动/关闭测试副本（一次只能开一个）。用法：python3 Tests/ui/run_regions_stats_tests.py
退出码 0 = 全过。每项打印 PASS/FAIL 与细节，最后汇总。
"""
import os, sys, json, time, shutil, subprocess, datetime, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ui

HOME = os.environ["HOME"]
C = HOME + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp"
UIT = C + "/uitest"
RDIR = C + "/regions"
SP = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(os.path.dirname(SP))
DST = SP + "/app.noindex/GPXPointViewer.app"
BIN = PROJ + "/Tests/synth/regions_synthetic.bin"
FWDB = PROJ + "/data/2026.fwdb"

results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + ("  — " + str(detail) if detail else ""))
    return ok

def gen_track(path):
    pts = []
    def add(lat, lon, day, n, step=0.0005):
        for i in range(n):
            t = datetime.datetime(2026, 1, day, 8, 0, 0) + datetime.timedelta(seconds=10 * i)
            pts.append((lat + step * i, lon, t))
    add(0.5, 0.5, 1, 100)   # 甲一市 100 点 day1
    add(1.5, 0.5, 1, 60)    # 甲二市 60 点 day1
    add(1.5, 0.5, 2, 40)    # 甲二市 40 点 day2 → 到访 2 天
    add(1.0, 1.5, 3, 50)    # 乙州 50 点 day3
    add(0.2, 2.2, 4, 30)    # 丙州 30 点 day4
    add(1.0, 3.0, 4, 20)    # 丙州的洞 → 只归贝塔国 20 点 day4
    add(5.0, 5.0, 5, 10)    # 海上 → 未归属 10 点
    with open(path, "w") as f:
        f.write('<?xml version="1.0"?>\n<gpx version="1.1" creator="probe"><trk><name>regions probe</name><trkseg>\n')
        for la, lo, t in pts:
            f.write(f'<trkpt lat="{la:.6f}" lon="{lo:.6f}"><time>{t.strftime("%Y-%m-%dT%H:%M:%SZ")}</time></trkpt>\n')
        f.write('</trkseg></trk></gpx>\n')
    return len(pts)

def kill():
    subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)

def launch(extra_env):
    kill()
    src = ui.app_source(); print("testing", src)
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    if os.path.exists(DST): shutil.rmtree(DST)
    shutil.copytree(src, DST, symlinks=True)
    cmd = ["open", "-n", "--env", "GPXPV_UITEST_DIR=" + UIT]
    for k, v in extra_env.items(): cmd += ["--env", f"{k}={v}"]
    cmd += [DST, "--args", "-AppleLanguages", "(zh-Hans)"]
    subprocess.run(cmd, check=True)
    for _ in range(60):
        time.sleep(1)
        if "points" in ui.state(): return True
    return False

def regionstate():
    r = ui.send(["regionstate"]).strip().splitlines()[-1]
    try: return json.loads(r)
    except Exception: return {"raw": r}

def wait_ready(timeout=30, mode=None):
    """等报告就绪；切口径后旧报告可能还挂着几十毫秒，传 mode 可同时要求口径已切换，避免读到旧报告"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = regionstate()
        if st.get("ready") and (mode is None or st.get("mode") == mode): return st
        time.sleep(0.3)
    return regionstate()

def wait_points(n, timeout=30):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if ui.state().get("points") == n: return True
        time.sleep(0.3)
    return False

def flatten(nodes, out=None):
    out = {} if out is None else out
    for n in nodes:
        out[n["name"]] = n
        flatten(n.get("children", []), out)
    return out

def main():
    os.makedirs(UIT, exist_ok=True); os.makedirs(RDIR, exist_ok=True)
    shutil.copy(BIN, RDIR + "/regions_synthetic.bin")
    gpx = RDIR + "/synthetic_regions_track.gpx"; n_pts = gen_track(gpx)
    fw = RDIR + "/2026.fwdb"
    if os.path.isdir(FWDB):
        if os.path.exists(fw): shutil.rmtree(fw)
        shutil.copytree(FWDB, fw)

    # ---------- A. 合成边界 + 合成轨迹 ----------
    if not check("A0 启动（GPXPV_REGIONS_BIN=合成边界）", launch({"GPXPV_REGIONS_BIN": RDIR + "/regions_synthetic.bin"})): return finish()
    st = ui.state()
    check("A1 state.regionsIndex 为 true", st.get("regionsIndex") is True, st.get("regionsIndex"))
    rs = regionstate()
    check("A2 regionstate：index=true, regions=7", rs.get("index") is True and rs.get("regions") == 7, {k: rs.get(k) for k in ("index", "regions", "ready")})

    probes = [("0.5 0.5", "3:甲一市 < 1:甲州 < 0:阿尔法国"), ("1.5 0.5", "4:甲二市 < 1:甲州 < 0:阿尔法国"),
              ("1.0 1.5", "2:乙州 < 0:阿尔法国"), ("0.2 2.2", "6:丙州 < 5:贝塔国"), ("1.0 3.0", "5:贝塔国"),
              ("5 5", "none"), ("-0.001 0.5", "none"), ("1.999 3.999", "6:丙州 < 5:贝塔国"), ("0.5 1.9999", "2:乙州 < 0:阿尔法国"),
              ("0.5 2.49", "6:丙州 < 5:贝塔国"), ("0.5 2.51", "6:丙州 < 5:贝塔国"), ("1.0 3.0", "5:贝塔国"), ("91 0", "none"), ("0 181", "none")]   # 洞边 ≤3 km 吸附到丙州，洞中心仍是国家直属
    out = ui.send(["regionlookup " + p for p, _ in probes]).strip().splitlines()
    for (p, exp), got in zip(probes, out):
        want = "regionlookup: none" if exp == "none" else "regionlookup " + exp
        check(f"A3 lookup {p}", got.strip() == want, f"got {got.strip()!r}")
    check("A3 lookup 参数不足给用法", ui.send(["regionlookup 1"]).strip().startswith("regionlookup <lat> <lon>"))

    ui.send(["open " + gpx]); check("A4 载入合成轨迹", wait_points(n_pts), f"points={ui.state().get('points')} 期望 {n_pts}")
    r = ui.send(["regions"]).strip(); check("A5 regions 命令打开窗口", r == "regions true", r)
    time.sleep(0.6)
    w = ui.send(["windows"]); check("A6 windows 列表里有「地区统计」", "地区统计" in w, w[:160])
    ui.send(["regionsmode points"])
    rs = wait_ready(mode="points"); check("A7 点口径报告就绪", rs.get("ready") is True and rs.get("mode") == "points", {k: rs.get(k) for k in ("ready", "mode")})
    check("A8 总点数 / 未归属", rs.get("totalPoints") == n_pts and rs.get("unassignedPoints") == 10, {k: rs.get(k) for k in ("totalPoints", "unassignedPoints")})
    f = flatten(rs.get("countries", []))
    exp = {"阿尔法国": (250, 3, 2, 2), "甲州": (200, 2, 2, 2), "甲一市": (100, 1, 0, 0), "甲二市": (100, 2, 0, 0),
           "乙州": (50, 1, 0, 0), "贝塔国": (50, 1, 1, 1), "丙州": (30, 1, 0, 0)}
    for name, (pts, days, childTotal, childVisited) in exp.items():
        n = f.get(name)
        ok = n and n["points"] == pts and n["days"] == days and n["childTotal"] == childTotal and len(n["children"]) == childVisited
        check(f"A9 {name} 点数/天数/下级", ok, n and {k: n[k] for k in ("points", "days", "childTotal")} | {"childrenVisited": len(n["children"])} if n else "缺")
    names = [c["name"] for c in rs.get("countries", [])]
    check("A10 国家按点数降序", names == ["阿尔法国", "贝塔国"], names)
    kids = [c["name"] for c in f["阿尔法国"]["children"]] if "阿尔法国" in f else []
    check("A11 阿尔法国下级按点数降序", kids == ["甲州", "乙州"], kids)
    check("A12 国家 iso / 级别", f.get("阿尔法国", {}).get("iso") == "AA" and f.get("甲一市", {}).get("level") == 2, {n: (f[n].get("iso"), f[n].get("level")) for n in f})

    ui.send(["regionsmode fog"])
    rs = wait_ready(mode="fog"); check("B1 迷雾口径报告就绪", rs.get("ready") is True and rs.get("mode") == "fog", {k: rs.get(k) for k in ("ready", "mode")})
    f = flatten(rs.get("countries", []))
    check("B2 totalCells>0 且未归属格>0（海上点）", rs.get("totalCells", 0) > 0 and rs.get("unassignedCells", 0) > 0, {k: rs.get(k) for k in ("totalCells", "unassignedCells")})
    check("B3 两国都有格子，点数字段为 0", all(f.get(n, {}).get("cells", 0) > 0 and f.get(n, {}).get("points") == 0 for n in ("阿尔法国", "贝塔国")), {n: f.get(n, {}).get("cells") for n in ("阿尔法国", "贝塔国")})
    if "阿尔法国" in f and "贝塔国" in f:
        a = f["阿尔法国"]; b = f["贝塔国"]
        check("B4 阿尔法国格数 = 甲州 + 乙州（无直属）", a["cells"] == sum(c["cells"] for c in a["children"]), (a["cells"], [c["cells"] for c in a["children"]]))
        check("B5 甲州格数 = 甲一市 + 甲二市", f["甲州"]["cells"] == f["甲一市"]["cells"] + f["甲二市"]["cells"], (f["甲州"]["cells"], f["甲一市"]["cells"], f["甲二市"]["cells"]))
        check("B6 贝塔国格数 > 丙州（洞里的格子直属国家）", b["cells"] > f["丙州"]["cells"] > 0, (b["cells"], f["丙州"]["cells"]))
        check("B7 km² 单调（父 ≥ 子）且 >0", a["km2"] >= f["甲州"]["km2"] >= f["甲一市"]["km2"] > 0, (a["km2"], f["甲州"]["km2"], f["甲一市"]["km2"]))
        for n in f:
            lv = int(math.sqrt(max(0.0, f[n]["km2"] * 250)))
            check(f"B8 {n} 等级 = ⌊√(km²×250)⌋", f[n]["lv"] == lv, (f[n]["lv"], lv, f[n]["km2"]))
        sumc = sum(c["km2"] for c in rs["countries"]); check("B9 两国 km² 之和 ≤ 全部（未归属不计入）", sumc > 0, sumc)
        # 面积量级：每格约 (9.55 m)² ≈ 9.1e-5 km²（赤道附近，纬度 0–2°）
        per = a["km2"] / a["cells"]; check("B10 赤道附近每格面积 ≈ 9.1e-5 km²", 8.8e-5 < per < 9.3e-5, per)
    r = ui.send(["regionsmode points"]).strip(); rs = wait_ready(mode="points")
    f2 = flatten(rs.get("countries", []))
    check("B11 切回点口径数字不变", rs.get("mode") == "points" and f2.get("甲二市", {}).get("points") == 100 and f2.get("甲二市", {}).get("days") == 2, {k: f2.get("甲二市", {}).get(k) for k in ("points", "days")})
    r = ui.send(["regionsmode nonsense"]).strip(); check("B12 非法口径给用法", r.startswith("regionsmode: points|fog"), r)

    r = ui.send(["regionselect 3"]).strip(); time.sleep(1.2); rs = regionstate()
    check("C1 regionselect 3 → 选中 + 1 个高亮多边形", r == "regionselect 3" and rs.get("selection") == 3 and rs.get("highlightPolys") == 1, (r, rs.get("selection"), rs.get("highlightPolys")))
    check("C1b state.regionSelection 同步", ui.state().get("regionSelection") == 3, ui.state().get("regionSelection"))
    r = ui.send(["regionselect 6"]).strip(); time.sleep(1.2); rs = regionstate()
    check("C2 带洞的丙州 → 仍是 1 个多边形（洞作内环）", rs.get("selection") == 6 and rs.get("highlightPolys") == 1, (rs.get("selection"), rs.get("highlightPolys")))
    r = ui.send(["regionselect 99"]).strip(); check("C3 不存在的 id 报错且选中不变", r.startswith("regionselect: no region") and regionstate().get("selection") == 6, r)
    r = ui.send(["regionselect off"]).strip(); time.sleep(1.0); rs = regionstate()
    check("C4 regionselect off → 清除高亮", r == "regionselect off" and rs.get("selection") is None and rs.get("highlightPolys") == 0, (rs.get("selection"), rs.get("highlightPolys")))

    # 换数据：选中清空、报告重算
    ui.send(["regionselect 3"]); time.sleep(0.8)
    ui.send(["open " + gpx]); wait_points(n_pts); time.sleep(0.8); rs = wait_ready()
    check("C5 重新载入轨迹后选中清空、报告重算就绪", rs.get("selection") is None and rs.get("highlightPolys") == 0 and rs.get("ready") is True, (rs.get("selection"), rs.get("highlightPolys"), rs.get("ready")))

    ui.send(["regionselect 3"]); time.sleep(0.8)
    ui.send(["regionsmode fog"]); rs = wait_ready(mode="fog"); time.sleep(0.5); rs = regionstate()
    check("C6 只换口径不清高亮", rs.get("selection") == 3 and rs.get("highlightPolys") == 1, (rs.get("selection"), rs.get("highlightPolys")))
    ui.send(["regionsmode points"]); wait_ready(mode="points"); ui.send(["regionselect off"]); time.sleep(0.5)

    # ---------- D. 真实 .fwdb（合成边界 → 全部未归属） ----------
    if os.path.isdir(fw):
        ui.send(["open " + fw])
        t0 = time.time(); modes = None
        while time.time() - t0 < 40:
            rs = regionstate(); modes = rs.get("modes")
            if modes == ["fog"]: break
            time.sleep(0.5)
        check("D1 载入 .fwdb 后只有迷雾口径", modes == ["fog"], modes)
        ui.send(["regions"]); rs = wait_ready(60)
        check("D2 存档报告就绪、口径=fog", rs.get("ready") is True and rs.get("mode") == "fog", {k: rs.get(k) for k in ("ready", "mode")})
        check("D3 存档格数 >0 且在合成边界下全部未归属、无国家", rs.get("totalCells", 0) > 0 and rs.get("unassignedCells") == rs.get("totalCells") and rs.get("countries") == [], {k: rs.get(k) for k in ("totalCells", "unassignedCells")} | {"countries": len(rs.get("countries", []))})
        r = ui.send(["regionsmode points"]).strip(); rs = regionstate()
        check("D4 存档下切点口径被拒（仍是 fog）", rs.get("mode") == "fog", (r, rs.get("mode")))
    else:
        check("D0 data/2026.fwdb 存在", False, "缺 data/2026.fwdb，跳过 D 组")

    # ---------- E. 不带环境变量：app 内置 Regions.bin（占位/真实） ----------
    if check("E0 重启（内置 Regions.bin）", launch({})):
        rs = regionstate(); st = ui.state()
        check("E1 内置索引可加载（index=true）", rs.get("index") is True and st.get("regionsIndex") is True, {k: rs.get(k) for k in ("index", "regions")})
        print("INFO 内置 Regions.bin 地区数 =", rs.get("regions"), "（0 = 占位文件，真实边界数据接入后应 >0）")
        ui.send(["open " + gpx]); wait_points(n_pts); ui.send(["regions"]); time.sleep(2); rs = regionstate()
        if rs.get("regions") == 0:
            check("E2 占位边界：不算报告（ready=false）、不崩溃", rs.get("ready") is False and ui.state().get("points") == n_pts, {k: rs.get(k) for k in ("ready", "regions")})
            check("E4 占位边界：lookup 为 none", ui.send(["regionlookup 0.5 0.5"]).strip() == "regionlookup: none")
        else:
            rs = wait_ready(); check("E2 内置真实边界下报告就绪", rs.get("ready") is True, rs.get("ready"))
            print("INFO 内置边界下合成轨迹的国家：", [c["name"] for c in rs.get("countries", [])])
    return finish()

def finish():
    kill()
    ok = sum(1 for _, p, _ in results if p); bad = [n for n, p, _ in results if not p]
    print(f"\n== {ok}/{len(results)} 通过" + ("" if not bad else "；失败：" + "、".join(bad)))
    return 0 if not bad else 1

if __name__ == "__main__":
    sys.exit(main())
