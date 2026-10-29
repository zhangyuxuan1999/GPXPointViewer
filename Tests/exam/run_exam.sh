#!/bin/sh
# 合成断档考卷（离线回放）：Tests/exam/run_exam.sh [--baseline] [--record [--max-requests N]]
#   默认：用 Tests/exam/recordings 回放、判卷、与 baseline.json 对照（基线里通过的题现在不过 = 回归，退出码 1），
#         结果存 Tests/exam/results/<时间>.json，末行 "exam summary: …"
#   --baseline：判卷后把每题通过/未通过写进 baseline.json（只在有意接受新结果时用）
#   --record：联网录制（唯一出网的步骤；串行、≤1 req/s、≤N 请求；先用 Tools/agents/status.sh 确认没有别的客户端）
#   SKIP_BUILD=1 复用已有的 synthrunner
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
RUNNER="$PROJ/Tests/synth/runner/synthrunner"
if [ "${SKIP_BUILD:-0}" != "1" ] || [ ! -x "$RUNNER" ]; then
  # 只编译（check.py 的过滤选一个不存在的族，不跑数据）；编译失败要报出来，别拿旧二进制判卷
  SKIP_BUILD=0 "$PROJ/Tests/synth/runner/run_all.sh" --family __none__ >/dev/null 2>"$HERE/.build.err"
  if grep -q "build FAILED" "$HERE/.build.err"; then cat "$HERE/.build.err" >&2; rm -f "$HERE/.build.err"; exit 3; fi
  rm -f "$HERE/.build.err"
  [ -x "$RUNNER" ] || { echo "synthrunner build failed (see Tests/synth/runner/build.log)" >&2; exit 3; }
fi
MODE=--exam; EXTRA=""
for a in "$@"; do
  case "$a" in
    --record) MODE=--exam-record;;
    --baseline) EXTRA="$EXTRA --exam-baseline";;
    --max-requests) EXTRA="$EXTRA --max-requests";;
    *) EXTRA="$EXTRA $a";;
  esac
done
cd "$PROJ" || exit 1
exec "$RUNNER" $MODE "$HERE" $EXTRA
