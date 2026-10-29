#!/usr/bin/env python3
"""legit-motion: clean, artefact-free recordings of real kinds of motion.

Every file must give replays 0 and jitter 0; gap counts are stated per file
(0 everywhere except the sparse phone background file, where every step with
dt >= 20 s, >= 150 m and 15-350 km/h is a legitimate timeGap candidate by the
detector's own definition).

Run with this directory as cwd:  python3 -I gen.py
Writes the data files and expect.json. Stdlib only, deterministic (fixed seeds).

Model
-----
* Route = polyline in local metres (x east, y north) built from straight / arc
  pieces, each with a speed cap; stops are vertices with cap 0 and a dwell time.
* Speed profile = classic forward/backward pass (accel / brake limits) over the
  vertex grid, then t(s) integrated; positions are sampled at the recorder's
  sample times by interpolating s(t).
* Noise = AR(1) per axis (correlated GPS error, tau 20-60 s) + small white part;
  device error is additionally low-passed (4 s) so per-second changes are dm-level;
  phones additionally get a heavy tail (3 % single-fix outliers of 45-110 m).
  Device sigma 2.5-4.5 m/axis (radial 3-6 m, stationary wander ~5 m);
  phone 9 m/axis (radial ~11 m, 10-30 m with a 50 m+ tail).
* lat/lon: lat = lat0 + y/111195, lon = lon0 + x/(111195 cos lat) (exact local
  scale w.r.t. the detector's haversine R = 6371 km).
"""
import csv
import io
import json
import math
import os
import random
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

R_EARTH = 6371000.0
M_PER_DEG = R_EARTH * math.pi / 180.0          # 111194.9 m


