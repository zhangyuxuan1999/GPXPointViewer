#!/usr/bin/env python3
"""铁路断档：只补隧道。RE1（Kaiser-Wilhelm-Tunnel）应取到并落地；Garmin Roma→Da 铁路段里的断档按隧道占比分「补 / 不补」"""
import ui, json, time, os, sys, datetime
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
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
def wait_idle():
    for _ in range(120):
        s = st()
        if not s.get("loading") and s.get("points"): return s
        time.sleep(0.5)
def run_batch(name, force_rail_trips=None):
    ui.send(["place 0", "front", "open %s/%s" % (C, name)]); wait_idle()
    ui.send(["exit", "sleep 300", "fill", "sleep 1500", "roadonly 0"])
    s = st(); print(f"\n== {name}: {s['points']} 点 · 候选 {s['candidates']} · 段 {len(s['trips'])} · roadOnly={s['roadOnly']}")
    ui.send(["batchplan", "sleep 1000"])
    t0 = time.time()
    for _ in range(600):
        s = st()
        if not s.get("tripMapRunning"): break
        time.sleep(1)
    print(f"   地图判段 {time.time()-t0:.0f}s：" + " ".join(f"段{t['i']}={t['kind']}({'地图' if t['mapVerdict'] else '速度'},{t['gaps']}处)" for t in s["trips"] if t["gaps"] > 0))
    if force_rail_trips:
        for k in force_rail_trips: print("  ", ui.send([f"trip {k} rail"]).strip())
    s = st(); b = s["batch"]
    kinds = {}
    for it in b["items"]: kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
    print(f"   批次分类：{kinds}")
    t1 = time.time(); ui.send(["batchrun"])
    for _ in range(900):
        s = st(); b = s.get("batch")
        if b and b["phase"] == "preview": break
        time.sleep(1)
    items = b["items"]
    rail = [it for it in items if it["kind"] == "rail"]
    done = [it for it in rail if it["status"] == "done"]; nt = [it for it in rail if it["status"].startswith("nottunnel")]; bad = [it for it in rail if it["status"].startswith("failed")]
    print(f"   取草稿 {time.time()-t1:.0f}s · 请求 {b['requests']} · 铁路 {len(rail)} 处：补 {len(done)} · 不补 {len(nt)} · 失败 {len(bad)}")
    for it in rail:
        print(f"     {it['status'][:110]}  | {it['method']} {it['meters']} m shift {it['shiftA']}/{it['shiftB']} warn {it['warnings']}")
    return rail, done, nt, bad
rail, done, nt, bad = run_batch("RE1.gpx")
if not rail:
    # 地图没判成铁路就手动指定再跑一次
    ui.send(["batchclose"]); rail, done, nt, bad = run_batch("RE1.gpx", force_rail_trips=[1])
check(len(rail) >= 1 and len(bad) == 0 and len(done) + len(nt) == len(rail), f"R1 RE1 铁路项全部处理且无失败（取到路径/删点 {len(done)}、不补 {len(nt)}、失败 {len(bad)}）")   # 回放规则收紧后 Kaiser-Wilhelm 隧道的乒乒球成了回放点，不再作为断档候选出现（隧道内剩航位推算的贴线点）
ui.send(["batchclose"])
rail, done, nt, bad = run_batch("Garmin_Roma_Da.gpx")
check(len(rail) >= 3 and len(bad) == 0, f"R2 Garmin 铁路段断档 {len(rail)} 处：补 {len(done)} · 不补 {len(nt)} · 失败 {len(bad)}")
ui.send(["batchclose"])
print("FAILS:", fails if fails else "none"); sys.exit(1 if fails else 0)
