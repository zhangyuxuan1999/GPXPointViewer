#!/usr/bin/env python3
"""乱跳清理：回放点一键清理（RE1）、乱跳候选进批量（铁路隧道处补路径、其余只删点）、Garmin 专用记录仪零误报、手机 CSV 计数、单处只删点。
用法：run_jitter_tests.py [--no-network]"""
import ui, json, time, os, sys, subprocess, shutil
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
SP = os.path.dirname(os.path.abspath(__file__))
NONET = "--no-network" in sys.argv
fails = []
def check(c, l):
    print(("    ok   " if c else "    FAIL ") + l)
    if not c: fails.append(l)
def st():
    for _ in range(6):
        s = ui.state()
        if "trips" in s: return s
        time.sleep(2)
    return s
def wait_idle(n=120):
    for _ in range(n):
        s = st()
        if not s.get("loading") and s.get("points"): return s
        time.sleep(0.5)
    return st()
def relaunch():
    subprocess.run(["pkill", "-f", SP + "/app.noindex/GPXPointViewer.app"], capture_output=True); time.sleep(1.5)
    src = ui.app_source()
    dst = SP + "/app.noindex/GPXPointViewer.app"; os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst): shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, dst, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
    for _ in range(60):
        time.sleep(1)
        s = ui.state()
        if "points" in s: return s
    raise SystemExit("app did not come up")
relaunch()
def open_file(name):
    ui.send(["place 0", "front", "open %s/%s" % (C, name)]); s = wait_idle()
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "roadonly 0", "findjitter on"])
    return st()

# ---- J1 RE1：回放点与乱跳候选
s = open_file("RE1.gpx")
print(f"\n== RE1: {s['points']} 点 · 候选 {s['candidates']} · 乱跳 {s['jitter']} · 回放点 {s['replays']}")
print("   乱跳：", ui.send(["jitter"]).strip()[:600])
check(s["replays"] > 4000 and s["replays"] < 5200, f"J1a RE1 回放点 {s['replays']}（期望 4600 ± 500）")
check(s["jitter"] >= 3, f"J1b RE1 乱跳候选 {s['jitter']}（期望 ≥3）")
pts0 = s["points"]; rep0 = s["replays"]
r = ui.send(["cleanreplays"]); print("   ", r.strip())
for _ in range(60):
    s = st()
    if s.get("changes", 0) >= 1 and not s.get("loading"): break
    time.sleep(0.5)
check(s["changes"] == 1 and s["points"] == pts0 - rep0, f"J1c 清理后 修改记录 {s['changes']} · 点 {pts0}→{s['points']}（应减 {rep0}）")
check(s["replays"] == 0, f"J1d 清理后再检测回放点 {s['replays']}（应为 0）")
rv = json.loads(ui.send(["reviewstate"]).strip().splitlines()[-1])
check(rv["changes"] and rv["changes"][0]["kind"] == "replay" and rv["changes"][0]["removed"] == rep0, f"J1e 修改记录类型 {rv['changes'][0]['kind'] if rv['changes'] else None} 删 {rv['changes'][0]['removed'] if rv['changes'] else None}")
s = st(); print(f"   清理后：候选 {s['candidates']} · 乱跳 {s['jitter']}"); print("   乱跳：", ui.send(["jitter"]).strip()[:600])
check(s["jitter"] >= 2, f"J1f 清理后乱跳候选 {s['jitter']}（期望 ≥2）")
# 关掉找乱跳 → 乱跳候选为 0
r = ui.send(["findjitter off"]); s = st()
check(s["jitter"] == 0, f"J1g 关掉找乱跳后乱跳候选 {s['jitter']}")
ui.send(["findjitter on"]); s = st()

