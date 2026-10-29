# API 任务：路网结果按文件缓存 + 重新获取按钮 + 修改记录窗口两路切换

记录日期 2026-10-26。模型：claude-fable-5-1。权限：`--write`（可改源码、可 xcodebuild、可跑离线测试脚本）。**不安装到 /Applications、不联网**（所有测试用假引擎）。用中文写 output.md 与进度。

## 0. 项目与背景

GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX/CSV 轨迹查看器（仓库根目录就是当前目录，App Sandbox）。四语本地化：zh-Hans 为源语言（中文原文即键），en/de/zh-Hant 由 `Tests/l10n` 流水线组装进 String Catalog。
「断档补点」：时间空洞两端锚点 A/B 向 OSRM（`routing.openstreetmap.de`）/ Valhalla（`valhalla1.openstreetmap.de`）取道路几何再沿路插点；「精确模式」两路同取并比对（`RouteCrossCheck`）。
批量补点窗口（`GPXPointViewer/BatchFillWindow.swift`）三步：① 判段 ② 取路 ③ 预览/落地；落地前可在修改记录窗口（`GPXPointViewer/ChangeReviewWindow.swift`）预览逐处效果（预览模式），每处可开关落地；落地后记录带两路草稿与依据（`TrackChange.drafts/cross/routeSource`）。
设计文档：`docs/cross-check-design.md`、`docs/batch-review-design.md`；README 功能段「断档补点（隧道）」；自测钩子与脚本说明 `Tests/README.md`（§2–§3，必读）。
关键代码入口（行号为 2026-10-26 时）：`GPXPointViewer/TrackStore.swift` — `load(urls:)` 911、`requestRouteDraft` 1992、`requestCrossCheckedDraft` 2060、`batch` 2769、`runBatch` 2959、`routeBatchItem` 3186（nonisolated，真正发请求的地方，返回 `BatchOutcome`）、`cancelBatch` 3422、`landBatch` 3515；`GPXPointViewer/BatchFill.swift`（BatchItem/BatchState/BatchStatus/ConflictKind）；`GPXPointViewer/RoadNetwork.swift`（`RouteDraft` 174、`RouteEngine`、`carRoute`、`RouteCrossCheck`）；`GPXPointViewer/GapFill.swift`（`GapRouteInputs`：一处断档取路的全部输入）；`GPXPointViewer/UITestHook.swift`（钩子命令 + `stateJSON` / `reviewstate`）。

用户反馈原话（2026-10-26）：
> 加一个缓存，只要我传一个 gpx/fwdb 文件进来，向路网请求了数据，这个数据就一直先存着，只要这个文件不关闭，这个路网数据就一直在，这样如果我取消落地之后又反悔，不用重新从路网读数据。当然要有个重新从路网获取数据的按钮，可以是重新获取所有断点，也可以针对某一个断点重新获取数据。

> （修改记录窗口里）要有一个按钮，能让我看到 OSRM 和 Valhalla 各自在这里的数据，你没做。

背景事实：精确模式下两路几何经常完全相同（最多相差 0 m），现在详细页把另一路画成蓝虚线，被采用的绿线盖住，用户看不出有两份。

## 1. 要做的功能

### 1.1 路网结果缓存（按打开的文件）

