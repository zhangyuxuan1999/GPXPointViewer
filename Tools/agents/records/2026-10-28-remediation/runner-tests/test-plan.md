# 离线回归计划与接口假设

仅用标准库 unittest / mock CLI / 合成 Git 仓库；不调用 SDK/API/app、无需凭据。

1. 旧实现：AST 提取状态表达式、台账更新算式；同秒/分钟名覆盖和默认 git diff 漏 untracked/staged 的最小复现。
2. 唯一目录：同名同秒并发创建仍唯一，已有目录拒绝覆盖；完整 task/meta/progress/result 留档。
3. 终止分类：success + provider/turn/budget/is_error/无 final/坏 JSON/非零/timeout/signal；普通 stderr 不失败；过程终止和产物验收独立。
4. 持久性：缓慢 mock 输出中途可读事件/工具结果，杀进程后数据可恢复；secret 脱敏同时完整保留普通长数据。
5. 快照：已有 tracked、staged、untracked、新增、删除、二进制、symlink；before/after 能重建内容、变更清单；禁止绝对越界、..、symlink 逃逸和元数据目录越界。
6. 预算：同时 reserve 的总额 <= cap；锁与结算可重复调用不双记；未知费用保留预留；历史费用列重算不改原件，不把估算当实际；坏/不完整账本保守处理。
7. 状态：JSON 可含引号/反斜杠/换行；PID 死亡/启动时间不符/心跳失联；native agent session 登记与未知费用。
8. 最终静态独立审查：读所有新实现，最小缺陷复现发主代理，修后重跑。

接口暂定：run_store 模块提供 create_run/event/finalize/snapshot/reserve/settle，agent_run CLI 可注入 mock command 与 records root。接收到实际接口后只调整适配层，断言保持独立。
