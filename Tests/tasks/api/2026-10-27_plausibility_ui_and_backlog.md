# API 任务：落地前自检的界面接线 + 界面待办四项（卡片高度 / 翻页跟随 / 底行按钮截断 / 性能面板重叠）

记录日期 2026-10-27。模型：claude-opus-5-5。权限：`--write`。预算 ≤ $12。**不联网（测试用假引擎、副本默认假瓦片）、不安装到 /Applications、一次只跑一个 xcodebuild 和一个测试副本、不开子 agent。** 用中文写 output.md 与进度。

## 0. 项目与现状
GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX 轨迹查看器（仓库根目录就是当前目录；四语本地化 zh-Hans 源 + en/de/zh-Hant）。自测钩子与脚本说明 `Tests/README.md` §2–§3（必读），钩子源码 `GPXPointViewer/UITestHook.swift`。
刚完成的 fable 任务做了「落地前自检」的数据层（`GPXPointViewer/FillPlausibility.swift`；`BatchItem.plausibility`、`BatchState.highRiskCount/mediumRiskCount`、`store.fillRouteInfo?.plausibility`、`TrackChange.plausibility`；钩子 `riskthreshold`，state 字段 `risk/riskLevel/riskReasons`、`counts.high/medium`），批量窗口只加了最小的「风险」列和排序。**先读 `docs/fill-plausibility-design.md` 全文，§3「给 Opus 的界面接线清单」就是本任务第 1 部分的规格。**
先 `git status --short | head` 看工作区现状，**不要回退任何已有改动**；本地化块用下一个未用编号（`ls Tests/l10n/translations | sort | tail -1`，上一个是 chunk_25）。

## 1. 自检的界面（按设计文档 §3 做，全部要做）
1. 批量窗口（`GPXPointViewer/BatchFillWindow.swift`）：筛选开关「只看要看一眼的」（与现有 `warnedOnly` / `conflictOnly` 同一机制）；风险徽标可点 → popover 列 `reasons`，每条前加 ⚠︎，底部一行「风险 N / 100 · 等级」；第 3 步汇总行加「要看一眼 N · 留意 M」；紧凑卡片（单处卡片）上同样显示徽标与原因。
2. 单处补点操作条（`GPXPointViewer/ContentView.swift`）：状态行后加徽标 + 点开原因；`edited == true`（手改过顶点）时 plausibility 为 nil，不显示。
3. 修改记录详细页（`GPXPointViewer/ChangeReviewWindow.swift`）：依据行下面加「落地前自检：风险 N（等级）」+ 原因列表（预览模式与已落地模式都要）；原因多于 3 条折叠进「说明…」弹窗。
4. 颜色：high 红、medium 橙、low 不显示；与「疑点」列的橙色区分（例如 medium 用黄橙、疑点保持现有橙）。
5. 文案禁词：待审核 / 报警 / 冲突 / 已验证 / 失锁。徽标文字已定「要看一眼」「留意」。
6. 钩子：`batchriskonly 0|1`（筛选开关）；`reviewstate.changes[]` 已有 `risk/riskLevel`，补 `riskReasons`。

## 2. 界面待办四项（来源 `Tests/tasks/api/_backlog.md`「界面待办」与上一任务报告）
1. **单处卡片高度按内容算**：现在固定 300 pt，下方约 50 pt 空白（`TrackStore.swift` 的 `dockBatchWindow()` 与 `batchCompact` 相关逻辑，`grep -n "batchCompact\|dockBatchWindow\|batchCardTarget" GPXPointViewer/*.swift`）。用 SwiftUI 的尺寸读取（`GeometryReader` / `onGeometryChange` 或 `NSHostingView.fittingSize`）把窗口高度设为卡片内容高度 + 标题栏，内容变化（原因弹窗不算）时跟着调；仍以 560 宽为准。
2. **修改记录翻页时主地图跟随**：详细页顶部加开关「主地图跟随」（偏好 `reviewFollowMap`，默认关）；开着时 ‹ › / ← → 翻页后自动执行「在主地图上看」的飞行；关着时维持点一次飞一次。钩子 `reviewfollow 0|1`，`reviewstate.followMap`。
3. **控制面板底行按钮截断**：主窗口 290 pt 面板最底一行「导出 / 图片 / 删除点 / 补点」在德文下显示 `Exp… / Pun… / Lüc…`、简中 `删… / 补…`；补点底栏「退出」简中显示 `退…`。改法：这一行用 `ViewThatFits`——放得下时显示图标+文字，放不下时只显示图标并用 `help` 给全名（和刚改过的「打开 GPX」同一做法，`grep -n "ViewThatFits" GPXPointViewer/ContentView.swift`）；「退出」同理或给它足够宽度。三种语言都不得出现省略号。
4. **性能面板与候选面板重叠**：窗口高 800 pt、补点模式下，右下角性能面板盖住右侧候选面板底部的说明文字。改法任选：补点模式下性能面板自动收成一行（点开展开）；或把性能面板挪到左下、避开右侧面板；或让候选面板给性能面板让出高度。要求：800 pt 高、960 pt 宽的最小窗口下两者不重叠。

