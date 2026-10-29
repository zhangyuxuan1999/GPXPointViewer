# 任务：把过期的文档改对（README 文件结构、地区设计文档、历史探针说明）· 2026-10-28

## 背景
DeepSeek 的建议书 `Tests/reports/20261028_1201_2026-10-28_feature_ideas.md` 第 4 节「代码/文档里看起来没做完的东西」和问题清单 P2 / P5 指出几处文档和代码现状不符。本任务只改文档，不碰代码、不构建、不跑 app、不联网。

## 允许改的文件（只有这些）
- `README.md`
- `docs/regions-design.md`
- `Tests/README.md`
- `Tests/tasks/api/_backlog.md`（只追加）

## 要改什么
1. **README.md 的「文件结构」一节**（约第 119–143 行，只列了旧模块）：按 `GPXPointViewer/*.swift`、`GPXQuickLook/*.swift`、`GPXThumbnail/*`、`Tests/`、`Tools/`、`docs/` 的**实际内容**重写：每个 Swift 文件一行，一句话说它干什么（从文件头注释取；没有注释就读前 60 行归纳）。用 Glob 列全，不要漏（现在约 34 个 Swift 文件：BatchFill、BatchFillWindow、ChangeLog、ChangeReviewWindow、DiffCompare、DiffWindow、FillPlausibility、FogArchive、GapFill、Heat3D、L10nSupport、MapSources、MetalPointRenderer、PixelGlobe、Playback、PointMapView、RegionIndex、RegionStats、RegionsWindow、RoadNetwork、RouteReplay、TrackData、TrackStore、TunnelOverlay、UITestHook、VideoExport、GPXParser、GPXWriter、ExportSheet、ContentView、GPXPointViewerApp、StressTest 等，以 Glob 为准）。
2. **docs/regions-design.md**（约第 55–61 行）仍说 `Regions.bin` 是「0 个地区的占位文件（待办）」，而同文档第 86–103 行和实际文件（`ls -l GPXPointViewer/Regions.bin`，约 29.4 MB、5309 个地区）说明真实数据已接入：把占位段落改成现状描述，并保留「怎么换源/重建」的说明。文档里其它地方凡与现状矛盾的也顺手改（先通读全文）。
3. **Tests/README.md** 第 393 行附近提到 `railgraph` / `routeprobe2` 因 API 变化编不过：加一句「历史探针，不随产品维护；要用得先修编译」，避免误导。
4. **README.md 其它过期句子**：通读一遍，凡是和 `docs/*.md` 或代码现状明显矛盾的（例如说某功能「待做」但已经有了），改成现状；拿不准的不改，列进报告。
5. 在 `Tests/tasks/api/_backlog.md` 末尾追加一节「2026-10-28 文档刷新后仍待处理」，把你发现但不属于本任务的点列进去（例如 DeepSeek 提到的地区数据小错：阿鲁巴首府点落在多边形外、name_zh 夹繁体字、「佛罗伦斯省」应为「佛罗伦萨」等，照抄它的描述并注明来源）。

## 规则
- 只改上面四个文件；改文档用 Edit/Write；不运行脚本、不起 app、不联网。
- 每处改动要能在源码或文件系统里核实（用 Glob/Grep/ls），不要凭推测写功能描述。
- 中文；保持各文档原有的语气和格式。

## 报告
按运行器要求输出：改了什么（逐文件逐处）、没改的和原因、追加到 backlog 的条目。
