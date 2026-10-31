可选字段协议已一次收口，最终建议见 decision.md。

本次仅完成架构与一手 schema 核对，没有改生产源、执行 API/CLI/App/UI 或重复产品测试。模型请求 gpt-6-astra / ultra；服务端模型/强度、token 与费用回执未知。

核心为三个独立谓词：合法遥测接纳、唯一历史任务关联、完整后台续轮认证。run_id/task_type/tool_use_id/is_backgrounded 缺键合法；识别的 task 帧仍须非空同 session/task_id；显式 null/错类型/空标识仍失败。其他合法 task_type 字符串只作辅助，不自动认证。

通知使用全部历史 start（含已终结）计算唯一候选；双方有 run_id 必须相等，缺 run 仅可弱匹配，不能补造 start 身份。孤立、歧义、重复、显式 tool 冲突仍失败。只有完整 local_bash、显式 True、start/notice 相同非空 run_id 才认证续 result。

EOF 义务按所有显式后台 True 独立计算，即便缺认证字段也不能忽略：未终结或未被认证结果消费时，成功候选降为 unknown。缺后台标志或明确 false 的辅助事件可与普通 single success 共存，但不能为多 result 背书。

设计已发送 root/实施者/审查者。实施者表示 r4 已按此落地，审查者已准备 38 例可选字段矩阵；这些是对方的进度回执，不冒称本代理已验证其实现或测试通过。完整历史匹配边界与 20 行预期矩阵在 decision.md，执行归其他任务独立留证。
