# T13最终独立验收

Root逐段核对reducer与runner集成及Astra两份设计。最终r4b源hash与实施者/独立Sol冻结相同；root串行109/109，32.129秒，0 errors/failures，exit0（commands/20261029T124221_background-protocol-final-independent_83d0a90e）。独立Sol86/86场景及3项关联回执通过；前景兼容/null/可选schema/已知run跨任务复用四项均真实复现后修复，原失败探针保留。

真实后台原11989事件经实际runner纯转发重放16/16；旧前景流及最小明确合成终报告对照12/12。未重执行记录中的工具，provider calls0。真实原报告逐hash一致；费用仅末累计CLI估价，实际cost null。两个历史run的result/output/transcript/events各四份hash仍一致，旧失败/中断不改写。

辅助合法遥测与后台认证分离；仅完整同session/task/run、local_bash+显式true、通知到result来源/连续index/唯一UUID可背书多结果。前序错误、孤立/重复/错身份、run跨任务复用永久失败；显式后台不完整为unknown。failed/stopped通知只记任务失败，provider成功仍独立验收pending。

早期86探索轮一次计时12.0784>7失败，子命令3.5028秒，余8.5756秒在测试归档/读回范围，外部耗时原因未确证；日志保留，未放宽阈值。孤立重测3.311秒通过，此后冻结98/102/104/109及本次root109通过；无可复现未修阻塞。

本项工具实现与审查验收通过；后续真实DeepSeek四图运行另验，不将离线重放冒称新增API。精确回执见background-protocol-root-review.json。
