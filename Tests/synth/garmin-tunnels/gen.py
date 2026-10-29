#!/usr/bin/env python3
"""Synthetic family "garmin-tunnels": device-logger GPX (creator "Garmin eTrex 32x") with tunnels.

Run with this directory as cwd:  python3 -I gen.py
Writes every *.gpx plus expect.json. stdlib only, deterministic (per-file seed = crc32(name) ^ SEED).

Model
-----
* A road / rail centreline is built from (length, total turn, grade) segments on a local metric plane
  (equirectangular around the start point) and sampled at 2 m.
* A vehicle drives it with 1 s true time steps: speed zones with look-ahead braking, accel/decel limits,
  an AR(1) speed fluctuation and optional stops (dwell seconds).
* The receiver: 1 Hz fixes, AR(1)-correlated position error (sigma 3.5 m, rho 0.96, typical of a
  dedicated logger) + 0.8 m white noise; coordinates quantised to Garmin semicircles (2^31 per 180 deg)
  and printed with Python repr (like the real Garmin export: lat="41.909239172935486"); timestamps
  whole seconds, ISO 8601 Z.
* Tunnel events (all along-road arc-length intervals [s_a, s_b)):
    hole        no fixes inside; the receiver needs `reacq` more seconds after the portal; first 3 fixes
                after re-lock carry a decaying portal bias (8-25 m).
    stale       as hole, but the first k fixes after re-lock are stamped tA+1..tA+k (clock continues from
                the entry time), then the clock jumps back to real time (jump = real A->S1 time). This is
                what real eTrex/Explore data shows (data/Garmin_Roma_Da.gpx: 89 such events, k = 5).
    stale2      stale with a two-step correction: after k stale fixes the clock jumps +J1 s but is still
                behind, m more fixes, then the remaining lag is corrected (real case quoted in
                GapFill.swift: 3.2 km tunnel, +46 s then +68 s).
    bogus       hole whose stamped duration is far too short (receiver clock froze while unlocked and
                never caught up): the lag persists for the rest of the file.
    timed       exactly dt-1 fixes missing right after the portal (stamped hole = dt seconds).
    continuous  the receiver keeps a (degraded, sigma 8 m) fix through the tunnel: no points missing.
    island      no fixes inside except one isolated fix (20 m error) nearest to each listed position.
* Bunching (optional): Garmin-style timestamp sticking -- runs of 1-4 consecutive 1 Hz fixes share the
  stamp of the first one, then the stamp jumps by the run length (positions keep advancing).

Every event is checked here against the spec-level rules quoted in the task (timeGap: dt >= 20 s,
>= 150 m, 15-350 km/h, dt <= 3600 s; staleClock: 1 s step >= 150 m / > 350 km/h followed within 20
points by a clock jump >= 5 s that makes A->B 15-350 km/h), and the whole file is scanned so that no
step outside the intended events satisfies a candidate precondition. expect.json is written from the
event list, not from running any detector.
"""
import bisect
import datetime
import json
import math
import random
import zlib

SEED = 20261023
CREATOR = "Garmin eTrex 32x"
R_EARTH = 6371000.0
SEMI = 2147483648.0 / 180.0


