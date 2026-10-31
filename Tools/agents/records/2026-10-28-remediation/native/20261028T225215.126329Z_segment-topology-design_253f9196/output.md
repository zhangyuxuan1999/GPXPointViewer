# P4 显式分段与交叠拓扑：最终实施设计

设计完成，产品实现和真实测试尚未执行。Astra Ultra；记录跨当地2026-10-28/29。本报告以当前源码、前轮设计及主代理followup-01/02/03为准，替代前轮“交叠段保守全断线可作为本轮范围”的建议。

## 1. 已确定语义

1. **保留现有按时间规范化语义。** 四列仍全局按time排序、缺时间排尾；同时间稳定保留输入序。每个显式段内也按这套规范化顺序连接。完整拓扑指在此语义内不跨段、交叠段不丢边、LOD/检测/编辑/导出一致。不承诺原始GPX/XML节点顺序和扩展字段往返；不新增原文顺序pathOrder。
2. **不引入跨编辑稳定pointID。** 所有当前轨迹的候选/段内下标随TrackData.id换代失效并重建；R1保留COW基线+完整位键多重集方案。段标签是当前编辑会话的来源语义，并非持久点身份。
3. **CSV保持单文件平面点表。** 不新增多文件CSV导出UI，不承诺CSV保留trkseg；但CSV的速度、距离、航向必须用本段前驱。GPX及内部拓扑必须完整修复。
4. **A0 B0 A1 B1必须产生A0→A1和B0→B1。** 不产生A0→B0/B0→A1，也不能全部断开。该断言同时约束line、fog、CPU解锁格、速度距离、缺口检测及GPX。

## 2. 最小数据契约：保留时间SoA，增加段内索引视图

### ParsedTrack与解析

新增`segmentID: [UInt32]`。空表示一个隐式段；非空必须等于count，不能半长数组。每个GPX trkseg独立、每个rte独立、不同trk不合并；wpt是孤立点（每点独立段）；CSV一个文件一个隐式段。容忍无trkseg的旧GPX时可把同一trk内的连续trkpt当一个隐式段，但不得跨trk。标签不要求在会话外保持数值。

`parse` / `parseMany` / `slice` / `mergeParsed` / 坏点compact必须保留此列。merge为不同输入文件重编号，本地都为0的两个段不可碰撞；普通编辑/重新build保留标签，不随点数变化随意改写，以便R1记录仍可比对。同一个文件再次作为新输入导入时由新会话重编号即可。

并行字节parser使用一次结构扫描得到按字节offset有序的容器边界表，供各chunk由point起始offset取段标签。结构扫描必须跳过注释、CDATA、属性引号里的伪标签；chunk首点可以落在一个早先打开的段内。若修改token识别，count与parse必须共享判定，避免预分配点数与实际写入失配。不为每个chunk从文首重扫。CSV快路不变。扫描/压紧两阶段都用有效写入数同步段列。

### TrackTopology（建议新建TrackTopology.swift，纯Swift/Foundation）

`TrackData`增加不可变`topology`：

- `order: [UInt32]`：按segment聚合的全局时间下标；每段内部递增。
- `rank: [UInt32]`：inverse，给全局下标找order位置。
- `segments: [SegmentRange]`：segment标签及order坐标中的半开range，可直接索引/字典查找。
- `lineRuns: [Range<Int>]`、`fogRuns: [Range<Int>]`：每个segment按各自原有时间/距离阈值进一步切出的连续段。显式边界永不合并，软断点口径不擅改。
- 单段且order为identity时可省略order/rank实际数组，通过helper回退i→i；保留既有向量化/渲染快路。

构建：统计段计数→前缀offset→按全局时间序稳定scatter，O(n+段数)，不需要每段重新排序；大文件不做每个段扫描全部点的O(n×段数)。构建topology发生在全局排序之后、并行派生阶段之前。新列在全局vDSP排序和多路归并/块复制两条路径都必须搬运；同时间排序要显式稳定，不能假设vDSP索引排序稳定。

固定公共helpers：

```
segment(of globalIndex) -> UInt32
pathRank(of globalIndex) -> Int
globalIndex(atPathRank) -> Int
adjacent(to globalIndex, direction, steps=1) -> Int? // 限当前segment
indices(between a, b, includeEnds=false) -> 段内索引视图 // 不同段返回失败
innerCount(a,b) -> Int?
makeDrawRuns(kind, globalTimeRange, stride) -> PathDrawPlan
```