# ---- J2 批量：铁路隧道处补路径，其余只删点
if not NONET:
    ui.send(["batchplan", "sleep 1000"])
    for _ in range(600):
        s = st()
        if not s.get("tripMapRunning"): break
        time.sleep(1)
    print("   地图判段：" + " ".join(f"段{t['i']}={t['kind']}({t['gaps']}处)" for t in s["trips"] if t["gaps"] > 0))
    b = s["batch"]
    if not any(it["kind"] == "rail" for it in b["items"]):
        for t in s["trips"]:
            if t["gaps"] > 0: print("  ", ui.send([f"trip {t['i']} rail"]).strip())
        s = st(); b = s["batch"]
    jit = [it for it in b["items"] if it["ckind"] == "jitter"]
    print(f"   批次 {len(b['items'])} 处，其中乱跳 {len(jit)}：" + " ".join(f"{it['kind']}/{it['inner']}pt" for it in jit))
    t1 = time.time(); ui.send(["batchrun"])
    for _ in range(1200):
        s = st(); b = s.get("batch")
        if b and b["phase"] == "preview": break
        time.sleep(1)
    print(f"   取草稿 {time.time()-t1:.0f}s · phase {b['phase']} · 请求 {b['requests']} · 网络：{s.get('network')}")
    jit = [it for it in b["items"] if it["ckind"] == "jitter"]
    for it in jit: print(f"     {it['status'][:120]} | {it['kind']} {it['method']} inner {it['inner']} deleteOnly {it['deleteOnly']} include {it['include']}")
    done = [it for it in jit if it["status"] == "done" and it["method"] != "deleteOnly"]
    dels = [it for it in jit if it["deleteOnly"]]
    if b["phase"] != "preview":
        print("    SKIP J2a/J2d：路网服务没在 20 分钟内跑完（公共 Overpass 限流），落地断言跳过")
    else:
        check(len(done) + len(dels) >= 1 and not any(it["status"].startswith("failed") for it in jit), f"J2a 乱跳候选都处理完（取到路径 {len(done)}、只删点 {len(dels)}、失败 {sum(1 for it in jit if it['status'].startswith('failed'))}）")   # 隧道乒乒球现多被判为回放点，不再要求乱跳簇本身取到隧道路径
    check(all(it["include"] for it in jit if it["status"].startswith("nottunnel")), "J2b 不像隧道的乱跳处默认只删点落地")
    check(len(b["items"]) > 0 and all(not it["include"] or it["status"] == "done" or it["deleteOnly"] or it["straight"] for it in b["items"]), "J2c 勾选落地的都有草稿/直线/只删点")
    pts1 = s["points"]; ch1 = s["changes"]
    ui.send(["batchland"])
    for _ in range(120):
        s = st()
        if s.get("changes", 0) > ch1 and not s.get("loading"): break
        time.sleep(0.5)
    inner_del = sum(it["inner"] for it in jit if it["include"])
    print(f"   落地：点 {pts1}→{s['points']} · 修改记录 {ch1}→{s['changes']}（乱跳区间内点合计 {inner_del}）")
    if b["phase"] == "preview": check(s["changes"] > ch1 and s["points"] < pts1 + 5000, f"J2d 落地成功，点数变化合理")
    ui.send(["batchclose"])

# ---- J3 Garmin 专用记录仪：零误报
s = open_file("Garmin_Roma_Da.gpx")
print(f"\n== Garmin: {s['points']} 点 · 候选 {s['candidates']} · 乱跳 {s['jitter']} · 回放点 {s['replays']}")
check(s["replays"] == 0 and s["jitter"] == 0, f"J3a Garmin 回放点 {s['replays']} 乱跳 {s['jitter']}（都应为 0）")
check(s["candidates"] == 97, f"J3b Garmin 候选 {s['candidates']}（应为 97，与上一版相同）")

# ---- J4 手机 CSV：计数与批量规划
s = open_file("2026.csv")
print(f"\n== 2026.csv: {s['points']} 点 · 候选 {s['candidates']} · 乱跳 {s['jitter']} · 回放点 {s['replays']}")
check(10000 < s["replays"] < 20000, f"J4a 手机回放点 {s['replays']}（期望 1.0–2.0 万）")
check(200 < s["jitter"] < 500, f"J4b 手机乱跳候选 {s['jitter']}（期望 200–500）")
ui.send(["findjitter off"]); s2 = st()
check(s2["candidates"] == 192 and s2["jitter"] == 0, f"J4c 关掉找乱跳：候选 {s2['candidates']}（应为 192）")
ui.send(["findjitter on"]); s = st()
# 单处只删点：找一个弦很短的乱跳候选
import re as _re
raw = ui.send(["jitter"]).strip()
# 每项：序号:MM-ddTHH:mm/innerN/jJ/rR/maxM/mD/vV（时间里的空格已换成 T）
lst = _re.findall(r"(\d+):\S+?/inner(\d+)/j\d+/r\d+/max\d+/m(\d+)/v\d+", raw)
small = [(int(i), int(inner)) for i, inner, m in lst if int(m) < 150 and int(inner) >= 1]
if small:
    idx = small[0][0]
    r = ui.send([f"select {idx}", "sleep 500", "apply"]); s = st()
    print("   单处：", r.strip().replace("\n", " | ")[:200], "prompt", s.get("prompt"), "removeCount", s.get("removeCount"))
    check(s.get("prompt") and s.get("removeCount", 0) > 0, "J4d 弦很短的乱跳候选：应用弹框、区间内有点可删")
    ch = s["changes"]; pts = s["points"]
    r = ui.send(["confirm replace"]); 
    for _ in range(60):
        s = st()
        if s.get("changes", 0) > ch and not s.get("loading"): break
        time.sleep(0.5)
    check(s["changes"] == ch + 1 and s["points"] < pts, f"J4e 只删点落地：点 {pts}→{s['points']} 修改记录 {ch}→{s['changes']}")
else:
    check(False, "J4d 没找到弦 <150 m 的乱跳候选")
print("\nFAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
