# API 任务：写 DeepSeek 第 4 轮测试任务书（收尾项 + 阈值方案 B + 文档刷新）

记录日期 2026-10-28。模型：claude-opus-5-5。权限：**只读**（不改仓库文件、不构建、不跑 app、不联网）。**运行目录的写入会被拒，所以把两份产出（`output.md` 一句话 + 疑点；`deepseek_task.md` 全文）直接放在最终回复里**，用 `## output.md` 和 `## deepseek_task.md` 两个标题分开，任务书正文从 `# 任务：` 开始。用中文。

## 0. 背景
GPXPointViewer（macOS，当前目录是仓库根）。项目用 DeepSeek 做机械化测试：任务书放 `Tests/tasks/<日期>_<名>.md`，`Tests/run_deepseek.sh` 交给 DeepSeek（只读 + 可运行命令），报告落 `Tests/reports/`。
写法与硬规则**照搬上一轮** `Tests/tasks/2026-10-27_plausibility_card_r3.md`（读全文，含文末「2026-10-28 修订记录」，那里记录了上一轮任务书的 7 处错误，别再犯）。禁止「同前」；命令完整可复制；期望值具体并标出处；`run_profile_tests.py` 已改为自己等待重算，可接在其它脚本后跑。

本轮要测的改动（都已在工作区，正在装到 /Applications；DeepSeek 测 `/Applications/GPXPointViewer.app`，`export GPXPV_APP=/Applications/GPXPointViewer.app`）：
1. **收尾八项**（`Tools/agents/runs/20261028_120149_loose-ends/output.md`；`docs/cross-check-design.md` 延后清单已标「已做」）：补点模式左面板不被操作条盖住（中段可滚动、底两行固定）；分歧线中点 OSRM/Valhalla 标签（钩子字段 `lineLabels`）；单处两路进度合一行；「只有一路结果」一键重比对（钩子 `batchrecross all|<i>`）；OSRM `intersections.classes` 解析隧道占比（`synthrunner --tunnel-selftest`）；`replay` 钩子测试 R1；`run_suite.sh` 25 个脚本。
2. **阈值方案 B**（`Tools/agents/runs/20261028_132305_plausibility-threshold-b/output.md`；`docs/fill-plausibility-design.md` §2/§5/§8）：考卷伪影 123/125、平行 125/125、误报 0、pass 121/125；`synthrunner --plausibility-selftest` 7 例；真实数据基线 high 0 / medium 4 / low 46（不要让 DeepSeek 联网复核，只写进「已知事实」）。
3. **文档刷新**（`Tests/reports/20261028_1257_2026-10-28_docs_refresh.md`）：README 文件结构、`docs/regions-design.md`——DeepSeek 只需抽查 3 处文档描述与源码/文件是否一致（例如 README 列的 Swift 文件都存在、`Regions.bin` 大小与文档一致）。
4. 回归脚本：`Tests/ui/run_suite.sh` 列表里的 25 个脚本——**不要全跑**（有联网的）：跑 `run_plausibility_tests / run_crosscheck_tests / run_batch_review_tests / run_batch_card_tests / run_route_cache_tests / run_tunnel_fix_tests / run_map_sources_tests / run_fill_tests / run_profile_tests / run_review_tests / run_network_tests`（联网的 run_batch_drift / run_crosscheck_online / run_route_tests / run_drift_tests 一律不跑）+ `Tests/synth/runner/run_all.sh` + 四个 selftest（`--portal-selftest --crosscheck-selftest --tunnel-selftest --plausibility-selftest`，每个单独一条命令，期望末行各自的「x/x ok」原文以源码为准）。

钩子说明：`Tests/README.md` §2–§3 与 `GPXPointViewer/UITestHook.swift`（`case "…"`，以源码为准）。数据：容器里 `Garmin_Roma_Da_copy.gpx`、`Muenchen_Roma_Garmin.gpx`。

## 1. 任务书要包含
- 背景、范围（要测/不用测）、已知数据事实（候选数 100/50；假引擎 `offset 30` 下 Valhalla 项判「要看一眼」是预期；考卷数字；锁屏时 `run_map_sources_tests` 的 M1c 假失败要注明不判）、硬规则（照搬 + 收尾复位：`batchriskonly 0` `batchcompact 0` `reviewfollow 0` `riskthreshold off` `crosscheck 0` `fakeroute all off` `reviewmap standard light 1` `set mapStyle 标准`）。
- 准备（完整写法，含 `export GPXPV_APP=…`、起副本、`info` 在起副本之后）。
- 逐项步骤：① 11 个脚本 + run_all + 4 个 selftest（末行原文）；② 分歧线标签：`fakeroute valhalla offset 30` 精确模式到 preview，`select`/`batchselect` 某一不一致项后 `state.batch.lineLabels == 2`，缩到大视野（`mapgoto … 3000`）后为 0；③ 一键重比对：`fakeroute valhalla fail` 跑出 unverified → `fakeroute valhalla ok` → `batchrecross <i>` 请求 +2、该项变一致；`batchrecross all`；④ 单处进度合一行：`select 0`、`crosscheck 1`、`routecross` 后 `state.route` 或操作条文字字段含「OSRM ✓ · Valhalla」样式（字段名以源码/脚本为准）；⑤ 左面板：三语主窗口补点模式 960×800 截图，`shotwin`，判据「导出/图片/删除点/补点」「修改记录」两行可见（锁屏不判）；⑥ 阈值 B：`riskthreshold` 默认（off）下 `fakeroute valhalla offset 30` 的项 `risk ≥ 60`（出处：设计文档 §2 新档位）；⑦ 文档抽查 3 处；⑧ 收尾。
- 报告格式（每项 ok/FAIL + 原文；结论「可以发布 / 不可以」+ 缺陷数；任务书问题另列）。

## 2. 硬规则（给你）
- 只读；不要运行任何脚本或 app；期望值从脚本源码、docs、报告里取并标出处；不联网。
- 所有路径/命令/钩子名/state 字段用 Glob/Grep 在仓库里核实存在，不凭记忆写。
- 写完自查：无「同前」类引用、每步有期望值、没有超出屏幕的窗口尺寸（本机 1440×932，窗口高 ≤ 880）。
