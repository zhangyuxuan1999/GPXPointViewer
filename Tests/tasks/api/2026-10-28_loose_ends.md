# API 任务：收尾——把设计文档里「延后」的小项和最后一条界面待办全部做完

记录日期 2026-10-28。模型：claude-opus-5-5。权限：`--write`。预算 ≤ $14。**不联网（测试用假引擎 / 假瓦片 / 考卷回放）、不安装到 /Applications、一次只跑一个 xcodebuild 和一个测试副本、不开子 agent。** 用中文写 output.md 与进度。

## 0. 项目与现状
GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX 轨迹查看器（仓库根目录就是当前目录；四语本地化 zh-Hans 源 + en/de/zh-Hant，新文案走 `Tests/README.md` 第 410 行附近流程，下一个未用编号 `ls Tests/l10n/translations | sort | tail -1`）。自测钩子与脚本：`Tests/README.md` §2–§3（必读）、`GPXPointViewer/UITestHook.swift`。
设计文档：`docs/cross-check-design.md`（末尾有「延后」清单）、`docs/batch-review-design.md`、`docs/fill-plausibility-design.md`（§6 局限、以及 fable 任务 `Tools/agents/runs/20261027_215456_fill-plausibility-exam/output.md` §8「未做/存疑」）、`docs/map-sources.md`。待办清单：`Tests/tasks/api/_backlog.md`。
先 `git status --short | head`，不要回退工作区任何改动。

## 1. 要做的（全部）
1. **补点模式下底部操作条盖住左侧控制面板最底一行**（窗口高 800 pt；`Tests/tasks/api/_backlog.md` 最新一条；`GPXPointViewer/ContentView.swift` 左侧面板 + 补点操作条 `fillBar`）。改法：补点模式下给左侧面板加底部内边距等于操作条高度（用 `safeAreaInset(edge: .bottom)` 或测量操作条高度后 `padding(.bottom)`），或者让左侧面板在高度不够时可滚动。要求：960×800 下 zh-Hans / de / en 三语面板最底一行「导出 / 图片 / 删除点 / 补点」「修改记录」完整可见、不被盖住。
2. **分歧线上标引擎名**（`docs/cross-check-design.md` 延后项）：精确模式两路不一致时主地图上的两条蓝线（OSRM 实线、Valhalla 虚线）在线中点各加一个小标签「OSRM」「Valhalla」（MKAnnotation 或在 PointMapView 的 Metal/MapKit 叠层上画文字，按现有画法选最省的），缩小到看不清时隐藏。钩子：`state.batch.lines` 现有计数之外加 `lineLabels` 计数。
3. **单处模式两路进度合并成一行**（延后项）：单处「沿公路取路径并交叉验证」时操作条上的两条进度文字合成一行「OSRM ✓ · Valhalla 取路中…」这种形式。
4. **「只有一路结果」的一键重新比对**（延后项）：批量第 3 步对 `unverified` 项提供「重新比对这一处（两路重取）」行内菜单项，和汇总行旁的「全部重新比对 N 处」按钮；实现复用 route-cache 任务加的 `refetchBatchItem` / `refetchBatchAll` 的 ignoreCache 路径，只针对 unverified 项。钩子 `batchrecross all|<i>`。
5. **tunnelShare 从 OSRM 取**（fable 任务 §8：现在恒为未知）：OSRM 请求加 `annotations=true` 或用 `steps=true` 的 `intersections[].classes`（含 `"tunnel"`），把隧道段长度占比算进 `RouteDraft`（新字段 `tunnelShare: Double?`），`FillPlausibility` 用它（有值时：隧道占比高且 `devRoute` 小的，不因「看着在路外」扣分；没值时保持现状）。Valhalla 没有就留 nil。缓存值随之多存一个字段。**不要改其它阈值**。考卷回放的录音是旧请求的 JSON，`steps`/`annotations` 字段可能没有——回放时缺字段必须按 nil 处理，考卷成绩不能变（`Tests/synth/runner/run_all.sh` 末尾汇总与 `Tests/exam/baseline.json` 一致）。
6. **`replay` 钩子加测试**：`Tests/ui/run_plausibility_tests.py` 加一条：`replay Tests/exam/recordings` 后对一处真实题（锚点见 `Tests/exam/questions/real_*.json`）`route car` → 不出网（`requestsByHost` 不变）且取到草稿。
7. **扰动题 16/125 只到 medium 的原因分析**（fable 任务 §8）：跑 `Tests/synth/runner/synthrunner --exam Tests/exam` 看哪 16 题、各自的指标值，写进 output.md 并给出阈值建议；**不改阈值**（那是另一个任务的决定）。
8. `Tests/ui/run_suite.sh` 的列表补齐：`run_batch_card_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`、`run_map_sources_tests.py`、`run_batch_review_tests.py`、`run_crosscheck_tests.py` 凡是没排进去的都排进去（会重启副本的放后面）；README §3.6 表同步。

## 2. 测试
- 1：三语截图主窗口补点模式 960×800（`frame 240 60 960 800`，`shotwin <本地化标题> <png>` → jpg 后 Read；**不要 Read 原始 png**），存 `Tests/reports/loose_ends_shots/`。
- 2–4：加到 `Tests/ui/run_crosscheck_tests.py` 或 `run_batch_review_tests.py` 末尾（假引擎 `fakeroute valhalla offset 30` 造出不一致 → `lineLabels ≥ 2`；`fakeroute valhalla fail` 造出 unverified → `batchrecross <i>` 后请求计数 +2、状态变化；单处合并进度行用 `state.route`/操作条文字字段断言）。
- 5：`run_all.sh` 末尾考卷汇总与 baseline 一致；新加一条 runner 自测或 python 检查：对一份含 `intersections.classes` 的 OSRM 回复样例（自己构造）解析出 `tunnelShare`。
- 回归：`run_plausibility_tests / run_batch_card_tests / run_batch_review_tests / run_route_cache_tests / run_tunnel_fix_tests / run_crosscheck_tests / run_map_sources_tests`（各自新起副本；map_sources 的 M1c 在锁屏时会假失败——先 `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`，锁着就注明不判）末行 `FAILS: none`；`Tests/synth/runner/run_all.sh` 114/114 + 考卷。
- 本地化：新文案 → 导出 → 下一个 chunk → assemble（missing 0）→ 重建；导出产物放 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api7/`。
- 收尾：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "set mapStyle 标准" "riskthreshold off" "batchcompact 0"`，`pkill -f app.noindex`。

## 3. 文档
`docs/cross-check-design.md` 延后清单标「已做」并写做法；`docs/fill-plausibility-design.md` 补 tunnelShare 与第 7 项分析；`Tests/tasks/api/_backlog.md` 把做完的标「已做」；`Tests/README.md` 补钩子。

## 4. 产出与硬规则
- `output.md`（中文）：每项做了什么、测试末行原文、截图结论、第 7 项分析表、构建结果、没做到的及原因。
- 构建 `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` BUILD SUCCEEDED；不安装；不动 /Applications；不联网；UI 禁词（待审核/报警/冲突/已验证/失锁）；不改 FillPlausibility 阈值。进度随时写 progress.md。
