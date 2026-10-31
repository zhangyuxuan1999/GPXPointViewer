# R4 复测进度

## 已完成
- 准备：app=/Applications/GPXPointViewer.app，exe mtime 2026-10-28 14:12:04，CFBundle 1.0/1，源码 HEAD b8927ed1（工作区 dirty）；5 字符串 UTF-8 grep 3/5，diag 证实「取路中…」「主地图跟随」在 de/en/zh-Hant Localizable.strings（UTF-16LE）→ 任务书 grep 方法问题，非旧版。
- 测前无 /Applications 实例；prefs_before 已存；容器数据 4 文件齐全。
- 第 1 节 1–11：11 个回归脚本全部 exit=0、末行 `FAILS: none`（P2a counts.high=49；R1a netRequests 100→100；R1b replayHits 0→1；B15/B16/R1/R2/R3/E5/E6 全对）。
- 第 1 节 12：synth exit=0，build ok，114/114，exam summary 逐字匹配（requests sent 0 replayed 255 missing 0，95 s）。
- 第 1 节 13：4 selftest 8/31/5/7 全 ok，exit=0；阶梯 0/30/30/50/50；archetype risk=70。
- 第 2 节 13/13：disagree 100/100，lines 200，选中后 lineLabels 2，缩视野后 lineLabels 0、lines 200；截图 r4_line_labels.png 2864×1944（视觉交主代理）。
- 第 3 节 18/18：unverified 100，engineDisabled 含 Valhalla；R0=104→R1=106（+2）→304（+198，U1=99）；最终 agree 100、unverified 0、请求 304、status done 100。
- 第 4 节 5/5：`OSRM ✓ · Valhalla 取路中…` crossLegs=[1,0]；完成 None、agree true（otherMeters 362）。
- 第 5 节 3×6/6：zh-Hans/en/de 主窗口均 960×800；info front=GPX 点位查看器 / GPX Point Viewer / GPX-Punktbetrachter；三张 PNG 已生成（2144×1824），视觉判据未验收，交主代理。
- 第 6 节 9/10：valhalla 50、vHighExcl 49、oHigh 0、counts.high=49=nHigh；严格判据 vMinRisk>50 实得 0（1 个 stale 项 risk=0），剔除 stale 后 min=55（落在任务书 51–59「偏差」带）→ 判任务书判据与已知 stale 项冲突，非产品缺陷；vRisk 分布 {"0":1,"55":4,"85":25,"95":10,"100":10}。
- 第 7 节 12/12：README 38 文件全在、app 34 个全列；Regions.bin 29411770/头 827213650 1 5319 14275 3496861 64800；31 个 run_*.py，run_suite 25，Tests/README 三处均 25。
- 第 8 节：复位回显完整，测试副本已关闭，prefs 前后 sha256 相同、文本 diff 0；测前/测后均无 /Applications 实例（环境项，非本轮关闭）。
- 网络：synth 0 sent/255 replayed；R1a 100→100；UI 假引擎计数 netRequests sec2 200、sec3 304、sec4 306、sec5 各 1、sec6 100，均为假请求计数（UITestHook.swift 第 49 行按设计计数），真实公共网络请求 0。

## 正在做
- 无（测试阶段全部结束）。

## 下一步
- 主代理读取 3 张主窗口截图与 1 张分歧线截图完成视觉验收，再定最终发布结论。

## 备注
- 任务书问题：5 字符串 UTF-8 grep 期望；第 6 节 vMinRisk 取全量 min 与已知 stale 项冲突；截图尺寸示例 2056×1736 与实测 2144×1824 不符（仅记录项）。
- 不联网；未跑 run_suite.sh / record；未改产品源码、测试脚本、期望值、baseline.json。
