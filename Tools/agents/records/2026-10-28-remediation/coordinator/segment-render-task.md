# P4-C 分段拓扑的 Metal 线路和迷雾实现

模型 GPT-6.1 Sol / ultra。先完成的P3已被主代理独立运行17/17真实Metal回归，源码将拷入共享scratch作为本任务基础。Astra最终方案：native/20261028T225215.126329Z_segment-topology-design_253f9196/output.md、artifacts/interface-contract.md（路径均相对于当前 remediation 批次）。

唯一实现工作区 /private/tmp/gpxpv-segment-integration-o3kf8civ；主产品工作区冻结，禁止改回。你独占 MetalPointRenderer.swift、Shaders.metal、Tests/segments/render/新增harness。P4-A Sol负责GPXParser/TrackData/TrackTopology/GeoCompute/GPXWriter/QuickLook，会尽快提供具体api-contract；你可先读现有shader、准备受控案例，再和A按该接口实现。P4-B负责PointMapView/ContentView与gap/state，所需调用改动请给patch/精确接口，不直接抢文件。

必须在保留现有时间规范化语义下正确渲染同文件/多文件交叠段 A0 B0 A1 B1 的真实段内边。采用段内order+run描述符，按time filter/stride/line与fog软断点产生缓存plan，不能每帧O(n)造边表。任意stride保留每段尾边/孤点，无跨段线/迷雾走廊；不要因端点均在视口外漏掉穿视口边。普通单段快路保留。复用P3不可变buffer生命周期；所有平面/球面/截图离屏/迷雾相关路径审查覆盖，不把只修一个shader宣称全部通过。

实际Swift+Metal测试必须能击穿旧实现，包含交叠段/LOD/筛选/软断点/孤点/视口穿越与旧GPU在途资源；能复用P3测试。无窗口GPU CLI可运行，若沙盒无设备走必要设备授权并保存失败证据；不启动产品app，不调用API/公共路网，不安装。不要另派agent。

记录完整派发、命令输出/退出码、阶段progress、允许文件前后快照。交付shared scratch中的改动、新测试、patch、完整output与未验项。所有代理间消息先存原文；主代理负责最终整合/Release/UI。
