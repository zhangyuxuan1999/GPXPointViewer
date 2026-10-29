#!/usr/bin/env python3
"""补点「落地前自检」（FillPlausibility，docs/fill-plausibility-design.md §1）钩子回归。假引擎，不联网；autotripmap 0。
数据：Garmin_Roma_Da_copy.gpx（容器 tmp/uitest；缺就从 data/ 拷）。
P0 state 字段齐全：batch.items[] 每项都有 risk / riskLevel / riskReasons，batch.counts 有 high / medium
P1 fakeroute all ok（普通模式）：有草稿的公路项 risk 非 null、没有 high、≥80% low（假引擎的直弦没有几何缺陷；少数带停车的
   长断档会因「按时长算车速」偏低记 medium，是合理的「留意」）；low 的 riskReasons 为空
P2 fakeroute valhalla offset 30：Valhalla 做的项补点离「路网原始折线」30 m → risk 升到 high、reasons 非空、默认不勾选（include false）、
   counts.high ≥ 1；OSRM 做的项仍 low
P3 riskthreshold 100 → batchrefetch all：同样的 offset 项变成 medium、include true、counts.high == 0；riskthreshold off 回 50
P4 单处：fakeroute all ok，select 一处 → route car → state.route 有 risk/riskLevel/riskReasons（low）；apply → confirm replace →
   reviewstate.changes[0].risk 非 null、riskLevel == "low"；reviewrevert 0 还原
R1（2026-10-28）replay 钩子：录音拷进容器 → 开 Muenchen_Roma_Garmin.gpx → replay → 真实题 real_14_tusch 锚点 selectnear → route car：
   netRequests 不变（不出网）、replayHits 增加、取到 osrmCar 草稿
结束 replay off、crosscheck 0、fakeroute all off、riskthreshold off。"""
import ui, json, time, os, sys, subprocess, shutil
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "data/Garmin_Roma_Da_copy.gpx")
GPX = os.path.join(C, "Garmin_Roma_Da_copy.gpx")
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
def plan_and_run():
    ui.send(["batchclose", "sleep 300", "batchplan", "sleep 800"])
    wait(lambda s: not s.get("tripMapRunning"), 60, 0.5)
    ui.send(["batchall road", "sleep 200", "batchrun"])
    return wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 300, 0.5)
def drafted(items):
    return [it for it in items if it["kind"] == "road" and it["status"] == "done" and it["source"] in ("osrmCar", "valhallaCar")]

