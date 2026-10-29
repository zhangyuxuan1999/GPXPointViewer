#!/usr/bin/env python3
"""乱跳检测探针：按时间戳聚合 → 以已接受窗口的步长/速度/航向为参照，判「大跳」与「倒退」→ 聚簇 → 等 20 s 稳定段收尾。
用法：probe.py 文件 [--verbose] [--from HH:MM:SS --to HH:MM:SS]"""
import re, math, sys, datetime, statistics, csv
def hav(la1, lo1, la2, lo2):
    la1, lo1, la2, lo2 = map(math.radians, (la1, lo1, la2, lo2))
    h = math.sin((la2-la1)/2)**2 + math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*6371000*math.asin(math.sqrt(min(1, h)))
def load(path):
    if path.endswith(".csv"):
        pts = []
        with open(path, encoding="utf-8") as f:
            r = csv.reader(f); hdr = next(r)
            il = [i for i,h in enumerate(hdr) if h.lower() in ("latitude","lat")][0]
            io = [i for i,h in enumerate(hdr) if h.lower() in ("longitude","lon","lng")][0]
            it = [i for i,h in enumerate(hdr) if "time" in h.lower()][0]
            for row in r:
                try:
                    t = float(row[it]);  
                    if t > 1e11: t /= 1000
                    pts.append((float(row[il]), float(row[io]), t))
                except Exception: pass
        pts.sort(key=lambda p: p[2]); return pts
    txt = open(path, encoding="utf-8", errors="ignore").read()
    out = []
    for m in re.finditer(r'<trkpt lat="([^"]+)" lon="([^"]+)">(.*?)</trkpt>', txt, re.S):
        tm = re.search(r'<time>([^<]+)</time>', m.group(3))
        if not tm: continue
        s = tm.group(1)
        try: t = datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
        except Exception: continue
        out.append((float(m.group(1)), float(m.group(2)), t))
    return out
def hms(t): return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%m-%d %H:%M:%S")

P = dict(jMin=300.0, rMin=200.0, speedMul=2.5, stepMul=4.0, headMin=100.0, settle=20.0, settleN=4, maxKmh=350.0,
         minSeconds=20.0, revDtMax=10.0, window=60.0, merge=60.0, maxCluster=600.0)

def aggregate(pts):
    S = []
    for i, (la, lo, t) in enumerate(pts):
        if S and S[-1]["t"] == t: S[-1]["pts"].append((la, lo)); S[-1]["last"] = i
        else: S.append({"t": t, "pts": [(la, lo)], "first": i, "last": i})
    for s in S:
        s["la"] = statistics.median(p[0] for p in s["pts"]); s["lo"] = statistics.median(p[1] for p in s["pts"])
    return S

def window_stats(win, medianDtProfile, medianStepProfile):
    """win: list of samples（已接受）。返回 mLoc, vRef, heading(或 None), dtLoc"""
    steps = [hav(win[k-1]["la"], win[k-1]["lo"], win[k]["la"], win[k]["lo"]) for k in range(1, len(win))]
    dts = [win[k]["t"] - win[k-1]["t"] for k in range(1, len(win))]
    mLoc = statistics.median(steps) if len(steps) >= 3 else medianStepProfile
    dtLoc = statistics.median(dts) if len(dts) >= 3 else medianDtProfile
    heading = None; vRef = None
    if len(win) >= 2:
        dur = win[-1]["t"] - win[0]["t"]; chord = hav(win[0]["la"], win[0]["lo"], win[-1]["la"], win[-1]["lo"])
        if dur >= 10: vRef = chord / dur
        if chord >= max(P["headMin"], 3 * mLoc):
            kx = 111320 * math.cos(math.radians(win[-1]["la"])); ky = 110540
            heading = ((win[-1]["lo"] - win[0]["lo"]) * kx, (win[-1]["la"] - win[0]["la"]) * ky)
    if vRef is None: vRef = mLoc / max(1.0, dtLoc)
    return mLoc, vRef, heading, dtLoc

def step_test(a, b, mLoc, vRef, heading, dtLoc):
    """返回 (isJump, isReversal, d, dt)"""
    dt = b["t"] - a["t"]; d = hav(a["la"], a["lo"], b["la"], b["lo"])
    if dt >= P["minSeconds"]: return False, False, d, dt      # 时间空洞归断档检测
    jump = d > max(P["jMin"], P["speedMul"] * vRef * dt + P["stepMul"] * mLoc)
    rev = False
    if heading is not None and dt <= max(P["revDtMax"], 3 * dtLoc):
        kx = 111320 * math.cos(math.radians(a["la"])); ky = 110540
        sx, sy = (b["lo"] - a["lo"]) * kx, (b["la"] - a["la"]) * ky
        hn = math.hypot(*heading)
        proj = (sx * heading[0] + sy * heading[1]) / hn if hn > 0 else 0
        rev = proj < -max(P["rMin"], 3 * mLoc)
    return jump, rev, d, dt