- `TrackStore` 里加一个缓存（例如 `RouteCache`，主线程持有、`routeBatchItem` 这类 nonisolated 代码通过 actor 或传入快照访问——保持现有并发模型，不引入数据竞争）。
- 键：这一处断档的**完整取路输入**（`GapRouteInputs` 里影响结果的全部字段：锚点下标与坐标、方向点、上下文点、匹配点、半径、公路/铁路、以及引擎 `RouteEngine`）。请把键做成可哈希的结构并写注释说明哪些字段参与；同一处断档在同样输入下第二次就不再请求。点距、精确模式开关、勾选状态**不参与**键（它们不影响路网几何）。
- 值：该引擎这一处的结果——`RouteDraft`（含 notes/method/shift）或「无路」（noRoute 也缓存，它是确定性的）；传输失败 / 429 冷却 / 取消**不缓存**。精确模式的比对结果 `RouteCrossCheck.Result` 由两份草稿现算即可（便宜），也可以一起缓存。
- 生命周期：`load(urls:)` 换文件时清空（含 .fwdb）；关批量窗口、取消批量、退出预览、落地、撤销/还原都**不清**。内存即可，不要落盘。
- 命中时：notes 里加一行「路网结果来自缓存（本文件打开以来取过）」，批量进度文字里显示「命中缓存 N 处」，`BatchState` 加计数 `cacheHits`；主窗口单处补点的「路网草稿」菜单也走缓存。
- 重新获取：
  - 批量窗口第 2/3 步：「重新获取全部…」按钮（确认弹层：会忽略缓存向路网重新请求 N 处公路/铁路断档，预计用时），执行等同于忽略缓存重跑第 2 步；
  - 每一行：右键/行内菜单「重新获取这一处」（只重跑这一项，保留其它项状态与用户的勾选/手选）；
  - 单处补点操作条：「重新取（忽略缓存）」。
  - 实现上给取路入口一个 `ignoreCache: Bool` 参数，别复制整段逻辑。
- 缓存不改变现有的网络纪律（限速器、冷却、故障停用引擎等照旧）。

### 1.2 修改记录窗口：两路切换

- 详细页（预览模式与已落地记录模式都要）当 `drafts.count >= 2` 时显示分段控件「OSRM | Valhalla」（用引擎名，采用的那份名字后带「✓」，例如「OSRM ✓」）。切换只改**当前显示**哪一份：地图上被显示的那份画成粗实线（颜色保持现有口径：采用的绿、未采用的蓝），另一份细虚线；点击「说明…」弹出的是被显示那份的 notes；依据行（`evidenceRow`）的来源·方式·长度·贴路也跟着切。切换**不改变**采用哪一份、不改变勾选/落地。
- 两路几何完全相同时（`cross` 的最大偏差为 0，或坐标逐点相等），分段控件旁加说明「两路几何完全相同」，免得用户以为切换没反应。
- 翻到另一处时显示份复位为「采用的那份」。
- 不要用 UI 禁词：待审核 / 报警 / 冲突 / 已验证 / 失锁（代码注释里可以用）。

### 1.3 钩子与 state JSON（`UITestHook.swift`）

- `routecache stats` → 返回「entries=N hits=M」；`routecache clear`。
- `batchrefetch all` / `batchrefetch <i>`（忽略缓存重取全部 / 第 i 项）。
- `routerefetch`（单处补点忽略缓存重取当前来源）。
- `reviewdraft osrm|valhalla|next`；`reviewstate` JSON 加 `shownDraft`（当前显示的引擎名）与 `sameGeometry`（布尔）。
- `state` 的 `batch` 加 `cacheHits`、根加 `routeCache{entries,hits}`。
- 现有钩子里，假引擎 `fakeroute <osrm|valhalla|all> <ok|offset m|noroute|fail|slow ms|off>` 与计数 `requestsByHost` 可以用来证明「没有再请求」。

## 2. 测试（全部离线，用假引擎；一次只跑一个测试副本，用默认通信目录 `~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest`）

先读 `Tests/README.md` §2.2–§2.5、§3.1–§3.3（怎么构建 Release、怎么起测试副本、`Tests/ui/ui.py` 的用法）。测试数据已在容器里（`Garmin_Roma_Da_copy.gpx` 等；若缺，`Tests/ui/setup_data.sh`）。

