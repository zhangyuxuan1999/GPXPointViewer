#!/usr/bin/env python3
"""合成断档考卷出题脚本（docs/fill-plausibility-design.md §2.1）。

用法（在仓库根目录）：
    python3 -I Tests/exam/make_questions.py [--osm <all_osm_ways.json>] [--out Tests/exam/questions]

纯标准库、离线、固定随机种子 random.Random(20261027)；同样输入两次运行结果逐字节相同。
只出题，不判卷。输出 <out>/*.json（每题一个）与 <out>/INDEX.md；运行前会删掉 <out> 里旧的 *.json。

源文件（GPX 1.1，单 trk 单 trkseg，trkpt 已按时间有序）：
    mr = data/compare/Muenchen_Roma_Garmin.gpx
    rd = data/Garmin_Roma_Da_copy.gpx
用正则解析 <trkpt lat lon> 与其中的 <ele>（缺则 null）、<time>（ISO Z → epoch 整数）。
下标 = trkpt 在文件里的顺序（从 0 数）。

OSM 隧道 way（--osm，Overpass JSON，下载数据，只用 json 读）：只取 type=way 且 tags.tunnel=yes 的几何。

synthetic 题规则：
  1. 每步（i-1→i）算 dt、haversine 步长（米）、速度。dt>3 s 或步长>150 m 的步记为「坏步」。
  2. 候选窗口 [ia, ib]：挖掉 ia+1…ib-1，ia、ib 为锚点。
     - seconds = t[ib]-t[ia] 落在 10-20s / 20-60s / 1-3min / 3-8min（左闭右开，3-8min 含 480）；
     - t[ia]-300 … t[ib]+300 范围内（含窗口内部）没有坏步；
     - 挖掉点的速度（进入该点那一步的速度）中位 ≥ 40 km/h；
     - seconds ≥ 20 时 A→B 直线 ≥ 150 m；
     - 离文件首尾 ≥ 600 s；
     - 已选窗口互不重叠，且相邻窗口 t[B_前] 与 t[A_后] 之间 ≥ 120 s（同一源文件内）。
     枚举：按步进扫描 ia（每档固定步长），每个 (ia, 档) 用种子 RNG 抽一个档内目标时长，bisect 找 ib；
     隧道附近（挖掉点可能命中隧道的 ia）额外按步长 1 扫描。复杂度 O(n·档数·log n)。
  3. 路型：
     - tunnel：挖掉的点 ≥30% 到任一 tunnel=yes way 折线距离 ≤ 25 m（局部平面 kx=111320·cos(lat), ky=110540）；
     - straight：序列 A + 挖掉点 + B 每 5 点取一个点（末点必取），相邻采样点的航向，
       相邻航向差（折到 ±180°）绝对值累计 ≤ 20°；
     - curve：其它。（junction 无数据，本期不出。）
  4. 选题：先收 tunnel（每条隧道 way 最多 2 题、不同档优先，总数封顶 25）；
     再按档补到 10-20s 15 / 20-60s 40 / 1-3min 40 / 3-8min 25（含 tunnel 题），
     每档 mr:rd ≈ 6:4，一侧不够由另一侧补；档内从候选里用种子 RNG 均匀抽，straight/curve 各半，
     一类不够由另一类补。候选不够就有多少出多少，INDEX.md 里说明。
  5. 每题 JSON：<src>_<band>_<NNNN>.json，NNNN 全局递增（按源文件、时间排序后编号）。
     坐标保留 7 位小数；truthMeters = A→挖掉点→B 折线长。

real 题：5 处诊断报告里的断档（mr），答案 = OSM way 几何按给定顺序首尾相连拼成的折线（不裁剪）。
  首条 way 的方向取「首点离 A 更近」；之后每条比较上一条末点到本条首/末点哪个近，近的那端接上。
"""
import argparse
import bisect
import calendar
import json
import math
import os
import random
import re
import sys
import time

