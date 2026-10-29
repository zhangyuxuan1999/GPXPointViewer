# API 任务：Muenchen_Roma_Garmin 隧道补点 5 处问题的根因诊断（只读 + 少量联网）

记录日期 2026-10-26。模型：claude-fable-5-1。权限：**只读代码、不改任何源文件、不构建、不安装**；允许运行 python3 / swiftc、运行一份自己的测试副本、少量联网请求（限额见 §6）。
产出只写进运行器给你的运行目录（output.md、progress.md、以及你保存的 GeoJSON/JSON 中间文件）。用中文写报告。

## 0. 项目与背景

GPXPointViewer 是 macOS SwiftUI + MapKit + Metal 的 GPX/CSV 轨迹查看器（仓库根目录就是当前目录，App Sandbox，bundle id `de.wayne.GPXPointViewer`）。
「断档补点」功能：轨迹里的时间空洞（隧道、失锁）按两端锚点 A/B 向公共 OpenStreetMap 路线服务取道路几何（OSRM `routing.openstreetmap.de`、Valhalla `valhalla1.openstreetmap.de`，两者都用 OSM 数据），
再按原始点距沿路插点；「精确模式」两路同时取并比对。设计文档：`docs/cross-check-design.md`、`docs/batch-review-design.md`；功能总述：`README.md` 里「断档补点（隧道）」一段。
关键代码：`GPXPointViewer/GapFill.swift`（候选检测 GapDetector、采样画像、上下文/锚点外推 portalSamples 等）、`GPXPointViewer/RoadNetwork.swift`（取路、候选比较、RouteCrossCheck）、
`GPXPointViewer/TrackStore.swift`（requestRouteDraft / requestCrossCheckedDraft / runBatch / routeBatchItem / landBatch）、`GPXPointViewer/UITestHook.swift`（自测钩子）。

用户用 `data/compare/Muenchen_Roma_Garmin.gpx`（33,496 点，Garmin Explore App 导出，采样中位 1 s / 28 m，慕尼黑→罗马，走 A22/A1）在精确模式下批量补了 44 处，落地前审阅时指出 5 处有问题（截图见 §2）。
上一轮我已经确认：这 5 处 OSRM 与 Valhalla 的几何**完全相同**（最多相差 0 m），所以交叉验证查不出问题；它们都在隧道里（A22 Tusch 隧道、SS12/A22 Galleria Doss Trento、A1 Variante di Valico）。
用户不接受「是隧道所以看着在路外」这个解释，并指出了具体错误。本任务要**用数据把每一处的根因钉死**，并给出可实施的修改方案。

## 1. 已有的数据（不要重复取）

- 原始文件：`data/compare/Muenchen_Roma_Garmin.gpx`。
- 上一轮逐处取回的路网结果：`Tests/reports/inv5/cand13.json`（第 14 处）、`cand15.json`（第 16 处）、`cand18.json`（第 19 处）、`cand32.json`（第 33 处）、`cand33.json`（第 34 处）。
  每个 JSON：`anchorA/anchorB`（锚点在轨迹里的下标）、`route{source, meters, warnings, notes[]}`（notes 是 app 给用户看的判断依据，含「A 离路 32 m」之类的关键数字）、`points`（将新增的点）、`vertices`、`cross{shown, other, agree}`（两路各自的比对数据）。
- 44 处的取路输入：`Tests/reports/inv5/routeinputs.jsonl`（每行一处：ia/ib 锚点下标、bA/bB 方向点、cA/cB 上下文点、trace 匹配点、radius、tau、nature）。
- 用户截图（PNG）：`/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/userfb/fb_44.jpg` … `fb_49.jpg`（用 Read 工具看图；**只看 .jpg**，同目录的 .png 太大会撑爆运行器）。
- 上一轮我截的标准/混合底图截图：`/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/inv5/cand13_std.jpg`、`cand13_hybrid.jpg`、`cand15_*.jpg`、`cand18_*.jpg`、`cand32_*.jpg`、`cand33_*.jpg`（同样只看 .jpg）。