## 3. 其它
- 把 `Tests/ui/run_plausibility_tests.py` 排进 `Tests/ui/run_suite.sh` 的脚本列表（README 3.6 表已列但 run_suite.sh 没加）。
- `docs/fill-plausibility-design.md` §3 改成「已做」并记录控件位置；`docs/batch-review-design.md` 补「翻页跟随」「卡片高度」；`Tests/README.md` 补新钩子；`Tests/tasks/api/_backlog.md` 把做完的四项标为已做（保留原文）。

## 4. 测试
- 新用例（加到 `Tests/ui/run_plausibility_tests.py` 末尾或新脚本，写法照现有）：
  - U1 `fakeroute valhalla offset 30` 跑到 preview 后 `batchriskonly 1` → 列表只剩 risk ≥ 20 的项（用 state 的 items 与筛选后计数对照；若 state 不暴露筛选后计数，加 `state.batch.visibleCount`）；`batchriskonly 0` 恢复。
  - U2 `batchcompact 1` → `state.batch.windowSize` 高度在 [卡片内容高, 内容高+60] 内（不再固定 300）；`batchcompact 0` 恢复。
  - U3 `batchreview`、`reviewselect 2`、`reviewfollow 1`、`reviewnext` → `reviewstate.mainMapCenter` 到第 3 处的距离 < 2 km；`reviewfollow 0`、`reviewnext` → 中心不变。
  - U4 `reviewstate.changes[i].riskReasons` 是数组。
- 截图（屏幕已解锁；副本按语言启动 `--args -AppleLanguages '(de)'` 等）：zh-Hans / en / de 各截主窗口补点模式（`frame 240 60 960 800` 后 `shotwin <本地化主窗口标题> <png>`）确认底行无省略号、性能面板不盖候选面板；zh-Hans 截批量窗口（有「要看一眼」徽标与 popover 打开时）与修改记录详细页（自检一行）。转 jpg（`sips -s format jpeg -s formatOptions 80 -Z 1600`）后 Read，**不要 Read 原始 png**。截图存 `Tests/reports/plausibility_ui_shots/`。
- 回归：`run_plausibility_tests.py`、`run_batch_review_tests.py`、`run_batch_card_tests.py`、`run_map_sources_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`（各自新起副本、离线）末行 `FAILS: none`；`Tests/synth/runner/run_all.sh`（命令以 `Tests/` 开头直接调用）114/114 + 考卷末行。
- 本地化：新文案 → `xcodebuild -exportLocalizations …` → `python3 Tests/l10n/extract_keys.py <export dir> <out dir>` → `chunk_26.json` → `python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`（missing 0 / specifier problems 0）→ 重建；导出产物放 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api6/`。
- 收尾：`python3 Tests/ui/ui.py "batchriskonly 0" "batchcompact 0" "reviewfollow 0" "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "set mapStyle 标准" "riskthreshold off"`，`pkill -f app.noindex`。

## 5. 产出与硬规则
- `output.md`（中文）：每项做了什么、控件在哪、截图路径与结论、测试末行原文、构建结果、没做到的项目及原因。
- 构建 `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` BUILD SUCCEEDED；不安装；不动 /Applications；不联网；不改 FillPlausibility 的阈值与打分逻辑（那是上一任务的范围，发现问题写进报告）。
- 进度随时写 progress.md。
