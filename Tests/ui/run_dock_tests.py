#!/usr/bin/env python3
"""紧凑卡片停靠 + 飞到断档避开卡片/面板（主窗口放屏幕内）"""
import ui, json, time, os
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
ui.send(['open %s/Garmin_Roma_Da.gpx' % C])
for i in range(30):
    time.sleep(1); s = ui.state()
    if not s.get('loading') and s.get('points'): break
# 主窗口必须完整在屏幕内（1440×932），否则 AppKit 会把卡片的 x 钳住；测试框架别处会把窗口挪到屏幕外，这里反复设到位为止
for _ in range(5):
    ui.send(['frame 60 40 1320 860', 'front', 'sleep 600']); time.sleep(0.3)
    if 'GPX 点位查看器: x=60 y=40' in str(ui.send(['windows'])): break
check('GPX 点位查看器: x=60 y=40' in str(ui.send(['windows'])), "主窗口在屏幕内")
ui.send(['fill', 'sleep 800'])
opened = False
for _ in range(3):
    ui.send(['openbatch', 'sleep 1500']); time.sleep(0.5)
    if '批量补点' in str(ui.send(['windows'])): opened = True; break
check(opened, "批量窗口已打开")
if ui.state()['batch'] is None: ui.send(['batchplan', 'sleep 600'])
# SwiftUI 在场景内容变化（批量状态出现）后会把钩子程序设的主窗口框恢复成它记住的位置（用户拖动不受影响）：再设一次
for _ in range(5):
    ui.send(['frame 60 40 1320 860', 'sleep 600']); time.sleep(0.3)
    if 'GPX 点位查看器: x=60 y=40' in str(ui.send(['windows'])): break
print("   windows:", ui.send(['windows']))
def visible_ok(s, label):
    a, b = s['overlay']['a'], s['overlay']['b']; W, H = s['content']
    # 卡片在内容坐标里占 x 410–910、y 0–242（顶部居中 500×240 + 标题栏）；两端都要在地图里且不在卡片下
    inside = all(0 <= p[0] <= W and 0 <= p[1] <= H for p in (a, b))
    under_card = any(410 <= p[0] <= 910 and p[1] <= 250 for p in (a, b))
    check(inside and not under_card, f"{label} A={a} B={b} 都可见且不在卡片下")
for idx in (1, 2, 5):
    ui.send([f'batchselect {idx}', 'sleep 2500']); s = ui.state(); w = ui.send(['windows'])
    check('批量补点: x=470 y=61' in str(w), f"卡片停靠（第 {idx} 处）" + ("" if '批量补点: x=470 y=61' in str(w) else f" windows={w}"))
    visible_ok(s, f"D{idx}")
ui.send(['batchnext 1', 'sleep 2000']); s = ui.state(); visible_ok(s, "D-next")
ui.send(['batchclose', 'frame 1320 -740 1320 860'])
print("FAILS:", fails or "none")