### 我已经核实的事实（第 14 处，A22 Tusch 隧道，意大利 Renon，46.50268° 11.45585°）

原始点（下标、UTC 时间、与前一点的时间差、步长、航向）：

```
9726 23:12:07 dt=1s ds=28.9m 222.6°
9727 23:12:08 dt=1s ds=28.8m 224.8°
9728 23:12:09 dt=1s ds=28.6m 225.3°
9729 23:12:10 dt=1s ds=28.5m 225.7°
9730 23:12:11 dt=1s ds=28.7m 225.7°
9731 23:12:12 dt=1s ds=28.6m 225.7°
9732 23:12:13 dt=1s ds=28.6m 225.7°   ← 锚点 A
9733 23:12:14 dt=1s ds=233.9m 232.2°  ← 区间内唯一一点，被替换（红点）
9734 23:12:22 dt=8s ds=27.1m 227.7°   ← 锚点 B
9735 23:12:23 dt=1s ds=29.6m 217.7°
```

- 9729–9732 航向锁死在 225.7°、步长锁死在 28.6 m：这是接收机进隧道后按最后速度**外推**出来的假点（卫星图上它们排成直线穿过森林，就是用户说「右上那几个蓝点才真正该删」的点）。它们现在被当成真实点，A 还取在最后一个假点上。
- 9733 一步跳了 234 m 但时间只过了 1 s，9734 才补上 8 s：这就是 Garmin「过时时钟」现象（复锁后头几个点时间戳滞后）。9733 的**位置**在 A22 出口段的车道上是对的，只是时间错了；它被整个替换，用户看成「删了不该删的点」。
- notes 里写「A 离路 32 m：补点起始 34 m 内渐进靠到 A」——隧道口外推逻辑（锚点离路 >20 m 且外侧点回到路上就把锚点往外挪）**没有触发**，而是做了渐进靠拢，要查清为什么。
- 两路路网给的几何完全一致（最多相差 0 m）；混合底图上，新增的绿点沿一条直线穿过森林，和那串假点共线，最后在 Via Prato all'Isarco 附近向西折到 A22 出口。要判定：这条直线是 OSM 里 A22 隧道 way 的几何（画成直线），还是路由走了别的 way。

## 2. 用户的指控（逐条回答）

| 截图 | 处 | 用户的话 | 要回答的问题 |
|---|---|---|---|
| fb_44.jpg（标准）/ fb_45.jpg（混合） | 第 14 处 Renon A22 | 删了一个不必删的点；右上那几个蓝点才该删；补的点跑到路外另一条路上了，切卫星也不对 | 假点怎么识别、为什么没识别；红点为什么被替换、位置对时间错该怎么处理；绿点到底在哪条 OSM way 上；OSM 的隧道几何与 Apple 底图差多少 |
| fb_46 | 第 16 处 Trento（Galleria Doss Trento / A22） | 中途换路 | 路线是否在 A22 与并行的 SS12 隧道之间切换；锚点是否吸错 |
| fb_47 | 第 19 处 Monzuno A1 | 中途换路 | 同上；A1 旧线与 Variante di Valico 并行，路由是否选了用户没走的那条 |
| fb_48 | 第 33 处 Calenzano A1（7.8 km） | 蓝点里有一处短断档没补上 | 找出那处空洞的下标、dt、距离；现行检测门槛是什么、为什么没进候选 |
| fb_49 | 第 33 处（同一处的另一段） | 补的点离路太远，是否 OSRM/Valhalla 的隧道与苹果地图不一致 | 量化：绿点到 OSM 隧道 way 的距离 vs 到 Apple 路线几何的距离 |

用户还问了一个总问题：「路网数据（苹果地图）明明画清楚了路线，为什么补出来的点能差这么多？」报告要用这 5 处的数字正面回答。

## 3. 要做的事