SEED = 20261027
SOURCES = [("mr", "data/compare/Muenchen_Roma_Garmin.gpx"), ("rd", "data/Garmin_Roma_Da_copy.gpx")]
DEFAULT_OSM = ("/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/"
               "api-runs/20261026_143424_tunnel-diagnosis-2/work/all_osm_ways.json")
BANDS = [("10-20s", 10, 20), ("20-60s", 20, 60), ("1-3min", 60, 180), ("3-8min", 180, 481)]  # [lo, hi)
QUOTA = {"10-20s": 15, "20-60s": 40, "1-3min": 40, "3-8min": 25}
STRIDE = {"10-20s": 7, "20-60s": 11, "1-3min": 23, "3-8min": 41}
MR_SHARE = 0.6
TUNNEL_CAP, TUNNEL_PER_WAY = 25, 2
BAD_DT, BAD_STEP, CONT_PAD, EDGE, GAP = 3, 150.0, 300, 600, 120
MIN_KMH, MIN_STRAIGHT, TUNNEL_D, TUNNEL_FRAC, STRAIGHT_DEG = 40.0, 150.0, 25.0, 0.30, 20.0

REAL = [
    ("real_14_tusch", 9732, 9734, [30838319, 30838322, 30838314], "§1"),
    ("real_16_trento", 12013, 12015, [23882756, 23882762], "§2"),
    ("real_19_monzuno", 20893, 20895, [155056885, 155056896, 296778992], "§2"),
    ("real_33_santalucia", 21676, 21678, [288687374, 1037336052, 288687373], "§4"),
    ("real_34_calenzano", 21730, 21732, [288687371, 387897841], "§4"),
]

TRKPT = re.compile(r'<trkpt\b([^>]*)>(.*?)</trkpt>', re.S)
LAT = re.compile(r'\blat="([-\d.eE+]+)"')
LON = re.compile(r'\blon="([-\d.eE+]+)"')
ELE = re.compile(r'<ele>(.*?)</ele>', re.S)
TIME = re.compile(r'<time>(.*?)</time>', re.S)


