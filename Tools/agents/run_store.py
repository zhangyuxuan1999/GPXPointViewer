#!/usr/bin/env python3
"""Durable, append-only run evidence. No provider SDK or network dependency.

Permission lists are task constraints, not a filesystem sandbox. Snapshots detect
out-of-scope writes and retain regular files, including untracked/staged files.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager

REPO = Path(__file__).resolve().parents[2]
RECORDS = REPO / "Tools/agents/records"
HISTORY = Path.home() / ".claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results"
DEFAULT_WATCH = ["GPXPointViewer", "GPXQuickLook", "GPXThumbnail", "Tests", "Tools", "docs", "README.md", "AGENTS.md"]
EXCLUDE_PARTS = {".git", ".agents", ".codex", ".aws", "__pycache__", "node_modules", "sdkenv", "DerivedData"}
EXCLUDE_PREFIXES = ("Tools/agents/records", "Tools/agents/runs", "Tests/reports", "Tests/ui/app.noindex", "Tests/ui/perf", "Tests/ui/synth.gpx", "Tests/exam/results", "Tests/synth/runner/synthrunner", "Tests/synth/runner/build.log")
GENERATED_PATTERN = r"^Tests/synth/(?:format-edge|garmin-tunnels|legit-motion|replay-artefacts|scale-mixed|stationary-noise)/[^/]+\.(?:gpx|csv|fit|bin)$"
TERMINAL = {"succeeded", "failed", "interrupted", "unknown"}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def redact(value):
    """Preserve ordinary inputs/results; drop reasoning and common credentials."""
    if dataclasses.is_dataclass(value):
        value = dataclasses.asdict(value)
    if isinstance(value, dict):
        if str(value.get("type", "")).lower() in {"thinking", "thinking_delta", "redacted_thinking"}:
            return {"type": "reasoning_omitted"}
        result = {}
        for k, v in value.items():
            if str(k).lower() in {"thinking", "reasoning", "reasoning_content", "reasoning_details", "chain_of_thought", "signature"}:
                continue
            if re.search(r"(?i)^(?:authorization|auth|auth_token|token|api[_-]?key|x-api-key|password|secret|access_token|refresh_token)$", str(k)):
                result[k] = "[REDACTED]"
            else:
                result[k] = redact(v)
        return result
    if isinstance(value, (list, tuple)):
        return [redact(v) for v in value]
    if isinstance(value, (Path,)):
        return str(value)
    if isinstance(value, str):
        if value.lstrip().startswith(("{", "[")):
            try:
                parsed = json.loads(value)
                clean = redact(parsed)
                if clean != parsed:
                    return json.dumps(clean, ensure_ascii=False)
            except (ValueError, TypeError):
                pass
        value = re.sub(r"\bsk-[A-Za-z0-9_-]+", "[REDACTED]", value)
        value = re.sub(r"(?i)(\b(?:Bearer|Basic)\s+)[A-Za-z0-9+/=_\-.]+", r"\1[REDACTED]", value)
        value = re.sub(r"(?im)((?:ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|API_KEY|AUTHORIZATION|AUTH_TOKEN|PASSWORD|SECRET|ACCESS_TOKEN|TOKEN)\s*[=:]\s*)[^\s\"']+", r"\1[REDACTED]", value)
        return value
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return str(value)


@contextmanager
def locked(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temp.open("x", encoding="utf-8") as f:
        json.dump(redact(value), f, ensure_ascii=False, indent=2, allow_nan=False)
        f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def durable_text(path, value, exclusive=False):
    with Path(path).open("x" if exclusive else "w", encoding="utf-8") as f:
        f.write(redact(value)); f.flush(); os.fsync(f.fileno())


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def process_identity(pid):
    if not pid:
        return None
    try:
        pid = int(pid)
        if sys.platform == "darwin":
            # Local SDK sys/proc_info.h proc_bsdinfo, PROC_PIDTBSDINFO=3.
            # libproc works for our owner even when sandbox policy blocks ps.
            import ctypes
            class BSDInfo(ctypes.Structure):
                _fields_ = [("head", ctypes.c_uint32 * 12), ("comm", ctypes.c_char * 16),
                            ("name", ctypes.c_char * 32), ("tail", ctypes.c_uint32 * 6),
                            ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]
            lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
            lib.proc_pidinfo.restype = ctypes.c_int
            info = BSDInfo()
            size = lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            if size == ctypes.sizeof(info) and info.head[3] == pid:
                return f"darwin:{pid}:{info.seconds}.{info.microseconds:06d}"
            return None
        if sys.platform.startswith("linux"):
            stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            return f"linux:{boot}:{pid}:{stat[19]}"
        p = subprocess.run(["ps", "-o", "lstart=", "-p", str(int(pid))], capture_output=True, text=True, timeout=3)
        return p.stdout.strip() if p.returncode == 0 and p.stdout.strip() else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def normalized_relative(cwd, path):
    raw = Path(path)
    absolute = Path(os.path.abspath(raw if raw.is_absolute() else Path(cwd) / raw))
    try:
        # Preserve a symlink itself, but never traverse a symlink parent outside
        # the declared workspace when reading snapshots.
        if absolute != Path(cwd).resolve():
            absolute.parent.resolve().relative_to(Path(cwd).resolve())
        return absolute.relative_to(Path(cwd).resolve()).as_posix()
    except ValueError:
        raise ValueError(f"scope must be inside cwd: {path}")


# Git is supplementary evidence: bounded separately from the file snapshot.
GIT_METADATA_TOTAL_SECONDS = 12.0
GIT_METADATA_COMMAND_SECONDS = 3.0
GIT_METADATA_CLEANUP_SECONDS = 0.2


def collect_git_metadata(cwd, dest, meta):
    watched = meta["watch"]
    policy = meta["snapshot_exclusions"]
    overrides = policy.get("explicit_overrides", [])
    regular = [p for p in watched if p not in overrides]
    scopes = []
    if regular or not overrides:
        scopes.append((regular, policy["prefixes"]))
    if overrides:
        scopes.append((overrides, policy.get("user_prefixes", []) + [
            prefix for prefix in policy["prefixes"]
            if not any(p == prefix or p.startswith(prefix + "/") for p in overrides)]))
    commands = [("head", ["rev-parse", "HEAD"], [], [])]
    base_commands = {"status": ["status", "--porcelain=v1", "-uall"],
                     "unstaged": ["diff", "--binary", "--no-ext-diff", "--no-textconv"],
                     "staged": ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"],
                     "untracked": ["ls-files", "--others", "--exclude-standard"]}
    for index, (scope, prefixes) in enumerate(scopes):
        pathspecs = ["." if p == "." else ":(literal)" + p for p in scope]
        pathspecs += [":(exclude,literal)" + p for p in dict.fromkeys(prefixes)]
        for part in sorted(EXCLUDE_PARTS):
            pathspecs += [":(exclude,glob)**/" + part, ":(exclude,glob)**/" + part + "/**"]
        try:
            own_run = dest.parent.parent.relative_to(cwd).as_posix()
        except ValueError:
            pass
        else:
            pathspecs.append(":(exclude,literal)" + own_run)
        for key, args in base_commands.items():
            commands.append((key + ("_explicit" if index else ""), args, scope, pathspecs))
    started = time.monotonic()
    deadline = started + GIT_METADATA_TOTAL_SECONDS
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    git = {}
    for key, args, scope, pathspecs in commands:
        argv = ["git", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", str(cwd), *args]
        if key != "head":
            argv += ["--", *pathspecs]
        t0 = time.monotonic()
        allowance = min(GIT_METADATA_COMMAND_SECONDS, deadline - t0)
        rec = {"argv": argv, "path": key + ".txt", "started_utc": now(),
               "exit_code": None, "timed_out": False, "attempted": False,
               "timeout_seconds": max(0.0, allowance), "error": None,
               "status": "skipped", "cleanup_complete": True, "watch": scope, "pathspecs": pathspecs}
        stdout = stderr = b""
        proc = None
        if key != "head" and not scope:
            rec["error"] = "empty watch scope; repository-wide fallback disabled"
        elif allowance <= 0:
            rec["error"] = "total Git metadata time budget exhausted"
        else:
            rec["attempted"] = True
            try:
                proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, start_new_session=True)
                try:
                    stdout, stderr = proc.communicate(timeout=allowance)
                    rec["status"] = "ok" if proc.returncode == 0 else "error"
                except subprocess.TimeoutExpired as exc:
                    rec.update(status="timeout", timed_out=True,
                               error="Git metadata command exceeded its time allowance")
                    stdout, stderr = exc.output or b"", exc.stderr or b""
                    # start_new_session establishes this command's own group.
                    # Never match names or signal any other Git/app process.
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                        rec["termination"] = "own_process_group_sigkill"
                    except ProcessLookupError:
                        pass
                    except OSError as kill_error:
                        rec["cleanup_error"] = str(kill_error)
                        proc.kill()
                    try:
                        stdout, stderr = proc.communicate(timeout=GIT_METADATA_CLEANUP_SECONDS)
                    except subprocess.TimeoutExpired as remaining:
                        stdout, stderr = remaining.output or stdout, remaining.stderr or stderr
                        rec["cleanup_complete"] = False
                        rec["cleanup_error"] = "output pipe still open after group termination"
                        proc.stdout.close(); proc.stderr.close()
                        try:
                            proc.wait(timeout=GIT_METADATA_CLEANUP_SECONDS)
                        except subprocess.TimeoutExpired:
                            rec["cleanup_error"] += "; leader wait exceeded cleanup allowance"
                rec["exit_code"] = proc.returncode
            except OSError as exc:
                rec.update(status="unavailable", error=f"{type(exc).__name__}: {exc}")
                if proc is not None:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait(timeout=GIT_METADATA_CLEANUP_SECONDS)
                    except (OSError, subprocess.TimeoutExpired) as cleanup_error:
                        rec.update(cleanup_complete=False, cleanup_error=str(cleanup_error))
                    rec["exit_code"] = proc.returncode
        rec.update(ended_utc=now(), duration_seconds=time.monotonic() - t0,
                   stdout_bytes=len(stdout), stderr_bytes=len(stderr))
        text = stdout.decode("utf-8", errors="replace") + stderr.decode("utf-8", errors="replace")
        if rec["status"] != "ok":
            text += f"\n[Git metadata {rec['status']}: {rec['error'] or 'nonzero exit'}; exit={rec['exit_code']}]\n"
        durable_text(dest / rec["path"], text)
        git[key] = rec
    git["_meta"] = {"complete": all(r["status"] == "ok" for r in git.values()),
                    "total_budget_seconds": GIT_METADATA_TOTAL_SECONDS,
                    "per_command_seconds": GIT_METADATA_COMMAND_SECONDS,
                    "cleanup_seconds": GIT_METADATA_CLEANUP_SECONDS,
                    "duration_seconds": time.monotonic() - started,
                    "watch": watched, "scopes": [{"watch": scope, "excluded_prefixes": prefixes} for scope, prefixes in scopes],
                    "optional_locks": False, "fsmonitor": False, "untracked_cache": False,
                    "meaning": "Supplementary Git evidence; unavailable/skipped/timeout is not a clean diff."}
    atomic_json(dest / "git.json", git)
    return git


class RunStore:
    def __init__(self, path):
        self.path = Path(path).resolve()

    @classmethod
    def create(cls, root, name, task, *, cwd=REPO, provider="native", model=None, effort=None,
               watch=None, allow_write=None, parent_run=None, recovery=None, index=False, project_index=None, exclude=None, **extra):
        root, cwd = Path(root).resolve(), Path(cwd).resolve()
        task_text = Path(task).read_text(encoding="utf-8")
        if not task_text.strip():
            raise ValueError("task must be nonempty")
        safe_name = re.sub(r"[^\w.-]+", "-", name).strip(".-")[:80] or "task"
        run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + "_" + safe_name + "_" + uuid.uuid4().hex[:8]
        root.mkdir(parents=True, exist_ok=True)
        path = root / run_id
        path.mkdir()
        store = cls(path)
        writable = [normalized_relative(cwd, p) for p in (allow_write or [])]
        watched = list(dict.fromkeys([normalized_relative(cwd, p) for p in (watch if watch is not None else DEFAULT_WATCH)] + writable))
        explicit = list(dict.fromkeys([normalized_relative(cwd, p) for p in (watch or [])] + writable))
        overrides = [p for p in explicit if any(p == prefix or p.startswith(prefix + "/") for prefix in EXCLUDE_PREFIXES)
                     or re.match(GENERATED_PATTERN, p)]
        user_excludes = [normalized_relative(cwd, p) for p in (exclude or [])]
        meta = dict(schema_version=1, run_id=run_id, name=name, provider=provider,
                    requested_model=model, requested_effort=effort, observed_model=None,
                    observed_effort=None, model_verification="unknown", cwd=str(cwd),
                    task_source=str(Path(task).resolve()), started_utc=now(), watch=watched,
                    allow_write=writable, snapshot_exclusions={"parts": sorted(EXCLUDE_PARTS), "prefixes": list(EXCLUDE_PREFIXES) + user_excludes, "default_prefixes": list(EXCLUDE_PREFIXES), "user_prefixes": user_excludes, "explicit_overrides": overrides, "generated_pattern": GENERATED_PATTERN},
                    parent_run=str(Path(parent_run).resolve()) if parent_run else None,
                    recovery=recovery or "New run; never replay side effects without checking existing evidence.",
                    cost_usd=None, cost_source="unknown", **extra)
        durable_text(path / "task.md", task_text, exclusive=True)
        atomic_json(path / "meta.json", meta)
        durable_text(path / "progress.md", "# 进度\n\n## 已完成\n- 已预登记任务。\n\n## 正在做\n- 等待派发。\n\n## 下一步\n- 按任务书执行并逐事件记录。\n", exclusive=True)
        atomic_json(path / "status.json", {"status": "planned", "provider_status": "unknown", "acceptance_status": "pending", "last_activity": now()})
        store.event("registered", meta=meta)
        with locked(root / ".agent-log.lock"):
            with (root / "AGENT_LOG.md").open("a", encoding="utf-8") as f:
                f.write(f"\n- {now()} planned `{run_id}` · {provider} · {model}/{effort} · [{safe_name}]({run_id}/task.md)\n"); f.flush(); os.fsync(f.fileno())
        # Also maintain the project-level index required by AGENTS.md.
        # Never infer permission to mutate a real index from fixture location.
        if index or project_index:
            index_path = Path(project_index) if project_index else REPO / "Tools/agents/AGENT_LOG.md"
            with locked(str(index_path) + ".lock"):
                with index_path.open("a", encoding="utf-8") as f:
                    f.write(f"\n- {now()} planned `{run_id}` · {provider} · {model}/{effort} · {path}\n"); f.flush(); os.fsync(f.fileno())
        return store

    @property
    def meta(self):
        return read_json(self.path / "meta.json", {})

    def event(self, event_type, **data):
        with locked(self.path / ".run.lock"):
            event = {**data, "time_utc": now(), "event_id": uuid.uuid4().hex, "type": event_type}
            with (self.path / "events.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(redact(event), ensure_ascii=False, allow_nan=False) + "\n"); f.flush(); os.fsync(f.fileno())
            status = read_json(self.path / "status.json", {})
            status["last_activity"] = now()
            atomic_json(self.path / "status.json", status)
            if event_type in {"bound", "dispatch", "process_started", "budget_reserved", "termination_requested", "runner_error", "snapshot"}:
                with (self.path / "progress.md").open("a", encoding="utf-8") as f:
                    f.write(f"\n\n## 阶段更新 {now()}\n### 已完成\n- 已持久记录 `{event_type}`，完整输入/结果见 events.jsonl。\n### 正在做\n- runner 状态：{status.get('status', 'unknown')}。\n### 下一步\n- 继续当前任务；恢复前核验既有产物与最后正常工具结果。\n")
                    f.flush(); os.fsync(f.fileno())
        return event

    def bind(self, **data):
        if data.get("pid"):
            data["process_identity"] = process_identity(data["pid"])
        with locked(self.path / ".run.lock"):
            meta = self.meta; meta.update(redact(data)); atomic_json(self.path / "meta.json", meta)
            status = read_json(self.path / "status.json", {})
            status.update(status="running", last_activity=now())
            atomic_json(self.path / "status.json", status)
        self.event("bound", **data)

    def snapshot(self, label):
        if not re.fullmatch(r"[\w-]+", label):
            raise ValueError("invalid snapshot label")
        meta = self.meta; cwd = Path(meta["cwd"])
        dest = self.path / "snapshots" / label
        dest.mkdir(parents=True, exist_ok=False)
        files = {}
        candidates = set()
        policy = meta["snapshot_exclusions"]
        overrides = policy.get("explicit_overrides", [])
        def excluded(rel):
            p = cwd / rel
            if any(x in EXCLUDE_PARTS for x in Path(rel).parts) or p == self.path or self.path in p.parents:
                return True
            if any(x == "." or rel == x or rel.startswith(x + "/") for x in policy.get("user_prefixes", [])):
                return True
            explicit = any(rel == x or rel.startswith(x + "/") or x.startswith(rel + "/") for x in overrides)
            if any(rel == x or rel.startswith(x + "/") for x in policy["prefixes"]) and not explicit:
                return True
            return bool(re.match(GENERATED_PATTERN, rel)) and not any(rel == x or rel.startswith(x + "/") for x in overrides)
        for item in meta["watch"]:
            p = cwd / item
            if p.is_dir() and not p.is_symlink():
                for base, dirs, names in os.walk(p, followlinks=False):
                    relbase = Path(base).relative_to(cwd).as_posix()
                    dirs[:] = [d for d in dirs if not excluded((Path(relbase) / d).as_posix())]
                    for name in names:
                        candidates.add(Path(base) / name)
                    for name in dirs:
                        if (Path(base) / name).is_symlink():
                            candidates.add(Path(base) / name)
            elif p.exists() or p.is_symlink():
                candidates.add(p)
        for p in sorted(candidates):
            rel = p.relative_to(cwd).as_posix()
            # Re-check at snapshot time; a directory may have been replaced by a
            # symlink since registration or the previous snapshot.
            normalized_relative(cwd, p)
            if excluded(rel):
                continue
            if p.is_symlink():
                files[rel] = {"kind": "symlink", "target": os.readlink(p)}
                continue
            if not p.is_file():
                continue
            target = dest / "files" / rel; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, target)
            with target.open("rb") as stream:
                if hasattr(hashlib, "file_digest"):
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                else:
                    hasher = hashlib.sha256()
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        hasher.update(block)
                    digest = hasher.hexdigest()
            files[rel] = {"kind": "file", "sha256": digest, "size": target.stat().st_size, "mode": p.stat().st_mode & 0o777}
        atomic_json(dest / "manifest.json", {"time_utc": now(), "files": files, "watch": meta["watch"], "exclusions": meta["snapshot_exclusions"]})
        # Persist the authoritative file changes before supplementary Git work.
        changes = None
        if label == "after" and (self.path / "snapshots/before/manifest.json").exists():
            before = read_json(self.path / "snapshots/before/manifest.json")["files"]
            changes = {"added": sorted(files.keys() - before.keys()), "deleted": sorted(before.keys() - files.keys()), "modified": sorted(k for k in files.keys() & before.keys() if files[k] != before[k])}
            changes["out_of_scope"] = sorted(p for paths in changes.values() for p in paths if not any(x == "." or p == x or p.startswith(x.rstrip("/") + "/") for x in meta["allow_write"]))
            changes["attribution"] = "Difference from baseline; concurrent shared-workspace writes cannot be attributed automatically."
            atomic_json(self.path / "changes.json", changes)
        git = collect_git_metadata(cwd, dest, meta)
        self.event("snapshot", label=label, file_count=len(files), manifest=str(dest / "manifest.json"),
                   git_metadata_complete=git["_meta"]["complete"], git_metadata=str(dest / "git.json"))
        return changes if changes is not None else {"files": files}

    def finish(self, result, output=""):
        with locked(self.path / ".run.lock"):
            if (self.path / "result.json").exists():
                raise FileExistsError("run is already finalized; record acceptance in a new event, never overwrite the result")
            result = dict(result)
            result.setdefault("provider_status", "unknown")
            result.setdefault("acceptance_status", "pending")
            result.setdefault("cost_usd", None)
            result.setdefault("finished_utc", now())
            result.setdefault("session_id", self.meta.get("session_id"))
            result.setdefault("exit_code", None)
            if result["provider_status"] not in TERMINAL:
                raise ValueError("invalid provider_status")
            if result["acceptance_status"] not in {"passed", "failed", "pending", "partial"}:
                raise ValueError("invalid acceptance_status")
            if result["provider_status"] == "succeeded" and (not isinstance(output, str) or not output.strip()):
                result["acceptance_status"] = "failed"
                result["artifact_error"] = "required final report is empty or not text"
                if not isinstance(output, str):
                    output = json.dumps(redact(output), ensure_ascii=False)
            # Provider completion never implies task acceptance.
            status = result["provider_status"]
            if result["acceptance_status"] == "failed":
                status = "failed"
            result["status"] = status
            result["run_status"] = status
            result["verification_status"] = {"passed": "passed", "failed": "failed", "partial": "incomplete", "pending": "not_run"}.get(result["acceptance_status"], "not_run")
            output_path = self.path / "output.md"
            prepared_output = redact(output or "(No final provider output; inspect events and result.)\n")
            if output_path.exists():
                if output_path.read_text() != prepared_output:
                    conflict = self.path / ("output-conflict-" + uuid.uuid4().hex + ".md")
                    durable_text(conflict, prepared_output, exclusive=True)
                    with (self.path / "events.jsonl").open("a", encoding="utf-8") as f:
                        f.write(json.dumps({"time_utc": now(), "event_id": uuid.uuid4().hex,
                                           "type": "output_conflict", "preserved_output": str(output_path),
                                           "candidate_output": str(conflict)}, ensure_ascii=False) + "\n")
                        f.flush(); os.fsync(f.fileno())
                    raise FileExistsError(f"existing output differs; preserved original and candidate {conflict}")
            else:
                durable_text(output_path, prepared_output, exclusive=True)
            atomic_json(self.path / "result.json", result)
            atomic_json(self.path / "status.json", {"status": status, "provider_status": result["provider_status"], "acceptance_status": result["acceptance_status"], "last_activity": now()})
        self.event("finalized", result=result)
        with (self.path / "progress.md").open("a", encoding="utf-8") as f:
            f.write(f"\n\n## Runner 收尾 {now()}\n- provider={result['provider_status']}，验收={result['acceptance_status']}。\n- 下一步：核验 output/result/events/changes；未完成项须新建关联轮次恢复。\n")
            f.flush(); os.fsync(f.fileno())
        return result

    def effective_status(self, stale_seconds=120):
        status = dict(read_json(self.path / "status.json", {"status": "unknown"}))
        verification = read_json(self.path / "verification.json")
        if verification:
            status["verification_status"] = verification["verification_status"]
            if verification["verification_status"] == "failed":
                status["status"] = "failed"
        if status.get("status") != "running":
            return status
        meta = self.meta
        pid, identity = meta.get("pid"), meta.get("process_identity")
        try:
            recent = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(status["last_activity"])).total_seconds() <= stale_seconds
        except (ValueError, KeyError, TypeError):
            recent = False
        if pid:
            live = bool(identity) and process_identity(pid) == identity
        else:
            # Native agent IDs are not OS processes; lack of fresh evidence is unknown.
            live = bool(meta.get("agent_id")) and recent
        if not live:
            status.update(status="unknown", reason="owner process absent/reused or native agent heartbeat stale; inspect before recovery")
        return status

    def verify(self, verification_status, evidence, note=""):
        if verification_status not in {"passed", "failed", "incomplete"}:
            raise ValueError("invalid verification status")
        if not (self.path / "result.json").exists():
            raise ValueError("finalize provider execution before independent verification")
        evidence = Path(evidence).resolve()
        if not evidence.is_file() or not evidence.stat().st_size:
            raise ValueError("verification requires nonempty evidence file")
        result = read_json(self.path / "result.json", {})
        if verification_status == "passed" and result.get("run_status") != "succeeded":
            raise ValueError("cannot pass verification of failed/interrupted/unknown execution")
        receipt = {"time_utc": now(), "verification_status": verification_status,
                   "evidence": str(evidence), "evidence_sha256": hashlib.sha256(evidence.read_bytes()).hexdigest(), "note": note}
        dest = self.path / ("verification-evidence-" + uuid.uuid4().hex + ".txt")
        durable_text(dest, evidence.read_text(errors="replace"), exclusive=True)
        receipt["saved_evidence"] = str(dest)
        self.event("verification", **receipt)
        atomic_json(self.path / "verification.json", receipt)
        return receipt


def classify_result(final, exit_code=0, *, interrupted=False, error=None):
    """Use structured termination fields; never infer success from missing output."""
    if interrupted:
        return "interrupted"
    if error:
        return "failed"
    if exit_code is None or exit_code < 0:
        return "failed"  # no verified exit, or the child itself died from a signal
    if not final:
        return "unknown" if exit_code == 0 else "failed"
    if final.get("api_error_status"):
        return "failed"
    # Limit finals are unsuccessful completions; the CLI normally exits 1.
    # Explicit runner/protocol/API errors still take precedence over this reason.
    if final.get("subtype") in {"error_max_turns", "error_max_budget_usd"} or final.get("terminal_reason") in {"max_turns", "max_budget_usd", "budget"}:
        return "interrupted"
    if exit_code != 0:
        return "failed"
    if final.get("is_error") is not False or final.get("api_error_status") or final.get("errors"):
        return "failed"
    if final.get("subtype") != "success":
        return "failed"
    reason = final.get("terminal_reason")
    if reason in {"aborted_streaming", "aborted_tools", "interrupted", "cancelled"}:
        return "interrupted"
    if reason not in {None, "completed"}:
        return "failed"
    return "succeeded"


def reconcile_legacy(ledger):
    """Read-only arithmetic reconciliation; USD columns are not actual invoices."""
    ledger = Path(ledger).resolve()
    rows, unknown = [], []
    for number, line in enumerate(ledger.read_text().splitlines(), 1):
        parts = [x.strip() for x in line.split("|")]
        if len(parts) < 10:
            continue
        if not re.match(r"^\d{4}", parts[1]) or not parts[8]:
            continue
        try:
            cost = float(parts[6])
        except ValueError:
            cost = None
        try:
            cumulative = float(parts[7])
        except ValueError:
            cumulative = None
        if cost is not None and (not math.isfinite(cost) or cost < 0):
            cost = None
        result_path = ledger.parent / parts[8] / "result.json"
        result = read_json(result_path)
        # Old runner invented zero when no final message arrived.
        anomaly = cost == 0 and (not result or result.get("num_turns") is None or result.get("is_error"))
        if anomaly:
            unknown.append({"line": number, "run": parts[8], "reason": "historical zero lacks reliable final cost", "source": str(result_path)})
            cost = None
        elif cost is None:
            unknown.append({"line": number, "run": parts[8], "reason": "ledger cost is unknown or invalid", "source": str(ledger)})
        rows.append({"line": number, "run": parts[8], "cost_usd": cost, "legacy_cumulative_usd": cumulative})
    known = sum(x["cost_usd"] for x in rows if x["cost_usd"] is not None)
    return {"generated_utc": now(), "source": str(ledger), "source_sha256": hashlib.sha256(ledger.read_bytes()).hexdigest(), "known_total_usd": round(known, 8), "unknown_costs": unknown, "rows": rows, "last_legacy_cumulative_usd": rows[-1]["legacy_cumulative_usd"] if rows else None, "meaning": "SDK ledger arithmetic only; not account balance or actual billed charges."}


class BudgetLedger:
    """One lock protects check + reservation + settlement. Unknown cost holds reserve."""
    def __init__(self, path, config):
        self.path = Path(path).resolve()
        self.config = dict(config)
        capacity = self.config.get("capacity_usd")
        if not isinstance(capacity, (int, float)) or not math.isfinite(capacity) or capacity <= 0 or not self.config.get("source"):
            raise ValueError("budget config requires positive capacity_usd and an explicit source")
        base = self.config.get("baseline_known_usd", 0)
        if not isinstance(base, (int, float)) or not math.isfinite(base) or base < 0:
            raise ValueError("baseline_known_usd must be finite and nonnegative")

    def _load(self):
        state = read_json(self.path)
        if self.path.exists() and (not isinstance(state, dict) or not isinstance(state.get("runs"), dict)):
            raise ValueError("budget ledger is corrupt; refusing allocation until explicit reconciliation")
        fingerprint = hashlib.sha256(json.dumps(self.config, sort_keys=True).encode()).hexdigest()
        if state and state.get("config_sha256") != fingerprint:
            raise ValueError("budget configuration changed; reconcile into a new ledger explicitly")
        return state or {"schema_version": 1, "config_sha256": fingerprint, "config": self.config, "runs": {}}

    def reserve(self, run_id, amount):
        if not math.isfinite(amount) or amount <= 0:
            raise ValueError("reservation must be positive")
        with locked(str(self.path) + ".lock"):
            state = self._load()
            if run_id in state["runs"]:
                if state["runs"][run_id]["reserved_usd"] == amount:
                    return amount
                raise ValueError("conflicting duplicate reservation")
            base = float(self.config.get("baseline_known_usd", 0))
            if self.config.get("baseline_unknown_costs"):
                raise ValueError("unresolved historical costs: reconcile before allocating budget")
            if any(row.get("status") == "unknown_cost_hold" for row in state["runs"].values()):
                raise ValueError("unresolved run cost: automatic budget allocation frozen until reconciliation")
            used = base + sum(r["cost_usd"] if r.get("cost_usd") is not None else r["reserved_usd"] for r in state["runs"].values())
            if used + amount > self.config["capacity_usd"] + 1e-9:
                raise ValueError("insufficient unreserved configured budget")
            state["runs"][run_id] = {"reserved_usd": amount, "cost_usd": None, "status": "reserved", "time_utc": now()}
            atomic_json(self.path, state)
        return amount

    def settle(self, run_id, cost):
        if cost is not None and (not isinstance(cost, (int, float)) or not math.isfinite(cost) or cost < 0):
            raise ValueError("invalid cost")
        with locked(str(self.path) + ".lock"):
            state = self._load(); row = state["runs"][run_id]
            if row["status"] != "reserved":
                if row.get("cost_usd") == cost:
                    return row
                raise ValueError("reservation already settled; corrections require reconciliation")
            row.update(cost_usd=cost, status="settled" if cost is not None else "unknown_cost_hold", finished_utc=now())
            atomic_json(self.path, state)
        return row
