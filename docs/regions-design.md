# 地区统计（国家 → 省/州 → 市）设计 · 2026-10-25

## 目标
对标《世界迷雾》新版的"行政区"卡片：按国家列出已探索的省/州（德国到州、中国到地级市/直辖市的区），每个地区给
已探索面积、占该国已探索总面积的百分比、下级行政区到访数；查看点模式给点数/天数，迷雾模式给面积/等级口径。
热力图模式不做。

## 数据从哪来
- 《世界迷雾》存档（.fwdb）里**没有**行政区信息（新旧库逐字节对比：区块编码/布局完全一致，只是内容增长、
  空 tile 不再保留），省/州是 App 内置边界数据算出来的。我们也内置。
- 边界来源（已下载并离线预处理成 app 内置的 `Regions.bin`；换源/重建见下文「内置数据现状」）：
  - 国家：geoBoundaries CGAZ ADM0 多边形（CC BY 4.0；2026-10-25 换源，见下），Natural Earth 10m
    `admin_0_countries` 提供属性与名称；港澳与 CGAZ 没有的 62 个小属地仍用 NE 多边形。
  - 省/州：Natural Earth 10m `admin_1_states_provinces`（公共领域，含 name_zh/name_de/name_en）。
  - 中国地级：阿里云 DataV GeoAtlas `areas_v3/bound/<省 adcode>_full.json`（31 份大陆省级文件；直辖市给区；港澳分区单独处理）。
- 预处理 `Tools/build_regions.py`（纯标准库）：解析 GeoJSON → Douglas-Peucker 简化（容差 ~150 m）→
  微度 Int32 坐标 → 1°×1° 格索引（每格相交的地区 id 列表）→ 四语名称表 → `Regions.bin`。

## 二进制格式 `Regions.bin`（小端）
```
magic "RGN1" u32version
u32 regionCount, u32 ringCount, u32 vertexCount, u32 gridCellCount
regions[regionCount]: u16 id, u8 level(0 国 1 省/州 2 市), u16 parent(0xFFFF=无), char[2] iso2(国家才有), 
                     f32 areaKm2(官方/计算), f32 minLat,minLon,maxLat,maxLon, u32 ringStart, u16 ringCount,
                     u32 nameOffset(zh-Hans), u32 nameOffsetEn, u32 nameOffsetDe, u32 nameOffsetHant
rings[ringCount]:  u32 vertexStart, u32 vertexCount, u8 isHole, f32 bbox×4
vertices[vertexCount]: i32 latMicroDeg, i32 lonMicroDeg
grid: 360×180 格，每格 u32 offset + u16 count 指向 u16 regionId 列表（按 level 排序）
names: UTF-8 zero-terminated 字符串池
```

## App 内
- `RegionIndex.swift`：懒加载 bin；`lookup(lat:lon:) -> UInt16?（最细一级，父链用 parent(of:)）；逐点归属用 Assigner.assign(lat:lon:)` = 格索引候选 + 射线法；
  `Assigner.assign(lat:lon:)`（逐点最细 id），按 0.01° 单元缓存（单元内无边界经过才整单元共用，见下文「点归属缓存」）。
- `RegionStats`（TrackStore 后台算，按轨迹缓存）：
  - 查看点模式：每地区 点数、到访天数、首末时间；
  - 迷雾模式：每地区 解锁格数、面积 km²（格宽 9.55 m×cosφ 逐格累计，与 FogStats 同口径）、等级 ⌊√(km²×250)⌋、
    占该国已探索面积的百分比；`.fwdb` 模式用存档的解锁格。
  - 国家卡：到访行政区 n/N、已探索面积、占国土百分比。
- 界面：新窗口「地区统计」（Window id regions，像修改记录窗口）：左列国家（国旗 emoji 按 ISO），右侧省/州排行
  （名次、名称、面积/点数、百分比、下级到访数徽标），中国的省可点进地级市一层；点一行主地图飞到该区并画边界。
  控制面板和迷雾行各加入口；热力图模式隐藏。
- 本地化：新文案走 String Catalog 流程（Tests/l10n）。

## 测试（交给 DeepSeek）
- 合成：构造已知落点的 GPX（例如法兰克福/西安/边界上的点）→ 探针校验 lookup 与统计；
- UI：钩子命令 `regions`（返回统计 JSON）、`regionselect`、`shotwin 地区统计`；
- 真实：Garmin_Roma_Da（意大利/瑞士/德国）、2026.csv（德国/卢森堡）、`.fwdb` 两份存档。


