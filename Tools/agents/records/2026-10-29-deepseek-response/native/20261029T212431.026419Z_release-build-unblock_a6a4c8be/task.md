# 单次Xcode协调读取绕过开关
GPT-6.1 Sol/ultra。前轮只读诊断证明本机xcodebuild在DVT NSFileCoordinator等待工程读取，尚未编译。本机反汇编与man支持单进程参数-SynchronizeWithICloud=NO。完整证据前run release-build-diagnosis，不复制猜测。
仅允许改Tools/build_release.py，必要时本run artifacts中新mock。产品源码冻结，不动。新增显式命令开关 --no-icloud-coordination，启用时向xcodebuild argv加入 -SynchronizeWithICloud=NO；默认保持原行为。记录requested选项于build-command.json，help说明仅进程级userdefault，不改全局defaults、不得用defaults write。不要另开真实build、kill任何进程或重跑已过14harness，root处理owned中断/新构建。
仅用mock或静态精确argv检查此新增选项有/无两支，保存实际命令/输出/退出/源码前后hash、说明之前阻塞无编译事实，必要phase event。允许root后续马上使用一次新build。不要网络/API/安装/用户偏好。完成finish succeeded/pending，报告最终sha。文档精确一句命令交root，不自行写README避免并发。异常/旧记录保留。
