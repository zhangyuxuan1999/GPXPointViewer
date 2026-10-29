# 多来源底图与 OSM 隧道叠加层（2026-10-26）

## 为什么

补点用的是 OpenStreetMap 的道路几何（OSRM / Valhalla / Overpass 都基于 OSM），而显示用的 Apple 底图**不画隧道**（标准 / 混合都不画）。用户看到补的点「在路外」，其实它们在 OSM 隧道中心线上 0 m（诊断报告 `Tests/reports/20261026_1500_tunnel_diagnosis.md` §4/§6/§8）。要让用户看到路由用的那条线，有两条路：

1. 把底图换成 OpenStreetMap 标准瓦片（画隧道虚线与分向车道）；
2. 不换底图，在 Apple 图上叠一层 OSM 隧道线。

两条都做了。Google 地图不做：需要密钥计费，且条款禁止在 Google SDK 之外使用其瓦片。

## 1. 底图来源

`BaseMapStyle`（`TrackData.swift`）在 Apple 的 标准 / 卫星 / 混合 之外多了三项，rawValue 是稳定标识（偏好、钩子、渲染缓存键都用它），显示名本地化：

| rawValue | 来源 | URL 模板 | 最大 zoom | 署名 |
|---|---|---|---|---|
| `OpenStreetMap` | OSM 标准瓦片 | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` | 19 | © OpenStreetMap contributors |
| `OpenTopoMap` | OpenTopoMap | `https://{a,b,c}.tile.opentopomap.org/{z}/{x}/{y}.png`（子域按 (x+y)%3 轮流） | 17 | © OpenTopoMap (CC-BY-SA), data © OpenStreetMap contributors, SRTM |
| `Esri 影像` | Esri World Imagery | `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}`（注意 z/y/x） | 19 | Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community |

实现（`MapSources.swift`）：

- `ExternalTileOverlay: MKTileOverlay`，`canReplaceMapContent = true`，`loadTile(at:result:)` 用自己的 `URLSession` 取瓦片。
- `BaseMapApplier`：每个 `MKMapView` 一个。外部来源时把地图配置退到 `MKStandardMapConfiguration(elevationStyle: .flat)`（立体高程会让瓦片变形；也不画 Apple 的兴趣点/交通），然后 `insertOverlay(_, at: 0, level: .aboveLabels)`——盖住 Apple 自己的文字（OSM 瓦片自带文字），但在所有折线/多边形覆盖层之下。Metal 点层是 `MKMapView` 的**兄弟子视图**（`MapContainerView` / `ComparePaneView`），永远在瓦片之上，叠层顺序不变。切回 Apple 时移除 overlay 并恢复 Apple 配置。
- 用到的地图：主窗口（realistic 高程，外部来源退平面）、对比模式双栏、找不同窗口、修改记录窗口（`reviewMapStyle` 复用同一枚举；「浅色」开关对外部来源置灰——瓦片不分日夜、不反色）。
- 快照路径（高清图片导出、视频导出、3D 热力地面）用 `MKMapSnapshotter`，它**不画瓦片 overlay**，外部来源按 `appleFallback` 退回最接近的 Apple 底图（OSM/OpenTopoMap → 标准，Esri → 卫星）。
- 偏好：`mapStyle`（主窗口，UserDefaults，启动时恢复）、`reviewMapStyle`（修改记录窗口）。

### 使用政策与署名

- 请求头：`User-Agent: GPXPointViewer/<CFBundleShortVersionString> (macOS; de.wayne.GPXPointViewer)`、`Accept: image/png`（Esri 返回 JPEG，忽略该头）。每主机并发 ≤ 4。
- 不超过各来源的最大 zoom：`maximumZ` 让 MapKit 放大低一级瓦片，不请求不存在的级别。
- 只按视野取瓦片；**不预取、不批量下载**（OSMF 瓦片使用政策）。
- 署名：地图左下角（Apple「地图」标识旁）显示对应署名，点一下打开版权页（OSM → openstreetmap.org/copyright）。设置页「地图」区也列出三家署名。
- 第一次切到任一外部底图弹一次性说明（用量与署名要求、公共服务请勿滥用），`externalMapNoticeShown` 记住不再弹。

### 缓存与失败

- 独立 `URLCache`：内存 32 MB、磁盘 300 MB，目录为容器 `Caches/MapTiles`；遵守服务器缓存头（不自己强制过期）。设置页「清空底图缓存」显示当前占用、一键清空。
- 瓦片 4xx/5xx/超时：同一瓦片 60 s 内不再请求（按 z/x/y 记冷却）；每次成功/失败都报 `NetworkHealth.note`，连续失败走现有橙色横幅口径（「网络不好：最近 N 次请求 M 次失败」）。

