#!/bin/zsh
# 25-script hook suite. Explicit, attributed GPXPV_APP is checked before launch.
# Region statistics is separate: python3 Tests/ui/run_regions_stats_tests.py
set -o pipefail
cd "$(dirname "$0")" || exit 1
mkdir -p perf || exit 1
RUN_DIR=$(mktemp -d "perf/suite_$(date -u +%Y%m%dT%H%M%SZ)_XXXXXX") || exit 1
OUT="$RUN_DIR/suite.log"
echo "SUITE_LOG=$PWD/$OUT"
python3 -u - "$OUT" <<'PY' 2>&1 | tee -a "$OUT"
import datetime, json, os, shutil, subprocess, sys, time
from pathlib import Path
import ui

SCRIPTS = """run_fill_tests_onscreen.py run_fill_tests.py run_review_tests.py run_hover_perf_test.py run_drift_tests.py run_network_tests.py run_keep_tests.py run_dock_tests.py run_trip_tests.py run_region_tests.py run_profile_tests.py run_nature_tests.py run_route_notes_tests.py run_route_tests.py run_parallel_tests.py run_tripmap_tests.py run_rail_tests.py run_jitter_tests.py run_plausibility_tests.py run_tunnel_fix_tests.py run_crosscheck_tests.py run_batch_review_tests.py run_batch_card_tests.py run_route_cache_tests.py run_map_sources_tests.py""".split()
log = Path(sys.argv[1]).resolve()
result_path = log.with_suffix(".json")
result = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "log": str(log), "scripts": [], "status": "starting",
          "separate_scripts": ["run_regions_stats_tests.py"], "build": None}


def save():
    result_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


def classify(returncode, output, diagnostic=False):
    summaries = [line.split("FAILS:", 1)[1].strip() for line in output.splitlines() if line.startswith("FAILS:")]
    if returncode != 0 or any(value.lower() != "none" for value in summaries):
        return "failed", summaries
    if summaries:
        return "passed", summaries
    return ("diagnostic" if diagnostic else "missing-result"), summaries


save()
try:
    # Validate before stopping/removing any existing test copy.
    src = ui.app_source()
    result["build"] = ui.build_provenance(src)
    print("testing", src, flush=True)
    SP = Path.cwd()
    dst = SP / "app.noindex/GPXPointViewer.app"
    subprocess.run(["pkill", "-f", str(dst)], capture_output=True)
    time.sleep(1.5)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists(): shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    Path(ui.IO).mkdir(parents=True, exist_ok=True)
    subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + ui.IO, str(dst),
                    "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
    ready = False
    for _ in range(60):
        time.sleep(1)
        if "points" in ui.state():
            ready = True
            print("app up", flush=True)
            break
    if not ready:
        raise RuntimeError("Test app did not become ready within 60 probes")
    result["status"] = "running"
    save()
    for script in SCRIPTS:
        print("#####", script, datetime.datetime.now(datetime.timezone.utc).isoformat(), flush=True)
        start = time.monotonic()
        execution = ui._archive.run_owned([sys.executable, "-u", script],
                                          stderr=subprocess.STDOUT, text=True, timeout=2400)
        code, output = execution["exit_code"], execution["stdout"]
        if execution["stderr"]: output += execution["stderr"]
        if execution["stop_reason"]: output += "\n" + execution["stop_reason"].upper() + "\n"
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
        status, summaries = classify(code, output, diagnostic=script == "run_drift_tests.py")
        entry = {"script": script, "exit_code": code, "status": status,
                 "fails_summaries": summaries, "elapsed_seconds": time.monotonic() - start,
                 "execution": {key: value for key, value in execution.items() if key not in ("stdout", "stderr")}}
        result["scripts"].append(entry)
        save()
        print("SCRIPT_RESULT", json.dumps(entry, ensure_ascii=False), flush=True)
        if execution["stop_reason"] or not execution["cleanup_complete"]:
            # A timed out script may have created clients outside its process
            # group. Stop the suite even when the owned group is gone.
            result["stop_reason"] = execution["stop_reason"] or "cleanup-unconfirmed"
            print("SUITE_STOP", result["stop_reason"], flush=True)
            break
    result["status"] = "failed" if result.get("stop_reason") or any(entry["status"] in ("failed", "missing-result") for entry in result["scripts"]) else "passed"
except BaseException as error:
    result["status"] = "failed"
    result["error"] = type(error).__name__ + ": " + str(error)
    print(result["error"], file=sys.stderr, flush=True)
finally:
    result["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save()
print("SUITE_RESULT", json.dumps(result, ensure_ascii=False), flush=True)
sys.exit(0 if result["status"] == "passed" else 1)
PY
