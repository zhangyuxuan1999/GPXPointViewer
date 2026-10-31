# ADR-2026-10-30：每日／行程摘要

**Status:** Accepted（2026-10-30主代理已验收，正在实施）  
**Date:** 2026-10-30  
**Deciders:** 用户授权范围内由主代理验收；架构请求模型为 GPT-6 Astra / ultra。请求参数不等于服务端模型证明。

## Context

首版交付每日列表、行程列表及距离、时长、爬升／下降、国家地区和交通方式。所有计算离线；不调用地理编码、路由、Overpass 或生成游记，不扩展项目持久化、隐私裁剪或多设备融合。摘要基于当前已落地的数据，草稿、预删除灰点和批次预览不算已修改数据。

当前源码约束（2026-10-30 只读核对）：

- `TrackData.swift` 的 `TrackTopology` 在同一源段内提供路径顺序；`order` 为空表示 identity。全局数组相邻点可能不相邻，`segmentID` 与 `fileID` 是不同维度。时间已稳定排序，有效时间在 `timedCount` 前缀；缺时间、海拔以 NaN 表示。每次 build 生成新 `TrackData.id`。
- `fileID` 是当前 `LoadedFile` 数组的 `UInt16` 下标，不能当持久文件身份；`LoadedFile.id` 是会话 UUID。重叠模式使用合并轨迹，对比模式有独立 `compareTracks`；`files[].parsed` 不是可直接复用的渲染／排序后拓扑。
- `Trip.km` 只累计 `dt <= 60 s` 且速度不超过 350 km/h 的边；`Trip.autoKind` 的低速分支也会把步行判成补点公路。`store.trips` 随补点候选刷新，普通摘要打开时可能根本没有它。摘要不依赖这些结果，也不用 `GapDetector.isBreakStep` 的 150 m／20 s 断档阈值。
- `GapFillExport.syntheticKeys` 包含改时观察点。真正新造坐标点必须逐条 `GapFill.points` 排除该条 `retimedKeys`；点键包含 time/lat/lon 的位值和 segment。数据本身没有持久逐点来源标记，重新导入外部 GPX 后无法识别其历史补点。
- `RegionIndex.Assigner` 支持离线逐点归属和父链；`RegionStatsBuilder.points` 是全轨迹点数报告，不能直接作为按日边长度或持续时间的计算器。
- `DataPublicationClock` 已有独立 lane、文档 revision、文件 UUID 列表与来源轨迹 UUID 校验。`TrackStore` 是唯一主线程发布者。
- 主地图有 `MapFocusRequest` 和 `[start,end)` 的 `viewFilter`；`TimeFilterSection` 的日期控件目前不响应外部任意秒级筛选。新入口必须显示真实正在生效的摘要筛选，不能让旧控件仍显示“全部”。

## Decision

采用独立、纯数据的 `JourneySummaryBuilder`，新增一个共享 Store 的摘要窗口。先按**一个选定文件**计算报告；来源下拉列出各文件，但不把两台设备的里程相加。默认选当前单文件；多文件选第一个仍存在的文件。源选择与图层显隐无关，并明确写“当前文件的全部记录”；摘要不随主地图 `viewFilter` 改变。

首版自动划分行程、允许每个行程人工选择交通方式。合并／拆分行程及 CSV 导出留待另行授权，不能把它们宣传为已实现；它们并非本次五项摘要字段的前提。

### 1. 时间与日期

- 窗口提供“本机时区／UTC／指定时区”。本机模式在发起计算时捕获 `TimeZone.current.identifier`；报告总是显示实际 IANA ID，不称为轨迹所在地时间。指定时区用已知 IANA ID 列表或校验后的输入，不接受静默回退。
- 用 Gregorian `Calendar` 设置该 `TimeZone`，通过 `dateInterval(of: .day, for:)` 获得自然日边界；下一日使用 calendar 运算，不加 86,400 秒。夏令时日允许 23／25 小时。
- 每条合格边按其跨越的午夜切分，距离、边时长和该边的滤波爬升贡献均按时间比例分配。这个比例是分配假设，不声称真实运动匀速。点在午夜时只计入后一天；边的前一段仍归前一天。
- 非有限时间，或日历不能表示的时间，记入 `undatedPointCount`，不塞进某一天。不为无时间点虚构持续时间、速度或日期；窗口提供“日期未知：N 点”说明。
- 不把长期空白展开成大量空日。只有含有效带日期点或合格边贡献的日期有行；两次记录相隔一周，不造出中间六天的“0 公里”。