## 实现状态（2026-10-25，内置数据 2026-10-28 核对）

- 已实现：`GPXPointViewer/RegionIndex.swift`（读 Regions.bin、格候选、偶奇射线法、`Assigner` 1 km 单元缓存、按界面语言取名、国旗 emoji）、
  `GPXPointViewer/RegionStats.swift`（`RegionStatsBuilder.points / .fog`、`RegionReport`）、`GPXPointViewer/RegionsWindow.swift`（窗口 `SceneID.regions`）、
  `TrackStore`（`regionReport / regionsMode / regionSelection / ensureRegionReport() / selectRegion()`）、`PointMapView` 协调器（`applyRegionHighlight()` + `rendererFor overlay`）、
  控制面板「地区统计…」按钮（热力图模式隐藏）。`TrackData.fogUnlockKeys()` 从 `computeFogStats()` 拆出来，两处共用同一套解锁格键。
- 测试钩子：`regions`（开窗口）、`regionsmode points|fog`、`regionstate`（JSON：index/regions/mode/modes/selection/highlightPolys/ready/totals/countries 嵌套）、
  `regionselect <id>|off`、`regionlookup <lat> <lon>`（返回 `id:名 < 父 < 国`）；`state` 里多了 `regionsReady / regionSelection / regionsIndex`。
  环境变量 `GPXPV_REGIONS_BIN=<路径>` 可换一份边界（自测用 `Tests/synth/regions_synthetic.bin`，`open --env` 传入，路径须在沙盒容器里）。
- 回归脚本：`Tests/ui/run_regions_stats_tests.py`（合成边界 + 合成轨迹的确定性断言、.fwdb 口径、内置 Regions.bin 路径）。
- **内置数据现状（2026-10-28 核对）**：`GPXPointViewer/Regions.bin` 已接入真实边界，不再是占位文件——文件头显示
  29,411,770 字节（约 29.4 MB）、5319 个地区、14,275 环、3,496,861 顶点。窗口能正常出国家/省州/中国地级市卡片，
  不再显示「没有内置行政区边界数据」。
- **换源 / 重建**：原始数据用 `Tools/fetch_regions_data.sh` 下载（需用户批准；落到 `data/regions-src/`，只下载、不生成），然后跑
  `python3 -I Tools/build_regions.py --countries data/regions-src/ne/ne_10m_admin_0_countries.geojson --admin1 data/regions-src/ne/ne_10m_admin_1_states_provinces.geojson --china-dir data/regions-src/datav --countries-geom data/regions-src/cgaz/geoBoundariesCGAZ_ADM0.geojson --tolerance-m-l0 100 --out GPXPointViewer/Regions.bin`。
  换源或调参后先跑 `Tests/ui/run_regions_stats_tests.py` 与 `Tests/probes/regions/run.sh`；自测时可用
  `GPXPV_REGIONS_BIN=<容器内的 .bin>` 临时换一份边界，不动内置文件。


## 格式补充与约定（2026-10-25 复审后，以 RegionIndex.load / Builder.write 为准）

- 全部小端、无对齐：地区记录 49 B（`<HBH2sfffffIHIIII`），环记录 25 B（`<IIBffff`，外接框顺序 minLat,minLon,maxLat,maxLon），顶点 8 B（`<ii` lat,lon 微度）。
- 格表 360×180 之后：`u32 nList` + `u16 regionId[nList]`；每格的 offset 以**列表条目**计。每格切片按 level **降序**（市→省→国），同级按 id 升序。
  格号 ci = clamp(⌊lat+90⌋,0,179)×360 + clamp(⌊lon+180⌋,0,359)。
