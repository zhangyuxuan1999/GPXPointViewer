#!/usr/bin/env python3
"""两步：① 去回放点（坐标在 10–1800 s 前出现过、期间离开 ≥300 m）② 在剩下的点上跑运动学乱跳簇检测"""
import sys
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import probe, probe2
hms, hav = probe.hms, probe.hav
for path in [a for a in sys.argv[1:] if not a.startswith("--")]:
    pts = probe.load(path)
    fl, pairs = probe2.repeats(pts, dtMax=1800)
    # 只删"第二次及以后"出现的那一个：fl 里也含首次出现的 j，这里重新判定——保留每个坐标的首个
    seen = set(); keep = []
    removed = 0
    for i, p in enumerate(pts):
        key = (p[0], p[1])
        if i in fl and key in seen: removed += 1; continue
        seen.add(key); keep.append(p)
    print(f"\n{path.split('/')[-1]}: {len(pts)} 点 · 回放点删除 {removed}（重复对 {pairs}）· 剩 {len(keep)}")
    verbose = "--verbose" in sys.argv
    S, cl, mP, dtP = probe.detect(keep, verbose, "07:02:00" if verbose else None, "07:05:00" if verbose else None)
    print(f"   画像 步 {mP:.0f} m / {dtP:.0f} s · 乱跳簇 {len(cl)}")
    for c in cl:
        sp = c["tB"] - c["tA"]
        print(f"  {hms(c['tA'])} → {hms(c['tB'])}  跨 {sp:5.0f} s · 弦 {c['chord']:6.0f} m（{c['chord']/sp*3.6 if sp>0 else 0:4.0f} km/h）· 大跳 {c['jumps']} 倒退 {c['revs']} · 内点 {c['inner']:4d}{' · 并 '+str(c['n']) if c.get('n') else ''} @ {c['la']:.4f},{c['lo']:.4f}")