### 2. 边、距离、断档与来源

`summary-v1` 固定规则：

| 参数 | 值与含义 |
|---|---|
| `maxContinuousSeconds` | 300 s；支持正常稀疏采样，超过后不凭一条直弦宣称已覆盖路线 |
| `maxPlausibleSpeedKmh` | 1200 km/h；保留航空量级，超过视为可疑跳点，不猜实际距离 |
| `journeyGapSeconds` | 1800 s；达到该记录空白时开始下一行程 |
| `movingThresholdMps` | 1 m/s；只用于“移动估计／低速间隔”，不是停留检测 |
| `elevationDeadbandMeters` | 3 m；下述滤波器的垂直迟滞阈值 |
| `minimumElevationCoverage` | 0.8；下述有效海拔边比例最低值 |

只处理拓扑上相邻、属于选定源文件及同一源段的边。经纬度必须有限且在有效范围，两个时间必须有效且严格递增，`dt <= 300`，haversine 速度 `<= 1200`。距离使用球面 haversine，地球半径固定 6,371,000 m，反三角输入 clamp；不使用 Mercator 长度或 `speedKmh` 反推距离。

满足条件的两个“记录位置”端点贡献 `recordedMeters`；任一端点是本会话合成位置，则整条边贡献 `estimatedMeters`，包含观察锚点接到第一个合成点的两侧边。改时点仍是记录位置：其相邻距离仍可计入 `recordedMeters`，但对应时间属于估算。合成身份优先于改时身份。同值重复点无法从现有集合中辨认原件，保守按已知估算标记；不能把不确定部分升级为原始观察。

两列都只是存储点的折线长度。`recordedMeters` 的界面名用“记录折线”，不称“真实路程”；稀疏采样会漏掉弯道，定位抖动也可能增大长度。合成列名“补点估算”。缺失路线不当作零路程：同时显示排除边数、未覆盖时间；没有合格边时显示“距离不可计算”，不是 0 km。真实重复坐标的有效零长度边可以显示 0。

不同源段绝不补连线。单个文件内若不同源段时间重叠，保留各段记录折线合计，同时展示“源段时间重叠，距离可能含重复记录”；不自动去重。不同文件始终独立报告，无跨文件总计、自动主记录选择或融合。

### 3. 时长：用区间并集而非逐边相加

每行 `startTime/endTime` 来自该行的有效点及切边贡献，`elapsedSeconds = end-start`。日行不是固定 24 小时，单点行跨度为 0，并明确显示“仅一个记录点”。

为一行收集半开边区间：

1. `O`：合格边、两端时间均未改写且均非合成。
2. `E`：合格边但至少一端为合成或改时。
3. `M`：`O` 中速度严格大于 1 m/s 的区间。

计算 `observedSeconds = |union(O)|`、`estimatedSeconds = |union(E) \\ union(O)|`、`movingSeconds = |union(M)|`、`lowMotionSeconds = observedSeconds-movingSeconds`、`unknownSeconds = max(0,elapsed-observed-estimated)`。重叠观察优先于估算；观察段间发生运动判定冲突时运动区间优先，但有源段重叠提示。UI 标“观测间隔／估算时间／未覆盖时间／移动估计／低速间隔”，不能把低速或记录空白称作确定停留。

`overlapSeconds` 是不同源段的记录跨度覆盖次数至少为二的时间并集，不将同一段的相邻边算重叠。每日时长不会因同一文件包含两条重叠段而超过跨度。各行程时长之和未必等于每日时长，这是并集语义的必然结果。未知时间边无法给出未知秒数，另保留无时间点及排除边计数。

未覆盖时间仅指本行首末贡献之间的空白，不包括日行第一点之前／最后点之后的整天时间。跨午夜但不连续的边不能产生合格切边贡献，因此两个日行不会把各自范围之外的夜间空白算进去；仍在同一行程内时，其完整空白可在行程跨度中看到。跨 30 分钟边界的空白不属于任一行程。界面帮助需明确这一范围，不把未知秒数称作“当天全部漏记时长”，也不声称日时长求和必然等于行程时长求和。

