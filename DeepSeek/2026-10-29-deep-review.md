# 2026-10-29 · 深度代码审查（第二轮）

- **时间**：2026-10-29 19:20–19:45（Europe/Berlin）
- **发起**：用户"仔细研究这个项目，看看有啥地方能优化，或者看看有啥 bug/不合理的地方"
- **执行**：DeepSeek Harness 主代理（静态审查 + 三个最小复现探针）
- **产出**：[issues.md](issues.md) 新增 N-19 … N-30；更新 N-06 / N-07 的复核结论

## 方法

1. 静态审查：`GPXParser`、`TrackData`、`TrackStore` 异步与发布、`GapFill`/`ChangeRevert`、`FogArchive`、`RegionIndex`/`RegionStats`、`RoadNetwork` 限速与 HTTP、`GPXWriter`、`MapSources`、`VideoExport`、`DiffCompare`、`StressTest`。
2. 模式扫描：`try!`/`as!`/`fatalError`、`precondition`、`Int(Double)`、`removeFirst`、阻塞等待、`@unchecked Sendable`、`Task` 入口的 token 覆盖。
3. 最小探针：用产品源码编三个命令行程序，验证"静态看起来可疑"的地方。**探针只读产品源码，不修改仓库。**
4. 真实数据核对：扫 `data/` 下 GPX/CSV 的 `<ele>`/`<time>` 完整性。

所有结论按"已复现 / 静态推断 / 未验证"标注，不把推断写成缺陷。

## 结论一：时间/海拔着色遇到部分缺失值会崩溃（已复现，真实数据可触发）

### 现象

一个轨迹里**部分点**有海拔（或时间）、部分点没有时，切到「海拔」或「时间」着色，应用以 `SIGTRAP` 终止。

### 根因

