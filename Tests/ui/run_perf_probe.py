#!/usr/bin/env python3
"""卡顿动态探针：每个文件做 载入→静置→进补点→悬停 40 次→拖拽平移 6 次→批量规划，记录钩子往返耗时（主线程阻塞的代理）、bodyEvals 增量、
进程 CPU；悬停/平移期间用 sample 抓主线程热点。用法：run_perf_probe.py [文件...]"""
import ui, json, time, os, sys, subprocess, shutil, re
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
SP = os.path.dirname(os.path.abspath(__file__))
OUT = SP + "/perf"; os.makedirs(OUT, exist_ok=True)
def st():
    for _ in range(6):
        s = ui.state()
        if "trips" in s: return s
        time.sleep(1)
    return s
def timed(cmds, timeout=60):
    t0 = time.time(); r = ui.send(cmds, timeout=timeout); return time.time() - t0, r
def relaunch():
    subprocess.run(["pkill", "-f", SP + "/app.noindex/GPXPointViewer.app"], capture_output=True); time.sleep(1.5)
    src = ui.app_source()
    dst = SP + "/app.noindex/GPXPointViewer.app"; os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst): shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, dst, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
    for _ in range(60):
        time.sleep(1)
        if "points" in ui.state(): return
    raise SystemExit("app did not come up")
def pid():
    r = subprocess.run(["pgrep", "-f", SP + "/app.noindex/GPXPointViewer.app/Contents/MacOS"], capture_output=True, text=True)
    return r.stdout.split()[0] if r.stdout.strip() else None
def cpu(p):
    r = subprocess.run(["ps", "-o", "%cpu=", "-p", p], capture_output=True, text=True); return r.stdout.strip()
def sample_start(tag, secs):
    p = pid(); path = f"{OUT}/sample_{tag}.txt"
    return subprocess.Popen(["sample", p, str(secs), "-mayDie", "-file", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), path
def main_thread_hot(path, n=14):
    try: txt = open(path, encoding="utf-8", errors="ignore").read()
    except Exception: return "(no sample)"
    m = re.search(r"Thread_\w+ DispatchQueue_1: com\.apple\.main-thread.*?(?=\n    Thread_|\nTotal number)", txt, re.S)
    if not m: return "(main thread section not found)"
    sec = m.group(0).splitlines()
    out = []
    for l in sec[1:]:
        s = l.strip()
        if not s or s.startswith("+ !"): continue
        mm = re.match(r"\+?\s*(\d+)\s+(.*)", s)
        if mm and int(mm.group(1)) >= 30 and "start" not in mm.group(2)[:5]:
            frame = re.sub(r"\(in .*", "", mm.group(2)).strip()[:110]
            out.append(f"{mm.group(1):>5}  {frame}")
    # 去重相邻重复
    dedup = []
    for o in out:
        if not dedup or dedup[-1].split(None, 1)[1] != o.split(None, 1)[1]: dedup.append(o)
    return "\n".join(dedup[:n])
relaunch()
files = sys.argv[1:] or ["Garmin_Roma_Da.gpx", "2026.csv", "backup2026.gpx"]
report = []
for name in files:
    print(f"\n=== {name}")
    ui.send(["place 0", "front"])
    t0 = time.time(); ui.send([f"open {C}/{name}"])
    for _ in range(600):
        s = ui.state()
        if s.get("points") and not s.get("loading"): break
        time.sleep(0.5)
    tload = time.time() - t0
    s = st(); be0 = s["bodyEvals"]; p = pid()
    print(f"  载入 {tload:.1f}s · {s['points']} 点 · bodyEvals {be0}")
    time.sleep(8); s = st()
    print(f"  静置 8s：bodyEvals +{s['bodyEvals']-be0} · CPU {cpu(p)}%"); be0 = s["bodyEvals"]
    dt, _ = timed(["exit", "sleep 200", "fill"]); 
    for _ in range(120):
        s = st()
        if not s.get("loading"): break
        time.sleep(0.5)
    s = st(); print(f"  进补点 {dt:.2f}s · 候选 {s['candidates']} 乱跳 {s['jitter']} 回放 {s['replays']} · bodyEvals +{s['bodyEvals']-be0}"); be0 = s["bodyEvals"]
    w, h = s["content"]
    # 悬停 40 次（地图区域左半）
    proc, path = sample_start(name.split(".")[0] + "_hover", 7)
    lat = []
    for i in range(40):
        x = 200 + (i * 17) % 500; y = 150 + (i * 23) % 450
        d, _ = timed([f"move {x} {y}"]); lat.append(d)
    proc.wait(); s = st()
    lat.sort(); print(f"  悬停 40 次：钩子往返 中位 {lat[20]*1000:.0f} ms · p90 {lat[36]*1000:.0f} ms · 最大 {lat[-1]*1000:.0f} ms · bodyEvals +{s['bodyEvals']-be0} · CPU {cpu(p)}%"); be0 = s["bodyEvals"]
    print("  悬停期主线程热点：\n    " + main_thread_hot(path).replace("\n", "\n    "))
    # 拖拽平移 6 次
    proc, path = sample_start(name.split(".")[0] + "_pan", 8)
    lat = []
    for i in range(6):
        d, _ = timed([f"drag 400 400 {400 + (120 if i % 2 == 0 else -120)} {420 + (60 if i % 3 == 0 else -60)} 12"], timeout=60); lat.append(d)
        time.sleep(0.3)
    proc.wait(); s = st()
    print(f"  平移 6 次：每次 {['%.2f' % x for x in lat]} s · bodyEvals +{s['bodyEvals']-be0} · CPU {cpu(p)}%"); be0 = s["bodyEvals"]
    print("  平移期主线程热点：\n    " + main_thread_hot(path).replace("\n", "\n    "))
    # 批量规划（不联网跑；只看进入耗时）
    d, r = timed(["batchplan"], timeout=120); s = st()
    print(f"  批量规划 {d:.2f}s · items {len((s.get('batch') or {}).get('items', []))} · bodyEvals +{s['bodyEvals']-be0}"); be0 = s["bodyEvals"]
    time.sleep(3); s = st(); print(f"  批量窗口静置 3s：bodyEvals +{s['bodyEvals']-be0} · CPU {cpu(p)}% · tripMapRunning {s.get('tripMapRunning')}")
    ui.send(["batchclose", "exit"])
print("\ndone")
