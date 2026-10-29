#!/bin/sh
# Build synthrunner against the project sources, then run check.py over every family.
# All arguments are passed to check.py (e.g. --family 'stale*' --file '*.csv' --json out.json -v).
#   SKIP_BUILD=1  reuse the existing synthrunner binary
#   REGEN=1       re-run each family's gen.py (cwd = family dir) before checking
#   PROJ=...      project root (default: two levels above Tests/synth)
# Exit code: check.py's (0 ok, 1 failures, 2 usage), 3 = build failed, 4 = a gen.py failed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PROJ="${PROJ:-$(cd "$ROOT/../.." && pwd)}"
RUNNER="$HERE/synthrunner"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "building $RUNNER (swiftc -O, ~30 s) ..." >&2
  (
    cd "$PROJ" || exit 1
    swiftc -O -o "$RUNNER" "$HERE/main.swift" \
      GPXPointViewer/GPXParser.swift GPXPointViewer/TrackData.swift GPXPointViewer/GapFill.swift \
      GPXPointViewer/RoadNetwork.swift GPXPointViewer/GeoCompute.swift GPXPointViewer/MetalPointRenderer.swift \
      GPXPointViewer/Colormaps.swift GPXPointViewer/Heat3D.swift GPXPointViewer/BatchFill.swift \
      GPXPointViewer/PixelGlobe.swift GPXPointViewer/GPXWriter.swift GPXPointViewer/L10nSupport.swift \
      GPXPointViewer/FillPlausibility.swift GPXPointViewer/RouteReplay.swift "$HERE/exam.swift"
  ) > "$HERE/build.log" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    grep -E "error:" "$HERE/build.log" | head -20 >&2
    echo "build FAILED (exit $rc); full log: $HERE/build.log" >&2
    exit 3
  fi
  echo "build ok ($(grep -c 'warning:' "$HERE/build.log") warnings; log: $HERE/build.log)" >&2
elif [ ! -x "$RUNNER" ]; then
  echo "SKIP_BUILD=1 but $RUNNER does not exist" >&2
  exit 3
fi

if [ "${REGEN:-0}" = "1" ]; then
  for gen in "$ROOT"/*/gen.py; do
    [ -f "$gen" ] || continue
    fam="$(dirname "$gen")"
    [ "$fam" = "$HERE" ] && continue
    echo "regenerating $(basename "$fam") ..." >&2
    if ! (cd "$fam" && python3 gen.py) >&2; then
      echo "gen.py FAILED in $fam" >&2
      exit 4
    fi
  done
fi

python3 "$HERE/check.py" --root "$ROOT" --runner "$RUNNER" "$@"
rc=$?
# 末尾：合成断档考卷（离线回放，几秒；docs/fill-plausibility-design.md §2）。只在跑全套（没有 --family/--file 过滤）时跑；
# 有录音就判卷并与 baseline.json 对照，回归则退出码 1
case " $* " in *" --family "*|*" --file "*|*" --list "*) exit $rc;; esac
if [ -d "$ROOT/../exam/recordings" ]; then
  # 不能写成 `… | tail -1; erc=$?`：那样拿到的是 tail 的退出码，考卷回归会被吞掉（2026-10-27 DeepSeek 任务书起草时发现）
  exam_out=$(cd "$PROJ" && "$RUNNER" --exam "$ROOT/../exam" 2>/dev/null); erc=$?
  printf '%s\n' "$exam_out" | tail -1
  [ $rc -eq 0 ] && rc=$erc
else
  echo "exam summary: no recordings (Tests/exam/recordings missing) — skipped"
fi
exit $rc