def haversine(la1, lo1, la2, lo2):
    p1, p2 = math.radians(la1), math.radians(la2)
    dp, dl = p2 - p1, math.radians(lo2 - lo1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371008.8 * math.asin(min(1.0, math.sqrt(h)))


def bearing(la1, lo1, la2, lo2):
    p1, p2 = math.radians(la1), math.radians(la2)
    dl = math.radians(lo2 - lo1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return math.degrees(math.atan2(y, x))


def parse_gpx(path):
    text = open(path, encoding="utf-8").read()
    pts = []
    for attrs, body in TRKPT.findall(text):
        la, lo = float(LAT.search(attrs).group(1)), float(LON.search(attrs).group(1))
        m = ELE.search(body)
        ele = float(m.group(1)) if m else None
        t = calendar.timegm(time.strptime(TIME.search(body).group(1).strip(), "%Y-%m-%dT%H:%M:%SZ"))
        pts.append((la, lo, ele, t))
    return pts


def load_osm(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    ways = {}
    for e in data.get("elements", []):
        if e.get("type") != "way" or not isinstance(e.get("geometry"), list):
            continue
        geom = [(float(g["lat"]), float(g["lon"])) for g in e["geometry"]
                if isinstance(g, dict) and "lat" in g and "lon" in g]
        tags = e.get("tags") or {}
        ways[int(e["id"])] = {"geom": geom, "tunnel": tags.get("tunnel") == "yes"}
    return ways


def seg_dist(q, a, b):
    kx = 111320.0 * math.cos(math.radians(q[0]))
    ky = 110540.0
    bx, by = (b[1] - a[1]) * kx, (b[0] - a[0]) * ky
    qx, qy = (q[1] - a[1]) * kx, (q[0] - a[0]) * ky
    L2 = bx * bx + by * by
    t = max(0.0, min(1.0, (qx * bx + qy * by) / L2)) if L2 > 0 else 0.0
    return math.hypot(qx - bx * t, qy - by * t)


def tunnel_hits(pts, ways):
    """每个点 → 25 m 内最近的 tunnel way id（没有则 None）。先按 way 包围盒（外扩）粗筛。"""
    tw = []
    for wid, w in sorted(ways.items()):
        g = w["geom"]
        if not w["tunnel"] or len(g) < 1:
            continue
        mlat = sum(p[0] for p in g) / len(g)
        dlat = TUNNEL_D / 110540.0 * 1.5
        dlon = TUNNEL_D / (111320.0 * math.cos(math.radians(mlat))) * 1.5
        box = (min(p[0] for p in g) - dlat, max(p[0] for p in g) + dlat,
               min(p[1] for p in g) - dlon, max(p[1] for p in g) + dlon)
        tw.append((wid, g, box))
    hits = [None] * len(pts)
    for i, p in enumerate(pts):
        best, bw = TUNNEL_D, None
        for wid, g, box in tw:
            if not (box[0] <= p[0] <= box[1] and box[2] <= p[1] <= box[3]):
                continue
            segs = zip(g, g[1:]) if len(g) > 1 else [(g[0], g[0])]
            for a, b in segs:
                d = seg_dist(p, a, b)
                if d <= best:
                    best, bw = d, wid
        hits[i] = bw
    return hits


def median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def band_of(sec):
    for name, lo, hi in BANDS:
        if lo <= sec < hi:
            return name
    return "<10s" if sec < 10 else ">8min"


class Track:
    def __init__(self, key, rel, pts, ways):
        self.key, self.rel, self.pts = key, rel, pts
        n = len(pts)
        self.t = [p[3] for p in pts]
        self.step = [0.0] * n
        self.speed = [0.0] * n  # km/h，进入点 i 的那一步
        bad = [0] * n
        for i in range(1, n):
            d = haversine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1])
            dt = self.t[i] - self.t[i - 1]
            self.step[i] = d
            self.speed[i] = d / dt * 3.6 if dt > 0 else float("inf")
            bad[i] = 1 if (dt > BAD_DT or d > BAD_STEP) else 0
        self.badpre = [0] * (n + 1)
        for i in range(n):
            self.badpre[i + 1] = self.badpre[i] + bad[i]
        self.cum = [0.0] * n
        for i in range(1, n):
            self.cum[i] = self.cum[i - 1] + self.step[i]
        self.hits = tunnel_hits(pts, ways)
        self.hitpre = [0] * (n + 1)
        for i in range(n):
            self.hitpre[i + 1] = self.hitpre[i] + (1 if self.hits[i] is not None else 0)

    def continuous(self, ia, ib):
        """t[ia]-300 … t[ib]+300 内所有步（步 i = i-1→i）都不是坏步。"""
        lo = bisect.bisect_left(self.t, self.t[ia] - CONT_PAD)
        hi = bisect.bisect_right(self.t, self.t[ib] + CONT_PAD) - 1
        if self.t[ia] - CONT_PAD < self.t[0] or self.t[ib] + CONT_PAD > self.t[-1]:
            return False
        # 涉及的步：lo+1 … hi（以及进入 lo 的步若其起点仍在范围内 —— lo 是第一个 ≥ 下界的点，故步 lo 起点在界外，不计）
        return self.badpre[hi + 1] - self.badpre[lo + 1] == 0

    def evaluate(self, ia, ib):
        """返回候选 dict 或 None。"""
        t, pts = self.t, self.pts
        n = len(pts)
        if ib - ia < 2:
            return None
        sec = t[ib] - t[ia]
        band = band_of(sec)
        if band not in QUOTA:
            return None
        if t[ia] - t[0] < EDGE or t[-1] - t[ib] < EDGE:
            return None
        if not self.continuous(ia, ib):
            return None
        A, B = pts[ia], pts[ib]
        straight = haversine(A[0], A[1], B[0], B[1])
        if sec >= 20 and straight < MIN_STRAIGHT:
            return None
        med = median(self.speed[ia + 1:ib])
        if med < MIN_KMH:
            return None
        removed = ib - ia - 1
        nh = self.hitpre[ib] - self.hitpre[ia + 1]
        seq = pts[ia:ib + 1]
        samp = seq[::5]
        if (len(seq) - 1) % 5:
            samp = samp + [seq[-1]]
        hd = [bearing(a[0], a[1], b[0], b[1]) for a, b in zip(samp, samp[1:])]
        turn = 0.0
        for h1, h2 in zip(hd, hd[1:]):
            turn += abs((h2 - h1 + 180.0) % 360.0 - 180.0)
        if nh >= TUNNEL_FRAC * removed:
            rt = "tunnel"
            cnt = {}
            for i in range(ia + 1, ib):
                w = self.hits[i]
                if w is not None:
                    cnt[w] = cnt.get(w, 0) + 1
            way = max(sorted(cnt), key=lambda k: cnt[k])
        else:
            rt = "straight" if turn <= STRAIGHT_DEG else "curve"
            way = None
        return {"src": self.key, "ia": ia, "ib": ib, "seconds": sec, "band": band, "roadType": rt,
                "straightMeters": straight, "truthMeters": self.cum[ib] - self.cum[ia],
                "removedCount": removed, "medianSpeedKmh": med, "turnDegrees": turn, "way": way,
                "tunnelFrac": nh / removed}

    def candidates(self, rng):
        t, n = self.t, len(self.t)
        out = {b: [] for b in QUOTA}
        seen = set()
        # 隧道附近：命中点前后各 (8 min + 余量) 内的 ia 全扫
        near = [False] * n
        hit_idx = [i for i in range(n) if self.hits[i] is not None]
        diff = [0] * (n + 1)
        for i in hit_idx:
            diff[bisect.bisect_left(t, t[i] - 500)] += 1
            diff[i + 1] -= 1
        acc = 0
        for j in range(n):
            acc += diff[j]
            near[j] = acc > 0
        for name, lo_s, hi_s in BANDS:
            for ia in range(n):
                if not (ia % STRIDE[name] == 0 or near[ia]):
                    continue
                target = t[ia] + rng.randint(lo_s, hi_s - 1)
                ib = bisect.bisect_left(t, target)
                if ib >= n:
                    continue
                for jb in ((ib,) if ia % STRIDE[name] == 0 and not near[ia] else (ib, ib + 1)):
                    if jb >= n or (ia, jb) in seen:
                        continue
                    c = self.evaluate(ia, jb)
                    if c is not None and c["band"] == name:
                        seen.add((ia, jb))
                        out[name].append(c)
        return out


def overlaps(chosen, c, tracks):
    t = tracks[c["src"]].t
    a, b = t[c["ia"]], t[c["ib"]]
    for o in chosen:
        if o["src"] != c["src"]:
            continue
        oa, ob = t[o["ia"]], t[o["ib"]]
        if a < ob + GAP and oa < b + GAP:
            return True
    return False


def r7(x):
    return round(x, 7)


def pt_json(pts, i):
    p = pts[i]
    return {"index": i, "time": p[3], "lat": r7(p[0]), "lon": r7(p[1])}


def build_polyline(ways, ids, A):
    poly, missing = [], []
    for wid in ids:
        w = ways.get(wid)
        if not w or not w["geom"]:
            missing.append(wid)
            continue
        g = list(w["geom"])
        if not poly:
            if haversine(A[0], A[1], g[-1][0], g[-1][1]) < haversine(A[0], A[1], g[0][0], g[0][1]):
                g.reverse()
        else:
            e = poly[-1]
            if haversine(e[0], e[1], g[-1][0], g[-1][1]) < haversine(e[0], e[1], g[0][0], g[0][1]):
                g.reverse()
            if g[0] == e:
                g = g[1:]
        poly.extend(g)
    return poly, missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--osm", default=DEFAULT_OSM)
    ap.add_argument("--out", default="Tests/exam/questions")
    ap.add_argument("--root", default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    args = ap.parse_args()
    t0 = time.time()
    root = args.root
    out = args.out if os.path.isabs(args.out) else os.path.join(root, args.out)
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith(".json"):
            os.remove(os.path.join(out, f))

    ways = load_osm(args.osm)
    print(f"OSM: {len(ways)} ways, {sum(1 for w in ways.values() if w['tunnel'])} tunnel=yes")
    rng = random.Random(SEED)
    tracks, cands = {}, {}
    for key, rel in SOURCES:
        pts = parse_gpx(os.path.join(root, rel))
        tr = Track(key, rel, pts, ways)
        tracks[key] = tr
        cands[key] = tr.candidates(rng)
        nb = tr.badpre[-1]
        print(f"{key}: {len(pts)} pts, bad steps {nb}, tunnel-near pts {tr.hitpre[-1]}, candidates "
              + ", ".join(f"{b}={len(cands[key][b])}"
                          + f"(t{sum(c['roadType']=='tunnel' for c in cands[key][b])}"
                          + f"/s{sum(c['roadType']=='straight' for c in cands[key][b])}"
                          + f"/c{sum(c['roadType']=='curve' for c in cands[key][b])})"
                          for b in QUOTA)
              + f"  [{time.time()-t0:.1f}s]")

    chosen = []
    # --- tunnel ---
    tun = [c for k in cands for b in QUOTA for c in cands[k][b] if c["roadType"] == "tunnel"]
    rng.shuffle(tun)
    by_way = {}
    for c in tun:
        by_way.setdefault(c["way"], []).append(c)
    tunnel_note = []
    # 轮转：每轮每条 way 取 1 题（优先该 way 尚未出现的档），直到每条 way 2 题或封顶
    for rnd in range(TUNNEL_PER_WAY):
        for wid in sorted(by_way):
            if sum(1 for c in chosen if c["roadType"] == "tunnel") >= TUNNEL_CAP:
                break
            have = [c for c in chosen if c.get("way") == wid]
            if len(have) >= TUNNEL_PER_WAY:
                continue
            used_bands = {c["band"] for c in have}
            band_cnt = {b: sum(1 for c in chosen if c["band"] == b) for b in QUOTA}
            pool = sorted(by_way[wid], key=lambda c: (c["band"] in used_bands, band_cnt[c["band"]] >= QUOTA[c["band"]]))
            for c in pool:
                if band_cnt[c["band"]] >= QUOTA[c["band"]]:
                    continue
                if not overlaps(chosen, c, tracks):
                    chosen.append(c)
                    break
    # --- 按档补齐 ---
    shortfall = []
    for name in ["3-8min", "1-3min", "20-60s", "10-20s"]:
        q = QUOTA[name]
        have = [c for c in chosen if c["band"] == name]
        mr_target = round(q * MR_SHARE)
        tgt = {"mr": max(0, mr_target - sum(c["src"] == "mr" for c in have)),
               "rd": max(0, q - mr_target - sum(c["src"] == "rd" for c in have))}
        # 若 tunnel 题已让某侧超额，从另一侧扣
        excess = len(have) + tgt["mr"] + tgt["rd"] - q
        for k in ("rd", "mr"):
            d = min(excess, tgt[k]) if excess > 0 else 0
            tgt[k] -= d
            excess -= d

        def take(src, need):
            pools = {}
            for rt in ("straight", "curve"):
                p = [c for c in cands[src][name] if c["roadType"] == rt]
                rng.shuffle(p)
                pools[rt] = p
            got = {"straight": 0, "curve": 0}
            want = {"straight": need // 2, "curve": need - need // 2}
            if need % 2 and rng.random() < 0.5:
                want = {"straight": need - need // 2, "curve": need // 2}

            def fill(rt, k):
                n_ = 0
                for c in pools[rt]:
                    if n_ >= k:
                        break
                    if not overlaps(chosen, c, tracks):
                        chosen.append(c)
                        n_ += 1
                return n_
            got["straight"] = fill("straight", want["straight"])
            got["curve"] = fill("curve", want["curve"] + (want["straight"] - got["straight"]))
            short = want["curve"] - got["curve"]
            if short > 0:
                got["straight"] += fill("straight", short)
            return got["straight"] + got["curve"]

        g_mr = take("mr", tgt["mr"])
        g_rd = take("rd", tgt["rd"] + (tgt["mr"] - g_mr))
        if g_rd < tgt["rd"] + (tgt["mr"] - g_mr):
            take("mr", tgt["rd"] + (tgt["mr"] - g_mr) - g_rd)
        got = sum(1 for c in chosen if c["band"] == name)
        if got < q:
            shortfall.append(f"{name}: 目标 {q}，实际 {got}（两份源文件的不重叠候选已用尽）")

    # --- 写 synthetic ---
    order = {k: i for i, (k, _) in enumerate(SOURCES)}
    chosen.sort(key=lambda c: (order[c["src"]], c["ia"]))
    rows = []
    for no, c in enumerate(chosen, 1):
        tr = tracks[c["src"]]
        qid = f"{c['src']}_{c['band']}_{no:04d}"
        removed = [[r7(p[0]), r7(p[1]), p[2], p[3]] for p in tr.pts[c["ia"] + 1:c["ib"]]]
        notes = ""
        if c["roadType"] == "tunnel":
            notes = f"tunnel: {c['tunnelFrac']*100:.0f}% 挖掉点距 OSM way {c['way']} ≤ 25 m"
        q = {"id": qid, "kind": "synthetic", "source": tr.rel, "band": c["band"], "roadType": c["roadType"],
             "anchorA": pt_json(tr.pts, c["ia"]), "anchorB": pt_json(tr.pts, c["ib"]),
             "seconds": c["seconds"], "straightMeters": round(c["straightMeters"], 1),
             "truthMeters": round(c["truthMeters"], 1), "removedCount": c["removedCount"],
             "medianSpeedKmh": round(c["medianSpeedKmh"], 1), "turnDegrees": round(c["turnDegrees"], 1),
             "removed": removed, "notes": notes}
        with open(os.path.join(out, qid + ".json"), "w", encoding="utf-8") as f:
            json.dump(q, f, ensure_ascii=False)
        rows.append(q)

    # --- real ---
    mr = tracks["mr"]
    real_rows = []
    for rid, ia, ib, wids, sec_ref in REAL:
        A, B = mr.pts[ia], mr.pts[ib]
        poly, missing = build_polyline(ways, wids, A)
        sec = B[3] - A[3]
        notes = f"答案来自 OSM way 几何，见诊断报告 {sec_ref}（Tests/reports/20261026_1500_tunnel_diagnosis.md）"
        if missing:
            notes += f"；OSM 文件中找不到 way {missing}，折线只用了找到的 way"
        plen = sum(haversine(a[0], a[1], b[0], b[1]) for a, b in zip(poly, poly[1:]))
        q = {"id": rid, "kind": "real", "source": mr.rel, "band": band_of(sec), "roadType": "tunnel",
             "anchorA": pt_json(mr.pts, ia), "anchorB": pt_json(mr.pts, ib),
             "seconds": sec, "straightMeters": round(haversine(A[0], A[1], B[0], B[1]), 1),
             "removedCount": 0, "truthWays": [str(w) for w in wids],
             "truthPolyline": [[r7(p[0]), r7(p[1])] for p in poly], "notes": notes}
        with open(os.path.join(out, rid + ".json"), "w", encoding="utf-8") as f:
            json.dump(q, f, ensure_ascii=False)
        real_rows.append((q, plen, missing))

    # --- INDEX.md ---
    L = ["# 合成断档考卷 题目索引", "",
         f"由 `Tests/exam/make_questions.py` 生成（种子 {SEED}，规则见脚本 docstring 与 docs/fill-plausibility-design.md §2.1）。", "",
         "## 题数汇总（synthetic）", "",
         "| 源 | 档 | tunnel | straight | curve | 合计 |", "|---|---|---|---|---|---|"]
    for key, _ in SOURCES:
        for name in QUOTA:
            cs = [r for r in rows if r["id"].startswith(key + "_") and r["band"] == name]
            L.append(f"| {key} | {name} | " + " | ".join(str(sum(r["roadType"] == rt for r in cs))
                                                       for rt in ("tunnel", "straight", "curve")) + f" | {len(cs)} |")
    for name in QUOTA:
        cs = [r for r in rows if r["band"] == name]
        L.append(f"| 全部 | {name} | " + " | ".join(str(sum(r["roadType"] == rt for r in cs))
                                                   for rt in ("tunnel", "straight", "curve")) + f" | {len(cs)} / {QUOTA[name]} |")
    L += ["", f"synthetic 合计 **{len(rows)}**（mr {sum(r['id'].startswith('mr_') for r in rows)}，"
              f"rd {sum(r['id'].startswith('rd_') for r in rows)}）；real **{len(real_rows)}**；总计 **{len(rows) + len(real_rows)}**。", "",
          "## 候选池（去重前，同档内可互相重叠）", "",
          "| 源 | 档 | tunnel | straight | curve |", "|---|---|---|---|---|"]
    for key, _ in SOURCES:
        for name in QUOTA:
            cs = cands[key][name]
            L.append(f"| {key} | {name} | " + " | ".join(str(sum(c["roadType"] == rt for c in cs))
                                                       for rt in ("tunnel", "straight", "curve")) + " |")
    L += ["", "## real 题", "", "| id | band | seconds | straightMeters | ways | 折线点数 | 折线长 m | notes |",
          "|---|---|---|---|---|---|---|---|"]
    for q, plen, missing in real_rows:
        L.append(f"| {q['id']} | {q['band']} | {q['seconds']} | {q['straightMeters']} | {', '.join(q['truthWays'])} | "
                 f"{len(q['truthPolyline'])} | {plen:.0f} | {q['notes']} |")
    L += ["", "## synthetic 题", "", "| id | band | roadType | seconds | straightMeters | removedCount |",
          "|---|---|---|---|---|---|"]
    for r in rows:
        L.append(f"| {r['id']} | {r['band']} | {r['roadType']} | {r['seconds']} | {r['straightMeters']} | {r['removedCount']} |")
    L += ["", "## 候选不足", ""]
    L += [f"- {s}" for s in shortfall] if shortfall else ["- 无：各档均已出满。"]
    ntun = sum(r["roadType"] == "tunnel" for r in rows)
    L.append(f"- tunnel 题 {ntun} / 封顶 {TUNNEL_CAP}（候选来自 {len(by_way)} 条隧道 way；每条最多 {TUNNEL_PER_WAY} 题）。")
    if not by_way:
        nh = {k: tracks[k].hitpre[-1] for k in tracks}
        L.append(f"- tunnel 候选为 0：隧道 25 m 内的轨迹点只有 {nh}，且这些点前后 300 s 内都有 GPS 断档"
                 "（dt>3 s 或步长>150 m 的步），不满足「连续路段」条件——Garmin 进隧道就丢信号，"
                 "隧道断档只能由 real 题覆盖。")
    with open(os.path.join(out, "INDEX.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")

    print(f"synthetic {len(rows)} (tunnel {ntun}), real {len(real_rows)} → {out}")
    for s in shortfall:
        print("SHORTFALL", s)
    for q, plen, missing in real_rows:
        print(f"  {q['id']}: band {q['band']} sec {q['seconds']} poly {len(q['truthPolyline'])} pts {plen:.0f} m"
              + (f" MISSING {missing}" if missing else ""))
    print(f"done in {time.time()-t0:.1f}s")


if __name__ == "__main__":
    main()