### 4. 自动行程边界

按选定文件的每一硬源段独立扫描路径顺序。段首开始行程；有效时间之间空白 `>= 1800 s` 开始下一行程；中间遇到无效时间，终止已知行程，随后有效点另起。有限时间相同或局部不递增的边不计距离／时长，保留点并登记排除，不能跨过去造新边。

不按午夜切断行程；一趟跨午夜行程仍一行。首版不自动猜“换乘”“回家”或从 GPS 半径推断长停；窗口说明“按源轨迹段和 30 分钟记录空白分段”。孤立带时间点也有一条行程，但距离、海拔和交通候选不可用。稳定 ID 包含 `trackID + sourceID + segment + firstPathRank`，只承诺同一数据版本稳定；编辑后身份更新，人工交通选择不能漂移到另一行程。

### 5. 爬升／下降与覆盖

只在合格的记录位置边上计算海拔，合成位置的插值海拔不参与；改时但位置／海拔仍为记录的点可以参与。每次硬段、无效时间／坐标、超过连续性规则、缺海拔或合成位置均断开滤波链，禁止跨断点做高度差。

每个连续有限海拔链先做五点滚动中位数，链首尾采用最近端点重复补满五点；该固定窗口是抑制孤立尖峰的规则，不宣称传感器校准。随后以第一滤波值为 anchor：新值与 anchor 差的绝对值达到 3 m 时，正差加爬升、负差绝对值加下降，并把 anchor 更新到新值；不足 3 m 的尾差丢弃。贡献归到触发更新的那条边，再依午夜比例分配。午夜不重置滤波器，避免每天改变算法；因此日计之和与行程计贡献守恒。

`elevationEligibleEdges` = 合格记录位置边数；`elevationCoveredEdges` = 其中两端海拔有限的边数。覆盖比例基于边数，UI 明示“海拔边覆盖率”，不称距离覆盖率。比例至少 80%、且至少两条海拔边时才对外发布爬升／下降，否则两个值为 nil。即使发布，也标“滤波估算”；不对缺失部分按比例外推。零爬升只表示已覆盖数据在该滤波规则下没有显著爬升。固定点数滤波会受采样率影响，3 m 以下起伏和狭窄山峰可能被抑制，这属于显式规则局限。

### 6. 国家／地区与交通方式

地区：每个有效坐标点使用本 worker 私有 `RegionIndex.Assigner` 查最细归属，再走父链。输出记录位置与合成位置各自命中的地区 ID，顺序按 ID 固定；UI 使用当前 `RegionIndex` 的本地化名，分别显示“记录位置到访”和“补点经过（估算）”。改时点的地理位置仍是记录证据，但其日归属受估算时间影响，整行有改时提示。不为跨境边猜越境位置、地区内里程或停留时长；没有落点的国家不推断为到访。未归属计数可见。索引缺失时整个地区字段不可用，而不是“0 个国家”。继承当前边界简化、海岸、既有同国内子级吸附等索引规则，不新增跨国吸附。

交通：GPX/CSV 当前未保留可作为摘要真值的活动类型。现有补点路型选择和地图证据既不覆盖所有行程也不一定同一边界，首版不移植它们。人工模式选择为 `unknown/walking/cycling/road/rail/air/water`，界面标“手动指定”；未知也是合法选择，另有“恢复自动候选”。只存本会话、当前 trackID 下的选择。

自动候选始终带“仅按速度，未确认”，不输出伪概率。只使用 `O` 中的移动边；有效移动观测时间至少 120 s 且至少 5 条移动边才给候选。按这些边时长加权，统计速度带占比：若至少 90% 时间 `<=12 km/h`，候选为步行／骑行；否则若至少 90% 时间 `<=45 km/h`，候选为骑行／公路／铁路；否则候选为公路／铁路／航空。它们只是常见候选，不是穷举（船舶等也可能同速）；界面不得自动选中其中一个。没有足够证据就是未知。合成／改时速度不参与候选，以免“按匀速插值”又证明交通方式。

日行交通展示当天重叠行程的模式集合：已人工指定的标手动，其余保留候选／未知；不生成唯一的全天交通方式，不按这些候选分配精确里程。模式编辑只改变展示，不重跑百万点统计。

