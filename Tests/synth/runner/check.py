#!/usr/bin/env python3
"""Synthetic-data checker for the GPXPointViewer gap / replay / jitter detectors.

Discovers every family directory under ROOT (default: the parent of this script's
directory) that contains an expect.json, runs the compiled `synthrunner` as a
SUBPROCESS per data file (so a Swift trap in one file is isolated and reported as
CRASH with the last pipeline stage), and compares the runner's JSON line with the
expectations.

expect.json
    {"files": {"<name>": {
        "desc": "...",
        "points": N | [min,max],             # TrackData.count
        "profile": "deviceLogger|phone|unknown|any" | [allowed, ...],
        "gaps": [min,max],                   # timeGap + staleClock candidates (raw GapDetector.detect)
        "replays": [min,max],                # replayFlags count
        "jitter": [min,max],                 # detectJitter cluster count (raw)
        "jitter_cover": [[tA,tB], ...],      # each covered by a jitter candidate with IoU >= 0.5
        "jitter_free": [[tA,tB], ...],       # no jitter candidate may START (tA) inside
        "load_ok": true|false,               # false: parser may reject (an error line is fine), must not crash
        "max_load_seconds": s                # read + parse + TrackData.build
    }}}
    A range is [min,max] (max may be null = unbounded), [min], or a bare integer (exact).
    Extensions (optional): "stale", "timegap", "merged", "trips", "timed", "candidates",
    "jitter_kept" as ranges; "gap_cover"/"gap_free" like jitter_cover/jitter_free but on
    timeGap/staleClock candidates; "max_total_seconds" for the whole pipeline.

Independent of expect.json, every loaded file is checked against detector invariants
(indices inside [0, timed), timeGap = consecutive points with dt >= 20 s, >= 150 m,
15-350 km/h, dt <= 3600 s, candidates sorted and non-overlapping, ...). Data files
(*.gpx, *.csv) present in a family directory but not listed in expect.json are run
as crash + invariant checks only.

If load_ok is false and the file nevertheless loads, the other expectations are
reported as soft notes, not failures.

Exit code: 0 all ok, 1 any FAIL/CRASH/TIMEOUT/MISSING/ERROR, 2 usage problem.
"""
import argparse
import concurrent.futures as cf
import fnmatch
import json
import math
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
DEFAULT_RUNNER = os.path.join(HERE, "synthrunner")
DATA_EXT = {".gpx", ".csv"}
SKIP_DIRS = {"__pycache__", ".git"}

INF = float("inf")


def _jitter_count(r):
    return r.get("jitter_count", len(r.get("jitter") or []))


# expect key -> runner value
RANGE_KEYS = {
    "gaps": lambda r: r["gaps"],
    "replays": lambda r: r["replays"],
    "jitter": _jitter_count,
    "stale": lambda r: r["stale"],
    "timegap": lambda r: r.get("timegap", r["gaps"] - r["stale"]),
    "merged": lambda r: r["merged"],
    "trips": lambda r: r["trips"],
    "timed": lambda r: r["timed"],
    "candidates": lambda r: r.get("candidates"),
    "jitter_kept": lambda r: r.get("jitter_kept"),
}
KNOWN_KEYS = set(RANGE_KEYS) | {
    "desc", "points", "profile", "load_ok", "max_load_seconds", "max_total_seconds",
    "jitter_cover", "jitter_free", "gap_cover", "gap_free",
}
PROFILES = {"deviceLogger", "phone", "unknown", "any"}
OK_STATUSES = {"ok"}
NOTE_PREFIXES = ("soft", "unknown expect", "not in expect", "jitter list truncated")


# ---------------------------------------------------------------- helpers

