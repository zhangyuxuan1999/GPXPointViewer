# P4 完整分段与交叠拓扑设计补充

模型：GPT-6 Astra，ultra。沿用已完成设计证据，补齐 P4，使本轮能修复已发现的问题，不以交叠段断线作为已完成。这里只设计和核对源码，不修改产品、不运行 app/API/网络。

请读取 design/product-design.md 和实际 parser、TrackData、GeoCompute、MetalPointRenderer、GPXWriter、GapFill/BatchFill/ChangeLog/TrackStore，给出可实施的最小完整方案：显式 segmentID 与段内连接索引如何沿排序、速度/里程、line/fog LOD、填补/删除/撤销/导出传播。重点交叠 A0 B0 A1 B1 的真实段内边保留，不能错误跨段连线、开迷雾或识别缺口。保留单段快路径，不做泛化大重构。

输出：按文件列修改接口和共享文件依赖、精确可失败测试；指出可并行工作边界。如某路径真正不是产品功能范围，引用代码与现有 UI 约束说明，但不能以限制掩盖已发现的单文件交叠段错误。

完整 task/过程/输出写本次 agent_run init 分配目录。把重要命令结果、正常过程、源码证据保存进 artifacts，维护 progress.md。允许改自身日志目录；不写业务文件。不要另派 agent/调用 API。结束给 output.md，并说明所有未执行验证。主代理负责保存 native 回执并验收。
