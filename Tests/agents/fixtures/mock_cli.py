#!/usr/bin/env python3
"""Offline Claude stream-json fixture. Never imports an SDK or uses the network.

MOCK_SCENARIO chooses the stream. Extra CLI arguments are deliberately accepted
so the executable can replace a configured Claude executable in integration tests.
All strings that resemble credentials are public synthetic test canaries.
"""
import json
import os
import signal
import sys
import time
from pathlib import Path


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


scenario = os.environ.get("MOCK_SCENARIO", "success")
session = "offline-session-123"
emit({"type": "system", "subtype": "init", "session_id": session,
      "model": "offline-mock", "tools": ["Read"]})
if scenario in {"bad-json", "turns-nonzero-protocol"}:
    print('{"type": broken}', flush=True)
if scenario == "stderr":
    print("ordinary diagnostic: indexing fixture 2/3", file=sys.stderr, flush=True)
if scenario == "scope-write":
    with open(os.environ.get("MOCK_WRITE_PATH", "source.txt"), "w") as handle:
        handle.write("mock changed watched source\n")
if scenario in {"run-path", "run-path-live"}:
    run_path = os.environ.get("GPXPV_AGENT_RUN_DIR")
    if not run_path:
        print("mock did not receive GPXPV_AGENT_RUN_DIR", file=sys.stderr, flush=True)
        sys.exit(31)
    run = Path(run_path)
    (run / "progress.md").write_text("# 语义进度\n已完成：MOCK_SEMANTIC_PROGRESS\n正在做：offline fixture\n下一步：review report\n")
    (run / "artifacts").mkdir(exist_ok=True)
    (run / "artifacts" / "child-run-path.json").write_text(json.dumps({"run_dir": run_path}))
    if scenario == "run-path-live":
        time.sleep(60)
if scenario in {"stream", "secret", "signal", "timeout", "kill-parent"}:
    text = "BEGIN_NORMAL_" + ("abcdef0123456789" * 12000) + "_END_NORMAL"
    emit({"type": "assistant", "session_id": session, "message": {
        "content": [{"type": "tool_use", "id": "call-1", "name": "Read",
                     "input": {"file_path": "fixture.txt", "ordinary": text}}]}})
    emit({"type": "user", "session_id": session, "message": {
        "content": [{"type": "tool_result", "tool_use_id": "call-1", "content": text}]}})
    if scenario == "secret":
        emit({"type": "assistant", "message": {"content": [{"type": "text", "text":
            "Authorization: Bearer synthetic-secret-123456789\n"
            "api_key=synthetic-key-123456789\n"
            "ordinary_data=COMPLETE_KEEP_THIS"}]},
            "api_key": "synthetic-nested-credential", "usage": {"input_tokens": 5}})
        print("Authorization: Bearer synthetic-stderr-credential", file=sys.stderr, flush=True)
    if scenario in {"timeout", "kill-parent"}:
        time.sleep(60)
    elif scenario == "signal":
        os.kill(os.getpid(), signal.SIGTERM)
    else:
        time.sleep(float(os.environ.get("MOCK_DELAY", "0.4")))
if scenario == "no-final":
    sys.exit(0)
if scenario == "exit-error":
    print("synthetic execution failure", file=sys.stderr, flush=True)
    sys.exit(17)
subtype = {"provider": "error_during_execution", "turns": "error_max_turns",
           "budget": "error_max_budget_usd", "turns-nonzero": "error_max_turns",
           "turns-nonzero-protocol": "error_max_turns", "budget-nonzero": "error_max_budget_usd"}.get(scenario, "success")
final = {"type": "result", "subtype": subtype, "is_error": subtype != "success",
         "terminal_reason": "completed" if subtype == "success" else scenario,
         "stop_reason": "end_turn", "session_id": session, "num_turns": 2,
         "result": "OFFLINE_EXPECTED_OUTPUT", "total_cost_usd": 0.125,
         "usage": {"input_tokens": 123, "output_tokens": 45}}
if scenario in {"turns-nonzero", "turns-nonzero-protocol", "budget-nonzero"}:
    final["terminal_reason"] = "max_budget_usd" if scenario == "budget-nonzero" else "max_turns"
    final["errors"] = ["Reached maximum budget" if scenario == "budget-nonzero" else "Reached maximum number of turns (4)"]
    final["num_turns"] = 5
    emit(final)
    sys.exit(1)
if scenario == "is-error":
    final["is_error"] = True
if scenario == "blank-output":
    final["result"] = ""
if scenario == "invalid-output":
    final["result"] = {"unexpected": "object instead of text"}
if scenario == "missing-error-flag":
    final.pop("is_error")
if scenario == "unknown-cost":
    final.pop("total_cost_usd")
if scenario == "late-nonzero":
    emit(final)
    sys.exit(17)
emit(final)