def parse_range(v):
    """-> (lo, hi) or raise ValueError."""
    if isinstance(v, bool):
        raise ValueError("bool is not a range")
    if isinstance(v, (int, float)):
        return (v, v)
    if isinstance(v, (list, tuple)) and 1 <= len(v) <= 2:
        lo = v[0] if v[0] is not None else -INF
        hi = v[1] if len(v) == 2 and v[1] is not None else INF
        if not isinstance(lo, (int, float)) or not isinstance(hi, (int, float)) or isinstance(lo, bool) or isinstance(hi, bool):
            raise ValueError("range bounds must be numbers or null")
        if lo > hi:
            raise ValueError("min > max")
        return (lo, hi)
    raise ValueError("expected N, [min,max] or [min]")


def fmt_range(lo, hi):
    if lo == hi:
        return str(lo)
    return "[%s,%s]" % ("" if lo == -INF else lo, "" if hi == INF else hi)


def parse_intervals(v):
    if not isinstance(v, list):
        raise ValueError("expected [[tA,tB], ...]")
    out = []
    for it in v:
        if (not isinstance(it, (list, tuple)) or len(it) != 2
                or not all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in it)):
            raise ValueError("bad interval %r" % (it,))
        a, b = float(it[0]), float(it[1])
        if a > b:
            a, b = b, a
        out.append((a, b))
    return out


def iou(a0, a1, b0, b1):
    inter = max(0.0, min(a1, b1) - max(a0, b0))
    union = max(a1, b1) - min(a0, b0)
    if union <= 0:
        return 1.0 if (a0 == b0 and a1 == b1) else 0.0
    return inter / union


def sig_name(rc):
    try:
        return signal.Signals(-rc).name
    except Exception:
        return "signal %d" % -rc


def short(s, n=160):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


# ---------------------------------------------------------------- discovery

def discover(root, fam_filters, file_filters):
    """-> (families, tasks, errors). task = dict(family, name, path, expect|None)."""
    families, tasks, errors = [], [], []
    try:
        entries = sorted(os.listdir(root))
    except OSError as e:
        return [], [], [("?", "?", "ERROR", ["cannot list root %s: %s" % (root, e)])]
    for fam in entries:
        fdir = os.path.join(root, fam)
        if fam in SKIP_DIRS or fam.startswith(".") or not os.path.isdir(fdir):
            continue
        if os.path.abspath(fdir) == HERE:
            continue
        exp_path = os.path.join(fdir, "expect.json")
        if not os.path.isfile(exp_path):
            continue
        if fam_filters and not any(fnmatch.fnmatchcase(fam, f) for f in fam_filters):
            continue
        families.append(fam)
        try:
            with open(exp_path, "rb") as fh:
                exp = json.loads(fh.read().decode("utf-8"))
            files = exp["files"]
            if not isinstance(files, dict):
                raise ValueError('"files" must be an object')
        except Exception as e:
            errors.append((fam, "expect.json", "ERROR", ["unreadable expect.json: %s" % short(e)]))
            continue
        listed = set()
        for name, spec in files.items():
            listed.add(os.path.normpath(name))
            if not want_file(fam, name, file_filters):
                continue
            tasks.append({"family": fam, "name": name, "path": os.path.join(fdir, name),
                          "expect": spec if isinstance(spec, dict) else {"__bad__": spec}})
        # unlisted data files: crash + invariant check only
        for dp, dns, fns in os.walk(fdir):
            dns[:] = sorted(d for d in dns if d not in SKIP_DIRS and not d.startswith("."))
            for fn in sorted(fns):
                if os.path.splitext(fn)[1].lower() not in DATA_EXT or fn.startswith("."):
                    continue
                rel = os.path.normpath(os.path.relpath(os.path.join(dp, fn), fdir))
                if rel in listed or not want_file(fam, rel, file_filters):
                    continue
                tasks.append({"family": fam, "name": rel, "path": os.path.join(fdir, rel), "expect": None})
    return families, tasks, errors


def want_file(fam, name, file_filters):
    if not file_filters:
        return True
    base = os.path.basename(name)
    for f in file_filters:
        if fnmatch.fnmatchcase(name, f) or fnmatch.fnmatchcase(base, f) or fnmatch.fnmatchcase(fam + "/" + name, f):
            return True
    return False