建议`indices`返回ArraySlice/自定义只读view，避免每个UI计数分配数组。所有“前后k个点”“区间内点数”均在path rank域计算。global index只负责坐标引用/拾取。此处的`order`是规范化段内索引，不是原始XML顺序。

## 3. line/fog/LOD完整渲染：紧凑draw-run，而非全断线

当前`segmentVertex:209–210`和`fogSegVertex:841`直接i+stride；全局breakPrefix无法表示A与B交叠后各自连续的边。不能只增加segment相等检查。

### DrawRun布局与公式

新增16字节GPU描述符：

```
PathDrawRun { begin: UInt32, end: UInt32,
              firstInstance: UInt32, instanceCount: UInt32 }
```

begin/end是topology.order坐标。各lineRuns/fogRuns先与全局时间range相交：段内order下标递增，可对global start/end分别二分，因此截取后仍是一个连续子range。不同文件显隐可继续在shader按fileID过滤，不改变段内连接。

L=end-begin，s=max(1,stride)：

- line：L>1时count=ceil((L-1)/s)，否则0。
- fog：L>1时同上；L==1时count=1，画自身圆；L==0不提交。
- firstInstance为前面描述符count的前缀和。

shader以iid二分找到描述符，j=iid-firstInstance；
`p0=begin+min(j*s,L-1)`，`p1=begin+min((j+1)*s,L-1)`；
`i0=order[p0]`、`i1=order[p1]`，用原时间序坐标buffer取值。

一个draw可提交全部runs；不为每个segment发一个draw call，不每帧生成O(n)端点数组。描述符仅在trackID、时间range、stride或pass改变时重建，通常O(run数×log段长)，镜头平移无需重建。line/fog用各自runs/stride。最后不足stride的尾边必须保留；单点fog必须保留。箭头朝规范化的时间方向；密度可按run内j重复，不能用串到下个segment的尾边。

**例子：** 全局[A0,B0,A1,B1]，order=[0,2,1,3]，两个range=[0,2)、[2,4)。stride=1、2、100都产生(0,2)和(1,3)。过滤global[1,4)时line只剩(1,3)，fog还有(2,2)孤点；绝不能把A1接到B0。

### 视口裁剪、缓冲与快路

新路径不要再用“可见点的Morton范围”直接决定线段集合：两端都在视口外的线也可能穿过视口。最小实现提交缓存的draw runs，shader以边AABB与扩展视口相交裁剪；fog按半径扩展，line按线宽/箭头扩展。当前fog的“两个端点max(abs)>1.6”判断也不能当成正确线段裁剪。

点云/热力图仍用已有Morton/去重LOD；它们是点消费，不需要拓扑重写。line/fog若后续量化需要空间加速，可为edge/run建bbox索引；这不是正确性前提。不能为省事关闭交叠段路径。single identity路径保留，但端点/过滤结果须与新公式等价，特别检查n=5、stride=3不能漏3→4。

GPU新增order/drawRun buffer及小uniform；Swift/Metal布局使用size/stride断言。缓冲发布按R3不可变版本方式，GPU完成前不可复用。MetalPointRenderer.setData/clearData更新拓扑缓存；截图及视频调用同一render入口，因此自然复用相同路径，不能只改屏幕分支。Globe源码只画点，不额外添加地球轨迹线。

## 4. 速度、长度与CPU迷雾必须用同一段内邻接

- `TrackData.buildStageSpeed:696`单段继续现有GeoCompute快路；多段按order gather/按段向量化并scatter回时间序speedKmh，或使用rank前驱表计算。段首遵循“该段单独加载”的现有口径（如复制本段第二点速度），绝不复制别段速度。缺/重复时间沿用现有零速度规则。
- `TrackData.buildStageProjection:630–658`总长度、典型段长、break统计都改为段内相邻边。当前总长度语义是否计入同段大gap保持原口径，不借P4改统计定义；只去掉跨段假边。
- `lineRuns`沿每段按原line阈值切分；`fogRuns`沿每段按原fog阈值切分；阈值分别是原代码的30min/10km与10min/100m，不合并成一个新阈值。
- `fogUnlockKeys:1037–1054`改为“每点自身格 + 每个fogRun内的实际相邻边DDA”。不能继续全局i→i+1，也不能只清交叠段的孤点。CPU统计用stride=1真实邻接，不使用显示LOD捷径。
- `computeFogStats`和`TrackStore:496`地区统计都消费fogUnlockKeys，修正后使用同一真源；无需改地区多边形算法或fwdb格式。

## 5. 缺口/批次/编辑：必须消除全局区间假设

### 最小算法复用方式

