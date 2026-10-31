# P4-A 显式段核心实现交付

完成实现，修改仅留在 `/private/tmp/gpxpv-segment-integration-o3kf8civ`。请求模型 GPT-6.1 Sol / ultra；工具未提供服务端模型回执、token或实际费用，均未知。主工作区产品源码未写回；主代理独立验收仍待执行。

## 具体实现

- `ParsedTrack.segmentID` 与 `TrackData.segmentID/topology` 独立于fileID；CSV单文件隐式段、GPX每个trkseg/rte独立、不同trk独立、wpt孤立。真实词法容器扫描只保留容器边界和注释/CDATA/引号伪标签排除区间。每个并行chunk一次二分定起点，随后线性推进边界游标；count/parse共享真实点判定。单双引号坐标、坏点compact、slice、parseMany、mergeParsed均传播段列，跨文件重新编号。
- `TrackTopology` 放在既有 `TrackData.swift`，无需新产品build入口。稳定scatter生成段内order/rank、段范围；单段两表为空。段内helpers返回共享只读索引view。line/fog各自保持原软断点阈值，时间过滤用段内二分，draw descriptor恰16字节；LOD尾边与fog孤点保留。`includeSoftBreaks:false`仍保留hard段边界。具体API见 `artifacts/api-contract.md`。
- 时间仍全局规范化、缺时间排尾；vDSP相同时间索引显式稳定，heap相同时间按原下标比较，disjoint块搬运与所有置换都搬运段列。不承诺原始XML节点顺序。
- 速度沿path gather一次、复用向量核并修正每段首点后scatter；单段直接调用原向量核。长度/典型步长/软断点只遍历真实邻接。CPU fog仍每点自身格+真实fogRun内DDA，不跨交叠段。旧prefix字段作为全局下标的run token使用，注释已澄清。
- GPXWriter每个请求窗口先按真实source segment分组、段内按规范化时间下标输出独立trkseg，完整导出和已有增量窗口都不会吞并别段。CSV写出位于GapFill.swift，已通知主代理交P4-B负责段内前驱。
- QuickLook/Thumbnail传递采样source标签，TrackShape按段抽稀并断笔。大预览同一次词法扫描给count与sample标签，避免重复完整扫描；采样时间也跳过CDATA/注释伪标签。

## 实际验证

`python3 Tests/segments/core/run.py /private/tmp/gpxpv-segment-core-sample-fixed`：生产Swift解析/构建/计算/GPX写出/QuickLook几何 **97项通过，0失败，退出0**。GPU发布以nil stub隔离，不启动app或提交GPU；可选synthetic PointKey采用生产相同位值语义声明，synthetic标记行为未在此套覆盖。Metal真实渲染由P4-C验证。

覆盖A0 B0 A1 B1的真边0→2/1→3、所有stride与filter/fog孤点、段内helper、独立载入A/B作速度/距离/fog真值、GPX导出重读、多个增量窗口、XML注释/CDATA/属性伪标签、混合CSV的parseMany命名空间、并行chunk起点与坏点compact、slice、全局/heap/块搬运各排序通路的稳定同秒/缺时语义、16字节ABI、QuickLook两条真笔和近距不同段断笔。

QuickLook/Thumbnail全部Swift与共享parser/GeoCompute独立typecheck退出0。最终完整stdout/stderr/命令/真实退出码在 `commands/` 与 `artifacts/final-validation/`。首次typecheck因默认module cache越出沙盒失败，改显式/tmp cache后通过；早期parseMany调用参数错误已修复；新增采样时间断言抓到一个未转换窗口已修复。还保留一次编译期间输入被后续修复改动导致的退出1；最终冻结源码编译通过。所有失败证据保留，没有覆盖为通过。

百万点CPU/解析诊断（`artifacts/benchmark-r2/`）：baseline/current build **34.32/42.11 ms**，24,000,039-byte XML parse **372.97/524.98 ms**。两版均真实解析1,000,000点；当前隐式单段order/rank空、单draw run和尾边断言通过。结构扫描与段列带来实测增加（build约7.8ms，parse约152ms）；这是单次诊断，不宣称吞吐零回归，也不代表GPU或正式app性能。第一轮基准保留在 `artifacts/benchmark/`。

## 交付与集成

7个产品Swift文件修改，6个测试文件新增，无删除。拥有文件精确前后快照、SHA-256、添加清单与独立patch位于 `artifacts/before/`、`artifacts/after/`、`artifacts/*manifest.json`、`artifacts/changes.json`、`artifacts/segment-core.patch`；没有把其他owner并发差异记为自己修改。

生产文件：GPXParser.swift、TrackData.swift、GeoCompute.swift、GPXWriter.swift、GPXQuickLook/TrackShape.swift、GPXQuickLook/PreviewViewController.swift、GPXThumbnail/ThumbnailProvider.swift。新测试在Tests/segments/core/，README列明执行与stub边界。

需要主代理继续：P4-B CSV/编辑状态集成，P4-C实际Metal验证，检查freeze解除后再整合主工作区，执行Release构建与独立核验。无API/网络/公共路网/app启动/安装/另派代理。
