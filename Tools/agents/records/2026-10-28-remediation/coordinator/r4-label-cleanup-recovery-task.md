# 最后一次窗口偏好清理失败：有证据的单键恢复

模型Sol Ultra。用户要求全部问题修复，所有派发执行结果留档。本次用户已允许DeepSeek本项目复测必要文件。不得再次重跑11组、数值、三语或标签截图（新标签PNG root已实际查看通过）。

刚才DeepSeek run `deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c` 的新app标签sec2和cleanup自动检查全过，source intact、其他偏好typed-equal，主代理标签像素通过。但helper精确窗口恢复拒绝：final frame为`240 60 960 800 0 0 1440 903 `，不在baseline/legacy/成功tracker列表。Tracker观察place0回显1320×860时Preferences.snapshot遇到preference file changed while reading，未纳入列表。不要抹去失败，也不要把未知值加入通用白名单。

请独立检查该run日志、快照（只在本地，禁止向外API输出完整prefs/进程列表）、原visual helper恢复/FrameTracker与相关UI源码，确认这次仅窗口frame变化。实现一个新的、范围严格的单次恢复入口 `r4-label-cleanup-recovery/driver.py` 与必要小测试：固定失败run/hash、精确本次观察的prefs after SHA a6af0275f47b1c1adb624817ac488cf7dc68a1e147cce1307997bd6868c89bf1及唯一键值；证明前后其他keys相同、原始baseline SHA 54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8；进程guard无任何GPXPointViewer，CFPreferences+disk稳定且current exact与失败run快照相同后才单键defaults恢复。漂移、并发、其他key差异必须拒绝；不整份覆盖。可复用原恢复实现的函数，以这次固定可审阅receipt作为唯一allowed_after，不改旧helper/旧run。

CLI仅run，GPXPV_AGENT_RUN_DIR新唯一目录、先验证不写旧目录、原始task/meta必有，结果含命令日志/前后快照/单键变化与所有其他值保持/原hash还原。不启动UI、不重拍、不做网络，恢复不需桌面前台。返回summary供DeepSeek只读简报，偏好内容不得发送外部。明确将本次窗口恢复与已通过标签阶段拆开接受。

只允许写新r4-label-cleanup-recovery目录及本native run。你不可实际改偏好、启动app、调用API或build；真实动作留给root独立核验后的DeepSeek一次后台命令。当前DeepSeek还可能在报告，等root通知API已终结再记录该run最终result hash（source/summary/after快照可先固定）。保留所有诊断/命令/失败/测试，完成finish pending，尽快冻结。此任务不扩大产品或基础架构。