### 7. `.fwdb` 与缺少数据

`.fwdb` 页面显示“存档没有逐点真实时间和连续路线，无法计算每日／行程摘要”，可链接现有地区迷雾统计。禁止从区块 mtime 生成日期、距离、持续时间、爬升、交通方式或首次到访。没有 GPX 数据、正在载入、没有时间点、区域索引不可用、计算失败／取消须有不同状态；取消不可发布空报告当成功。

## 精确 Swift 接口：两个实现任务共同遵守

以下类型放在新文件 `GPXPointViewer/JourneySummary.swift`，仅依赖 Foundation 和已有 Foundation-only `RegionIndex`；不引用 SwiftUI、TrackStore、TrackData、GapFill、CLLocation、网络或文件系统。类型均为应用模块 internal（这里“公开契约”指模块之间，不要求 Swift `public`）。所有结果字段用 `let`，集合不暴露可变共享引用。允许增加私有 helper，不自行改名或改变字段语义。

```swift
import Foundation

struct SummaryPointKey: Hashable, Sendable {
    let timeBits: UInt64
    let latBits: UInt64
    let lonBits: UInt64
    let segment: UInt32
    init(time: Double, lat: Double, lon: Double, segment: UInt32)
}
struct SummarySegment: Sendable {
    let id: UInt32
    let pathRange: Range<Int>       // indexes into pathOrder; identity if empty
}
struct SummaryInput: Sendable {
    let sourceID: UUID
    let trackID: UUID
    let sourceName: String
    let timeZoneIdentifier: String
    let lat: [Double]
    let lon: [Double]
    let elevation: [Double]
    let time: [Double]
    let fileID: [UInt16]            // empty means implicit file zero
    let selectedFileID: UInt16?     // nil means all points in this snapshot
    let pathOrder: [UInt32]         // empty means identity
    let segments: [SummarySegment]
    let syntheticKeys: Set<SummaryPointKey>
    let retimedKeys: Set<SummaryPointKey>
}
struct SummaryBounds: Equatable, Sendable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
    // UI skips camera flight if maxLon-minLon > 180; time selection still works.
}
struct SummaryMetrics: Equatable, Sendable {
    let pointCount: Int
    let syntheticPointCount: Int
    let retimedPointCount: Int      // excludes points already counted synthetic
    let acceptedEdgeCount: Int
    let excludedEdgeCount: Int
    let recordedMeters: Double
    let estimatedMeters: Double
    let elapsedSeconds: Double
    let observedSeconds: Double
    let estimatedSeconds: Double
    let movingSeconds: Double
    let lowMotionSeconds: Double
    let unknownSeconds: Double
    let overlapSeconds: Double
    let elevationEligibleEdges: Int
    let elevationCoveredEdges: Int
    let ascentMeters: Double?
    let descentMeters: Double?
}
struct SummaryGeography: Equatable, Sendable {
    let available: Bool
    let recordedRegionIDs: [UInt16] // unique, sorted; includes ancestor IDs
    let estimatedRegionIDs: [UInt16]
    let unassignedRecordedPoints: Int
    let unassignedSyntheticPoints: Int
}
enum SummaryTransportMode: String, CaseIterable, Sendable {
    case unknown, walking, cycling, road, rail, air, water
}
struct SummaryTransportEvidence: Equatable, Sendable {
    let candidates: [SummaryTransportMode] // empty = insufficient evidence
    let observedMovingSeconds: Double
    let observedMovingEdgeCount: Int
}
enum SummaryRowKind: String, Sendable { case day, journey }
struct SummaryRow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: SummaryRowKind
    let sourceID: UUID
    let segment: UInt32?           // only journey rows
    let firstPathRank: Int?        // only journey rows
    let startTime: Double          // actual first contribution, Unix seconds
    let endTime: Double            // actual last contribution, inclusive instant
    let dayStart: Double?          // natural day [dayStart,dayEnd); nil for journey
    let dayEnd: Double?
    let bounds: SummaryBounds?
    let metrics: SummaryMetrics
    let geography: SummaryGeography
    let transport: SummaryTransportEvidence
    // Day filter: [dayStart,dayEnd). Journey filter: [startTime,endTime.nextUp).
}
struct SummaryReport: Sendable {
    let sourceID: UUID
    let trackID: UUID
    let sourceName: String
    let timeZoneIdentifier: String
    let ruleVersion: String        // exactly JourneySummaryBuilder.ruleVersion
    let totalPointCount: Int
    let undatedPointCount: Int
    let invalidCoordinatePointCount: Int
    let days: [SummaryRow]          // chronological; ID tie break
    let journeys: [SummaryRow]      // startTime, segment, firstPathRank order
}
enum SummaryBuildError: Error {
    case invalidInput(String)
    case invalidTimeZone(String)
    case cancelled
}
enum JourneySummaryBuilder {
    static let ruleVersion = "summary-v1"
    static func build(
        _ input: SummaryInput,
        regionIndex: RegionIndex?,
        isCancelled: () -> Bool = { false }
    ) throws -> SummaryReport
}
```

