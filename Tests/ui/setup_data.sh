#!/bin/zsh
# 把 UI 测试要打开的轨迹文件拷进 app 沙盒容器（app 只能读自己容器里的文件；钩子命令 open 用的就是这里的路径）。
# 源文件在项目的 data/ 下（不进 git）。只需要跑一次；data/ 里的文件换了再跑。
set -e
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
C="$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
mkdir -p "$C"
cp_one() { if [ -f "$PROJ/data/$1" ]; then cp "$PROJ/data/$1" "$C/$2" && echo "ok  $2 ← data/$1"; else echo "缺  data/$1（跳过；用到 $2 的测试会失败）"; fi }
cp_one "Garmin_Roma_Da.gpx" "Garmin_Roma_Da.gpx"
cp_one "20260326_KoblenzHBF_TrierHBF_RE1.gpx" "RE1.gpx"
cp_one "20260326_TrierHBF_Luxembourg_RE11.gpx" "RE11.gpx"
cp_one "2026.01.01-2026.12.31.csv" "2026.csv"
cp_one "backUpData-2026.gpx" "backup2026.gpx"
cp_one "backUpData-all 6.gpx" "backupall.gpx"
cp_one "Garmin_Roma_Da_copy.gpx" "Garmin_Roma_Da_copy.gpx"          # run_trip_tests / run_tripmap_tests
cp_one "backUpData-all 5/backUpData-all 5.csv" "stepLife.csv"         # run_profile_tests（171 MB）
cp_one "2026.01.01-2026.12.31.csv" "stepLife2026.csv"                 # run_nature_tests / run_route_notes_tests
