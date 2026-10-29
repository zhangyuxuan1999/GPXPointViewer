#!/usr/bin/env python3
"""隧道补点修复：过时时钟点「保留位置、只改时间」（StaleRetime，诊断报告 §1.4）钩子回归。
假引擎 fakeroute all ok（不联网；弦上 3 个中间点——Tusch 那处 9733 离 9728→9734 的弦约 1 m，够用）；autotripmap 0。
数据：Muenchen_Roma_Garmin.gpx（容器 tmp/uitest；缺就从 data/compare 拷）。
T1 selectnear 46.503401 11.457193（原 9732）→ 候选 A 已前移到 9728（冻结链 9729–9732），B = 9734
T2 route car → apply：确认框 promptRetimed == 1、promptInsert = 合成点数
T3 confirm replace：点数变化 = +合成点 − 4（冻结点删掉；9733 旧点删 + 新点加，不算）
T4 pointfind 9733 坐标：距离 < 1 m、时间 23:12:21 ±1 s（原 23:12:14）
T5 reviewstate：retimed == 1、removed == 4、added == 合成点数
T6 reviewrevert：点数回原值、9733 时间回 23:12:14
T7 对照：没有冻结链的 staleClock 候选 iA=21676：retimed ≤ 离弦 ≤ max(半径,10) m 的区间内点数，removed = 区间内点数 − retimed，
   点数变化 = added − removed；还原后点数回原值
结束 crosscheck 0、fakeroute all off；测试副本留着（可接着跑 run_fill_tests.py）。"""
import ui, json, time, os, sys, subprocess, shutil, re, math, calendar
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "data/compare/Muenchen_Roma_Garmin.gpx")
GPX = os.path.join(C, "Muenchen_Roma_Garmin.gpx")
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
def js(cmd):
    r = ui.send([cmd]).strip().splitlines()[-1]
    try: return json.loads(r)
    except Exception: return {"raw": r}
def wait(pred, n=120, dt=0.5):
    for _ in range(n):
        s = st()
        if pred(s): return s
        time.sleep(dt)
    return st()
def utc(s):
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
def hav(a, b):
    R = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))
def seg_dist(q, a, b):
    kx = 111320.0 * math.cos(math.radians(a[0])); ky = 110540.0
    ax, ay = 0.0, 0.0
    bx, by = (b[1] - a[1]) * kx, (b[0] - a[0]) * ky
    qx, qy = (q[1] - a[1]) * kx, (q[0] - a[0]) * ky
    L2 = bx * bx + by * by
    t = max(0.0, min(1.0, (qx * bx + qy * by) / L2)) if L2 > 0 else 0.0
    return math.hypot(qx - bx * t, qy - by * t)

# 数据：缺就从仓库拷；按 trkpt 下标读坐标/时间（与 TrackData 下标一致：文件已按时间有序）
os.makedirs(C, exist_ok=True)
if not os.path.exists(GPX): shutil.copyfile(SRC, GPX)
text = open(GPX, encoding="utf-8").read()
P = [(float(la), float(lo), re.search(r"<time>(.*?)</time>", body).group(1))
     for la, lo, body in re.findall(r'<trkpt[^>]*lat="([-\d.]+)"[^>]*lon="([-\d.]+)"[^>]*>(.*?)</trkpt>', text, re.S)]
N0 = len(P)
P9733 = P[9733]; T9733 = utc(P9733[2]); TB = utc(P[9734][2])
print(f"    data {N0} trkpt; 9733 = ({P9733[0]:.8f}, {P9733[1]:.8f}) {P9733[2]}; 9734 {P[9734][2]}")