1. **第 14 处**：
   a. 用 Overpass 取 A22 在 46.498–46.507°N、11.450–11.462°E 范围内的 `highway=motorway*` way（带 tunnel 标签）几何（1 次请求即可，`[out:json][timeout:25]; way["highway"~"motorway"](bbox); out geom;`）。
   b. 把 cand13.json 里的 points/route 与 OSM way 逐点算距离，说明绿点在哪条 way 上、OSM 隧道是不是直线、出口处那个向西的折角从哪来（OSM 节点？路由贴路？`RouteDraft.snapB`？）。
   c. 读 `GapFill.swift` 里隧道口外推（portalSamples、"离路"相关、`shiftA/shiftB`）与 `RoadNetwork.swift` 里的调用，解释为什么 A 离路 32 m 却没外推（是外侧点也离路、还是上限 portalMaxPoints/阈值的问题），给出能让 9729–9732 被判为假点并一起替换的检测规则（建议：从锚点往外连续步的航向差 ≤0.2°、步长差 ≤0.2 m 的「冻结」段，至少 3 步；用这份文件里其它隧道口验证误报率——全文件扫一遍，统计有多少段满足条件、它们是否都紧邻断档）。
   d. 对 9733（位置对、时间错）给出处理建议：保留位置只改时间 vs 现在的整点替换，权衡后推荐一种。
2. **第 16、19 处**：对 cand15 / cand18 的几何，用 Overpass 取路线包围盒内的 motorway/trunk/primary way（每处 1 次请求），把路线逐段匹配到 way（ref / name / tunnel 标签），列出路线依次经过的 way 序列。判定是「换路」（路线在并行道路之间切换）、「锚点吸错路」还是「OSM 几何与 Apple 不同」。结合用户截图（fb_46、fb_47）说明用户看到的「换路」在图上对应什么。
3. **第 33 处短断档**：在 21,5xx–21,7xx 区间（以及 fb_48 视野 43.92296° 11.20589° 附近）扫描原始点，找 dt 或步长异常的空洞，列出下标/dt/ds；对照 `GapDetector.Options`（minMeters 150、minSeconds 20 等）和采样画像说明为什么没成为候选；提出门槛调整方案（例如按局部步长的倍数判定）并估计对整份文件候选数的影响（用 python 复现检测规则做粗算即可）。
4. **第 33 处偏离**（fb_49）：取 OSM A1 隧道 way 几何，算绿点到它的距离；再算绿点到 Apple 路线（见第 5 项）的距离；给出「OSM 隧道 vs Apple 隧道」的偏差量（最大/中位，米）。
5. **Apple 路线可行性**：写一个最小 Swift 命令行程序（`swiftc -framework MapKit -framework CoreLocation`），用 `MKDirections`（`transportType = .automobile`，`requestsAlternateRoutes = true`）请求 9726→9736（第 14 处）、以及第 16/19/33 处锚点外 ~150 m 的两点之间的路线，打印 polyline 坐标到 GeoJSON。
   - 成功：把 Apple 几何与 OSM 路线、与原始假点逐点比距离，回答「用 Apple 的路线补点，点会不会落在 Apple 底图画的路上」。
   - 失败（无 bundle / 权限 / 限流）：记录错误原文，说明是否需要在 app 内（有 bundle id、沙盒已开 network client）做，并估计工作量。
6. **底图/路网来源建议**：用户提议 app 支持多种地图来源（Apple 之外，比如 Google）。结合 MapKit 的能力（`MKTileOverlay` 叠栅格瓦片）评估：OpenStreetMap 标准瓦片（tile.openstreetmap.org，注意 OSMF 瓦片使用政策：需 User-Agent、不可大量使用、要署名）、OpenTopoMap、Esri World Imagery、Google（Map Tiles API 要密钥计费且 ToS 限制在 Google SDK 之外使用）。给出推荐清单（做哪几个、为什么、各自的署名与用量约束），以及「路线来源」清单（OSRM、Valhalla、Apple MKDirections、是否值得加 GraphHopper 等）。

## 4. 运行一份自己的测试副本（需要时才用；比如要重新取某处的两路结果或 routedump）

