# API 任务：多来源底图（OpenStreetMap / OpenTopoMap / Esri 影像）+ OSM 隧道叠加层

记录日期 2026-10-26。模型：claude-fable-5-1。权限：`--write`（改源码、xcodebuild、跑离线测试）。**测试不联网（假瓦片/假 Overpass）、不安装到 /Applications、一次只跑一个 xcodebuild 和一个测试副本**。用中文写 output.md 与进度。

## 0. 背景

GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX/CSV 轨迹查看器（仓库根目录就是当前目录，App Sandbox 已开 network client，四语本地化 zh-Hans 源 + en/de/zh-Hant）。
主窗口地图在 `GPXPointViewer/PointMapView.swift`（MKMapView + Metal 点层叠加），底图样式枚举 `BaseMapStyle`（标准/卫星/混合，rawValue 为中文、不本地化，显示用 `.title`），用户偏好 `mapStyle`；修改记录窗口 `GPXPointViewer/ChangeReviewWindow.swift` 有自己的 MKMapView 与底图分段（`TrackStore.reviewMapStyle`、`reviewLightMap`）。
Overpass 相关的缓存/限速已有：`GPXPointViewer/RoadNetwork.swift`（`RateLimiter`、`OverpassCache`、`host(for:)`、NetworkHealth 横幅）。钩子：`GPXPointViewer/UITestHook.swift`；测试说明 `Tests/README.md` §2–§3。

动机（诊断报告 `Tests/reports/20261026_1500_tunnel_diagnosis.md` §4/§6/§8）：补点用的是 OpenStreetMap 的道路几何，而显示用的 Apple 底图**不画隧道**（标准/混合都不画），用户看到补的点「在路外」其实是在 OSM 隧道中心线上 0 m。要让用户能看到路由用的那条线：① 可切换 OSM 标准瓦片当底图（画隧道虚线与分向车道）；② 不换底图也能在 Apple 图上叠一层 OSM 隧道线。
用户原话：「既然可能问题出在不同的地图对于隧道路线画的不同，我这个 app 应该需要支持不同来源的地图」。Google 不做（需密钥计费、条款限制在 Google SDK 之外使用）。

前面两个 API 任务（route-cache、tunnel-fix）已在同一仓库改过 TrackStore/RoadNetwork/GapFill/BatchFill/ChangeReviewWindow/UITestHook；先 `git diff --stat`、读 `docs/batch-review-design.md` 与 `docs/cross-check-design.md` 末尾几节了解现状，**不要回退它们的改动**；本地化块用下一个未用编号（`ls Tests/l10n/translations | sort | tail -1`）。

## 1. 要做的功能

### 1.1 底图来源（主窗口 + 修改记录窗口）
- `BaseMapStyle` 扩展三项：`OpenStreetMap`、`OpenTopoMap`、`Esri 影像`（rawValue 仍是稳定标识符，显示名本地化）。现有「标准/卫星/混合」保持 Apple。
- 实现：`MKTileOverlay` 子类（`canReplaceMapContent = true`，`loadTile(at:result:)` 用 URLSession 自己取，请求头 `User-Agent: GPXPointViewer/<CFBundleShortVersionString> (macOS; de.wayne.GPXPointViewer)`，`Accept: image/png`），加在最底层（`.aboveRoads` 之下，用 `MKOverlayLevel.aboveRoads` 之外的 `addOverlay(_:level: .aboveLabels)` 会盖住点层——点层是 Metal 自绘，确认叠层顺序不变）。切回 Apple 时移除 overlay。
- 瓦片来源与限制（写进代码注释与设置页说明）：
  | 来源 | URL 模板 | 最大 zoom | 署名 |
  |---|---|---|---|
  | OpenStreetMap 标准 | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` | 19 | © OpenStreetMap contributors |
  | OpenTopoMap | `https://{a,b,c}.tile.opentopomap.org/{z}/{x}/{y}.png` | 17 | © OpenTopoMap (CC-BY-SA), 数据 © OpenStreetMap contributors, SRTM |
  | Esri World Imagery | `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}` | 19 | Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community |
  - 超过最大 zoom 时用 `maximumZ` 让 MapKit 放大低一级瓦片，不请求不存在的级别。
  - 缓存：`URLCache` 独立实例（磁盘 ≤ 300 MB，放容器 Caches），遵守服务器缓存头；不做预取、不批量下载（OSMF 瓦片使用政策）。
  - 署名：地图左下角（Apple 的「地图」标识旁）显示对应署名文字，可点开链接（OSM → openstreetmap.org/copyright）。
  - 第一次切到任一外部底图时弹一次性说明（用量与署名要求、是公共服务请勿滥用），记住不再弹。
  - 失败处理：瓦片 4xx/5xx/超时不重试轰炸（同一瓦片 60 s 内不再请求）；连续失败走现有 NetworkHealth 横幅口径。
