后台 CLI 多结果协议架构已完成；实现和独立验收尚未由本代理验证。

完整决策见 decision.md；原始 transcript 的结构见证见 replay-witness.json。15 项实际流断言全部通过：连续 result_index 0→1、同 session/不同 UUID、已注册 local_bash 后台任务、匹配终结通知、末结果 origin.runId 一次性消费该通知、CLI exit 0、无未完成流或清理问题。旧 result.json 保持不变；本记录仅建议将该历史流复判为协议合法、provider succeeded，任务验收仍 pending。

建议状态机锁定 session 并永久保留协议错误；后续结果必须用连续 index 和匹配且未消费的 task-notification 来源认证；EOF 仍有后台任务或未消费通知为 incomplete/unknown。不能凭等待文字放行，也不能让后续 success 覆盖前序 provider 错误、上限或空报告。同 session 重复 init 合法。通知允许早于被延迟写出的前一结果；tool_use_id 两侧均存在时必须一致。

后台 failed/stopped 通知与 provider 失败分层：它们可触发合法诊断续轮，但必须单列任务失败状态，不能据 provider success 宣称测试通过。root 已采纳。CLI 累计估价只取末结果，不能相加；actual cost 与观测模型/强度仍未知。

已核对本地 CLI 2.1.310 内嵌 schema，保存二进制身份、精确字节偏移与摘录。没有执行 CLI/API/网络/App/UI，也没有重复 R4 测试。Sol 实现代理已收到全部可实施规则。

并发归属：本代理只写自己的 run。Sol 已开始编辑被本 run watch 的工具源码；如 runner after 快照报告 scope 变化，保留原始证据并结合 concurrent-source-ownership.md 独立归属。本代理没有修改生产工具或测试文件。

模型请求：gpt-6-astra / ultra；服务端模型与强度回执未暴露，observed_model/observed_effort/cost_usd 均 null。
