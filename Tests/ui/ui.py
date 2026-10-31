#!/usr/bin/env python3
"""把命令写进 io/cmd，等 io/out.txt，打印结果。用法：ui.py "cmd1" "cmd2" ...（每个参数一行命令）"""
import sys, os, time, json, importlib.util
from pathlib import Path
# 钩子通信目录：默认容器 tmp/uitest；GPXPV_UITEST_IO 可指定另一个（同时跑第二个测试副本做诊断时用，副本启动的 GPXPV_UITEST_DIR 要给同一目录）
IO = os.environ.get("GPXPV_UITEST_IO") or os.path.expanduser("~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest")
PROJ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # Tests/ui → 项目根
_archive_spec = importlib.util.spec_from_file_location("gpxpv_archive_build", Path(PROJ) / "Tools/archive_build.py")
_archive = importlib.util.module_from_spec(_archive_spec)
_archive_spec.loader.exec_module(_archive)


def build_provenance(app):
    """Check content hashes, not filesystem dates, before touching a test copy."""
    app = Path(app).expanduser().resolve()
    executable = app / "Contents/MacOS/GPXPointViewer"
    if not executable.is_file():
        raise ValueError("GPXPV_APP 不是可用的 GPXPointViewer.app：" + str(app))
    try:
        return _archive.validate_bundle(app, os.environ.get("GPXPV_BUILD_MANIFEST"))
    except (OSError, ValueError, KeyError, TypeError) as error:
        if os.environ.get("GPXPV_ALLOW_UNVERIFIED_BUILD") != "1":
            raise ValueError(str(error) + "；先运行 Tools/build_release.py。历史对照可显式设 GPXPV_ALLOW_UNVERIFIED_BUILD=1，结果不得归属当前源码。") from error
        return {"app": str(app), "executable_sha256": _archive.sha256(executable),
                "source_association": "UNVERIFIED_EXPLICIT_OVERRIDE", "reason": str(error)}


def app_source():
    """Explicit target only; a verified build manifest binds it to current inputs."""
    env = os.environ.get("GPXPV_APP")
    if not env:
        raise SystemExit("必须显式设置 GPXPV_APP；用 Tools/build_release.py 生成带源码/构建归属的稳定归档。")
    try:
        provenance = build_provenance(env)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print("BUILD_PROVENANCE " + json.dumps(provenance, ensure_ascii=False), file=sys.stderr, flush=True)
    return provenance["app"]
def send(lines, timeout=20):
    out = os.path.join(IO, "out.txt"); cmd = os.path.join(IO, "cmd")
    if os.path.exists(out): os.remove(out)
    tmp = cmd + ".tmp"
    with open(tmp, "w") as f: f.write("\n".join(lines) + "\n")
    os.rename(tmp, cmd)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(out):
            time.sleep(0.05)
            with open(out) as f: return f.read()
        time.sleep(0.05)
    return "TIMEOUT"
def state():
    r = send(["state"])
    try: return json.loads(r.strip().splitlines()[-1])
    except Exception: return {"raw": r}
if __name__ == "__main__":
    print(send(sys.argv[1:]))