def hav(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R_EARTH * math.asin(min(1.0, math.sqrt(h)))


def iso(t):
    return datetime.datetime.fromtimestamp(t, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(y, mo, d, h, mi, s=0):
    return int(datetime.datetime(y, mo, d, h, mi, s, tzinfo=datetime.timezone.utc).timestamp())


def semi(x):
    return round(x * SEMI) / SEMI


# ----------------------------------------------------------------------------- geometry

class Road:
    def __init__(self, lat0, lon0, heading_deg, ele0, segs, step=2.0):
        self.lat0, self.lon0 = lat0, lon0
        self.ky = R_EARTH * math.pi / 180.0
        self.kx = self.ky * math.cos(math.radians(lat0))
        h = math.radians(heading_deg)
        x = y = s = 0.0
        e = ele0
        S, X, Y, H, E = [0.0], [0.0], [0.0], [h], [e]
        self.seg_ends = []
        for (L, turn, grade) in segs:
            n = max(1, int(math.ceil(L / step)))
            ds, dh = L / n, math.radians(turn) / n
            for _ in range(n):
                h += dh / 2
                x += ds * math.sin(h)
                y += ds * math.cos(h)
                h += dh / 2
                e += grade * ds
                s += ds
                S.append(s); X.append(x); Y.append(y); H.append(h); E.append(e)
            self.seg_ends.append(s)
        self.S, self.X, self.Y, self.H, self.E = S, X, Y, H, E
        self.length = s

    def at(self, s):
        s = min(max(s, 0.0), self.length)
        i = min(bisect.bisect_right(self.S, s) - 1, len(self.S) - 2)
        f = (s - self.S[i]) / (self.S[i + 1] - self.S[i])
        lerp = lambda a: a[i] + f * (a[i + 1] - a[i])
        return lerp(self.X), lerp(self.Y), lerp(self.H), lerp(self.E)

    def latlon(self, x, y):
        return self.lat0 + y / self.ky, self.lon0 + x / self.kx


# ----------------------------------------------------------------------------- vehicle

def drive(rng, road, t0, cruise, zones=(), stops=(), accel=1.0, decel=1.4, start_dwell=20,
          end_dwell=15, v_fluct=0.5, s_end=None):
    """-> list of (t_true, s, v) at 1 s steps. zones: (s_a, s_b, vmax); stops: (s_stop, dwell_s)."""
    s_end = road.length - 3.0 if s_end is None else s_end
    zones = sorted(zones)

    def vlim(s):
        v = cruise
        for a, b, vz in zones:
            if a <= s < b:
                v = min(v, vz)
        return v

    def vallowed(s):
        v = vlim(s)
        for a, b, vz in zones:
            if s < a < s + 4000:
                v = min(v, math.sqrt(vz * vz + 2 * 0.6 * decel * (a - s)))
        return v

    out = []
    t, s, v, fl = t0, 0.0, 0.0, 0.0
    for _ in range(start_dwell):
        out.append((t, s, 0.0)); t += 1
    stops = sorted(stops) + [(s_end, end_dwell)]
    k = 0
    while k < len(stops):
        out.append((t, s, v))
        fl = 0.92 * fl + rng.gauss(0, 0.4 * v_fluct)
        target = vallowed(s) + fl
        ss, dwell = stops[k]
        dist = ss - s
        target = min(target, math.sqrt(2 * 0.6 * decel * max(dist, 0.0)))
        if dist <= max(1.0, v) and v <= 2.5:
            t += 1
            s, v = ss, 0.0
            for _ in range(dwell):
                out.append((t, s, 0.0)); t += 1
            k += 1
            if k == len(stops):
                break
            continue
        if target < 1.0 and dist > 1.0:
            target = 1.0
        target = max(0.0, target)
        dv = max(-decel, min(accel, target - v))
        vn = max(0.0, v + dv)
        s += 0.5 * (v + vn)
        v = vn
        t += 1
    return out


# ----------------------------------------------------------------------------- receiver

class Ev:
    def __init__(self, mode, s_a, s_b=None, **kw):
        self.mode, self.s_a, self.s_b = mode, s_a, s_b
        self.reacq = kw.pop("reacq", 2)
        self.k = kw.pop("k", 5)
        self.J1 = kw.pop("J1", 46)
        self.m = kw.pop("m", 6)
        self.dt_stamp = kw.pop("dt_stamp", None)
        self.dt = kw.pop("dt", None)
        self.islands = kw.pop("islands", ())
        self.expect = kw.pop("expect", None)      # 'timeGap' | 'staleClock' | None (no candidate)
        self.label = kw.pop("label", mode)
        assert not kw, kw
        # filled by observe()
        self.A = self.B = None         # output indices of the anchors
        self.S1 = None                 # first fix after re-lock (stale modes)
        self.island_idx = []


def observe(rng, road, samples, events, sigma=3.5, rho=0.96, lane=1.8):
    n = len(samples)
    ts = [x[0] for x in samples]
    ss = [x[1] for x in samples]
    keep = [True] * n
    extra_sigma = [0.0] * n
    portal_bias = {}                  # sample idx -> (bx, by)
    stale_stamp = {}                  # sample idx -> ('stale', ev, j) / ('mid', ev, j)
    lag_events = []                   # (sample idx of B, ev) for bogus lag
    for ev in events:
        if ev.mode == "timed":
            ia = max(i for i in range(n) if ss[i] < ev.s_a)
            for i in range(ia + 1, ia + ev.dt):
                keep[i] = False
            ev._ia, ev._ib = ia, ia + ev.dt
            continue
        if ev.mode == "continuous":
            for i in range(n):
                if ev.s_a <= ss[i] < ev.s_b:
                    extra_sigma[i] = 8.0
            ev._ia = ev._ib = None
            continue
        inside = [i for i in range(n) if ev.s_a <= ss[i] < ev.s_b]
        assert inside, ev.label
        ia = inside[0] - 1
        j0 = inside[-1] + 1
        for i in inside:
            keep[i] = False
        if ev.mode == "island":
            for pos in ev.islands:
                best = min(inside, key=lambda i: abs(ss[i] - pos))
                keep[best] = True
                extra_sigma[best] = 20.0
                ev.island_idx.append(best)
            ev.island_idx.sort()
        for i in range(j0, j0 + ev.reacq):
            keep[i] = False
        ib = j0 + ev.reacq
        for j in range(3):
            ang = rng.uniform(0, 2 * math.pi)
            mag = rng.uniform(8, 25) * math.exp(-j / 1.5)
            portal_bias[ib + j] = (mag * math.cos(ang), mag * math.sin(ang))
        ev._ia, ev._s1 = ia, ib
        if ev.mode == "stale":
            for j in range(ev.k):
                stale_stamp[ib + j] = ("stale", ev, j + 1)
            ev._ib = ib + ev.k
        elif ev.mode == "stale2":
            for j in range(ev.k):
                stale_stamp[ib + j] = ("stale", ev, j + 1)
            for j in range(ev.m):
                stale_stamp[ib + ev.k + j] = ("mid", ev, j)
            ev._ib = ib + ev.k + ev.m
        else:
            ev._ib = ib
            if ev.mode == "bogus":
                lag_events.append((ib, ev))

    # positions (noise runs over dropped samples too: the error process is continuous in time).
    # extra_sigma: inside a 'continuous' tunnel the correlated error grows to 8 m; isolated island fixes
    # get 20 m white error on top
    ex = rng.gauss(0, sigma); ey = rng.gauss(0, sigma); ez = 0.0
    lat, lon, ele = [None] * n, [None] * n, [None] * n
    q = math.sqrt(1 - rho * rho)
    for i in range(n):
        sg = max(sigma, extra_sigma[i]) if extra_sigma[i] < 10 else sigma
        ex = rho * ex + q * sg * rng.gauss(0, 1)
        ey = rho * ey + q * sg * rng.gauss(0, 1)
        ez = 0.95 * ez + 0.3 * rng.gauss(0, 1)
        x, y, h, e = road.at(ss[i])
        x += lane * math.cos(h); y -= lane * math.sin(h)
        x += ex + rng.gauss(0, 0.8)
        y += ey + rng.gauss(0, 0.8)
        if extra_sigma[i] >= 10:
            x += rng.gauss(0, extra_sigma[i]); y += rng.gauss(0, extra_sigma[i])
        if i in portal_bias:
            x += portal_bias[i][0]; y += portal_bias[i][1]
        la, lo = road.latlon(x, y)
        lat[i], lon[i], ele[i] = semi(la), semi(lo), e + ez

    # stamps
    stamp = [None] * n
    lag = 0
    lag_at = {ib: ev for ib, ev in lag_events}
    last_kept = None
    l2 = {}
    for i in range(n):
        if not keep[i]:
            continue
        if i in lag_at:
            ev = lag_at[i]
            want = stamp[ev._ia] + ev.dt_stamp
            lag = ts[i] - want
        st = ts[i] - lag
        if i in stale_stamp:
            kind, ev, j = stale_stamp[i]
            if kind == "stale":
                st = stamp[ev._ia] + j
            else:
                if j == 0:
                    l2[id(ev)] = ts[i] - lag - (stamp[last_kept] + ev.J1)
                st = ts[i] - lag - l2[id(ev)]
        stamp[i] = st
        last_kept = i

    kept = [i for i in range(n) if keep[i]]
    out_index = {i: k for k, i in enumerate(kept)}
    pts = [(lat[i], lon[i], ele[i], stamp[i]) for i in kept]
    for ev in events:
        if ev._ia is not None:
            ev.A = out_index[ev._ia]
            ev.B = out_index[ev._ib]
        if getattr(ev, "_s1", None) is not None and ev.mode in ("stale", "stale2"):
            ev.S1 = out_index[ev._s1]
        ev.island_out = [out_index[i] for i in ev.island_idx]
    return pts


def bunch_stamps(rng, pts):
    """Garmin timestamp sticking on 1 Hz data: runs of 1-4 consecutive fixes (stamps +1 apart) share the
    first stamp; a run never spans a hole."""
    out = []
    i, n = 0, len(pts)
    while i < n:
        g = rng.choices([1, 2, 3, 4], weights=[15, 20, 25, 40])[0]
        j = i + 1
        while j < n and j - i < g and pts[j][3] - pts[j - 1][3] == 1:
            j += 1
        for k in range(i, j):
            la, lo, el, _ = pts[k]
            out.append((la, lo, el, pts[i][3]))
        i = j
    return out


# ----------------------------------------------------------------------------- output

def write_gpx(path, name, pts):
    t0 = pts[0][3]
    lines = [
        '<?xml version="1.0" encoding="UTF-8" standalone="no" ?>',
        '<gpx creator="%s" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">' % CREATOR,
        '  <metadata>',
        '    <link href="http://www.garmin.com">',
        '      <text>Garmin International</text>',
        '    </link>',
        '    <time>%s</time>' % iso(t0),
        '  </metadata>',
        '  <trk>',
        '    <name>%s</name>' % name,
        '    <extensions>',
        '      <gpxx:TrackExtension>',
        '        <gpxx:DisplayColor>Cyan</gpxx:DisplayColor>',
        '      </gpxx:TrackExtension>',
        '    </extensions>',
        '    <trkseg>',
    ]
    for la, lo, el, t in pts:
        lines.append('      <trkpt lat="%r" lon="%r">' % (la, lo))
        lines.append('        <ele>%.2f</ele>' % el)
        lines.append('        <time>%s</time>' % iso(t))
        lines.append('      </trkpt>')
    lines += ['    </trkseg>', '  </trk>', '</gpx>', '']
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


# ----------------------------------------------------------------------------- spec-level checks

def step(pts, i, j):
    return hav(pts[i][0], pts[i][1], pts[j][0], pts[j][1]), pts[j][3] - pts[i][3]


def is_timegap(d, dt):
    return dt >= 20 and d >= 150 and dt <= 3600 and 15 <= (d / dt * 3.6) <= 350


def check_events(name, pts, events):
    """Assert each event is what it claims under the spec rules, with margins; returns
    (positives, gap_cover, gap_free, notes)."""
    cover, free, notes = [], [], []
    pos = 0
    intended_steps = set()            # step indices (i-1 -> i) that are allowed to satisfy a precondition
    for ev in events:
        if ev.mode == "continuous":
            continue
        A, B = ev.A, ev.B
        tA, tB = pts[A][3], pts[B][3]
        dAB = hav(pts[A][0], pts[A][1], pts[B][0], pts[B][1])
        span = tB - tA
        kmh = dAB / span * 3.6 if span > 0 else float("inf")
        ev.info = dict(tA=tA, tB=tB, meters=round(dAB), seconds=span, kmh=round(kmh, 1))
        if ev.mode == "island":
            idx = [A] + ev.island_out + [B]
            segs = []
            for a, b in zip(idx, idx[1:]):
                assert b == a + 1, (name, ev.label, "island fixes must be consecutive output points")
                d, dt = step(pts, a, b)
                assert is_timegap(d, dt) and dt >= 60 and d >= 1000 and 40 <= d / dt * 3.6 <= 250, (name, ev.label, d, dt)
                segs.append((pts[a][3], pts[b][3], round(d), dt))
                cover.append([pts[a][3], pts[b][3]])
                intended_steps.add(b)
                pos += 1
            ev.info["segments"] = segs
            continue
        if ev.mode in ("hole", "timed") and ev.expect == "timeGap":
            assert B == A + 1
            assert is_timegap(dAB, span) and dAB >= 300 and 15 * 1.25 <= kmh <= 350 * 0.8, (name, ev.label, dAB, span, kmh)
            cover.append([tA, tB]); pos += 1; intended_steps.add(B)
        elif ev.mode == "timed" and ev.expect is None:
            assert B == A + 1 and span < 20 and kmh < 300, (name, ev.label, span, kmh)
            free.append([tA - 5, tB + 5]); intended_steps.add(B)
        elif ev.mode == "hole" and ev.expect is None:
            # rejected holes: too long (> 3600 s) and/or too slow (< 15 km/h)
            assert B == A + 1 and dAB >= 150 and span >= 20 and (span > 3600 or kmh < 15 * 0.8), (name, ev.label, span, kmh)
            free.append([tA - 5, tB + 5]); intended_steps.add(B)
        elif ev.mode == "bogus":
            assert B == A + 1 and dAB >= 150 and kmh > 350 * 1.1, (name, ev.label, dAB, span, kmh)
            if span < 20:
                # stale branch precondition fires, but no clock jump >= 5 s may follow within 20 points
                for k in range(B, min(len(pts) - 1, B + 25)):
                    assert pts[k + 1][3] - pts[k][3] < 5, (name, ev.label, "unexpected clock jump")
            free.append([tA - 5, tB + 5]); intended_steps.add(B)
        elif ev.mode in ("stale", "stale2"):
            S1 = ev.S1
            assert S1 == A + 1
            d1, dt1 = step(pts, A, S1)
            assert dt1 == 1 and d1 >= 5 * 40 and d1 / dt1 * 3.6 > 350, (name, ev.label, d1, dt1)
            nstale = ev.k
            assert 3 <= nstale <= 8
            # stale fixes: 1 s stamps, ordinary 1 Hz steps between them
            for k in range(S1, S1 + nstale - 1):
                d, dt = step(pts, k, k + 1)
                assert dt == 1 and d < 60, (name, ev.label, d, dt)
            jump1 = pts[S1 + nstale][3] - pts[S1 + nstale - 1][3]
            assert jump1 >= 20, (name, ev.label, jump1)
            if ev.mode == "stale":
                assert B == S1 + nstale
                assert jump1 >= 0.35 * span * 1.5, (name, ev.label, jump1, span)
            else:
                B1 = S1 + nstale
                sp1 = pts[B1][3] - tA
                d1b = hav(pts[A][0], pts[A][1], pts[B1][0], pts[B1][1])
                v1 = d1b / sp1 * 3.6
                # first correction alone leaves A->B1 implausibly fast for this road (> 1.5 x 110 + 20)
                assert 1.5 * 115 + 20 < v1 <= 330 and jump1 >= 0.35 * sp1 * 1.3, (name, ev.label, v1, jump1, sp1)
                jump2 = pts[B][3] - pts[B - 1][3]
                assert jump2 >= 20 and B - S1 < 16, (name, ev.label, jump2)
                ev.info["first_jump"] = jump1
                ev.info["second_jump"] = jump2
                ev.info["kmh_after_first_jump"] = round(v1, 1)
            assert 150 * 2 <= dAB and 15 * 1.5 <= kmh <= 160, (name, ev.label, dAB, kmh)
            ev.info["stale_points"] = nstale
            ev.info["clock_jump"] = jump1
            cover.append([tA, tB]); pos += 1
            intended_steps.add(S1)
            intended_steps.update(range(S1 + 1, B + 1))
        else:
            raise AssertionError((name, ev.label, ev.mode, ev.expect))
    # whole-file scan: no other step may satisfy a timeGap rule or the stale-branch precondition,
    # and every ordinary step must be a plausible 1 Hz road/rail step
    for i in range(1, len(pts)):
        d, dt = step(pts, i - 1, i)
        assert dt >= 0, (name, i, "stamps must be non-decreasing")
        if i in intended_steps:
            continue
        assert dt < 20, (name, i, d, dt, "unintended time hole")
        assert d < 150 * 0.8, (name, i, d, dt, "unintended spatial jump")
    return pos, cover, free, notes


# ----------------------------------------------------------------------------- scenarios

def kmh(v):
    return v / 3.6


def zone_around(s_a, s_b, v, before=400, after=200):
    return (s_a - before, s_b + after, kmh(v))


FILES = {}


def scenario(fn):
    FILES[fn.__name__] = fn
    return fn


@scenario
def highway_3tunnels_holes(rng):
    road = Road(46.6213, 8.5937, 12, 640, [
        (3500, 0, 0.004), (1400, 22, 0.010), (2600, 0, 0.012), (1100, -28, 0.002),
        (2600, 5, 0.008),                      # T1 8600-11200
        (1800, 12, 0.000), (2400, 0, -0.004), (1500, -18, 0.006),
        (3700, -6, 0.011),                     # T2 17100-20800
        (2200, 15, 0.000), (2800, 0, -0.009), (1200, 26, 0.000),
        (1650, 4, 0.004),                      # T3 27000-28650
        (2600, 0, 0.000), (1800, -12, -0.003), (1200, 0, 0.0)])
    T = [(8600, 11200, 90), (17100, 20800, 80), (27000, 28650, 60)]
    zones = [zone_around(a, b, v) for a, b, v in T]
    smp = drive(rng, road, epoch(2025, 7, 12, 6, 41, 7), kmh(120), zones)
    evs = [Ev("hole", a, b, reacq=r, expect="timeGap", label="T%d" % (k + 1))
           for k, ((a, b, _), r) in enumerate(zip(T, (2, 3, 2)))]
    return road, smp, evs, dict(), (
        "A2-style motorway at 120 km/h, eTrex 1 Hz; three tunnels (2.6 km @90, 3.7 km @80, 1.65 km @60 km/h) "
        "as pure time holes: no fixes inside, 2-3 s re-lock after the portal, 8-25 m decaying portal bias. "
        "Each hole is one consecutive-point step of 90-300 s / 1.5-4 km / 60-95 km/h -> exactly 3 timeGap, "
        "0 staleClock (clock never stale), no replay (no bit-identical coordinates), no jitter (every "
        "1 s step <= 40 m and forward; holes >= 20 s reset the jitter reference).")


@scenario
def stale_clock_tunnel(rng):
    road = Road(47.0571, 11.4402, 205, 720, [
        (3000, 0, 0.003), (1500, -20, 0.008), (1500, 0, 0.010),
        (2200, 3, 0.006),                      # T 6000-8200
        (2000, 18, -0.004), (2500, 0, -0.006), (1300, 0, 0.0)])
    smp = drive(rng, road, epoch(2025, 9, 3, 14, 12, 40), kmh(110), [zone_around(6000, 8200, 80)])
    evs = [Ev("stale", 6000, 8200, reacq=2, k=5, expect="staleClock", label="T")]
    return road, smp, evs, dict(), (
        "Motorway 110 km/h, one 2.2 km tunnel at 80 km/h. Garmin stale clock: after re-lock the first 5 fixes "
        "are stamped entry+1..entry+5 (1 s apart, but the first one is ~2.2 km from the last entry fix), "
        "then the clock jumps by the real hole time (~100 s). -> exactly 1 staleClock candidate anchored "
        "entry fix -> first correctly-stamped fix (gap_cover), 0 timeGap (the clock-jump step itself is "
        "a ~25 m step), no jitter: the 1 s/2.2 km step opens a cluster but the >= 20 s clock jump right "
        "after it abandons it (hole inside cluster), and with only 1 forward jump it could not be emitted anyway.")


@scenario
def stale_clock_variants(rng):
    road = Road(46.2508, 7.3631, 70, 520, [
        (3200, 0, 0.002), (1800, 15, 0.004),
        (1900, 2, 0.003),                      # T1 5000-6900
        (2600, -10, 0.0), (3500, 0, 0.004),
        (3100, -4, 0.007),                     # T2 13000-16100
        (2200, 14, 0.0), (3700, 0, -0.003),
        (3200, 3, 0.005),                      # T3 22000-25200
        (2600, -16, 0.0), (1500, 0, 0.0)])
    zones = [zone_around(5000, 6900, 100), zone_around(13000, 16100, 90), zone_around(22000, 25200, 100)]
    smp = drive(rng, road, epoch(2025, 10, 18, 9, 5, 21), kmh(120), zones)
    evs = [Ev("stale", 5000, 6900, reacq=1, k=3, expect="staleClock", label="T1 k=3"),
           Ev("stale", 13000, 16100, reacq=3, k=8, expect="staleClock", label="T2 k=8"),
           Ev("stale2", 22000, 25200, reacq=2, k=4, J1=46, m=6, expect="staleClock", label="T3 two-step")]
    return road, smp, evs, dict(), (
        "Motorway 120 km/h with three stale-clock tunnels: T1 1.9 km, 3 stale fixes; T2 3.1 km, 8 stale fixes "
        "(upper end of the observed 3-8); T3 3.2 km with a two-step clock correction (4 stale fixes, +46 s, "
        "6 more fixes still ~75 s behind, then +75 s -- modelled on the real case quoted in GapFill.swift, +46 s then +68 s). "
        "-> exactly 3 staleClock, 0 timeGap. For T3 the candidate must end at the SECOND correction "
        "(A->B1 alone implies ~240 km/h, far above the 100-120 km/h recorded around it); gap_cover for T3 uses "
        "the full [entry, second correction] interval, which an A->B1 candidate would cover only with IoU ~0.4. "
        "No jitter (clusters opened by the 1 s jumps are abandoned at the >= 20 s clock jumps).")


@scenario
def tunnel_chain_holes(rng):
    road = Road(46.8869, 9.5102, 160, 590, [
        (4000, 0, 0.003),
        (1200, 4, 0.006),                      # T1 4000-5200
        (780, 8, 0.004),
        (2400, -5, 0.008),                     # T2 5980-8380
        (1500, -9, 0.004),
        (900, 3, 0.006),                       # T3 9880-10780
        (3000, 10, 0.0), (1500, 0, -0.002)])
    T = [(4000, 5200), (5980, 8380), (9880, 10780)]
    zones = [(3600, 11000, kmh(100))]
    smp = drive(rng, road, epoch(2025, 8, 2, 16, 27, 55), kmh(120), zones)
    evs = [Ev("hole", a, b, reacq=r, expect="timeGap", label="T%d" % (k + 1))
           for k, ((a, b), r) in enumerate(zip(T, (3, 2, 2)))]
    return road, smp, evs, dict(merged=[3, 3]), (
        "Tunnel chain at 100 km/h: 1.2 km, 2.4 km, 0.9 km tunnels separated by 780 m and 1.5 km of open road "
        "(~25 s and ~51 s of real on-road 1 Hz fixes after re-lock). Pure time holes (40-90 s) -> exactly 3 "
        "timeGap, 0 stale, 0 jitter, 0 replay. merged = 3: the open stretches hold >= 20 real points, far above "
        "mergeChains' 3-point limit (GapFill.swift: 'Garmin chains are 17-30 on-road points, not merged').")


@scenario
def tunnel_chain_stale(rng):
    road = Road(45.9093, 6.8667, 300, 1010, [
        (3500, 0, 0.004),
        (1500, -3, 0.007),                     # T1 3500-5000
        (900, 10, 0.005),
        (2000, 4, 0.008),                      # T2 5900-7900
        (1250, -12, 0.003),
        (1300, 0, 0.006),                      # T3 9150-10450
        (2600, 9, 0.0), (1400, 0, 0.0)])
    T = [(3500, 5000, 5), (5900, 7900, 4), (9150, 10450, 6)]
    zones = [(3100, 10700, kmh(90))]
    smp = drive(rng, road, epoch(2026, 2, 14, 11, 3, 9), kmh(110), zones)
    evs = [Ev("stale", a, b, reacq=2, k=k, expect="staleClock", label="T%d k=%d" % (n + 1, k))
           for n, (a, b, k) in enumerate(T)]
    return road, smp, evs, dict(merged=[3, 3]), (
        "Tunnel chain at 90 km/h (1.5 km, 2.0 km, 1.3 km; open stretches 900 m and 1250 m = 36 s and 50 s of "
        "fixes) where every tunnel exit has the Garmin stale clock (5/4/6 stale fixes, then the clock jumps by "
        "the real hole time 60-80 s). Each clock jump lies inside the 20-point stale window and before the next "
        "tunnel -> exactly 3 separate staleClock candidates, 0 timeGap, 0 jitter; merged = 3 (>= 20 points "
        "between candidates).")


@scenario
def short_tunnel_continuous(rng):
    road = Road(47.4106, 9.2930, 95, 450, [
        (3000, 0, 0.002), (300, 2, 0.004),     # tunnel 3000-3300
        (2500, 15, 0.0), (650, 3, 0.006),      # gallery 5800-6450
        (2200, -10, 0.0), (300, 0, -0.004),    # tunnel 8650-8950
        (2000, 0, 0.0)])
    smp = drive(rng, road, epoch(2025, 5, 21, 7, 44, 30), kmh(100), [])
    evs = [Ev("continuous", 3000, 3300, label="300 m tunnel"),
           Ev("continuous", 5800, 6450, label="650 m gallery"),
           Ev("continuous", 8650, 8950, label="300 m tunnel 2")]
    return road, smp, evs, dict(trips=[1, 1]), (
        "100 km/h road with two 300 m tunnels and a 650 m avalanche gallery the eTrex logs straight through "
        "(1 Hz never interrupted, error grows to sigma ~8 m inside). No step >= 20 s, no 1 s step >= 150 m "
        "-> 0 candidates, 0 jitter (largest step ~50 m vs the 300 m jump floor), 0 replay; 1 trip.")


@scenario
def short_holes_subthreshold(rng):
    road = Road(46.4950, 11.3540, 20, 260, [
        (3000, 0, 0.0), (2000, 10, 0.003), (3000, 0, 0.002), (2000, -14, 0.0),
        (3000, 0, 0.002), (2000, 8, 0.0), (3000, 0, 0.0), (1500, 0, 0.0)])
    smp = drive(rng, road, epoch(2025, 6, 9, 18, 20, 2), kmh(100), [])
    evs = [Ev("timed", 3000, dt=9, label="9 s hole"),
           Ev("timed", 6500, dt=14, label="14 s hole"),
           Ev("timed", 10000, dt=19, label="19 s hole"),
           Ev("timed", 14000, dt=20, expect="timeGap", label="20 s hole")]
    return road, smp, evs, dict(trips=[1, 1]), (
        "100 km/h road with four short tunnels where exactly 8/13/18/19 fixes are missing (stamped holes of "
        "9, 14, 19 and 20 s, 250-560 m, ~100 km/h). Only the 20 s hole meets dt >= 20 s -> exactly 1 timeGap "
        "(gap_cover), the others are gap_free (dt < 20 s and speed << 350 km/h, so neither the timeGap nor the "
        "stale branch applies). No jitter: a 19 s / 530 m step is far below the jump threshold "
        "2.5*vRef*dt + 4*mLoc (~1.4 km).")


@scenario
def train_blackout_40km(rng):
    road = Road(50.3510, 7.5880, 222, 70, [
        (6000, 0, 0.0), (3000, 12, 0.0), (9000, 0, 0.001), (2500, -15, 0.0), (6000, 0, 0.0),
        (3000, 18, -0.001), (8000, 0, 0.0), (2500, -10, 0.0), (7000, 0, 0.001), (3000, 14, 0.0),
        (9000, 0, 0.0), (2000, -8, 0.0), (7000, 0, 0.0), (6000, 0, 0.0)])
    zones = [(9000, 12500, kmh(120)), (20500, 23500, kmh(130)), (32000, 35500, kmh(130)),
             (43500, 46500, kmh(120)), (53000, 56500, kmh(130))]
    stops = [(16000, 55), (48500, 50), (72000, 60)]
    smp = drive(rng, road, epoch(2026, 3, 26, 15, 2, 11), kmh(160), zones, stops,
                accel=0.45, decel=0.7, start_dwell=40, v_fluct=0.3)
    evs = [Ev("island", 24000, 64000, reacq=4, islands=(33000, 41500, 55000), label="40 km blackout")]
    return road, smp, evs, dict(trips=[1, 1]), (
        "Regional train (RE, up to 160 km/h, station stops 50-60 s), eTrex on the seat: 1 Hz fixes except a "
        "40 km blackout (km 24-64, includes a station stop) with only 3 isolated fixes (20 m error). The "
        "blackout is therefore 4 consecutive-point steps of 8.5-13.5 km / 200-500 s / 95-160 km/h, each a "
        "timeGap -> exactly 4 timeGap, 0 stale (all steps >= 20 s), 0 jitter (every >= 20 s step resets "
        "the reference), 0 replay. Detector-level only: no expectation on merging/filling (mergeChains "
        "would collapse the 4 steps into one chain because only 1 point separates them).")


@scenario
def tunnel_stop_1h(rng):
    road = Road(47.2650, 11.2410, 250, 600, [
        (3000, 0, 0.002), (2000, 3, 0.006),    # T1 3000-5000 (control)
        (3000, -12, 0.0), (4000, 0, 0.003),
        (2600, 2, 0.007),                      # T2 12000-14600 (closure: stop inside)
        (2500, 10, 0.0), (1500, 0, 0.0)])
    zones = [zone_around(3000, 5000, 90), (11300, 12000, kmh(25)), (12000, 12160, kmh(8)),
             (12160, 14600, kmh(60))]
    stops = [(12150, 3620)]
    smp = drive(rng, road, epoch(2025, 12, 22, 8, 15, 0), kmh(110), zones, stops)
    evs = [Ev("hole", 3000, 5000, reacq=2, expect="timeGap", label="T1 control"),
           Ev("hole", 11990, 14600, reacq=3, expect=None, label="T2 1 h stop")]
    return road, smp, evs, dict(trips=[2, 2]), (
        "Motorway; T1 (2 km at 90 km/h, ~80 s hole) is a normal positive control. T2 (2.6 km) is closed: the "
        "car crawls in, stands ~150 m inside the portal for 60 min, then drives out at 60 km/h. The T2 hole is "
        "one step of ~2.65 km in ~3830 s: > 3600 s AND ~2.5 km/h < 15 km/h -> not a candidate (gap_free). "
        "-> exactly 1 timeGap. trips = 2: the >= 10 min recording hole splits the day (crawl speed <= 2 m/s "
        "means a 30 s checkpoint lands within 150 m of the last fix before the hole).")


@scenario
def bogus_overspeed_holes(rng):
    road = Road(46.0310, 8.9620, 15, 280, [
        (3000, 0, 0.002), (2000, 4, 0.006),    # T0 3000-5000 control
        (4000, -15, 0.0),
        (4200, 3, 0.004),                      # T(a) 9000-13200
        (4800, 12, 0.0),
        (2400, -2, 0.003),                     # T(b) 18000-20400
        (4600, -9, 0.0),
        (1600, 2, 0.003),                      # T(c) 25000-26600
        (3000, 0, 0.0), (1500, 0, 0.0)])
    zones = [zone_around(3000, 5000, 90)]
    smp = drive(rng, road, epoch(2025, 11, 7, 13, 30, 45), kmh(105), zones)
    evs = [Ev("hole", 3000, 5000, reacq=2, expect="timeGap", label="T0 control"),
           Ev("bogus", 9000, 13200, reacq=2, dt_stamp=30, label="a: 4.2 km in 30 s"),
           Ev("bogus", 18000, 20400, reacq=2, dt_stamp=22, label="b: 2.4 km in 22 s"),
           Ev("bogus", 25000, 26600, reacq=1, dt_stamp=12, label="c: 1.6 km in 12 s")]
    return road, smp, evs, dict(), (
        "Road at ~105 km/h; T0 is a normal tunnel hole (positive control, ~80 s / 2 km). Three more tunnels "
        "whose receiver clock froze while unlocked and never caught up (the lag persists for the rest of the "
        "file): (a) 4.2 km stamped 30 s (~510 km/h), (b) 2.4 km stamped 22 s (~400 km/h), (c) 1.6 km stamped "
        "12 s (~490 km/h). (a),(b): dt >= 20 but > 350 km/h -> rejected. (c): dt < 20 enters the staleClock "
        "branch but no clock jump >= 5 s follows within 20 points -> rejected. -> exactly 1 timeGap, 0 stale. "
        "Jitter 0: (c) opens a cluster (one forward 1.6 km jump, no reversal) that settles at the next "
        "fix; 1 jump and 0 reversals is below the emit rule.")


@scenario
def mountain_hairpins_tunnel(rng):
    segs = [(1500, 15, 0.05)]
    sign = 1
    for k in range(8):                         # ascending switchbacks
        segs += [(rng.uniform(330, 480), sign * 4, 0.075), (42, sign * 172, 0.04)]
        sign = -sign
    segs += [(900, 20, 0.05), (1200, -15, 0.03)]
    s_tun = sum(L for L, _, _ in segs)
    segs += [(1800, 5, 0.015)]                 # tunnel
    segs += [(1000, 25, -0.02), (800, -30, -0.04)]
    for k in range(6):                         # descending switchbacks
        segs += [(rng.uniform(300, 420), sign * 3, -0.07), (38, sign * 175, -0.04)]
        sign = -sign
    segs += [(1500, 0, -0.03)]
    road = Road(46.5290, 10.4530, 300, 1500, segs)
    # slow zones on every hairpin arc (+-35 m), 60 km/h in the tunnel
    zones = []
    s = 0.0
    for L, turn, _ in segs:
        if abs(turn) >= 150:
            zones.append((s - 35, s + L + 35, kmh(16)))
        s += L
    zones.append((s_tun - 250, s_tun + 1800 + 150, kmh(60)))
    smp = drive(rng, road, epoch(2025, 8, 23, 10, 18, 33), kmh(50), zones, accel=1.2, decel=1.6)
    evs = [Ev("hole", s_tun, s_tun + 1800, reacq=2, expect="timeGap", label="tunnel")]
    return road, smp, evs, dict(trips=[1, 1]), (
        "Alpine pass at 40-50 km/h: 8 ascending + 6 descending hairpins (172-175 deg turns on 38-42 m arcs, "
        "~16 km/h through the bends, legs 25-60 m apart) and one 1.8 km tunnel at <= 60 km/h (~135 s hole). "
        "Hairpins are real 180-degree reversals of direction but at 4-14 m per 1 s step, far below the 200 m "
        "reversal floor -> 0 jitter; exactly 1 timeGap (the tunnel), 0 stale, 0 replay, 1 trip.")


@scenario
def bunched_timestamps_tunnels(rng):
    road = Road(45.8120, 9.0850, 340, 300, [
        (3000, 0, 0.002), (1200, 10, 0.004),
        (2900, 3, 0.006),                      # T1 4200-7100
        (2500, -14, 0.0), (2000, 0, 0.002),
        (1800, -4, 0.005),                     # T2 11600-13400
        (3000, 12, 0.0), (1500, 0, -0.003),
        (3400, 2, 0.006),                      # T3 17900-21300
        (2500, 0, 0.0), (1200, 0, 0.0)])
    T = [(4200, 7100, 100), (11600, 13400, 80), (17900, 21300, 90)]
    zones = [zone_around(a, b, v) for a, b, v in T]
    smp = drive(rng, road, epoch(2026, 1, 30, 7, 55, 12), kmh(125), zones)
    evs = [Ev("hole", a, b, reacq=r, expect="timeGap", label="T%d" % (k + 1))
           for k, ((a, b, _), r) in enumerate(zip(T, (2, 3, 2)))]
    return road, smp, evs, dict(bunch=True), (
        "Same as highway_3tunnels_holes (125 km/h, tunnels 2.9 km, 1.8 km, 3.4 km = 80-140 s holes) but with "
        "Garmin timestamp sticking: runs of 1-4 consecutive 1 Hz fixes share one whole-second stamp, then the "
        "stamp jumps by the run length (dt = 0 steps of ~35 m, then 1-4 s steps). Same-stamp steps are < 150 m "
        "so they never reach either branch -> exactly 3 timeGap, 0 stale, 0 jitter (per-second medians "
        "advance steadily), 0 replay (positions all differ).")


@scenario
def tunnel_jam_speed_boundary(rng):
    road = Road(47.6930, 13.0420, 140, 480, [
        (3000, 0, 0.002), (2000, 2, 0.006),    # T1 3000-5000 slow (~20 km/h)
        (4000, -10, 0.0), (3000, 0, 0.002),
        (2000, -3, 0.006),                     # T2 12000-14000 very slow (~9 km/h)
        (2500, 8, 0.0), (1500, 0, 0.0)])
    zones = [(2500, 5150, kmh(22)), (11400, 14150, kmh(12))]
    stops = [(12700, 70), (13300, 80)]
    smp = drive(rng, road, epoch(2025, 8, 9, 9, 40, 2), kmh(110), zones, stops)
    evs = [Ev("hole", 3000, 5000, reacq=2, expect="timeGap", label="T1 ~20 km/h"),
           Ev("hole", 12000, 14000, reacq=2, expect=None, label="T2 ~9 km/h")]
    return road, smp, evs, dict(trips=[2, 2]), (
        "Holiday traffic: T1 (2 km) crawled at <= 22 km/h -> hole ~2 km in ~320 s = ~23 km/h >= 15 -> timeGap. "
        "T2 (2 km) in stop-and-go at <= 12 km/h with two 70-80 s standstills inside -> ~2 km in ~800 s = "
        "~9 km/h < 15 km/h -> not a candidate (gap_free). -> exactly 1 timeGap, 0 stale, 0 jitter. trips = 2: "
        "the T2 hole (~770 s) is a recording hole >= 10 min, and at <= 12 km/h crawl a 30 s trip checkpoint "
        "always lies within 150 m of the last fix before it.")


def main():
    expect = {"files": {}}
    summary = []
    for name, fn in FILES.items():
        rng = random.Random(SEED ^ zlib.crc32(name.encode()))
        road, smp, evs, opts, desc = fn(rng)
        pts = observe(rng, road, smp, evs)
        if opts.get("bunch"):
            pts = bunch_stamps(rng, pts)
            # bunching only rewrites stamps of points within a 1 Hz run; anchors keep their output index
        fname = name + ".gpx"
        pos, cover, free, _ = check_events(fname, pts, evs)
        nstale = sum(1 for e in evs if e.mode in ("stale", "stale2"))
        write_gpx(fname, name, pts)
        facts = []
        for ev in evs:
            info = getattr(ev, "info", None)
            if not info:
                continue
            if "segments" in info:
                facts.append("%s: " % ev.label + ", ".join("%d m/%d s" % (d, dt) for _, _, d, dt in info["segments"]))
            else:
                f = "%s: %d m/%d s/%.0f km/h" % (ev.label, info["meters"], info["seconds"], info["kmh"])
                if "stale_points" in info:
                    f += ", %d stale fixes, clock jump %d s" % (info["stale_points"], info["clock_jump"])
                if "second_jump" in info:
                    f += " then %d s (A->B1 alone %.0f km/h)" % (info["second_jump"], info["kmh_after_first_jump"])
                facts.append(f)
        if facts:
            desc += " [generated anchors A->B: " + "; ".join(facts) + "]"
        e = {
            "desc": desc,
            "points": len(pts),
            "profile": "deviceLogger",
            "gaps": [pos, pos],
            "stale": [nstale, nstale],
            "timegap": [pos - nstale, pos - nstale],
            "replays": [0, 0],
            "jitter": [0, 0],
            "load_ok": True,
        }
        if cover:
            e["gap_cover"] = cover
        if free:
            e["gap_free"] = free
        for k in ("merged", "trips"):
            if k in opts:
                e[k] = opts[k]
        expect["files"][fname] = e
        summary.append((fname, len(pts), pos, nstale, [(ev.label, getattr(ev, "info", None)) for ev in evs]))
    with open("expect.json", "w", encoding="utf-8") as f:
        json.dump(expect, f, ensure_ascii=False, indent=1)
        f.write("\n")
    for fname, n, pos, nstale, infos in summary:
        print("%-34s %6d pts  gaps=%d stale=%d" % (fname, n, pos, nstale))
        for label, info in infos:
            if info:
                print("    %-22s %s" % (label, {k: v for k, v in info.items() if k not in ("tA", "tB")}))


if __name__ == "__main__":
    main()