os.makedirs(C, exist_ok=True)
if not os.path.exists(GPX): shutil.copyfile(SRC, GPX)
subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
wait(lambda s: "points" in s, 40, 1)
try:
    print("   ", ui.send(["autotripmap 0", "place 0", "front", "riskthreshold off", "open " + GPX]).strip().replace("\n", " | "))
    wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "crosscheck 0", "fakeroute all ok", "routecache clear"])
    # ---- P0 / P1 ----
    s = plan_and_run(); b = s["batch"]; items = b["items"]; d = drafted(items)
    keys_ok = all(all(k in it for k in ("risk", "riskLevel", "riskReasons")) for it in items)
    check(keys_ok and "high" in b["counts"] and "medium" in b["counts"], f"P0 字段齐全：items {len(items)} 项都有 risk/riskLevel/riskReasons；counts={b['counts']}")
    n = len(d); lows = [it for it in d if it["riskLevel"] == "low"]; highs = [it for it in d if it["riskLevel"] == "high"]
    nonnull = all(it["risk"] is not None for it in d)
    # 假引擎的直弦不是真路：弯道上「路线末段方向与 B 侧行进方向差」会扣 10–25，少数带停车的长断档「按时长算车速」会扣，所以允许少量 medium
    for it in highs: print(f"      high 项 {it['id']}: risk={it['risk']} ckind={it['ckind']} reasons={it['riskReasons']}")
    check(n > 10 and nonnull and len(highs) <= 0.02 * n and len(lows) >= 0.75 * n, f"P1a fakeroute all ok：有草稿 {n} 处，risk 非 null={nonnull}，low {len(lows)}（≥75%），high {len(highs)}（≤2%），counts.high={b['counts']['high']}")
    check(all(it["risk"] <= 19 for it in lows) and all(it["riskReasons"] == [] for it in lows if it["risk"] == 0), "P1b low 项 risk ≤ 19，risk 0 的 riskReasons 为空")
    med = [it for it in d if it["riskLevel"] == "medium"]
    for it in med[:3]: print(f"      medium 示例 {it['id']}: risk={it['risk']} reasons={it['riskReasons']}")
    # ---- P2 Valhalla 偏 30 m ----
    ui.send(["fakeroute valhalla offset 30"])
    s = plan_and_run(); b = s["batch"]; items = b["items"]; d = drafted(items)
    v = [it for it in d if it["source"] == "valhallaCar"]; o = [it for it in d if it["source"] == "osrmCar"]
    vh = [it for it in v if it["riskLevel"] == "high" and it["riskReasons"] and not it["include"]]
    check(len(v) > 0 and len(vh) >= 0.95 * len(v), f"P2a Valhalla 偏 30 m 的 {len(v)} 处 ≥95% high + reasons 非空 + 默认不勾选（{len(vh)}）；counts.high={b['counts']['high']}")
    for it in v:
        if it not in vh: print(f"      未判 high 的 Valhalla 项 {it['id']}: risk={it['risk']} level={it['riskLevel']} include={it['include']} ckind={it['ckind']} reasons={it['riskReasons']}")
    if v: print(f"      示例 {v[0]['id']}: risk={v[0]['risk']} reasons={v[0]['riskReasons']}")
    check(b["counts"]["high"] >= 1 and b["counts"]["high"] == len([it for it in d if it["riskLevel"] == "high"]), f"P2b counts.high={b['counts']['high']} 与 high 项数一致")
    check(len(o) > 0 and all(it["riskLevel"] != "high" for it in o), f"P2c OSRM 做的 {len(o)} 处没有 high")
    # ---- P3 riskthreshold ----
    # risk 最高100；门槛设100后high归零。通常保留30m偏移的项转medium；retime裁掉全部偏移的low项仍可为low，P3a按≥95%判。
    print("   ", ui.send(["riskthreshold 100"]).strip())
    ui.send(["batchrefetch all"])
    s = wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 300, 0.5); b = s["batch"]; d = drafted(b["items"])
    v = [it for it in d if it["source"] == "valhallaCar"]
    vm = [it for it in v if it["riskLevel"] == "medium" and it["include"]]
    check(len(v) > 0 and len(vm) >= 0.95 * len(v) and b["counts"]["high"] == 0, f"P3a riskthreshold 100：Valhalla {len(v)} 处变 medium + 勾选（{len(vm)}）；counts.high={b['counts']['high']} medium={b['counts']['medium']}")
    r = ui.send(["riskthreshold off"]).strip()
    check(r.endswith("50"), f"P3b riskthreshold off → {r}")
    # ---- P4 单处 ----
    ui.send(["fakeroute all ok", "batchclose", "sleep 300", "exit", "sleep 300", "fill", "sleep 1500"])
    s = wait(lambda s: not s.get("refreshing") and s.get("candidates", 0) > 0, 40, 0.5)
    ui.send(["select 0", "sleep 300", "route car"])
    s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 60, 0.5)
    r = s.get("route") or {}
    check(all(k in r for k in ("risk", "riskLevel", "riskReasons")) and r.get("risk") is not None and r.get("riskLevel") in ("low", "medium"),
          f"P4a 单处 route：risk={r.get('risk')} level={r.get('riskLevel')} reasons={r.get('riskReasons')}")
    n0 = s["points"]
    ui.send(["apply", "sleep 600"]); s = st()
    if s.get("prompt"):
        ui.send(["confirm replace"]); s = wait(lambda s: not s.get("loading") and s.get("points") != n0, 120, 0.5); s = wait(lambda s: not s.get("loading"), 60, 0.5)
    ch = rv().get("changes", [])
    c0 = ch[0] if ch else {}
    check(len(ch) == 1 and c0.get("risk") is not None and c0.get("riskLevel") == r.get("riskLevel"), f"P4b reviewstate changes={len(ch)} risk={c0.get('risk')} level={c0.get('riskLevel')}")
    ui.send(["reviewrevert 0"]); s = wait(lambda s: not s.get("loading") and s.get("points") == n0, 120, 0.5)
    check(s["points"] == n0, f"P4c 还原后点数 {s['points']}（原 {n0}）")
    # ---- U：界面接线（2026-10-27 Opus）----
    import math
    def km(a, b):
        p1, p2 = math.radians(a[0]), math.radians(b[0]); dl = math.radians(b[1] - a[1])
        h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
        return 12742 * math.asin(math.sqrt(h))
    ui.send(["fakeroute valhalla offset 30", "exit", "sleep 300", "fill", "sleep 1500"])
    s = plan_and_run(); b = s["batch"]; items = b["items"]
    look = [it for it in items if it["riskLevel"] in ("medium", "high")]
    print("   ", ui.send(["openbatch", "sleep 1200", "batchriskonly 1", "sleep 300"]).strip().replace("\n", " | "))
    b = st()["batch"]
    check(len(look) > 0 and b["riskOnly"] and b["visibleCount"] == len(look) and all(it["risk"] >= 20 for it in look),
          f"U1a batchriskonly 1：visibleCount={b['visibleCount']}，risk ≥ 20 的项 {len(look)}（共 {len(items)}）")
    ui.send(["batchriskonly 0", "sleep 300"]); b = st()["batch"]
    check(not b["riskOnly"] and b["visibleCount"] == len(items), f"U1b batchriskonly 0：visibleCount={b['visibleCount']}（共 {len(items)}）")
    sz0 = b.get("windowSize")
    ui.send(["batchcompact 1", "sleep 2000"]); b = st()["batch"]; sz = b.get("windowSize"); ch_ = b.get("cardContentHeight", 0)
    check(sz is not None and ch_ > 60 and ch_ <= sz[1] <= ch_ + 60 and sz[1] != 300,
          f"U2a batchcompact 1：windowSize={sz}，卡片内容高 {ch_}（窗口高应在 [{ch_}, {ch_ + 60}]，不再固定 300）")
    ui.send(["batchcompact 0", "sleep 1500"]); b = st()["batch"]
    check(b.get("windowSize") == sz0 and not b["compact"], f"U2b batchcompact 0：windowSize={b.get('windowSize')}（进入前 {sz0}）")
    print("   ", ui.send(["batchreview", "sleep 1500", "reviewselect 2", "sleep 800", "reviewfollow 1", "reviewnext", "sleep 2500"]).strip().replace("\n", " | "))
    r = rv(); chs = r.get("changes", []); i = r.get("selected", -1)
    c = r.get("mainMapCenter"); it = chs[i] if 0 <= i < len(chs) else None
    d = km(c, (it["lat"], it["lon"])) if c and it else 99
    check(r.get("followMap") is True and i == 3 and d < 2.0, f"U3a reviewfollow 1 + reviewnext：selected={i} 主地图中心距该处 {d:.2f} km（中心 {c}）")
    ui.send(["reviewfollow 0", "reviewnext", "sleep 2000"]); r2 = rv(); c2 = r2.get("mainMapCenter")
    moved = km(c, c2) if c and c2 else 99
    check(r2.get("followMap") is False and r2.get("selected") == 4 and moved < 0.05, f"U3b reviewfollow 0 + reviewnext：selected={r2.get('selected')} 中心移动 {moved:.3f} km（应不变）")
    check(len(chs) > 0 and all(isinstance(x.get("riskReasons"), list) for x in chs) and all("risk" in x and "riskLevel" in x for x in chs),
          f"U4 reviewstate.changes[] {len(chs)} 项 riskReasons 都是数组（示例 {chs[0].get('riskReasons') if chs else None}）")

    # ---- R1 replay 钩子（2026-10-28）：考卷录音回放下单处 route car 不出网且取到草稿 ----
    # 真实题 real_14_tusch（Muenchen_Roma_Garmin.gpx，锚点 9732→9734；冻结链会把 A 前移到 9728，与考卷 runner 同口径）。
    # 沙盒副本读不到仓库目录：录音拷进容器 tmp/uitest/exam_recordings
    q = json.load(open(os.path.join(ROOT, "Tests/exam/questions/real_14_tusch.json")))
    mgpx = os.path.join(C, "Muenchen_Roma_Garmin.gpx")
    if not os.path.exists(mgpx): shutil.copy(os.path.join(ROOT, q["source"]), mgpx)
    rec = os.path.join(C, "exam_recordings")
    shutil.rmtree(rec, ignore_errors=True); shutil.copytree(os.path.join(ROOT, "Tests/exam/recordings"), rec)
    pts_before = st().get("points")
    ui.send(["batchclose", "sleep 300", "exit", "sleep 300", "fakeroute all off", "crosscheck 0", "open %s" % mgpx, "sleep 1500"])
    wait(lambda s: not s.get("loading") and s.get("points") and s.get("points") != pts_before, 120)
    print("   ", ui.send(["replay %s" % rec]).strip())
    ui.send(["fill", "sleep 1500", "selectnear %.7f %.7f" % (q["anchorA"]["lat"], q["anchorA"]["lon"]), "sleep 800"])
    s0 = st(); net0, hit0 = s0.get("netRequests"), s0.get("replayHits", 0)
    print("   ", ui.send(["route car"]).strip())
    s = wait(lambda s: s.get("routeBusy") is None and (s.get("route") is not None or s.get("error")), 60, 0.5)
    r = s.get("route") or {}
    check(s.get("netRequests") == net0 and net0 is not None, f"R1a replay 下 route car 不出网：netRequests {net0} → {s.get('netRequests')}")
    check(s.get("replayHits", 0) > hit0 and r.get("source") == "osrmCar" and s.get("vertexCount", 0) > 0,
          f"R1b 取到草稿：replayHits {hit0} → {s.get('replayHits')}，misses {s.get('replayMisses')}，route={ {k: r.get(k) for k in ('source', 'meters', 'method')} } vertexCount={s.get('vertexCount')}，A={s.get('anchorA')} B={s.get('anchorB')}")
finally:
    print("   ", ui.send(["replay off", "batchriskonly 0", "batchcompact 0", "reviewfollow 0", "crosscheck 0", "fakeroute all off", "riskthreshold off", "exit"]).strip().replace("\n", " | "))
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