不要为每个segment调用TrackData.build（会重复构造Metal和空间索引）。引入纯数据`SegmentSamples`/轻量采样协议，只有四列、speed、count/timedCount和local→global映射。多段背景检测逐段构造/消费，内部现有循环继续使用连续local index；单段直接借用既有数组。内部函数可以改为泛型/协议输入，公共wrapper负责一次段选择与结果映射。

`GapDetector.detect/replayFlags/detectJitter/shiftFrozenChains`、`SamplingProfile`的步时步长统计、`TripSegmenter.trips/samplePoints`必须只看同段邻接。段末不与下一段作为gap，两个来源的同值点也不能互相判回放。缺时间点不进入候选扫描。

公共`GapRouteInputs`入口和StaleRetime需要为全局锚点取得同段view，把local输出一次映射回global。返回的trace.indices、heading/context索引、retimed.index、keep集合均是当前TrackData全局索引；shiftA/B、frozenA仍表示**段内步数**，调用方不得直接globalIndex±shift。使用topology.adjacent。局部view至少以trackID+segment缓存/复用，不能每个12点上下文调用复制整段。

### 候选身份

`GapCandidate.id: Double { tA }`（GapFill:56）、`BatchItem.id`及多处[Double:...]在交叠同起时会碰撞。改为
`GapID(trackID: UUID, segment: UInt32, a: Int, b: Int)`。

它只在当前track有效；换代清缓存/批次符合现有逻辑。不要求跨编辑稳定ID。候选保留global indexA/B，增加segment，innerCount改按段内rank求差。Equatable不能只比tA/tB。以下消费者必须统一：

- TrackStore classifyCache、gapSampling、CandidateComputation.sampling、mergeChains的nature、previewIDs、batchRefetchTasks；所有按c.tA取状态的位置；batch selection/set/refetch函数参数。
- ChangeLog.previewItemID；BatchFillWindow选择集合；ChangeReviewWindow；ContentView.gapSampling；PointMapView.batchMapPointCache。
- UITestHook保持“按列表序号选项”的现有可用操作；若输出id，新字段可序列化为结构/字符串，但不得在内部又用Double截掉segment。

Trip.range改为`segment + pathRange`。`TrackStore.trip(for:)`目前在全局range二分（:1399–1407），交叠时区间相交，必须改为同segment内按rank查找；trip.index仍可当前计算结果唯一编号，相关覆盖/地图证据随track换代清除。

### 补点与删除的精确影响集

`GapSplice.Job`增加segment；中心helper给出同段anchors、inner成员、keep子集、removed成员和新增点所属段。先验证所有job：同段锚点、当前版本、rankA<rankB、keep合法、同段jobs不重叠。无效不能静默continue后声称整批完成；返回明确失败/跳过原因由上层处理。

实现建议：按segment/rank验证并构建全局删除mask及带segment的新增点；遍历当前时间序原点，只删除mask命中；合并新点后由build稳定规范化。同一global时间区间内的其它segment原点必须原样保留。新点/改时点继承该job段标签。

`landBatch:4032`和`batchPreviewChanges`的单一lastB改为`lastBBySegment`（记录path rank）。不同段时间交叠合法；同段外推才受前一job锚点限制。`landingJob:4081`的index±shift、`:4089/4094`的ib-ia计数全改成段内helpers。

下列调用点必须一起改，不能只修GapSplice：

- TrackStore.seededVertices(:1759)、localMovingStep(:1843)、last step时长(:1698)、isStaleAnchor/自动外推检查(:1998/2004)。
- GapRouteInputs所有向外步进、monotonicChain、StaleRetime.plan/landingPoints。
- TrackStore.performFills记录removed(:2676–2679)、makePreviewChange(:2812–2813)、originalInnerCount/keptInnerPoints、批量直线补(:2583)。
- 预览颜色/计数与实际落地必须共用job membership，不能把夹在时间序中的B段预览成A段待删点。

普通圈选删除按global index精确删点即可，但复制segment列；填补/删除/撤销/还原/会话基线所有ParsedTrack构造点都复制segment元数据。ChangePoint增加segment，R1完整位键含segment（同值不同段不可互相替换）。added记录可由job.segment赋值；removed从当前点取。审阅额外历史点保持段标签，显示颜色仍fileID类别，不能混用。

## 6. GPX与CSV导出、Quick Look

### GPX

