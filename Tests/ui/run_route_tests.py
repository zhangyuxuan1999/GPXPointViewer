#!/usr/bin/env python3
"""路网草稿回归（联网；需先 run_fill_tests.py 或自行 open 文件并进入补点）"""
import ui, time, time, os, json, sys
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
def wait_route(limit=150):
    for i in range(limit):
        time.sleep(1); s = ui.state()
        if s.get('routeBusy') is None: return s
    return ui.state()
import os
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
ui.send(["place 0", "front", f"open {C}/Garmin_Roma_Da.gpx"])          # 自带文件，不依赖前一个脚本留下的是哪一份
for _ in range(120):
    s = ui.state()
    if s.get("points") and not s.get("loading"): break
    time.sleep(0.5)
ui.send(['exit', 'sleep 300'])
ui.send(['fill', 'select 0', 'sleep 1500']); s = ui.state(); b0 = s['anchorB']; n0 = s['vertexCount']   # 派生顶点数随候选而变（隧道群合并/乱跳候选会改变候选 0），撤销后应回到它
ui.send(['route car']); s = wait_route(60)
check(s.get('route') and s['route']['source'] == 'osrmCar' and s['history'] == 1, f"R1 公路草稿到达 {s.get('route')}")
n_route = s['vertexCount']
ui.send(['select 1', 'sleep 1200']); s = ui.state()
check(s.get('route') is None and s.get('routeBusy') is None, "R2 换候选后路网标签清空")
ui.send(['select 0', 'sleep 1200']); s = ui.state()
check(s.get('route') is None, "R3 再选回来也不带旧草稿")
ui.send(['route car']); s = wait_route(60)
ui.send(['anchor B 1']); s = ui.state()
check(s['anchorB'] == b0 + 1 and s['route'] and s['route']['edited'], "R4 挪锚点后标记已手动调整")
ui.send(['undo']); s = ui.state()
check(s['anchorB'] == b0 and s['route'] and not s['route']['edited'], "R5 撤销锚点移动后 edited 恢复")
ui.send(['undo']); s = ui.state()
check(s.get('route') is None and s['vertexCount'] == n0, f"R6 撤掉草稿 → 未使用路网、派生顶点恢复（{s['vertexCount']} vs 选中时 {n0}）")
ui.send(['route car']); s = wait_route(60)
ui.send(['route rail']); s = wait_route(150)
check(s.get('route') and s['route']['source'] == 'osrmCar', f"R7 公路断档上铁路请求失败不影响公路草稿（{(s.get('error') or '')[:40]}）")
ui.send(['dismiss', 'sleep 300'])   # R7 的铁路请求失败会弹「无法加载」提示；真实用户要先点「好」，弹框还开着时「应用」的确认框出不来
ui.send(['apply']); s = ui.state(); check(s['prompt'], "R8a 弹框打开")
ui.send(['route car']); s = wait_route(60)
check(s['prompt'] and s['vertexCount'] == n_route and s['route'] and not s['route']['edited'], "R8b 弹框期间到达的草稿挂起")
ui.send(['confirm replace', 'sleep 3000']); s = ui.state()
check(s['fills'] >= 1 and not s['fillActive'], f"R8c 确认落地（fills {s['fills']}）")
print("FAILS:", fails if fails else "none")
sys.exit(1 if fails else 0)