def hav(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R_EARTH * math.asin(min(1.0, math.sqrt(h)))


def xy_to_ll(lat0, lon0, x, y):
    lat = lat0 + y / M_PER_DEG
    lon = lon0 + x / (M_PER_DEG * math.cos(math.radians(lat)))
    return lat, lon


# --------------------------------------------------------------------------- route

class Route:
    """Polyline with per-vertex speed caps (m/s) and dwell (s) at stop vertices.
    heading: degrees, 0 = north, clockwise. arc angle > 0 = right turn."""

    def __init__(self, heading=0.0, step=2.0, rng=None, var=0.04):
        self.x, self.y = [0.0], [0.0]
        self.cap = [0.0]
        self.dwell = {0: 0.0}
        self.h = math.radians(heading)
        self.step = step
        self.rng = rng or random.Random(0)
        self.var = var              # +-relative slow variation of the cap on straights
        self.marks = {}
        self.s = [0.0]

    def _push(self, x, y, cap):
        self.s.append(self.s[-1] + math.hypot(x - self.x[-1], y - self.y[-1]))
        self.x.append(x)
        self.y.append(y)
        self.cap.append(cap)

    def straight(self, length, v, step=None):
        st = step or self.step
        n = max(1, int(math.ceil(length / st)))
        x0, y0 = self.x[-1], self.y[-1]
        ph1, ph2 = self.rng.uniform(0, 6.283), self.rng.uniform(0, 6.283)
        lam1, lam2 = max(200.0, 40 * v), max(90.0, 15 * v)
        s0 = self.s[-1]
        for k in range(1, n + 1):
            d = length * k / n
            s = s0 + d
            f = 1 + self.var * (0.6 * math.sin(2 * math.pi * s / lam1 + ph1) + 0.4 * math.sin(2 * math.pi * s / lam2 + ph2)) - self.var
            self._push(x0 + d * math.sin(self.h), y0 + d * math.cos(self.h), v * f)
        return self

    def arc(self, radius, angle_deg, v, step=None):
        st = min(step or self.step, max(0.5, radius * 0.1))
        sign = 1.0 if angle_deg > 0 else -1.0
        ang = math.radians(abs(angle_deg))
        n = max(2, int(math.ceil(radius * ang / st)))
        x0, y0 = self.x[-1], self.y[-1]
        cx = x0 + radius * math.sin(self.h + sign * math.pi / 2)
        cy = y0 + radius * math.cos(self.h + sign * math.pi / 2)
        for k in range(1, n + 1):
            hk = self.h + sign * ang * k / n
            self._push(cx + radius * math.sin(hk - sign * math.pi / 2), cy + radius * math.cos(hk - sign * math.pi / 2), v)
        self.h += sign * ang
        return self

    def stop(self, dwell):
        i = len(self.x) - 1
        self.cap[i] = 0.0
        self.dwell[i] = self.dwell.get(i, 0.0) + dwell
        return self

    def mark(self, name):
        self.marks[name] = len(self.x) - 1
        return self

    def retrace(self, to_index, v_scale=1.0):
        """Drive back along the vertices already laid (dead-end reversal): same geometry, reversed."""
        last = len(self.x) - 1
        for k in range(last - 1, to_index - 1, -1):
            cap = self.cap[k] if self.cap[k] > 0 else self.cap[k + 1]
            self._push(self.x[k], self.y[k], cap * v_scale)
        dx, dy = self.x[-1] - self.x[-2], self.y[-1] - self.y[-2]
        self.h = math.atan2(dx, dy)
        return self


class Kin:
    """Speed profile + timeline for a Route."""

    def __init__(self, route, acc, dec, t0=0.0, start_dwell=0.0, end_stop=True, v_start=0.0):
        r = route
        n = len(r.x)
        cap = list(r.cap)
        cap[0] = v_start
        if end_stop:
            cap[-1] = 0.0
        v = cap[:]
        # forward
        for i in range(1, n):
            ds = r.s[i] - r.s[i - 1]
            v[i] = min(cap[i], math.sqrt(v[i - 1] ** 2 + 2 * acc * ds))
        # backward
        for i in range(n - 2, -1, -1):
            ds = r.s[i + 1] - r.s[i]
            v[i] = min(v[i], math.sqrt(v[i + 1] ** 2 + 2 * dec * ds))
        self.v = v
        ta = [0.0] * n
        td = [0.0] * n
        ta[0] = t0
        td[0] = t0 + start_dwell + r.dwell.get(0, 0.0)
        for i in range(1, n):
            ds = r.s[i] - r.s[i - 1]
            vm = 0.5 * (v[i] + v[i - 1])
            if vm <= 1e-9:
                raise ValueError("zero-speed cell at vertex %d" % i)
            ta[i] = td[i - 1] + ds / vm
            td[i] = ta[i] + r.dwell.get(i, 0.0)
        self.ta, self.td = ta, td
        self.route = r
        self.t_end = td[-1]
        self._j = 0

    def at(self, t):
        """-> (x, y, speed m/s, heading deg, vertex index) at time t (monotone queries are O(1) amortised)."""
        r = self.route
        n = len(r.x)
        if t <= self.td[0]:
            return r.x[0], r.y[0], 0.0, None, 0
        if t >= self.ta[-1]:
            return r.x[-1], r.y[-1], 0.0, None, n - 1
        j = self._j
        if t < self.td[j]:
            j = 0
        while j + 1 < n and self.ta[j + 1] <= t:
            j += 1
        self._j = j
        if t <= self.td[j]:                       # dwelling at vertex j
            return r.x[j], r.y[j], 0.0, None, j
        f = (t - self.td[j]) / (self.ta[j + 1] - self.td[j])
        x = r.x[j] + f * (r.x[j + 1] - r.x[j])
        y = r.y[j] + f * (r.y[j + 1] - r.y[j])
        sp = self.v[j] + f * (self.v[j + 1] - self.v[j])
        hd = math.degrees(math.atan2(r.x[j + 1] - r.x[j], r.y[j + 1] - r.y[j])) % 360
        return x, y, sp, hd, j


# --------------------------------------------------------------------------- noise

class ARNoise:
    def __init__(self, rng, sigma, tau, white, outlier_p=0.0, outlier_r=(45.0, 110.0), smooth=0.0):
        self.rng, self.sigma, self.tau, self.white = rng, sigma, tau, white
        self.p, self.orr = outlier_p, outlier_r
        self.smooth = smooth            # extra first-order low-pass (s): receiver-filtered, smooth error
        self.ex = rng.gauss(0, sigma)
        self.ey = rng.gauss(0, sigma)
        self.fx, self.fy = self.ex, self.ey
        self.t = None

    def __call__(self, t):
        if self.t is not None:
            rho = math.exp(-max(0.0, t - self.t) / self.tau)
            k = math.sqrt(1 - rho * rho) * self.sigma
            self.ex = rho * self.ex + k * self.rng.gauss(0, 1)
            self.ey = rho * self.ey + k * self.rng.gauss(0, 1)
            if self.smooth > 0:
                a = math.exp(-max(0.0, t - self.t) / self.smooth)
                self.fx = a * self.fx + (1 - a) * self.ex
                self.fy = a * self.fy + (1 - a) * self.ey
        self.t = t
        bx, by = (self.fx, self.fy) if self.smooth > 0 else (self.ex, self.ey)
        nx = bx + self.rng.gauss(0, self.white)
        ny = by + self.rng.gauss(0, self.white)
        out = False
        if self.p > 0 and self.rng.random() < self.p:
            a = self.rng.uniform(0, 2 * math.pi)
            rr = self.rng.uniform(*self.orr)
            nx += rr * math.sin(a)
            ny += rr * math.cos(a)
            out = True
        return nx, ny, out


def device_noise(rng, sigma=None):
    return ARNoise(rng, sigma if sigma is not None else rng.uniform(2.5, 4.5), tau=60.0, white=0.15, smooth=4.0)


def phone_noise(rng, sigma=9.0, outlier_p=0.03):
    return ARNoise(rng, sigma, tau=20.0, white=2.5, outlier_p=outlier_p)


# --------------------------------------------------------------------------- sampling

def times_1hz(t0, t1):
    return [float(t) for t in range(int(math.ceil(t0)), int(math.floor(t1)) + 1)]


def times_steps(rng, t0, t1, choices, weights):
    out, t = [], float(int(t0))
    while t <= t1:
        out.append(t)
        t += rng.choices(choices, weights)[0]
    return out


def sample(kin, times, lat0, lon0, noise, ele_fn, freeze_stops=False):
    """-> list of dicts: lat, lon, ele, t, speed, heading, outlier, moving."""
    pts = []
    frozen = None
    for t in times:
        x, y, sp, hd, j = kin.at(t)
        nx, ny, out = noise(t)
        moving = sp > 0.3
        if freeze_stops and not moving:
            # iOS while stationary: keeps handing out the same cached fix (bit-identical)
            if frozen is None:
                frozen = (x + nx, y + ny)
            px, py = frozen
            out = False
        else:
            frozen = None
            px, py = x + nx, y + ny
        lat, lon = xy_to_ll(lat0, lon0, px, py)
        s_here = kin.route.s[j]
        pts.append(dict(lat=lat, lon=lon, ele=ele_fn(s_here, t), t=t, speed=sp, heading=hd, outlier=out, moving=moving))
    return pts


# --------------------------------------------------------------------------- writers

def iso(t):
    return datetime.fromtimestamp(int(t), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_gpx(fname, creator, name, pts, decimals=8, tfield="t"):
    b = io.StringIO()
    b.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    b.write('<gpx version="1.1" creator="%s" xmlns="http://www.topografix.com/GPX/1/1" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">\n' % creator)
    b.write('  <metadata><time>%s</time></metadata>\n' % iso(pts[0][tfield]))
    b.write('  <trk>\n    <name>%s</name>\n    <trkseg>\n' % name)
    fmt = '      <trkpt lat="%.{0}f" lon="%.{0}f"><ele>%.1f</ele><time>%s</time></trkpt>\n'.format(decimals)
    for p in pts:
        b.write(fmt % (p["lat"], p["lon"], p["ele"], iso(p[tfield])))
    b.write('    </trkseg>\n  </trk>\n</gpx>\n')
    with open(fname, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(b.getvalue())


CSV_HEADER = "dataTime,locType,longitude,latitude,heading,accuracy,speed,distance,isBackForeground,stepType,altitude"


def write_csv(fname, rng, pts, background=False, zero_acc_p=0.4):
    lines = [CSV_HEADER]
    dist = 0.0
    prev = None
    for p in pts:
        if prev is not None:
            dist += hav(prev["lat"], prev["lon"], p["lat"], p["lon"])
        prev = p
        if p["outlier"]:
            acc = rng.choice([50.0, 65.0, 65.0, 100.0])
        else:
            acc = rng.choice([5.0, 10.0, 10.0, 15.0, 15.0, 20.0, 30.0])
        if rng.random() < zero_acc_p:
            acc = 0.0                         # one-life-footprint writes 0 (unknown) for about half of the fixes
        hd = p["heading"] if p["heading"] is not None else -1.0
        sp = p["speed"] if p["moving"] else -1.0
        lines.append("%d,%d,%.8f,%.8f,%.1f,%.1f,%.2f,%.1f,%d,%d,%.1f" % (
            int(p["t"]), 1, p["lon"], p["lat"], hd, acc, sp, dist, 2 if background else 1, 0, p["ele"]))
    with open(fname, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


# --------------------------------------------------------------------------- detector ports (for expectations)

def timegap_count(pts):
    """Port of GapDetector.detect's timeGap branch. -> (count, borderline)"""
    n = c = border = 0
    for a, b in zip(pts, pts[1:]):
        dt = b["t"] - a["t"]
        d = hav(a["lat"], a["lon"], b["lat"], b["lon"])
        if d >= 150 and dt >= 20:
            kmh = d / dt * 3.6
            if dt <= 3600 and 15 <= kmh <= 350:
                c += 1
            if abs(d - 150) < 3 or abs(kmh - 15) < 0.5 or abs(kmh - 350) < 5:
                border += 1
        elif dt >= 20 and abs(d - 150) < 3:
            border += 1
    return c, border


def stale_entries(pts):
    """Steps that enter the staleClock branch at all (>= 150 m and implied > 350 km/h)."""
    k = 0
    for a, b in zip(pts, pts[1:]):
        dt = b["t"] - a["t"]
        d = hav(a["lat"], a["lon"], b["lat"], b["lon"])
        if d >= 150 and (dt <= 0 or d / dt * 3.6 > 350):
            k += 1
    return k


def max_time_jump(pts):
    return max((b["t"] - a["t"] for a, b in zip(pts, pts[1:])), default=0)


def trips_port(pts):
    """Port of TripSegmenter.trips boundary logic -> trip count."""
    n = len(pts)
    if n < 2:
        return 0
    la = [p["lat"] for p in pts]
    lo = [p["lon"] for p in pts]
    t = [p["t"] for p in pts]
    bounds = [0]
    i = 0
    while i < n - 1:
        j = i
        while j + 1 < n and hav(la[i], lo[i], la[j + 1], lo[j + 1]) <= 150:
            j += 1
        stayed = t[j] - t[i] >= 600
        blank = j + 1 < n and t[j + 1] - t[j] >= 600
        if stayed or blank:
            if j + 1 < n and bounds[-1] != j + 1:
                bounds.append(j + 1)
            i = j + 1
        else:
            k = i + 1
            while k < n - 1 and t[k] - t[i] < 30:
                k += 1
            i = k
    bounds.append(n)
    return sum(1 for a, b in zip(bounds, bounds[1:]) if b - a >= 2)


def replay_port(pts):
    """Port of GapDetector.replayFlags -> count (sanity: must be 0 here)."""
    n = len(pts)
    flags = [False] * n
    last = {}
    order = []
    head = 0
    la = [p["lat"] for p in pts]
    lo = [p["lon"] for p in pts]
    t = [p["t"] for p in pts]
    for i in range(n):
        while head < len(order) and t[i] - t[order[head]] > 1800:
            k = order[head]
            key = (la[k], lo[k])
            if last.get(key) == k:
                del last[key]
            head += 1
        kk = (la[i], lo[i])
        j = last.get(kk)
        if j is not None:
            if t[i] - t[j] < 10:
                continue
            k, steps = i - 1, 0
            while k > 0 and (flags[k] or t[i] - t[k] < 10) and steps < 256:
                k -= 1
                steps += 1
            if k >= 0 and hav(la[k], lo[k], la[i], lo[i]) >= 50:
                stride = max(1, (i - j) // 60)
                m = j + 1
                while m < i:
                    if hav(la[i], lo[i], la[m], lo[m]) >= 300:
                        flags[i] = True
                        break
                    m += stride
        if not flags[i]:
            last[kk] = i
            order.append(i)
    return sum(flags)


def round_like_file(pts, decimals):
    """The detector sees the coordinates as written: round for the ports."""
    q = []
    for p in pts:
        r = dict(p)
        r["lat"] = float("%.*f" % (decimals, p["lat"]))
        r["lon"] = float("%.*f" % (decimals, p["lon"]))
        q.append(r)
    return q


# --------------------------------------------------------------------------- scenarios

T_BASE = 1777600000            # 2026-05-01 01:46:40 UTC


def flat(e):
    return lambda s, t: e


def sc_walk_loop():
    rng = random.Random(101)
    r = Route(heading=80, step=1.0, rng=rng, var=0.05)
    v = 1.45
    r.straight(300, v).arc(12, 90, 1.1).straight(200, v).arc(40, 35, 1.3).straight(130, v)
    r.stop(95)                                                   # pause 1: shop window, 95 s
    r.straight(160, v).arc(40, 55, 1.3).straight(330, v).arc(15, 90, 1.1).straight(120, v)
    r.stop(185)                                                  # pause 2: viewpoint, ~3 min
    r.straight(300, v).arc(25, -60, 1.2).straight(110, v).arc(25, 60, 1.2).straight(200, v)
    r.stop(240)                                                  # pause 3: bench, 4 min
    r.straight(160, v).arc(10, 90, 1.0).straight(260, v).arc(30, 40, 1.2).straight(120, v)
    k = Kin(r, acc=0.5, dec=0.7, t0=T_BASE + 3600 * 7, start_dwell=25)
    times = times_1hz(k.ta[0], k.t_end)
    pts = sample(k, times, 47.37690, 8.54170, device_noise(rng, 3.2), lambda s, t: 410 + 6 * math.sin(s / 300))
    return dict(kind="gpx", creator="Garmin eTrex 32x", pts=pts, decimals=8,
                desc="Walking loop in Zurich, Garmin eTrex 1 Hz, %.0f min, three pauses (95 s, 185 s, 240 s) with stationary "
                     "GPS wander (AR noise sigma 3.2 m/axis), ends near the start. 1.45 m/s, corners r=10-40 m." % ((times[-1] - times[0]) / 60),
                profile="deviceLogger", trips=True)


def sc_hike_switchbacks():
    rng = random.Random(102)
    r = Route(heading=10, step=1.0, rng=rng, var=0.06)
    r.straight(420, 1.25).arc(30, 25, 1.1).straight(180, 1.2)
    # zigzag up the slope (uphill = north): legs at +-70 deg from the fall line, hairpins 140 deg, r 4 m
    r.h = math.radians(70)
    turn = -140
    for leg in range(12):
        L = rng.uniform(150, 300)
        r.straight(L, rng.uniform(0.85, 1.0))
        r.arc(4.0, turn, 0.55)
        turn = -turn
    r.straight(120, 0.95)
    r.stop(150)                                                  # summit rest 2.5 min
    r.straight(200, 1.2)
    k = Kin(r, acc=0.4, dec=0.6, t0=T_BASE + 86400 * 3 + 3600 * 6, start_dwell=15)
    times = times_1hz(k.ta[0], k.t_end)
    base = 1050.0

    def ele(s, t):
        return base + 0.12 * s + 3 * math.sin(s / 90)
    pts = sample(k, times, 46.62410, 8.04120, device_noise(rng, 3.8), ele)
    return dict(kind="gpx", creator="Garmin eTrex 32x", pts=pts, decimals=8,
                desc="Hike with 12 switchbacks (legs 150-300 m at +-70 deg from the fall line, 140-deg hairpins r=4 m at 0.55 m/s), "
                     "Garmin 1 Hz, %.0f min, summit rest 150 s. Walking pace 0.85-1.25 m/s, slow hairpins." % ((times[-1] - times[0]) / 60),
                profile="deviceLogger", trips=False)


def sc_cycle():
    rng = random.Random(103)
    r = Route(heading=0, step=2.0, rng=rng, var=0.06)
    r.straight(900, 6.2).arc(10, 90, 4.0).straight(700, 6.0).stop(35)          # red light
    r.straight(650, 6.3).mark("uturn_a").arc(3.0, 180, 1.8).mark("uturn_b")       # wrong way: U-turn
    r.straight(320, 6.0).arc(10, -90, 4.0).straight(1100, 6.2)
    # roundabout (right-hand traffic, counter-clockwise): veer right 30, circle left 300, veer right 30
    r.mark("rb_a").arc(12, 30, 4.0).arc(14, -300, 4.2).arc(12, 30, 4.0).mark("rb_b")
    r.straight(1500, 6.3).arc(25, 45, 5.0).straight(900, 6.1).arc(10, -90, 4.0).straight(1300, 6.0)
    r.arc(60, 30, 5.5).straight(1400, 6.2).stop(20).straight(600, 5.8)
    k = Kin(r, acc=0.8, dec=1.5, t0=T_BASE + 86400 * 5 + 3600 * 16, start_dwell=10)
    times = times_1hz(k.ta[0], k.t_end)
    pts = sample(k, times, 52.37020, 4.89520, device_noise(rng, 3.0), flat(2.0))
    tu = (k.ta[r.marks["uturn_a"]], k.td[r.marks["uturn_b"]])
    trb = (k.ta[r.marks["rb_a"]], k.td[r.marks["rb_b"]])
    return dict(kind="gpx", creator="Garmin Edge 830", pts=pts, decimals=8,
                desc="Cycling in Amsterdam, Garmin Edge 1 Hz, %.0f min at ~6 m/s; U-turn (180 deg, r=3 m, 1.8 m/s) at t=%d-%d, "
                     "roundabout (veer 30, circle 300 deg r=14 m, veer 30) at t=%d-%d, two light stops." % (
                         (times[-1] - times[0]) / 60, tu[0], tu[1], trb[0], trb[1]),
                profile="deviceLogger", trips=True,
                jitter_free=[[int(tu[0]) - 30, int(tu[1]) + 60], [int(trb[0]) - 30, int(trb[1]) + 60]])


def sc_car_city():
    rng = random.Random(104)
    r = Route(heading=90, step=2.0, rng=rng, var=0.05)
    v = 13.9
    marks = []
    plan = [("s", 420), ("light", 45), ("s", 300), ("t", 90), ("s", 520), ("light", 70), ("s", 260), ("t", -90),
            ("s", 380), ("u", 0), ("s", 380), ("t", 90), ("s", 600), ("light", 25), ("s", 450), ("t", 90),
            ("s", 300), ("light", 90), ("s", 330), ("t", -90), ("s", 700), ("u", 0), ("s", 250), ("light", 55),
            ("s", 450), ("t", 90), ("s", 380), ("light", 30), ("s", 520), ("t", -90), ("s", 400), ("light", 60), ("s", 300)]
    for kind, val in plan:
        if kind == "s":
            r.straight(val, v * rng.uniform(0.85, 1.0))
        elif kind == "t":
            r.arc(10, val, 4.2)
        elif kind == "u":
            r.mark("u%d" % len(marks))
            marks.append(len(r.x) - 1)
            r.straight(4, 3.0).arc(6, -180, 2.6).straight(4, 3.0)
        elif kind == "light":
            r.stop(val)
    k = Kin(r, acc=1.6, dec=2.2, t0=T_BASE + 86400 * 8 + 3600 * 15, start_dwell=30)
    times = times_1hz(k.ta[0], k.t_end)
    pts = sample(k, times, 48.13720, 11.57540, device_noise(rng, 3.5), flat(520.0))
    uts = [int(k.ta[m]) for m in marks]
    return dict(kind="gpx", creator="Garmin DriveSmart 66", pts=pts, decimals=8,
                desc="City drive in Munich, Garmin 1 Hz, %.0f min at <=50 km/h; 90-deg turns r=10 m, two U-turns (r=6 m, 2.6 m/s) at "
                     "t~%s, 8 stops at lights 25-90 s with stationary GPS wander (~5 m)." % ((times[-1] - times[0]) / 60, uts),
                profile="deviceLogger", trips=True,
                jitter_free=[[u - 30, u + 60] for u in uts])


def sc_highway():
    rng = random.Random(105)
    r = Route(heading=20, step=4.0, rng=rng, var=0.04)
    r.straight(300, 15).arc(150, 30, 15).straight(400, 30)                     # on-ramp, merge
    r.straight(3000, 36.1).arc(1500, 12, 36.1).straight(4200, 36.1).arc(2000, -18, 36.1).straight(2500, 36.1)
    r.straight(600, 30)                                                           # past the overpass
    r.mark("clover_a").arc(300, 8, 24).straight(250, 18).arc(55, 270, 11.0).straight(200, 18).mark("clover_b")
    r.arc(300, -8, 25).straight(4500, 36.1).arc(1800, 15, 36.1).straight(5200, 36.1).arc(1200, -20, 33)
    r.straight(3000, 36.1).arc(400, 25, 22).straight(600, 15)                    # off-ramp
    k = Kin(r, acc=1.4, dec=1.6, t0=T_BASE + 86400 * 10 + 3600 * 9, start_dwell=20)
    times = times_1hz(k.ta[0], k.t_end)
    pts = sample(k, times, 49.42100, 11.11500, device_noise(rng, 3.0), lambda s, t: 330 + 20 * math.sin(s / 4000))
    tc = (int(k.ta[r.marks["clover_a"]]), int(k.td[r.marks["clover_b"]]))
    return dict(kind="gpx", creator="Garmin DriveSmart 76", pts=pts, decimals=8,
                desc="Motorway near Nuremberg, Garmin 1 Hz, %.0f min at 130 km/h (36 m/s); cloverleaf left turn = 270-deg loop ramp "
                     "r=55 m at 40 km/h between t=%d-%d, gentle r=1.2-2 km curves." % ((times[-1] - times[0]) / 60, tc[0], tc[1]),
                profile="deviceLogger", trips=True, jitter_free=[[tc[0] - 60, tc[1] + 60]])


def sc_car_phone():
    rng = random.Random(106)
    r = Route(heading=0, step=2.0, rng=rng, var=0.06)
    r.straight(600, 16).arc(15, 90, 5).straight(900, 15).stop(40).straight(700, 16).arc(12, -90, 4.5)
    r.straight(1200, 17).mark("u_a").arc(7, 180, 2.8).mark("u_b").straight(500, 15).arc(15, 90, 5)
    r.straight(1500, 18).stop(65).straight(1300, 17).arc(200, -40, 14).straight(1800, 19).arc(15, 90, 5)
    r.straight(800, 15).stop(30).straight(1100, 16).arc(12, -90, 4.5).straight(700, 14)
    k = Kin(r, acc=1.5, dec=2.0, t0=T_BASE + 86400 * 12 + 3600 * 10, start_dwell=20)
    times = times_steps(rng, k.ta[0], k.t_end, [2, 3, 4], [0.15, 0.7, 0.15])
    pts = sample(k, times, 31.23040, 121.47370, phone_noise(rng), flat(8.0))
    tu = (int(k.ta[r.marks["u_a"]]), int(k.td[r.marks["u_b"]]))
    return dict(kind="csv", pts=pts, background=False,
                desc="Car in Shanghai, phone CSV (one-life-footprint layout) foreground ~3 s sampling (2/3/4 s), %.0f min, "
                     "phone noise 9 m/axis + 3%% outliers 45-110 m (never >= 300 m step); U-turn r=7 m at t=%d-%d, 3 light stops." % (
                         (times[-1] - times[0]) / 60, tu[0], tu[1]),
                profile="phone", trips=True, jitter_free=[[tu[0] - 30, tu[1] + 60]])


def sc_bus():
    rng = random.Random(107)
    r = Route(heading=270, step=2.0, rng=rng, var=0.07)
    for leg in range(12):
        r.straight(rng.uniform(350, 700), 12.0 * rng.uniform(0.8, 1.0))
        if leg % 4 == 3:
            r.arc(15, rng.choice([90, -90]), 4.0)
        r.straight(rng.uniform(80, 200), 11.0)
        if leg % 3 == 1:
            r.stop(rng.uniform(25, 60))       # traffic light
        r.straight(rng.uniform(60, 150), 10.0)
        r.stop(rng.uniform(20, 45))           # bus stop
    r.straight(400, 11)
    k = Kin(r, acc=1.0, dec=1.2, t0=T_BASE + 86400 * 14 + 3600 * 1, start_dwell=40)
    times = times_steps(rng, k.ta[0], k.t_end, [1, 2, 3], [0.5, 0.35, 0.15])
    pts = sample(k, times, 39.91380, 116.39740, phone_noise(rng), flat(48.0), freeze_stops=True)
    return dict(kind="csv", pts=pts, background=False,
                desc="City bus in Beijing, phone CSV 1-3 s sampling, %.0f min, <=43 km/h, 12 bus stops + 4 lights; while stationary "
                     "the phone repeats the same cached fix bit-identically (static repeats are not replays: no movement in between)." % (
                         (times[-1] - times[0]) / 60),
                profile="phone", trips=True)


def sc_train_regional():
    rng = random.Random(108)
    r = Route(heading=200, step=4.0, rng=rng, var=0.03)
    r.straight(1500, 25).arc(900, 25, 28).straight(5200, 33.3).arc(1200, -30, 30).straight(3000, 33.3).stop(55)    # station 1
    r.straight(2500, 33.3).arc(700, 40, 25).straight(6000, 33.3).arc(1500, 20, 33.3).straight(2000, 33.3).stop(80)  # station 2
    r.straight(4000, 33.3).arc(1000, -35, 28).straight(5500, 33.3).arc(800, 15, 27).straight(2500, 30).stop(70)
    r.straight(3500, 33.3).arc(1200, 25, 30).straight(2000, 28)
    k = Kin(r, acc=0.7, dec=0.8, t0=T_BASE + 86400 * 17 + 3600 * 13, start_dwell=60)
    times = times_1hz(k.ta[0], k.t_end)
    pts = sample(k, times, 50.35080, 7.58870, device_noise(rng, 3.5), lambda s, t: 80 + 0.002 * s)
    return dict(kind="gpx", creator="Garmin eTrex 32x", pts=pts, decimals=8,
                desc="Regional train along the Moselle, Garmin 1 Hz, %.0f min, 120 km/h (33.3 m/s), accel 0.7 / brake 0.8 m/s^2, "
                     "3 intermediate stops 55-80 s, curves r=0.7-1.5 km." % ((times[-1] - times[0]) / 60),
                profile="deviceLogger", trips=True)


def sc_hsr_bunching():
    rng = random.Random(109)
    r = Route(heading=310, step=6.0, rng=rng, var=0.02)
    r.straight(3000, 45).arc(4000, 10, 70).straight(18000, 83.3).arc(6000, -12, 83.3).straight(22000, 95.0)
    r.arc(7000, 9, 90).straight(15000, 88).arc(4000, -10, 75).straight(4500, 40).stop(120)
    r.straight(3000, 45).arc(5000, 12, 80).straight(26000, 92).arc(6000, -8, 86).straight(5000, 60)
    k = Kin(r, acc=0.45, dec=0.55, t0=T_BASE + 86400 * 20 + 3600 * 8, start_dwell=60)
    true_t = times_1hz(k.ta[0], k.t_end)
    pts = sample(k, true_t, 50.05300, 8.57000, device_noise(rng, 3.0), flat(140.0))
    # Garmin bunching: true 1 Hz positions, timestamps stick for 1-4 points then jump to the true time
    i = 0
    max_group = 0
    while i < len(pts):
        g = rng.choices([1, 2, 3, 4], [0.3, 0.3, 0.22, 0.18])[0]
        tw = pts[i]["t"]
        for q in range(i, min(len(pts), i + g)):
            pts[q]["tw"] = tw
        max_group = max(max_group, g)
        i += g
    for p in pts:
        p["t_true"] = p["t"]
        p["t"] = p["tw"]
    vmax = max(k.v) * 3.6
    return dict(kind="gpx", creator="Garmin Explore", pts=pts, decimals=8,
                desc="High-speed rail Frankfurt area, %.0f min, cruise 300-342 km/h (83-95 m/s), one 2-min station stop; Garmin "
                     "bunching: true 1 Hz positions advance ~90 m per point but written timestamps stick for 1-4 points then jump "
                     "(same-second groups of up to 4 points). Max speed %.0f km/h. Consecutive points stay < 150 m apart, so neither "
                     "the staleClock branch nor timeGap can fire." % ((true_t[-1] - true_t[0]) / 60, vmax),
                profile="deviceLogger", trips=True)


def sc_aircraft():
    rng = random.Random(110)
    r = Route(heading=250, step=10.0, rng=rng, var=0.015)
    r.straight(3400, 82).mark("liftoff")                                        # takeoff roll 0 -> 80 m/s
    r.straight(9000, 150).arc(6000, 95, 150).straight(30000, 240)
    r.arc(15000, -20, 245).straight(120000, 250).mark("hold_a")
    R_hold = 230 * 240 / (2 * math.pi)                                          # 4-min circle at 230 m/s
    r.arc(R_hold, 720, 230).mark("hold_b").straight(45000, 232)
    k = Kin(r, acc=1.9, dec=0.6, t0=T_BASE + 86400 * 23 + 3600 * 11, start_dwell=60, end_stop=False)
    times = times_1hz(k.ta[0], k.t_end)
    t_lift = k.ta[r.marks["liftoff"]]

    def ele(s, t):
        if t <= t_lift:
            return 111.0
        return min(11000.0, 111.0 + 12.0 * (t - t_lift))
    pts = sample(k, times, 50.03330, 8.57060, device_noise(rng, 3.0), ele)
    th = (int(k.ta[r.marks["hold_a"]]), int(k.ta[r.marks["hold_b"]]))
    return dict(kind="gpx", creator="Garmin GPSMAP 66sr", pts=pts, decimals=8,
                desc="Aircraft from FRA, Garmin 1 Hz, %.0f min: 60 s lined up, takeoff roll, climb 150 m/s, cruise 240-250 m/s "
                     "(up to 900 km/h), then two 4-min holding circles (r=%.1f km, 230 m/s) t=%d-%d, exit. Every 1-s step (>= 150 m at "
                     ">350 km/h) enters the staleClock branch, but there is no time jump so it must find nothing; 60-s heading "
                     "chord in the circle is 45 deg off the step, never a reversal." % ((times[-1] - times[0]) / 60, R_hold / 1000, th[0], th[1]),
                profile="deviceLogger", trips=True, jitter_free=[[th[0], th[1] + 120]])


def sc_boat():
    rng = random.Random(111)
    r = Route(heading=180, step=2.0, rng=rng, var=0.05)
    # backs out of the pier (heading reversed in the route = boat moving astern), then turns and cruises
    r.straight(60, 1.0).stop(8)
    r.h = math.radians(180 + 150)
    r.arc(70, -110, 3.0).straight(500, 7.0).arc(1200, 25, 8.5).straight(4200, 8.8).arc(800, -30, 8.5).straight(1800, 8.6)
    r.arc(150, 70, 4.0).straight(250, 2.5).straight(40, 0.8)
    k = Kin(r, acc=0.25, dec=0.3, t0=T_BASE + 86400 * 26 + 3600 * 12, start_dwell=120)
    times = times_steps(rng, k.ta[0], k.t_end, [1, 2, 3], [0.1, 0.8, 0.1])
    pts = sample(k, times, 46.50600, 6.62700, phone_noise(rng, sigma=5.0, outlier_p=0.01), flat(372.0))
    return dict(kind="gpx", creator="GPSLogger for Android", pts=pts, decimals=7,
                desc="Lake Geneva passenger boat, phone GPX (GPSLogger for Android, ~2 s), %.0f min: 2 min at the pier, backs out "
                     "60 m astern, stops, turns 110 deg and cruises at 30 km/h, docks. Open-water phone noise 5 m/axis, 1%% outliers." % (
                         (times[-1] - times[0]) / 60),
                profile="phone", trips=True)


def sc_phone_sparse_mountain():
    rng = random.Random(112)
    r = Route(heading=45, step=3.0, rng=rng, var=0.04)
    r.straight(3000, 27.8).arc(600, 20, 25).straight(5000, 27.8).arc(450, -35, 22).straight(3500, 27.8)
    r.mark("pins_a")
    r.h = math.radians(80)
    turn = -160
    for leg in range(9):
        r.straight(rng.uniform(250, 600), 16.7)
        r.arc(12, turn, 7.0)
        turn = -turn
    r.mark("pins_b")
    r.straight(800, 20).arc(300, 30, 18).straight(4500, 27.8).arc(800, -25, 26).straight(6000, 27.8).arc(500, 30, 24).straight(2500, 27.8)
    k = Kin(r, acc=2.0, dec=2.5, t0=T_BASE + 86400 * 29 + 3600 * 4, start_dwell=30)
    # background sampling: mostly 20-30 s, 15 % shorter (8-19 s) steps
    times = []
    t = float(int(k.ta[0]))
    while t <= k.t_end:
        times.append(t)
        t += rng.randint(20, 30) if rng.random() < 0.85 else rng.randint(8, 19)
    pts = sample(k, times, 26.87200, 100.22500, phone_noise(rng), lambda s, t: 2400 + 0.03 * s)
    th = (int(k.ta[r.marks["pins_a"]]), int(k.ta[r.marks["pins_b"]]))
    return dict(kind="csv", pts=pts, background=True,
                desc="Mountain road in Yunnan, phone CSV in background: 20-30 s steps (15%% 8-19 s), %.0f min, 100 km/h valley "
                     "sections and 9 hairpins (160 deg, r=12 m, 25 km/h) t=%d-%d. Every step with dt >= 20 s, >= 150 m, 15-350 km/h "
                     "is a legitimate timeGap candidate by definition (expected count from a port of the rule; range widened by the "
                     "number of steps within 3 m / 0.5 km/h of a threshold). No replays, no jitter." % (
                         (times[-1] - times[0]) / 60, th[0], th[1]),
                profile="phone", trips=True, jitter_free=[[th[0], th[1]]])


def sc_train_reverse(device):
    rng = random.Random(113 if device else 114)
    r = Route(heading=150 if device else 30, step=3.0, rng=rng, var=0.03)
    r.straight(2500, 22).arc(800, 20, 25).straight(4500, 28).mark("join").arc(600, -15, 22).straight(1500, 20)
    r.straight(450, 9).mark("terminus").stop(180)          # dead-end station, 3 min
    j = r.marks["join"]
    r.retrace(j, v_scale=0.95)                              # depart the same way back to the junction
    r.mark("back_at_join").arc(700, 25 if device else -25, 24).straight(5000, 28).arc(900, -20, 26).straight(2500, 25).stop(60)
    k = Kin(r, acc=0.6, dec=0.7, t0=T_BASE + 86400 * (32 if device else 34) + 3600 * 7, start_dwell=45)
    tt = int(k.ta[r.marks["terminus"]])
    if device:
        times = times_1hz(k.ta[0], k.t_end)
        pts = sample(k, times, 47.54450, 9.68200, device_noise(rng, 3.5), flat(398.0))
        return dict(kind="gpx", creator="Garmin eTrex 32x", pts=pts, decimals=8,
                    desc="Train into a dead-end terminus (Lindau-type), Garmin 1 Hz, %.0f min: brakes to a stop at t=%d, waits 3 min, "
                         "departs back along the same track (heading flips 180 deg) and branches off at the junction. Reversal "
                         "happens at 0 speed after the 60-s heading window has gone stale, never as a >= 200 m backward step." % (
                             (times[-1] - times[0]) / 60, tt),
                    profile="deviceLogger", trips=True, jitter_free=[[tt - 120, tt + 400]])
    times = times_steps(rng, k.ta[0], k.t_end, [1, 2, 3], [0.55, 0.35, 0.1])
    pts = sample(k, times, 50.10700, 8.66300, phone_noise(rng), flat(100.0))
    return dict(kind="csv", pts=pts, background=False,
                desc="Train into a terminus station (Frankfurt Hbf-type), phone CSV 1-3 s, %.0f min: stops at t=%d, 3 min dwell, "
                     "departs the same way back (180 deg heading flip), phone noise + outliers." % ((times[-1] - times[0]) / 60, tt),
                profile="phone", trips=True, jitter_free=[[tt - 120, tt + 400]])


def sc_cold_start():
    rng = random.Random(115)
    r1 = Route(heading=60, step=2.0, rng=rng, var=0.05)
    r1.straight(1200, 14).arc(12, 90, 5).straight(2500, 22).arc(400, -30, 20).straight(3500, 25).arc(12, -90, 5).straight(600, 12)
    k1 = Kin(r1, acc=1.5, dec=2.0, t0=T_BASE + 86400 * 36 + 3600 * 8, start_dwell=20)
    t1 = times_1hz(k1.ta[0], k1.t_end)
    lat0, lon0 = 48.78340, 9.18070
    p1 = sample(k1, t1, lat0, lon0, device_noise(rng, 3.2), flat(250.0))
    # device switched off for 5 h, carried ~100 km (e.g. on a coach), first fix after the cold start is accurate
    gap = 5 * 3600
    lat2, lon2 = xy_to_ll(lat0, lon0, 72000.0, -68000.0)
    r2 = Route(heading=200, step=2.0, rng=rng, var=0.05)
    r2.straight(500, 10).arc(12, 90, 5).straight(3000, 22).arc(600, 25, 20).straight(4000, 25).arc(15, -90, 5).straight(800, 12)
    k2 = Kin(r2, acc=1.5, dec=2.0, t0=t1[-1] + gap, start_dwell=5)
    t2 = times_1hz(k2.ta[0], k2.t_end)
    p2 = sample(k2, t2, lat2, lon2, device_noise(rng, 3.0), flat(480.0))
    jump = hav(p1[-1]["lat"], p1[-1]["lon"], p2[0]["lat"], p2[0]["lon"])
    return dict(kind="gpx", creator="Garmin DriveSmart 66", pts=p1 + p2, decimals=8,
                desc="Two drives (Garmin 1 Hz) separated by a 5-h power-off: last fix at t=%d, first (accurate) fix after the cold "
                     "start %.1f km away at t=%d. Implied 5-h speed %.1f km/h is inside 15-350, so only the dt <= 3600 s limit keeps "
                     "it from being a timeGap. Two trips (blank >= 10 min)." % (p1[-1]["t"], jump / 1000, p2[0]["t"], jump / gap * 3.6),
                profile="deviceLogger", trips=True)


def sc_dropouts():
    rng = random.Random(116)
    r = Route(heading=110, step=2.0, rng=rng, var=0.05)
    r.straight(800, 14).straight(3500, 27).arc(500, 25, 24).straight(2500, 27).arc(15, -90, 6).straight(1800, 22)
    r.stop(40).straight(1200, 14).straight(5200, 27.5).arc(700, -30, 25).straight(4200, 27).arc(300, 40, 19)
    r.straight(3800, 26).arc(15, 90, 6).straight(2000, 22).straight(800, 13)
    k = Kin(r, acc=1.5, dec=2.0, t0=T_BASE + 86400 * 38 + 3600 * 14, start_dwell=15)
    full = times_1hz(k.ta[0], k.t_end)
    # 1-s dropouts: drop runs of 1-4 consecutive fixes (dt 2-5 s), clustered (forest / bridges), ~ every 30 s on average
    keep = []
    i = 0
    nd = 0
    while i < len(full):
        keep.append(full[i])
        if 10 < i < len(full) - 10 and rng.random() < 0.035:
            i += 1 + rng.randint(1, 4)
            nd += 1
        else:
            i += 1
    pts = sample(k, keep, 47.99000, 7.85000, device_noise(rng, 3.8), lambda s, t: 280 + 15 * math.sin(s / 2500))
    return dict(kind="gpx", creator="Garmin Montana 700", pts=pts, decimals=8,
                desc="Country-road drive, Garmin 1 Hz, %.0f min at up to 100 km/h with %d dropouts of 1-4 missing fixes (dt 2-5 s, up "
                     "to ~140 m per step). dt < 20 s and implied speed < 350 km/h, so neither timeGap nor staleClock may fire; no "
                     "jitter." % ((keep[-1] - keep[0]) / 60, nd),
                profile="deviceLogger", trips=True)


SCENARIOS = [
    ("walk_loop_pauses.gpx", sc_walk_loop),
    ("hike_switchbacks.gpx", sc_hike_switchbacks),
    ("cycle_uturn_roundabout.gpx", sc_cycle),
    ("car_city_1hz_uturns.gpx", sc_car_city),
    ("highway_cloverleaf.gpx", sc_highway),
    ("car_phone_3s.csv", sc_car_phone),
    ("bus_phone.csv", sc_bus),
    ("train_regional_1hz.gpx", sc_train_regional),
    ("hsr_garmin_bunching.gpx", sc_hsr_bunching),
    ("aircraft_holding.gpx", sc_aircraft),
    ("boat_ferry_phone.gpx", sc_boat),
    ("phone_sparse_mountain.csv", sc_phone_sparse_mountain),
    ("train_reverse_deadend.gpx", lambda: sc_train_reverse(True)),
    ("train_reverse_deadend_phone.csv", lambda: sc_train_reverse(False)),
    ("cold_start_5h.gpx", sc_cold_start),
    ("car_dropouts_1hz.gpx", sc_dropouts),
]


def verify_file(fname, kind, npts):
    if kind == "gpx":
        root = ET.parse(fname).getroot()
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        trkpts = root.findall(".//g:trkpt", ns)
        assert len(trkpts) == npts, (fname, len(trkpts), npts)
        for tp in trkpts[:5]:
            float(tp.get("lat")), float(tp.get("lon"))
            datetime.strptime(tp.find("g:time", ns).text, "%Y-%m-%dT%H:%M:%SZ")
    else:
        with open(fname, newline="", encoding="utf-8") as fh:
            rows = list(csv.reader(fh))
        assert ",".join(rows[0]) == CSV_HEADER
        assert len(rows) - 1 == npts, (fname, len(rows) - 1, npts)
        for row in rows[1:]:
            assert len(row) == 11
            int(row[0]), float(row[2]), float(row[3]), float(row[5])


def main():
    expect = {"family": "legit-motion",
              "about": "Clean, artefact-free recordings of legitimate motion (U-turns, hairpins, roundabouts, cloverleaf, holding "
                       "circles, dead-end reversals, Garmin timestamp bunching, sparse phone sampling, 1-s dropouts, cold start). "
                       "Replays and jitter must be 0 everywhere; gaps are 0 except for the sparse phone file.",
              "files": {}}
    for fname, fn in SCENARIOS:
        sc = fn()
        pts = sc["pts"]
        if sc["kind"] == "gpx":
            write_gpx(fname, sc["creator"], os.path.splitext(fname)[0], pts, decimals=sc["decimals"])
            dec = sc["decimals"]
        else:
            write_csv(fname, random.Random(sum(map(ord, fname))), pts, background=sc["background"])
            dec = 8
        verify_file(fname, sc["kind"], len(pts))
        q = round_like_file(pts, dec)
        q.sort(key=lambda p: p["t"])                       # stable, like the loader
        gaps, border = timegap_count(q)
        nrep = replay_port(q)
        assert nrep == 0, (fname, nrep)
        st_entries = stale_entries(q)
        jumps = sorted(set(int(b["t"] - a["t"]) for a, b in zip(q, q[1:])))
        moving_dup = 0
        seen = {}
        for p in q:
            key = (p["lat"], p["lon"])
            if key in seen and p["moving"]:
                moving_dup += 1
            seen[key] = True
        assert moving_dup == 0, (fname, moving_dup)
        e = {"desc": sc["desc"], "points": len(pts), "profile": sc["profile"],
             "gaps": [max(0, gaps - border), gaps + border], "replays": [0, 0], "jitter": [0, 0], "load_ok": True,
             "max_load_seconds": 5}
        if sc.get("jitter_free"):
            e["jitter_free"] = sc["jitter_free"]
        if sc.get("trips"):
            nt = trips_port(q)
            e["trips"] = [nt, nt]
        info = "port: timeGap %d (borderline %d), staleClock-branch entries %d, dt values %s" % (
            gaps, border, st_entries, jumps if len(jumps) <= 12 else (jumps[:6] + ["..."] + jumps[-3:]))
        if not sc.get("trips"):
            info += ", trips (port, not asserted) %d" % trips_port(q)
        e["desc"] += " [" + info + "]"
        expect["files"][fname] = e
        print("%-34s %6d pts  gaps %d (+-%d)  staleEntries %d  trips %s  span %.0f min" % (
            fname, len(pts), gaps, border, st_entries, e.get("trips", "-"), (q[-1]["t"] - q[0]["t"]) / 60))
    with open("expect.json", "w", encoding="utf-8") as fh:
        json.dump(expect, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