`SummaryPointKey.init` 直接取三项 `Double.bitPattern`。输入等长列／可选 `fileID` 长度、pathOrder 长度和索引范围、segment 区间覆盖与合法时区需在后台校验，错误不能 trap；无需为可信 Store 的拓扑额外构造一个百万项 Set 来检测每个排列重复。输入不符合完整拓扑合约时返回 `.invalidInput`。`selectedFileID` 的 nil 与 0 含义不同：前者不筛列，后者选择隐式／显式源零。

`SummaryRowKind` 和 `SummaryTransportMode` 增加 `Equatable` 或 `Hashable` 的显式声明可按编译器需要；不改变原始值。Builder 每最多 4096 点／边以及地区遍历、排序前后检查取消，抛 `.cancelled`；不能返回部分报告。DateFormatter 不放在核心循环，结果不存本地化字符串。

计数分配：点按其真实／估算 timestamp 所在日期及自身行程各计一次；边贡献归两端所在的同一行程（30 min 断开边本来已超出 300 s，不参与距离）。跨午夜边的 `acceptedEdgeCount` 在受影响的每个日行各计一次，距离／时间分摊；因此边计数不是跨日可加的唯一边数量。排除边归有效后端所在日与后端所属行程一次；如果两端都无日期只反映在报告的无日期点计数。海拔 eligible/covered 在边触及的日行各计一次，覆盖比例不按午夜比例变成分数边。

### Store／UI 接口与发布流程

Store 集成任务增加以下成员，命名固定，私有实现可调整。`SummaryTimeZoneChoice` 与 `SummaryFilterSelection` 在新 `JourneySummaryState.swift` 中定义，核心引擎不依赖它们。

```swift
enum SummaryTimeZoneChoice: Equatable {
    case system, utc, named(String)
}
struct SummaryFilterSelection: Equatable {
    let trackID: UUID
    let sourceID: UUID
    let rowID: String
    let start: Double
    let end: Double
    let timeZoneIdentifier: String
}
// TrackStore (@MainActor):
@Published var summaryWindowOpen = false
@Published private(set) var summarySourceID: UUID?
@Published private(set) var summaryTimeZoneChoice: SummaryTimeZoneChoice = .system
@Published private(set) var summaryReport: SummaryReport?
@Published private(set) var summaryBusy = false
@Published private(set) var summaryError: String?
@Published private(set) var summaryTransportOverrides: [String: SummaryTransportMode] = [:]
@Published private(set) var summaryFilterSelection: SummaryFilterSelection?
func ensureSummaryReport()
func pickSummarySource(_ id: UUID)
func pickSummaryTimeZone(_ choice: SummaryTimeZoneChoice)
func setSummaryTransport(_ mode: SummaryTransportMode?, journeyID: String)
func showSummaryOnMainMap(_ rowID: String)
func clearSummaryMapFilter()
private func invalidateSummaryReport()
```

