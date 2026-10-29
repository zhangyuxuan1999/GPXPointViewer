#!/usr/bin/env python3
"""Explicit-budget Claude Agent SDK compatibility entry point.

Requires --model, --budget, --budget-config; no historical CAP/default model.
Config JSON: {"capacity_usd": 100, "source": "operator verified ...",
"baseline_known_usd": 0, "baseline_unknown_costs": []}.
Configured SDK costs are not live balance or actual invoice claims.
"""
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import math
import multiprocessing
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from agent_run import (common_registration, register, tool_configuration, terminate_group,
                       process_owner, cleanup_failure)
from run_store import BudgetLedger, REPO, RunStore, atomic_json, classify_result, durable_text, read_json, redact, process_identity


def ledger_total(ledger):
    """Compatibility helper: fee-column sum; reconcile reports unknowns separately."""
    from run_store import reconcile_legacy
    return reconcile_legacy(ledger)["known_total_usd"]


def serialize_message(message):
    if dataclasses.is_dataclass(message):
        body = dataclasses.asdict(message)
    elif isinstance(message, dict):
        body = message
    elif hasattr(message, "__dict__"):
        body = vars(message)
    else:
        body = {"value": str(message)}
    return {"message_class": type(message).__name__, **redact(body)}


def _sdk_worker(run_path, fields, prompt):
    """Own session/process group so outer timeout can reap CLI + tool children.

    The SDK documents that foreign asyncio cancellation can bypass transport
    escalation. The outer runner never cancels this query in its own process.
    """
    os.setsid()
    os.environ["GPXPV_AGENT_RUN_DIR"] = str(run_path)
    run = RunStore(run_path)
    atomic_json(run.path / "sdk-worker-owner.json", {"pid": os.getpid(), "process_group": os.getpgrp(),
                "session_id": os.getsid(0), "process_identity": process_identity(os.getpid())})
    final, error = None, None
    try:
        from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage
        def capture_stderr(text):
            run.event("stderr", text=text)
            with (run.path / "stderr.log").open("a", encoding="utf-8") as f:
                f.write(redact(text) + ("" if text.endswith("\n") else "\n")); f.flush(); os.fsync(f.fileno())
        options = ClaudeAgentOptions(**fields, stderr=capture_stderr)
        run.event("sdk_worker_started", pid=os.getpid(), process_group=os.getpgrp())
        async def consume():
            nonlocal final
            async for message in query(prompt=prompt, options=options):
                body = serialize_message(message)
                run.event("provider_message", message=body)
                with (run.path / "transcript.jsonl").open("a", encoding="utf-8") as f:
                    f.write(json.dumps(body, ensure_ascii=False) + "\n"); f.flush(); os.fsync(f.fileno())
                sid = body.get("session_id")
                if sid and run.meta.get("session_id") != sid:
                    run.bind(session_id=sid)
                if isinstance(message, ResultMessage):
                    if final is not None:
                        raise ValueError("SDK emitted multiple final results")
                    final = body
                    atomic_json(run.path / "sdk-worker-result.json", {"final": final, "error": None, "query_completed": False})
        asyncio.run(consume())
    except BaseException as exc:
        error = f"{type(exc).__name__}: {exc}"
        run.event("sdk_worker_error", error=error)
    finally:
        atomic_json(run.path / "sdk-worker-result.json", {"final": final, "error": error, "query_completed": error is None})


def _stop_worker(worker, *, owner=None, run_path=None):
    group_owner = (lambda: read_json(Path(run_path) / "sdk-worker-owner.json", {})) if run_path else None
    return terminate_group(worker, owner=owner, group_owner=group_owner)


def _disable_unconfirmed_worker_join(worker, cleanup):
    """Do not let multiprocessing's later atexit join undo our bounded cleanup.

    Only detach this locally created object from the stdlib exit registry.
    Its PID/identity and incomplete state remain recorded; no process is killed.
    """
    if not worker or cleanup.get("leader_alive") is False:
        return
    try:
        children = multiprocessing.process._children
        registered = worker in children
        children.discard(worker)
        cleanup["automatic_exit_join"] = "disabled" if registered else "not_registered"
    except Exception as exc:
        cleanup["automatic_exit_join"] = "unavailable"
        cleanup["errors"].append({"operation": "automatic_exit_join", "type": type(exc).__name__,
                                  "errno": getattr(exc, "errno", None), "message": str(exc)})