`GPXWriter.write(indices:)`目前直接segments:[indices]（:29），应将选中点按真实source segment分组并在该段规范化顺序写出；A0B0A1B1输出两个trkseg。显式segments overload的外层分组（每处fill）也不能跨source segment：每个外层组再按segment分组，且不能跨外层组重新合并。未选择的点遵循现有选择导出口径，可在同段内连剩余选点；P4不改变圈选导出的产品语义。

`GapFill`保存segment；`GapFillExport.mergedWindows`按segment分组再合并时间窗；`fogOfWorldGPX`筛点同时检查segment和点键，输出一个fill/source段一组，不能把另段同time/lat/lon点吸入。增量导出`TrackStore:4172`同样按fill所属段匹配。锚点必须本段，保留已有“世界迷雾导出带锚点”的行为。

### CSV

按主代理明确范围保留现有单文件API和UI。它是时间排序的平面点表，无法携带trkseg，文档不称拓扑无损。`stepLifeCSV`/`stepLifeCSVWholeTrack:1785/1804`的前一点改成topology.previous；段首按0处理。现有同秒只留一个规则保留并测试，不趁本轮变更格式或导入语义。

### QuickLook/Thumbnail不能遗漏

实际源码会画折线：GPXQuickLook/TrackShape:21/112；预览完整解析和>32MB采样分支都只传lat/lon；缩略图也调用SampleScan。因此core流负责：

- SampleScan增加segmentID，按采样点offset归属段；仅采样到部分段是预览已有降采样边界，但不能把两个被保留点跨段连线。
- PreviewViewController.full/sample两个分支、buildUI、GPXTrackShapeView都传segment。
- GPXTrackShape按段独立抽稀，段尾补齐、段边界断笔；阈值跳跃仍是段内的额外断开，不能覆盖显式边界。
- ThumbnailProvider传相同字段。保持预览采样内存/点数预算；不能为600点图标永久保存数百万点数组。

## 7. 三流分工与共享文件边界

先由core流冻结以上helper/类型签名，建可编译契约；之后三流并行。只按文件独占，不能让两个代理同时改TrackStore或MetalPointRenderer。

| 流 | 独占文件 | 主要职责 | 等待/输出依赖 |
|---|---|---|---|
| A：core、parser、导出、QuickLook | GPXParser.swift；新TrackTopology.swift；TrackData.swift；GeoCompute.swift；GPXWriter.swift；GPXQuickLook/TrackShape.swift、PreviewViewController.swift；GPXThumbnail/ThumbnailProvider.swift | 段元数据、排序/快路、topology与draw plan、速度距离/CPU fog、标准GPX、预览 | 最先提交类型/helper接口和测试夹具；供B/C调用。GPXWriter接受B新增fill segment无直接耦合 |
| B：gap、batch、state和UI集成 | GapFill.swift；BatchFill.swift；TrackStore.swift；ChangeLog.swift；BatchFillWindow.swift；ChangeReviewWindow.swift；ContentView.swift；UITestHook.swift；PointMapView.swift | 段内检测/上下文/行程、GapID、job membership、批量/预览/编辑/CSV与增量GPX；R1/R2接入 | 依赖A的topology；持有TrackStore/ChangeLog，P1/P2同一owner串行整合；PointMapView含Double-key cache，故归B |
| C：Metal与shader | MetalPointRenderer.swift；Shaders.metal | drawRun/拓扑buffer、line/fog映射、LOD/端点/过滤/裁剪、GPU验证；R3同owner整合 | 依赖A的PathDrawPlan；需要PointMapView调用点修改时给B精确补丁，不同时编辑 |

主代理单独维护project.pbxproj与harness源文件清单，或明确交A独占；该工程使用显式PBXBuildFile，不是自动同步目录。新TrackTopology应加入主app与实际需要的测试targets；仅parser新增字段若保持原生整数数组，不必让QuickLook依赖主app TrackData。Tests/synth/run_all和exam脚本需包含新文件，否则只能app编过、离线harness失败。

阶段门：

1. A交付字段/helper与纯函数测试；B/C可基于固定签名实施。
2. A的parser/normalization/metrics和C的GPU draw plan先通过纯数据/Metal测试；B完成所有global-range消费者并合并R1/R2。
3. 主代理集成编译app/QuickLook/Thumbnail与synth/exam，执行端到端编辑/导出和GPU路径；DeepSeek按固定任务复测。

不能把A/B/C任意一个完成当作P4整体完成，尤其不能用parser已保留segment来代替shader/批次membership验收。

## 8. 精确验收用例（先失败、后通过）