# ---------------------------------------------------------------- running

def run_one(runner, task, timeout):
    path = task["path"]
    t0 = time.monotonic()
    rec = {"family": task["family"], "file": task["name"], "path": path}
    if not os.path.exists(path):
        rec.update(status="MISSING", failures=["file not found (did gen.py run?)"], notes=[])
        return rec
    exp = task["expect"] or {}
    lim = timeout
    for key in ("max_load_seconds", "max_total_seconds"):
        if _num(exp.get(key)) > 0:
            lim = max(lim, 5 * _num(exp.get(key)) + 30)
    try:
        p = subprocess.run([runner, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=lim)
        out, err, rc = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        err = (e.stderr or b"").decode("utf-8", "replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        rec.update(status="TIMEOUT", failures=["runner exceeded %.0f s (last stage: %s)" % (lim, last_stage(err))],
                   notes=[], wall=time.monotonic() - t0)
        return rec
    rec["wall"] = time.monotonic() - t0
    err_s = err.decode("utf-8", "replace")
    res = None
    for line in reversed(out.decode("utf-8", "replace").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                res = json.loads(line)
                break
            except json.JSONDecodeError as e:
                rec["bad_json"] = short(e)
    if rc != 0 or res is None:
        why = ("killed by %s" % sig_name(rc)) if rc < 0 else ("exit %d" % rc if rc != 0 else "no JSON on stdout")
        if rc == 0 and rec.get("bad_json"):
            why += " (unparseable: %s)" % rec["bad_json"]
        msgs = [l for l in err_s.splitlines() if l.strip() and not l.startswith("@stage")]
        detail = "%s at stage '%s'" % (why, last_stage(err_s))
        if msgs:
            detail += ": " + short(" | ".join(msgs[-3:]), 300)
        rec.update(status="CRASH", failures=[detail], notes=[])
        return rec
    rec["result"] = res
    return rec


def _num(x):
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) else 0.0


def last_stage(err):
    st = [l[7:].strip() for l in err.splitlines() if l.startswith("@stage ")]
    return st[-1] if st else "startup"


# ---------------------------------------------------------------- checking

def invariants(r):
    """Detector contract checks that hold for any input. -> list of failure strings."""
    bad = []
    pts, timed = r.get("points", 0), r.get("timed", 0)
    if not (0 <= timed <= pts):
        bad.append("timed %s not in [0, points %s]" % (timed, pts))
    if not (0 <= r.get("stale", 0) <= r.get("gaps", 0)):
        bad.append("stale %s > gaps %s" % (r.get("stale"), r.get("gaps")))
    if not (0 <= r.get("replays", 0) <= timed):
        bad.append("replays %s > timed %s" % (r.get("replays"), timed))
    if r.get("merged", 0) > r.get("candidates", r.get("merged", 0)):
        bad.append("merged %s > candidates %s" % (r.get("merged"), r.get("candidates")))
    for k, v in (r.get("ms") or {}).items():
        if v is None or v < 0:
            bad.append("ms.%s = %s" % (k, v))
    tr = r.get("time_range")
    if timed > 0 and tr and tr[0] is not None and tr[1] is not None and tr[0] > tr[1]:
        bad.append("time not sorted: first %s > last %s" % tuple(tr))
    eps = 0.051  # runner rounds metres / km/h to 0.1

    def idx_ok(c, what):
        ia, ib = c.get("iA"), c.get("iB")
        if ia is None or ib is None:
            bad.append("%s missing global indices" % what)
            return False
        if not (0 <= ia < ib < max(timed, 1)):
            bad.append("%s indices %s..%s outside [0,%s) or not increasing" % (what, ia, ib, timed))
            return False
        if c.get("tA") is not None and c.get("tB") is not None and c["tA"] > c["tB"]:
            bad.append("%s tA %s > tB %s" % (what, c["tA"], c["tB"]))
        if r.get("topology_version") == 1:
            fields = ("segment", "segmentA", "segmentB", "pathA", "pathB")
            if any(type(c.get(k)) is not int for k in fields):
                bad.append("%s missing topology certificate" % what)
                return False
            if not (c["segment"] == c["segmentA"] == c["segmentB"] and 0 <= c["pathA"] < c["pathB"] < pts):
                bad.append("%s crosses source or reverses path" % what)
                return False
        return True

    def source(c):
        return c["segment"] if r.get("topology_version") == 1 else 0

    def path(c, side):
        return c["path" + side] if r.get("topology_version") == 1 else c["i" + side]

    prev_by_segment = {}
    last_global = -1
    for c in r.get("gap_list") or []:
        what = "%s@%s" % (c.get("kind"), c.get("tA"))
        if not idx_ok(c, what):
            continue
        if c["iA"] < last_global:
            bad.append("%s out of global time order" % what)
        last_global = c["iA"]
        sec = c["tB"] - c["tA"]
        if c.get("kind") == "timeGap":
            adjacent = type(c.get("nextInSegment")) is int and c["nextInSegment"] == c["iB"] and c["pathB"] == c["pathA"] + 1 if r.get("topology_version") == 1 else c["iB"] == c["iA"] + 1
            if not adjacent:
                bad.append("%s not consecutive points (%s..%s)" % (what, c["iA"], c["iB"]))
            if sec < 20 - 1e-6 or sec > 3600 + 1e-6:
                bad.append("%s dt %.2f s outside [20,3600]" % (what, sec))
        elif sec > 3600 + 1e-6:
            bad.append("%s span %.2f s > 3600" % (what, sec))
        if c.get("meters") is not None and c["meters"] < 150 - eps:
            bad.append("%s %.1f m < 150" % (what, c["meters"]))
        if c.get("kmh") is not None and not (15 - eps <= c["kmh"] <= 350 + eps):
            bad.append("%s %.1f km/h outside [15,350]" % (what, c["kmh"]))
        prev = prev_by_segment.get(source(c))
        if prev is not None and path(c, "A") < path(prev, "B"):
            bad.append("%s overlaps / out of order within its source" % what)
        prev_by_segment[source(c)] = c
    prev = None
    for c in r.get("jitter") or []:
        what = "jitter@%s" % c.get("tA")
        if not idx_ok(c, what):
            continue
        if c.get("inner") is not None and c["inner"] != max(0, path(c, "B") - path(c, "A") - 1):
            bad.append("%s inner %s != iB-iA-1" % (what, c["inner"]))
        if prev is not None and c["iA"] < prev["iA"]:
            bad.append("%s out of order" % what)
        prev = c
    prev_by_segment = {}
    last_global = -1
    for c in r.get("merged_list") or []:
        what = "merged %s@%s" % (c.get("kind", "jitter"), c.get("tA"))
        if not idx_ok(c, what):
            continue
        if c["iA"] < last_global:
            bad.append("%s out of global time order" % what)
        last_global = c["iA"]
        prev = prev_by_segment.get(source(c))
        if prev is not None and path(c, "A") < path(prev, "B"):
            bad.append("%s overlaps previous merged candidate within its source" % what)
        prev_by_segment[source(c)] = c
    if len(bad) > 6:
        bad = bad[:6] + ["… %d more invariant violations" % (len(bad) - 6)]
    return ["invariant: " + b for b in bad]


def check_expect(r, exp):
    """-> (failures, notes) for a successfully loaded file."""
    fails, notes = [], []
    if "__bad__" in exp:
        return ["expect entry is not an object: %r" % (exp["__bad__"],)], notes
    for k in exp:
        if k not in KNOWN_KEYS:
            notes.append("unknown expect key '%s' ignored" % k)

    if "points" in exp:
        try:
            lo, hi = parse_range(exp["points"])
            if not (lo <= r["points"] <= hi):
                fails.append("points %d, expected %s" % (r["points"], fmt_range(lo, hi)))
        except ValueError as e:
            fails.append("bad expect 'points': %s" % e)

    if "profile" in exp:
        want = exp["profile"]
        allowed = want if isinstance(want, list) else [want]
        if any(a not in PROFILES for a in allowed):
            fails.append("bad expect 'profile': %r" % (want,))
        elif "any" not in allowed and r["profile"] not in allowed:
            pd = r.get("profile_detail") or {}
            fails.append("profile %s, expected %s (creator %r, acc %s, mdt %s, mstep %s)" % (
                r["profile"], "|".join(allowed), pd.get("creator"), pd.get("accuracy"), pd.get("medianDt"), pd.get("medianStep")))

    for key, getter in RANGE_KEYS.items():
        if key not in exp:
            continue
        try:
            lo, hi = parse_range(exp[key])
        except ValueError as e:
            fails.append("bad expect '%s': %s" % (key, e))
            continue
        val = getter(r)
        if val is None:
            notes.append("runner did not report '%s'" % key)
            continue
        if not (lo <= val <= hi):
            extra = ""
            if key == "gaps":
                extra = " (timeGap %s, stale %s)" % (r.get("timegap"), r.get("stale"))
            elif key == "jitter":
                extra = " (%s)" % ", ".join("%.0f-%.0f j%d r%d" % (c["tA"], c["tB"], c.get("jumps", 0), c.get("revs", 0))
                                           for c in (r.get("jitter") or [])[:4])
            fails.append("%s %s, expected %s%s" % (key, val, fmt_range(lo, hi), extra))

    jit = r.get("jitter") or []
    if _jitter_count(r) > len(jit):
        notes.append("jitter list truncated to %d of %d" % (len(jit), _jitter_count(r)))
    gl = r.get("gap_list") or []
    for key, cands, label in (("jitter_cover", jit, "jitter"), ("gap_cover", gl, "gap")):
        if key not in exp:
            continue
        try:
            ivs = parse_intervals(exp[key])
        except ValueError as e:
            fails.append("bad expect '%s': %s" % (key, e))
            continue
        for a, b in ivs:
            best, bc = 0.0, None
            for c in cands:
                v = iou(a, b, c["tA"], c["tB"])
                if v > best:
                    best, bc = v, c
            if best < 0.5:
                fails.append("%s [%.0f,%.0f] not covered: best IoU %.2f%s" % (
                    label, a, b, best, (" by %.0f-%.0f" % (bc["tA"], bc["tB"])) if bc else " (no overlapping candidate)"))
    for key, cands, label in (("jitter_free", jit, "jitter"), ("gap_free", gl, "gap")):
        if key not in exp:
            continue
        try:
            ivs = parse_intervals(exp[key])
        except ValueError as e:
            fails.append("bad expect '%s': %s" % (key, e))
            continue
        for a, b in ivs:
            hits = [c for c in cands if a <= c["tA"] <= b]
            if hits:
                fails.append("%s starts inside free [%.0f,%.0f]: %s" % (
                    label, a, b, ", ".join("%.0f-%.0f" % (c["tA"], c["tB"]) for c in hits[:4])
                    + (" …+%d" % (len(hits) - 4) if len(hits) > 4 else "")))

    ms = r.get("ms") or {}
    for key, mkey in (("max_load_seconds", "load"), ("max_total_seconds", "total")):
        if key not in exp:
            continue
        lim = exp[key]
        if not isinstance(lim, (int, float)) or isinstance(lim, bool):
            fails.append("bad expect '%s': %r" % (key, lim))
            continue
        got = (ms.get(mkey) or 0) / 1000.0
        if got > lim:
            fails.append("%s %.2f s > %s s" % (mkey, got, lim))
    return fails, notes


def evaluate(rec):
    if "status" in rec:          # MISSING / TIMEOUT / CRASH already decided
        return rec
    r, exp = rec["result"], rec.get("expect")
    fails, notes = [], []
    if "error" in r:
        if exp is None:
            notes.append("rejected: %s" % short(r["error"], 120))
        elif exp.get("load_ok", True) is False:
            notes.append("rejected as allowed (%s): %s" % (r.get("stage", "?"), short(r["error"], 120)))
        else:
            fails.append("load failed at %s: %s" % (r.get("stage", "?"), short(r["error"], 200)))
        rec.update(status="FAIL" if fails else "ok", failures=fails, notes=notes)
        return rec
    fails += invariants(r)
    if exp is None:
        notes.append("not in expect.json: crash/invariant check only")
    else:
        f2, n2 = check_expect(r, exp)
        if exp.get("load_ok", True) is False:
            notes += n2 + ["soft (load_ok=false): " + f for f in f2]
        else:
            fails += f2
            notes += n2
    rec.update(status="FAIL" if fails else "ok", failures=fails, notes=notes)
    return rec


def summary_line(r):
    ms = r.get("ms") or {}
    return "pts=%d prof=%s gaps=%d(st%d) rep=%d jit=%d merged=%d trips=%d load=%.0fms total=%.0fms" % (
        r.get("points", 0), {"deviceLogger": "dev", "phone": "phone", "unknown": "unk"}.get(r.get("profile"), r.get("profile")),
        r.get("gaps", 0), r.get("stale", 0), r.get("replays", 0), _jitter_count(r), r.get("merged", 0), r.get("trips", 0),
        ms.get("load") or 0, ms.get("total") or 0)


# ---------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--root", default=DEFAULT_ROOT, help="directory holding family dirs (default: %(default)s)")
    ap.add_argument("--runner", default=DEFAULT_RUNNER, help="synthrunner binary (default: %(default)s)")
    ap.add_argument("--family", action="append", default=[], help="family name or glob; repeatable or comma-separated")
    ap.add_argument("--file", action="append", default=[], help="file name, family/file or glob; repeatable or comma-separated")
    ap.add_argument("--json", metavar="OUT", help="write full results as JSON to OUT")
    ap.add_argument("--json-full", action="store_true", help="keep gap/merged/trip lists in --json output")
    ap.add_argument("--jobs", "-j", type=int, default=min(4, os.cpu_count() or 1),
                    help="parallel runner processes for untimed files (timed ones always run serially; default %(default)s)")
    ap.add_argument("--timeout", type=float, default=120.0, help="per-file runner timeout in seconds (default %(default)s)")
    ap.add_argument("--list", action="store_true", help="list families/files and exit")
    ap.add_argument("-v", "--verbose", action="store_true", help="show desc, notes and full details")
    ap.add_argument("-q", "--quiet", action="store_true", help="no progress on stderr")
    a = ap.parse_args(argv)

    split = lambda xs: [p.strip() for x in xs for p in x.split(",") if p.strip()]
    fam_f, file_f = split(a.family), split(a.file)
    root = os.path.abspath(a.root)
    families, tasks, errors = discover(root, fam_f, file_f)

    if a.list:
        for t in tasks:
            d = "(unlisted: crash/invariant check only)" if t["expect"] is None else str(t["expect"].get("desc", ""))
            print("%s/%s\t%s" % (t["family"], t["name"], d))
        for e in errors:
            print("%s/%s\t%s: %s" % (e[0], e[1], e[2], "; ".join(e[3])))
        return 0
    if not families and not errors:
        print("no family with expect.json under %s%s" % (root, " matching filters" if fam_f else ""), file=sys.stderr)
        return 2
    if tasks and not (os.path.isfile(a.runner) and os.access(a.runner, os.X_OK)):
        print("runner not found or not executable: %s (run run_all.sh to build it)" % a.runner, file=sys.stderr)
        return 2

    timed = [t for t in tasks if t["expect"] and ("max_load_seconds" in t["expect"] or "max_total_seconds" in t["expect"])]
    untimed = [t for t in tasks if t not in timed]
    recs, done = [], [0]
    t_start = time.monotonic()

    def finish(rec, task):
        rec["expect"] = task["expect"]
        evaluate(rec)
        recs.append(rec)
        done[0] += 1
        if not a.quiet:
            print("[%d/%d] %-6s %s/%s" % (done[0], len(tasks), rec["status"], rec["family"], rec["file"]),
                  file=sys.stderr, flush=True)

    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        futs = {ex.submit(run_one, a.runner, t, a.timeout): t for t in untimed}
        for f in cf.as_completed(futs):
            finish(f.result(), futs[f])
    for t in timed:                       # serial: timing must not compete with other runners
        finish(run_one(a.runner, t, a.timeout), t)

    for fam, name, st, fl in errors:
        recs.append({"family": fam, "file": name, "status": st, "failures": fl, "notes": []})
    order = {(t["family"], t["name"]): i for i, t in enumerate(tasks)}
    recs.sort(key=lambda r: (r["family"], order.get((r["family"], r["file"]), -1), r["file"]))

    # ---- table
    rows = []
    for r in recs:
        res = r.get("result") or {}
        if r["status"] == "ok":
            det = ("rejected: " + short(res["error"], 80)) if "error" in res else summary_line(res)
            shown = r.get("notes", []) if a.verbose else [n for n in r.get("notes", []) if n.startswith(NOTE_PREFIXES)]
            if shown:
                det += " | " + "; ".join(shown)
        else:
            det = "; ".join(r.get("failures") or [])
            if res and "error" not in res:
                det += "  <" + summary_line(res) + ">"
            shown = r.get("notes", []) if a.verbose else [n for n in r.get("notes", []) if n.startswith(NOTE_PREFIXES)]
            if shown:
                det += " | " + "; ".join(shown)
        if not a.verbose:
            det = short(det, 400)
        rows.append((r["family"], r["file"], r["status"], det))
        if a.verbose and isinstance(r.get("expect"), dict) and r["expect"].get("desc"):
            rows.append(("", "", "", "  desc: " + str(r["expect"]["desc"])))
    w0 = max([6] + [len(x[0]) for x in rows])
    w1 = max([4] + [len(x[1]) for x in rows])
    w2 = max([6] + [len(x[2]) for x in rows])
    print("%-*s  %-*s  %-*s  %s" % (w0, "family", w1, "file", w2, "status", "details"))
    print("%s  %s  %s  %s" % ("-" * w0, "-" * w1, "-" * w2, "-" * 7))
    for fam, fn, st, det in rows:
        print("%-*s  %-*s  %-*s  %s" % (w0, fam, w1, fn, w2, st, det))

    # ---- summary
    from collections import Counter, defaultdict
    by_status = Counter(r["status"] for r in recs)
    per_fam = defaultdict(Counter)
    for r in recs:
        per_fam[r["family"]][r["status"]] += 1
    bad = [r for r in recs if r["status"] not in OK_STATUSES]
    print()
    print("summary: %d entries in %d families, %s  (%.1f s)" % (
        len(recs), len(families), ", ".join("%s %d" % (k, v) for k, v in sorted(by_status.items())), time.monotonic() - t_start))
    for fam in sorted(per_fam):
        c = per_fam[fam]
        tot = sum(c.values())
        print("  %-*s %3d/%-3d ok%s" % (w0, fam, c.get("ok", 0), tot,
                                       "" if c.get("ok", 0) == tot else "  (" + ", ".join("%s %d" % kv for kv in sorted(c.items()) if kv[0] != "ok") + ")"))
    if bad:
        print("FAILED: " + " ".join("%s/%s" % (r["family"], r["file"]) for r in bad[:40]) + (" …" if len(bad) > 40 else ""))

    if a.json:
        out = []
        for r in recs:
            o = {k: v for k, v in r.items() if k != "result"}
            res = r.get("result")
            if res is not None:
                o["result"] = res if a.json_full else {k: v for k, v in res.items() if k not in ("gap_list", "merged_list", "trip_list")}
            out.append(o)
        payload = {"root": root, "runner": a.runner, "summary": dict(by_status), "total": len(recs),
                   "families": {f: dict(c) for f, c in per_fam.items()}, "results": out}
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
