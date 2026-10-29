#!/usr/bin/env python3
"""采样画像/点距自动跟随（离线，不发网络请求）
2026-10-28：载入后等重算完成，避免接在其它脚本后面跑时 P4/P5 误报"""
import ui, json, time, os
C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
fails = []
def check(cond, label):
    print(("    ok   " if cond else "    FAIL ") + label)
    if not cond: fails.append(label)
def settled(s):
    # 大文件（>30 万点）的候选/画像在后台重算：refreshing=true 时 state 里的 profile/candidates 还是上一份的，
    # 不能只看 profile 非空就取。老版本钩子没有 refreshing 字段时，退回「profile 非空」判据。
    return (not s['refreshing']) if 'refreshing' in s else bool(s.get('profile'))
def load(name, timeout=180):
    ui.send(['open %s/%s' % (C, name)])
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(1.0); s = ui.state()
        if not s.get('loading') and s.get('points') and 'candidates' in s and settled(s): return s
    return ui.state()
def fill(timeout=60):
    # fill 后重算候选/画像（171 MB CSV 实测约 11 s）；等 refreshing 结束且 profile 非空再取。
    ui.send(['fill'])
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(1.0); s = ui.state()
        if s.get('profile') and settled(s): return s
    return ui.state()
ui.send(['frame 1320 -740 1320 860', 'front', 'sleep 500'])
s = load('Garmin_Roma_Da.gpx'); s = fill(); p = s['profile']
print("   Garmin profile:", p)
check(p and p['kind'] == 'deviceLogger' and p['radius'] == 15 and 0.9 <= p['medianDt'] <= 1.1 and 20 <= p['medianStep'] <= 35, "P1 Garmin 画像 = 专用记录仪、1 s / 27 m、半径 15")
# 2026-10-26 起 100：staleClock 微型入口门槛 V1（短断档 dt<20 s、单步隐含速度 >350 km/h、d ≥ max(60, 3.5×局部步长)）多检出
# 14593→14599（9 s / 249 m）、29200→29206（10 s / 286 m）、29352→29358（10 s / 244 m）三处短隧道；原 97 处一处不少
check(s['candidates'] == 100, f"P2 Garmin 候选 100（隧道群合并后；实际 {s['candidates']}）")
ui.send(['select 0', 'sleep 1200']); s = ui.state()
print("   spacing", s['spacing'], "manual", s['spacingManual'], "localStep", s['localStep'])
check(s['localStep'] and 20 <= s['localStep'][0] <= 35 and not s['spacingManual'] and abs(s['spacing'] - round(s['localStep'][0])) <= 1, f"P3 选断档后点距自动跟随原始步长本身（实际 {s['spacing']}，原始 {s['localStep']}）")
s = load('stepLife.csv', 180); s = fill(); p = s['profile']
print("   StepLife profile:", p, "candidates", s['candidates'])
check(p and p['kind'] == 'phone' and p['accuracy'] is not None and 20 <= p['radius'] <= 50, "P4 一生足迹 CSV 画像 = 手机、有精度、半径 20–50")
check(s['candidates'] > 0, "P5 一生足迹有候选（staleClock 已按画像关闭）")
ui.send(['select 0', 'sleep 1200']); s = ui.state()
print("   spacing", s['spacing'], "manual", s['spacingManual'], "localStep", s['localStep'])
expect6 = min(100, max(5, round(s['localStep'][0] if s['localStep'] else p['medianStep'])))
check(not s['spacingManual'] and abs(s['spacing'] - expect6) <= 1, f"P6 手机数据点距按原始步长（局部步长，没有就按画像中位 {p['medianStep']}；实际 {s['spacing']}，期望 {expect6}，原始 {s['localStep']}）")
print("FAILS:", fails or "none")
