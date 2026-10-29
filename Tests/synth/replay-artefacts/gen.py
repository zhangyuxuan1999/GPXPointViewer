#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Synthetic family "replay-artefacts": the phone / Garmin-Explore failure modes that
GapDetector.replayFlags and GapDetector.detectJitter are meant to catch, each with ground truth.

Run with this directory as cwd:   python3 -I gen.py
Deterministic (fixed seeds, no wall clock); stdlib only. Writes every data file, then expect.json,
then re-reads every file (xml.etree / csv) as a self-check.

Files
  a_explore_sweep.gpx               (a) Garmin Explore: 6 min replay of the last 3 km, triangle sweep, bit-identical, bunched stamps
  a2_explore_sawtooth_perturbed.gpx (a') same loss, replay restarts at the oldest stored fix every pass, coords moved 1-2 m
  g_explore_sweep_perturbed.gpx     (g) = (a) but every replayed coordinate moved 1-2 m (not bit-identical)
  b_phone_interleave.csv            (b) live stream + copy delayed 40 s (identical strings), alternating every 1-3 s for 5 min
  b2_phone_interleave_requant.csv   (b') = (b) but the delayed copy is re-quantised to 5 decimals (never bit-identical)
  c_tunnel_pingpong.csv             (c) 2 min alternating between two noisy network fixes 1 km apart, no time hole
  c2_tunnel_pingpong_cellfix.csv    (c') = (c) with two fixed (bit-identical) cell positions
  c3_tunnel_pingpong_x5.csv         (c'') five (c) tunnels in one drive (independent noise draws)
  d_cochem_dr_overshoot.csv         (d) dead reckoning runs ~1 km ahead in the tunnel, then snaps back at the portal
  e_outlier_lateral.gpx             (e) one fix 2 km to the side in a 1 Hz car trace (eTrex)
  e2_outlier_behind.gpx             (e') one fix 2 km behind in a 1 Hz car trace
  f_station_cached_replay.csv       (f) cached fixes re-emitted while standing in stations (no departure -> not a replay)
  h_sweep_10s.csv                   (h) the (a) sweep recorded by a phone at 10 s sampling
  i_hole_then_pingpong.csv          (i) 40 s time hole immediately followed by 90 s ping-pong
  j_long_pingpong.csv               (j) 20 min continuous ping-pong (longer than the 600 s cluster cap)
"""
import calendar
import csv
import json
import math
import random
import time
import xml.etree.ElementTree as ET

EARTH_R = 6371000.0
M_PER_DEG = EARTH_R * math.pi / 180.0      # same sphere as GeoMath.haversine


def deg_lon(lat):
    return M_PER_DEG * math.cos(math.radians(lat))


def hav(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(h)))


def bearing(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def epoch(y, mo, d, h=0, mi=0, s=0):
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))


# ---------------------------------------------------------------------------------- geometry / noise

class Path:
    """Smooth curve in local metres (x east, y north) around (lat0, lon0):
    heading(s) = theta0 + sum(a * sin(s / L + ph)), integrated every `step` metres."""

    def __init__(self, lat0, lon0, theta0, terms, length, step=2.0):
        self.lat0, self.lon0, self.step = lat0, lon0, step
        self.kx, self.ky = deg_lon(lat0), M_PER_DEG
        n = int(length / step) + 2
        xs, ys = [0.0], [0.0]
        x = y = 0.0
        for i in range(1, n):
            s = (i - 0.5) * step
            th = theta0 + sum(a * math.sin(s / L + ph) for a, L, ph in terms)
            x += step * math.cos(th)
            y += step * math.sin(th)
            xs.append(x)
            ys.append(y)
        self.xs, self.ys = xs, ys
        self.length = (n - 1) * step

    def xy(self, s):
        if s < 0 or s > self.length:
            raise ValueError('path too short: s=%.0f > %.0f' % (s, self.length))
        u = s / self.step
        i = min(int(u), len(self.xs) - 2)
        f = u - i
        return (self.xs[i] + (self.xs[i + 1] - self.xs[i]) * f,
                self.ys[i] + (self.ys[i + 1] - self.ys[i]) * f)

    def tangent(self, s):
        a, b = self.xy(max(0.0, s - 5)), self.xy(min(self.length, s + 5))
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = math.hypot(dx, dy)
        return dx / n, dy / n

    def ll(self, x, y):
        return self.lat0 + y / self.ky, self.lon0 + x / self.kx


class DeviceNoise:
    """Dedicated logger: slowly wandering bias (AR(1), ~3.3 m per axis) + 2 m white -> 3-8 m typical."""

    def __init__(self, rng):
        self.r, self.bx, self.by = rng, 0.0, 0.0

    def __call__(self):
        r = self.r
        self.bx = 0.97 * self.bx + r.gauss(0, 0.8)
        self.by = 0.97 * self.by + r.gauss(0, 0.8)
        return self.bx + r.gauss(0, 2.0), self.by + r.gauss(0, 2.0), 0


class PhoneNoise:
    """Phone: AR(1) bias (~9 m per axis at rho .95) + 6 m white -> 10-30 m typical, plus multipath excursions
    of 50-100 m that rise and fall over several samples (half-sine), i.e. the 50 m+ tail is temporally
    correlated as in real data and never a single-sample 200 m reversal. Returns (dx, dy, accuracy column)."""

    def __init__(self, rng, rate=0.012, ex_len=(4, 10), rho=0.95, white=6.0):
        self.r, self.rate, self.ex_len, self.rho, self.white = rng, rate, ex_len, rho, white
        self.bx = self.by = 0.0
        self.left = 0
        self.innov = 9.0 * math.sqrt(1 - rho * rho)

    def __call__(self):
        r = self.r
        self.bx = self.rho * self.bx + r.gauss(0, self.innov)
        self.by = self.rho * self.by + r.gauss(0, self.innov)
        ex = ey = 0.0
        if self.left <= 0 and r.random() < self.rate:
            self.len = r.randint(*self.ex_len)
            self.left = self.len
            self.amp = r.uniform(50.0, 100.0)
            self.dir = r.uniform(0, 2 * math.pi)
        excursion = self.left > 0
        if excursion:
            k = self.len - self.left + 1
            a = self.amp * math.sin(math.pi * k / (self.len + 1))
            ex, ey = a * math.cos(self.dir), a * math.sin(self.dir)
            self.left -= 1
        dx = self.bx + r.gauss(0, self.white) + ex
        dy = self.by + r.gauss(0, self.white) + ey
        if r.random() < 0.4:
            acc = 0                      # 一生足迹: about half the rows carry 0 = unknown
        else:
            acc = int(round(r.uniform(30, 65) if excursion else r.uniform(8, 25)))
        return dx, dy, acc


FMT = '%.7f'


def rec(lat, lon, ele, kind, **kw):
    r = {'lat': lat, 'lon': lon, 'las': FMT % lat, 'los': FMT % lon, 'ele': ele, 'kind': kind, 'acc': 0, 'loc': 1}
    r.update(kw)
    return r


def moved(rng, base, kind, dmin=1.0, dmax=2.0, **kw):
    """Copy of `base` displaced dmin..dmax metres in a random direction (guaranteed different strings)."""
    while True:
        ang, d = rng.uniform(0, 2 * math.pi), rng.uniform(dmin, dmax)
        lat = base['lat'] + d * math.sin(ang) / M_PER_DEG
        lon = base['lon'] + d * math.cos(ang) / deg_lon(base['lat'])
        r = rec(lat, lon, base['ele'], kind, acc=base.get('acc', 0), **kw)
        if r['las'] != base['las'] and r['los'] != base['los']:
            return r


def requant(base, kind, **kw):
    """Copy of `base` with coordinates written at 5 decimals (<= 0.56 m lat / 0.4 m lon away): never bit-identical."""
    las, los = '%.5f' % base['lat'], '%.5f' % base['lon']
    if float(las) == float(base['las']):
        las = '%.5f' % (float(las) + 1e-5)
    if float(los) == float(base['los']):
        los = '%.5f' % (float(los) + 1e-5)
    r = dict(base)
    r.update(las=las, los=los, lat=float(las), lon=float(los), kind=kind)
    r.update(kw)
    return r


def tri_index(tau, m):
    """Triangle sweep over stored[0..m-1] starting at the oldest: 0,1,..,m-1,m-2,..,1,0,1,.."""
    p = 2 * (m - 1)
    u = tau % p
    return u if u <= m - 1 else p - u


def bunch(recs, rng, t0):
    """Garmin second-resolution bunching: records are produced at a true 1 Hz (rec['k'] = true second) but
    written in batches of 1-4 that share the batch's first second; the stamp then jumps by the batch size
    (so stamps stick 1-4 s then jump, never by >= 5 s)."""
    i = 0
    while i < len(recs):
        g = rng.choices([1, 2, 3, 4], weights=[15, 20, 25, 40])[0]
        st = t0 + recs[i]['k']
        for r in recs[i:i + g]:
            r['t'] = st
        i += g


# ---------------------------------------------------------------------------------- writers

def write_gpx(fn, creator, name, recs):
    with open(fn, 'w', encoding='utf-8', newline='\n') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write('<gpx version="1.1" creator="%s" xmlns="http://www.topografix.com/GPX/1/1" '
                'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
                'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">\n' % creator)
        f.write(' <metadata><time>%s</time></metadata>\n' % iso(recs[0]['t']))
        f.write(' <trk>\n  <name>%s</name>\n  <trkseg>\n' % name)
        for r in recs:
            f.write('   <trkpt lat="%s" lon="%s"><ele>%.1f</ele><time>%s</time></trkpt>\n'
                    % (r['las'], r['los'], r['ele'], iso(r['t'])))
        f.write('  </trkseg>\n </trk>\n</gpx>\n')


CSV_HEADER = 'dataTime,locType,longitude,latitude,heading,accuracy,speed,distance,isBackForeground,stepType,altitude'


def write_csv(fn, recs):
    with open(fn, 'w', encoding='utf-8', newline='\n') as f:
        f.write(CSV_HEADER + '\n')
        prev = None
        for r in recs:
            lat, lon = float(r['las']), float(r['los'])
            if prev is None:
                d, spd, hd = 0.0, 0.0, 0.0
            else:
                d = hav(prev[1], prev[2], lat, lon)
                dt = r['t'] - prev[0]
                spd = d / dt if dt > 0 else 0.0
                hd = bearing(prev[1], prev[2], lat, lon) if d > 0 else 0.0
            f.write('%d,%d,%s,%s,%.1f,%d,%.2f,%.1f,%d,%d,%.1f\n'
                    % (r['t'], r.get('loc', 1), r['los'], r['las'], hd, r.get('acc', 0), spd, d,
                       r.get('bg', 1), 0, r['ele']))
            prev = (r['t'], lat, lon)


def max_step(recs, a=0, b=None):
    b = len(recs) if b is None else b
    m = 0.0
    for i in range(max(1, a), b):
        m = max(m, hav(float(recs[i - 1]['las']), float(recs[i - 1]['los']), float(recs[i]['las']), float(recs[i]['los'])))
    return m


# ---------------------------------------------------------------------------------- scenarios

def explore_sweep(seed, t0, mode, perturb):
    """Regional train at ~40 m/s (Koblenz-Trier style curves, R >= ~1.5 km), Garmin Explore, true 1 Hz with
    bunched stamps. 600 s live, then 360 s without fix in which the app re-emits its stored last 3 km
    (75 stored fixes, 1 per second = 40 m/s replay speed, i.e. 75 s per pass), then 600 s live again at the
    position the train really reached (14.4 km further)."""
    rng = random.Random(seed)
    path = Path(50.3530, 7.5700, math.radians(205), [(0.30, 2600.0, 0.0), (0.15, 950.0, 1.1)], 75000.0)
    noise = DeviceNoise(rng)
    PRE, LOSS, POST = 600, 360, 600
    N = PRE + LOSS + POST
    s = [500.0] * N
    for k in range(1, N):
        s[k] = s[k - 1] + 40.0 + 1.5 * math.sin(k / 97.0) + 0.8 * math.sin(k / 23.0 + 0.7)

    def ele(sv):
        return 72.0 + 9.0 * math.sin(sv / 2900.0) + 3.0 * math.sin(sv / 700.0)

    def fix(k):
        x, y = path.xy(s[k])
        dx, dy, _ = noise()
        lat, lon = path.ll(x + dx, y + dy)
        return rec(lat, lon, ele(s[k]), 'live', k=k)

    pre = [fix(k) for k in range(PRE)]
    stored = [r for r in pre if s[r['k']] >= s[PRE - 1] - 3000.0]
    m = len(stored)
    rep = []
    for tau in range(LOSS):
        idx = tri_index(tau, m) if mode == 'triangle' else tau % m
        b = stored[idx]
        if perturb:
            r = moved(rng, b, 'replay', k=PRE + tau)
        else:
            r = dict(b)
            r.update(kind='replay', k=PRE + tau)
        rep.append(r)
    post = [fix(k) for k in range(PRE + LOSS, N)]
    recs = pre + rep + post
    bunch(recs, rng, t0)
    return recs, {'T_loss': rep[0]['t'], 'T_resume': post[0]['t'], 'R': len(rep), 'stored': m,
                  'last_live': pre[-1]['t'], 'jump_back_m': round(hav(pre[-1]['lat'], pre[-1]['lon'], stored[0]['lat'], stored[0]['lon'])),
                  'resume_jump_m': round(hav(rep[-1]['lat'], rep[-1]['lon'], post[0]['lat'], post[0]['lon']))}


def phone_interleave(seed, t0, identical):
    """Regional train ~35 m/s, phone 1 Hz (foreground). For 5 min the location source alternates every 1-3 s
    between the live fix and a copy of the live fix from 40 s earlier (1.4 km behind)."""
    rng = random.Random(seed)
    path = Path(30.6200, 120.5600, math.radians(40), [(0.25, 3200.0, 0.0), (0.12, 1200.0, 2.0)], 60000.0)
    noise = PhoneNoise(rng)
    PRE, IL, POST, DELAY = 600, 300, 600, 40
    N = PRE + IL + POST
    s = [300.0] * N
    for k in range(1, N):
        s[k] = s[k - 1] + 35.0 + 2.0 * math.sin(k / 80.0)
    L = []
    for k in range(N):
        x, y = path.xy(s[k])
        dx, dy, acc = noise()
        lat, lon = path.ll(x + dx, y + dy)
        L.append(rec(lat, lon, 8.0 + 2.0 * math.sin(s[k] / 1500.0), 'live', k=k, acc=acc))
    out, written_live = [], set()
    src, left = 'live', 0
    for k in range(N):
        if PRE <= k < PRE + IL:
            if left == 0:
                src = 'delayed' if src == 'live' else 'live'
                left = rng.randint(1, 3)
            left -= 1
        else:
            src = 'live'
        if src == 'live':
            r = L[k]
            written_live.add(k)
        else:
            b = L[k - DELAY]
            if identical:
                r = dict(b)
                r.update(kind='delayed', k=k, src=k - DELAY)
            else:
                r = requant(b, 'delayed', k=k, src=k - DELAY)
        r['t'] = t0 + k
        out.append(r)
    delayed = [r for r in out if r['kind'] == 'delayed']
    E = sum(1 for r in delayed if r['src'] in written_live)
    return out, {'T1': t0 + PRE, 'T2': t0 + PRE + IL, 'delayed': len(delayed), 'E': E}


def phone_segments(seed, t0, path, s0, speed, segments, ele0=20.0):
    """1 Hz phone trace along `path`; the vehicle keeps moving through holes and ping-pong.
    segments: (kind, seconds, opts); kind in live | hole | pp.
    pp opts: offB (metres along the path from P = true position at pp start to Q), runs (min,max) samples per
    visit, first ('P'|'Q'), identical (P = last live fix string, Q = one fixed string), spot_noise (m)."""
    rng = random.Random(seed)
    noise = PhoneNoise(rng)
    out, meta = [], {'seg': []}
    k, s = 0, s0
    last_live = None
    for kind, dur, opt in segments:
        k_start = k
        if kind == 'pp':
            P, Q = path.xy(s), path.xy(s + opt['offB'])
            Pll, Qll = path.ll(*P), path.ll(*Q)
            meta['pp_spot_dist'] = round(hav(Pll[0], Pll[1], Qll[0], Qll[1]))
            if opt.get('identical'):
                Prec = dict(last_live)
                Qrec = rec(Qll[0], Qll[1], last_live['ele'], 'pp', loc=2, acc=414)
            cur = opt.get('first', 'P')
            left = rng.randint(*opt.get('runs', (1, 3)))
            meta['pp_count'] = 0
        for _ in range(dur):
            v = speed(k)
            if kind == 'live':
                x, y = path.xy(s)
                dx, dy, acc = noise()
                lat, lon = path.ll(x + dx, y + dy)
                r = rec(lat, lon, ele0 + 3.0 * math.sin(s / 900.0), 'live', acc=acc)
                last_live = r
            elif kind == 'pp':
                if left == 0:
                    cur = 'Q' if cur == 'P' else 'P'
                    left = rng.randint(*opt.get('runs', (1, 3)))
                left -= 1
                if opt.get('identical'):
                    r = dict(Prec if cur == 'P' else Qrec)
                    r.update(kind='pp', spot=cur)
                else:
                    cx, cy = P if cur == 'P' else Q
                    sn = opt.get('spot_noise', 12.0)
                    lat, lon = path.ll(cx + rng.gauss(0, sn), cy + rng.gauss(0, sn))
                    r = rec(lat, lon, ele0, 'pp', loc=2, spot=cur, acc=rng.choice([65, 165, 414, 1414]))
                meta['pp_count'] += 1
            else:
                r = None
            if r is not None:
                r['t'] = t0 + k
                out.append(r)
            k += 1
            s += v
        meta['seg'].append((kind, t0 + k_start, t0 + k))
    return out, meta


def phone_cochem(seed, t0):
    """RE Koblenz-Trier towards Cochem: 400 s live at 33 m/s; Kaiser-Wilhelm-Tunnel 110 s in which the true
    train brakes 33 -> 15 m/s (Cochem station is at the south portal) while the phone dead-reckons along the
    line at the entry speed (smooth, ~1 m noise) and ends up ~1 km ahead; at the portal the fix returns and
    the position snaps back ~1 km; then braking to a 90 s stop, departure, 300 s cruise."""
    rng = random.Random(seed)
    path = Path(50.1700, 7.1900, math.radians(250), [(0.12, 2500.0, 0.3), (0.05, 800.0, 1.0)], 40000.0)
    noise = PhoneNoise(rng)
    out = []
    k, s = 0, 200.0

    def live(n, vfun):
        nonlocal k, s
        for i in range(n):
            x, y = path.xy(s)
            dx, dy, acc = noise()
            lat, lon = path.ll(x + dx, y + dy)
            r = rec(lat, lon, 85.0 + 2.0 * math.sin(s / 700.0), 'live', acc=acc, t=t0 + k)
            out.append(r)
            k += 1
            s += vfun(i)

    live(400, lambda i: 33.0)
    T_e, s_e = t0 + k, s
    TUN = 110
    for i in range(TUN):
        dr_s = s_e + 33.0 * i
        x, y = path.xy(dr_s)
        lat, lon = path.ll(x + rng.gauss(0, 1.0), y + rng.gauss(0, 1.0))
        out.append(rec(lat, lon, 85.0, 'dr', acc=rng.choice([0, 0, 50, 65]), t=t0 + k))
        k += 1
        s += 33.0 - 18.0 * (i + 0.5) / TUN
    T_snap = t0 + k
    snap_m = hav(out[-1]['lat'], out[-1]['lon'], *path.ll(*path.xy(s)))
    overshoot = 33.0 * (TUN - 1) - (s - s_e)       # DR tip vs true position at the snap, along the line
    live(30, lambda i: max(0.0, 15.0 - 0.5 * (i + 1)))
    live(90, lambda i: 0.0)
    live(50, lambda i: 0.5 * (i + 1))
    live(300, lambda i: 25.0)
    return out, {'T_e': T_e, 'T_snap': T_snap, 'snap_m': round(snap_m), 'overshoot_true_m': round(overshoot)}


def device_outlier(seed, t0, where):
    """Car on a winding country road (R >= ~600 m) at 18-25 m/s, dedicated logger at a steady 1 Hz, 20 min;
    exactly one fix at minute 10 is 2 km away (`side`: perpendicular to travel; `behind`: back along the
    travel direction)."""
    rng = random.Random(seed)
    path = Path(47.7000, 11.1000, math.radians(70), [(0.55, 900.0, 0.0), (0.25, 320.0, 1.0)], 40000.0)
    noise = DeviceNoise(rng)
    N, KOUT = 1200, 600
    out = []
    s = 100.0
    for k in range(N):
        x, y = path.xy(s)
        dx, dy, _ = noise()
        if k == KOUT:
            tx, ty = path.tangent(s)
            if where == 'side':
                ox, oy = -ty * 2000.0, tx * 2000.0      # 90 deg to the left
            else:
                ox, oy = -tx * 2000.0, -ty * 2000.0
            lat, lon = path.ll(x + ox + dx, y + oy + dy)
            kind = 'outlier'
        else:
            lat, lon = path.ll(x + dx, y + dy)
            kind = 'live'
        out.append(rec(lat, lon, 640.0 + 25.0 * math.sin(s / 2200.0), kind, t=t0 + k))
        s += 21.5 + 3.5 * math.sin(k / 45.0)
    return out, {'T_out': t0 + KOUT, 'chord_m': round(hav(out[KOUT - 1]['lat'], out[KOUT - 1]['lon'], out[KOUT + 1]['lat'], out[KOUT + 1]['lon']))}


def phone_station(seed, t0):
    """S-Bahn style train, phone 1 Hz. Two station stops without fix:
    stop 1 (300 s): the phone keeps re-emitting 4 cached approach fixes (0-120 m before the stop, bit-identical
    strings, hops of up to ~130 m so the 50 m 'moving' test can pass) - the track never leaves 300 m, so no
    replay; stop 2 (180 s): one cached fix repeated (classic stationary cache, 'moving' test fails)."""
    rng = random.Random(seed)
    path = Path(31.2400, 121.3000, math.radians(-20), [(0.20, 2500.0, 0.5), (0.08, 700.0, 0.0)], 40000.0)
    noise = PhoneNoise(rng)
    out = []
    k, s = 0, 150.0
    meta = {}

    def move(n, vs, ve, tag):
        nonlocal k, s
        start = len(out)
        for i in range(n):
            x, y = path.xy(s)
            dx, dy, acc = noise()
            lat, lon = path.ll(x + dx, y + dy)
            out.append(rec(lat, lon, 4.0, 'live', acc=acc, t=t0 + k, s=s, phase=tag))
            k += 1
            s += vs + (ve - vs) * (i + 0.5) / n
        return start

    def cache_from(approach_start):
        stop_ll = path.ll(*path.xy(s))
        appr = out[approach_start:]
        chosen = []
        for target in (0.0, 40.0, 80.0, 120.0):
            best = None
            for r in appr:
                if r in chosen:
                    continue
                if hav(r['lat'], r['lon'], stop_ll[0], stop_ll[1]) > 130.0:
                    continue
                e = abs((s - r['s']) - target)
                if best is None or e < best[0]:
                    best = (e, r)
            if best is not None:
                chosen.append(best[1])
        # newest first: the last fix before the stop is the one re-emitted most often
        chosen.sort(key=lambda r: -r['t'])
        return chosen

    move(300, 30.0, 30.0, 'cruise')
    a1 = move(60, 30.0, 0.0, 'approach1')
    cache = cache_from(a1)
    st1 = len(out)
    for i in range(300):
        b = cache[0] if rng.random() < 0.5 else rng.choice(cache[1:])
        r = dict(b)
        r.update(kind='cache', t=t0 + k, phase='stop1')
        out.append(r)
        k += 1
    meta['stop1'] = (out[st1]['t'], out[-1]['t'] + 1)
    meta['stop1_cache_spread_m'] = round(max(hav(p['lat'], p['lon'], q['lat'], q['lon']) for p in cache for q in cache))
    meta['stop1_max_hop_m'] = round(max_step(out, st1, len(out)))
    move(60, 0.0, 30.0, 'depart1')
    move(300, 30.0, 30.0, 'cruise')
    a2 = move(60, 30.0, 0.0, 'approach2')
    last = out[-1]
    st2 = len(out)
    for i in range(180):
        r = dict(last)
        r.update(kind='cache', t=t0 + k, phase='stop2')
        out.append(r)
        k += 1
    meta['stop2'] = (out[st2]['t'], out[-1]['t'] + 1)
    move(60, 0.0, 30.0, 'depart2')
    move(200, 30.0, 30.0, 'cruise')
    meta['max_step_m'] = round(max_step(out))
    meta['cache_records'] = sum(1 for r in out if r['kind'] == 'cache')
    return out, meta


def phone_sweep_10s(seed, t0):
    """(a) recorded by a phone app at a fixed 10 s interval: train ~40 m/s (400 m per sample), 20 min live,
    6 min of replayed stored fixes (the last 3 km = 8 fixes, triangle sweep from the oldest, bit-identical,
    one stored fix per sample = 40 m/s replay speed, ~70 s per pass), 20 min live."""
    rng = random.Random(seed)
    path = Path(30.9000, 120.1000, math.radians(-60), [(0.25, 4000.0, 0.0), (0.10, 1500.0, 1.0)], 150000.0)
    noise = PhoneNoise(rng, rate=0.03, ex_len=(1, 2), rho=0.5)
    DT, PRE, LOSS, POST = 10, 120, 36, 120
    N = PRE + LOSS + POST
    s = [1000.0] * N
    for k in range(1, N):
        s[k] = s[k - 1] + DT * (40.0 + 2.0 * math.sin(k / 9.0))

    def fix(k):
        x, y = path.xy(s[k])
        dx, dy, acc = noise()
        lat, lon = path.ll(x + dx, y + dy)
        return rec(lat, lon, 12.0, 'live', k=k, acc=acc, bg=2)

    pre = [fix(k) for k in range(PRE)]
    stored = [r for r in pre if s[r['k']] >= s[PRE - 1] - 3000.0]
    m = len(stored)
    rep = []
    for tau in range(LOSS):
        r = dict(stored[tri_index(tau, m)])
        r.update(kind='replay', k=PRE + tau)
        rep.append(r)
    post = [fix(k) for k in range(PRE + LOSS, N)]
    recs = pre + rep + post
    for r in recs:
        r['t'] = t0 + DT * r['k']
    return recs, {'T_loss': rep[0]['t'], 'T_resume': post[0]['t'], 'R': len(rep), 'stored': m}


# ---------------------------------------------------------------------------------- main

def rng_range(lo, hi):
    return [int(lo), int(hi)]


def main():
    files = {}

    # ---------------- (a) Explore sweep, bit-identical, triangle
    recs, m = explore_sweep(101, epoch(2026, 5, 16, 7, 12), 'triangle', perturb=False)
    write_gpx('a_explore_sweep.gpx', 'Garmin Explore', 'RE1 Koblenz - Trier (replay sweep)', recs)
    R = m['R']
    files['a_explore_sweep.gpx'] = {
        'desc': ('(a) Garmin Explore (creator -> deviceLogger), train ~40 m/s, true 1 Hz with 1-4 points per '
                 'second-resolution stamp. Fix lost %d..%d (stamped): the app re-emits its stored last 3 km '
                 '(%d fixes, bit-identical strings) as a triangle sweep starting at the oldest fix (%d m back), '
                 '1 fix/s = 40 m/s, ~75 s per pass, %d replay records; then live resumes %d m away. '
                 'Accepted outcomes (spec): replayFlags marks >= 60%% of the %d replay records (only they can '
                 'match, so <= %d) and the sweep vanishes from the jitter scan (jitter 0 is fine), OR jitter '
                 'covers it -> jitter range 0..3, no jitter_cover. gaps exactly 0: no step has dt >= 20 s and '
                 'stamps never jump >= 5 s, so the staleClock search cannot find a clock jump. No cluster may '
                 'start in the clean live parts.'
                 % (m['T_loss'], m['T_resume'], m['stored'], m['jump_back_m'], R, m['resume_jump_m'], R, R)),
        'points': len(recs), 'profile': 'deviceLogger', 'gaps': [0, 0],
        'replays': rng_range(math.ceil(0.6 * R), R), 'jitter': [0, 3],
        'jitter_free': [[recs[0]['t'], m['T_loss'] - 10], [m['T_resume'] + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (a') sawtooth, perturbed
    recs, m = explore_sweep(102, epoch(2026, 5, 17, 7, 12), 'sawtooth', perturb=True)
    write_gpx('a2_explore_sawtooth_perturbed.gpx', 'Garmin Explore', 'RE1 Koblenz - Trier (replay restarts)', recs)
    files['a2_explore_sawtooth_perturbed.gpx'] = {
        'desc': ('(a variant) same loss %d..%d, but each pass restarts at the oldest stored fix (3 km reversal '
                 'every %d s: 5 restarts incl. the first) and every replayed fix is moved 1-2 m (not '
                 'bit-identical) -> replays 0. This is the shape the 90 s merge window was designed for: one '
                 'reversal cluster per restart, consecutive clusters ~75 s apart merge into one that spans at '
                 'least first restart..last restart (300 of 360 s, IoU ~0.83 with the loss interval). The final '
                 'forward jump to the live position is not a reversal, so it may or may not add a cluster -> '
                 'jitter 1..2.' % (m['T_loss'], m['T_resume'], m['stored'])),
        'points': len(recs), 'profile': 'deviceLogger', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 2],
        'jitter_cover': [[m['T_loss'], m['T_resume']]],
        'jitter_free': [[recs[0]['t'], m['T_loss'] - 10], [m['T_resume'] + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (g) triangle, perturbed
    recs, m = explore_sweep(107, epoch(2026, 5, 18, 7, 12), 'triangle', perturb=True)
    write_gpx('g_explore_sweep_perturbed.gpx', 'Garmin Explore', 'RE1 Koblenz - Trier (perturbed sweep)', recs)
    files['g_explore_sweep_perturbed.gpx'] = {
        'desc': ('(g) the (a) triangle sweep (%d..%d) with every replayed coordinate moved 1-2 m -> replays 0 '
                 '(nothing bit-identical). Spec: a jitter cluster must be present. The sweep starts with a %d m '
                 'reversal (oldest stored fix) which opens a cluster; the triangle turn-arounds themselves are '
                 'gradual (40 m per fix) and the passes run at the train speed, so full coverage of the 6 min is '
                 'NOT expected from per-step jump/reversal tests -> jitter 1..4, no jitter_cover.'
                 % (m['T_loss'], m['T_resume'], m['jump_back_m'])),
        'points': len(recs), 'profile': 'deviceLogger', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 4],
        'jitter_free': [[recs[0]['t'], m['T_loss'] - 10], [m['T_resume'] + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (b) interleave, identical
    recs, m = phone_interleave(201, epoch(2026, 6, 2, 1, 30), identical=True)
    write_csv('b_phone_interleave.csv', recs)
    E = m['E']
    files['b_phone_interleave.csv'] = {
        'desc': ('(b) phone CSV (accuracy column -> phone), regional train ~35 m/s at 1 Hz. %d..%d the source '
                 'alternates every 1-3 s between the live fix and a bit-identical copy of the fix from 40 s '
                 'earlier (1.4 km behind): %d delayed records, of which %d copy a fix that was itself written '
                 '(the others copy a moment when the delayed stream was being written, so they match nothing). '
                 'Those %d are textbook replays (40 s old, track 1.4 km away in between, moving) -> replays '
                 '>= 90%% of %d, <= %d. The unflagged delayed records still alternate with the live ones, so a '
                 'jitter cluster must cover the 5 min (IoU >= 0.5); 1..3 clusters allowed (90 s merge).'
                 % (m['T1'], m['T2'], m['delayed'], E, E, E, E)),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0],
        'replays': rng_range(math.floor(0.9 * E), E), 'jitter': [1, 3],
        'jitter_cover': [[m['T1'], m['T2']]],
        'jitter_free': [[recs[0]['t'], m['T1'] - 10], [m['T2'] + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (b') interleave, requantised
    recs, m = phone_interleave(202, epoch(2026, 6, 3, 1, 30), identical=False)
    write_csv('b2_phone_interleave_requant.csv', recs)
    files['b2_phone_interleave_requant.csv'] = {
        'desc': ('(b variant) same interleave %d..%d (%d delayed records) but the delayed stream writes its '
                 'coordinates at 5 decimals, so nothing is bit-identical -> replays 0 and the whole job falls '
                 'to detectJitter: 1.4 km reversals every 1-3 s for 5 min -> cluster(s) covering it (IoU >= 0.5).'
                 % (m['T1'], m['T2'], m['delayed'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 3],
        'jitter_cover': [[m['T1'], m['T2']]],
        'jitter_free': [[recs[0]['t'], m['T1'] - 10], [m['T2'] + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (c) tunnel ping-pong, noisy spots
    car = Path(46.8000, 9.8000, math.radians(30), [(0.60, 900.0, 0.0), (0.30, 300.0, 1.0)], 40000.0)
    t0 = epoch(2026, 7, 4, 9, 0)
    recs, m = phone_segments(301, t0, car, 200.0, lambda k: 25.0 + 2.0 * math.sin(k / 60.0),
                             [('live', 300, {}), ('pp', 120, {'offB': 1000.0, 'runs': (1, 3)}), ('live', 300, {})])
    write_csv('c_tunnel_pingpong.csv', recs)
    pa, pb = m['seg'][1][1], m['seg'][1][2]
    files['c_tunnel_pingpong.csv'] = {
        'desc': ('(c) phone 1 Hz, car ~25 m/s in a tunnel: %d..%d (120 s, %d records, no time hole) the fixes '
                 'alternate (runs of 1-3) between two network positions %d m apart (tunnel entry and 1 km '
                 'further), each with ~12 m scatter (not bit-identical -> replays 0); the car meanwhile drives '
                 '3 km. Exactly one cluster covering the ping-pong (IoU >= 0.5). Phone profile -> staleClock off, '
                 'no dt >= 20 s -> gaps 0.' % (pa, pb, m['pp_count'], m['pp_spot_dist'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 1],
        'jitter_cover': [[pa, pb]],
        'jitter_free': [[recs[0]['t'], pa - 10], [pb + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (c') tunnel ping-pong, bit-identical cell positions
    t0 = epoch(2026, 7, 5, 9, 0)
    recs, m = phone_segments(302, t0, car, 200.0, lambda k: 25.0 + 2.0 * math.sin(k / 60.0),
                             [('live', 300, {}), ('pp', 120, {'offB': 1000.0, 'runs': (1, 3), 'identical': True}),
                              ('live', 300, {})])
    write_csv('c2_tunnel_pingpong_cellfix.csv', recs)
    pa, pb = m['seg'][1][1], m['seg'][1][2]
    files['c2_tunnel_pingpong_cellfix.csv'] = {
        'desc': ('(c variant) as (c) %d..%d but the two positions are fixed strings: P = the last live fix '
                 '(cached), Q = one cell position %d m ahead. Ping-pong points ~10 s after a visit to the other '
                 'spot satisfy every replay criterion, the rest do not, so the split between replayFlags and '
                 'detectJitter depends on the visit order -> wide ranges: replays 0..%d, jitter 0..2; only '
                 'no-crash, invariants and no clusters in the clean parts are firm.'
                 % (pa, pb, m['pp_spot_dist'], m['pp_count'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, m['pp_count']], 'jitter': [0, 2],
        'jitter_free': [[recs[0]['t'], pa - 10], [pb + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (c'') five tunnels of (c) in one drive: one seed must not decide the verdict
    road = Path(46.5000, 9.6000, math.radians(40), [(0.60, 900.0, 0.0), (0.30, 300.0, 1.0)], 100000.0)
    t0 = epoch(2026, 7, 6, 7, 0)
    segs = [('live', 300, {})]
    for q in range(5):
        segs += [('pp', 120, {'offB': 1000.0, 'runs': (1, 3)}), ('live', 600 if q < 4 else 300, {})]
    recs, m = phone_segments(303, t0, road, 200.0, lambda k: 25.0 + 2.0 * math.sin(k / 60.0), segs)
    write_csv('c3_tunnel_pingpong_x5.csv', recs)
    pps = [(a, b) for kind, a, b in m['seg'] if kind == 'pp']
    lives = [(a, b) for kind, a, b in m['seg'] if kind == 'live']
    files['c3_tunnel_pingpong_x5.csv'] = {
        'desc': ('(c variant) the (c) tunnel ping-pong five times in one 1 h drive (other noise draws), 10 min of '
                 'clean driving between tunnels so nothing merges: %s. Each tunnel must get exactly one cluster '
                 'covering it (IoU >= 0.5) -> jitter exactly 5; none may start in the clean parts. Same physics '
                 'as (c), but five independent draws, so a pass/fail here does not hinge on one seed.'
                 % ', '.join('%d..%d' % ab for ab in pps)),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [5, 5],
        'jitter_cover': [[a, b] for a, b in pps],
        'jitter_free': [[recs[0]['t'], lives[0][1] - 10]] + [[a + 30, b - 10] for a, b in lives[1:-1]]
                       + [[lives[-1][0] + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (d) Cochem dead-reckoning overshoot
    recs, m = phone_cochem(401, epoch(2026, 8, 9, 10, 5))
    write_csv('d_cochem_dr_overshoot.csv', recs)
    files['d_cochem_dr_overshoot.csv'] = {
        'desc': ('(d) phone 1 Hz, RE at 33 m/s into the Kaiser-Wilhelm-Tunnel at %d; in the tunnel the phone '
                 'dead-reckons smoothly at the entry speed while the train brakes, at %d the fix returns and '
                 'the position snaps back %d m (true overshoot %d m), then a 90 s station stop. The DR stretch '
                 'is smooth and indistinguishable step by step; the snap is a ~1 km reversal -> 1 cluster at '
                 'the snap (A = DR tip, B = first real fix); a second one is tolerated -> jitter 1..2, and no '
                 'cluster may start before the tunnel or after the snap (location check without assuming '
                 'whether a future detector also claims the DR stretch). Ground-truth garbage: %d..%d.'
                 % (m['T_e'], m['T_snap'], m['snap_m'], m['overshoot_true_m'], m['T_e'], m['T_snap'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 2],
        'jitter_free': [[recs[0]['t'], m['T_e'] - 5], [m['T_snap'] + 5, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (e) single outlier, lateral
    recs, m = device_outlier(501, epoch(2026, 9, 12, 8, 0), 'side')
    write_gpx('e_outlier_lateral.gpx', 'eTrex 32x', 'Landstrasse (outlier)', recs)
    files['e_outlier_lateral.gpx'] = {
        'desc': ('(e) eTrex (creator -> deviceLogger), car 18-25 m/s on a winding road at a steady 1 Hz; the '
                 'single fix at %d is 2 km to the LEFT of the road (out and straight back). Spec: exactly one '
                 'cluster A = %d .. B = %d (chord %d m = two normal steps, i.e. noise level). No clock jump at '
                 '1 Hz -> no staleClock; replays 0.' % (m['T_out'], m['T_out'] - 1, m['T_out'] + 1, m['chord_m'])),
        'points': len(recs), 'profile': 'deviceLogger', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 1],
        'jitter_cover': [[m['T_out'] - 1, m['T_out'] + 1]],
        'jitter_free': [[recs[0]['t'], m['T_out'] - 3], [m['T_out'] + 2, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (e') single outlier, behind
    recs, m = device_outlier(502, epoch(2026, 9, 13, 8, 0), 'behind')
    write_gpx('e2_outlier_behind.gpx', 'eTrex 32x', 'Landstrasse (outlier behind)', recs)
    files['e2_outlier_behind.gpx'] = {
        'desc': ('(e variant) as (e) but the single fix at %d lies 2 km BEHIND the car (a 2 km reversal and '
                 'back) -> exactly one cluster %d..%d (chord %d m).'
                 % (m['T_out'], m['T_out'] - 1, m['T_out'] + 1, m['chord_m'])),
        'points': len(recs), 'profile': 'deviceLogger', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [1, 1],
        'jitter_cover': [[m['T_out'] - 1, m['T_out'] + 1]],
        'jitter_free': [[recs[0]['t'], m['T_out'] - 3], [m['T_out'] + 2, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (f) cached fixes at stations
    recs, m = phone_station(601, epoch(2026, 6, 20, 0, 45))
    write_csv('f_station_cached_replay.csv', recs)
    assert m['max_step_m'] < 200, m     # no step can reach the 200 m reversal / 300 m jump floors -> jitter 0
    files['f_station_cached_replay.csv'] = {
        'desc': ('(f) phone 1 Hz, train 30 m/s with two stops without fix. Stop 1 %d..%d: 4 cached approach '
                 'fixes (spread %d m, hops up to %d m, bit-identical strings) re-emitted for 300 s - repeats are '
                 '>= 10 s apart and some hops pass the 50 m moving test, but the track never departs 300 m '
                 'from them -> not replays. Stop 2 %d..%d: the last fix repeated for 180 s (neighbour 10 s '
                 'earlier is the same spot -> not moving). %d cached records in all -> replays exactly 0. '
                 'Largest step in the whole file %d m < the 200 m reversal floor -> jitter exactly 0.'
                 % (m['stop1'][0], m['stop1'][1], m['stop1_cache_spread_m'], m['stop1_max_hop_m'],
                    m['stop2'][0], m['stop2'][1], m['cache_records'], m['max_step_m'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [0, 0],
        'load_ok': True,
    }

    # ---------------- (h) sweep at 10 s sampling
    recs, m = phone_sweep_10s(801, epoch(2026, 10, 3, 2, 0))
    write_csv('h_sweep_10s.csv', recs)
    R = m['R']
    files['h_sweep_10s.csv'] = {
        'desc': ('(h) phone CSV at a fixed 10 s interval, train ~40 m/s (400 m per sample). %d..%d: %d '
                 'replay records sweeping the stored last 3 km (%d fixes, bit-identical, triangle from the '
                 'oldest). Visits to the newest stored fix equal the last live fix position, so they fail the '
                 '50 m moving test; every other replay record is moving, >= 10 s after its original and '
                 'separated by a >= 300 m departure -> replays >= 60%% of %d. As in (a) either outcome is '
                 'acceptable for the jitter scan -> 0..2. 10 s steps, phone -> gaps 0.'
                 % (m['T_loss'], m['T_resume'], R, m['stored'], R)),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0],
        'replays': rng_range(math.ceil(0.6 * R), R), 'jitter': [0, 2],
        'jitter_free': [[recs[0]['t'], m['T_loss'] - 30], [m['T_resume'] + 60, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (i) hole then ping-pong
    t0 = epoch(2026, 7, 11, 6, 30)
    recs, m = phone_segments(901, t0, car, 300.0, lambda k: 25.0 + 1.5 * math.sin(k / 50.0),
                             [('live', 300, {}), ('hole', 40, {}),
                              ('pp', 90, {'offB': -800.0, 'runs': (1, 3), 'first': 'P'}), ('live', 300, {})])
    write_csv('i_hole_then_pingpong.csv', recs)
    ha, hb = m['seg'][1][1], m['seg'][1][2]
    pa, pb = m['seg'][2][1], m['seg'][2][2]
    files['i_hole_then_pingpong.csv'] = {
        'desc': ('(i) phone 1 Hz, car ~25 m/s: no records %d..%d (40 s, ~1 km driven), then immediately '
                 '%d..%d ping-pong between the true position after the hole and a network fix %d m back. The '
                 'step over the hole is a timeGap (~1 km / 40 s, ~90 km/h); ping-pong steps are 1 s so they are '
                 'never timeGaps and staleClock is off for phones -> gaps exactly 1. The ping-pong starts right '
                 'after a hole, i.e. with an empty jitter reference window -> jitter 0..3 (no firm claim); '
                 'candidates (gaps + kept jitter) 1..4. No cluster in the clean parts.'
                 % (ha - 1, hb, pa, pb, m['pp_spot_dist'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [1, 1], 'replays': [0, 0], 'jitter': [0, 3],
        'candidates': [1, 4],
        'jitter_free': [[recs[0]['t'], ha - 10], [pb + 30, recs[-1]['t']]],
        'load_ok': True,
    }

    # ---------------- (j) 20 min continuous ping-pong
    rail = Path(31.0000, 119.8000, math.radians(10), [(0.20, 3500.0, 0.0), (0.10, 1300.0, 2.0)], 80000.0)
    t0 = epoch(2026, 8, 30, 3, 0)
    recs, m = phone_segments(1001, t0, rail, 500.0, lambda k: 30.0 + 2.0 * math.sin(k / 70.0),
                             [('live', 300, {}), ('pp', 1200, {'offB': 1200.0, 'runs': (1, 4)}), ('live', 300, {})])
    write_csv('j_long_pingpong.csv', recs)
    pa, pb = m['seg'][1][1], m['seg'][1][2]
    files['j_long_pingpong.csv'] = {
        'desc': ('(j) phone 1 Hz, train ~30 m/s: 20 min (%d..%d, %d records) of continuous ping-pong between '
                 'two noisy fixes %d m apart, no time hole. Longer than the 600 s cluster cap, so clusters get '
                 'abandoned/restarted and merged; no fixed count is claimed. Merged clusters are > 90 s apart, '
                 'so at most ~15 fit -> jitter 0..15; none may start in the clean live parts (so none can be '
                 'longer than the garbage); replays 0, gaps 0; whole pipeline < 10 s.'
                 % (pa, pb, m['pp_count'], m['pp_spot_dist'])),
        'points': len(recs), 'profile': 'phone', 'gaps': [0, 0], 'replays': [0, 0], 'jitter': [0, 15],
        'jitter_free': [[recs[0]['t'], pa - 10], [pb + 30, recs[-1]['t']]],
        'max_total_seconds': 10,
        'load_ok': True,
    }

    with open('expect.json', 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'family': 'replay-artefacts', 'files': files}, f, ensure_ascii=False, indent=1)
        f.write('\n')
    verify(files)


def verify(files):
    """Self-check: every file parses (XML / CSV), point counts match expect.json, times are non-decreasing."""
    ns = '{http://www.topografix.com/GPX/1/1}'
    for name, spec in sorted(files.items()):
        ts = []
        if name.endswith('.gpx'):
            root = ET.parse(name).getroot()
            assert root.tag == ns + 'gpx', name
            for p in root.iter(ns + 'trkpt'):
                float(p.get('lat')); float(p.get('lon'))
                ts.append(calendar.timegm(time.strptime(p.find(ns + 'time').text, '%Y-%m-%dT%H:%M:%SZ')))
        else:
            with open(name, newline='', encoding='utf-8') as f:
                rd = csv.reader(f)
                assert next(rd) == CSV_HEADER.split(','), name
                for row in rd:
                    assert len(row) == 11, (name, row)
                    float(row[2]); float(row[3])
                    ts.append(int(row[0]))
        assert len(ts) == spec['points'], (name, len(ts), spec['points'])
        assert all(a <= b for a, b in zip(ts, ts[1:])), name + ': time not sorted'
        print('%-36s %6d points  %s .. %s' % (name, len(ts), iso(ts[0]), iso(ts[-1])))


if __name__ == '__main__':
    main()
