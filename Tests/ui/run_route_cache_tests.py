#!/usr/bin/env python3
"""路网结果缓存 / 重新获取 / 修改记录两路切换（假引擎，不联网；autotripmap 0 防 batchplan 查 Overpass）：
D0 精确模式 fakeroute all ok 跑完第 2 步：requestsByHost 两台主机各 = 发请求的公路项数、cacheHits 0、routecache entries = 2 × 项数
D1 batchclose → batchplan → batchall road → batchrun：requestsByHost 空（没再请求）、cacheHits = 公路项数、各项 routes/source/cross 与第一次一致
D2 batchrefetch all：requestsByHost 两台各 = 项数、cacheHits 0
D3 batchrefetch <i>：只那一项两台各 +1；其它项状态/来源/勾选/手选不变
D6 batchreview + reviewselect 0：reviewdraft valhalla/osrm/next、翻页复位、sameGeometry（ok 时 true；Valhalla 偏 30 m 重取后 false）
D4 routecache stats entries>0；open 另一份文件后 entries=0
D5 单处 routecross 两次：第二次 notes 带「来自缓存」且不增请求；routerefetch 增请求、notes 不带
结束 crosscheck 0、fakeroute all off、reviewmap standard light 1、fillpoints 0。"""
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
def cache_stats():
    r = ui.send(["routecache stats"]).strip()
    d = dict(kv.split("=") for kv in r.split())
    return int(d.get("entries", -1)), int(d.get("hits", -1))
def hosts(b):
    h = b.get("requestsByHost", {})
    return h.get("routing.openstreetmap.de", 0), h.get("valhalla1.openstreetmap.de", 0)
def road_items(items):
    return [it for it in items if it["kind"] == "road" and len(it["routes"]) == 2]
def sig(it):
    return (it["status"], it["source"], it["cross"], it["meters"], [(r["engine"], r["meters"], r["method"]) for r in it["routes"]])
def plan_and_run():
    ui.send(["batchclose", "sleep 300", "batchplan", "sleep 800"])
    wait(lambda s: not s.get("tripMapRunning"), 60, 0.5)
    ui.send(["batchall road", "sleep 200", "batchrun"])
    return wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview", 240, 0.5)
subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
wait(lambda s: "points" in s, 40, 1)
try:
    ui.send(["autotripmap 0", "place 0", "front", "open %s/Garmin_Roma_Da_copy.gpx" % C]); wait(lambda s: not s.get("loading") and s.get("points"), 120)
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "crosscheck 1", "fakeroute all ok", "routecache clear"])
    # ---- D0 第一次：全部真"请求"（假引擎也计数）----
    s = plan_and_run(); b1 = s["batch"]; items1 = b1["items"]; road1 = road_items(items1)
    n = len(road1)
    check(n > 10 and all(it["status"] == "done" and it["cross"] == "agree" for it in road1), f"D0a 公路项 {n} 处全部 done+agree")
    o, v = hosts(b1)
    check(o == n and v == n, f"D0b 两台主机各 {o}/{v} 个请求 = 公路项数 {n}")
    check(b1["cacheHits"] == 0, f"D0c 第一次 cacheHits={b1['cacheHits']}")
    e, h = cache_stats()
    check(e == 2 * n and h == 0, f"D0d routecache entries={e}（= 2×{n}）hits={h}")
    sig1 = {it["id"]: sig(it) for it in items1}
    # ---- D1 关掉再来：全部命中缓存，不再请求 ----
    s = plan_and_run(); b2 = s["batch"]; items2 = b2["items"]
    o, v = hosts(b2)
    check(o == 0 and v == 0 and b2["requests"] == 0, f"D1a 第二次没有请求（requestsByHost={b2['requestsByHost']} requests={b2['requests']}）")
    check(b2["cacheHits"] == n, f"D1b cacheHits={b2['cacheHits']} = 公路项数 {n}")
    same = sum(1 for it in items2 if sig1.get(it["id"]) == sig(it))
    check(same == len(items2), f"D1c 各项 routes/source/cross 与第一次一致（{same}/{len(items2)}）")
    e, h = cache_stats()
    check(e == 2 * n and h == 2 * n, f"D1d entries={e} hits={h}（两路各命中 {n}）")
    # ---- D2 重新获取全部 ----
    print("   ", ui.send(["batchrefetch all"]).strip())
    s = wait(lambda s: s.get("batch") and s["batch"]["phase"] == "preview" and s["batch"]["requests"] > 0, 240, 0.5)
    b3 = s["batch"]; o, v = hosts(b3)
    check(b3["phase"] == "preview" and o == n and v == n, f"D2a 重新获取全部：两台各 {o}/{v} 个请求（= {n}）")
    check(b3["cacheHits"] == 0, f"D2b cacheHits={b3['cacheHits']}")
    e, h = cache_stats()
    check(e == 2 * n, f"D2c entries 仍 {e}（覆盖，不新增）")
    # ---- D3 只重取一项 ----
    items3 = b3["items"]
    idx = [i for i, it in enumerate(items3) if it["kind"] == "road" and len(it["routes"]) == 2]
    i0, i1 = idx[0], idx[1]
    ui.send([f"batchswap {i0}"]); s = st(); items3 = s["batch"]["items"]
    check(items3[i0]["source"] == "valhallaCar" and items3[i0]["picked"], f"D3a 先把第 {i0} 项改用 Valhalla（手选）")
    before = {it["id"]: sig(it) + (it["include"], it["picked"]) for it in items3}
    o0, v0 = hosts(s["batch"])
    print("   ", ui.send([f"batchrefetch {i1}"]).strip())
    s = wait(lambda s: s.get("batch") and s["batch"]["items"][i1]["status"] != "running", 60, 0.3)
    b4 = s["batch"]; items4 = b4["items"]; o, v = hosts(b4)
    check(o == o0 + 1 and v == v0 + 1, f"D3b 只多了两路各 1 个请求（{o0}/{v0} → {o}/{v}）")
    check(items4[i1]["status"] == "done" and items4[i1]["cross"] == "agree" and items4[i1]["include"], f"D3c 第 {i1} 项重取后 done+agree+勾选")
    others_same = all(before[it["id"]] == sig(it) + (it["include"], it["picked"]) for j, it in enumerate(items4) if j != i1)
    check(others_same and items4[i0]["source"] == "valhallaCar" and items4[i0]["picked"], f"D3d 其它项状态/勾选/手选不变（第 {i0} 项仍 Valhalla 手选）")
    check(b4["cacheHits"] == 0 and b4["phase"] == "preview", f"D3e 仍在预览、cacheHits={b4['cacheHits']}")
    # ---- D6 修改记录两路切换 ----
    print("   ", ui.send(["batchreview", "sleep 1200"]).strip())
    ui.send(["reviewselect 0", "sleep 400"]); r = rv()
    adopted0 = st()["batch"]["items"][0]["source"]
    check(r.get("preview") is True and r.get("detail") is True and r.get("shownDraft") == adopted0, f"D6a 详细页默认显示采用的那份 shownDraft={r.get('shownDraft')}（采用 {adopted0}）")
    check(r.get("sameGeometry") is True, f"D6b 假引擎 ok：sameGeometry={r.get('sameGeometry')}")
    print("   ", ui.send(["reviewdraft valhalla"]).strip()); r = rv()
    check(r.get("shownDraft") == "valhallaCar", f"D6c reviewdraft valhalla → {r.get('shownDraft')}")
    s = st(); check(s["batch"]["items"][0]["source"] == adopted0, "D6d 切换显示不改采用")
    print("   ", ui.send(["reviewdraft osrm"]).strip()); r = rv()
    check(r.get("shownDraft") == "osrmCar", f"D6e reviewdraft osrm → {r.get('shownDraft')}")
    ui.send(["reviewdraft next"]); r = rv(); check(r.get("shownDraft") == "valhallaCar", f"D6f next → {r.get('shownDraft')}")
    ui.send(["reviewnext", "sleep 300"]); r = rv()
    # 第 2 处的采用份：预览列表按轨迹顺序，与批量表同序 → 第 2 个有两路草稿的公路项
    adopted1 = [it for it in st()["batch"]["items"] if it["kind"] == "road" and len(it["routes"]) == 2][1]["source"]
    check(r.get("selected") == 1 and r.get("shownDraft") == adopted1, f"D6g 翻页后显示份复位为采用的（selected={r.get('selected')} shownDraft={r.get('shownDraft')} 采用 {adopted1}）")
    ui.send(["reviewprev", "sleep 300"]); r = rv()
    check(r.get("selected") == 0 and r.get("shownDraft") == adopted0, f"D6h 翻回第 1 处显示份 = 采用的（{r.get('shownDraft')}）")
    print("   ", ui.send([f"shotviewwin 修改记录 {C}/rc_review_toggle.png"]).strip())
    # Valhalla 偏 30 m 重取第 1 处 → 两路不一致，几何不同
    first_road = [i for i, it in enumerate(st()["batch"]["items"]) if it["kind"] == "road" and len(it["routes"]) == 2][0]
    print("   ", ui.send(["fakeroute valhalla offset 30", f"batchrefetch {first_road}"]).strip().replace("\n", " | "))
    s = wait(lambda s: s.get("batch") and s["batch"]["items"][first_road]["status"] != "running", 60, 0.3)
    check(s["batch"]["items"][first_road]["status"] == "conflict:disagree", f"D6i 重取后两路不一致：{s['batch']['items'][first_road]['status']}")
    ui.send(["reviewselect 0", "sleep 500"]); r = rv()
    check(r.get("sameGeometry") is False and len(r["changes"][0]["drafts"]) == 2, f"D6j sameGeometry={r.get('sameGeometry')} drafts={r['changes'][0]['drafts']}")
    ui.send(["reviewdraft valhalla"]); r = rv(); check(r.get("shownDraft") == "valhallaCar", f"D6k 待选项也能切换显示 → {r.get('shownDraft')}")
    print("   ", ui.send(["reviewdetail off"]).strip())
    # ---- D4 换文件清空（fakeroute 换模式本身也会清缓存，所以 D4a 看的是 offset 30 重取后留下的 2 条）----
    e, h = cache_stats()
    check(e > 0, f"D4a 换文件前 entries={e}")
    ui.send(["batchclose", "exit", "open %s/Garmin_Roma_Da.gpx" % C]); wait(lambda s: not s.get("loading") and s.get("points"), 120)
    print("   ", ui.send(["fakeroute all ok"]).strip())
    e, h = cache_stats()
    check(e == 0 and h == 0, f"D4b 换文件后 entries={e} hits={h}")
    rc = st().get("routeCache")
    check(rc == {"entries": 0, "hits": 0}, f"D4c state.routeCache={rc}")
    # ---- D5 单处 ----
    ui.send(["fill", "sleep 1500", "select 0", "sleep 500", "routecross"])
    s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 40, 0.5)
    notes = s["route"]["notes"] if s.get("route") else []
    check(s["cross"] and s["cross"]["agree"] is True and not any("来自缓存" in x for x in notes), f"D5a 第一次 routecross：一致、不带缓存说明（notes {len(notes)} 条）")
    e1, h1 = cache_stats()
    check(e1 == 2 and h1 == 0, f"D5b entries={e1} hits={h1}")
    ui.send(["routecross"]); s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 40, 0.5)
    notes = s["route"]["notes"]
    e2, h2 = cache_stats()
    check(any("来自缓存" in x for x in notes) and e2 == 2 and h2 == 2, f"D5c 第二次：notes 带「来自缓存」、hits {h1}→{h2}、entries {e2}")
    ui.send(["routerefetch"]); s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 40, 0.5)
    notes = s["route"]["notes"]
    e3, h3 = cache_stats()
    check(not any("来自缓存" in x for x in notes) and h3 == 2 and e3 == 2, f"D5d routerefetch：不带缓存说明、hits 不变（{h3}）、entries {e3}")
    # 单处「沿公路取路径（OSRM）」与交叉验证的 OSRM 腿输入完全相同（同 economy=false）→ 共用同一条缓存
    r = ui.send(["route car"]).strip(); s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 40, 0.5)
    e4, h4 = cache_stats()
    check(e4 == 2 and h4 == 3 and s["route"]["source"] == "osrmCar" and any("来自缓存" in x for x in s["route"]["notes"]), f"D5e 单处 OSRM 取路命中交叉验证留下的缓存 entries={e4} hits={h4}")
finally:
    print("   ", ui.send(["crosscheck 0", "fakeroute all off", "reviewmap standard light 1", "fillpoints 0", "exit"]).strip().replace("\n", " | "))
    subprocess.run(["pkill", "-f", DST], capture_output=True)
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
