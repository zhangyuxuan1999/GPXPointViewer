# API 任务：写 DeepSeek 第 3 轮测试任务书（落地前自检 / 考卷 / 单处卡片 / 在主地图上看 / 翻页跟随 / 界面待办四项）

记录日期 2026-10-27。模型：claude-opus-5-5。权限：**只读**（不改仓库文件、不构建、不跑 app、不联网）。产出写进运行器给你的进度目录（`Tools/agents/runs/<本次运行>/`）：`deepseek_task.md`（任务书正文）和 `output.md`（一句话说明 + 你发现的疑点）。用中文。

## 0. 背景
GPXPointViewer（macOS，当前目录是仓库根）。项目用 DeepSeek 做机械化测试：主会话把一份**自洽**的任务书放 `Tests/tasks/<日期>_<名>.md`，`Tests/run_deepseek.sh` 交给 DeepSeek（只读 + 可运行命令），报告落 `Tests/reports/`。
任务书写法与硬规则**照搬上一轮** `Tests/tasks/2026-10-26_route_cache_tunnel_r2.md`（读全文：背景 / 范围 / 已知数据事实 / 硬规则 / 准备（完整写法，含 `export GPXPV_APP=/Applications/GPXPointViewer.app`）/ 逐项步骤 / 报告格式）。禁止「同前」「见上一轮」；命令完整可复制；期望值具体，并标出处。

本轮要测的改动（都已在工作区并将装到 /Applications；DeepSeek 测 `/Applications/GPXPointViewer.app`）：
1. **落地前自检**：`docs/fill-plausibility-design.md`（§4「给 DeepSeek 的可测项清单」是现成规格；§3 已做的界面）；脚本 `Tests/ui/run_plausibility_tests.py`（含 U1–U4）；钩子 `riskthreshold`、`batchriskonly`、`replay`；state 字段 `risk/riskLevel/riskReasons`、`counts.high/medium`、`visibleCount`。
2. **考卷**：`Tests/exam/`（`run_exam.sh`、`questions/`、`recordings/`、`baseline.json`），离线；`Tests/synth/runner/run_all.sh` 末尾有考卷汇总行；期望值看 `baseline.json` 与设计文档 §5。
3. **单处卡片**与**在主地图上看**：`docs/batch-review-design.md` 末尾几节；脚本 `Tests/ui/run_batch_card_tests.py`；钩子 `batchcompact`、`reviewgoto`、`closebatchwin`、`resizewin`；state `batch.windowSize`、`reviewstate.mainMapCenter/mainMapSpanKm`。
4. **翻页跟随**：钩子 `reviewfollow`，`reviewstate.followMap`；偏好 `reviewFollowMap`。
5. **界面待办四项**（卡片高度按内容、底行按钮三档无省略号、补点模式性能面板收成一行不重叠、翻页跟随）：改动说明在 `Tools/agents/runs/20261027_224806_plausibility-ui-backlog/output.md`；截图样例 `Tests/reports/plausibility_ui_shots/`（DeepSeek 用 `shotwin` 自己截，锁屏时截图全白要注明）。
6. 回归脚本总表：`Tests/ui/run_suite.sh` 的列表（新加了 `run_plausibility_tests.py`）；本轮至少跑 `run_plausibility_tests / run_batch_card_tests / run_batch_review_tests / run_route_cache_tests / run_tunnel_fix_tests / run_map_sources_tests / run_fill_tests / run_profile_tests`（各自新起副本的要分别起）+ `Tests/synth/runner/run_all.sh`。

钩子总说明：`Tests/README.md`（§2–§3）与 `GPXPointViewer/UITestHook.swift`（`case "…"`，以源码为准）。数据：容器里 `Garmin_Roma_Da_copy.gpx`、`Muenchen_Roma_Garmin.gpx`（缺就从 `data/` 拷）。

## 1. 任务书要包含
- 背景、范围（要测 / 不用测：联网、nanoGPT 无关、本地化文字）、已知数据事实（Garmin_Roma_Da 候选 100、Muenchen 候选 50；假引擎 `offset 30` 下会把 Valhalla 做的项判为「要看一眼」是**预期**，不是缺陷；考卷 121/125 × 两引擎、4 道未通过是数据偏差——都标出处）、硬规则（离线、`autotripmap 0`、`fakeroute`、一次一个副本、不 kill /Applications 实例、结束复位：`batchriskonly 0` `batchcompact 0` `reviewfollow 0` `riskthreshold off` `crosscheck 0` `fakeroute all off` `reviewmap standard light 1` `set mapStyle 标准`）。
- 准备（完整写法）。
- 逐项步骤（命令 → 期望 → 判据），至少：① 8 个脚本 + run_all（末行原文）；② 自检 7 项（设计文档 §4 逐条）；③ 筛选 `batchriskonly` 与 `visibleCount`；④ 卡片：`batchcompact 1` 后 `windowSize` 宽 560、高 < 300，`batchcompact 0` 恢复；关窗重开不再是卡片（`closebatchwin` 后 `batchopen`/重开的钩子名以源码为准）；⑤ `reviewgoto` 与 `reviewfollow 1` 翻页跟随；⑥ 考卷：`Tests/exam/run_exam.sh` 退出码 0、汇总行与 `baseline.json` 一致；⑦ 三语截图各一张主窗口补点模式（960×800）看底行无省略号、性能面板不盖候选面板（锁屏则注明不判）。
- 报告格式（每项 ok/FAIL + 原文；结论「可以发布 / 不可以」+ 缺陷数；任务书本身的问题另列）。

## 2. 硬规则（给你）
- 只读；不要运行任何脚本或 app；期望值从脚本源码、docs、baseline.json、报告里取并标出处；不联网。
- 所有路径/命令/钩子名用 Glob/Grep 在仓库里核实存在，不凭记忆写。
- 写完自查：无「同前」类引用、每步有期望值。
