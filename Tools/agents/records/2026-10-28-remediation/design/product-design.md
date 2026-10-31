# ADR-20261028-B：R1–R4 最小正确性修复与可证伪测试

状态：建议实现；日期：2026-10-28；Astra Ultra 设计，Sol 实现，主代理核验。本文只做设计，不声称产品代码已修复或生产测试已通过。

## 范围与取舍

优先防止数据被错误发布或错误还原，其次保证显示缓冲版本完整。不要借本轮把 TrackStore 拆成服务层或引入持久化事件系统。R4 的明确安全边界是“不凭时间相邻跨来源/分段制造运动”；完整段内拓扑渲染须另行满足下述连接表条件，不能凭新增 segmentID 就宣布完成。

## R1：还原依赖、重复点与顺序

### 已核对事实

`ChangeLog.swift:115–121` 把所有选中记录的 added 放入 Set、removed 汇总；`:135` 删除当前所有命中点。`TrackStore.swift:2944` 传选中记录，`:2979` 把全部 active 记录一并传入。`performFills:2672–2691` 同批多记录共享同一修改前轨迹下标；`performDeletion:4355–4359` 保存删除前下标。只倒序遍历各条记录仍不能把同批原始下标当作不同时间版本。

本任务已运行纯 Python 逻辑反例（不是生产 Swift 测试），确认当前算法的三个错误：补入 P 再删 P 后全部还原会残留 P；已有 P 又补一个完全相同的 P 后还原会删掉两个；同 time/lat/lon 但不同 ele 的原点也会被一起删。证据见 r1-counterexamples.py/.out。

### 最小决策

1. **全部还原用精确会话基线。** 在首次真实修改提交前保存规范化当前轨迹的 `ParsedTrack` COW 快照，包含四列与来源/分段元数据；在同一编辑会话内保持基线，换文件/clear 时清空。`revertAllChanges` 或选中全部 active 记录直接从该基线重建。它保证完全相依的任意链、无时间点、同秒顺序、相同值重复实例均恢复原序列。不要以每次 mutation 更新的 `files[0].parsed` 作为基线。整批撤销继续使用已有 fillUndo，但基线与 changes 必须保持一致。COW 快照初始不拷贝，代价是会话期间保留原始坐标数组。
2. **部分还原不用 Set 删点。** 引入还原专用完整位键 `(lat, lon, ele, time[, segment])`，不要修改用于增量导出的全局 PointKey 语义。采用有符号多重集：选中记录 removed 贡献 +1、added 贡献 -1；先抵消同键中间点，再从当前轨迹恰好删除负数数量并补回正数数量。正数需保存实际 ChangePoint 候选，不能只保存计数。缺少必要出现次数时返回 conflict，不发布部分结果。不要依赖 Double 的 NaN 等值运算，按位键处理（如规范化 NaN，必须四列统一）。完全相同的点只删所需数量，海拔不同的点不能相互顶替。
3. **明确部分还原的可验证边界。** 对早期选中修改的 added/removed 建 touched 集，检查后续仍保留记录的 added/removed/anchors 是否相交，递归检查依赖闭包。如依赖记录不在选择集合，返回 conflict；不静默扩大选区、不把未选记录标成 reverted。选择包含依赖闭包时多重集抵消能处理补后删/多次改时。无稳定实例 ID 时，同键冲突按保守依赖处理，允许误拒，禁止误删。
4. **不继续声称无时间任意选择能精确。** 如部分还原需要插回无时间点，或同一有限时间的不同点顺序不能由现有记录确定，返回 conflict，建议还原后续修改或全部还原。最近完整事务可做按原始下标逆操作，但同批必须整体处理；本轮不必为了放开这条捷径引入事务分组。仅删除新增点而无需插回时，多重集数量匹配可安全处理。
5. `ChangeRevert` 返回 Result/计划（parsed 或 conflict 原因），所有内存轨迹、files.parsed、fills、changes.reverted 的变动只在主线程一次提交且受 R2 token 保护。冲突时不改任何记录。新用户提示需要按现有 l10n 流程组装。

