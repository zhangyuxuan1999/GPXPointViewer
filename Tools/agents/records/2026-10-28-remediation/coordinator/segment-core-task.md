# P4-A 显式分段、拓扑、计算和导出实现

模型 GPT-6.1 Sol / ultra。Astra最终设计：Tools/agents/records/2026-10-28-remediation/native/20261028T225215.126329Z_segment-topology-design_253f9196/output.md 与 artifacts/interface-contract.md；必须读当前最终版以及followup-02/03的业务范围。

唯一实现工作区：/private/tmp/gpxpv-segment-integration-o3kf8civ。它从当前产品复制，清单在 coordinator/segment-workspace.json。主工作区 /Users/zyx/Documents/GPXPointViewer 产品源仍冻结给 DeepSeek R4，禁止直接改回去。所有记录写本次唯一 run；所有命令显式 workdir 指向 scratch，stdout/stderr/真实退出码和前后源码快照持久保存。

你独占 scratch 中 GPXParser.swift、TrackData.swift（TrackTopology放此或新文件但必须更新所有构建入口）、GeoCompute.swift、GPXWriter.swift、GPXQuickLook/与GPXThumbnail/需要修改的Swift、Tests/segments/core/新增测试。不要改GapFill/BatchFill/TrackStore/ChangeLog/MetalPointRenderer/Shaders/PointMapView/ContentView；这些有别的Sol所有者，跨边界具体提案或接口变更先消息协调且存原文。

实施：ParsedTrack/TrackData独立segmentID（空隐式单段），真实XML容器扫描一次供并行chunk查段，skip注释/CDATA/引号伪标签；trkseg/rte/不同trk/wpt段身份；compact/slice/merge/所有sort传播，merge重编号。时间规范化是既有产品语义，同秒稳定输入序，不引入原XML顺序保真。TrackTopology按段索引与逆表、邻接/helpers、line/fog runs和缓存可用draw plan接口；交叠 A0 B0 A1 B1 真边0→2/1→3保留，time filter/LOD/softbreak/孤点不丢。速度/距离/迷雾格沿段前驱；单段保留快路径。GPX按真段输出；CSV仍一个平面点表，不承诺保留段结构，速度/距离不跨段。QuickLook/Thumbnail采样段身份并断笔，不能错误连线。

第一步先发布具体Swift接口到本run/artifacts/api-contract.md，并通知主代理；P4-C马上消费，不要长期仅写方案。主代理会转发接口并协调B。设计有16组可失败验收，请实现你拥有的组：实际Swift解析/排序/merge/速度/距离/导出重读/LOD计划、QuickLook分段与百万点快路径；逻辑模型不代替生产测试。无网络/API、无产品app启动、无安装。编译/CLI纯测试可执行；GPU由C负责。不要另派agent。

交付：修改在共享scratch保持、own文件前后快照、patch、新测试、完整output.md与验证结果。不要把其他owner并发差异当自己变更。需要改构建脚本时仅你新测试脚本；产品统一构建入口主代理整合，列出所需项。最终主代理会审查、整合、Release构建和复测。
