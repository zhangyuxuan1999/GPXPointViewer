#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""format-edge: small files that stress the GPXPointViewer loader and must never crash the detectors.

Run with this directory as cwd:   python3 -I gen.py
stdlib only, deterministic (SEED).  Writes every data file plus expect.json, then
re-reads each file (ElementTree / csv module) and prints a summary table.

How expectations are derived
----------------------------
Every generated file also yields a "view": the points a correct loader should keep
(lat, lon, unix time or None), in file order.  From the view this script computes,
with straight Python ports of the Swift code in GPXPointViewer/GapFill.swift and
TrackData.swift:
  * the load-time time sort (stable; NaN last; only when out of order / timed after untimed),
  * timeGap count (dt >= 20 s, d >= 150 m, 15-350 km/h, dt <= 3600 s) and the number of
    "stale triggers" (single steps >= 150 m faster than 350 km/h; staleClock can only start
    at one of those and only for the deviceLogger profile),
  * replayFlags, SamplingProfile.compute (+ CSV accuracy median), TripSegmenter.trips.
Jitter is not ported: every track here is smooth (GPS noise only, no jumps >= 300 m and
no backward steps >= 200 m), so the truth is 0 jitter clusters, except the chaos CSV.
Ranges are widened (and the reason is written into "desc") where the parser's behaviour
on an odd-but-valid input is a judgement call (commented-out trkpt, single-quoted XML
attributes, truncated last point, rows without a parsable time).
"""
import csv
import datetime
import io
import json
import math
import os
import random
import struct
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

SEED = 20261023
R = 6371000.0
INF = float("inf")
EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
T0 = 1716019200          # 2024-05-18T08:00:00Z

FILES = {}               # name -> expect entry
WELLFORMED = {}          # name -> True (must parse as XML / CSV) | False (deliberately broken)
WARN = []


# ----------------------------------------------------------------------------- geo

def rad(x):
    return x * math.pi / 180.0


def deg(x):
    return x * 180.0 / math.pi


def norm_lon(lon):
    lon = (lon + 180.0) % 360.0 - 180.0
    return lon


def hav(lat1, lon1, lat2, lon2):
    """GeoMath.haversine, same formula and radius."""
    p1, p2 = rad(lat1), rad(lat2)
    dp, dl = rad(lat2 - lat1), rad(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(h)))


def bearing(lat1, lon1, lat2, lon2):
    p1, p2 = rad(lat1), rad(lat2)
    dl = rad(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    b = deg(math.atan2(y, x))
    return b + 360 if b < 0 else b


def dest(lat, lon, brg, d):
    """Great-circle destination (works across the dateline and next to the pole)."""
    p1, l1, th, dl = rad(lat), rad(lon), rad(brg), d / R
    sp2 = math.sin(p1) * math.cos(dl) + math.cos(p1) * math.sin(dl) * math.cos(th)
    sp2 = max(-1.0, min(1.0, sp2))
    p2 = math.asin(sp2)
    l2 = l1 + math.atan2(math.sin(th) * math.sin(dl) * math.cos(p1), math.cos(dl) - math.sin(p1) * sp2)
    return deg(p2), norm_lon(deg(l2))


def offset(lat, lon, dx, dy):
    r = math.hypot(dx, dy)
    if r == 0:
        return lat, lon
    return dest(lat, lon, deg(math.atan2(dx, dy)), r)


def wrap180(a):
    return (a + 180.0) % 360.0 - 180.0


# ----------------------------------------------------------------------------- motion + noise

class Mover:
    """Piecewise-steady heading around a base direction (street-like), speed OU process."""
    MODES = {
        "walk":  dict(v=1.4, vsd=0.10, vmin=0.9, vmax=1.9, turn=15.0, wig=1.2, seg=(40, 150), off=55.0),
        "cycle": dict(v=6.0, vsd=0.35, vmin=3.5, vmax=9.0, turn=10.0, wig=0.5, seg=(30, 120), off=50.0),
        "car":   dict(v=20.0, vsd=1.0, vmin=9.0, vmax=33.0, turn=6.0, wig=0.2, seg=(40, 150), off=45.0),
        "ferry": dict(v=9.0, vsd=0.08, vmin=8.0, vmax=10.0, turn=1.0, wig=0.05, seg=(300, 900), off=8.0),
        "ship":  dict(v=8.0, vsd=0.08, vmin=7.0, vmax=9.0, turn=1.0, wig=0.05, seg=(300, 900), off=5.0),
    }

    def __init__(self, rng, mode, lat, lon, base):
        self.rng, self.p = rng, self.MODES[mode]
        self.lat, self.lon, self.base = lat, lon, base
        self.h = self.target = base
        self.v = self.p["v"]
        self.tick = 0
        self.next_change = rng.uniform(*self.p["seg"])

    def step(self):
        p, rng = self.p, self.rng
        self.tick += 1
        if self.tick >= self.next_change:
            self.target = self.base + rng.uniform(-p["off"], p["off"])
            self.next_change = self.tick + rng.uniform(*p["seg"])
        diff = wrap180(self.target - self.h)
        self.h += max(-p["turn"], min(p["turn"], diff)) + rng.gauss(0, p["wig"])
        vt = p["v"] * (1 - 0.5 * min(1.0, abs(diff) / 90.0))
        self.v += 0.15 * (vt - self.v) + rng.gauss(0, p["vsd"])
        self.v = max(p["vmin"], min(p["vmax"], self.v))
        self.lat, self.lon = dest(self.lat, self.lon, self.h, self.v)


def simulate(rng, mode, lat, lon, base, seconds):
    """True positions at every whole second 0..seconds."""
    m = Mover(rng, mode, lat, lon, base)
    out = [(lat, lon)]
    for _ in range(seconds):
        m.step()
        out.append((m.lat, m.lon))
    return out


def elevation(rng, n, e0, amp=15.0):
    out, e = [], 0.0
    ph = rng.uniform(0, 6.28)
    for k in range(n):
        e = 0.9 * e + rng.gauss(0, 0.15)
        out.append(e0 + amp * math.sin(k / 400.0 + ph) + 0.3 * amp * math.sin(k / 97.0) + e)
    return out


class ARNoise:
    """Slowly varying GPS position error (metres east / north), AR(1) per second."""

    def __init__(self, rng, sigma, rho1):
        self.rng, self.sigma, self.rho1 = rng, sigma, rho1
        self.x, self.y = rng.gauss(0, sigma), rng.gauss(0, sigma)

    def next(self, dt=1.0):
        rho = self.rho1 ** max(dt, 0.0)
        s = self.sigma * math.sqrt(max(0.0, 1 - rho * rho))
        self.x = rho * self.x + self.rng.gauss(0, s)
        self.y = rho * self.y + self.rng.gauss(0, s)
        return self.x, self.y


def device_points(rng, true, ele, t0, sigma=4.0, rho1=0.98, every=1):
    """1 Hz (or every N s) dedicated-logger fixes: list of dicts lat/lon/ele/t (true t, integer)."""
    nz = ARNoise(rng, sigma, rho1)
    pts = []
    for k in range(0, len(true), every):
        dx, dy = nz.next(every)
        la, lo = offset(true[k][0], true[k][1], dx, dy)
        pts.append({"lat": la, "lon": lo, "ele": ele[k] if ele else None, "t": t0 + k})
    return pts


def phone_times(rng, seconds, fg_dts=(2, 3, 3, 3, 4, 5), bg=(20, 30)):
    """一生足迹-like sampling: foreground ~3 s, background 20-30 s, alternating stretches."""
    ts, t, fg = [0], 0, True
    end = rng.uniform(120, 300)
    while True:
        if t >= end:
            fg = not fg
            end = t + (rng.uniform(120, 300) if fg else rng.uniform(180, 420))
        t += rng.choice(fg_dts) if fg else rng.randint(*bg)
        if t > seconds:
            return ts
        ts.append(t)


def phone_points(rng, true, ele, t0, times, sigma=10.0, rho1=0.92, p_out=0.02):
    nz = ARNoise(rng, sigma, rho1)
    pts, prev = [], None
    for t in times:
        dt = 1 if prev is None else t - prev
        fg = dt < 15
        dx, dy = nz.next(dt)
        acc_true = min(65.0, max(5.0, rng.lognormvariate(math.log(14), 0.45)))
        if fg and rng.random() < p_out:                  # 50 m+ tail
            a = rng.uniform(0, 2 * math.pi)
            r = rng.uniform(40, 85)
            dx += r * math.sin(a)
            dy += r * math.cos(a)
            acc_true = rng.uniform(35, 65)
        la, lo = offset(true[t][0], true[t][1], dx, dy)
        acc = 0 if rng.random() < 0.5 else round(acc_true)
        if prev is None:
            hd, sp = -1.0, -1.0
        else:
            hd = bearing(true[prev][0], true[prev][1], true[t][0], true[t][1])
            sp = hav(true[prev][0], true[prev][1], true[t][0], true[t][1]) / dt
        pts.append({"lat": la, "lon": lo, "ele": ele[t], "t": t0 + t, "acc": acc, "fg": fg,
                    "hd": hd, "sp": sp})
        prev = t
    return pts


# ----------------------------------------------------------------------------- formatting

def iso(t, ms=False, off_min=0, z=True):
    tm = int(round(t * 1000))
    if not ms and tm % 1000:
        raise ValueError("non-integer time without ms")
    sec, msec = divmod(tm, 1000)
    loc = EPOCH + datetime.timedelta(seconds=sec + off_min * 60)
    s = "%04d-%02d-%02dT%02d:%02d:%02d" % (loc.year, loc.month, loc.day, loc.hour, loc.minute, loc.second)
    if ms:
        s += ".%03d" % msec
    if off_min == 0 and z:
        s += "Z"
    else:
        a = abs(off_min)
        s += "%s%02d:%02d" % ("+" if off_min >= 0 else "-", a // 60, a % 60)
    return s


def swift_iso_value(y, mo, d, h, mi, s, frac=0.0, tz_sec=0):
    """GPXParser.parseISO8601 arithmetic (Howard Hinnant days-from-civil, no range checks)."""
    yy = y - 1 if mo <= 2 else y
    era = (yy if yy >= 0 else yy - 399) // 400
    yoe = yy - era * 400
    doy = (153 * (mo + (-3 if mo > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    days = era * 146097 + doe - 719468
    return days * 86400.0 + (h * 3600 + mi * 60 + s) + frac - tz_sec


def f7(x):
    return "%.7f" % x


def f6(x):
    return "%.6f" % x


def r7(x):
    return float(f7(x))


def r6(x):
    return float(f6(x))


GPX11_NS = ('xmlns="http://www.topografix.com/GPX/1/1" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
            'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"')


def gpx_open(creator, ns=GPX11_NS, version="1.1", decl=True):
    s = '<?xml version="1.0" encoding="UTF-8"?>\n' if decl else ""
    return s + "<gpx version=%s creator=%s %s>\n" % (quoteattr(version), quoteattr(creator), ns)


def pt_xml(tag, lat, lon, ele=None, tstr=None, ind="      ", extra="", attr_order="latlon"):
    a = ('lat="%s" lon="%s"' % (f7(lat), f7(lon))) if attr_order == "latlon" else ('lon="%s" lat="%s"' % (f7(lon), f7(lat)))
    s = "%s<%s %s>\n" % (ind, tag, a)
    if ele is not None:
        s += "%s  <ele>%.1f</ele>\n" % (ind, ele)
    if tstr is not None:
        s += "%s  <time>%s</time>\n" % (ind, tstr)
    s += extra
    s += "%s</%s>\n" % (ind, tag)
    return s


def trk_xml(pts, name=None, ms=False, ind="    "):
    s = "  <trk>\n"
    if name:
        s += "    <name>%s</name>\n" % name
    s += "    <trkseg>\n"
    for p in pts:
        s += pt_xml("trkpt", p["lat"], p["lon"], p.get("ele"), iso(p["t"], ms=ms) if p.get("t") is not None else None)
    s += "    </trkseg>\n  </trk>\n"
    return s


def view_of(pts, rnd=r7):
    return [(rnd(p["lat"]), rnd(p["lon"]), p["t"]) for p in pts]


# ----------------------------------------------------------------------------- Swift ports (analysis)

def sort_view(view):
    timed, need, seen_nan, prev = 0, False, False, -INF
    for (_, _, t) in view:
        if t is not None:
            timed += 1
            if seen_nan or t < prev:
                need = True
            prev = t
        else:
            seen_nan = True
    ties = False
    if timed and need:
        ts = [p[2] for p in view if p[2] is not None]
        ties = len(set(ts)) != len(ts)
        view = sorted(view, key=lambda p: p[2] if p[2] is not None else INF)
    return view, timed, ties


def timegap_port(v, timed):
    tg, stale_trig, border = 0, 0, 0
    for i in range(1, timed):
        dt = v[i][2] - v[i - 1][2]
        d = hav(v[i - 1][0], v[i - 1][1], v[i][0], v[i][1])
        if 135 <= d <= 165 and dt >= 18:
            border += 1
        if d >= 150:
            kmh = d / dt * 3.6 if dt > 0 else INF
            if dt >= 20:
                if dt <= 3600 and 15 <= kmh <= 350:
                    tg += 1
                if 13 <= kmh <= 17 or 330 <= kmh <= 370 or 3500 <= dt <= 3700:
                    border += 1
            elif kmh > 350:
                stale_trig += 1
    return tg, stale_trig, border


def profile_port(v, timed, creator, accuracy):
    dts, ds = [], []
    n = timed
    if n >= 2:
        stride = max(1, (n - 1) // 100000)
        i = 1
        while i < n:
            dt = v[i][2] - v[i - 1][2]
            if dt > 0:
                d = hav(v[i - 1][0], v[i - 1][1], v[i][0], v[i][1])
                if d / dt > 1:
                    dts.append(dt)
                    ds.append(d)
            i += stride
    dts.sort()
    ds.sort()

    def q(a, p, fb):
        return fb if not a else a[min(len(a) - 1, int(len(a) * p))]
    mdt = q(dts, 0.5, 1)
    q90dt = q(dts, 0.9, mdt)
    mst = q(ds, 0.5, 30)
    q90st = q(ds, 0.9, mst)
    lc = creator.lower()
    dev = any(k in lc for k in ("garmin", "etrex", "wahoo", "suunto"))
    phone = any(k in lc for k in ("stepofmyworld", "一生足迹", "fog", "iphone", "android"))
    steady = bool(dts) and mdt <= 2 and q90dt <= 2 * mdt + 1 and q90st <= 3 * mst
    # margin: does the answer hinge on `steady`, and is any of its three tests close to flipping?
    depends = (dev and accuracy is not None) or (not dev and accuracy is None and not phone and bool(dts))
    margin = True
    if depends:
        ratio = q90st / mst if mst > 0 else INF
        near = [1.5 <= mdt <= 2.5, mdt <= 2.5 and 2 * mdt <= q90dt <= 2 * mdt + 3, mdt <= 2.5 and 2.4 <= ratio <= 3.6]
        if any(near):
            margin = False
    if dev and accuracy is None:
        kind = "deviceLogger"
    elif dev:
        kind = "deviceLogger" if steady else "phone"
    elif accuracy is not None or phone:
        kind = "phone"
    elif steady:
        kind = "deviceLogger"
    else:
        kind = "unknown" if not dts else "phone"
    return kind, margin, dict(mdt=mdt, q90dt=q90dt, mst=round(mst, 1), q90st=round(q90st, 1), n=len(dts))


def replay_port(v, timed):
    n = timed
    flags = [False] * n
    if n < 3:
        return 0
    key = lambda i: (struct.pack("<d", v[i][0]), struct.pack("<d", v[i][1]))
    last, order, head = {}, [], 0
    for i in range(n):
        while head < len(order) and v[i][2] - v[order[head]][2] > 1800:
            k = order[head]
            if last.get(key(k)) == k:
                del last[key(k)]
            head += 1
        kk = key(i)
        if kk in last:
            j = last[kk]
            if v[i][2] - v[j][2] < 10:
                continue
            k, steps = i - 1, 0
            while k > 0 and (flags[k] or v[i][2] - v[k][2] < 10) and steps < 256:
                k -= 1
                steps += 1
            if k >= 0 and hav(v[k][0], v[k][1], v[i][0], v[i][1]) >= 50:
                stride = max(1, (i - j) // 60)
                m, away = j + 1, False
                while m < i:
                    if hav(v[i][0], v[i][1], v[m][0], v[m][1]) >= 300:
                        away = True
                        break
                    m += stride
                if away:
                    flags[i] = True
        if not flags[i]:
            last[kk] = i
            order.append(i)
    return sum(flags)


def trips_port(v, timed):
    n = timed
    if n < 2:
        return 0
    bounds, i = [0], 0
    while i < n - 1:
        j = i
        while j + 1 < n and hav(v[i][0], v[i][1], v[j + 1][0], v[j + 1][1]) <= 150:
            j += 1
        stayed = v[j][2] - v[i][2] >= 600
        blank = j + 1 < n and v[j + 1][2] - v[j][2] >= 600
        if stayed or blank:
            if j + 1 < n and bounds[-1] != j + 1:
                bounds.append(j + 1)
            i = j + 1
        else:
            k = i + 1
            while k < n - 1 and v[k][2] - v[i][2] < 30:
                k += 1
            i = k
    bounds.append(n)
    return sum(1 for a, b in zip(bounds, bounds[1:]) if b - a >= 2)


def csv_acc_median(accs):
    vals = sorted(a for a in accs if 0 < a < 1000)
    return vals[len(vals) // 2] if len(vals) >= 20 else None


def expect(name, desc, view, creator="", accuracy=None, *, profile=None, points=None, timed=None,
           jitter=(0, 0), trips=None, extra=None, segments=None):
    v, n_timed, ties = sort_view(view)
    tg, stale_trig, border = timegap_port(v, n_timed)
    kind, margin, pdet = profile_port(v, n_timed, creator, accuracy)
    rep = replay_port(v, n_timed)
    ntrips = trips_port(v, n_timed)
    if segments is not None:
        tg = stale_trig = border = rep = ntrips = 0
        for source in segments:
            sv, sn, _ = sort_view(source)
            a, b, c = timegap_port(sv, sn)
            tg += a; stale_trig += b; border += c
            rep += replay_port(sv, sn)
            ntrips += trips_port(sv, sn)
    gaps = [tg, tg]
    if kind == "deviceLogger" and stale_trig:
        gaps = [tg, tg + stale_trig]
        WARN.append("%s: %d stale triggers on a deviceLogger track; gaps widened" % (name, stale_trig))
    if border:
        gaps = [max(0, gaps[0] - border), gaps[1] + border]
        WARN.append("%s: %d borderline timeGap steps; gaps widened" % (name, border))
    if ties:
        WARN.append("%s: equal timestamps in a file that needs sorting (vDSP sort is not stable)" % name)
    if profile is None:
        profile = kind if margin else "any"
    elif profile != "any" and profile != kind:
        WARN.append("%s: profile given as %s but port says %s %s" % (name, profile, kind, pdet))
    e = {"desc": desc,
         "points": points if points is not None else len(view),
         "profile": profile,
         "gaps": gaps,
         "replays": [rep, rep],
         "jitter": list(jitter),
         "load_ok": True,
         "timed": timed if timed is not None else [n_timed, n_timed]}
    if trips is not None:
        e["trips"] = trips
        if not (trips[0] <= ntrips <= trips[1]):
            WARN.append("%s: trips expected %s but port says %d" % (name, trips, ntrips))
    if extra:
        e.update(extra)
    e["_port"] = {"profile": kind, "profile_detail": pdet, "timegap": tg, "stale_triggers": stale_trig,
                  "replays": rep, "trips": ntrips, "timed": n_timed}
    return e


def rejected(desc, points=(0, None)):
    return {"desc": desc, "points": list(points), "profile": "any", "gaps": [0, None], "replays": [0, None],
            "jitter": [0, None], "load_ok": False}


def put(name, data, exp, wellformed=True):
    with open(name, "wb") as fh:
        fh.write(data if isinstance(data, bytes) else data.encode("utf-8"))
    FILES[name] = exp
    WELLFORMED[name] = wellformed


# ============================================================================= GPX files

def g01_empty_0byte():
    put("g01_empty_0byte.gpx", b"",
        rejected("0-byte file: GPXParser.parse throws .empty (n <= 8). Must not crash."), wellformed=False)


def g02_tiny():
    put("g02_tiny_8byte.gpx", b"<gpx/>\r\n",
        rejected("8-byte '<gpx/>' + CRLF: exactly at the n > 8 guard -> .empty. Must not crash."))


def g03_header_only():
    s = gpx_open("Garmin Connect")
    s += ("  <metadata>\n    <name>Planned but never recorded</name>\n"
          "    <time>2024-05-18T08:00:00Z</time>\n  </metadata>\n</gpx>\n")
    put("g03_header_only.gpx", s,
        rejected("Valid GPX with metadata (incl. a metadata <time>) but no trk/rte/wpt: parser throws .noPoints."))


def g04_no_trkpt():
    s = gpx_open("Garmin Edge 830")
    s += ("  <trk>\n    <name>Morning Ride</name>\n    <type>cycling</type>\n"
          "    <trkseg>\n    </trkseg>\n    <trkseg/>\n  </trk>\n</gpx>\n")
    put("g04_no_trkpt.gpx", s,
        rejected("trk with two empty trkseg (one self-closing), no trkpt: .noPoints expected."))


def g05_one_point(rng):
    p = {"lat": 47.3769123, "lon": 8.5416987, "ele": 408.2, "t": T0}
    s = gpx_open("eTrex 32x") + trk_xml([p], "Single fix") + "</gpx>\n"
    view = view_of([p])
    put("g05_one_point.gpx", s,
        expect("g05_one_point.gpx", "Single trkpt (eTrex creator -> deviceLogger by creator). timedCount 1: "
               "detect/replay/jitter guards (n<2, n<3, n<8) must return empty; trips 0.",
               view, "eTrex 32x", trips=[0, 0]))


def g06_two_points(rng):
    a = {"lat": 51.0504, "lon": 13.7373, "ele": 112.0, "t": T0}
    la, lo = dest(a["lat"], a["lon"], 62.0, 600.0)
    b = {"lat": la, "lon": lo, "ele": 115.0, "t": T0 + 30}
    s = gpx_open("GPXSynth 1.0") + trk_xml([a, b], "Two fixes, 30 s logger interval") + "</gpx>\n"
    put("g06_two_points.gpx", s,
        expect("g06_two_points.gpx", "Two fixes 30 s / ~600 m apart (72 km/h): the minimal timeGap -> exactly 1 "
               "gap. Profile from 1 step is meaningless (any).",
               view_of([a, b]), "GPXSynth 1.0", profile="any", trips=[1, 1]))


def g07_no_time(rng):
    true = simulate(rng, "walk", 48.8566, 2.3522, 75, 239)
    ele = elevation(rng, len(true), 35)
    pts = device_points(rng, true, ele, T0)
    for p in pts:
        p["t"] = None
    s = gpx_open("OsmAnd~ 4.7.6") + trk_xml(pts, "Untimed walk") + "</gpx>\n"
    put("g07_no_time.gpx", s,
        expect("g07_no_time.gpx", "240 trkpt with ele but no <time>: timedCount 0, all detectors return empty. "
               "Creator matches no rule and there are no timed steps -> unknown.",
               view_of(pts), "OsmAnd~ 4.7.6", trips=[0, 0]))


def g08_half_time(rng):
    true = simulate(rng, "cycle", 48.137, 11.575, 120, 299)
    ele = elevation(rng, len(true), 520)
    pts = device_points(rng, true, ele, T0 + 3600)
    for k, p in enumerate(pts):
        if k % 2 == 1:
            p["t"] = None
    s = gpx_open("GPSLogger for Android") + trk_xml(pts, "Every other point untimed") + "</gpx>\n"
    put("g08_half_time.gpx", s,
        expect("g08_half_time.gpx", "300 trkpt, odd ones without <time> (interleaved): load must stable-sort the 150 "
               "timed points first (2 s steps, cycling). Creator contains 'android' -> phone.",
               view_of(pts), "GPSLogger for Android", trips=[1, 1]))


def g09_out_of_order(rng):
    true = simulate(rng, "car", 45.7640, 4.8357, 30, 599)
    ele = elevation(rng, len(true), 180, 8)
    pts = device_points(rng, true, ele, T0 + 7200)
    blocks = [pts[i:i + 50] for i in range(0, len(pts), 50)]
    blocks[3] = blocks[3][::-1]
    order = list(range(len(blocks)))
    rng.shuffle(order)
    shuffled = [p for b in order for p in blocks[b]]
    s = gpx_open("eTrex 32x") + "  <trk>\n    <name>Backup merge, scrambled</name>\n    <trkseg>\n"
    for p in shuffled:
        s += pt_xml("trkpt", p["lat"], p["lon"], p["ele"], iso(p["t"]))
    s += "    </trkseg>\n  </trk>\n</gpx>\n"
    put("g09_out_of_order.gpx", s,
        expect("g09_out_of_order.gpx", "600 s car drive at 1 Hz written as 12 shuffled 50-point blocks (one block "
               "reversed). After the load-time sort it is one clean drive: 0 gaps/jitter; any missed sort "
               "would show up as 5-30 km jumps. Times are unique, so the unstable vDSP sort is irrelevant.",
               view_of(shuffled), "eTrex 32x", trips=[1, 1]))


def g10_dup_timestamps(rng):
    true = simulate(rng, "walk", 48.2082, 16.3738, 200, 399)
    ele = elevation(rng, len(true), 180, 4)
    pts = device_points(rng, true, ele, T0)
    stuck = pts[150]["t"]
    for k in range(150, 200):
        pts[k]["t"] = stuck
    s = gpx_open("GPXSynth Logger") + trk_xml(pts, "Clock stuck for 50 fixes") + "</gpx>\n"
    put("g10_dup_timestamps_50.gpx", s,
        expect("g10_dup_timestamps_50.gpx", "Walk at 1 Hz; fixes 150-199 all carry the same timestamp while the "
               "position keeps advancing (70 m), then the clock resumes (+50 s). dt=0 steps (infinite speed) must "
               "not crash speed/profile code; per-second jitter sample = median of 50 points, ~35 m steps: no "
               "jump, no gap (steps < 150 m).",
               view_of(pts), "GPXSynth Logger", trips=[1, 1]))


def g11_dup_points(rng):
    true = simulate(rng, "cycle", 52.3676, 4.9041, 160, 299)
    ele = elevation(rng, len(true), 2, 1)
    pts = device_points(rng, true, ele, T0 + 600)
    out = []
    for k, p in enumerate(pts):
        out.append(p)
        out.append(dict(p))
        if k % 15 == 7:
            out.append(dict(p))
    s = gpx_open("StravaGPX Android") + trk_xml(out, "Merged twice") + "</gpx>\n"
    put("g11_dup_points.gpx", s,
        expect("g11_dup_points.gpx", "300 cycling fixes, each written twice (every 15th three times) with identical "
               "lat/lon/time - a double import. dt=0 duplicates are not replays (replay needs >= 10 s), no gaps, "
               "no jitter. Creator 'android' -> phone.",
               view_of(out), "StravaGPX Android", trips=[1, 1]))


def g12_missing_ele(rng):
    true = simulate(rng, "cycle", 55.676, 12.568, 300, 499)
    pts = device_points(rng, true, None, T0 + 1800)
    s = gpx_open("Wahoo ELEMNT BOLT") + trk_xml(pts, "No elevation") + "</gpx>\n"
    put("g12_missing_ele.gpx", s,
        expect("g12_missing_ele.gpx", "500 s cycling at 1 Hz with no <ele> at all (ele = NaN everywhere). "
               "Wahoo creator -> deviceLogger. Clean track: 0 gaps / replays / jitter.",
               view_of(pts), "Wahoo ELEMNT BOLT", trips=[1, 1]))


def g13_multi_trk_seg(rng):
    day1 = 1717232400       # 2024-06-01T09:00:00Z
    day2 = 1717336800       # 2024-06-02T14:00:00Z
    # day 1: walk 600 s | 120 s unrecorded, 1.5 km on (45 km/h) | walk 600 s | 30 min break same spot | walk 600 s
    w1 = simulate(rng, "walk", 47.2692, 11.4041, 90, 600)
    p1 = device_points(rng, w1, elevation(rng, 601, 575, 3), day1)
    la, lo = dest(w1[-1][0], w1[-1][1], 35, 1500)
    w2 = simulate(rng, "walk", la, lo, 40, 600)
    p2 = device_points(rng, w2, elevation(rng, 601, 590, 3), day1 + 600 + 120)
    la3, lo3 = dest(w2[-1][0], w2[-1][1], 10, 4)
    w3 = simulate(rng, "walk", la3, lo3, 300, 600)
    p3 = device_points(rng, w3, elevation(rng, 601, 588, 3), day1 + 600 + 120 + 600 + 1800)
    # day 2: cycle 900 s | 2 h, 20 km later: cycle 600 s
    c1 = simulate(rng, "cycle", 47.30, 11.50, 70, 900)
    q1 = device_points(rng, c1, elevation(rng, 901, 560, 10), day2)
    la4, lo4 = dest(c1[-1][0], c1[-1][1], 80, 20000)
    c2 = simulate(rng, "cycle", la4, lo4, 120, 600)
    q2 = device_points(rng, c2, elevation(rng, 601, 610, 10), day2 + 900 + 7200)

    def seg(ps):
        return "    <trkseg>\n" + "".join(pt_xml("trkpt", p["lat"], p["lon"], p["ele"], iso(p["t"])) for p in ps) + "    </trkseg>\n"
    s = gpx_open("Garmin Connect")
    s += "  <trk>\n    <name>Day 2 ride</name>\n" + seg(q1) + seg(q2) + "  </trk>\n"
    s += "  <trk>\n    <name>Day 1 hike</name>\n" + seg(p1) + seg(p2) + seg(p3) + "  </trk>\n</gpx>\n"
    view = view_of(q1 + q2 + p1 + p2 + p3)
    put("g13_multi_trk_seg.gpx", s,
        expect("g13_multi_trk_seg.gpx", '[2026-10-29 调整] ' "Two <trk> in reverse chronological order (day 2 first), 2 + 3 <trkseg>. "
               "Each explicit source segment is a hard boundary, including the 120 s / ~1.5 km transition. "
               "All five source segments are internally continuous: 0 gaps and 5 trips."
               ' 调整理由：旧扁平期待gap1/trips4会跨源段连接；独立逐段旧算法与生成器真值确认五段各自连续，改为gap0/trips5。',
               view, "Garmin Connect", trips=[5, 5],
               segments=[view_of(q1), view_of(q2), view_of(p1), view_of(p2), view_of(p3)]))


def g14_waypoints_only(rng):
    s = gpx_open("Garmin BaseCamp")
    view = []
    times = [T0, T0 + 3 * 3600, T0 + 7 * 3600, T0 + 11 * 3600, T0 + 26 * 3600, T0 + 30 * 3600]
    names = ["Colosseo", "Café &amp; Bäckerei", "Fontana di Trevi", "Pantheon", "&lt;start&gt;",
             "Campo de' Fiori", "Trastevere", "Piazza Navona", "罗马大学", "Vaticano"]
    ti = 0
    for k in range(30):
        la, lo = offset(41.9028, 12.4964, rng.uniform(-3000, 3000), rng.uniform(-3000, 3000))
        t = None
        if k % 5 == 2 and ti < len(times):
            t = times[ti]
            ti += 1
        if k % 3 == 0 and t is None:
            s += '  <wpt lat="%s" lon="%s"/>\n' % (f7(la), f7(lo))
        else:
            s += '  <wpt lat="%s" lon="%s">\n' % (f7(la), f7(lo))
            s += "    <ele>%.1f</ele>\n" % rng.uniform(15, 60)
            if t is not None:
                s += "    <time>%s</time>\n" % iso(t)
            s += "    <name>%s</name>\n    <desc>POI %d, no track</desc>\n    <sym>Flag, Blue</sym>\n  </wpt>\n" % (names[k % len(names)], k)
        view.append((r7(la), r7(lo), t))
    s += "</gpx>\n"
    put("g14_waypoints_only.gpx", s,
        expect("g14_waypoints_only.gpx", "30 <wpt> POIs only (10 self-closing, entities and CJK in <name>), 6 with "
               "<time> 3-15 h apart: the parser keeps wpt as points; timed 6, spacing > 3600 s -> 0 gaps; "
               "jitter needs >= 8 timed points -> 0. Garmin creator -> deviceLogger.",
               view, "Garmin BaseCamp", trips=[0, 0]))


def g15_route_only(rng):
    true = simulate(rng, "cycle", 41.3874, 2.1686, 40, 1500)
    s = gpx_open("BRouter-1.7") + "  <rte>\n    <name>Planned loop</name>\n"
    view = []
    for k in range(0, 1500, 10):
        la, lo = true[k]
        s += '    <rtept lat="%s" lon="%s"><ele>%.0f</ele></rtept>\n' % (f7(la), f7(lo), 12 + 0.01 * k)
        view.append((r7(la), r7(lo), None))
    s += "  </rte>\n</gpx>\n"
    put("g15_route_only.gpx", s,
        expect("g15_route_only.gpx", "Route only: 150 <rtept> (no time, one line each). Parser keeps rtept as points; "
               "timed 0 -> nothing to detect; BRouter creator -> unknown.",
               view, "BRouter-1.7", trips=[0, 0]))


def g16_mixed(rng):
    true = simulate(rng, "cycle", 50.0755, 14.4378, 210, 399)
    ele = elevation(rng, len(true), 240, 6)
    pts = device_points(rng, true, ele, T0 + 5400)
    s = gpx_open("Garmin Desktop App")
    view = []
    for k in (0, 100, 200, 300, 399):
        la, lo = true[k]
        s += '  <wpt lat="%s" lon="%s">\n    <name>WP%d</name>\n  </wpt>\n' % (f7(la), f7(lo), k)
        view.append((r7(la), r7(lo), None))
    s += "  <rte>\n    <name>Course</name>\n"
    for k in range(0, 400, 10):
        la, lo = true[k]
        s += '    <rtept lat="%s" lon="%s"/>\n' % (f7(la), f7(lo))
        view.append((r7(la), r7(lo), None))
    s += "  </rte>\n" + trk_xml(pts, "Ride") + "</gpx>\n"
    view += view_of(pts)
    put("g16_mixed_wpt_rte_trk.gpx", s,
        expect("g16_mixed_wpt_rte_trk.gpx", "5 untimed <wpt> + 40 untimed self-closing <rtept> before a 400-point timed "
               "<trk>: timed points come after NaN times, so the load sort must move them to [0, 400). 445 points, "
               "400 timed, clean ride.",
               view, "Garmin Desktop App", trips=[1, 1]))


def g17_dateline(rng):
    true = simulate(rng, "ferry", -16.75, 179.875, 85, 2500)
    ele = [0.0] * len(true)
    pts = device_points(rng, true, ele, T0 + 20000, sigma=3.0)
    tc = None
    for k in range(1, len(pts)):
        if pts[k - 1]["lon"] > 0 > pts[k]["lon"]:
            tc = pts[k]["t"]
            break
    assert tc is not None
    s = gpx_open("Garmin GPSMAP 66sr") + trk_xml(pts, "Taveuni ferry across 180") + "</gpx>\n"
    put("g17_dateline.gpx", s,
        expect("g17_dateline.gpx", "Ferry at ~9 m/s, 1 Hz, lat -16.75, lon 179.875 -> -179.9: crosses the "
               "antimeridian at t=%d. Haversine steps are <= 12 m everywhere, so truth is 0 gaps and 0 jitter. "
               "jitter_free guards the crossing: detectJitter's planar frame uses an unwrapped lon2-lon1, which "
               "turns the 8 m crossing step into a ~38,000 km westward step (counted as a reversal); any jitter "
               "here is that bug." % tc,
               view_of(pts), "Garmin GPSMAP 66sr", trips=[1, 1],
               extra={"jitter_free": [[tc - 120, tc + 120]]}))


def g18_near_pole(rng):
    # snowmobile on a great circle from lat 89.9 through ~40 m off the North Pole to lat ~89.9 on the far side
    lat, lon = 89.9, 20.0
    h = deg(math.asin(math.sin(40.0 / R) / math.sin(hav(89.9, 20.0, 90.0, 0.0) / R)))
    true = [(lat, lon)]
    v = 8.0
    for _ in range(2780):
        v += 0.1 * (8.0 - v) + rng.gauss(0, 0.15)
        la2, lo2 = dest(lat, lon, h, v)
        h = (bearing(la2, lo2, lat, lon) + 180.0) % 360.0
        lat, lon = la2, lo2
        true.append((lat, lon))
    ele = elevation(rng, len(true), 2, 0.5)
    pts = device_points(rng, true, ele, T0 + 40000)
    closest = min(hav(p["lat"], p["lon"], 90.0, 0.0) for p in pts)
    tam = next(pts[k]["t"] for k in range(1, len(pts)) if pts[k - 1]["lon"] > 90 and pts[k]["lon"] < -90)
    s = gpx_open("Garmin fenix 7X") + trk_xml(pts, "Pole crossing") + "</gpx>\n"
    put("g18_near_pole.gpx", s,
        expect("g18_near_pole.gpx", "Snowmobile 8 m/s, 1 Hz, from lat 89.9 (lon 20) over the pole (closest fix "
               "%.0f m) to lat ~89.9 on lon -160: longitude sweeps 180 deg in ~1 min and passes the antimeridian "
               "~100 m from the pole at t=%d. Real steps are <= 12 m, so truth is 0 gaps / 0 jitter. Any jitter "
               "is a detector artefact (unwrapped lon2-lon1 in the planar lon*cos(lat) frame: the 8 m step "
               "179.75 -> -178.90 becomes dx = -680 m). Mercator clamp at 85.05 must not crash."
               % (closest, tam),
               view_of(pts), "Garmin fenix 7X", trips=[1, 1],
               extra={"jitter_free": [[tam - 120, tam + 120]]}))


def g19_southern(rng):
    true = simulate(rng, "car", -34.6037, -58.3816, 235, 900)
    ele = elevation(rng, len(true), 25, 3)
    pts = device_points(rng, true, ele, T0 + 50000)
    s = gpx_open("Garmin DriveSmart 66") + trk_xml(pts, "Buenos Aires drive") + "</gpx>\n"
    put("g19_southern_western.gpx", s,
        expect("g19_southern_western.gpx", "900 s car drive at 1 Hz in Buenos Aires: negative lat AND lon everywhere. "
               "Clean track: 0 gaps / replays / jitter.",
               view_of(pts), "Garmin DriveSmart 66", trips=[1, 1]))


def g20_equator(rng):
    true = simulate(rng, "ship", -0.03, -0.03, 45, 1150)
    ele = [0.0] * len(true)
    pts = device_points(rng, true, ele, T0 + 60000, sigma=3.0)
    k0 = min(range(len(pts)), key=lambda k: hav(pts[k]["lat"], pts[k]["lon"], 0.0, 0.0))
    d0 = hav(pts[k0]["lat"], pts[k0]["lon"], 0.0, 0.0)
    pts[k0]["lat"], pts[k0]["lon"] = 0.0, 0.0
    s = gpx_open("Garmin GPSMAP 86sci") + trk_xml(pts, "Gulf of Guinea, through Null Island") + "</gpx>\n"
    put("g20_equator_greenwich.gpx", s,
        expect("g20_equator_greenwich.gpx", "Ship at 8 m/s crossing the equator and the prime meridian; the fix "
               "nearest (0,0) (%.0f m off) is written as exactly lat=\"0.0000000\" lon=\"0.0000000\" - must stay a "
               "normal point (not treated as 'no fix'). 0 gaps / jitter." % d0,
               view_of(pts), "Garmin GPSMAP 86sci", trips=[1, 1]))


def g21_invalid_coords(rng):
    true = simulate(rng, "cycle", 52.52, 13.405, 100, 299)
    ele = elevation(rng, len(true), 35, 2)
    pts = device_points(rng, true, ele, T0 + 70000)
    bad = [
        'lat="95.0000000" lon="13.4050000"',
        'lat="52.5200000" lon="200.0000000"',
        'lat="-90.0000001" lon="13.4050000"',
        'lat="52.5200000" lon="-180.0000001"',
        'lat="NaN" lon="13.4050000"',
        'lat="52.5200000" lon="nan"',
        'lat="" lon="13.4050000"',
        'lat="52.5200000" lon=""',
        'lon="13.4050000"',
        'lat="1e999" lon="13.4050000"',
        'lat="abc" lon="def"',
        'lat="--5" lon="13.4050000"',
        'LAT="52.5200000" LON="13.4050000"',
    ]
    s = gpx_open("GPXSynth Fuzzer") + "  <trk>\n    <trkseg>\n"
    view = []
    bi = 0
    single_quote_at = 150
    for k, p in enumerate(pts):
        la, lo = f7(p["lat"]), f7(p["lon"])
        if k % 41 == 5:
            la = "%.9e" % p["lat"]                      # 5.252012345e+01
        if k % 43 == 11:
            lo = "+" + lo
        if k % 47 == 13:
            la = "  " + la
        sep = "\n\t\t" if k % 53 == 17 else " "
        s += '      <trkpt lat="%s"%slon="%s">\n        <ele>%.1f</ele>\n        <time>%s</time>\n      </trkpt>\n' % (
            la, sep, lo, p["ele"], iso(p["t"]))
        view.append((float(la), float(lo), p["t"]))
        if k % 23 == 9 and bi < len(bad):
            s += "      <trkpt %s>\n        <time>%s</time>\n      </trkpt>\n" % (bad[bi], iso(p["t"] + 0.5, ms=True))
            bi += 1
        if k == single_quote_at:
            nx = pts[k + 1]
            s += "      <trkpt lat='%s' lon='%s'>\n        <time>%s</time>\n      </trkpt>\n" % (
                f7((p["lat"] + nx["lat"]) / 2), f7((p["lon"] + nx["lon"]) / 2), iso(p["t"] + 0.5, ms=True))
    assert bi == len(bad), bi
    s += "    </trkseg>\n  </trk>\n</gpx>\n"
    e = expect("g21_invalid_coords.gpx", "300 valid cycling fixes (some written as 5.25e+01 exponent, '+13.4', "
               "leading blanks, newline/tab between attributes) plus 13 invalid trkpt: lat 95, lon 200, "
               "lat -90.0000001, lon -180.0000001, NaN, nan, empty, missing lat, 1e999, abc, --5, upper-case "
               "LAT/LON. All invalid ones must be dropped. One extra trkpt uses single-quoted attributes "
               "(valid XML; this parser only matches lat=\"); points 300-301 either way.",
               view, "GPXSynth Fuzzer", points=[300, 301], profile="any", trips=[1, 1])
    e["timed"] = [300, 301]
    put("g21_invalid_coords.gpx", s, e)


def simple_track(rng, mode, lat, lon, base, seconds, t0, e0=50.0):
    true = simulate(rng, mode, lat, lon, base, seconds - 1)
    ele = elevation(rng, len(true), e0, 5)
    return device_points(rng, true, ele, t0)


def g22_crlf(rng):
    pts = simple_track(rng, "cycle", 59.9139, 10.7522, 20, 300, T0 + 80000, 20)
    s = (gpx_open("Garmin Edge 540") + trk_xml(pts, "CRLF ride") + "</gpx>\n").replace("\n", "\r\n")
    put("g22_crlf.gpx", s,
        expect("g22_crlf.gpx", "300 s cycling, 1 Hz, every line ends in CRLF (Windows export). Clean: 0 gaps / jitter.",
               view_of(pts), "Garmin Edge 540", trips=[1, 1]))


def g23_bom(rng):
    pts = simple_track(rng, "walk", 60.1699, 24.9384, 300, 300, T0 + 90000, 10)
    s = b"\xef\xbb\xbf" + (gpx_open("Suunto app") + trk_xml(pts, "BOM walk") + "</gpx>\n").encode("utf-8")
    put("g23_bom.gpx", s,
        expect("g23_bom.gpx", "UTF-8 BOM before <?xml ...?>, 300 s walk at 1 Hz. The BOM must not break format "
               "sniffing (first line has '<' -> GPX) nor creator lookup (Suunto -> deviceLogger).",
               view_of(pts), "Suunto app", trips=[1, 1]))


def g24_garmin_ext(rng):
    true = simulate(rng, "cycle", 41.9794, 2.8214, 330, 599)
    ele = elevation(rng, len(true), 75, 12)
    pts = device_points(rng, true, ele, T0 + 100000)
    sentinel = {33, 34, 35, 290, 512}
    s = '<?xml version="1.0" encoding="UTF-8" standalone="no" ?>\n'
    s += "<!-- Exported 2024-05-18; 600 trkpt records at 1 Hz; heart rate in extensions -->\n"
    s += ('<gpx creator="Garmin Edge 830" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" '
          'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" '
          'xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3" '
          'xmlns:ns3="http://www.garmin.com/xmlschemas/TrackPointExtension/v2" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
          'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd '
          'http://www.garmin.com/xmlschemas/TrackPointExtension/v1 http://www8.garmin.com/xmlschemas/TrackPointExtensionv1.xsd">\n')
    s += ('  <metadata>\n    <link href="connect.garmin.com">\n      <text>Garmin Connect</text>\n    </link>\n'
          '    <time>%s</time>\n    <extensions><gpxx:Note>timer &amp; laps</gpxx:Note></extensions>\n  </metadata>\n' % iso(pts[0]["t"]))
    s += ('  <trk>\n    <name>Girona Lunch Ride</name>\n    <type>cycling</type>\n'
          '    <extensions>\n      <gpxx:TrackExtension><gpxx:DisplayColor>Red</gpxx:DisplayColor></gpxx:TrackExtension>\n'
          '    </extensions>\n    <trkseg>\n')
    for k, p in enumerate(pts):
        if k and k % 100 == 0:
            s += "      <!-- lap %d -->\n" % (k // 100 + 1)
        if k == 300:
            q = pts[0]
            s += ('      <!-- removed by editor: <trkpt lat="%s" lon="%s"><ele>%.1f</ele></trkpt> -->\n'
                  % (f7(q["lat"]), f7(q["lon"]), q["ele"]))
        ele_s = "9.999999562023526e+24" if k in sentinel else "%.1f" % p["ele"]
        attrs = ('lat="%s" lon="%s"' % (f7(p["lat"]), f7(p["lon"]))) if k % 3 else ('lon="%s"\n        lat="%s"' % (f7(p["lon"]), f7(p["lat"])))
        hr = 120 + int(25 * math.sin(k / 60.0))
        s += ('      <trkpt %s>\n        <ele>%s</ele>\n        <time>%s</time>\n        <extensions>\n'
              '          <ns3:TrackPointExtension>\n            <ns3:atemp>21.0</ns3:atemp>\n'
              '            <ns3:hr>%d</ns3:hr>\n            <ns3:cad>%d</ns3:cad>\n'
              '          </ns3:TrackPointExtension>\n        </extensions>\n      </trkpt>\n'
              % (attrs, ele_s, iso(p["t"]), hr, 80 + k % 11))
    s += "    </trkseg>\n  </trk>\n</gpx>\n<!-- trailing comment after root -->\n"
    e = expect("g24_garmin_ext_ns.gpx", "Garmin Connect style: XML comments (before root, between laps, after root), "
               "5 namespaces, metadata/track <extensions>, TrackPointExtension (hr/cad/atemp) inside every trkpt, "
               "lon-before-lat attributes split over lines, 5 fixes with the 9.999999562023526e+24 'no elevation' "
               "sentinel. A comment contains a commented-out untimed <trkpt> at fix 0's position: a byte-scanning "
               "parser counts it, so points 600-601; timed is 600 either way. 0 gaps / jitter.",
               view_of(pts), "Garmin Edge 830", points=[600, 601], trips=[1, 1])
    put("g24_garmin_ext_ns.gpx", s, e)


def g25_ns_prefixed(rng):
    pts = simple_track(rng, "walk", 38.7223, -9.1393, 45, 200, T0 + 110000, 60)
    s = ('<?xml version="1.0" encoding="UTF-8"?>\n<gpx:gpx xmlns:gpx="http://www.topografix.com/GPX/1/1" '
         'version="1.1" creator="xmlstarlet-roundtrip">\n  <gpx:trk>\n    <gpx:trkseg>\n')
    for p in pts:
        s += ('      <gpx:trkpt lat="%s" lon="%s">\n        <gpx:ele>%.1f</gpx:ele>\n        <gpx:time>%s</gpx:time>\n'
              '      </gpx:trkpt>\n' % (f7(p["lat"]), f7(p["lon"]), p["ele"], iso(p["t"])))
    s += "    </gpx:trkseg>\n  </gpx:trk>\n</gpx:gpx>\n"
    put("g25_ns_prefixed.gpx", s,
        rejected("Namespace-qualified GPX (<gpx:trkpt>, prefix bound to the GPX 1.1 namespace) - valid XML but the "
                 "byte scanner matches only unprefixed '<trkpt '. Rejection (.noPoints) is acceptable; a "
                 "namespace-aware parser would load 200 points, 0 gaps.", points=(0, 200)))


def g26_fractional_offsets(rng):
    true = simulate(rng, "cycle", 53.5511, 9.9937, 260, 899)
    ele = elevation(rng, len(true), 15, 3)
    nz = ARNoise(rng, 4.0, 0.98)
    s = gpx_open("OruxMaps v.10 (merged)") + "  <trk>\n    <trkseg>\n"
    view = []
    for k in range(900):
        t = T0 + 120000 + k + round(rng.uniform(-0.2, 0.2), 3)
        dx, dy = nz.next(1)
        la, lo = offset(true[k][0], true[k][1], dx, dy)
        off = 120 if k < 300 else (0 if k < 600 else -210)
        ts = iso(t, ms=True, off_min=off, z=(off == 0))
        s += pt_xml("trkpt", la, lo, ele[k], ts)
        view.append((r7(la), r7(lo), t))
    s += "    </trkseg>\n  </trk>\n</gpx>\n"
    put("g26_fractional_offsets.gpx", s,
        expect("g26_fractional_offsets.gpx", "900 s cycling, fixes at whole seconds +-0.2 s written with millisecond "
               "fractions; first 300 as local +02:00, next 300 as Z, last 300 as -03:30 - one continuous UTC "
               "timeline. Wrong offset handling would create 2 h / 3.5 h holes and reorderings: trips 1 and 0 gaps "
               "only if offsets are applied.",
               view, "OruxMaps v.10 (merged)", trips=[1, 1]))


def g27_time_1970(rng):
    t0 = -120                                           # 1969-12-31T23:58:00Z
    pts = simple_track(rng, "walk", 51.4779, -0.0015, 270, 600, t0, 45)
    s = gpx_open("GPXSynth Epoch") + trk_xml(pts, "Around the epoch") + "</gpx>\n"
    assert any(p["t"] == 0 for p in pts)
    put("g27_time_1970.gpx", s,
        expect("g27_time_1970.gpx", "600 s walk at Greenwich from 1969-12-31T23:58:00Z to 1970-01-01T00:07:59Z: "
               "unix times -120..479 including exactly 0. Negative and zero times are valid ISO 8601 and must not "
               "be treated as 'no time': timed 600, trips 1, 0 gaps.",
               view_of(pts), "GPXSynth Epoch", trips=[1, 1]))


def g28_time_2100(rng):
    t0 = int(swift_iso_value(2100, 2, 28, 23, 45, 0))
    pts = simple_track(rng, "cycle", 35.6762, 139.6503, 10, 1800, t0, 40)
    s = gpx_open("GPXSynth Future") + trk_xml(pts, "Across 2100-02-28/03-01") + "</gpx>\n"
    put("g28_time_2100.gpx", s,
        expect("g28_time_2100.gpx", "1800 s ride from 2100-02-28T23:45:00Z across midnight into 2100-03-01 (2100 is "
               "NOT a leap year; times ~4.1e9). A wrong leap rule would open a 24 h hole -> trips 2. Expect trips 1, "
               "0 gaps, timed 1800.",
               view_of(pts), "GPXSynth Future", trips=[1, 1]))


def g29_minified(rng):
    pts = simple_track(rng, "cycle", 47.3769, 8.5417, 135, 400, T0 + 130000, 410)
    s = '<?xml version="1.0" encoding="UTF-8"?><gpx version="1.1" creator="GPXSynth Minifier" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>'
    view = []
    for k, p in enumerate(pts):
        if k % 4 == 0:
            a = 'lon="%s" lat="%s"' % (f7(p["lon"]), f7(p["lat"]))
        elif k % 4 == 1:
            a = 'lat="%s"\tlon="%s"' % (f7(p["lat"]), f7(p["lon"]))
        else:
            a = 'lat="%s" lon="%s"' % (f7(p["lat"]), f7(p["lon"]))
        tm = (" %s " % iso(p["t"])) if k % 5 == 0 else iso(p["t"])
        if k % 2:
            s += "<trkpt %s><time>%s</time><ele>%.1f</ele></trkpt>" % (a, tm, p["ele"])
        else:
            s += "<trkpt %s><ele>%.1f</ele><time>%s</time></trkpt>" % (a, p["ele"], tm)
        view.append((r7(p["lat"]), r7(p["lon"]), p["t"]))
    s += "</trkseg></trk></gpx>"
    put("g29_minified_oneline.gpx", s,
        expect("g29_minified_oneline.gpx", "Whole document on one line, no trailing newline: attribute order varies, "
               "tab between attributes, <time> before <ele> on half the fixes, whitespace inside <time> on every "
               "5th fix (XML-valid for xs:dateTime). 400 s ride, 0 gaps / jitter.",
               view, "GPXSynth Minifier", trips=[1, 1]))


def g30_truncated(rng):
    pts = simple_track(rng, "walk", 55.9533, -3.1883, 60, 501, T0 + 140000, 80)
    s = gpx_open("eTrex 22x") + trk_xml(pts, "Battery died") + "</gpx>\n"
    cut = s.rfind("<time>") + len("<time>") + 10       # inside the last fix's time text
    s = s[:cut]
    view = view_of(pts[:-1]) + [(r7(pts[-1]["lat"]), r7(pts[-1]["lon"]), None)]
    e = expect("g30_truncated.gpx", "Recording cut off mid-file (battery): 500 complete fixes, the 501st ends inside "
               "'<time>2024-05-19' with no closing tags. Keeping the partial fix untimed or dropping it are both "
               "fine (points 500-501, timed 500). No crash, 0 gaps.",
               view, "eTrex 22x", points=[500, 501], trips=[1, 1])
    put("g30_truncated.gpx", s, e, wellformed=False)


def g31_bad_time_formats(rng):
    pts = simple_track(rng, "walk", 53.3498, -6.2603, 10, 240, T0 + 150000, 20)
    s = gpx_open("GPXSynth TimeFuzz") + "  <trk>\n    <trkseg>\n"
    view = []
    slash, epoch, empty, month13 = {20, 45, 70, 95}, {120, 140, 160}, {180, 200}, {220}
    for k, p in enumerate(pts):
        t = p["t"]
        if k in slash:
            d = EPOCH + datetime.timedelta(seconds=t)
            ts, tv = d.strftime("%Y/%m/%d %H:%M:%S"), None
        elif k in epoch:
            ts, tv = str(t), None
        elif k in empty:
            ts, tv = "", None
        elif k in month13:
            ts, tv = "2024-13-45T25:61:61Z", swift_iso_value(2024, 13, 45, 25, 61, 61)
        else:
            ts, tv = iso(t), t
        s += pt_xml("trkpt", p["lat"], p["lon"], p["ele"], ts)
        view.append((r7(p["lat"]), r7(p["lon"]), tv))
    s += "    </trkseg>\n  </trk>\n</gpx>\n"
    put("g31_bad_time_formats.gpx", s,
        expect("g31_bad_time_formats.gpx", "240 s walk; 9 fixes carry unparsable times ('2024/05/19 ...', bare epoch "
               "digits, empty <time></time>) -> untimed; one carries '2024-13-45T25:61:61Z', which this parser "
               "does not range-check and turns into a finite time ~9 months later (2025-02-15) -> it sorts last, "
               "separated by > 3600 s: no gap, a lone 1-point tail is not a trip. timed 230-231 (231 if the "
               "month-13 time is accepted).",
               view, "GPXSynth TimeFuzz", timed=[230, 231], trips=[1, 1]))


def g32_fit_binary(rng):
    body = bytearray(rng.getrandbits(8) for _ in range(4096))
    for pat in (b"<trkpt", b"<wpt", b"<rtept"):
        i = body.find(pat)
        while i >= 0:
            body[i] = 0x3E
            i = body.find(pat)
    hdr = bytes([14, 0x20, 0x8C, 0x08]) + struct.pack("<I", len(body)) + b".FIT" + b"\x00\x00"
    put("g32_fit_binary.gpx", hdr + bytes(body) + b"\x00\x00",
        rejected("A Garmin .FIT binary (14-byte header + 4 KB random records) saved with a .gpx extension. "
                 "Expect .noPoints (or any rejection); must not crash or hang."), wellformed=False)


def g33_html_error(rng):
    s = ("<!DOCTYPE html>\n<html>\n<head><title>404 Not Found</title></head>\n<body>\n<h1>Not Found</h1>\n"
         "<table><tr><td>track</td><td>export.gpx</td></tr><tr><td>reason</td><td>expired link</td></tr></table>\n"
         "<p>The requested URL /export/track.gpx was not found on this server.</p>\n<hr><address>nginx</address>\n"
         "</body>\n</html>\n")
    put("g33_html_error.gpx", s,
        rejected("An HTML 404 page saved as .gpx (failed download); contains <tr>/<td>/<title> that share prefixes "
                 "with <trkpt>/<time>. Expect .noPoints; must not crash."), wellformed=False)


def g34_gpx10(rng):
    true = simulate(rng, "cycle", 50.8503, 4.3517, 290, 299)
    ele = elevation(rng, len(true), 60, 4)
    pts = device_points(rng, true, ele, T0 + 160000)
    s = ('<?xml version="1.0" encoding="ISO-8859-1"?>\n<gpx version="1.0" creator="GPSBabel - https://www.gpsbabel.org" '
         'xmlns="http://www.topografix.com/GPX/1/0">\n<time>%s</time>\n'
         '<bounds minlat="50.80" minlon="4.30" maxlat="50.90" maxlon="4.40"/>\n<trk>\n<name>ACTIVE LOG</name>\n'
         '<number>1</number>\n<trkseg>\n' % iso(pts[0]["t"]))
    for k, p in enumerate(pts):
        crs = bearing(true[max(0, k - 1)][0], true[max(0, k - 1)][1], true[k][0], true[k][1]) if k else 0.0
        s += ('<trkpt lat="%s" lon="%s">\n  <time>%s</time>\n  <ele>%.3f</ele>\n  <course>%.1f</course>\n'
              '  <speed>%.2f</speed>\n  <sat>%d</sat>\n  <hdop>%.1f</hdop>\n  <fix>3d</fix>\n</trkpt>\n'
              % (f7(p["lat"]), f7(p["lon"]), iso(p["t"]), p["ele"], crs, 6.0 + rng.uniform(-1, 1),
                 rng.randint(6, 12), rng.uniform(0.7, 1.6)))
    s += "</trkseg>\n</trk>\n</gpx>\n"
    put("g34_gpx10_speed_course.gpx", s.encode("latin-1"),
        expect("g34_gpx10_speed_course.gpx", "GPX 1.0 (GPSBabel, ISO-8859-1 declaration): top-level <time> and "
               "<bounds/>, per-point <time> before <ele>, plus <course>/<speed>/<sat>/<hdop>/<fix>. 300 s ride; "
               "0 gaps / jitter. No creator signal; steady 1 Hz sampling -> deviceLogger by the regularity rule.",
               view_of(pts), "GPSBabel - https://www.gpsbabel.org", trips=[1, 1]))


def g35_boundary_coords(rng):
    corners = [("90.0000000", "0.0000000"), ("90.0000000", "180.0000000"), ("-90.0000000", "-180.0000000"),
               ("0.0000000", "180.0000000"), ("0.0000000", "-180.0000000"), ("-0.0000000", "-0.0000000"),
               ("89.9999999", "179.9999999"), ("-89.9999999", "-179.9999999"), ("0", "0"), ("-90", "180")]
    s = gpx_open("GPXSynth Limits") + "  <trk>\n    <trkseg>\n"
    view = []
    t = T0 + 170000
    for k in range(40):
        la, lo = corners[(k * 7) % len(corners)]
        t += 1 if k % 4 else 30
        s += '      <trkpt lat="%s" lon="%s"><time>%s</time></trkpt>\n' % (la, lo, iso(t))
        view.append((float(la), float(lo), t))
    s += "    </trkseg>\n  </trk>\n</gpx>\n"
    e = expect("g35_boundary_coords.gpx", "40 timed fixes hopping between coordinates exactly ON the valid limits "
               "(lat +-90, lon +-180, -0.0, 0, 89.9999999/179.9999999) at 1 s and 30 s steps; (0,180)/(0,-180) "
               "and (90,0)/(90,180) are the same physical point. All 40 must be kept (|lat| <= 90 and |lon| <= 180 "
               "are inclusive). Not a real track: a no-crash test for haversine/heading/mercator at the limits "
               "with exact coordinate repeats; detector counts are unconstrained.",
               view, "GPXSynth Limits", profile="any")
    e["gaps"] = [0, None]
    e["replays"] = [0, None]
    e["jitter"] = [0, None]
    put("g35_boundary_coords.gpx", s, e)


# ============================================================================= CSV files

STD_HEADER = "dataTime,locType,longitude,latitude,heading,accuracy,speed,distance,isBackForeground,stepType,altitude"


def phone_walk(rng, lat, lon, base, seconds, t0, fg_dts=(2, 3, 3, 3, 4, 5)):
    true = simulate(rng, "walk", lat, lon, base, seconds)
    ele = elevation(rng, len(true), 40, 3)
    times = phone_times(rng, seconds, fg_dts)
    return phone_points(rng, true, ele, t0, times)


def std_row(p, dist, loc="1", bg=None, step="0"):
    bgv = bg if bg is not None else ("1" if p["fg"] else "2")
    hd = "-1" if p["hd"] < 0 else "%.1f" % p["hd"]
    sp = "-1" if p["sp"] < 0 else "%.2f" % p["sp"]
    acc = "%g" % p["acc"]
    return "%d,%s,%s,%s,%s,%s,%s,%.1f,%s,%s,%.1f" % (p["t"], loc, f6(p["lon"]), f6(p["lat"]), hd, acc, sp, dist, bgv, step, p["ele"])


def cumdist(pts):
    out, d = [], 0.0
    for k, p in enumerate(pts):
        if k:
            d += hav(pts[k - 1]["lat"], pts[k - 1]["lon"], p["lat"], p["lon"])
        out.append(d)
    return out


def c01_standard(rng):
    pts = phone_walk(rng, 39.9042, 116.4074, 30, 1700, T0 + 200000)
    dist = cumdist(pts)
    rows = [STD_HEADER] + [std_row(p, dist[k]) for k, p in enumerate(pts)]
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c01_phone_standard.csv", "\n".join(rows) + "\n",
        expect("c01_phone_standard.csv", "Baseline 一生足迹 export (11 columns): city walk, foreground ~3 s, background "
               "20-30 s stretches, ~50%% accuracy = 0, rest 5-65 m (median %s m). Accuracy column -> phone. Gaps "
               "counted by the timeGap rule on the exact written coordinates." % acc,
               view_of(pts, r6), "", acc, profile="phone"))


def c02_reordered(rng):
    pts = phone_walk(rng, -33.4489, -70.6693, 160, 1500, T0 + 210000)
    dist = cumdist(pts)
    hdr = "Latitude,Longitude,Altitude,Accuracy,dataTime,Speed,Heading,locType,isBackForeground,stepType,distance"
    rows = [hdr]
    view = []
    no_time = {57, 131, 203}
    for k, p in enumerate(pts):
        tt = "" if k in no_time else "%d" % p["t"]
        rows.append("%s,%s,%.1f,%g,%s,%s,%s,1,%s,0,%.1f" % (
            f6(p["lat"]), f6(p["lon"]), p["ele"], p["acc"], tt,
            "-1" if p["sp"] < 0 else "%.2f" % p["sp"], "-1" if p["hd"] < 0 else "%.1f" % p["hd"],
            "1" if p["fg"] else "2", dist[k]))
        view.append((r6(p["lat"]), r6(p["lon"]), None if k in no_time else p["t"]))
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c02_reordered_cols.csv", "\n".join(rows) + "\n",
        expect("c02_reordered_cols.csv", "Columns reordered and capitalised (Latitude,Longitude,Altitude,Accuracy,"
               "dataTime,...) in Santiago: every data line starts with '-' (negative latitude). 3 rows have an "
               "empty dataTime -> kept as untimed points (lat/lon valid). Accuracy column -> phone.",
               view, "", acc, profile="phone"))


def c03_no_accuracy(rng):
    pts = phone_walk(rng, 31.2304, 121.4737, 250, 1600, T0 + 220000)
    dist = cumdist(pts)
    hdr = "dataTime,locType,longitude,latitude,heading,speed,distance,isBackForeground,stepType,altitude"
    rows = [hdr]
    for k, p in enumerate(pts):
        rows.append("%d,1,%s,%s,%s,%s,%.1f,%s,0,%.1f" % (
            p["t"], f6(p["lon"]), f6(p["lat"]), "-1" if p["hd"] < 0 else "%.1f" % p["hd"],
            "-1" if p["sp"] < 0 else "%.2f" % p["sp"], dist[k], "1" if p["fg"] else "2", p["ele"]))
    e = expect("c03_no_accuracy.csv", "一生足迹-style CSV without the accuracy column: no creator, no accuracy -> "
               "profile decided by sampling regularity; ~3 s foreground + 20-30 s background is not 'steady' "
               "(median dt 3 > 2) -> phone.",
               view_of(pts, r6), "", None)
    put("c03_no_accuracy.csv", "\n".join(rows) + "\n", e)


def c04_quoted(rng):
    pts = phone_walk(rng, 30.2741, 120.1551, 100, 1300, T0 + 230000)
    dist = cumdist(pts)
    hdr = ",".join('"%s"' % h for h in STD_HEADER.split(",")) + ',"address"'
    rows = [hdr]
    blanks = 0
    for k, p in enumerate(pts):
        f = std_row(p, dist[k]).split(",")
        rows.append(",".join('"%s"' % x for x in f) + ',"West Lake, Hangzhou"')
        if k % 29 == 28:
            rows.append(["", "   ", ",,,,,,,,,,,"][blanks % 3])
            blanks += 1
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c04_quoted_emptylines.csv", "\n".join(rows) + "\n\n\n",
        expect("c04_quoted_emptylines.csv", "Every field double-quoted (header too), an extra trailing \"address\" "
               "column containing a comma, and %d junk lines (empty, blanks only, commas only) plus trailing empty "
               "lines. All %d data rows must load; accuracy -> phone." % (blanks, len(pts)),
               view_of(pts, r6), "", acc, profile="phone"))


def c05_variants(rng):
    pts = phone_walk(rng, 30.5728, 104.0668, 340, 1500, T0 + 240000)
    dist = cumdist(pts)
    rows = [STD_HEADER]
    locs = ["0", "1", "1", "1", "2", "3", "5", "6", "-1"]
    bgs = ["0", "1", "2", "", "true", "false", "1"]
    steps = ["0", "1", "2", "-1", ""]
    for k, p in enumerate(pts):
        r = std_row(p, dist[k], loc=locs[k % len(locs)], bg=bgs[k % len(bgs)], step=steps[k % len(steps)]).split(",")
        if k % 6 == 0:
            r[4] = "-1"          # heading unknown
        if k % 7 == 0:
            r[6] = "-1"          # speed unknown
        if k % 8 == 0:
            r[7] = ""            # distance empty
        rows.append(",".join(r))
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c05_loctype_variants.csv", "\n".join(rows) + "\n",
        expect("c05_loctype_variants.csv", "Standard columns, but locType cycles 0/1/2/3/5/6/-1, isBackForeground "
               "0/1/2/empty/true/false, stepType 0/1/2/-1/empty, heading and speed -1, distance sometimes empty. "
               "None of these columns is read; every row must load. Accuracy -> phone.",
               view_of(pts, r6), "", acc, profile="phone"))


def c06_all_acc_zero(rng):
    pts = phone_walk(rng, 22.5431, 114.0579, 200, 1600, T0 + 250000)
    dist = cumdist(pts)
    for p in pts:
        p["acc"] = 0
    rows = [STD_HEADER] + [std_row(p, dist[k]) for k, p in enumerate(pts)]
    put("c06_all_acc_zero.csv", "\n".join(rows) + "\n",
        expect("c06_all_acc_zero.csv", "Standard 一生足迹 columns but accuracy = 0 (unknown) on every row: the "
               "accuracy median ignores zeros -> nil, so the profile falls back to sampling regularity -> phone "
               "(median dt 3 s, 20-30 s background steps).",
               view_of(pts, r6), "", None))


def c07_crlf_bom(rng):
    pts = phone_walk(rng, 23.1291, 113.2644, 50, 1300, T0 + 260000)
    dist = cumdist(pts)
    rows = [STD_HEADER] + [std_row(p, dist[k]) for k, p in enumerate(pts)]
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c07_crlf_bom.csv", b"\xef\xbb\xbf" + ("\r\n".join(rows) + "\r\n").encode("utf-8"),
        expect("c07_crlf_bom.csv", "UTF-8 BOM + CRLF line endings (Excel re-save). Header must still be recognised "
               "(BOM and \\r trimmed), altitude field ends in \\r. Accuracy -> phone.",
               view_of(pts, r6), "", acc, profile="phone"))


def c08_headerless(rng):
    pts = phone_walk(rng, 34.3416, 108.9398, 80, 1100, T0 + 270000)
    dist = cumdist(pts)
    rows = [std_row(p, dist[k]) for k, p in enumerate(pts)]
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c08_headerless.csv", "\n".join(rows) + "\n",
        expect("c08_headerless.csv", "No header line: numeric first character -> fixed 一生足迹 layout "
               "(0=time, 2=lon, 3=lat, 5=accuracy, 10=altitude). Accuracy -> phone.",
               view_of(pts, r6), "", acc, profile="phone"))


def c09_millis(rng):
    pts = phone_walk(rng, 32.0603, 118.7969, 140, 1100, T0 + 280000)
    rows = ["dataTime,longitude,latitude,accuracy"]
    for p in pts:
        rows.append("%d,%s,%s,%g" % (p["t"] * 1000 + rng.randint(0, 999), f6(p["lon"]), f6(p["lat"]), p["acc"]))
    view = []
    for p, r in zip(pts, rows[1:]):
        view.append((r6(p["lat"]), r6(p["lon"]), int(r.split(",")[0]) / 1000.0))
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c09_millis_minimal.csv", "\n".join(rows) + "\n",
        expect("c09_millis_minimal.csv", "Minimal 4 columns (no altitude) with millisecond epoch times "
               "(1.7e12 > 4e10 -> divided by 1000). Accuracy -> phone.",
               view, "", acc, profile="phone"))


def c10_iso_time(rng):
    pts = phone_walk(rng, 30.5928, 114.3055, 20, 1100, T0 + 290000)
    dist = cumdist(pts)
    rows = [STD_HEADER]
    for k, p in enumerate(pts):
        r = std_row(p, dist[k]).split(",")
        r[0] = iso(p["t"], off_min=480, z=False) if k % 3 == 0 else (iso(p["t"], ms=True) if k % 3 == 1 else iso(p["t"]))
        rows.append(",".join(r))
    acc = csv_acc_median([p["acc"] for p in pts])
    put("c10_iso_time.csv", "\n".join(rows) + "\n",
        expect("c10_iso_time.csv", "dataTime as ISO 8601 strings instead of epoch: every 3rd row local "
               "'+08:00', others 'Z' with or without '.000'. Same instants as a normal export; accuracy -> phone.",
               view_of(pts, r6), "", acc, profile="phone"))


def c11_semicolon(rng):
    pts = phone_walk(rng, 25.0389, 102.7183, 0, 600, T0 + 300000)
    rows = [STD_HEADER.replace(",", ";")]
    for p in pts:
        rows.append("%d;1;%s;%s;-1;%g;-1;0;1;0;%s" % (p["t"], f6(p["lon"]).replace(".", ","), f6(p["lat"]).replace(".", ","),
                                                     p["acc"], ("%.1f" % p["ele"]).replace(".", ",")))
    put("c11_semicolon.csv", "\n".join(rows) + "\n",
        rejected("European-locale export: ';' delimiter and decimal commas. Header has no commas -> not sniffed "
                 "as CSV -> .noPoints is the expected outcome (loading with decimal-comma truncation would be "
                 "wrong data). Must not crash."))


def c12_header_only(rng):
    put("c12_header_only.csv", STD_HEADER + "\n",
        rejected("Header line only, no data rows: CSV layout found, 0 rows -> .noPoints."))


def c13_bad_rows(rng):
    pts = phone_walk(rng, 45.8038, 126.5350, 280, 3400, T0 + 310000)
    assert len(pts) >= 400, len(pts)
    pts = pts[:400]
    dist = cumdist(pts)
    good = [std_row(p, dist[k]) for k, p in enumerate(pts)]
    t = pts[100]["t"]
    junk = [
        "%d,1,126.535000,95.000000,-1,10,-1,0,1,0,150.0" % t,
        "%d,1,200.000000,45.803800,-1,10,-1,0,1,0,150.0" % t,
        "%d,1,126.535000,NaN,-1,10,-1,0,1,0,150.0" % t,
        "%d,1,null,null,-1,10,-1,0,1,0,150.0" % t,
        "%d,1,,,-1,10,-1,0,1,0,150.0" % t,
        "ERROR: location service timeout",
        "# exported by 一生足迹 3.2",
        "%d,1" % t,
        "%d,1,45.803800,126.535000,-1,10,-1,0,1,0,150.0" % t,     # lat/lon swapped -> lat 126.5 invalid
        STD_HEADER,                                                  # concatenated export
        ",1,%s,%s,-1,10,-1,0,1,0,150.0" % (f6(pts[200]["lon"]), f6(pts[200]["lat"])),   # empty dataTime
        "abc,1,%s,%s,-1,10,-1,0,1,0,150.0" % (f6(pts[300]["lon"]), f6(pts[300]["lat"])),  # text dataTime
    ]
    rows = [STD_HEADER]
    ji = 0
    for k, r in enumerate(good):
        rows.append(r)
        if k % 33 == 16 and ji < len(junk):
            rows.append(junk[ji])
            ji += 1
    while ji < len(junk):
        rows.append(junk[ji])
        ji += 1
    acc = csv_acc_median([p["acc"] for p in pts])
    e = expect("c13_bad_rows.csv", "400 good rows plus 12 junk rows: lat 95, lon 200, NaN, null, empty lat/lon, an "
               "error message, a '#' comment, a truncated row, swapped lat/lon (lat 126.5), a repeated header "
               "(concatenated exports), a row with empty dataTime and one with dataTime 'abc'. Junk with invalid "
               "coordinates must be dropped; the last two have valid coordinates and may be kept as untimed "
               "points or skipped (points 400-402, timed 400).",
               view_of(pts, r6), "", acc, profile="phone", points=[400, 402])
    put("c13_bad_rows.csv", "\n".join(rows) + "\n", e)


def c14_random_numeric(rng):
    pool = [(39.9 + rng.uniform(-0.05, 0.05), 116.4 + rng.uniform(-0.05, 0.05)) for _ in range(60)]
    base = T0 + 320000
    lines = []
    for k in range(2000):
        r = rng.random()
        if r < 0.55:
            t = "%d" % (base + rng.randint(0, 3000))
        elif r < 0.65:
            t = "%d" % (base + rng.randint(0, 3000) * 1000)
        else:
            t = rng.choice(["0", "-1", "99999999999", "40000000001", "%d" % rng.randint(0, 2_000_000_000), "1e308",
                            "-0", "%d" % (base + k), "3.5", "NaN", "inf"])
        q = rng.random()
        if q < 0.5:
            la, lo = 39.9 + rng.uniform(-0.05, 0.05), 116.4 + rng.uniform(-0.05, 0.05)
        elif q < 0.75:
            la, lo = rng.choice(pool)
        elif q < 0.9:
            la, lo = rng.uniform(-90, 90), rng.uniform(-180, 180)
        else:
            la, lo = rng.choice([(90.0, 180.0), (-90.0, -180.0), (0.0, 0.0), (95.0, 10.0), (1e308, -1e308), (89.99999, 179.99999)])
        fields = [t, str(rng.randint(-1, 6)), "%.6f" % lo, "%.6f" % la, "%.1f" % rng.uniform(-1, 360),
                  "%g" % rng.choice([0, 0, 5, 10, 30, 65, 1500]), "%.2f" % rng.uniform(-1, 40), "%.1f" % rng.uniform(0, 9e4),
                  rng.choice(["0", "1", "2", ""]), "0", "%.1f" % rng.uniform(-500, 9000)]
        z = rng.random()
        if z < 0.05:
            fields = fields[:rng.randint(1, 10)]
        elif z < 0.08:
            fields.insert(rng.randint(0, 10), "x,y")
        elif z < 0.10:
            fields = ["%s" % rng.choice(["-", "+", ".", "--1", "1-2", "1e", "e5", "0x1F"])] + fields[1:]
        lines.append(",".join(fields))
    put("c14_random_numeric.csv", "\n".join(lines) + "\n",
        {"desc": "Chaos: 2000 headerless numeric rows (fixed 一生足迹 layout) - times clustered in 50 min with many "
                 "per-second collisions plus 0, -1, 1e308, NaN, inf, 4e10+1 (ms branch), 99999999999 (> 1e11 -> NaN); "
                 "coordinates in a 10 km box, a 60-point exact-repeat pool, global random, poles/antimeridian, "
                 "out-of-range; short rows, inserted columns, garbage first fields. Purely a no-crash / no-hang / "
                 "invariant test: accept or reject, any counts.",
         "points": [0, 2000], "profile": "any", "gaps": [0, None], "replays": [0, None], "jitter": [0, None],
         "load_ok": False, "max_total_seconds": 10})


def c15_single_row(rng):
    rows = [STD_HEADER, "%d,1,91.172100,29.652000,-1,12,-1,0,1,0,3650.0" % (T0 + 330000)]
    put("c15_single_row.csv", "\n".join(rows) + "\n",
        expect("c15_single_row.csv", "Header + exactly one data row: 1 point; accuracy median needs >= 20 samples "
               "-> nil, no timed steps -> profile unknown. All detectors empty.",
               [(29.652, 91.1721, T0 + 330000)], "", None, profile="unknown", trips=[0, 0]))


# ============================================================================= main

def verify():
    """Re-read every file: GPX with ElementTree, CSV with the csv module."""
    rows = []
    for name in sorted(FILES):
        with open(name, "rb") as fh:
            data = fh.read()
        ok, info = True, ""
        if name.endswith(".gpx"):
            try:
                root = ET.fromstring(data)
                tags = {}
                for el in root.iter():
                    loc = el.tag.split("}")[-1]
                    if loc in ("trkpt", "wpt", "rtept"):
                        tags[loc] = tags.get(loc, 0) + 1
                info = "XML ok %s" % (" ".join("%s=%d" % kv for kv in sorted(tags.items())) or "(no points)")
            except ET.ParseError as e:
                ok, info = False, "XML error: %s" % e
        else:
            try:
                text = data.decode("utf-8-sig")
                rdr = list(csv.reader(io.StringIO(text)))
                info = "CSV ok %d records" % len(rdr)
            except Exception as e:  # noqa
                ok, info = False, "CSV error: %s" % e
        want = WELLFORMED[name]
        flag = "" if ok == want else "  <-- UNEXPECTED (wellformed expected %s)" % want
        rows.append("%-30s %7d B  %s%s" % (name, len(data), info, flag))
        if ok != want:
            WARN.append("%s: well-formedness %s, expected %s" % (name, ok, want))
    return rows


def main():
    gens = [g01_empty_0byte, g02_tiny, g03_header_only, g04_no_trkpt]
    rgens = [g05_one_point, g06_two_points, g07_no_time, g08_half_time, g09_out_of_order, g10_dup_timestamps,
             g11_dup_points, g12_missing_ele, g13_multi_trk_seg, g14_waypoints_only, g15_route_only, g16_mixed,
             g17_dateline, g18_near_pole, g19_southern, g20_equator, g21_invalid_coords, g22_crlf, g23_bom,
             g24_garmin_ext, g25_ns_prefixed, g26_fractional_offsets, g27_time_1970, g28_time_2100, g29_minified,
             g30_truncated, g31_bad_time_formats, g32_fit_binary, g33_html_error, g34_gpx10, g35_boundary_coords,
             c01_standard, c02_reordered, c03_no_accuracy, c04_quoted, c05_variants, c06_all_acc_zero,
             c07_crlf_bom, c08_headerless, c09_millis, c10_iso_time, c11_semicolon, c12_header_only,
             c13_bad_rows, c14_random_numeric, c15_single_row]
    for g in gens:
        g()
    for i, g in enumerate(rgens):
        g(random.Random(SEED * 1000 + i))
    exp = {"family": "format-edge", "seed": SEED, "generator": "gen.py",
           "files": {k: {kk: vv for kk, vv in v.items() if not kk.startswith("_")} for k, v in sorted(FILES.items())},
           "_port": {k: v["_port"] for k, v in sorted(FILES.items()) if "_port" in v}}
    with open("expect.json", "w", encoding="utf-8") as fh:
        json.dump(exp, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    for line in verify():
        print(line)
    print()
    for name in sorted(FILES):
        e = FILES[name]
        print("%-30s pts=%-12s prof=%-12s gaps=%-8s rep=%-6s jit=%-6s timed=%s %s" % (
            name, e["points"], e["profile"], e["gaps"], e["replays"], e["jitter"], e.get("timed"),
            "" if e["load_ok"] else "(load_ok=false)"))
    if WARN:
        print("\nwarnings:")
        for w in WARN:
            print("  " + w)
    print("\n%d files written" % len(FILES))


if __name__ == "__main__":
    main()
