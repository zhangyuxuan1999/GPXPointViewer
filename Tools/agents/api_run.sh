#!/bin/zsh
# Explicit --model/--budget/--budget-config required. Never auto-install deps.
set -e
cd "$(dirname "$0")/../.."
SDK_PYTHON=Tools/agents/sdkenv/bin/python
[[ -x "$SDK_PYTHON" ]] || { print -u2 'SDK environment missing; provision it explicitly first.'; exit 2; }
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
# CLI's configured credential helper supplies auth; an explicit API key stays in
# memory. Do not print credentials or copy wrapper authentication into records.
exec "$SDK_PYTHON" Tools/agents/api_run.py "$@"
