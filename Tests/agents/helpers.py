"""Independent fixture and evidence helpers for runner regressions."""
import datetime
import hashlib
import json
import os
import subprocess
import shutil
import tempfile
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RECORD = REPO / "Tools/agents/records/2026-10-28-remediation/runner-tests"
MOCK = REPO / "Tests/agents/fixtures/mock_cli.py"
TEMP_ROOT = Path(tempfile.mkdtemp(prefix="gpxpv-runner-tests-", dir="/private/tmp"))


def fresh_evidence(name):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S_%f")
    root = TEMP_ROOT / (stamp + "_" + name + "_" + uuid.uuid4().hex[:8])
    root.mkdir(parents=True)
    return root


def archive_evidence(root):
    """Keep fake repositories outside the real project's index; archive evidence."""
    destination = RECORD / "evidence" / Path(root).name
    destination.parent.mkdir(parents=True, exist_ok=True)
    (destination.parent / ".offline-fixture").write_text(
        "Archived offline test records. Exclude from real project status scans.\n")
    shutil.copytree(root, destination, dirs_exist_ok=True, symlinks=True)
    return destination


def invoke(argv, *, cwd=None, env=None, timeout=30, evidence=None):
    """Capture full normal output and process status, never truncate evidence."""
    evidence = evidence or fresh_evidence("command")
    merged = os.environ.copy()
    if env:
        merged.update(env)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    proc = subprocess.run([str(a) for a in argv], cwd=cwd, env=merged,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, text=True)
    (evidence / "stdout.txt").write_text(proc.stdout)
    (evidence / "stderr.txt").write_text(proc.stderr)
    meta = {"argv": [str(a) for a in argv], "cwd": str(cwd or Path.cwd()),
            "environment_overrides": env or {}, "started_at": started,
            "ended_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "exit_code": proc.returncode, "stdout": str(evidence / "stdout.txt"),
            "stderr": str(evidence / "stderr.txt")}
    (evidence / "command.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    meta["archived_evidence"] = str(archive_evidence(evidence))
    with (RECORD / "journal.jsonl").open("a") as f:
        f.write(json.dumps(meta, ensure_ascii=False) + "\n")
    return proc


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def init_repo(root):
    root.mkdir(parents=True, exist_ok=True)
    def git(*args):
        return subprocess.run(["git", "-C", str(root), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout
    git("init", "-q")
    (root / "tracked.txt").write_text("original tracked\n")
    (root / "deleted.txt").write_text("will be removed\n")
    (root / "binary.dat").write_bytes(bytes(range(256)))
    git("add", ".")
    git("-c", "user.email=offline@example.invalid", "-c", "user.name=Offline",
        "commit", "-qm", "offline baseline")
    (root / "tracked.txt").write_text("already staged before invocation\n")
    git("add", "tracked.txt")
    (root / "untracked.txt").write_text("already untracked before invocation\n")
    return git