1. **选输入：** 单文件用 `track`；overlay 用当前合并 `track` 和文件下标；compare 必须用 `compareTracks[index]` 且 `selectedFileID=nil`，不能用可能属于旧显示模式的 `store.track`。`isLoading` 或 compareTracks 尚未就绪时等待。没有 LoadedFile 的压测轨迹可以 `track.id` 作 sourceID。来源行名附同名文件的序号，ID 仍是 UUID。
2. **快照：** 主线程只复制数组值／CoW 引用和少量 segment ranges，不扫描所有点、不重新构建 TrackData、不复制成逐点 class。把必要 `fills` 的值快照交 worker，worker 才构造两种 SummaryPointKey 集合；摘要任务不能访问 Store。仅当前单文件且来源版本可对齐时传 fills；其他模式无可靠历史时为空，统一提示“补点来源仅在本次编辑会话可识别”。
3. **缓存键：** 文档 revision + 显示模式 + 所选 LoadedFile UUID + 实际输入 TrackData.id + 解析后的时区 ID + `summary-v1` + 本会话 provenance revision + RegionIndex 对象身份／无索引。不要只用 `fills.count`；撤销或等长替换也必须失效。主地图时间筛选、颜色、相机、鼠标、地区名称语言不在计算键里。
4. **归属：** `PublicationLane` 新增 `.summary`；发起时 `publicationClock.begin(.summary, fileIDs: files.map(\.id), sourceID: track?.id)`。该 token 中 sourceID 校验的是主 Store 的显示数据归属；另捕获实际 summary input TrackData.id（compare 时尤其不同）、完整缓存键和独立 request UUID。发布经现有 `publishData`／`owns` 机制，随后再次核验所选源、输入轨迹 ID、key 和 request。不要为了让跨文件 extension 访问而公开整个 clock。
5. **取消与失效：** `invalidateDataOperations()` 同步撤下旧报告、取消 `.summary` 和 Task、递增请求代，不等窗口 onChange。源或时区变化同样撤下旧报告；新数据发布完成／compareTracks 就绪后，只有窗口开着才 ensure。关闭窗口取消在途任务，已完成当前报告可保留。数据、fills 来源或清空变化必须失效；主线程在整次编辑落地后安排 ensure，避免先捕获新轨迹配旧 fills。旧成功和旧失败回调都不能改新报告／busy。
6. **有界缓存：** 首版只保留当前已完成报告和一个在途输入，不要求多源多时区 LRU。重开同源同版本直接复用；反复切源可能重算，但不会保存每个源的百万点副本。取消后的旧 worker 仍按检查点尽快退出，不人为声称立即释放所有旧数组。
7. **人工模式：** `setSummaryTransport(nil,...)` 清人工覆盖；其他 enum 包括 unknown 是显式人工指定。只允许当前报告已有的 journey ID。同源仅换时区时 journey ID 不变，可保留；换 trackID、删除来源或清空时删除覆盖。自动候选仍保留作依据，不反向改补点路型。
8. **地图和精确时间：** 明确按钮“在主地图上查看”；首版只在 single 且主 trackID 与报告相符、无删除事务／补点／批次预览／回放时启用。overlay／compare 保留摘要浏览，按钮给出不支持原因，不悄悄切模式。设置 `summaryFilterSelection`、`viewFilter` 和 `viewFilterSpec=nil`；日行使用完整自然日，行程尾时刻用 nextUp 保留最后点。对有限且经度跨度 <=180° 的 bounds 请求地图相机，最小800m；跨日界线的宽 bounds 只筛时间、不错误飞到半个地球外。摘要不以自身筛选作为新输入。
9. **筛选 UI 一致：** `TimeFilterSection` 在 summaryFilterSelection 存在时显示专用块：准确开始／结束及摘要时区、来源和“清除摘要筛选”，暂时隐藏原日期模式控件；initSpan/onAppear 不得覆盖此范围。清除后恢复完整记录和原“全部”模式。其他显式设置 viewFilter 的入口须撤下不再匹配的摘要标记；数据换代立即清掉。`viewFilterSpec` 不能装作日期范围精确等价于秒级 journey；现有导出默认行为保持，并且不宣称摘要支持新的导出功能。

窗口 `SceneID.journeySummary = "journeySummary"`，用 app 现有共享 Store。顶栏来源／时区／每日-行程切换；列表按日期分组可用 `List`，详情显示上述指标、覆盖与限制。长国家名、德文文案可换行，不用巨大固定宽卡片；建议最小 780×560，默认 1000×700。行点击只选择详情，不隐式改变主地图；地图按钮才改变筛选。先正常展示未知／不可用，不把每个字段缺失都升级成 alert。

## Options Considered