- 名称池之前有 `u32 nameBytes`；名称 UTF-8、`\0` 结尾，地区记录里的四个偏移指向池内。
- 地区 id 必须等于记录下标；parent 为 0xFFFF 或 < 地区数；level ≤ 2；地区数 < 0xFFFE（0xFFFE/0xFFFF 是运行时哨兵）。读取端会校验这些以及环/顶点/列表范围，不满足就当没有数据。
- iso2 为两位 A–Z（空格填充）；不是 A–Z 的值不出国旗。
- **环顺序约定**：每个外环后面紧跟它自己的洞（isHole=1），app 端据此分组画 MKPolygon。
- 文件里的 f32 外接框只作参考；app 载入时按微度顶点重算（f32 四舍五入会向内缩 ≈1 m）。
- 经度 180° 在查询前并到 −180°（多边形在 −180 一侧）。
- **跨国格规则**：某 1° 格的候选分属多个国家时，子级（省/市）命中还要求其所属国家的多边形也包含该点，否则跳过继续找——
  DataV 地级边界与 NE 国界不一致（争议区、GCJ 残差）时以 NE 国界裁决，不让一套数据的越界把点算给别国。
- **点归属缓存**：0.01° 单元内若无任何候选环的边经过（按 1° 格栅格化成 100×100 位图，带 1 单元余量），整单元同属（中心判一次）；
  有边经过的单元逐点判。飞地 / 窄条 / 小岛 / 凸出都不会丢（Tests/probes/regions 验证）。
- **预处理规则**：每块地区最大的多边形永远保留（微型国家不消失），`min_ring_km2` 只筛其余小岛（国 1 / 省州 0.2 / 地级 0.05 km²）；
  洞一律保留（洞是别人的飞地）；DP 容差自适应 `min(tol, 5%×√面积)`（国/省 150 m，地级 50 m）；
  DataV 坐标默认按 GCJ-02 反解到 WGS-84（`--datav-datum wgs84` 可关）；地级按文件名 / parent.adcode 的省 adcode 挂到 NE 省（表 CN_PROVINCES：ISO 3166-2 两种写法 + 简称），
  任一省文件贡献 0 个地级或总数 < 300 即报错退出；中国省面积 = 地级之和；显示名用简称（陕西 / 西安），DataV 的 en/de/zh-Hant 留空由 app 回退。
- 已知未做：相邻地区各自简化会在共享边界留 ≤ 几十米的缝/重叠（缝里的点算省直属，窗口以「其余」行显示）；
  法/意/西/英按大区分组后（省/县为二级），与《世界迷雾》的区划单元仍不完全一致；海岸线外（海滩、填海）的点算未归属。


## 真实数据接入（2026-10-25 初版）

- 数据：Natural Earth 10m v5.1.2（admin-0 258 国、admin-1 4596 单元，公共领域）+ 阿里云 DataV GeoAtlas areas_v3（31 省的 449 个地级/区、港澳 26 区；GCJ-02 已反解）。
  初版构建 6.6 s，Regions.bin 14.18 MB、5309 地区、13693 环、160 万顶点；国界换源后的当前文件见下（5319 地区 / 14,275 环 /
  3,496,861 顶点 / 29,411,770 字节）。中国 31 省（NE 的「西沙群岛」省级单元已跳过）。
- 对账（新版存档 2026_fog_new_db，1,209,290 格）：德国 34.2438 km² ↔ 世界迷雾卡片 34.2915（−0.14%）；黑森 6.6777 ↔ 6.6733（+0.07%），占比 19.50% ↔ 19.46%；
  到访州 12/16 ↔ 12/16。分区等级 92 ↔ 世界迷雾 96（它的分区等级公式未知，不是 ⌊√(km²×250)⌋）。
- 性能：2,016,647 点归属 0.21 s；1.2M 格迷雾报告 0.20 s（探针，-O）。
- **已知误差（2026-10-25 换源前）**：NE 10m 国界有 200–1000 m 的概化误差。用户的漠河江边轨迹 24,352 点里 360 点（1.5%）落入俄罗斯，巴塞尔—弗赖堡莱茵河边 20,063 点里 750 点（3.7%）落入法国，
  新版世界迷雾都不再这样算。要消除需换更高分辨率的国界数据（候选：geoBoundaries CGAZ ADM0 / OSM admin_level=2），
  只换 admin-0 即可：跨国格规则会按国家多边形裁决，NE admin-1 伸出国界的条带会被退回正确国家的州。
- 名称：NE 的 name_zh 覆盖大部分一级行政区；港澳区名只有中文（en/de 回退到中文）。法/意/西/英的 NE 单元是省/县级（英 232、意 110、法 101），app 里已按大区分组（见下）。

