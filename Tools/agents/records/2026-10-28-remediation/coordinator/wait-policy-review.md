# Root等待策略核验与修复

已阅读Sol完整报告、本地CLI2.1.310一级片段、真实Blocked原文及正常安全shell结果。接受allowedTools为追加预授权而非硬白名单的结论；未将只读偏差臆称危险逃逸。TaskOutput已移除，当前恢复采用固定受控命令和正式完成通知，不新增Monitor或工具权限。

Root已将禁止短sleep/waitsecs绕过阻止、完成前不得推进依赖阶段的规则加入通用DeepSeek system prompt，并采用Sol文档修订。变更仅agent_run.py提示字符串与README文字，前后副本/patch/hash见wait-policy-fix/。

原最终R4发现偏差后已身份核验安全停止；11/11 UI实际通过单独接受，整体interrupted/incomplete保留，synth部分输出不冒称通过。恢复由另一Sol实现，仅新run承接未完成阶段并继承最初prefs/PID。

改动后root完整离线工具86/86通过，exit0、28.157秒；证据commands/20261029T020109_wait-policy-tools-independent_14128fc8。该离线验证不代替新的DeepSeek真实恢复行为验收。
