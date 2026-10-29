#!/bin/zsh
# 全量钩子回归：先用最新 Release 构建重启测试副本，再顺序跑所有 run_*.py（公共路网服务一次只一个客户端），汇总 FAILS 行
cd "$(dirname "$0")"
mkdir -p perf
OUT=perf/suite_$(date +%H%M).log
python3 - <<'PY'
import subprocess, shutil, os, time, ui
SP = os.path.dirname(os.path.abspath("ui.py")); C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
subprocess.run(["pkill", "-f", SP + "/app.noindex/GPXPointViewer.app"], capture_output=True); time.sleep(1.5)
src = ui.app_source(); print("testing", src)
dst = SP + "/app.noindex/GPXPointViewer.app"; os.makedirs(os.path.dirname(dst), exist_ok=True)
if os.path.exists(dst): shutil.rmtree(dst)
shutil.copytree(src, dst, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, dst, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
for _ in range(60):
    time.sleep(1)
    if "points" in ui.state(): print("app up"); break
PY
for s in run_fill_tests_onscreen.py run_fill_tests.py run_review_tests.py run_hover_perf_test.py run_drift_tests.py run_network_tests.py run_keep_tests.py run_dock_tests.py run_trip_tests.py run_region_tests.py run_profile_tests.py run_nature_tests.py run_route_notes_tests.py run_route_tests.py run_parallel_tests.py run_tripmap_tests.py run_rail_tests.py run_jitter_tests.py run_plausibility_tests.py \
         run_tunnel_fix_tests.py run_crosscheck_tests.py run_batch_review_tests.py run_batch_card_tests.py run_route_cache_tests.py run_map_sources_tests.py; do
  # 2026-10-28：后 6 个（以及 jitter / plausibility）都会自己重启测试副本，排在最后；map_sources 的 M1c 在锁屏时假失败
  echo "##### $s $(date +%H:%M:%S)" | tee -a $OUT
  python3 -c 'import subprocess,sys
try: sys.exit(subprocess.run(["python3","-u",sys.argv[1]], timeout=2400).returncode)
except subprocess.TimeoutExpired: print("TIMEOUT"); sys.exit(124)' $s >> $OUT 2>&1; echo "exit=$? $(date +%H:%M:%S)" | tee -a $OUT
done
echo "===== SUMMARY" | tee -a $OUT
grep -E "^##### |^FAILS:|exit=|Traceback" $OUT