| 方案 | 复杂度／成本 | 百万点扩展 | 结论 |
|---|---|---|---|
| 直接复用 Trip 和 RegionReport | 最低，但当前边与路型口径不同 | 可能重复扫描，且普通模式缺 Trip | 拒绝；会把正常稀疏距离遗漏、把步行当公路 |
| 独立不可变摘要引擎＋Store 适配 | 中等；新增核心和窗口，小范围接线 | CoW 输入、按需后台扫描、有限缓存 | 采用；数据语义可定向验证，依赖清晰 |
| 全量活动模型、融合设备、可编辑日历旅程数据库 | 高；需要身份、冲突和持久化设计 | 可扩展，但首版复杂度与风险明显增大 | 本轮不做；无必要先大拆 TrackStore |

## Trade-off Analysis 与规模约束

按来源分别选择牺牲“一眼全部总数”，换取不重复计算设备里程的正确默认。固定 5 分钟连续性和 30 分钟旅程阈值均是可见版本化规则，不是所有记录设备的真理；未来若开放设置，设置必须进入缓存键并另做边界验证。自动候选保留不确定性，人工修正可给用户明确模式而不触发外部查询。

循环只读取现有 SoA 与 topology order，不生成新的渲染 track，不把每个点存成带字符串的对象。地区 Assigner 每 worker 一个，点归属一次后同时写其日和行程集合；父链层数有界。日界缓存每个 calendar day 一次，正常顺序下不对每点调用日期格式化。距离／海拔按段流式累加，五点中位数仅有固定窗口。

时间区间先在每段、每分类内合并相邻区间，再对每行的合并片段排序求并集及 O/E 差集；总复杂度 `O(N + R log R)`，R 为合并后的覆盖片段数，最坏可达 O(N)。可用扫描线处理源段跨度重叠；不能用所有点的两两比较或逐日重扫整个轨迹。输出内存为日／行程行、地区集合及压缩片段，工作区最坏 O(N)，正常长连续单段接近 O(行数+地区数)。无需预存 N 个 CLLocation 或每条边的富对象。百万点表现必须测量，不在设计里承诺具体毫秒或峰值。

## 两个并行 Sol 实现任务的文件所有权

**A：核心引擎与数值验证（GPT-6.1 Sol / ultra）**

- 独占新增 `GPXPointViewer/JourneySummary.swift`；拥有上述所有核心类型和 Builder，按契约供 B 消费。
- 独占新增 `Tests/summary/core/`（生产核心 Swift 的离线编译入口、main.swift、README、确定性夹具）。可直接编译已有 RegionIndex，不改它或 RegionStats；探针不能抄一份生产算法当真值。
- 不碰 TrackStore、UI、工程文件、翻译和现有测试期待值。先落核心类型骨架，再继续算法，尽早告知 B 接口可用。

**B：应用／状态／UI（GPT-6.1 Sol / ultra）**

- 独占新增 `GPXPointViewer/JourneySummaryState.swift`、`GPXPointViewer/JourneySummaryWindow.swift`。
- 有限修改 `TrackStore.swift`、`ChangeLog.swift`（仅新增 lane）、`GPXPointViewerApp.swift`、`ContentView.swift`、`ExportSheet.swift`（摘要筛选显示／清除）、`UITestHook.swift`、`GPXPointViewer.xcodeproj/project.pbxproj`。
- 工程只给 app 主 target 加三个新 Swift 文件，不无故加入 Quick Look／缩略图扩展。TrackStore 必需的私有发布接线放同文件，较大纯适配 helper 放新 State 文件；不重构无关 workflow。
- 新增唯一 `Tests/l10n/translations/chunk_<next>.json` 并按 RULES 组装 catalog；当前 next 编号先现场检查，不覆盖他人 chunk。拥有新增 `Tests/ui/run_summary_tests.py` 及需用的摘要状态钩子。README／Tests README 的最小使用说明也由 B 更新，或在主代理整合时更新，但不得两人同时写。
- 核心公共类型只能由 A 改；遇到契约缺口先与主代理／A 协调，不能在 UI 内再定义同名结构或偷偷改数值算法。

**主代理：** 整合、关键结论验收、指定归档构建与最后像素判断；默认验收两名代理原始证据，不重复其已通过测试。任何定向补测必须先记录具体新缺口或修复点。架构代理本轮只写本设计和自己的调用记录，没有产品代码／构建／测试／网络执行。

## Meaningful directed validation

