#!/usr/bin/env python3
"""卡顿探针 2：① 549 候选的批量窗口（分类阶段静置、地图判段进行中、批量运行 20 s）期间的钩子往返/bodyEvals/CPU；② 483 MB 全量备份：载入、静置、进补点、悬停、平移。"""
import ui, json, time, os, sys, subprocess
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
SP = os.path.dirname(os.path.abspath(__file__))
def st():
    for _ in range(6):
        s = ui.state()
        if "trips" in s: return s
        time.sleep(1)
    return s
def timed(cmds, timeout=120):
    t0 = time.time(); r = ui.send(cmds, timeout=timeout); return time.time() - t0, r
def pid():
    r = subprocess.run(["pgrep", "-f", SP + "/app.noindex/GPXPointViewer.app/Contents/MacOS"], capture_output=True, text=True)
    return r.stdout.split()[0]
def cpu(p): return subprocess.run(["ps", "-o", "%cpu=", "-p", p], capture_output=True, text=True).stdout.strip()
def mem(p): return int(subprocess.run(["ps", "-o", "rss=", "-p", p], capture_output=True, text=True).stdout.strip() or 0) // 1024
def hook_latency(n=10):
    lat = []
    for _ in range(n):
        d, _ = timed(["state"]); lat.append(d)
    lat.sort(); return f"中位 {lat[n//2]*1000:.0f} ms · 最大 {lat[-1]*1000:.0f} ms"
def open_file(name, maxwait=900):
    ui.send(["place 0", "front"]); t0 = time.time(); ui.send([f"open {C}/{name}"], timeout=60)
    for _ in range(maxwait * 2):
        s = ui.state()
        if s.get("points") and not s.get("loading"): break
        time.sleep(0.5)
    return time.time() - t0, st()
p = pid()
stage = sys.argv[1] if len(sys.argv) > 1 else "all"
if stage in ("all", "batch"):
    tl, s = open_file("2026.csv")
    print(f"=== 2026.csv 载入 {tl:.1f}s · {s['points']} 点")
    ui.send(["exit", "sleep 200", "fill"]); s = st(); be = s["bodyEvals"]
    d, _ = timed(["batchplan", "openbatch"]); s = st()
    print(f"  batchplan+openbatch {d:.2f}s · items {len(s['batch']['items'])} · bodyEvals +{s['bodyEvals']-be}"); be = s["bodyEvals"]
    print(f"  地图判段进行中（{s.get('tripMapRunning')}）：钩子往返 {hook_latency()} · CPU {cpu(p)}% · RSS {mem(p)} MB")
    for _ in range(300):
        s = st()
        if not s.get("tripMapRunning"): break
        time.sleep(1)
    s = st(); print(f"  地图判段结束：bodyEvals +{s['bodyEvals']-be}（期间）· 钩子往返 {hook_latency()} · CPU {cpu(p)}%"); be = s["bodyEvals"]
    # 批量运行 20 s（联网，公共服务；之后取消）
    kinds = {}
    for it in s["batch"]["items"]: kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
    print(f"  分类：{kinds}")
    ui.send(["batchrun"]); t0 = time.time(); lat = []
    while time.time() - t0 < 25:
        d, _ = timed(["state"]); lat.append(d); time.sleep(0.5)
    s = st(); done = sum(1 for it in s["batch"]["items"] if it["status"] != "pending")
    lat.sort(); print(f"  批量运行 25s：处理 {done} 处 · 钩子往返 中位 {lat[len(lat)//2]*1000:.0f} ms · p90 {lat[int(len(lat)*0.9)]*1000:.0f} ms · 最大 {lat[-1]*1000:.0f} ms · bodyEvals +{s['bodyEvals']-be} · CPU {cpu(p)}%")
    ui.send(["batchcancel", "sleep 500", "batchclose", "exit"])
if stage in ("all", "big"):
    tl, s = open_file("backupall.gpx")
    print(f"\n=== backupall.gpx 载入 {tl:.1f}s · {s['points']} 点 · RSS {mem(p)} MB · bodyEvals {s['bodyEvals']}")
    be = s["bodyEvals"]; time.sleep(6); s = st(); print(f"  静置 6s：bodyEvals +{s['bodyEvals']-be} · CPU {cpu(p)}% · 钩子往返 {hook_latency(5)}")
    be = s["bodyEvals"]
    d, _ = timed(["exit", "sleep 200", "fill"], timeout=600)
    for _ in range(600):
        s = st()
        if not s.get("loading"): break
        time.sleep(0.5)
    s = st(); print(f"  进补点 {d:.2f}s · 候选 {s['candidates']} 乱跳 {s['jitter']} 回放 {s['replays']} · bodyEvals +{s['bodyEvals']-be} · RSS {mem(p)} MB"); be = s["bodyEvals"]
    lat = []
    for i in range(20):
        d, _ = timed([f"move {200 + (i*17)%500} {150 + (i*23)%450}"]); lat.append(d)
    lat.sort(); s = st(); print(f"  悬停 20 次：中位 {lat[10]*1000:.0f} ms · 最大 {lat[-1]*1000:.0f} ms · bodyEvals +{s['bodyEvals']-be} · CPU {cpu(p)}%"); be = s["bodyEvals"]
    lat = []
    for i in range(4):
        d, _ = timed([f"drag 400 400 {400 + (120 if i % 2 == 0 else -120)} 450 12"]); lat.append(d)
    s = st(); print(f"  平移 4 次：{['%.2f' % x for x in lat]} s · bodyEvals +{s['bodyEvals']-be} · CPU {cpu(p)}%"); be = s["bodyEvals"]
    d, _ = timed(["batchplan"], timeout=300); s = st(); print(f"  批量规划 {d:.2f}s · items {len((s.get('batch') or {}).get('items', []))} · bodyEvals +{s['bodyEvals']-be}")
    time.sleep(3); s = st(); print(f"  批量窗口静置 3s：bodyEvals +{s['bodyEvals']-be} · CPU {cpu(p)}% · 钩子往返 {hook_latency(5)}")
    ui.send(["batchclose", "exit"])
print("done")