选择这条保守路线是为了在小改动中停止破坏数据；若产品必须保持“任何记录随便选且永远可还原”，则需要稳定 pointID 加事务依赖/重放语义，不能靠按值集合补丁兑现。建议让主代理按用户实际期望决定是否接受部分还原的安全拒绝；不要求为技术实现另起批准流程。

### 必须能失败的测试

- 起点 `[A,B]` → 补 P → 删 P → 全还原；结果四列位模式及顺序等于 `[A,B]`，P 为 0；当前算法应失败。
- 原点 P 与新增 P 全字段相同：部分还原新增后 P 数量从 2 到 1；另设海拔不同但旧 PointKey 相同的两个点，原海拔不能丢失。
- A→A' 改时 → A'→A'' 改时 → 删 A''，全还原回 A，部分仅还原第一条必须 conflict，全部轨迹和标志不变。
- 两条独立不同时间的删除，分别还原或同时还原均正确；部分还原后再全还原仍等于最初基线。
- `[U0,U1,U2,U3,U4]` 全无时间，两批非相邻删除/同批删除后全还原精确；不支持的非末尾部分还原必须明确 conflict，不能 approximate success。
- 同秒不同海拔/同秒不同坐标、不同段相同值、NaN 海拔、零点/全部删空、撤销最近 fill 后再全还原、重复点击全部还原，均验证值/顺序/重复次数及 fills/changes 状态。
- 测试实际 `ChangeRevert`，将 ChangeLog.swift 纳入离线 harness；Python 反例不能替代 Swift 验收。UI 再验证一条填→删→全还原链即可。

## R2：异步发布必须归属于当前请求

### 已核对事实

`rebuildDisplayTrack:801–808` 无版本校验直接 apply；`load:935–938` 的 progress、`:954` fail、`:979` ingest 无校验；`buildCompareTracks:649` 仅检查模式及文件数量。`clearTrack:1128–1160` 未使这些任务失效且未统一清 loading。除此以外 `runStress:1030`、`undoLastFill:2645`、`performFills:2712`、`revertChanges:2957`、`performDeletion:4363` 都是异步发布点，不能只修导入两处。

### 最小决策

- 在 MainActor 的 TrackStore 内增加一个统一的文档修订号与当前 publication owner（UUID/递增计数即可），以及必要 Task 句柄。`beginDataOperation` 捕获 owner、当前 dataRevision、输入文件 UUID 序列、source track.id（编辑路径）。
- 新接收的导入、显示重建、比较构建、压测、编辑重建开始时换 owner；close/clear/模式切换或文件集合变化使有关 owner 作废。取消 Task 是节约资源，不是正确性条件。
- 每个进度、错误、完成回调第一行校验 owner/revision/必要输入身份。旧回调直接 return，不能修改 isLoading、label、progress、errorMessage、files、track 或 compareTracks。只有当前 owner 可结束自己的 loading。clear 必须作废 owner 且同步清 loading。
- parse→ingest→build 是同一用户操作的受控阶段：ingest 只有在 parse token 有效时执行，再交接新 build owner。不要因无条件 apply 又递增 token 而把自己的合法链误判过期。
- 编辑提交必须验证 source track.id 仍相同；commit 把数据和关联记录一次性更新，然后使其他依赖旧数据的任务失效。比较构建除 owner 外核对文件 UUID 与数据修订（文件数相同不代表同一对文件）。
- 配色等轻量设置变化无需浪费整个几何重建；在合法完成时按当前设置重着色或检查单独 color revision，避免把捕获的旧色发布回来。
- 不把全 TrackStore 改成并发框架；集中 2–3 个 helper 和守卫就足够，但必须列全异步发布出口。

### 可证伪测试

用可控制完成顺序的 worker/闭包 gate，不用 sleep 赌竞态：