| 编号 | 输入/动作 | 必须满足 |
|---|---|---|
| T01 | 同文件两trkseg交叠A0 B0 A1 B1；每段两个点，边长30m、dt10s | order=[0,2,1,3]；line/fog边只有(0,2)/(1,3)；速度为各段单独结果；CPU格集合=分别加载后union，无A-B走廊 |
| T02 | T01 stride=1/2/100，filter全量及global[1,4) | 两点段不因stride大消失；过滤line剩B0→B1，fog另保留A1孤点；不存在跨段边 |
| T03 | 单段5点，stride3；另有单点段、2点段 | 边0→3和3→4齐全；line不画孤点，fog画孤点；最后一段未被漏算 |
| T04 | 同一段内部有100m/600s阈值两侧边，另段交叠 | fog软断处只留各端真实run，LOD不能跨软断点；line按自己阈值，不能误沿用fog阈值 |
| T05 | 两文件都用本地段号0，merge/slice/全局sort/多路merge两路径 | 段身份不碰撞；四列与segment逐点对应；同时间稳定；每段边与分别加载一致 |
| T06 | trk/trkseg/rte/wpt、空段、无时间/同秒、坏点在段首、标签跨chunk、伪标签在注释CDATA | 点数/段归属精确；无跨容器连接；坏点compact后元数据长度一致；不因结构扫描改变普通fixture点数 |
| T07 | A/B两段同tA/tB各一个gap、批次同时取假草稿 | GapID不同，两个item/采样/预览/重取状态独立；没有字典覆盖；不联网 |
| T08 | 时间序A0 B0 A1 B1 A2 B2，对A0→A2替换内部A1 | B0/B1/B2所有字段、数量与segment不变；removed只含A1；预览与落地计数完全相同 |
| T09 | T08同时对B段补点，两job全球区间重叠 | 两job都落地；不能因lastB跳过B；同段真正重叠job明确拒绝；shiftA/B不能移到别段 |
| T10 | 两段空间/时间接近，边界恰好满足旧gap门槛；段内也有真实gap | 跨段不造gap；段内真实gap仍发现；context/heading/retime/replay/jitter/trip样本都只取本段 |
| T11 | 填→删→部分还原/全部还原；同值不同segment点 | segment与数值一并恢复；R1完整键不会删除/恢复另一段的同值点；切模式重建不复活被删点 |
| T12 | T01标准GPX导出再解析；两fill时间窗重叠的世界迷雾GPX | 各自正确trkseg、点数与边保持；增量锚点/合成点不串段；显式外层fill分组不合并 |
| T13 | T01 CSV及CSV同秒碰撞 | 仍单文件/同秒现有规则；速度距离航向由本段前驱，无跨段假速度；不声称CSV段结构往返 |
| T14 | T01完整QuickLook、采样QuickLook、thumbnail | 显式段间不画桥；采样后同段仍连；点数预算和大文件限额有效 |
| T15 | 跨视口的边两端均在屏外、隐藏一个文件、截图/视频离屏render | 穿越边不被端点测试误剔除；隐藏文件完全消失，其它段保持；离屏与屏幕同边集合 |
| T16 | 单段原114项/考卷、百万点单段及多段、≥1万短段 | 原单段算法结果不变；记录构建耗时、峰值内存、draw调用数/帧时；无每段完整build、无每帧O(n)CPU扫描、无每段一次draw爆炸 |

GPU验收同时比较CPU draw-plan展开后的端点集合与离屏像素；只截图“看起来没错”不足。加入测试hook输出topology段数、drawRun/primitive数及可选小数据端点，供主代理核对。所有新增期待来自上述已知输入，而不是抄当前实现结果。

## 9. 本任务实际证据与未执行事项

已只读核对主app parser/TrackData/GeoCompute/GapFill/BatchFill/TrackStore/ChangeLog/GPXWriter、Metal/shader、UI约束、QuickLook/Thumbnail及显式工程/harness入口。完整读取在artifacts各txt，命令/结果在artifacts/journal.jsonl。

运行了`artifacts/topology-spec.py`，9项规格模型全部通过：交叠order与边、极大stride、时间过滤和孤点、尾边、soft break、job membership和候选唯一性。完整输出是topology-spec.out.json。这只验证设计公式，不是Swift实现、Metal或产品测试。未修改任何业务文件；未构建/运行app/API/公共路网；未安装或关闭正式app。未运行生产Swift、GPU、UI、性能或导出往返测试。

模型请求为gpt-6-astra/ultra；独立模型回执、token、费用未提供，为unknown/null，主代理负责native bind/finish。本任务恢复只需先读本报告、interface-contract.md和scope followups；其余工作为三流实施与上述真实验收。
