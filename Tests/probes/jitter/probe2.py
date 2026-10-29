#!/usr/bin/env python3
"""签名 1：移动中坐标**完全重复**（同一 lat/lon 在 10–600 s 后再次出现，期间轨迹离开过 ≥300 m）。
真 GPS 在移动中不会给出一字不差的坐标；Garmin Explore 失锁后回放旧点会。按 90 s 桥接聚簇。"""
import sys, math, collections
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import probe
hav, hms = probe.hav, probe.hms
def repeats(pts, dtMin=10, dtMax=600, away=300):
    seen = collections.defaultdict(list)   # (lat,lon) -> [indices]
    flagged = set()   # 点下标：是回放点（第二次及以后出现，且期间离开过）
    pairs = 0
    # 为"期间离开过"做前缀：对每个 i，离开检查用最大距离——直接扫描区间（簇通常短）；用步进采样限制成本
    for i, (la, lo, t) in enumerate(pts):
        key = (la, lo)
        for j in seen[key]:
            dt = t - pts[j][2]
            if dt < dtMin: continue
            if dt > dtMax: continue
            # 期间是否离开 ≥away（抽样最多 60 个点）
            step = max(1, (i - j) // 60)
            if any(hav(la, lo, pts[m][0], pts[m][1]) >= away for m in range(j + 1, i, step)):
                flagged.add(i); flagged.add(j); pairs += 1
                break
        seen[key].append(i)
    return flagged, pairs
def clusters(pts, flagged, bridge=90):
    out = []
    for i in sorted(flagged):
        t = pts[i][2]
        if out and t - pts[out[-1][1]][2] <= bridge: out[-1][1] = i
        else: out.append([i, i])
    return out
if __name__ == "__main__":
    for path in sys.argv[1:]:
        pts = probe.load(path)
        fl, pairs = repeats(pts)
        cl = clusters(pts, fl)
        print(f"\n{path.split('/')[-1]}: {len(pts)} 点 · 重复对 {pairs} · 被标记点 {len(fl)} · 簇 {len(cl)}")
        for a, b in cl:
            A = pts[max(0, a - 1)]; B = pts[min(len(pts) - 1, b + 1)]
            span = B[2] - A[2]; chord = hav(A[0], A[1], B[0], B[1])
            inner = b - a + 1
            far = max(hav(A[0], A[1], pts[m][0], pts[m][1]) for m in range(a, b + 1, max(1, (b - a) // 50)))
            print(f"  {hms(A[2])} → {hms(B[2])} 跨 {span:6.0f} s · 弦 {chord:6.0f} m（{chord/span*3.6 if span else 0:4.0f} km/h）· 内点 {inner:5d}（标记 {sum(1 for m in range(a, b+1) if m in fl)}）· 最远离 A {far:.0f} m")
