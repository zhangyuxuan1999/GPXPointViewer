# DeepSeek R4 派发与权限补充

用户已授权修复代理工具后让 DeepSeek 完成 R4。此轮用 deepseek-flash / max，最多 180 turns、5400 秒，一次有界运行；费用未知保留 null。不是 USD 余额授权，不改旧账本。无公共路网测试授权。

完整主任务见 Tests/tasks/2026-10-28_loose_ends_threshold_r4_codex.md。执行顺序优先源码离线 synth + 四项自测，然后 UI/手工钩子。只有此轮一个 UI 客户端；正式 app 不关闭、不覆盖。始终 GPXPV_APP=/Applications/GPXPointViewer.app。

允许在 Tools/agents/records/2026-10-28-remediation/r4-work/ 创建本轮 Python 执行脚本 driver.py；通过 python3 该精确脚本运行任务书已列命令、准备数据、控制 Tests/ui/app.noindex 副本、读取只涉及本任务的源码/文档/日志。不要调用任意外部网络、安装软件、访问凭据或运行别的 agent。Python 能操作文件，命令授权不是 OS 隔离；任务边界及源码前后快照用于复核。

driver 中子进程必须记录 argv、开始/结束时间、退出码、完整 stdout/stderr 到本 run artifacts 或 r4-work/logs，终端可只输出摘要。每阶段更新本 run progress.md。长任务必须有截止时间；失败也要 cleanup。脚本可以使用 pathlib/subprocess/ui.send 等正常 Python 功能；不能修改生产源码、现有脚本或任何期望值以通过测试。

禁止用 shell 管道 tail 的退出状态当测试结果；不得因单条脚本失败就跳过所有独立检查。脚本返回退出 0 但 FAILS 非 none，仍算测试失败。API 正常完成与 R4 验收分开。

截图生成后报告 PNG 的绝对路径；最终视觉验收由主代理读取图片完成。DeepSeek 不需要把图片送到不支持视觉的 API，也不能将未读到的图片标为通过。

结束给完整逐项结果、证据路径、app/source 版本、实际网络/回放计数、问题分类、清理与偏好恢复情况。所有未完成项明确列出。禁止编造“已全部通过”。
