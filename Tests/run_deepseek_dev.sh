#!/bin/zsh
# Explicit allowed paths are mandatory; no blanket edit/build/agent grants.
set -e
cd "$(dirname "$0")/.."
[[ $# -ge 1 && -f "$1" ]] || { print -u2 'usage: Tests/run_deepseek_dev.sh TASK --allow-write PATH [options]'; exit 2; }
TASK="$1"
shift
PERMITTED=0
for ARG in "$@"; do
  [[ "$ARG" == --allow-write || "$ARG" == --allow-write=* ]] && PERMITTED=1
done
[[ "$PERMITTED" == 1 ]] || { print -u2 'development tasks require explicit --allow-write PATH'; exit 2; }
NAME="$(basename "$TASK" .md)"
exec python3 Tools/agents/agent_run.py deepseek "$NAME" "$TASK" "$@"
