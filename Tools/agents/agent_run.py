#!/usr/bin/env python3
"""Run registration, native-agent evidence, bounded DeepSeek execution and status.

Run --help / COMMAND --help. All retries create new directories. `--resume`
requires an explicit recovery plan; context recovery never claims session resume.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time

from run_store import (REPO, RECORDS, HISTORY, RunStore, BudgetLedger, atomic_json,
                       classify_result, durable_text, now, read_json, redact,
                       reconcile_legacy, process_identity)


def recovery_context(args):
    if not getattr(args, "resume", None):
        return "", None
    if not args.recovery_plan or not Path(args.recovery_plan).read_text().strip():
        raise ValueError("--resume requires --recovery-plan FILE describing completed work, remaining work and side-effect checks")
    previous = RunStore(args.resume)
    if not (previous.path / "task.md").exists():
        raise ValueError("resume source has no task.md")
    # Explicitly read old task/progress/result; complete transcript stays linked.
    context = "\n\n# Recovery evidence (inspect before acting)\n"
    for name in ("task.md", "progress.md", "result.json"):
        file = previous.path / name
        context += f"\n## Previous {name}\n" + (file.read_text() if file.exists() else "missing; status unknown")
    context += "\n## Recovery plan\n" + Path(args.recovery_plan).read_text()
    context += f"\nFull previous events: {previous.path / 'events.jsonl'}. Verify existing artifacts; do not blindly repeat side effects.\n"
    session = previous.meta.get("session_id") or (read_json(previous.path / "result.json", {}) or {}).get("session_id")
    if args.resume_mode == "native" and not session:
        raise ValueError("native resume requires a recorded provider session ID; use explicit context recovery otherwise")
    return context, session


def register(args, provider=None):
    context, session = recovery_context(args)
    run = RunStore.create(args.records_root, args.name, args.task, cwd=args.cwd,
                          provider=provider or args.provider, model=args.model,
                          effort=args.effort, watch=args.watch, allow_write=args.allow_write,
                          exclude=getattr(args, "exclude_path", None),
                          parent_run=getattr(args, "resume", None),
                          project_index=None if getattr(args, "no_project_index", False) else getattr(args, "project_index", None),
                          recovery=(getattr(args, "resume_mode", None) or "new") + context,
                          max_turns=getattr(args, "max_turns", None), timeout_seconds=getattr(args, "timeout", None))
    run.snapshot("before")
    return run, context, session


def tool_configuration(args, run=None):
    tools, allowed = ["Read", "Glob", "Grep"], ["Read", "Glob", "Grep"]
    if args.allow_command:
        tools.append("Bash")
        allowed += [f"Bash({cmd})" for cmd in args.allow_command]
    if args.allow_write:
        tools += ["Write", "Edit"]
        for scope in args.allow_write:
            p = Path(scope)
            if p.is_absolute():
                p = p.relative_to(Path(args.cwd).resolve())
            text = p.as_posix()
            allowed += [f"Write({text})", f"Edit({text})"]
            if (Path(args.cwd) / p).is_dir():
                allowed += [f"Write({text}/**)", f"Edit({text}/**)"]
    if run:
        if "Write" not in tools:
            tools.append("Write")
        own = os.path.relpath(run.path, Path(args.cwd).resolve())
        if own == ".." or own.startswith("../"):
            own = "/" + run.path.as_posix()  # //path is the CLI filesystem-root anchor.
        # Claude Code matches Write file operations against Edit(path) rules;
        # Write(path) is accepted syntactically but never grants path access.
        allowed += [f"Edit({own}/progress.md)", f"Edit({own}/artifacts/**)"]
    return tools, allowed


def build_deepseek_command(args, prompt, session=None, run=None):
    tools, allowed = tool_configuration(args, run)
    command = [str(Path(args.cli).expanduser()), *args.cli_arg, "-p", prompt,
               "--model", "deepseek-flash", "--effort", "max", "--tools", ",".join(tools),
               "--allowedTools", *allowed, "--disallowedTools", "Skill", "Agent", "NotebookEdit", "WebFetch", "WebSearch",
               "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--setting-sources", "", "--safe-mode",
               "--permission-mode", "dontAsk", "--max-turns", str(args.max_turns),
               "--output-format", "stream-json", "--verbose", "--system-prompt",
               "Execute only the supplied task. Follow its allowed paths and commands. Do not invoke other agents, skills or plugins. "
               "Report incomplete checks explicitly. Tool permissions are task constraints, not filesystem isolation. "
               "Automatic CLI approval of a safe command does not extend the task's allowed commands. "
               "For a long authorized command, use a bounded foreground call or run_in_background and wait for its completion notification, then Read its output. "
               "Do not poll with shell sleeps, shorter chained sleeps, waitsecs or renamed waiting wrappers, especially after a tool blocks a wait. "
               "Do not start a dependent phase or claim completion before the command completes. If completion notifications are unavailable, report the task as incomplete for the host to inspect. "
               "Return the complete final Markdown report in your final answer; runner saves it. "
               "Never install/overwrite /Applications, close the production app or access credentials. "
               "Public routing tests must have only one client. Preserve existing user changes."]
    if session:
        command += ["--resume", session, "--fork-session"]
    return command


def _read_pipe(pipe, channel, messages):
    try:
        while True:
            chunk = os.read(pipe.fileno(), 65536)
            if not chunk:
                break
            messages.put((channel, chunk))
    finally:
        messages.put((channel, None))


CLEANUP_TERM_SECONDS = 0.2
CLEANUP_KILL_SECONDS = 0.5
CLEANUP_DRAIN_SECONDS = 1.0


def process_owner(proc, *, group_created=False):
    """Capture ownership immediately after our own Process/Popen.start."""
    return {"pid": proc.pid, "parent_pid": os.getpid(),
            "process_identity": process_identity(proc.pid), "group_created": group_created}


def cleanup_failure(proc, exc):
    return {"pid": getattr(proc, "pid", None), "status": "incomplete",
            "leader_alive": None, "group_alive": None, "leader_exit_code": None, "attempts": [],
            "errors": [{"operation": "cleanup_helper", "type": type(exc).__name__,
                        "errno": getattr(exc, "errno", None), "message": str(exc)}]}


def terminate_group(proc, *, owner=None, group_owner=None):
    """Bounded best effort. Return evidence; refusal never replaces termination."""
    started = time.monotonic()
    pid = getattr(proc, "pid", None)
    rec = {"pid": pid, "status": "incomplete", "attempts": [], "errors": [],
           "leader_alive": None, "group_alive": None, "leader_exit_code": None}
    if not proc or not pid:
        rec.update(status="not_started", leader_alive=False, group_alive=False, duration_s=0.0)
        return rec
    def action(operation, fn):
        try:
            value = fn()
            rec["attempts"].append({"operation": operation, "outcome": "ok"})
            return True, value
        except subprocess.TimeoutExpired:
            rec["attempts"].append({"operation": operation, "outcome": "wait_timeout"})
            return False, None
        except ProcessLookupError:
            rec["attempts"].append({"operation": operation, "outcome": "absent"})
            return False, "absent"
        except Exception as exc:
            error = {"operation": operation, "type": type(exc).__name__,
                     "errno": getattr(exc, "errno", None), "message": str(exc)}
            rec["errors"].append(error)
            rec["attempts"].append({"operation": operation, "outcome": "error", **error})
            return False, None
    def alive():
        ok, value = action("leader_probe", lambda: proc.poll() is None if hasattr(proc, "poll") else proc.is_alive())
        return value if ok else (False if value == "absent" else None)
    def owner_valid():
        return bool(owner and owner.get("pid") == pid and owner.get("parent_pid") == os.getpid()
                    and pid not in {0, 1, os.getpid(), os.getpgrp()})
    def identity_match(receipt=None):
        current = process_identity(pid)
        expected = owner.get("process_identity") or (receipt or {}).get("process_identity")
        if expected and current:
            if current != expected:
                rec["errors"].append({"operation": "ownership", "type": "IdentityMismatch", "errno": None,
                                      "message": "PID start identity differs from our created child"})
                return False
            return True
        return None
    def owns_pid():
        if not owner_valid():
            return False
        match = identity_match()
        # A still-live direct child cannot have its PID reused before reap.
        # Once reaped, unavailable identity is insufficient to signal that PID.
        return match is True or (match is None and alive() is True)
    def owns_group():
        if not owner_valid():
            return False
        receipt = group_owner() if callable(group_owner) else group_owner or {}
        known = bool(owner.get("group_created")) or (
            receipt.get("pid") == pid and receipt.get("process_group") == pid and receipt.get("session_id") == pid
            and (not owner.get("process_identity") or not receipt.get("process_identity")
                 or owner["process_identity"] == receipt["process_identity"]))
        match = identity_match(receipt)
        if match is False:
            return False
        try:
            if os.getpgid(pid) != pid or os.getsid(pid) != pid:
                return False
            return match is True or (match is None and alive() is True)
        except ProcessLookupError:
            return known  # no current PID exists; our recorded group may survive
        except Exception as exc:
            action("group_ownership_probe", lambda: (_ for _ in ()).throw(exc))
            return False
    def wait(seconds):
        action("wait", lambda: proc.wait(timeout=seconds) if hasattr(proc, "wait") else proc.join(timeout=seconds))
    try:
        group_term = False
        if owns_group():
            group_term, _ = action("group_sigterm", lambda: os.killpg(pid, signal.SIGTERM))
        else:
            rec["attempts"].append({"operation": "group_sigterm", "outcome": "skipped_unverified_group"})
        if alive() is True and not group_term and owns_pid():
            action("direct_terminate", proc.terminate)
        wait(CLEANUP_TERM_SECONDS)
        if owns_group():
            action("group_sigkill", lambda: os.killpg(pid, signal.SIGKILL))
        else:
            rec["attempts"].append({"operation": "group_sigkill", "outcome": "skipped_unverified_group"})
        if alive() is True and owns_pid():
            action("direct_kill", proc.kill)
        wait(CLEANUP_KILL_SECONDS)
        rec["leader_alive"] = alive()
        if owns_group():
            ok, value = action("group_probe", lambda: os.killpg(pid, 0))
            rec["group_alive"] = True if ok else (False if value == "absent" else None)
        ok, code = action("exit_code", lambda: proc.returncode if hasattr(proc, "returncode") else proc.exitcode)
        rec["leader_exit_code"] = code if ok else None
    except Exception as exc:
        # Guard unexpected adapter/probe errors as well as ordinary OS refusals.
        rec["errors"].append({"operation": "cleanup", "type": type(exc).__name__,
                              "errno": getattr(exc, "errno", None), "message": str(exc)})
    if rec["leader_alive"] is False and rec["group_alive"] is False and not rec["errors"]:
        rec["status"] = "confirmed"
    rec["duration_s"] = time.monotonic() - started
    return rec


class DeepSeekStreamProtocol:
    """Reduce turn results using the CLI's structured background wakeups.

    Single-result legacy streams remain supported. Text, costs and usage are
    never used to infer a continuation or completion.
    """
    def __init__(self):
        self.session_id = None
        self.final = None
        self.errors = []
        self.results = []
        self.tasks = {}
        self.sequence = 0
        self._result_ids = set()

    @staticmethod
    def _identifier(value):
        return isinstance(value, str) and bool(value.strip())

    def _error(self, message):
        self.errors.append(message)

    def _task(self, event):
        task_id, run_id = event.get("task_id"), event.get("run_id")
        if not self._identifier(task_id):
            self._error("task requires task_id")
            return None
        for field in ("run_id", "task_type", "tool_use_id"):
            if field in event and not self._identifier(event[field]):
                self._error("task optional " + field + " must be a nonempty string when present")
                return None
        return task_id, run_id

    def _continue(self, event):
        origin = event.get("origin")
        if not isinstance(origin, dict) or origin.get("kind") != "task-notification" or origin.get("producer") != "session-task":
            self._error("additional result requires task-notification origin")
            return
        matches = [task for task in self.tasks.values()
                   if task["is_backgrounded"] is True and task["task_type"] == "local_bash"
                   and self._identifier(task["run_id"]) and task["run_id"] == origin.get("runId")
                   and task["notification_run_id"] == task["run_id"] and task["status"] is not None
                   and task["notification_result_index"] is None]
        if len(matches) != 1:
            self._error("result origin has no unique unconsumed task notification")
            return
        matches[0]["notification_result_index"] = len(self.results)

    def consume(self, event):
        self.sequence += 1
        sid = event.get("session_id")
        if "session_id" in event:
            if not self._identifier(sid):
                self._error("invalid session_id")
            elif self.session_id is None:
                self.session_id = sid
            elif sid != self.session_id:
                self._error("cross-session event")
        kind, subtype = event.get("type"), event.get("subtype")
        if kind == "system" and subtype in {"task_started", "task_notification"}:
            if not self._identifier(sid) or sid != self.session_id:
                self._error("task event requires the locked session_id")
            key = self._task(event)
            if key is None:
                return
            if subtype == "task_started":
                if "is_backgrounded" in event and type(event["is_backgrounded"]) is not bool:
                    self._error("task_started requires boolean is_backgrounded")
                if key in self.tasks or (key[1] is not None and any(task["run_id"] == key[1] for task in self.tasks.values())):
                    self._error("duplicate task identity")
                    return
                self.tasks[key] = dict(task_id=key[0], run_id=key[1], session_id=sid,
                                       is_backgrounded=event.get("is_backgrounded"),
                                       task_type=event.get("task_type"),
                                       tool_use_id=event.get("tool_use_id"), started_sequence=self.sequence,
                                       status=None, notification_run_id=None, notification_match=None,
                                       notification_sequence=None, notification_result_index=None)
            else:
                # Include completed starts: a missing run ID must not redirect
                # a duplicate of an old notification to a newer pending task.
                candidates = [task for task in self.tasks.values()
                              if task["task_id"] == key[0] and task["session_id"] == sid
                              and (task["run_id"] is None or key[1] is None or task["run_id"] == key[1])]
                if len(candidates) != 1:
                    self._error("task notification has no unique matching task_started")
                    return
                task = candidates[0]
                if task["status"] is not None:
                    self._error("duplicate task notification")
                    return
                if task["tool_use_id"] is not None and event.get("tool_use_id") is not None and task["tool_use_id"] != event["tool_use_id"]:
                    self._error("task notification tool_use_id mismatch")
                if event.get("status") not in {"completed", "failed", "stopped"}:
                    self._error("invalid task notification status")
                    return
                task.update(status=event["status"], notification_run_id=key[1],
                            notification_match="weak" if task["run_id"] is None or key[1] is None else "strong",
                            notification_sequence=self.sequence)
            return
        if kind != "result":
            return
        if self.final is not None:
            if classify_result(self.final, 0) != "succeeded":
                self._error("unsuccessful intermediate result cannot be superseded")
            first = self.results[0]
            if not self._identifier(first["session_id"]) or not self._identifier(first["uuid"]) or first["result_index"] != 0:
                self._error("multiple results require indexed same-session identities")
            self._continue(event)
        elif event.get("origin") is not None:
            self._continue(event)
        index = event.get("result_index")
        if "result_index" in event or self.results:
            if type(index) is not int or index != len(self.results):
                self._error("result_index must be contiguous from zero")
        result_id = event.get("uuid")
        if "uuid" in event:
            if not self._identifier(result_id) or result_id in self._result_ids:
                self._error("invalid or duplicate result uuid")
            else:
                self._result_ids.add(result_id)
        if self.results and (not self._identifier(sid) or sid != self.session_id or not self._identifier(result_id)):
            self._error("additional result requires same-session identity and uuid")
        output = event.get("result")
        if classify_result(event, 0) == "succeeded" and (not isinstance(output, str) or not output.strip()):
            self._error("result report is empty or not text")
        self.results.append(dict(sequence=self.sequence, result_index=index, uuid=result_id, session_id=sid,
                                 subtype=subtype, is_error=event.get("is_error"),
                                 terminal_reason=event.get("terminal_reason"),
                                 stop_reason=event.get("stop_reason"), errors=event.get("errors"),
                                 api_error_status=event.get("api_error_status"),
                                 origin=event.get("origin"), total_cost_usd=event.get("total_cost_usd")))
        self.final = event

    def evidence(self):
        tasks = [task for task in self.tasks.values() if task["is_backgrounded"] is True]
        foreground = [task for task in self.tasks.values() if task["is_backgrounded"] is False]
        unqualified = [task for task in self.tasks.values() if task["is_backgrounded"] is None]
        incomplete = ["background task not terminated: " + task["task_id"] for task in tasks if task["status"] is None]
        incomplete += ["task notification has no result: " + task["task_id"] for task in tasks
                       if task["status"] is not None and task["notification_result_index"] is None]
        return dict(result_count=len(self.results), turn_results=self.results, background_tasks=tasks,
                    foreground_tasks=foreground, unqualified_tasks=unqualified,
                    background_task_failures=[task for task in tasks if task["status"] in {"failed", "stopped"}],
                    background_incomplete=incomplete)

    def classify(self, exit_code=0, *, interrupted=False, error=None):
        status = classify_result(self.final, exit_code, interrupted=interrupted, error=error or self.errors)
        if status == "succeeded" and self.evidence()["background_incomplete"]:
            return "unknown"
        return status


def run_deepseek(args):
    if args.max_turns <= 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        raise ValueError("max-turns and timeout must be positive")
    run, context, session = register(args, "deepseek-cli")
    print(f"RUN_DIR={run.path}", flush=True)
    (run.path / "artifacts").mkdir()
    prompt = Path(args.task).read_text() + context
    prompt += (f"\n\n# 本轮持久记录\n本轮唯一目录：{run.path}\n"
               f"在开始和每完成一个阶段后，用 Write 更新 {run.path / 'progress.md'}，明确「已完成／正在做／下一步」和中间结果、未做项。"
               f"测试输出、截图和调度脚本写入 {run.path / 'artifacts'}；此目录与 progress.md 是本轮特许写入范围。"
               "不要写其他 run 的日志；runner 自动事件不能代替你的语义进度。最终完整报告直接回答，由 runner 保存 output.md。\n")
    durable_text(run.path / "prompt.md", prompt, exclusive=True)
    command = build_deepseek_command(args, prompt, session if args.resume_mode == "native" else None, run=run)
    atomic_json(run.path / "command.json", command)
    run.event("dispatch_plan", command=command, cost_usd=None, cost_source="unknown; CLI estimate is not actual DeepSeek billing")
    proc, error, interrupted, stop_reason = None, None, False, None
    protocol = DeepSeekStreamProtocol()
    protocol_errors = protocol.errors
    cleanup_receipts, owner, drain_deadline, stream_incomplete = [], None, None, False
    started = time.monotonic()
    old_handlers = {}
    stopped = []
    def request_stop(signum, frame):
        stopped.append(signum)
    for sig in (signal.SIGTERM, signal.SIGINT):
        old_handlers[sig] = signal.signal(sig, request_stop)
    def cleanup_child():
        try:
            receipt = terminate_group(proc, owner=owner)
        except Exception as exc:
            receipt = cleanup_failure(proc, exc)
        cleanup_receipts.append(receipt)
        atomic_json(run.path / "process-cleanup.json", cleanup_receipts)
        run.event("process_cleanup", receipt=receipt)
    buffers, ended = {"stdout": b"", "stderr": b""}, set()
    # Backpressure bounds queued pipe chunks while fsync or snapshots are slow.
    messages = queue.Queue(maxsize=64)
    try:
        env = os.environ.copy()
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "CLAUDE_CODE_PLUGIN_DIRS", "CLAUDECODE"):
            env.pop(key, None)
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["GPXPV_AGENT_RUN_DIR"] = str(run.path)
        proc = subprocess.Popen(command, cwd=args.cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, start_new_session=True)
        owner = process_owner(proc, group_created=True)
        run.bind(pid=os.getpid(), child_pid=proc.pid, child_process_identity=owner["process_identity"])
        run.event("process_started", pid=proc.pid)
        for channel in buffers:
            threading.Thread(target=_read_pipe, args=(getattr(proc, channel), channel, messages), daemon=True).start()
        last_heartbeat = time.monotonic()
        def consume(channel, raw):
            text = raw.decode("utf-8", errors="replace")
            if channel == "stderr":
                run.event("stderr", text=text)
                with (run.path / "stderr.log").open("a", encoding="utf-8") as f:
                    f.write(redact(text) + "\n"); f.flush(); os.fsync(f.fileno())
                return
            try:
                event = json.loads(text)
                if not isinstance(event, dict):
                    raise ValueError("CLI event must be object")
            except ValueError:
                protocol_errors.append("invalid/non-object JSON on stdout")
                run.event("protocol_error", error="invalid/non-object JSON on stdout", text=text)
                return
            clean = redact(event)
            run.event("provider_event", event=clean)
            with (run.path / "transcript.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(clean, ensure_ascii=False) + "\n"); f.flush(); os.fsync(f.fileno())
            protocol.consume(clean)
            if protocol.session_id and not run.meta.get("session_id"):
                run.bind(session_id=protocol.session_id)
            if event.get("type") == "system" and event.get("subtype") == "init":
                run.bind(cli_reported_model=event.get("model"), model_verification="CLI report only; actual outbound model/effort unverified")
        def stop_if_requested():
            nonlocal interrupted, stop_reason, drain_deadline
            if drain_deadline is None and (stopped or time.monotonic() - started > args.timeout):
                interrupted = True
                stop_reason = "signal_" + str(stopped[0]) if stopped else "wall_clock_timeout"
                initial_signals = list(stopped)
                stopped.clear()
                run.event("termination_requested", reason=stop_reason, signals=initial_signals)
                cleanup_child()
                drain_deadline = time.monotonic() + CLEANUP_DRAIN_SECONDS
        while len(ended) < 2:
            stop_if_requested()
            if drain_deadline is not None and stopped:
                run.event("additional_termination_requested", signals=list(stopped), original_reason=stop_reason)
                stopped.clear()
            if drain_deadline is not None and time.monotonic() >= drain_deadline:
                stream_incomplete = True
                # Keep received bytes even when a denied cleanup leaves pipes open.
                for _ in range(messages.maxsize):
                    try:
                        channel, chunk = messages.get_nowait()
                    except queue.Empty:
                        break
                    if chunk:
                        buffers[channel] += chunk
                files = []
                for channel, raw in buffers.items():
                    if raw:
                        path = run.path / (channel + "-incomplete.txt")
                        durable_text(path, raw.decode("utf-8", errors="replace"), exclusive=True)
                        files.append(str(path))
                run.event("stream_drain_incomplete", files=files,
                          reason="bounded drain expired; cleanup or stream completion unconfirmed")
                for channel in buffers:
                    try:
                        getattr(proc, channel).close()
                    except OSError:
                        pass
                break
            try:
                channel, chunk = messages.get(timeout=0.25)
            except queue.Empty:
                if time.monotonic() - last_heartbeat >= 15:
                    run.event("heartbeat", child_pid=proc.pid)
                    last_heartbeat = time.monotonic()
                continue
            if chunk is None:
                if buffers[channel]:
                    consume(channel, buffers[channel]); buffers[channel] = b""
                ended.add(channel)
                continue
            buffers[channel] += chunk
            if len(buffers[channel]) > 64 * 1024 * 1024 and b"\n" not in buffers[channel]:
                protocol_errors.append("output line exceeds 64 MiB bound")
                artifact = run.path / (channel + "-oversize-" + str(len(protocol_errors)) + ".txt")
                durable_text(artifact, buffers[channel].decode("utf-8", errors="replace"), exclusive=True)
                run.event("protocol_error", error=protocol_errors[-1], complete_chunk_file=str(artifact))
                buffers[channel] = b""
            while b"\n" in buffers[channel]:
                line, buffers[channel] = buffers[channel].split(b"\n", 1)
                consume(channel, line)
        # EOF does not prove leader exit. Keep the original deadline/signals
        # active rather than entering an unrelated fixed wait timeout.
        while not stream_incomplete and proc.poll() is None:
            stop_if_requested()
            if drain_deadline is not None:
                break
            time.sleep(0.05)
    except BaseException as exc:
        error = f"{type(exc).__name__}: {exc}"
        run.event("runner_error", error=error)
        if proc:
            cleanup_child()
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            interrupted = True
    finally:
        if proc and not cleanup_receipts:
            cleanup_child()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        exit_code = proc.returncode if proc else None
        final = protocol.final
        provider_status = protocol.classify(exit_code, interrupted=interrupted, error=error)
        changes = None
        try:
            changes = run.snapshot("after")
        except Exception as exc:
            error = (error or "") + f" snapshot failed: {exc}"
            provider_status = "failed"
            run.event("snapshot_error", error=str(exc))
        scope_failed = bool(changes and changes.get("out_of_scope"))
        output = (final or {}).get("result") or ""
        if not isinstance(output, str):
            protocol_errors.append("final result is not text")
            output = json.dumps(output, ensure_ascii=False)
        if provider_status == "succeeded" and (not output.strip() or protocol_errors or scope_failed):
            provider_status = "failed"
        runner_exit_code = 0 if provider_status == "succeeded" and not scope_failed and bool(output.strip()) else (124 if stop_reason == "wall_clock_timeout" else 1)
        result = dict(process_cleanup=cleanup_receipts, cleanup_complete=all(x["status"] in {"confirmed", "not_started"} for x in cleanup_receipts),
                      stream_incomplete=stream_incomplete, runner_exit_code=runner_exit_code,
                      provider_status=provider_status, acceptance_status="failed" if scope_failed else "pending",
                      exit_code=exit_code, is_error=provider_status != "succeeded", error=error,
                      interrupted=interrupted, runner_terminal_reason=stop_reason, protocol_errors=protocol_errors, duration_s=round(time.monotonic() - started, 3),
                      cost_usd=None, cost_source="unknown", cli_reported_cost_usd=(final or {}).get("total_cost_usd"),
                      cost_note="CLI estimate is not authoritative DeepSeek billed cost.",
                      session_id=protocol.session_id or run.meta.get("session_id"),
                      subtype=(final or {}).get("subtype"), terminal_reason=(final or {}).get("terminal_reason"),
                      stop_reason=(final or {}).get("stop_reason"), errors=(final or {}).get("errors"),
                      api_error_status=(final or {}).get("api_error_status"), permission_denials=(final or {}).get("permission_denials"),
                      usage=(final or {}).get("usage"), num_turns=(final or {}).get("num_turns"),
                      **protocol.evidence(),
                      out_of_scope_changes=(changes or {}).get("out_of_scope"), incomplete_checks="Task acceptance requires independent review; provider completion is separate.")
        run.finish(result, output)
    print(f"REPORT={run.path / 'output.md'}")
    return runner_exit_code


def status_payload(records_root=RECORDS, history_root=HISTORY):
    items, records, unknown = [], [], []
    records_root, history_root = Path(records_root), Path(history_root)
    for meta_file in sorted(records_root.rglob("meta.json")):
        if "snapshots" in meta_file.parts:
            continue
        # Archived offline fixture records are evidence, not real dispatches.
        if any((parent / ".offline-fixture").exists() for parent in meta_file.parents if parent != records_root and records_root in parent.parents):
            continue
        run = RunStore(meta_file.parent); meta = run.meta
        if not meta.get("run_id"):
            # Older manually registered native records remain visible as unknown.
            st = read_json(run.path / "result.json") or read_json(run.path / "status.json") or {}
            state = st.get("status", "unknown")
            if state in {"running", "dispatched", "planned"}:
                state = "unknown"
            record = {"run_dir": str(run.path), "name": meta.get("name", run.path.name), "state": state, "source": "project-legacy-record", "provider": meta.get("provider", "native")}
        else:
            st = run.effective_status(); state = st.get("status", "unknown")
            record = {"run_dir": str(run.path), "name": meta.get("name", run.path.name), "state": state, "source": "project-records", "provider": meta.get("provider"), "reason": st.get("reason")}
        records.append(record)
        if state == "running":
            items.append({"kind": record["provider"] or "agent", "name": record["name"], "since": meta.get("started_utc", ""), "detail": str(run.path), "aux": False, "source": record["source"], "state": state})
        elif state == "unknown":
            unknown.append(record)
    legacy_ledger = history_root / "api-runs/LEDGER.md"
    reconciliation = reconcile_legacy(legacy_ledger) if legacy_ledger.exists() else None
    for path in sorted((history_root / "api-runs").glob("*/status.txt")):
        if path.read_text().splitlines()[:1] == ["running"]:
            unknown.append({"name": path.parent.name, "state": "unknown", "source": "legacy-api-runs", "run_dir": str(path.parent), "reason": "legacy status has no verified owner identity"})
    # Keep auxiliary fields consumed by Tools/mods/background-tasks. Only live
    # process evidence counts; command text is never emitted (may carry prompts).
    try:
        ps = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, timeout=3)
        for line in ps.stdout.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) != 2:
                continue
            pid, name = fields
            if name.endswith("/xcodebuild") or name.endswith("/synthrunner") or ("app.noindex/GPXPointViewer.app/" in name):
                items.append({"kind": "auxiliary", "name": Path(name).name, "since": "", "detail": "process " + pid, "aux": True, "source": "live-process"})
    except (OSError, subprocess.TimeoutExpired):
        pass
    return {"time": dt.datetime.now().strftime("%H:%M:%S"), "running": sum(not i["aux"] for i in items),
            "ledger_usd": reconciliation["known_total_usd"] if reconciliation else None,
            "ledger_source": str(legacy_ledger), "ledger_note": "Historical SDK arithmetic, not actual bill or current balance.",
            "ledger_unknown_costs": reconciliation["unknown_costs"] if reconciliation else [],
            "items": items, "unknown": unknown, "records": records,
            "sources": [{"kind": "project-records", "path": str(records_root)}, {"kind": "legacy-api-runs", "path": str(history_root / 'api-runs')}, {"kind": "legacy-workflow-registry", "path": str(history_root / 'registry/TASK_REGISTRY.json'), "historical_only": True}]}


def common_registration(parser):
    parser.add_argument("name"); parser.add_argument("task")
    parser.add_argument("--records-root", type=Path, default=RECORDS)
    parser.add_argument("--cwd", type=Path, default=REPO)
    parser.add_argument("--provider", default="codex-native")
    parser.add_argument("--model", required=True)
    parser.add_argument("--effort", required=True)
    parser.add_argument("--watch", action="append")
    parser.add_argument("--exclude-path", action="append", default=[], help="Explicit generated-output exclusion from source snapshots")
    parser.add_argument("--allow-write", action="append", default=[])
    parser.add_argument("--resume", type=Path)
    parser.add_argument("--resume-mode", choices=["context", "native"], default="context")
    parser.add_argument("--recovery-plan", type=Path)
    parser.add_argument("--project-index", type=Path, help="Explicit real AGENT_LOG target; offline fixtures leave unset")
    parser.add_argument("--no-project-index", action="store_true", help="Write only the records-root local index")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    init = sub.add_parser("init"); common_registration(init)
    event = sub.add_parser("event"); event.add_argument("run"); event.add_argument("--type", required=True); event.add_argument("--json", default="{}")
    bind = sub.add_parser("bind"); bind.add_argument("run"); bind.add_argument("--agent-id"); bind.add_argument("--session-id"); bind.add_argument("--pid", type=int)
    finish = sub.add_parser("finish"); finish.add_argument("run"); finish.add_argument("--provider-status", choices=["succeeded", "failed", "interrupted", "unknown"], required=True)
    finish.add_argument("--acceptance", choices=["passed", "failed", "pending", "partial"], default="pending"); finish.add_argument("--output", type=Path, required=True); finish.add_argument("--exit-code", type=int)
    verify = sub.add_parser("verify"); verify.add_argument("run"); verify.add_argument("--status", choices=["passed", "failed", "incomplete"], required=True); verify.add_argument("--evidence", type=Path, required=True); verify.add_argument("--note", default="")
    snapshot = sub.add_parser("snapshot"); snapshot.add_argument("run"); snapshot.add_argument("label")
    status = sub.add_parser("status"); status.add_argument("--json", action="store_true"); status.add_argument("--records-root", type=Path, default=RECORDS); status.add_argument("--history-root", type=Path, default=HISTORY)
    rec = sub.add_parser("reconcile"); rec.add_argument("ledger", type=Path); rec.add_argument("--output", type=Path, required=True)
    ds = sub.add_parser("deepseek"); common_registration(ds)
    ds.set_defaults(model="deepseek-flash", effort="max")
    # Explicit fixed values avoid silently changing user-requested routing.
    for action in ds._actions:
        if action.dest in {"model", "effort"}:
            action.required = False
    ds.add_argument("--allow-command", action="append", default=[])
    ds.add_argument("--cli", default=str(Path.home() / "bin/claude-ds")); ds.add_argument("--cli-arg", action="append", default=[])
    ds.add_argument("--max-turns", type=int, default=40); ds.add_argument("--timeout", type=float, default=1800)
    args = parser.parse_args(argv)
    try:
        if args.action == "init":
            run, _, _ = register(args); print(json.dumps({"run_dir": str(run.path)})); return 0
        if args.action == "event":
            print(json.dumps(RunStore(args.run).event(args.type, **json.loads(args.json)), ensure_ascii=False)); return 0
        if args.action == "bind":
            RunStore(args.run).bind(**{k: v for k, v in vars(args).items() if k in {"agent_id", "session_id", "pid"} and v is not None}); return 0
        if args.action == "finish":
            run = RunStore(args.run)
            if not (run.path / "snapshots/after").exists():
                changes = run.snapshot("after")
            else:
                changes = read_json(run.path / "changes.json", {})
            acceptance = "failed" if changes.get("out_of_scope") else args.acceptance
            result = run.finish({"provider_status": args.provider_status, "acceptance_status": acceptance, "exit_code": args.exit_code}, args.output.read_text()); return 0 if result["run_status"] == "succeeded" and acceptance in {"pending", "passed"} else 1
        if args.action == "snapshot":
            print(json.dumps(RunStore(args.run).snapshot(args.label), ensure_ascii=False)); return 0
        if args.action == "verify":
            print(json.dumps(RunStore(args.run).verify(args.status, args.evidence, args.note), ensure_ascii=False)); return 0 if args.status == "passed" else 1
        if args.action == "reconcile":
            report = reconcile_legacy(args.ledger)
            if args.output.exists():
                raise FileExistsError("reconciliation output exists; choose a new file")
            args.output.parent.mkdir(parents=True, exist_ok=True); atomic_json(args.output, report); print(json.dumps(report, ensure_ascii=False)); return 0
        if args.action == "status":
            payload = status_payload(args.records_root, args.history_root)
            if args.json:
                print(json.dumps(redact(payload), ensure_ascii=False))
            else:
                print(f"现在有 {payload['running']} 个已核验运行任务；{len(payload['unknown'])} 个状态未知记录。")
                for item in payload["items"]:
                    print(f"- {item['kind']} · {item['name']} · {item['detail']}")
                for item in payload["unknown"]:
                    print(f"- unknown · {item['name']} · {item['run_dir']}")
                print(f"历史 SDK 台账已知费用合计 {payload['ledger_usd']} USD；未知 {len(payload['ledger_unknown_costs'])} 条；非实际账单或实时余额。")
            return 0
        if args.action == "deepseek":
            if args.model != "deepseek-flash" or args.effort != "max":
                raise ValueError("DeepSeek runner requires --model deepseek-flash --effort max")
            return run_deepseek(args)
    except Exception as exc:
        print(redact(f"{type(exc).__name__}: {exc}"), file=sys.stderr); return 2


if __name__ == "__main__":
    raise SystemExit(main())
