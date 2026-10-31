# 显式watch与默认generated排除的冲突

请在当前run_store.py拥有范围一并修一处同属快照契约的真实问题：r4-final-driver-local明确--watch/--allow-write Tools/agents/records/.../r4-final-work，但默认EXCLUDE_PREFIXES含Tools/agents/records，导致前后自动manifest/changes全空，两个源脚本只能靠你独立manifest救回。默认宽目录扫描排除历史记录是正确的，但用户显式指定的源文件/工作子目录不应悄悄失效。

请实现最小、明确的规则：新run中显式watch或allow-write落在默认generated前缀内时，可按明确范围覆盖该默认排除，并在meta写清实际排除/覆盖；默认全仓Tools/Tests扫描仍排除大量records/generated，.git/.aws等敏感parts和本run目录递归保护仍强制，用户显式--exclude-path仍优先。不能为一个指定子目录重新启用整个records前缀。新增/修改/删除/未跟踪文件必须实际快照，加入针对性的真文件测试。不要倒填旧run的空快照为已记录；旧独立manifest保留。

SDK EPERM问题先保留现场，本轮不要超范围编辑api_run.py。主代理已看源码：_stop_worker只有ProcessLookupError处理，PermissionError会从finally逃出、跳过快照/结算/result。最后事件已是timeout且worker有真实final回执，确需另开工具修复任务并真实强制异常回归，不以重跑偶尔通过掩盖。你先完成当前Git/显式watch修复和测试，主代理随后新run派发这一清理错误隔离问题。