1. 在 `Tests/ui/run_batch_review_tests.py` 末尾（落地之前的阶段）或新建 `Tests/ui/run_route_cache_tests.py` 加用例（每条打印 ok/FAIL，末行 `FAILS: [...]`，与现有脚本一致）：
   - D1 精确模式假引擎 `fakeroute all ok` 跑完第 2 步后记 `requestsByHost`；`batchclose` 再 `batchplan`（`autotripmap 0`）、`batchall road`、`batchrun` 到 preview → `requestsByHost` **不变**、`batch.cacheHits` = 公路项数、各项 `routes`/`source`/`cross` 与第一次一致。
   - D2 `batchrefetch all` → `requestsByHost` 增加、`cacheHits` 为 0。
   - D3 `batchrefetch 3` → 只增加一项的请求数（两路各 +1）、其它项状态与勾选不变。
   - D4 `routecache stats` 的 entries > 0；`open` 另一份文件后 entries = 0。
   - D5 单处：`select 0`、`routecross`、再 `routecross` → 第二次不增请求；`routerefetch` → 增。
   - D6 审阅：`batchreview` 进预览，`reviewselect 0`，`reviewdraft valhalla` → `reviewstate.shownDraft == "valhallaCar"`，再 `reviewdraft osrm`；`sameGeometry` 在 `fakeroute all ok` 下为 true，在 `fakeroute valhalla offset 30` 重取后为 false。
2. 回归：`python3 Tests/ui/run_batch_review_tests.py`、`python3 Tests/ui/run_crosscheck_tests.py` 必须 `FAILS: none`；`python3 Tests/ui/run_profile_tests.py` 要**新起副本**单独跑（见 Tests/README.md 里 2026-10-26 的说明）。
3. 结束后复位偏好：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "fillpoints 0"`，并 `pkill -f app.noindex`。

## 3. 本地化（新增用户可见文案后必做）

流程见 `Tests/README.md` 第 410 行附近「本地化」一节：`xcodebuild -exportLocalizations …` 抽键 → `python3 Tests/l10n/extract_keys.py <export dir> <out dir>` 得 keys.jsonl → 新键翻译写进**下一个未用编号** `Tests/l10n/translations/chunk_21.json`（格式参照 `chunk_20.json`：`[{table,key,en,de,zh-Hant}]`；占位符多重集要一致）→ `python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`（期望输出 missing 0 / specifier problems 0）→ 重新构建 Release。导出产生的 Debug 构建产物与 export 目录放在 scratch 目录（`/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api2/`），不要留在仓库里。
术语：OSRM / Valhalla 原样；「路网」= road network（en）/ Straßennetz（de）/ 路網（zh-Hant）；「重新获取」= Fetch again / Erneut abrufen / 重新取得；「缓存」= cache / Cache / 快取。

## 4. 文档

- `docs/batch-review-design.md` 加「路网结果缓存」与「两路切换」两节（键的定义、生命周期、重取入口、钩子）。
- `README.md` 「断档补点（隧道）」段落里补一句缓存与重新获取、修改记录详细页可切换看两路。
- `Tests/README.md` 钩子清单补新钩子。

## 5. 产出与硬规则

- 产出：源码改动（运行器会记 changes.diff）、测试脚本、chunk_21.json、文档；`output.md`（中文）：做了什么、缓存键的定义、测试结果原文（各脚本末行 FAILS）、构建结果、未做/存疑的点。
- 构建：`xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build`（一次只跑一个 xcodebuild；最终必须 BUILD SUCCEEDED）。**不要**把产物装进 /Applications，不要删 /Applications 里的 app。
- 不联网：任何测试都在 `fakeroute all ok` 或 `fakeroute … offset/noroute` 下跑；`autotripmap 0` 防止 batchplan 查 Overpass。
- 保持现有并发/取消语义（`BatchCoordinator`、`LegOutcome`、`RateLimiter`）不退化；不要改 `RouteCrossCheck` 的判定规则。
- 进度随时写 progress.md（改了哪些文件、测试到哪一步），中断后续跑要能接上。