1. [Colormaps.swift:51](../GPXPointViewer/Colormaps.swift#L51)：

   ```swift
   let raw = Int(tBase[i] * 255.0 + 0.5)
   ```

   `tBase[i]` 是 `Float`；当它为 `NaN` 时，`Int(NaN)` 在 Swift 里是**受检转换，直接 trap**。

2. 这个 `NaN` 从哪来：[GeoCompute.swift:246](../GPXPointViewer/GeoCompute.swift#L246) `normalized01` 用 `vDSP_vclipD` 把值夹到 [0,1]。**实测 vDSP 的 clip 不处理 NaN，会把 NaN 原样传出去**（Apple 文档未承诺 NaN 行为）。
3. 为什么会有 NaN：[TrackData.swift:994](../GPXPointViewer/TrackData.swift#L994) `values(for:)` 直接返回 `time` / `ele` 原始列；缺失值在解析阶段就是 `.nan`。而 [TrackData.swift:982](../GPXPointViewer/TrackData.swift#L982) `resolveMode` 只在**全部**没有时间/海拔时降级到单色——**只要有任意一个点有值，`hasTime`/`hasEle` 就为真**（[:675](../GPXPointViewer/TrackData.swift#L675)、[:923](../GPXPointViewer/TrackData.swift#L923)），部分缺失不会降级。
4. 触发路径：[ContentView.swift:235](../GPXPointViewer/ContentView.swift#L235) 选着色 → `recolorNow()` → [TrackData.swift:1005](../GPXPointViewer/TrackData.swift#L1005) `recolor(preferred:)`。载入时 `TrackData.build` 也会按当前着色模式走同一条路（后台线程崩溃）。

### 复现（真实数据，最有力）

项目自己的 `data/Garmin_Roma_Da1_GPVexported.gpx`：49,672 个 `<trkpt>`，只有 49,667 个 `<ele>`；解析后 5 个点 `ele = NaN`。

```swift
// 探针（与产品同源码编译；只读）
let data = try! Data(contentsOf: URL(fileURLWithPath: ".../data/Garmin_Roma_Da1_GPVexported.gpx"))
let parsed = try! GPXParser.parse(data: data)
print("n=\(parsed.count) missingEle=\(parsed.ele.filter { !$0.isFinite }.count)")
let (track, _) = TrackData.build(parsed: parsed, preferredMode: .single,
                                 singleColor: SIMD4<UInt8>(255,0,0,255))
_ = track.recolor(preferred: .elevation)     // ← SIGTRAP
```

实际输出：

```
parsed n=49672 missingEle=5 missingTime=0
build ok; hasEle=true hasTime=true
choose 海拔 coloring...
Trace/BPT trap: 5   (exit 133)
```

同样的三行最小合成数据（中间点 `time = .nan`，或 `ele = .nan`）在 `.time` / `.elevation` 下均 exit 133；`.speed` 不受影响——`GeoCompute.speedsKmh` 在收尾把 `dt≤0/NaN/Inf` 清零（[GeoCompute.swift:171](../GPXPointViewer/GeoCompute.swift#L171)），所以速度列没有 NaN。

`compare/Da_Muenchen_Garmin_GPVexported.gpx` 同样是 15,113 点 / 15,112 个 `<ele>`，也会触发。

### 影响

- 用户一旦对这类文件选「时间」或「海拔」，应用当场退出；正在编辑但未落地的修改（预删除、补点草稿）丢失。
- 本项目导出的文件就可能带缺失值（`GPXWriter` 对 `ele` 为 NaN 的点不写 `<ele>`），导出→再导入→着色即可复现。
- 项目自己的合成数据族 `format-edge` 明确包含"半有时间"的 GPX，说明这类输入被当作真实场景。

### 建议修复

1. **`Colormaps.colorize` 做 NaN 兜底**（单点修复，覆盖所有调用方）：

   ```swift
   let f = tBase[i]
   let raw = f.isFinite ? Int(f * 255.0 + 0.5) : 0
   ```

2. **`GeoCompute.normalized01` 在 clip 后显式清 NaN**（因为 `vDSP_vclipD` 不处理）：

   ```swift
   for i in 0..<n where !out[i].isFinite { out[i] = 0 }
   ```

3. `Colormap.rgb(_:)`（[Colormaps.swift:28](../GPXPointViewer/Colormaps.swift#L28)）目前没有调用方，但同样有 `Int(NaN)`，一并加守卫。
4. 明确"缺失值画成最低档"还是"单独灰色"的产品口径，写进图例说明。
5. **补回归**：在 `Tests/segments/core` 或 synth runner 里加一个"部分缺时间 / 部分缺海拔"的夹具，四种着色模式各跑一遍，断言不崩溃且颜色数 = 4n。现有合成回归只测解析/检测，不经过 `TrackData.recolor`，所以漏掉了这条路径（见 N-30）。

## 结论二：`.fwdb` 目录里名字很长的"密码字母"文件会让应用崩溃（已复现）

### 根因

[FogArchive.swift:286](../GPXPointViewer/FogArchive.swift#L286)：

```swift
var num: UInt64 = 0
for ch in core {
    guard let d = cipher[ch] else { return [] }
    num = num * 10 + d          // ← 无溢出保护
}
```

`load` 会解析 `Sync/` 下**所有**非点开头的文件（[:104-115](../GPXPointViewer/FogArchive.swift#L104)）。只要文件名去掉前 4/后 2 个字符后是 ≥20 位密码表字母（`olhwjsktri`），`num * 10` 就超出 `UInt64`，Swift 的 `*` 是受检运算，直接 trap。`looksLikeArchive` 把名字限制在 8–20 字符，但 `load` 没有同样的限制。

### 复现

```sh
mkdir -p /tmp/fwdbprobe/Sync
touch "/tmp/fwdbprobe/Sync/olhwolhwjsktriolhwjsktriolhwjsktriri"   # 36 字符，全是密码表字母
```

调用 `FogArchive.load(url:)` → exit 133（SIGTRAP）。探针需为 `FogStats` 提供一个同字段的最小定义（本探针不链接 `TrackData`）。

### 影响

- 触发条件罕见（需要用户把这样一个文件放进存档目录），但后果是直接崩溃。
- 同一目录里正常的非区块文件（`.DS_Store`、`readme` 等）已有防护，不会走到这里。

### 建议修复

在循环前加边界（区块号最大 262143，6 位数就够；为兼容可能的零填充，限 18 位即可）：

```swift
guard core.count <= 18 else { return [] }
```

或改用 `&*` / `&+` 并在循环内 `guard num <= 512*512 else { return [] }`。同时给 `load` 加一条"只认名字长度 7…20"的过滤，与 `looksLikeArchive` 对齐。

## 结论三：README 的"多窗口互不影响"与实现不符（已核实）

[README.md:68](../README.md#L68) 写"⌘N 可开多个窗口同时看多个 GPX，互不影响"。实际：

- [GPXPointViewerApp.swift:120](../GPXPointViewer/GPXPointViewerApp.swift#L120) 在 App 级持有唯一 `@StateObject TrackStore`，`WindowGroup` 的每个窗口都拿到同一个对象（[:128-132](../GPXPointViewer/GPXPointViewerApp.swift#L128)）。
- [ContentView.swift:14](../GPXPointViewer/ContentView.swift#L14) 是 `@ObservedObject var store: TrackStore`，没有按窗口建 store。

所以 ⌘N 开的是**同一份文档的第二个视图**：在任一窗口打开/关闭文件、改筛选，所有窗口同步变化。这与 10-28 接手记录里"共享会话状态驱动的原生单体"一致，**是文档过时而不是实现错误**。

建议：改 README 为"⌘N 多窗口查看同一份数据（共享筛选与文件状态）"，或明确写出这是有意设计。

## 其他代码级问题（静态推断，未复现）

### 多段 GPX 导出走串行路径

[GPXWriter.swift:49](../GPXPointViewer/GPXWriter.swift#L49)：只有一个段时走并行的分块写出；`segs.count > 1` 时逐点串行格式化，且每段先建 `[UInt8]` 再 `Data(bytes)` 复制一次。重叠/对比模式导出、增量导出（每处补点一段）都会走这条慢路径。建议按段并行（各段写入独立缓冲后按顺序拼接），收益在百万点级导出时可见。

### `upload()` 用点数 `n` 而不是数组长度做拷贝长度

[MetalPointRenderer.swift:533](../GPXPointViewer/MetalPointRenderer.swift#L533)：

```swift
func upload(_ a: [Float]) -> MTLBuffer? {
    a.withUnsafeBufferPointer {
        device.makeBuffer(bytes: $0.baseAddress!, length: n * MemoryLayout<Float>.stride, ...)
    }
}
```

`n` 是 `track.count`，不是 `a.count`。当前所有列都等长，暂不出错；一旦某个派生列变短（新字段/裁剪路径），就是越界读或读进未初始化内存。建议 `guard !a.isEmpty`、`length: a.count * stride`。

### 每个区块文件都先分配并清零 8.4 MB

[FogArchive.swift:293](../GPXPointViewer/FogArchive.swift#L293)：`Data(count: 32768 + 515*16384)` ≈ 8.4 MB，`Data(count:)` 会清零。典型区块解压后只有几十 KB。归档包含上千个区块时是纯浪费（清零 = 写带宽）。建议先按 `comp.count * 8` 估一个上限、失败再倍增重试，或用 `compression_stream` 流式解压。README 里"80 万格 65 ms"说明常见归档只有少量文件，所以这不是当前瓶颈，但世界级归档会放大。

### Valhalla 错误码映射有不可达分支

[RoadNetwork.swift:542](../GPXPointViewer/RoadNetwork.swift#L542)：

```swift
ec == 442 || ec == 171 ? "NoRoute" : (ec == 170 || ec == 442 ? "NoSegment" : ...)
```

第二个 `ec == 442` 永远到不了（前面已经返回）。像是复制粘贴时留下的，建议对照 Valhalla 文档确认本意（170/171/172 的语义），否则某些错误会被归到 "NoRoute"。

### `GPXWriter` 静默丢弃越界下标

[GPXWriter.swift:41](../GPXPointViewer/GPXWriter.swift#L41)：

```swift
for index in selection where index >= 0 && Int(index) < track.count
```

调用方传错下标时会**少写点且不报错**。导出是"写文件"操作，静默少点比失败更糟。建议改为 `precondition` 或抛错（内部调用方都应保证下标有效）。

### 导出文件名递增依赖轨迹名

[TrackStore.swift:1313](../GPXPointViewer/TrackStore.swift#L1313) `exportedFileName` 只看轨迹名里有没有 `_GPVexported`。README 说"再次导出自动递增 `_2`、`_3`…"，但同一份轨迹连续导出两次时，第二次仍叫 `..._GPVexported`，靠保存面板提示覆盖。只有把导出的文件重新导入（轨迹名带后缀）才会递增。建议改文档措辞，或按已存在文件自动选下一个编号。

### `RailPath` 对空路径会 `1..<0` 崩溃（防御性）

[RoadNetwork.swift:1389](../GPXPointViewer/RoadNetwork.swift#L1389) `for k in 1..<path.count`：`path` 由 `ids.compactMap { coord[$0] }` 得到，正常图里非空；但若图里有节点没有坐标，`path` 可能为空，Range 构造直接 trap。加 `guard path.count >= 2 else { throw RouteError.noRailPath }` 即可。

## 优化机会（按收益排序）

1. **修复 N-19 的崩溃**：一行守卫 + 一条回归，优先级最高。
2. **单文件载入少两次整列拷贝**：`load` 里先 `slice`（每文件留底）再 `mergeParsed`（合并）——单文件时这两次都是整份 4 列的复制（1.9M 点约 121 MB 峰值、几十毫秒）。单文件可直接把解析结果作为显示数据，跳过 slice+merge。
3. **多段导出并行化**（见上）。
4. **区块解压缓冲按需分配**（见上）。
5. **`estimateCount` 在回放时按代过滤**：它不传 `maxGen`，早期回放会按全量估计实例数、可能选到更粗的聚合级。只影响观感，改动很小。
6. **`applyBlockMoves` 的 `segmentID` 用 `replaceSubrange`**：逐段替换会做多次 `memmove`，可改成一次分配 + `memcpy`（与 Double 列一致）。当前只在多文件合并/乱序排序时走，影响有限。

明确**不**建议改的：`recolor` 在 `apply()` 里的重复调用。实测 100 万点重复着色只要 1.1 ms（vDSP 很快），不值得为它加缓存判断。

## 已核实、没有发现问题的部分

- `GPXParser` 两趟并行：计数与写入共用同一套标签判定；坏点压紧只搬 `written` 前缀；`compact` 后 `removeLast` 正确。
- `TrackData.sortByTimeGlobal`：`vDSP_vsortiD` 后对等键按原下标重排，稳定性正确；`mergeSortedRuns` 的三级快路（已序 / 不重叠 / k 路堆归并）逻辑自洽，NaN 统一拼尾。
- `ChangeRevert`：全部还原直接返回会话基线；部分还原在后续修改触及同一完整位值时返回 `laterDependency`；同时间不同位值返回 `ambiguousOrder`。10-28 手记里的"补 P→删 P→全部还原"例子不会复活中间点。
- `TrackStore` 异步发布：审计 29 处 `Task`/`Task.detached`，全部带 publication token、请求 ID、generation 或内容级复核（如地名回填检查 `changes`/`previewIDs` 仍含该 id）。
- `RegionIndex`：载入时校验所有索引在界内；微度整数射线法乘积在 Int64 范围内；1° 格候选 + 0.01° 单元缓存逻辑正确。
- `DiffCompare`：`safeQ` 防 `Int64(Double)` 越界；两阶段匹配（精确 + 8 邻格）左右结论同源。
- `RegionStats`：日界按每个点当时的时区偏移取，夏令时切换用 `nextDaylightSavingTimeTransition` 缓存；`lastDay` 跳过重复插入不影响正确性。
- `VideoExport` 的 `sem.wait()` / `group.wait()` 在 `Task.detached` 里，不阻塞主线程。
- 单点、重复点、负时间、极区、日界线等边界轨迹：四种着色模式全部正常（探针已验证）。

## 未验证 / 下一步

- 没有构建应用、没有跑 UI/合成回归；上述崩溃是用同源码命令行探针复现的，未在 `.app` 里点过。
- N-19 的修复需要产品代码改动；按项目规则属于"重要实现"，建议由 Sol/Astra 或用户确认后再动，并补 `Tests/segments/core` 回归。
- N-20 的修复很小，但需要一个 `.fwdb` 目录夹具；可以放进 `Tests/synth/fixtures` 或 `Tests/segments/core`。
- 性能类建议没有做 A/B 基准（除 `recolor` 外），收益数字是复杂度推断，不是实测。
