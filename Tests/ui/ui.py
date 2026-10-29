#!/usr/bin/env python3
"""把命令写进 io/cmd，等 io/out.txt，打印结果。用法：ui.py "cmd1" "cmd2" ...（每个参数一行命令）"""
import sys, os, time, json, glob
# 钩子通信目录：默认容器 tmp/uitest；GPXPV_UITEST_IO 可指定另一个（同时跑第二个测试副本做诊断时用，副本启动的 GPXPV_UITEST_DIR 要给同一目录）
IO = os.environ.get("GPXPV_UITEST_IO") or os.path.expanduser("~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest")
PROJ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # Tests/ui → 项目根
# Xcode 默认 DerivedData 目录名带一个随机器/项目路径变化的哈希，用通配符找；有多份时取可执行文件最新的那份
DERIVED_GLOB = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/GPXPointViewer-*/Build/Products/Release/GPXPointViewer.app")
def _derived_release():
    def mtime(app):
        exe = os.path.join(app, "Contents/MacOS/GPXPointViewer")
        return os.path.getmtime(exe if os.path.exists(exe) else app)
    apps = [p for p in glob.glob(DERIVED_GLOB) if os.path.isdir(p)]
    return max(apps, key=mtime) if apps else None
def app_source():
    """测试用哪份 app：环境变量 GPXPV_APP 指定的优先（例如 -derivedDataPath 构建到别处时）；
    其次刚构建的 Release（安装前测）；没有就测 /Applications 里已安装的那份"""
    env = os.environ.get("GPXPV_APP")
    if env:
        if os.path.isdir(env): return env
        raise SystemExit("GPXPV_APP 指向的 app 不存在：" + env)
    derived = _derived_release()
    if derived: return derived
    if os.path.isdir("/Applications/GPXPointViewer.app"): return "/Applications/GPXPointViewer.app"
    raise SystemExit("找不到可测的 app：先 xcodebuild Release 构建，或先安装到 /Applications")
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