def settled_run(S, k, mProfile, dtProfile):
    """从 S[k] 起是否有一段 ≥settle 秒、≥settleN 个样本的稳定段（步步合理、无倒退、弦速 ≤maxKmh）。返回 j（段末下标）或 None"""
    j = k
    while j + 1 < len(S) and S[j + 1]["t"] - S[k]["t"] <= P["settle"] + 5:
        j += 1
        if S[j]["t"] - S[j-1]["t"] >= P["minSeconds"]: break   # 遇空洞：段到此
    if S[j]["t"] - S[k]["t"] < P["settle"] or j - k + 1 < P["settleN"]: return None
    run = S[k:j+1]
    dur = run[-1]["t"] - run[0]["t"]; chord = hav(run[0]["la"], run[0]["lo"], run[-1]["la"], run[-1]["lo"])
    if chord / dur * 3.6 > P["maxKmh"]: return None
    mLoc, vRef, heading, dtLoc = window_stats(run, dtProfile, mProfile)
    for q in range(1, len(run)):
        jump, rev, d, dt = step_test(run[q-1], run[q], mLoc, vRef, heading, dtLoc)
        if jump or rev: return None
    return j

def detect(pts, verbose=False, vfrom=None, vto=None):
    S = aggregate(pts)
    steps = [hav(S[k-1]["la"], S[k-1]["lo"], S[k]["la"], S[k]["lo"]) for k in range(1, len(S))]
    dts = [S[k]["t"] - S[k-1]["t"] for k in range(1, len(S))]
    mv = [(d, dt) for d, dt in zip(steps, dts) if dt > 0 and d / dt > 1]
    mProfile = statistics.median([d for d, _ in mv]) if mv else 30; dtProfile = statistics.median([dt for _, dt in mv]) if mv else 1
    clusters = []
    win = [S[0]]
    k = 1
    while k < len(S):
        mLoc, vRef, heading, dtLoc = window_stats(win, dtProfile, mProfile)
        jump, rev, d, dt = step_test(win[-1], S[k], mLoc, vRef, heading, dtLoc)
        if verbose and vfrom and vfrom <= hms(S[k]["t"])[6:] <= vto:
            print(f"   {hms(S[k]['t'])} n={len(S[k]['pts'])} d={d:.0f} dt={dt:.0f} mLoc={mLoc:.0f} vRef={vRef*3.6:.0f} J={max(P['jMin'], P['speedMul']*vRef*dt + P['stepMul']*mLoc):.0f} {'JUMP' if jump else ''}{'REV' if rev else ''}")
        if not (jump or rev):
            win.append(S[k]); 
            while win[-1]["t"] - win[0]["t"] > P["window"] and len(win) > 2: win.pop(0)
            k += 1; continue
        # 进簇：A = win[-1]
        A = win[-1]; aIdx = k - 1
        jumps = 1 if jump else 0; revs = 1 if rev else 0
        fixedStats = (mLoc, vRef, heading, dtLoc)
        q = k + 1; B = None
        while q < len(S):
            if S[q]["t"] - A["t"] > P["maxCluster"]: break
            if S[q]["t"] - S[q-1]["t"] >= P["minSeconds"]: break      # 簇里出现时间空洞：到此为止，B 取空洞前点？→ 交给断档，簇收尾于 q-1
            j = settled_run(S, q, mProfile, dtProfile)
            if j is not None: B = q; break
            jp, rv, _, _ = step_test(S[q-1], S[q], *fixedStats)
            jumps += jp; revs += rv
            q += 1
        if B is None:
            # 没稳定下来（空洞/超时/到结尾）：放弃这簇，窗口重置
            if verbose: print(f"   放弃簇 {hms(A['t'])}→{hms(S[min(q, len(S)-1)]['t'])} jumps={jumps} revs={revs}")
            win = [S[min(q, len(S)-1)]]; k = min(q, len(S) - 1) + 1; continue
        if jumps >= 2 or revs >= 1:
            clusters.append({"a": aIdx, "b": B, "tA": A["t"], "tB": S[B]["t"], "jumps": jumps, "revs": revs,
                             "chord": hav(A["la"], A["lo"], S[B]["la"], S[B]["lo"]), "inner": S[B]["first"] - A["last"] - 1,
                             "la": A["la"], "lo": A["lo"]})
        win = [S[B]]; k = B + 1
    # 合并相隔 ≤merge 秒的簇
    merged = []
    for c in clusters:
        if merged and c["tA"] - merged[-1]["tB"] <= P["merge"]:
            m = merged[-1]; m["b"] = c["b"]; m["tB"] = c["tB"]; m["jumps"] += c["jumps"]; m["revs"] += c["revs"]
            m["chord"] = hav(m["la"], m["lo"], S[c["b"]]["la"], S[c["b"]]["lo"]); m["inner"] = S[c["b"]]["first"] - S[m["a"]]["last"] - 1; m["n"] = m.get("n", 1) + 1
        else: merged.append(c)
    return S, merged, mProfile, dtProfile

if __name__ == "__main__":
    path = sys.argv[1]; verbose = "--verbose" in sys.argv
    vfrom = vto = None
    if "--from" in sys.argv: vfrom = sys.argv[sys.argv.index("--from")+1]; vto = sys.argv[sys.argv.index("--to")+1]
    pts = load(path)
    S, cl, mP, dtP = detect(pts, verbose, vfrom, vto)
    print(f"{path.split('/')[-1]}: {len(pts)} 点 · {len(S)} 时间戳 · 画像 步 {mP:.0f} m / {dtP:.0f} s · 乱跳簇 {len(cl)}")
    for c in cl:
        sp = c["tB"] - c["tA"]
        print(f"  {hms(c['tA'])} → {hms(c['tB'])}  跨 {sp:.0f} s · 弦 {c['chord']:.0f} m（{c['chord']/sp*3.6 if sp>0 else 0:.0f} km/h）· 大跳 {c['jumps']} 倒退 {c['revs']} · 内点 {c['inner']}{' · 并 '+str(c['n']) if c.get('n') else ''} @ {c['la']:.4f},{c['lo']:.4f}")
