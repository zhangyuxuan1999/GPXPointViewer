#!/bin/zsh
# Structured records + read-only history; no full command-line scan.
set -e
cd "$(dirname "$0")/../.."
if [[ "${1:-}" == -w ]]; then
  shift
  while true; do
    python3 Tools/agents/agent_run.py status "$@"
    sleep 10
  done
fi
exec python3 Tools/agents/agent_run.py status "$@"
