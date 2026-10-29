#!/usr/bin/env python3
"""补点模式交互回归（需先用 GPXPV_UITEST_DIR 启动测试副本并把 Garmin_Roma_Da.gpx 拷进容器 tmp/uitest）"""
import ui, json, time, os, sys
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
ui.send(['frame 1320 -740 1320 860', 'front', 'sleep 500'])
ui.send(['open %s/Garmin_Roma_Da.gpx' % C])
for i in range(20):
    time.sleep(1.5); s = ui.state()
    if not s.get('loading') and s.get('points'): break
ui.send(['fill', 'select 0', 'sleep 1500'])
c0 = ui.state()['candidates']
def st():
    s = ui.state(); return s, s['overlay']
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
s, o = st(); m0 = o['midpoints'][0]
ui.send([f"click {m0[0]} {m0[1]}"]); s, o = st()
check(s['vertexCount'] == 5 and s['history'] == 0 and not s['dragging'], "T0 单击段中点不加点")
ui.send([f"dbl {m0[0]} {m0[1]}"]); s, o = st()
check(s['vertexCount'] == 5 and s['history'] == 0 and not s['dragging'], "T0b 双击段中点不加点")
ui.send([f"drag {m0[0]} {m0[1]} 760 420 10"]); s, o = st()
check(s['vertexCount'] == 6 and s['sources'][0] is None and s['history'] == 1 and abs(o['vertices'][0][0]-760) < 3, "T1 拖线段中点 → 新顶点（下标 0，来源 nil，历史 1）")
ui.send(["drag 760 420 740 400 8"]); s, o = st()
check(s['vertexCount'] == 6 and s['history'] == 2 and abs(o['vertices'][0][0]-740) < 3, "T2 拖顶点移动（历史 2）")
ui.send(["dbl 740 400"]); s, o = st()
check(s['vertexCount'] == 5 and s['history'] == 3, "T3 双击顶点删除")
ui.send(["undo"]); s, o = st()
check(s['vertexCount'] == 6 and s['history'] == 2, "T4 撤销恢复顶点")
v0 = o['vertices'][0]; ui.send([f"rclick {v0[0]} {v0[1]}"]); s, o = st()
check(s['vertexCount'] == 5 and s['history'] == 3, "T5 右键顶点删除")
ui.send(["click 300 600"]); s, o = st()
check(s['vertexCount'] == 5 and s['history'] == 3 and not s['dragging'], "T6 单击空白地图不加点")
v0 = o['vertices'][0]; ui.send([f"click {v0[0]} {v0[1]}"]); s, o = st()
check(s['vertexCount'] == 5 and s['history'] == 3 and not s['dragging'], "T6b 只按不拖顶点不记历史")
b = o['b']; a = o['a']; dx, dy = b[0]-a[0], b[1]-a[1]; n = (dx*dx+dy*dy)**0.5
# 拖到 B 之后第一个真实点的位置（去向线 departure[1]；departure[0] 是 B 本身），期望吸附到下一点
dep = o['departure']; tgt = dep[1] if len(dep) > 1 else [b[0]+dx/n*30, b[1]+dy/n*30]
ui.send([f"drag {b[0]} {b[1]} {tgt[0]:.1f} {tgt[1]:.1f} 12"]); s, o = st()
check(s['anchorB'] == 1681 and s['history'] == 4, f"T7 拖锚点 B 沿轨迹吸附到下一点（历史 4，实际 B={s['anchorB']}）")
ui.send(["undo"]); s, o = st()
check(s['anchorB'] == 1680 and s['history'] == 3, "T8 撤销锚点移动")
v = o['vertices'][-1]; ui.send([f"drag {o['b'][0]} {o['b'][1]} {v[0]} {v[1]} 8"]); s, o = st()
check(s['anchorB'] == 1680, "T9 拒绝把 B 拖到过时点上")
ui.send(["apply"]); s, o = st()
check(s['prompt'] and s['removeCount'] == 5, "T10 应用 → 弹确认框（区间内 5）")
p0 = s['points']; ui.send(["confirm replace", "sleep 3000"]); s, o = st()
check(s['fills'] == 1 and s['points'] > p0 - 5 and s['candidates'] == c0 - 1 and not s['fillActive'], f"T10b 确认替换落地（{p0}→{s['points']} 点，候选 {s['candidates']}）")
print("FAILS:", fails if fails else "none")
sys.exit(1 if fails else 0)
