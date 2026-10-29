# API 任务：批量窗口「小卡片」模式大片空白 + 修改记录窗口「在主地图上看这处」按钮

记录日期 2026-10-27。模型：claude-opus-5-5。权限：`--write`。**不联网（测试用假引擎）、不安装到 /Applications、一次只跑一个 xcodebuild 和一个测试副本、不开子 agent、预算 ≤ $8。** 用中文写 output.md 与进度。

## 0. 项目
GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX 轨迹查看器（仓库根目录就是当前目录；四语本地化 zh-Hans 源 + en/de/zh-Hant，新文案走 `Tests/README.md` 第 410 行附近的流程）。自测钩子与脚本说明 `Tests/README.md` §2–§3（必读）；钩子源码 `GPXPointViewer/UITestHook.swift`。
相关代码：批量补点窗口 `GPXPointViewer/BatchFillWindow.swift`；`TrackStore.swift` 里 `batchCompact`（约 :2935，didSet 调 `dockBatchWindow()`，约 :2949–2980）与 `:3784` 附近「点行就是要看地图：窗口折叠成小卡片」；主地图停靠/避让逻辑 `PointMapView.swift` 约 :1528（`batchCardTarget`）；修改记录窗口 `GPXPointViewer/ChangeReviewWindow.swift`（详细页顶部「回总览」「还原此处 / 落地这一处」在约 :370–:416）；窗口默认尺寸 `GPXPointViewerApp.swift`（批量 920×780，修改记录 1000×720）。

## 1. 问题一：批量窗口折叠成「小卡片」后大片空白，而且用户觉得它「莫名其妙冒出来」
用户截图：`/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/userfb/fb_53.jpg`（用 Read 看）。
现象：批量补点窗口处于 `batchCompact` 模式——内容只有一张卡片（‹ › 第 28/50 处、时间/直线/隐含速度、段落判定、OSRM 一行、「改用另一条」「↻」「落地」、「放弃」「落地 50 处」、「审阅…」「展开列表」），但窗口还是 1130×990 的大窗口，卡片在中间，上下大片空白。
已知线索：`dockBatchWindow()` 里有 `win.frame.width < 600` 的守卫（约 :2949 与 :2974），窗口比 600 宽时就不缩/不停靠；进入 compact 的入口在 `:3784`（点某一行）。请核实：用户是在**主窗口右侧候选列表**点了一行（截图里高亮的是 05:23 那行，卡片正是第 28 处），还是在批量窗口列表点的；哪条路径把 `batchCompact` 设成了 true。
要做：
1. 进入 compact 时**无论当前窗口多大**都把窗口缩成卡片大小（宽约 560、高按卡片内容），停靠到约定位置；离开 compact（「展开列表」、批次重跑、关窗）恢复进入前的尺寸与位置。卡片内容本身改成 `frame(maxHeight: .infinity, alignment: .top)`，万一没缩成也不会居中留白。
2. 让这个模式有名字、有来由：卡片顶部加一行标题「单处卡片 · 点列表某一行后窗口折叠，方便看主地图」（文案可改，意思要到），右侧就是现有的「展开列表」。进入 compact 的那次点击，如果来自主窗口候选列表，要先确认用户确实是在批量流程中（批次存在且处于预览阶段）才折叠，否则不碰批量窗口。
3. 钩子 `batchcompact 0|1` 已有；`state.batch.compact` 已有。加 `state.batch.windowSize`（宽×高，整数）便于测试。

## 2. 问题二：修改记录窗口加「在主地图上看这处」
用户截图：`/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/userfb/fb_54.jpg`。
要做：修改记录窗口详细页（预览模式和已落地模式都要）顶部「回总览」旁加按钮「在主地图上看」：点一下主窗口地图飞到当前这处修改的范围（`TrackChange.bbox` 外扩一点，最小跨度按 `spanMeters` 保证能看清，和批量小卡片「主地图已飞到这处」用同一套飞行/避让逻辑，`grep -n "主地图已飞到这处\|batchCardTarget" GPXPointViewer/*.swift` 找现成函数），并把主窗口置前但不抢修改记录窗口的焦点（或置前后再把修改记录窗口 `makeKeyAndOrderFront`，总之用户还能继续按 ‹ › 翻）。如果主地图正处于补点模式等不便飞行的状态，就只飞不改模式。
钩子：`reviewgoto`（等价于点这个按钮）；`reviewstate` 加 `mainMapCenter:[lat,lon]`、`mainMapSpanKm`（取主地图当前 region）。

## 3. 测试（离线）
- 新用例加到 `Tests/ui/run_batch_review_tests.py` 末尾（或新脚本 `run_batch_card_tests.py`，写法照现有）：
  - K1 精确模式假引擎跑到 preview 后 `batchcompact 1` → `state.batch.windowSize` 宽 ≤ 600、高 ≤ 420；`batchcompact 0` → 宽高恢复到之前记录的值。
  - K2 `batchreview` 进预览、`reviewselect 3`、`reviewgoto` → `reviewstate.mainMapCenter` 到该处 `lat/lon` 的距离 < 2 km，`mainMapSpanKm` < 10。
- 回归：`python3 Tests/ui/run_batch_review_tests.py`、`python3 Tests/ui/run_map_sources_tests.py`、`python3 Tests/ui/run_route_cache_tests.py` 末行 `FAILS: none`。
- 截图：起副本（zh-Hans），`batchcompact 1` 后 `shotwin 批量补点 <png>`，转 jpg 后 Read 确认卡片贴顶、窗口已缩小；修改记录窗口 `shotwin 修改记录 <png>` 确认按钮在。
- 收尾：`python3 Tests/ui/ui.py "batchcompact 0" "crosscheck 0" "fakeroute all off" "reviewmap standard light 1"`，`pkill -f app.noindex`。

## 4. 本地化与文档
新文案 → `xcodebuild -exportLocalizations …` → `python3 Tests/l10n/extract_keys.py <export dir> <out dir>` → 下一个未用编号的 `Tests/l10n/translations/chunk_NN.json`（照 chunk_23.json 格式）→ `python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`（missing 0 / specifier problems 0）→ 重建。导出产物放 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api5/`。`docs/batch-review-design.md` 加「单处卡片」「在主地图上看」两小节；Tests/README.md 补钩子。

## 5. 产出与硬规则
- `output.md`（中文）：根因（哪条路径进入 compact、为什么没缩窗）、改动、测试末行原文、截图路径与结论、构建结果。
- 构建 `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` 必须 BUILD SUCCEEDED；不安装；不动 /Applications；不联网（`autotripmap 0`、`fakeroute all ok`、副本默认 faketiles）；UI 禁词：待审核 / 报警 / 冲突 / 已验证 / 失锁。
- 进度随时写 progress.md。