以下是新行为的计划，不是已执行通过的结果。A 先记录新功能缺少证据及准确输入版本，再跑核心；B/主代理记录各自 UI/异步缺口。原始失败和修复后新结果分开保存，不覆盖旧记录。

| 组 | 最小独立真值与断言 | 责任 |
|---|---|---|
| 数值／拓扑 | 赤道沿经线／赤道的已知小角度距离（由 `R*角度` 独立真值）；两段时间交错 A0 B0 A1 B1，无跨段边；同文件两段重叠时 span/coverage并集不翻倍，距离重叠警示可见；两个文件选择互不相加 | A，主代理审查真值 |
| 稀疏／边界 | 120 s 的正常稀疏边保留；300 s 计、300 s+ε 不计；1800 s 分旅程；1200 km/h边界；重复时刻／无时间／坏坐标／孤点不可造边；排除和不可用状态一致 | A |
| 日期 | UTC 午夜对半边的距离与时长守恒；Europe/Berlin 的 2026-03-29（23h）与2026-10-25（25h）calendar边界；午夜点只在后日、不同 IANA 选择改变日桶不改变行程总距离；跨午夜旅程不拆；长空白不造空日 | A |
| 来源／补点 | 观察锚点→合成→观察完整三边估算归类；retimed只影响估算时间、保留记录位置距离；同位值另一segment不误标；导入无历史时不假称合成数有完整追溯 | A＋B 适配 |
| 时间 | O/E重叠、E\O优先关系与unknown守恒；移动/低速边界；不跨源段补时长；段重叠与长空白分开；单点0跨度有不可用说明 | A |
| 海拔 | 长平台＋已知台阶得到确定升降；小于3m抖动不累积；单点高度尖峰被median5抑制；NaN／合成／断档分链；覆盖80%边界、少于两条海拔边不可用；午夜不改变滤波总贡献 | A |
| 地区／交通 | 复用小合成 RegionIndex，点父链／未归属／索引缺失；合成点经过不得变记录到访；不足120s或5移动边未知；同一速度不能自动确认road/rail；手选模式与恢复自动正确 | A＋B |
| 异步归属 | 挂住摘要 A，切源／换时区／编辑／清空后允许 B发布，再释放 A，成功与错误均不能覆盖B或busy；compare实际TrackData来源ID正确；关闭窗口取消；同key重开无第二次build；viewFilter/颜色/相机不触发重算 | B，在生产Store测试门／计数钩子上验 |
| 实际 UI | 指定新归档 GPXPV_APP；本地小夹具打开单文件／overlay／compare／fwdb状态；日与旅程切换、模式手选、准确日期、地图按钮和尾点包含；专用时间筛选chip与清除一致；编辑后摘要更新；网络请求计数无因摘要增长 | B／主代理，离线 |
| 多语言像素 | zh-Hans/en/de 的摘要窗口小尺寸，含长地区名、缺海拔、时间未知和候选说明；检查换行／截断／可点击；zh-Hant通过资源组装与键检查，发现布局特殊问题才补像素 | 主代理最终判断，可委派截图 |
| 规模 | 新引擎100万点连续单段＋多段重叠样本，记录真实墙钟／峰值或可用内存指标、取消完成时间、输入SHA；目标是无主线程全量循环与无每帧重建，不杜撰未定的FPS阈值 | A/B 分清引擎与UI证据 |

只触及新摘要模块与接线，不要求全套路由／补点在线回归。主 target 需要一次带输入归属的 Release 构建；未改 RegionIndex/RegionStats 不为摘要重复整个地区探针。若新增 lane 导致相关测试编译依赖，运行受影响的既有发布归属小探针，事前注明原因。正式 `/Applications` 安装不在本次授权内；UI 使用专门归档测试副本且恢复共用偏好。

## Consequences 与行动项

摘要有独立解释规则和原始／估算证据边界，普通查看不会启动补点网络工作。代价是无法从现有导入格式恢复外部补点来源，也不自动融合设备或确认交通方式；这些限制直接展示给用户。

1. 主代理验收本契约并将 A/B 文件边界写入各自完整 task。
2. A 先交付类型骨架，B 按同一接口接入；数值与状态各自保存原始证据。
3. 主代理整合构建、定向 UI 与像素验收，记录未完成项；本设计中的计划不得当作通过记录。
