# 代理留档修复与第4轮复测闭环（草稿，R4未完成）

当前产品修复已写回；最终R4剩余阶段正在执行，不能把本草稿视为验收通过。

## 修复与证据

| 范围 | 修复内容 | 证据 |
| --- | --- | --- |
| 调用/留档 T1–T11 | 并行预算预留与结算；未知费用null；唯一任务目录；实时事件和完整快照；真实终态/退出码；DeepSeek自己的日志权限；Git辅助元数据限时；进程身份安全和有界清理；结构化轮次/预算上限不误标一般失败 | [最终工具86/86](final-tools-verification.md)，[T9](git-metadata-review.md)，[T10](cleanup-independent-r2-summary.md) |
| P1/P2 | 全部还原精确基线、重复点多重集与修改依赖、后台回调归属/修订检查 | state-correctness native run及root48/48 |
| P3 | GPU时间/空间颜色缓冲不可变成组发布，在途版本保留到command完成 | metal-correctness native run，Apple M4实际17/17 |
| P4 | 显式段身份、真实邻接、同段检测/编辑/导出、缓存draw runs和QuickLook断笔/孤点/预算 | [核心/QuickLook](p4-core-review.md)，[GPU渲染](p4-render-review.md)，[独立业务审查](workflow-independent-review.md) |
| 改时覆盖 | 只保留连续出口尾链，交还未覆盖前缀给既有插值；两处实际长缺口消除且精确还原 | risk-audit / retime-design / segment-workflow-recovery；最终§6仍待验 |
| UI/本地化 | 英德中段侧栏布局调整；四条新字符串三语翻译 | [翻译](l10n-review.md)，真实最终截图仍待主代理像素审核 |
| 多段测试合同 | 四例旧扁平语义改为独立逐段真值；其他110例及125题基线不变 | [独立真值](synth-truth-review.md)，[8文件实际迁移](synth-migration-applied-review.md) |

## 构建与整合

`product-integration-applied.json`记录57个文件的原hash、最终hash、模式和体积；根目录写回前核验旧基线，未覆盖外来修改。`post-integration-source-check.json`无漂移。

三目标Release构建成功，记录 `commands/20261029T010833_final-release-build_481dea6f/`。临时构建目录与根工作区50输入一致；`final-prebuild-source-manifest.json`因慢文件读取实际于构建后完成，其文件名不代表构建前检查时刻。整合计划在写回前已校验变更源，后续50输入复核无漂移。完整bundle38文件见 `final-build-bundle-manifest.json`。

实际app：`/private/tmp/gpxpv-remediation-build/Build/Products/Release/GPXPointViewer.app`。
可执行文件 SHA256：`445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`。

## 最终R4（pending）

DeepSeek Flash/max run：`../deepseek/20261029T011600.159549Z_r4-final_fa1fd007/`。任务完整归档，最多220轮/7200秒；只允许固定driver和项目必要读文件。正常工具调用/输出、阶段命令/退出/JSON/PNG分别保存。

待填写：11组UI、114合成、125题录音基线、51自测、§2–6、文档检查、三语和双路像素、偏好/正式进程清理，最终源与bundle完整性。

## 失败记录和结论边界

原DeepSeek基线§6失败保留；第一次B实现容量失败后以新run恢复；一次DeepSeek派发被自动审批拒绝并未发出API，用户后续明确授权仅项目复测文件；旧R4准备由本地Sol接管不重复调用。八文件合成迁移真实CLI到轮次上限，虽实际变更已核验接收，原failed记录仍在。审查run因并发owner变更的保守scope警告保持原failed/incomplete，独立归属证据确认实质审查通过。

T10主代理初次测试包装脚本缺main guard造成multiprocessing启动错误，已保留并修正；进程清理尝试自动审批拒绝后未发送信号，子进程自然结束且只读核实消失。后续独立81/81及最终86/86通过。测试环境一次文件读取OS60失败保留，不当作已通过。

费用、未暴露的服务端模型/强度回执记unknown/null；CLI估算不是账单。真实DeepSeek路径已调用；旧SDK服务只做离线mock/控制进程验证，不冒称联网验证。没有安装或覆盖正式app。

## 日间恢复与T12补充（仍pending）

原最终run `20261029T011600.159549Z_r4-final_fa1fd007` 的11/11 UI已由root验收，详见 `r4-final-partial-review.md`。它因收到CLI等待Block后仍短sleep轮询被root按启动身份安全SIGINT中断，synth部分结果未算通过，原状态仍interrupted/incomplete，清理confirmed、源码未变。

Sol独立核验CLI 2.1.310的allowedTools为预授权，不是硬白名单；TaskOutput已移除。root采用正规后台完成通知策略，将禁止短sleep/waitsecs绕过限制加入统一提示，并精确化工具README。修改后86/86再次通过，最新源hash/证据在 `final-tools-verification-r2.md`，源码及文档前后patch在 `wait-policy-fix/`。

Sol恢复helper由root独立14/14验收，新DeepSeek `20261029T112901.777425Z_r4-remaining_d3ab729e` 只运行剩余11阶段，原prep与11UI均明确imported/origin，不重复计数、不重建最初prefs/PID基线。日间恢复原build hash仍一致，当前偏好另存 `resume-20261029-daytime/`；最后清理差异待核对。

项目所留同样“Selected model is at capacity”报错来自原Sol业务整合run，表示当次模型服务未能提供容量；原failed/partial保留，随后仍按Sol/ultra恢复完成，未静默换模型。不能把容量报错当成项目测试失败或据此推断API余额。