1. 启动 load A，暂停在 parse 完成前，clear，放行 A；最终 track/files为空、loading=false，A的progress/error均不能复活界面。
2. A 重建挂起，关闭 A 并让 B 重建完成，再放行 A；最终 track 内容/文件身份属于 B。
3. 比较 A+B 挂起；换成 C+D，文件数仍为2，C+D先完成再放A+B；compareTracks必须是C+D。
4. 新任务 B loading中，旧 A 失败/被拒完成；B 的 loading/progress不被A清掉。
5. 删除/补点/还原/undo 的 build 挂起后 clear/换文件；旧提交不得更改新文件 parsed、fills、changes 或 toast。
6. 合法 parse→ingest→build仍完成；取消后新load能开始；安全资源 scope 最终释放；完成顺序正反都验证。

主代理/Sol 应验证这些状态不变量；DeepSeek可跑固定脚本，但不能仅凭它说“没复现”宣称竞态已修。

## R3：颜色版本不可原地改写

### 已核对事实

`MetalPointRenderer.updateColors:475–485` 对 bufColor 与 bufSColor 原地 memcpy/gather；`:1132` 等到 scheduled 不等于所有GPU读取已完成。所有渲染入口使用 `queue.makeCommandBuffer()`（:669/:1572/:1903），没有自定义取消资源保留的路径。TrackGPUBuffers 的预建 color/scolor 还会被多renderer领养，原地写色也可能污染共享的基线缓冲。

### 最小决策

- 每次 updateColors 验证长度后，先分配一个新时间序颜色buffer，再按当前 spatialOrder生成新Morton颜色buffer；两者完全构建成功后再成对替换 renderer 引用。若该轨迹没有空间副本，只替换时间序。需要空间副本却分配失败时整体保留旧版本，不能半新半旧。
- 把颜色组表达成一个小的不可变 `ColorBuffers` 值/对象（temporal、spatial、version）或在同一线程一次赋值；render 开始捕获同一组局部引用，当前command buffer用该组直到完成。
- 已提交的command buffer必须保有其使用资源直到完成。当前标准makeCommandBuffer路径可依赖正常资源保留；为了清晰或测试，可completed handler显式capture该颜色组但不要形成持久循环。不要把旧buffer放回池中，除非完成回调归还。
- TrackGPUBuffers初始颜色也当不可变共享资源；某renderer换色只替换自身组，不修改track缓存或别的renderer颜色。
- 不加入逐帧waitUntilCompleted；若后续分配压力量化明显，再加有GPU完成交接的池，本轮先保证正确。

### 可证伪测试

- 捕获初始temporal/spatial引用与字节；updateColors后新引用不同，旧字节完全不变，新temporal准确、新spatial为同一颜色数组按已知置换重排。
- 两renderer领养同一TrackGPUBuffers，给一个换色；另一个及TrackGPUBuffers字节不变。
- 注入第二次分配失败：两引用/版本均保留旧组；非法颜色长度也不改变当前状态。
- GPU集成用受控事件/排队命令让旧帧延迟读取，CPU连续换两色后释放旧帧；旧帧读到旧组，新帧读到完整新组。单纯“快速切色100次没有花屏”不能证明无竞态。
- 单一已指定测试构建执行正常色/补点高亮/删除灰显/空间LOD/截图导出回归；监测分配峰值和颜色更新延迟。若环境无Metal/GPU测试，必须保留“GPU在途验证未完成”，不能当全部通过。

## R4：保留显式分段，分离时间顺序与连接语义

### 已核对事实

ParsedTrack(:26–47)只有四列与显示fileID；`parseChunk:741–805`不保留容器边界；`slice:457`和mergeParsed(:472)也没有段语义。TrackData全局按时间排序(:1099)，line break只看时间/距离(:654)，fog break也只看时间/距离(:791–796)。GeoCompute.speedsKmh(:105)只接四列，以全局相邻点测速。更改fileID判断只能修多文件的一小部分，并会混淆审阅的色类fileID。

### 最小可合入安全范围