## 2. OSM 隧道叠加层

开关「叠加 OSM 隧道」（主窗口图层面板 + 修改记录窗口顶栏），偏好 `tunnelOverlay`，默认关。实现 `TunnelOverlay.swift` 的 `TunnelLayer`，每个地图一个实例（`registry["main"]` / `registry["review"]`），各自按自己的视野取数。

请求规则：

- 视野跨度 ≤ 40 km **且** 瓦片 zoom ≥ 11 才取（zoom = log2(360 · 视宽px / (256 · 经度跨度))）；更远时清掉线、状态「放大后显示隧道」。
- bbox = 当前视野外扩 20%；相机停稳（`regionDidChangeAnimated`）后 600 ms 防抖再请求；已取范围包住当前视野就不再请求。
- 同一时刻只有一个隧道请求在飞（主窗口与审阅窗口共享 `inFlight`）；另一个图层碰上就再等一轮防抖。
- 结果按 bbox 缓存：独立的 `OverpassCache` 实例（与批量判段的实例分开，同一 bbox 不同查询不能串），包含匹配即命中。
- 查询（POST 到 `RoadNetwork.overpassEndpoints` 的镜像，失败依次换下一个）：

  ```
  [out:json][timeout:25];
  ( way["tunnel"="yes"]["highway"~"motorway|trunk|primary|secondary|tertiary"](s,w,n,e);
    way["tunnel"="yes"]["railway"~"rail|light_rail|subway|narrow_gauge"](s,w,n,e); );
  out geom;
  ```

- 429/5xx：走 `RateLimiter.perform(failIfCooling: true)`——主机冷却中直接报「冷却中（还有 N s）」，不排队；其他失败报原因。状态行「隧道层：取回 N 条 / 正在取回… / 冷却中 / 失败（原因）/ 放大后显示隧道」在图层面板开关下方与审阅窗口顶栏。

画法：公路隧道洋红、铁路隧道蓝，虚线（10/6）宽 3 pt，下面垫一条同几何的白色 5 pt 虚线当描边；线上没有文字。折线挂在 `.aboveLabels` 层，在瓦片底图之上、Metal 点层之下。

## 3. 自测钩子（UITestHook）

- `set mapStyle <rawValue|standard|imagery|hybrid|osm|topo|esri>`；`reviewmap <同上> [light 0|1]`。
- `faketiles 0|1`：瓦片不出网，返回程序生成的 256×256 PNG（画着 z/x/y），开时把 `tileRequests` 清零。**自测副本（`GPXPV_UITEST_DIR`）启动即为 1**，免得偏好里记着外部底图时一启动就出网。
- `tunnels 0|1`；`faketunnels <n>`：注入 n 条视野内的合成隧道 way（公路/铁路交替的水平直线），0 关；`tunnelrefresh` 作废已取范围重取；`mapgoto <lat> <lon> <km>` 把主地图视野置中；`mapnotice [0|1]` 读/写一次性说明的偏好（脚本结束还原）；`tunnelnet 0|1`：自测副本默认不让隧道层出网（没有合成数据时状态 failed + "network disabled"），人工验证才放行。
- 瓦片请求结果按 30 s 窗口汇总后才进 NetworkHealth（失败 ≥ 3 块且占多数报一次失败；成功每窗口最多报一次；404 不算），免得一次平移的几十块瓦片把补点/Overpass 的横幅冲掉。
- 审阅窗口的草稿折线改挂 `.aboveLabels`（`.aboveRoads` 整层会被不透明的瓦片底图盖住），隧道线画上来后草稿会重新抬到最上面。
- `state`：`baseMap`、`tileRequests`、`fakeTiles`、`attribution`、`tunnelOverlay{on,ways,state,lastError}`（state ∈ off/idle/tooFar/fetching/ready/cooling/failed）；`reviewstate`：`baseMap`、`attribution`、`tunnelOverlay`（审阅地图没显示时 state = `noMap`）。
- 脚本 `Tests/ui/run_map_sources_tests.py`（全离线，自己起副本，约 1 分钟）。

## 4. 没做 / 存疑

- 快照类导出（图片 / 视频 / 3D 热力地面）在外部底图下用 Apple 替代，没有自己拼瓦片。
- 暗色外观下外部瓦片不反色（只保证界面文字可读）。
- 真实瓦片 / Overpass 只在用户手动切换时请求；自动化测试一律假瓦片 / 合成隧道。
