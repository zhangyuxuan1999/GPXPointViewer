#!/usr/bin/env python3
"""多来源底图 + OSM 隧道叠加层（全部离线：faketiles 假瓦片、faketunnels 合成隧道，不出网）：
M1 faketiles 1 → set mapStyle OpenStreetMap：state.baseMap 变、tileRequests > 0；OpenTopoMap / Esri 影像 同样；切回 标准 → baseMap 回 Apple、tileRequests 不再增加
M2 修改记录窗口：reviewmap osm → 一次性说明弹出、dismiss 能关、记住不再弹；reviewstate.baseMap == OpenStreetMap、attribution 带 OpenStreetMap；reviewmap standard light 1 复原
M3 faketunnels 5 + tunnels 1 + 视野 10 km → state.tunnelOverlay.ways == 5、state ready；视野 200 km → tooFar、ways 0；faketunnels 0 → 自测副本不出网（failed + network disabled）；tunnels 0 → on false、ways 0
M4 署名随来源变化：state.attribution（标准 null / OSM 含 OpenStreetMap / Topo 含 OpenTopoMap / Esri 含 Esri）
结束 set mapStyle 标准、reviewmap standard light 1、tunnels 0、faketunnels 0、faketiles 0、mapnotice 还原、crosscheck 0、fakeroute all off。"""
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
def tun(s): return s.get("tunnelOverlay") or {}
subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
wait(lambda s: "points" in s, 40, 1)
notice0 = "1"
try:
    ui.send(["autotripmap 0", "place 0", "front", "tunnels 0", "faketunnels 0", "set mapStyle 标准", "sleep 300"])
    notice0 = ui.send(["mapnotice"]).strip().split()[-1]      # 一次性说明的偏好与正式版共用，结束时还原
    ui.send(["mapnotice 0"])                                   # 本次让它弹出来，顺便验证 dismiss 能关
    # ---- M1 外部底图瓦片（假瓦片）----
    print("   ", ui.send(["faketiles 1"]).strip())
    s0 = st(); check(s0.get("baseMap") == "标准" and s0.get("fakeTiles") is True, f"M1a 起点 baseMap={s0.get('baseMap')} fakeTiles={s0.get('fakeTiles')}")
    for raw, key in (("OpenStreetMap", "OpenStreetMap"), ("OpenTopoMap", "OpenTopoMap"), ("Esri 影像", "Esri")):
        ui.send(["faketiles 1", "set mapStyle %s" % raw, "mapgoto 48.137 11.575 10", "sleep 1500"])
        s = wait(lambda s: s.get("baseMap") == raw and s.get("tileRequests", 0) > 0, 20, 0.5)
        check(s.get("baseMap") == raw, f"M1b baseMap={s.get('baseMap')}（期望 {raw}）")
        check(s.get("tileRequests", 0) > 0, f"M1c {raw} 请求了假瓦片 tileRequests={s.get('tileRequests')}")
        check((s.get("attribution") or "").find(key) >= 0, f"M4 署名随来源变化：{s.get('attribution')}")
    ui.send(["set mapStyle 标准", "sleep 800"]); s1 = st()
    check(s1.get("baseMap") == "标准" and s1.get("attribution") is None, f"M1d 切回 Apple baseMap={s1.get('baseMap')} attribution={s1.get('attribution')}")
    n1 = s1.get("tileRequests"); ui.send(["mapgoto 48.2 11.7 20", "sleep 1200"]); n2 = st().get("tileRequests")
    check(n1 == n2, f"M1e 切回后不再请求瓦片（{n1} → {n2}）")
    # ---- M2 修改记录窗口 ----
    print("   ", ui.send(["review", "sleep 800", "reviewmap osm", "sleep 600"]).strip().replace("\n", " | "))
    d = ui.send(["dismiss"]).strip(); print("   ", d)   # 第一次切外部底图的一次性说明
    check(d.startswith("dismiss (click"), f"M2z 一次性说明弹出并可关闭：{d}")
    check(ui.send(["mapnotice"]).strip().endswith("1"), "M2y 弹过后记住不再弹")
    r = rv()
    check(r.get("baseMap") == "OpenStreetMap" and r.get("mapStyle") == "OpenStreetMap", f"M2a reviewstate.baseMap={r.get('baseMap')}")
    check("OpenStreetMap" in (r.get("attribution") or ""), f"M2b 审阅署名 {r.get('attribution')}")
    ui.send(["reviewmap esri", "sleep 300"]); r = rv(); check(r.get("baseMap") == "Esri 影像", f"M2c reviewmap esri → {r.get('baseMap')}")
    ui.send(["reviewmap standard light 1", "sleep 300"]); r = rv()
    check(r.get("baseMap") == "标准" and r.get("light") is True and r.get("attribution") is None, f"M2d 复原 baseMap={r.get('baseMap')} light={r.get('light')}")
    # ---- M3 隧道叠加层（合成）----
    ui.send(["faketunnels 5", "mapgoto 48.137 11.575 10", "sleep 300", "tunnels 1"])
    s = wait(lambda s: tun(s).get("ways") == 5, 30, 0.5); t = tun(s)
    check(t.get("on") is True and t.get("ways") == 5 and t.get("state") == "ready", f"M3a 合成 5 条隧道：{t}")
    r = rv(); check((r.get("tunnelOverlay") or {}).get("on") is True, f"M3b 审阅窗口也开着隧道层：{r.get('tunnelOverlay')}")
    ui.send(["mapgoto 48.137 11.575 200", "sleep 300"])
    s = wait(lambda s: tun(s).get("state") == "tooFar", 30, 0.5); t = tun(s)
    check(t.get("state") == "tooFar" and t.get("ways") == 0, f"M3c 视野 200 km → 放大后显示隧道：{t}")
    ui.send(["mapgoto 48.137 11.575 10", "sleep 300"])
    s = wait(lambda s: tun(s).get("ways") == 5, 30, 0.5); check(tun(s).get("ways") == 5, f"M3d 回到 10 km 再取回 5 条：{tun(s)}")
    ui.send(["faketunnels 3", "sleep 300"]); s = wait(lambda s: tun(s).get("ways") == 3, 30, 0.5)
    check(tun(s).get("ways") == 3, f"M3e faketunnels 3 → ways={tun(s).get('ways')}")
    ui.send(["faketunnels 0", "sleep 300"]); s = wait(lambda s: tun(s).get("state") == "failed", 30, 0.5); t = tun(s)
    check(t.get("state") == "failed" and t.get("ways") == 0 and "network disabled" in (t.get("lastError") or ""), f"M3h 自测副本不出网：faketunnels 0 → {t}")
    ui.send(["tunnels 0", "sleep 300"]); t = tun(st())
    check(t.get("on") is False and t.get("ways") == 0 and t.get("state") == "off", f"M3f tunnels 0 → {t}")
    r = rv(); check((r.get("tunnelOverlay") or {}).get("on") is False, f"M3g 审阅窗口隧道层也关了：{r.get('tunnelOverlay')}")
    print("   ", ui.send([f"shotviewwin 修改记录 {C}/ms_review.png"]).strip())
finally:
    print("   ", ui.send(["set mapStyle 标准", "reviewmap standard light 1", "tunnels 0", "faketunnels 0", "faketiles 0", "mapnotice " + notice0, "crosscheck 0", "fakeroute all off", "exit"]).strip().replace("\n", " | "))
    subprocess.run(["pkill", "-f", DST], capture_output=True)
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