- 修改记录窗口的底图分段加同样三项（`reviewMapStyle` 复用 `BaseMapStyle`）；「浅色」开关对外部底图无意义时置灰。
- 暗色外观下外部瓦片不做反色，只保证文字可读。

### 1.2 OSM 隧道叠加层（任何底图上都能开）
- 开关「叠加 OSM 隧道」（主窗口图层面板 + 修改记录窗口顶栏），默认关，偏好 `tunnelOverlay`。
- 开着时，视野跨度 ≤ 40 km 且 zoom ≥ 11 才取：Overpass `way["tunnel"="yes"]["highway"~"motorway|trunk|primary|secondary|tertiary"]` 与 `way["tunnel"="yes"]["railway"~"rail|light_rail|subway|narrow_gauge"]`，`out geom`，bbox 取当前视野外扩 20%；相机停稳 600 ms 后再请求；同一时刻只有一个请求在飞；结果按 bbox 缓存（扩展 `OverpassCache` 或同款），命中就不请求；超过 40 km 显示「放大后显示隧道」。
- 画法：公路隧道一种颜色、铁路另一种，虚线、宽 3 pt、白描边；线上不要文字。
- 失败：429/5xx 走 `RateLimiter` 冷却；状态栏显示「隧道层：取回 N 条 / 冷却中 / 失败原因」。

### 1.3 设置与文案
- 设置页「地图」区：底图来源说明（公共服务、署名、用量）、「清空底图缓存」按钮（显示当前占用）。
- UI 禁词：待审核 / 报警 / 冲突 / 已验证 / 失锁。

### 1.4 钩子（UITestHook.swift）
- `set mapStyle <rawValue>` 已有，确认能切到三个新值；`reviewmap <standard|imagery|hybrid|osm|topo|esri> [light 0|1]`。
- `faketiles 0|1`：开着时瓦片 overlay 不出网，返回程序生成的 256×256 PNG（画上 z/x/y 文字），并计数 `tileRequests`。
- `tunnels 0|1`；`faketunnels <n>`：注入 n 条合成隧道 way（视野内直线），不出网；`state` 加 `baseMap`、`tileRequests`、`tunnelOverlay{on, ways, state, lastError}`；`reviewstate` 加 `baseMap`、`tunnelOverlay`。

## 2. 测试（全部离线）
- 新脚本 `Tests/ui/run_map_sources_tests.py`（起新副本，写法照 `run_batch_review_tests.py`）：
  - M1 `faketiles 1`、`set mapStyle OpenStreetMap`（用实际 rawValue）→ `state.baseMap` 变、`tileRequests` > 0；切回 标准 → overlay 移除（state 里 `baseMap` 回到 Apple，tileRequests 不再增加）。
  - M2 修改记录窗口：`reviewmap osm` → `reviewstate.baseMap`；`reviewmap standard light 1` 复原。
  - M3 `faketunnels 5`、`tunnels 1` → `tunnelOverlay.ways == 5`；`tunnels 0` → 0。
  - M4 署名文字随来源变化（通过 `shotviewwin`/state 字段任一方式断言）。
- 回归：`Tests/ui/run_crosscheck_tests.py`、`run_batch_review_tests.py`、`run_route_cache_tests.py`、`run_review_tests.py`（新起副本）、`run_profile_tests.py`（新起副本）全部 `FAILS: none`；`Tests/synth/runner/run_all.sh` 114/114（命令字符串必须以 `Tests/` 开头直接调用）。
- 结束复位：`python3 Tests/ui/ui.py "set mapStyle 标准" "reviewmap standard light 1" "tunnels 0" "faketiles 0" "crosscheck 0" "fakeroute all off"`，`pkill -f app.noindex`；偏好 `defaults` 里 mapStyle/reviewMapStyle/tunnelOverlay 复位。

## 3. 本地化与文档
- 新文案 → `xcodebuild -exportLocalizations …` → `python3 Tests/l10n/extract_keys.py <export dir> <out dir>` → 翻译进下一个未用的 `chunk_NN.json` → `python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`（missing 0 / specifier problems 0）→ 重建；导出产物放 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api4/`。
- 新文档 `docs/map-sources.md`：来源表、使用政策与署名、缓存策略、隧道层的请求规则；README 功能段加「底图来源」一句（含 Google 不做的理由）；Tests/README.md 补钩子与脚本。

## 4. 产出与硬规则
- `output.md`（中文）：实现摘要、各测试脚本末行原文、构建结果、未做/存疑。
- 不联网（真实瓦片/Overpass 只在用户手动使用时才会请求；测试全用 faketiles/faketunnels）；不安装；不动 /Applications；一次一个 xcodebuild；不回退前面任务的改动。
- 进度随时写 progress.md，中断续跑要能接上。
