#!/bin/zsh
# Default Read/Glob/Grep; grant task commands explicitly. Exit propagates.
# Bash grants are task constraints, not filesystem isolation.
set -e
cd "$(dirname "$0")/.."
[[ $# -ge 1 && -f "$1" ]] || { print -u2 'usage: Tests/run_deepseek.sh TASK [agent_run deepseek options]'; exit 2; }
TASK="$1"
shift
NAME="$(basename "$TASK" .md)"
exec python3 Tools/agents/agent_run.py deepseek "$NAME" "$TASK" "$@"