钩子说明在 `Tests/README.md` §2–§3 与 `GPXPointViewer/UITestHook.swift`。本任务**不要用默认通信目录**（另一个任务正在用），用独立目录：

```bash
# 准备：容器里的通信目录 + 轨迹拷贝（沙盒只能读容器里的文件）
python3 - <<'EOF'
import os, shutil, subprocess
C = os.path.expanduser("~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest-diag")
os.makedirs(C, exist_ok=True)
shutil.copy("data/compare/Muenchen_Roma_Garmin.gpx", C)
dst = os.path.abspath("Tests/ui/app-diag.noindex/GPXPointViewer.app")
subprocess.run(["pkill", "-f", dst], capture_output=True)
shutil.rmtree(dst, ignore_errors=True); os.makedirs(os.path.dirname(dst), exist_ok=True)
shutil.copytree("/Applications/GPXPointViewer.app", dst, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, dst, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
EOF
# 之后所有钩子命令都带 GPXPV_UITEST_IO 指向同一目录：
GPXPV_UITEST_IO=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest-diag python3 Tests/ui/ui.py "autotripmap 0" "open $HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest-diag/Muenchen_Roma_Garmin.gpx"
```

常用钩子：`state`（JSON：candidates、profile、route、cross…）、`exit` / `fill`（退出/进入补点模式；进入后 state 里有候选表）、`select <i>`（选第 i 个候选，0 起）、`crosscheck 1`、`fakeroute all off`（确保用真实路网）、`routecross`（两路取路并比对，等 `route` 非空）、`routedump <容器内路径>`（把两路草稿、notes、points 写成 JSON）、`shotwin 修改记录 <png>`、`set mapStyle 标准|卫星|混合`。
候选的序号与 44 处的对应：按 state.candidates 的 ia/ib 与 §1 的 anchorA/anchorB 对上（cand13 ⇔ ia 9732）。
结束时：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off"`（同样带 GPXPV_UITEST_IO），然后 `pkill -f app-diag.noindex`。不要碰 `/Applications/GPXPointViewer.app` 本身，不要碰默认的 `tmp/uitest` 目录。

## 5. 产出（运行目录里）

- `output.md`（中文）：
  1. 每处结论：数据（表格）、根因类型（A 锚点/假点处理、B OSM 几何与 Apple 不同、C 路由选路与实际不同、D 检测门槛）、对用户每句指控的回答。
  2. 代码定位：涉及的函数/常量、为什么没按预期工作（引用行号）。
  3. 修改方案：按优先级列，每条含算法/阈值、改哪个文件哪个函数、怎么测（可离线复现的测试输入：下标区间、期望结果）。
  4. Apple MKDirections 可行性结论与数据；OSM vs Apple 隧道几何偏差表。
  5. 底图与路线来源建议清单。
  6. 请求用量：对每个公共服务各发了几次请求。
- 中间文件：各处的 `gapNN_osm_ways.json`（Overpass 原始返回）、`gapNN_apple.geojson`、`gapNN_compare.json`（逐点距离）。

## 6. 硬规则

- 联网限额：Overpass ≤ 6 次、OSRM ≤ 6 次、Valhalla ≤ 6 次、Apple MKDirections ≤ 8 次；**串行**，两次请求之间 ≥ 1.5 s；User-Agent 写 `GPXPointViewer-diagnosis/1.0 (contact: zhangyuxuan.wayne@gmail.com)`。收到 429/5xx 就停下记录，不重试轰炸。
- 不改任何仓库文件、不 xcodebuild、不安装、不动 /Applications、不动默认钩子目录 `tmp/uitest`。
- 中间文件、脚本、GeoJSON 写进运行器给你的进度目录 `Tools/agents/runs/<本次运行>/`（允许；运行结束会被收走）或 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/diag/`；仓库其它位置不要新建文件。
- 进度随时写 progress.md（做到哪一步、已发多少请求、中间文件路径），中断后续跑要能接上。
- 不确定的结论要标「推测」，并说明验证它还缺什么数据。
