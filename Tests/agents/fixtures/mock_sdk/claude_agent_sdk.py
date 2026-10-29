"""Offline SDK fixture: no transport, no authentication, no subprocesses."""
import asyncio
from dataclasses import dataclass, field
import os
from pathlib import Path
import subprocess
import sys


class ClaudeAgentOptions:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


@dataclass
class AssistantMessage:
    content: list
    model: str = "offline-sdk"
    session_id: str = "offline-sdk-session"


@dataclass
class UserMessage:
    content: list
    session_id: str = "offline-sdk-session"


@dataclass
class ResultMessage:
    subtype: str = "success"
    is_error: bool = False
    terminal_reason: str = "completed"
    result: str = "OFFLINE_SDK_EXPECTED_OUTPUT"
    total_cost_usd: float | None = 0.25
    num_turns: int = 2
    session_id: str = "offline-sdk-session"
    usage: dict = field(default_factory=lambda: {"input_tokens": 51, "output_tokens": 13})


async def query(*, prompt, options):
    scenario = os.environ.get("SDK_SCENARIO", "success")
    if scenario == "stderr":
        options.stderr("api_key=synthetic-sdk-stderr-credential\nordinary SDK stderr KEEP_DIAGNOSTIC")
    yield AssistantMessage(content=[{"type": "tool_use", "id": "sdk-call-1", "name": "Read",
                                      "input": {"file_path": "fixture.txt"}},
                                     {"type": "thinking", "thinking": "synthetic-private-reasoning-canary"}])
    normal = "SDK_NORMAL_BEGIN_" + "0123456789abcdef" * 12000 + "_SDK_NORMAL_END"
    yield UserMessage(content=[{"type": "tool_result", "tool_use_id": "sdk-call-1", "content": normal}])
    if scenario == "exception":
        raise RuntimeError("synthetic SDK failure api_key=synthetic-sdk-secret")
    if scenario == "timeout-spawn":
        descendant = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        Path(os.environ["SDK_DESCENDANT_PID_FILE"]).write_text(str(descendant.pid))
        await asyncio.sleep(60)
    if scenario == "timeout":
        await asyncio.sleep(60)
    if scenario == "no-final":
        return
    result = ResultMessage()
    if scenario in {"provider", "turns", "budget"}:
        result.is_error = True
        result.subtype = {"provider": "error_during_execution", "turns": "error_max_turns",
                          "budget": "error_max_budget_usd"}[scenario]
        result.terminal_reason = scenario
    if scenario == "blank-output":
        result.result = ""
    if scenario == "unknown-cost":
        result.total_cost_usd = None
    yield result