subprocess.run(["pkill", "-f", DST], capture_output=True); time.sleep(1.5)
shutil.rmtree(DST, ignore_errors=True); shutil.copytree(ui.app_source(), DST, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, DST, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
wait(lambda s: "points" in s, 40, 1)
try:
    print("   ", ui.send(["autotripmap 0", "fakeroute all ok", "crosscheck 0", "place 0", "front"]).strip().replace("\n", " | "))
    ui.send(["open " + GPX]); s = wait(lambda s: not s.get("loading") and s.get("points"), 120)
    check(s["points"] == N0, f"T0 载入 {s['points']} 点（文件 {N0}）")
    ui.send(["exit", "sleep 300", "fill", "sleep 1500"])
    s = wait(lambda s: not s.get("refreshing") and s.get("candidates", 0) > 0, 40, 0.5)
    print(f"    candidates={s['candidates']} profile={s.get('profile')}")
    # ---- T1 选第 14 处 ----
    print("   ", ui.send(["selectnear 46.503401 11.457193", "sleep 500"]).strip())
    s = st()
    check(s["anchorA"] == 9728 and s["anchorB"] == 9734, f"T1 anchorA={s['anchorA']}（期望 9728）anchorB={s['anchorB']}（期望 9734）")
    # ---- T2 取路（假引擎）→ apply ----
    print("   ", ui.send(["route car"]).strip())
    s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 60, 0.5)
    check(s.get("route") is not None and s["anchorA"] == 9728 and s["anchorB"] == 9734,
          f"T2a 取到草稿 vertices={s['route']['vertices'] if s.get('route') else None} 锚点仍 {s['anchorA']}/{s['anchorB']}")
    print("   ", ui.send(["apply", "sleep 600"]).strip())
    s = st()
    ins, ret = s.get("promptInsert", -1), s.get("promptRetimed", -1)
    check(s["prompt"] and ret == 1 and ins > 0, f"T2b 确认框 prompt={s['prompt']} insert={ins} retimed={ret}（期望 retimed 1）")
    # ---- T3 替换落地 ----
    print("   ", ui.send(["confirm replace"]).strip())
    s = wait(lambda s: not s.get("loading") and s.get("points") and s["points"] != N0, 120, 0.5)
    s = wait(lambda s: not s.get("loading"), 60, 0.5)
    d = s["points"] - N0
    check(d == ins - 4, f"T3 点数 {N0} → {s['points']}（变化 {d:+d}，期望 +{ins} − 4 = {ins - 4:+d}）")
    # ---- T4 9733 保留位置、时间回推 ----
    f = js(f"pointfind {P9733[0]:.8f} {P9733[1]:.8f}")
    t = f.get("time", 0)
    check(f.get("dist", 99) < 1 and T9733 + 6 <= t <= T9733 + 8,
          f"T4 9733 仍在：dist={f.get('dist')} m，time={time.strftime('%H:%M:%S', time.gmtime(t))}（原 {P9733[2][11:19]}，期望 23:12:21±1；B {P[9734][2][11:19]}）index={f.get('index')}")
    # ---- T5 修改记录 ----
    r = rv(); ch = r.get("changes", [])
    c0 = ch[0] if ch else {}
    check(len(ch) == 1 and c0.get("retimed") == 1 and c0.get("removed") == 4 and c0.get("added") == ins,
          f"T5 reviewstate changes={len(ch)} retimed={c0.get('retimed')} removed={c0.get('removed')} added={c0.get('added')}（期望 1/4/{ins}）")
    # ---- T6 还原 ----
    print("   ", ui.send(["reviewrevert 0"]).strip())
    s = wait(lambda s: not s.get("loading") and s.get("points") == N0, 120, 0.5)
    p = js("pointat 9733")
    check(s["points"] == N0 and abs(p.get("time", 0) - T9733) < 0.5 and abs(p.get("lat", 0) - P9733[0]) < 1e-7,
          f"T6 还原后点数 {s['points']}（原 {N0}）、9733 time={time.strftime('%H:%M:%S', time.gmtime(p.get('time', 0)))}（期望 {P9733[2][11:19]}）")
    # ---- T7 对照：21676（没有冻结链的 staleClock）----
    ui.send(["exit", "sleep 300", "fill", "sleep 1500"])
    wait(lambda s: not s.get("refreshing") and s.get("candidates", 0) > 0, 40, 0.5)
    print("   ", ui.send([f"selectnear {P[21676][0]:.8f} {P[21676][1]:.8f}", "sleep 500"]).strip())
    s = st(); ia, ib = s["anchorA"], s["anchorB"]
    check(ia == 21676 and ib is not None and ib - ia > 1, f"T7a 选中 anchorA={ia} anchorB={ib}")
    radius = max((s.get("profile") or {}).get("radius", 15), 10)
    ui.send(["route car"]); s = wait(lambda s: s.get("routeBusy") is None and s.get("route"), 60, 0.5)
    inner = list(range(ia + 1, ib))
    # 假引擎的折线是 A→B 直弦（中间点在弦上）：离弦 ≤ 半径的区间内点才可能改时
    near = [k for k in inner if seg_dist(P[k][:2], P[ia][:2], P[ib][:2]) <= radius]
    dists = {k: round(seg_dist(P[k][:2], P[ia][:2], P[ib][:2]), 1) for k in inner}
    print(f"    21676: inner={len(inner)} 离弦(m)={dists} 半径={radius} near={near}")
    print("   ", ui.send(["apply", "sleep 600"]).strip())
    s = st(); ins2, ret2 = s.get("promptInsert", -1), s.get("promptRetimed", -1)
    check(s["prompt"] and 0 <= ret2 <= len(near), f"T7b 确认框 insert={ins2} retimed={ret2}（≤ 离弦 ≤{radius:.0f} m 的 {len(near)} 点）")
    n1 = s["points"]
    print("   ", ui.send(["confirm replace"]).strip())
    s = wait(lambda s: not s.get("loading") and s.get("points") != n1, 120, 0.5)
    s = wait(lambda s: not s.get("loading"), 60, 0.5)
    r = rv(); ch = r.get("changes", []); c1 = ch[-1] if ch else {}
    check(c1.get("retimed") == ret2 and c1.get("removed") == len(inner) - ret2 and c1.get("added") == ins2
          and s["points"] - n1 == c1.get("added", 0) - c1.get("removed", 0),
          f"T7c retimed={c1.get('retimed')} removed={c1.get('removed')}（期望 {len(inner)} − {ret2}）added={c1.get('added')}（期望 {ins2}）点数变化 {s['points'] - n1:+d}")
    for k in inner:
        if k in near:
            q = js(f"pointfind {P[k][0]:.8f} {P[k][1]:.8f}")
            print(f"    inner {k}: 原 {P[k][2][11:19]} → 现在最近点 dist={q.get('dist')} time={time.strftime('%H:%M:%S', time.gmtime(q.get('time', 0)))}")
    print("   ", ui.send([f"reviewrevert {len(ch) - 1}"]).strip())
    s = wait(lambda s: not s.get("loading") and s.get("points") == N0, 120, 0.5)
    check(s["points"] == N0, f"T7d 还原后点数 {s['points']}（原 {N0}）")
finally:
    print("   ", ui.send(["crosscheck 0", "fakeroute all off", "exit"]).strip().replace("\n", " | "))
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
