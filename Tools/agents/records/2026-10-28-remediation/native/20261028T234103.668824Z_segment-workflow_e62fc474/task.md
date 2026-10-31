# P4-B 分段缺口、批次、编辑与 UI 集成

模型 GPT-6.1 Sol / ultra。先完整收尾 P1/P2（output/真实Swift测试/可审查patch）；主代理会把其明确文件版本拷入共享scratch。之后此任务在 /private/tmp/gpxpv-segment-integration-o3kf8civ 中继续，主工作区产品源码仍不能直接改回。

读 Astra 完整最终方案 native/20261028T225215.126329Z_segment-topology-design_253f9196/output.md；core接口 native/20261028T231200.451592Z_segment-core_c7b39e9c/artifacts/api-contract.md。路径前缀都是 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/。保留既有时间规范化与单CSV平面点表语义；不扩成原始XML往返，不加跨编辑稳定pointID。

独占共享scratch文件：GapFill.swift、BatchFill.swift、TrackStore.swift、ChangeLog.swift、BatchFillWindow.swift、ChangeReviewWindow.swift、ContentView.swift、UITestHook.swift、PointMapView.swift，以及Tests/segments/workflow/新增回归。A Sol拥有parser/TrackData/GeoCompute/GPXWriter/QuickLook；C Sol拥有MetalPointRenderer/Shaders。禁止抢文件，必要接口协调消息先留原文并通知主代理。

实现完整P4-B：
- 检测/replay/jitter/SamplingProfile/TripSegmenter逐真实segment的轻量view，保持单段快路，不逐段调用完整TrackData.build。段边界不造gap；段内context/heading/frozen chain/retime/外推移步用topology邻接，局部结果一次映射回global，避免每个小上下文复制整段。
- GapID(trackID,segment,a,b)替代tA唯一键，候选/采样/预览/批次/重取/颜色缓存/所有UI字典一致迁移；同tA跨段独立。Trip按segment+pathRange查找。
- GapSplice.Job的membership按同段anchors与rank；keep必须子集，同段jobs冲突明确拒绝，不静默部分成功。删除mask只能删除该段内点，不得吞交叠B段。批量lastB按segment分组；预览、实际落地、removed记录共用同一membership。跨段锚点拒绝落地。
- 所有编辑/补点/删除/撤销/还原/快照与ParsedTrack构造保留segmentID，ChangePoint/完整位键加入segment，P1的精确基线同时恢复段列。GapFill保存segment，世界迷雾增量导出与mergedWindows按segment，CSV速度/距离/航向按本段前驱但保持既有单文件/同秒策略。
- UI调用及缓存配合新GapID；协调C提供PointMapView所需局部改动。明确分段完整渲染后，审查原isMultiSegment启发式对线条开关的限制，避免支持了GPU却让UI永远禁用；保留真正仍适用的产品范围并说明。UITestHook保持原序号操作，并给小数据topology/段信息供核验。

R4独立审查刚确认一个额外产品缺陷，必须一起修：native/20261028T232721.100499Z_r4-risk-audit_9c4dd021中，candidate tA1792256646的StaleRetime同时保留近A两个只+2s的点和近B五个约+110s的点，plan.vertices被截在首保留点前，只新增2点，真正GapSplice落地后再跑computeCandidates仍得timeGap 109s/4195.402666m。risk0对实际落地geometry正确，不可给无偏移几何硬加分；问题是出口保留序列不连续造成underfill。Sol审查正给局部证据/patch，主代理将让Astra确认最小修复设计后转给你。你可先进行其它P4迁移，不抢改这一算法决策；后续必须加原数据生产链回归与普通/纯连续出口非回归，预览与实际落地仍同一job。

另外主代理已看 R4 三语截图：两行footer完整无遮挡，R4该项通过；但en/de侧栏中段确有左侧内容裁切（任务已注明旧德文问题不计R4失败）。用户现要求问题都修，请顺带在你拥有的ContentView排查并修该已有布局缺陷：/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/artifacts/shots/r4_main_fill_en.png 与 r4_main_fill_de.png。不能通过隐藏功能或缩小到难读字体掩盖；限制子布局宽度/允许合适换行或滚动。保留固定两行footer不遮挡。产品截图验证由主代理整合后做，不在scratch启动app。

验证必须用实际生产Swift，覆盖Astra T07–T13：同tA双段候选、A0B0A1B1A2B2只改A中间B完全不变、两个全球时间区间重叠的不同段job均成功、同段重叠拒绝、预览落地一致、段内context/retime、填删还原含同值不同segment、GPX增量段窗和CSV前驱。现有单段114项/考卷不可改期待；不能以新断点合理为由掩盖单段回归。无API/公共路网/产品app/安装，不另派agent；可本地编译和CLI测试。

记录完整任务、消息、命令stdout/stderr/退出码、阶段progress、独占文件前后快照，给patch/完整output和所有未验项。主代理负责最终产品构建/端到端UI和DeepSeek复测。不要把自己完成当P4全部完成。
