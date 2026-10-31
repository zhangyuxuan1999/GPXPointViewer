# 留档收尾的Git元数据不能无限阻塞

模型GPT-6.1 Sol / ultra。当前R4 final driver native run已完成文件快照，但finish中的`git status --porcelain=v1 -uall`曾阻塞超过1分钟，result迟迟未生成；后来自行返回。另B的event等待现象已经恢复，尚无证据证明同一原因，不要把它们合并成已证实死锁。

主代理源码核对Tools/agents/run_store.py snapshot的5个Git subprocess.run没有timeout，且扫描整个含大量历史记录的工作区。这是实际运行暴露的留档可用性缺陷：文件清单已经完成时，辅助Git信息不能无限挂住结果收尾。

只拥有Tools/agents/run_store.py、Tests/agents/新增/必要test_run_store.py回归和Tools/agents/README.md对应说明。其他工具、产品、R4脚本不改，不运行模型/API/app，不另派agent。新唯一run为执行记录；完整任务、命令、失败、正常输出、前后快照与最终patch必须保存，finish acceptance pending。

目标：
1. Git元数据收集有明确短总时限（建议总预算≤15秒，每命令≤5秒），错误/timeout记录精确argv、退出/超时、实际耗时和正常部分输出；不可谎报Git干净/成功，也不可丢文件manifest或把未知当空diff。
2. 默认避免无关巨大agent records导致全仓扫描，可将status/diff/staged/untracked限定watch路径，但先核对既有snapshot契约与测试；head仍全repo。不得为提速漏掉watch中的未跟踪/已删除/暂存文件，不改.gitignore或.git配置。关掉本次Git调用的optional locks/fsmonitor等可选缓存副作用可以考虑，需说明依据。
3. 无git/非repo/卡住Git不能破坏已完成的文件快照/变化清单和provider终态；Git为附加证据，其失败明确写git.json与日志。
4. 如需超时终止，只终止该次自身启动的Git进程/子进程组，不碰其它Git或app。用模拟挂起Git与子进程做快速有界反例；现有55项保持，补新针对性回归。
5. 首轮before snapshot若仍旧实现较慢，记录并等待，不用全局kill。实现后保存精确自身文件hash和完整测试输出。准备任务run的旧result不改写，这个缺陷独立记录。

重要：代码最小、失败保守；不要把本任务扩成全新日志框架，也不要因为Git metadata超时而把合法任务的真实provider成功改成失败，但验收能看到附加证据不全。