async def execute(args):
    run, context, session = register(args, "claude-agent-sdk")
    print(f"RUN_DIR={run.path}", flush=True)
    (run.path / "artifacts").mkdir()
    start = time.monotonic()
    final, error, interrupted, reason, ledger, reserved, started, worker = None, None, False, None, None, False, False, None
    owner, cleanup_receipts, receipt = None, [], {}
    task = asyncio.current_task()
    loop = asyncio.get_running_loop()
    received_signal = []
    def stop(sig):
        received_signal.append(sig)
        task.cancel()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop, sig)
    try:
        config = read_json(args.budget_config)
        if not isinstance(config, dict):
            raise ValueError("budget config missing/invalid")
        if args.import_reconciliation:
            report = read_json(args.import_reconciliation)
            if not isinstance(report, dict) or "known_total_usd" not in report:
                raise ValueError("invalid reconciliation report")
            if report.get("unknown_costs"):
                raise ValueError("historical unknown costs require explicit reconciliation; cannot auto-import")
            if config.get("baseline_known_usd") != report["known_total_usd"]:
                raise ValueError("config baseline_known_usd must match imported reconciliation")
            run.event("historical_reconciliation_source", report=report, report_path=str(args.import_reconciliation))
        ledger = BudgetLedger(args.ledger, config)
        ledger.reserve(run.meta["run_id"], args.budget); reserved = True
        run.event("budget_reserved", budget_usd=args.budget, ledger=str(args.ledger), config=config,
                  note="SDK budget is a termination threshold, not a bank-enforced exact spending cap.")
        if not os.environ.get("ANTHROPIC_API_KEY"):
            credentials = subprocess.run(["security", "find-generic-password", "-s", "anthropic-api-key", "-w"], capture_output=True, text=True)
            if credentials.returncode or not credentials.stdout.strip():
                raise RuntimeError("Anthropic API key unavailable from configured keychain entry")
            os.environ["ANTHROPIC_API_KEY"] = credentials.stdout.strip()
            run.event("credential_source", source="configured keychain entry; value never logged")
        tools, allowed = tool_configuration(args, run)
        if args.write and not args.allow_write:
            raise ValueError("--write requires explicit --allow-write PATH")
        prompt = Path(args.task).read_text() + context
        prompt += f"\n\nPersistent progress file: {run.path / 'progress.md'}. Runner records every normal message. "
        prompt += f"Update progress at every phase with completed/current/next work. Save artifacts only in {run.path / 'artifacts'}. "
        prompt += "Follow allowed paths and task commands. Verify existing artifacts before recovery; do not repeat completed side effects. Return the full final report in your final answer."
        durable_text(run.path / "prompt.md", prompt, exclusive=True)
        fields = dict(model=args.model, effort=args.effort, cwd=str(args.cwd), tools=tools,
                    allowed_tools=allowed, disallowed_tools=["Agent", "Skill", "NotebookEdit", "WebFetch", "WebSearch"],
                    permission_mode="dontAsk", max_turns=args.max_turns, max_budget_usd=args.budget,
                    max_buffer_size=64 * 1024 * 1024, setting_sources=[], skills=[], plugins=[],
                    strict_mcp_config=True, mcp_servers={}, extra_args={"safe-mode": None},
                    resume=session if args.resume_mode == "native" else None,
                    fork_session=args.resume_mode == "native" and bool(session))
        run.event("dispatch", options={"model": args.model, "effort": args.effort, "cwd": str(args.cwd), "tools": tools,
                  "allowed_tools": allowed, "max_turns": args.max_turns, "max_budget_usd": args.budget,
                  "strict_mcp_config": True, "setting_sources": [], "skills": [], "plugins": [],
                  "resume_session": session if args.resume_mode == "native" else None}, prompt_file="prompt.md")
        worker = multiprocessing.get_context("spawn").Process(target=_sdk_worker, args=(str(run.path), fields, prompt))
        worker.start()
        owner = process_owner(worker)
        run.bind(pid=os.getpid(), child_pid=worker.pid); started = True
        async def wait_worker():
            heartbeat = time.monotonic()
            while worker.is_alive():
                await asyncio.sleep(0.05)
                if time.monotonic() - heartbeat >= 15:
                    run.event("heartbeat", child_pid=worker.pid); heartbeat = time.monotonic()
        try:
            await asyncio.wait_for(wait_worker(), timeout=args.timeout)
        except asyncio.TimeoutError:
            interrupted, reason = True, "wall_clock_timeout"
            run.event("termination_requested", reason=reason)
    except asyncio.CancelledError:
        interrupted, reason = True, "signal_" + str(received_signal[0]) if received_signal else "cancelled"
        run.event("termination_requested", reason=reason)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        run.event("runner_error", error=error, started=started)
    finally:
        if worker:
            # Even an exited leader can leave descendants in its process group.
            try:
                cleanup = _stop_worker(worker, owner=owner, run_path=run.path)
            except Exception as exc:
                cleanup = cleanup_failure(worker, exc)
            _disable_unconfirmed_worker_join(worker, cleanup)
            cleanup_receipts.append(cleanup)
            atomic_json(run.path / "process-cleanup.json", cleanup_receipts)
            run.event("process_cleanup", receipt=cleanup)
            receipt = read_json(run.path / "sdk-worker-result.json", {})
            final = receipt.get("final")
            error = error or receipt.get("error")
            child_exit_code = cleanup.get("leader_exit_code")
            if not interrupted and child_exit_code not in {0, None}:
                error = error or f"SDK worker exit {child_exit_code}"
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.remove_signal_handler(sig)
        changes = None
        try:
            changes = run.snapshot("after")
        except Exception as exc:
            error = (error or "") + f" snapshot failed: {exc}"
            run.event("snapshot_error", error=str(exc))
        child_exit_code = (cleanup_receipts[-1] if cleanup_receipts else {}).get("leader_exit_code")
        status = classify_result(final, child_exit_code if child_exit_code is not None else 0, interrupted=interrupted, error=error)
        if status == "succeeded" and child_exit_code is None:
            status = "unknown"
        output = (final or {}).get("result") or ""
        if not isinstance(output, str):
            output = json.dumps(output, ensure_ascii=False)
            error = (error or "") + " invalid non-text final result"
            status = "failed"
        if status == "succeeded" and (not output.strip() or (changes or {}).get("out_of_scope")):
            status = "failed"
        cost = reported_cost = (final or {}).get("total_cost_usd")
        if cost is not None and (isinstance(cost, bool) or not isinstance(cost, (int, float)) or not math.isfinite(cost) or cost < 0):
            error = (error or "") + " invalid SDK cost field; retaining reservation"
            cost, status = None, "failed"
        cleanup_complete = all(x["status"] in {"confirmed", "not_started"} for x in cleanup_receipts)
        if cost is not None and not cleanup_complete and receipt.get("query_completed") is not True:
            run.event("budget_cost_uncertain", reported_cost_usd=cost,
                      reason="query completion and process cleanup both unconfirmed; retaining reservation")
            cost = None
        if reserved:
            try:
                ledger.settle(run.meta["run_id"], cost)
                run.event("budget_settled", cost_usd=cost, source="SDK ResultMessage.total_cost_usd" if cost is not None else "unknown; reservation retained")
            except Exception as exc:
                status = "failed"; error = (error or "") + f" budget settlement failed: {exc}"
                run.event("budget_settlement_error", error=str(exc))
        runner_exit_code = 0 if status == "succeeded" else (124 if reason == "wall_clock_timeout" else 1)
        result = dict(process_cleanup=cleanup_receipts, cleanup_complete=cleanup_complete, sdk_query_completed=receipt.get("query_completed"), sdk_reported_cost_usd=reported_cost,
                      runner_exit_code=runner_exit_code, child_exit_code=child_exit_code,
                      provider_status=status, acceptance_status="failed" if (changes or {}).get("out_of_scope") else "pending",
                      started=started, exit_code=runner_exit_code,
                      error=error, is_error=status != "succeeded", duration_s=round(time.monotonic() - start, 3),
                      cost_usd=cost, cost_source="SDK estimate" if cost is not None else "unknown", actual_billed_cost_usd=None,
                      budget_usd=args.budget, budget_ledger=str(args.ledger), runner_terminal_reason=reason,
                      **{k: (final or {}).get(k) for k in ("usage", "num_turns", "session_id", "subtype", "terminal_reason", "stop_reason", "errors", "permission_denials", "api_error_status")})
        run.finish(result, output)
    print(f"REPORT={run.path / 'output.md'}")
    return runner_exit_code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    common_registration(parser)
    parser.set_defaults(provider="claude-agent-sdk", effort="max")
    for action in parser._actions:
        if action.dest == "effort":
            action.required = False
    parser.add_argument("--budget", type=float, required=True)
    parser.add_argument("--budget-config", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, default=REPO / "Tools/agents/budget/sdk-ledger.json")
    parser.add_argument("--import-reconciliation", type=Path)
    parser.add_argument("--max-turns", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--write", action="store_true", help="Explicit --allow-write paths remain required")
    parser.add_argument("--allow-command", action="append", default=[])
    args = parser.parse_args(argv)
    if args.model.startswith(("gpt-", "deepseek")):
        parser.error("Astra/Sol require native Codex routing; DeepSeek uses agent_run.py deepseek")
    if args.max_turns <= 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("max-turns and timeout must be positive")
    try:
        return asyncio.run(execute(args))
    except Exception as exc:
        print(redact(f"{type(exc).__name__}: {exc}"), file=sys.stderr); return 2


if __name__ == "__main__":
    raise SystemExit(main())