1. 新增独立 `segmentID: [UInt32]`（空表示一个隐式段；非空长度必须等于count），与fileID分开。GPX每个trkseg、每个rte独立编号；不同trk不能共段；wpt默认孤立，不因相邻时间成为路径。CSV一个文件一个隐式连续段，仍保留现有时间/距离软断点。
2. 对并行字节解析先得到不可变结构边界表（容器开/闭标签offset→段编号），各chunk按point起始offset二分/顺序推进取段号。扫描必须识别真实XML标签并跳过注释/CDATA/引号内容，避免备注中的`<trkseg>`伪造分段。短小文件、跨chunk边界、空段/坏点过滤/带命名空间均应与现有点解析兼容。不要每个chunk从文件头重复扫描，避免O(n×chunks)。
3. parse/parseMany的压紧、slice、merge、两种时间排序路径都同步搬段号。merge重编号使来自不同文件的本地同号段不相等。修改/快照/ChangePoint/GapSplice/还原/审阅合成路径全部保留；补点只有两锚点同一真实段才继承该段，否则不自动跨段落地。审阅颜色类别不会改变segmentID。
4. 时间序中相邻点segment不同是hard break，合并进入line/fog前缀；LOD跨任何hard break同样断开。gap候选、上下文扩展、隧道群合并不能越过hard break，否则会把用户显式分段当丢星自动补起来。导出至少在hard break处分trkseg；不以输入完整XML往返保存为承诺。
5. 距离/速度另做一趟按段的前驱表 `previousInSegment`（或相同语义的段内索引列表），按时间规范化后在每段内相邻计算。段首速度为未知/现有约定0，不能复制另一段速度；多文件A-B-A-B交叠时A的速度仍由A前点得到。保留单段向量化快路，多段使用段内处理或按前驱gather。总长也不能累加跨段跳距。

### 必须明确的边界与完整拓扑条件

全局时间数组配合hard-break前缀能防止错误跨段连线，但交叠段A0,B0,A1,B1会把两条真实线都断开。这是保守安全结果，不是完整段内连线。若本轮要求该场景正确显示线路/迷雾，应增加段内edge列表（起/终点索引）或按段索引流，让line/fog按实际edge渲染；时间筛选、file可见性、LOD应在边两端/段内部判断。不能把“每条段号相同”当作LOD跨多个段的允许条件，必须检查中间路径。

建议本轮至少实现1–5，并把当前多文件轨迹线被禁用的界面边界保留；对单文件交叠trkseg的线路/迷雾明确记录保守断连限制。若要消除此限制，edge列表是必做实现项，不应作为“以后优化”混入已完成清单。不要为了R4同时改区域算法/迷雾存档格式。

### 可证伪测试

- 单GPX两个trkseg，段尾到段首仅1秒/2米（低于所有原阈值）：速度不跨段、line/fog前缀增加、没有跨边界gap候选；当前代码应失败。
- 同文件两trk、两rte、孤立wpt、空trkseg、坏点在段首/段尾、分隔标签跨chunk、注释/CDATA内伪标签，段身份及点数准确。
- 两文件本地均segment=0且时间交叠A0,B0,A1,B1，merge后不同来源段身份不碰撞，A/B速度等于各自单文件计算；时间排序两条快/慢路径结果一致。
- 删除某段中部点仍保留段身份；删除整个中间段后前后不同段不被拼接；补点不能跨明确段边界；撤销/全还原段数组精确恢复。
- LOD端点表面上同段但区间夹有别段时安全断开；若实现edge列表则按段获得两条真实边且fog不多开连接走廊。
- 正常导出再读：每段点值/重复次数保持，输入显式段边界不合并；允许输出因全局交叠被进一步拆段，但必须说明不是原始XML结构往返。
- 单段现有114项合成、离线考卷与百万点性能不可退化；新断点改变旧期待必须依据合成输入真相，不能照输出改答案。

## 顺序与完成判据

建议工具修复+mock通过 → DeepSeek第4轮按指定脚本查现状 → Sol实现R1/R2/R3及明确选定的R4范围 → 主代理执行关键纯函数/竞态/Metal验证 → DeepSeek固定命令复测。全部阶段都有唯一记录，任何未验证GPU/拓扑范围在最终报告中单列未完成。不调用公共路网、不安装到/Applications、不关闭正式app。
