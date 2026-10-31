# 每日／行程摘要架构交付

完成文档：`docs/journey-summary-design.md`。状态为 Proposed，接口和实现分工已定，待主代理独立验收。未实现产品代码，未构建、启动 app、执行产品测试或联网。

## 核心决定

- 单一选定文件的每日／行程报告；多设备无相加总计。默认全部记录，不随主地图筛选重新计算。
- 显式 IANA 时区；Gregorian Calendar 自然日处理 DST 和跨午夜分配，未知日期不造日期。
- 仅真实拓扑邻边，连续性300秒、速度上限1200 km/h；记录折线与补点估算分列，改时位置仍是记录位置但时间属估算。不得复用 Trip.km/autoKind 或 GapDetector 断档阈值。
- 時间区间并集区分观察、估算、移动、低速、未覆盖，源段重叠单列；未覆盖仅在各行首末贡献范围内，非全部漏记时长。
- 旅程按硬源段或30分钟空白分开；没有停车猜测。median5＋3m迟滞的升降估算要求至少80%海拔边覆盖与至少两条海拔边。
- 离线 RegionIndex 记录／估算地区分列，未归属和索引缺失可见。交通仅速度候选或本会话人工指定，不把补点路型当事实。fwdb 不输出虚构每日统计。
- 新 Foundation 核心 JourneySummary.swift 精确类型和 Builder；Store CoW 快照、独立 summary lane 与输入/请求/key校验；对比必须读取 compareTracks。地图筛选仅安全single状态，精确秒级专用筛选块避免控件假显示全部。

## 并行所有权

A（Sol ultra）：JourneySummary.swift，Tests/summary/core；核心类型先交B。
B（Sol ultra）：JourneySummaryState/Window、有限Store/ChangeLog/App/ContentView/ExportSheet/UITestHook/工程接线、翻译和定向UI脚本。
主代理：复用两人原始证据，构建整合与最后像素判断；不得无矛盾重测。

## 证据与限制

- 完整读取命令、stdout/stderr、退出码在 artifacts/commands-parent；apply_patch 精确参数和回执在 artifacts/native-tools。
- 第一次 task/agent README bootstrap 读取早于捕获helper接入，实际工具参数与根据当时读取文件重建的输出另行标记保存；不冒称helper原始采集。第二次helper源码读取原始工具回执已存。
- 一次假定 TrackTopology.swift 独立文件的读取失败；真实定义位于 TrackData.swift，已定位并读取，失败日志保留。
- 集成审查代理提供的独立源码契约已与本次直接读取相互核对；全文源审查路径：../20261030T040811.831198Z_journey-summary-integration-audit_68fdadc0/artifacts/integration-audit.md。
- artifacts/reviewed-source-manifest.json 记录已核对源码SHA；artifacts/static-contract-review.json 只检查文档结构，不代表Swift已编译或算法通过测试。计划表是待执行验证，不是结果。
- requested_model=gpt-6-astra, requested_effort=ultra；工具未提供服务端模型/强度/token/实际费用回执，verified_model/verified_effort/usage/cost保持unknown/null。

本次provider正常完成，acceptance=pending；主代理另行verify。