- **2026-10-25 国界换源**：国家多边形改用 geoBoundaries CGAZ ADM0（218 国，按美国国务院 LSIB 国界裁剪；CC BY 4.0，各国源另有 ODbL 等许可），
  NE admin-0 只出属性与名称（港澳与 CGAZ 没有的 62 个小属地仍用 NE 多边形）。容差 100 m（50 m 与 100 m 结果相同）。
  效果：漠河江边 360 → 0 个点漏到俄罗斯；莱茵河边 750 → 133 个点漏到法国（0.66%）；德国对账 34.2863 ↔ 34.2915（−0.015%）。
  代价：Regions.bin 14 → 29 MB（3,496,861 顶点）。NE 州界与 CGAZ 国界之间的条带算国家直属（「其余」行）。
- 完整账号存档（data/Sync_all，10,465,670 格）对账：中国 497.966 ↔ 498.153，陕西 140.485 ↔ 140.494，北京 47.343 ↔ 47.320（15/16），西安 71.83 ↔ 71.75，海淀 14.03 ↔ 14.07。
  新疆到访数 15/24 ↔ 13、河北 11/11 ↔ 12：世界迷雾的区划单元与 DataV 略不同。
- 存档目录不再要求 `.fwdb` 后缀：目录里（或 Sync/ 下）有 ≥2 个区块文件（名字去首 4 尾 2 后全是密码表字母）就当存档。


## 属地 / 飞地 / 缝的规则（2026-10-25，按 Claude API 全球抽查的发现修）

- **属地**：CGAZ 把直布罗陀、关岛、法罗、马恩岛、泽西、波多黎各、港澳…并进宗主国，NE 把它们单列（SOV_A3 指向宗主国）。构建时把宗主国 CGAZ 几何里
  「顶点多数落在属地 NE 多边形里、或外接框落在属地外接框内，且面积同量级」的多边形切出来，**转给属地**（比 NE/CGAZ 给属地自己的那份细）。面积限制防止以色列整块被挪给巴勒斯坦。
- **国家层重叠**（飞地没挖洞、属地叠加）：app 端在跨国格里取「包含该点的最小外环」所属的国家（坎皮奥内 → 意大利）。省/市层同级按面积升序排候选（小的先命中）。
- **缝**：NE 州界与 CGAZ 国界之间 1–2 km 的条带、威尼斯本岛、朗伊尔城这类海岸缺口，点落到国家直属时吸附到本国 ≤3 km 内最近的一级行政区（`nearestChild`）。
  合成测试里 贝塔国 洞边 ≤3 km 的点因此归丙州，洞中心仍是国家直属。
- **港澳**：国家轮廓 = DataV 分区并集（NE 轮廓缺机场岛、路氹填海区）；单一一级行政区的国家（梵蒂冈、摩纳哥等）不建那一层。
- 调试工具：`Tools/regions_debug.py <bin> lat lon …` 列出数据里包含某点的全部环（不经裁决规则）。
- 已知未修：阿鲁巴首府点落在所有多边形外（CGAZ 自有的阿鲁巴多边形太粗，下次构建改用宗主国切出来的）；NE name_zh 夹带繁体字（下萊茵、日內瓦、戈里齊亞）；「佛罗伦斯省」应为佛罗伦萨；意/法/英一级粒度。

- **2026-10-25 法/意/西/英分组**：NE admin-1 对这四国给的是省/县级，按 `region`（意/法/西）与 `geonunit`（英）聚成大区作一级（意 20、法 13+5 海外、西 17+2、英 4），
  原省/县挂为二级（只有一个省的大区不建二级）；大区几何 = 成员省多边形并列（高亮按省画）。名称四语在 `GROUP_NAMES` 表里（zh-Hant 留空回退）。
  简体名清洗 `clean_zh`：繁→简字表（不含歧义字）、台湾译名表、全角连字符→半角。台湾国家名改「台湾」。地级名 `地区/特区/新区` 不去尾字。
  缝吸附改为两层：国家 → 最近一级 → 最近二级（威尼斯本岛 → 威尼斯省 < 威尼托）。
- **2026-10-25 晚决定**：地区归属与世界迷雾一致（香港、澳门单列为「国家/地区」，中国 31 省；台湾名为「台湾」）。已知不修：北塞浦路斯海岸 500 m 带归塞浦路斯（两套多边形海岸线不一致）、
  马祖缺连江县（NE 台湾一级只有 21 个）、圣马力诺城判到博尔戈马焦雷（NE 微型区划粗）。同一上级下重名的地区简体名加「（英文名）」区分。
