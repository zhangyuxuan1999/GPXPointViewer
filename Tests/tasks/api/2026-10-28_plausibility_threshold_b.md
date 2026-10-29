# API 任务：落地前自检阈值方案 B（伪影信号 >20 m 扣 50）落地 + 用考卷与真实数据复核

记录日期 2026-10-28。模型：claude-fable-5-1（打分规则是设计决定，按用户分工归 fable）。权限：`--write`。预算 ≤ $15。**联网只允许最后一步的真实数据复核（≤ 100 次请求，串行、单客户端，见 §3）；其余全部离线；不安装到 /Applications；一次只跑一个 xcodebuild 和一个测试副本；不开子 agent。** 用中文写 output.md 与进度。

## 0. 背景
GPXPointViewer 的「落地前自检」（`GPXPointViewer/FillPlausibility.swift`，设计 `docs/fill-plausibility-design.md`）给每处补点打 0–100 风险分；high（>50）默认不勾选落地。考卷（`Tests/exam/`，`Tests/synth/runner/synthrunner --exam Tests/exam`，离线回放）里有 125 道题及两组扰动题：「伪影」（把正确几何人为推开，模拟上周 trimEnds/taper 那类错误）和「平行路」。现状：伪影 109/125 判 high，其余 16 题只到 medium（risk 40–50）；平行路 125/125；好结果误报 0。
上一任务（`Tools/agents/runs/20261028_120149_loose-ends/output.md` 第 7 项；设计文档 **§8**）分析了这 16 题：锚点本身离路 7–19 m 时端部允许量把 32 m 的人为推开吃掉大半、`devRoute` 只扣 10 分；另有 2 题补点太少采不到峰值。它模拟了三种改法，推荐**方案 B：伪影信号（补点离路网原始折线的超额偏移，扣除端部允许量后）超过 20 m 时扣 50**，模拟结果伪影 123/125 判 high、好结果误报 0。阈值当时没改。

## 1. 要做的
1. 读设计文档 §1–§2、§5、§8 和 `FillPlausibility.swift`，确认方案 B 的定义与 §8 一致；若你认为有更好的变体（例如按锚点离路距离分档），先在文档里写清理由，再实现，但**必须**满足 §2 的验收。
2. 实现方案 B（阈值常数集中、带注释与出处），`FillPlausibility` 的原因文案要让用户看懂（例如「补点被推离路网原始折线 24 m（已扣除端部允许的 6 m）」）。
3. 补 2 题「补点太少采不到峰值」的处理：补点少于 4 个时按折线顶点而不是补点采样伪影信号（或等价做法），写明。
4. 更新设计文档 §2 阈值表、§5 成绩、§8 结论；`Tests/exam/baseline.json` 按新成绩更新（只允许伪影/平行命中率上升、通过题数不变、误报仍 0；否则不更新并报告）。

## 2. 验收（离线）
- `Tests/synth/runner/run_all.sh`（命令以 `Tests/` 开头直接调用）114/114；考卷汇总：osrm/valhalla `pass 121/125` 不变、`perturb artefact ≥ 120/125`、`parallel 125/125`、`high∧pass 0`（好结果误报 0）。
- `synthrunner --portal-selftest`、`--crosscheck-selftest`、`--tunnel-selftest` 仍过。
- 钩子回归（新起副本、`fakeroute all ok`、`autotripmap 0`）：`Tests/ui/run_plausibility_tests.py`、`run_crosscheck_tests.py`、`run_batch_review_tests.py`、`run_tunnel_fix_tests.py` 末行 `FAILS: none`（`run_crosscheck_tests.py` 开头有 `riskthreshold 100`，保持）。
- Release 构建 `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` BUILD SUCCEEDED。

## 3. 真实数据复核（唯一联网步骤，最后做）
- 先 `Tools/agents/status.sh` 确认没有别的客户端在用公共路网；然后用刚构建的 Release 起测试副本（`Tests/README.md` §2.5；默认通信目录），钩子：`autotripmap 0`、`open <容器>/Muenchen_Roma_Garmin.gpx`（文件在 `~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/`，缺就从 `data/compare/` 拷）、`exit`、`fill`、`crosscheck 1`、`fakeroute all off`、`batchclose`、`batchplan`、`batchall road`、`batchrun`，等 `state.batch.phase == preview`（≤ 5 分钟；50 处 × 2 引擎 = 100 次请求，app 自带限速 1/s/主机）。
- 记录 `counts.high / medium`、每个 high/medium 项的 `risk` 与 `riskReasons`。**验收：high 仍为 0**（2026-10-27 23:35 同一数据的基线：high 0 / medium 4 / low 46；medium 的原因是锚点离路 11–17 m、保留点离路线 64 m、补点离折线 7 m）。若方案 B 让 high > 0，逐条分析是真问题还是误报：误报则回退或调整并重跑考卷，直到 high 0 且考卷验收仍满足；真问题则保留并在报告里说明。
- 结束：`python3 Tests/ui/ui.py "batchclose" "crosscheck 0" "fakeroute all off" "riskthreshold off"`，`pkill -f app.noindex`。

## 4. 产出与硬规则
- `output.md`（中文）：改了什么（常数前后值）、考卷汇总前后原文、真实数据复核结果表、测试末行原文、构建结果、没做到的及原因。
- 不安装；不动 /Applications；联网仅 §3 且 ≤ 100 次；UI 禁词（待审核/报警/冲突/已验证/失锁）；本地化新文案走 `Tests/README.md` 第 410 行附近流程（下一个未用 chunk 编号）；进度随时写 progress.md。
