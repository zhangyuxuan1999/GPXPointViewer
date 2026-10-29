#!/usr/bin/env python3
"""Bounded, logged smoke test of the existing claude-ds wrapper.

Usage: python3 Tools/agents/deepseek_probe.py <new/pre-registered run directory>
Requires task.md and fixture.txt. Never overwrites a previous attempt.
The local observer forwards only to api.deepseek.com and records request
configuration (never headers/credentials), normal messages, tools and results.
This is a diagnostic, not a general task runner or a billing meter.
"""
import datetime
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def transcript_evidence(messages):
    """Require a successful result for the actual Read call, not just intent."""
    read_ids = set()
    successful_ids = set()
    final = None
    for event in messages:
        if event.get("type") == "result":
            final = event
        content = event.get("message", {}).get("content", [])
        if not isinstance(content, list):
            continue
        for block in content:
            if block.get("type") == "tool_use" and block.get("name") == "Read":
                read_ids.add(block.get("id"))
            if block.get("type") == "tool_result" and not block.get("is_error", False):
                successful_ids.add(block.get("tool_use_id"))
    return bool((read_ids & successful_ids) - {None}), final


def main():
    run = Path(sys.argv[1]).resolve()
    prompt = (run / "task.md").read_text()
    (run / "fixture.txt").read_text()
    # Exclusive creation prevents retries from destroying earlier evidence.
    events = (run / "events.jsonl").open("x", encoding="utf-8")
    lock = threading.Lock()
    requests = []
    http_statuses = []

    def record(event):
        with lock:
            events.write(json.dumps({"time_utc": now(), **event}, ensure_ascii=False) + "\n")
            events.flush()

    class Observer(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            if not self.path.startswith("/anthropic/v1/messages"):
                self.send_error(404)
                return
            body = self.rfile.read(int(self.headers.get("content-length", "0")))
            conn = None
            try:
                obj = json.loads(body)
                entry = {k: obj.get(k) for k in ("model", "thinking", "output_config", "stream", "max_tokens")}
                entry["tools"] = [t.get("name") for t in obj.get("tools", [])]
                requests.append(entry)
                record({"type": "request_configuration", **entry})
                conn = http.client.HTTPSConnection("api.deepseek.com", timeout=90)
                headers = {k: v for k, v in self.headers.items()
                           if k.lower() not in ("host", "content-length", "connection", "accept-encoding")}
                conn.request("POST", self.path, body, headers)
                response = conn.getresponse()
                http_statuses.append(response.status)
                record({"type": "http_status", "status": response.status})
                self.send_response(response.status)
                for k, v in response.getheaders():
                    if k.lower() not in ("transfer-encoding", "connection", "content-length", "content-encoding"):
                        self.send_header(k, v)
                self.end_headers()
                while True:
                    chunk = response.read1(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except Exception as exc:
                record({"type": "observer_error", "error_type": type(exc).__name__})
            finally:
                if conn:
                    conn.close()

    server = None
    proc = None
    result = {"status": "error", "cost_usd": None, "started_utc": now()}
    start = time.monotonic()
    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Observer)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        wrapper = (Path.home() / "bin/claude-ds").read_text()
        endpoint = "https://api.deepseek.com/anthropic"
        if wrapper.count(endpoint) != 1:
            raise ValueError("wrapper endpoint changed; inspect before running")
        # Existing authentication remains in memory, passed through stdin only.
        # Never write a copied wrapper with its credential into the repository.
        wrapper = wrapper.replace(endpoint, f"http://127.0.0.1:{server.server_port}/anthropic")
        args = ["/bin/zsh", "-s", "--", "-p", prompt,
                "--tools", "Read", "--allowedTools", "Read", "--strict-mcp-config",
                "--mcp-config", '{"mcpServers":{}}', "--permission-mode", "dontAsk",
                "--effort", "max", "--max-turns", "4", "--setting-sources", "",
                "--safe-mode", "--no-session-persistence", "--output-format", "stream-json",
                "--verbose", "--system-prompt",
                "Read only the synthetic fixture in the current directory. Follow the task and answer concisely."]
        (run / "command.json").write_text(json.dumps(args, ensure_ascii=False, indent=2) + "\n")
        env = dict(os.environ)
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "CLAUDE_CODE_PLUGIN_DIRS"):
            env.pop(key, None)
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "2048"
        record({"type": "dispatch", "transport": "existing claude-ds wrapper via observer", "effort": "max"})
        proc = subprocess.Popen(args, cwd=run, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = proc.communicate(wrapper, timeout=180)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                stdout, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                stdout, stderr = proc.communicate()
        # Defense in depth: the fixture contains no secrets; redact any token
        # accidentally included by CLI diagnostics, without logging auth values.
        def redact(text):
            return re.sub(r"sk-[A-Za-z0-9_-]+", "[REDACTED]", text)

        (run / "stderr.log").write_text(redact(stderr))
        messages = []
        final = None
        tool_read = False
        with (run / "transcript.jsonl").open("x") as transcript:
            for line in stdout.splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    record({"type": "non_json_output", "text": redact(line)})
                    continue
                content = event.get("message", {}).get("content", [])
                if isinstance(event.get("message"), dict) and isinstance(content, list):
                    event["message"]["content"] = [b for b in content if b.get("type") != "thinking"]
                    for block in content:
                        if block.get("type") == "tool_use" and block.get("name") == "Read":
                            tool_read = True
                transcript.write(redact(json.dumps(event, ensure_ascii=False)) + "\n")
                messages.append(event)
                if event.get("type") == "result":
                    final = event
        answer = final.get("result", "") if final else ""
        (run / "output.md").write_text(answer + "\n")
        try:
            parsed = json.loads(answer.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip())
        except ValueError:
            parsed = None
        expected = {"total": 17, "guarantee_pair": 4, "marker": "GPXPV_HANDOVER_20261028_K9"}
        read_succeeded, final = transcript_evidence(messages)
        config_ok = bool(requests) and all(
            r["model"] == "deepseek-flash" and
            (r.get("output_config") or {}).get("effort") == "max" for r in requests)
        passed = (proc.returncode == 0 and not timed_out and final and not final.get("is_error")
                  and final.get("subtype") == "success" and final.get("terminal_reason") == "completed"
                  and bool(http_statuses) and all(s == 200 for s in http_statuses)
                  and read_succeeded and config_ok and parsed == expected)
        result.update(status="passed" if passed else "failed", exit_code=proc.returncode,
                      timed_out=timed_out, read_tool_observed=tool_read,
                      read_tool_succeeded=read_succeeded, http_statuses=http_statuses,
                      subtype=final.get("subtype") if final else None,
                      terminal_reason=final.get("terminal_reason") if final else None,
                      session_id=final.get("session_id") if final else None,
                      request_configuration_verified=config_ok, api_requests=len(requests),
                      expected=expected, actual=parsed, usage=final.get("usage") if final else None,
                      cli_reported_cost_usd=final.get("total_cost_usd") if final else None,
                      cost_note="CLI price tables are not authoritative for DeepSeek; cost_usd unknown.")
    except Exception as exc:
        result.update(error_type=type(exc).__name__, error=str(exc))
    finally:
        if server:
            server.shutdown()
            server.server_close()
        result.update(finished_utc=now(), duration_s=round(time.monotonic() - start, 2))
        (run / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        record({"type": "completed", **result})
        events.close()
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
