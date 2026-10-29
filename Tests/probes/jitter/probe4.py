#!/usr/bin/env python3
"""回放规则细化：重复点本身要处在"移动中"（与前一点相距 ≥moving 米），排除手机静止时反复写同一缓存位置的情况"""
import sys, collections
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import probe
hav, hms = probe.hav, probe.hms
def replays(pts, dtMin=10, dtMax=1800, away=300, moving=50):
    seen = collections.defaultdict(list); out = []   # out: (i, j, maxAway)
    for i, (la, lo, t) in enumerate(pts):
        key = (la, lo)
        prevs = seen[key]
        if prevs:
            if i >= 1 and hav(la, lo, pts[i-1][0], pts[i-1][1]) >= moving:
                for j in reversed(prevs):
                    dt = t - pts[j][2]
                    if dt < dtMin: continue
                    if dt > dtMax: break
                    step = max(1, (i - j) // 60)
                    far = max(hav(la, lo, pts[m][0], pts[m][1]) for m in range(j + 1, i, step))
                    if far >= away: out.append((i, j, far)); break
        prevs.append(i)
    return out
if __name__ == "__main__":
    for path in sys.argv[1:]:
        pts = probe.load(path)
        r = replays(pts)
        print(f"\n{path.split('/')[-1]}: {len(pts)} 点 · 回放点（移动中）{len(r)}")
        # 按天统计
        days = collections.Counter(hms(pts[i][2])[:5] for i, _, _ in r)
        print("   按天：", dict(sorted(days.items())[:30]))
        # 抽样 8 个看上下文
        for i, j, far in r[:: max(1, len(r) // 8)][:8]:
            ctx = " | ".join(f"{hms(pts[m][2])[6:]} {hav(pts[i][0], pts[i][1], pts[m][0], pts[m][1]):.0f}m" for m in range(max(0, i-2), min(len(pts), i+3)))
            print(f"   #{i} ({pts[i][0]:.5f},{pts[i][1]:.5f}) 首次 {hms(pts[j][2])} 再现 {hms(pts[i][2])} 期间最远 {far:.0f} m · 邻点: {ctx}")
