# ADR-20261028-A：最小代理运行契约（可开始实现）

状态：建议采用；2026-10-28；Astra Ultra 设计，主代理核验、Sol 实现。

## 决策

采用 `run_store.py`（标准库、记录/状态/快照/预算）+ `agent_run.py`（CLI 与 SDK 薄适配器）。保留旧入口为参数转发层；旧 Claude 历史只读。不要另建常驻调度器或第二份 progress 真源。

### 目录与派发

- 每次尝试用 `UTC时间_任务名_随机后缀` 独占 mkdir；不得覆盖。已有预登记目录可 attach，但必须尚未派发；重试必新建目录，写 `resume_from`。
- `task.md` 完整原文，`meta.json` 不可变请求/权限/输入契约，`progress.md` 单一可恢复进度，`events.jsonl` 实时正常事件，`output.md` 最终正常回答，`result.json` 最终结果；另存 stderr/长输出、before/after manifests 与内容快照。
- 保存 provider/transport/model_requested/effort_requested、独立 model_observed/effort_observed（无回执填 null）、agent/session/process ID、PID 启动身份、时间、允许写路径/命令、限时/轮数/预算、预计产物。请求参数不冒充回执。
- Native 的 register/start/event/finish 只登记，绝不通过 CLI 路由 Astra/Sol。主代理先登记再调用工具，把原生工具输入与结果写入记录；无法取得 token/cost 为 null。

### 状态和退出码

- `run_status`：planned → running → succeeded | failed | interrupted | unknown；未派发拒绝为 failed 并写 started=false/reason。这里 succeeded 只表示适配器正常成功终止、协议完整和产物存在，不表示产品测试通过。
- `verification_status` 独立：not_run | passed | failed | incomplete；需测试输出/断言可追溯，不能从代理文字“完成”或 CLI exit=0 推定 passed。
- succeeded 必须 exit=0、收到合法 final、final.is_error=false、subtype/terminal_reason 属于适配器明确白名单、必需 output 非空、没有解析损坏/执行越界。预算/轮数截止是 interrupted(reason=budget|max_turns)，不是成功。
- 超时/TERM/INT：保存已流出的事件，杀进程组并等待，finally 原子写 interrupted；启动失败/非零退出/协议错误为 failed。SIGKILL/崩溃无机会收尾：下一次 status 用 PID+启动身份检测失联，展示 unknown（不得猜测失败或通过）；reconcile 可标 interrupted(reason=owner_lost)。无 final 且无可靠终止原因为 unknown。
- JSON 损坏：落盘经过脱敏的原始行和解析错误，继续收集可能的后续事件以保留证据，但本次不得 succeeded。不要以“过滤掉坏行”修好结论。
- 外层退出码必须非零传播失败/中断/未知/测试失败；区分值可为 1失败、2用法/拒绝、3预算、124超时、130INT、143TERM。具体值可简化，零必须可信。
- 事务提交使用临时文件+os.replace；events 每行 flush；result 先落盘再宣布成功。状态面板从 records 汇总，不扫描完整命令行以免打印凭据。

### 权限与 DeepSeek

- 默认可用工具仅 Read/Glob/Grep，禁止 Agent/Skill/MCP/隐式插件和通用 Bash；禁默认 setting sources，strict-mcp-config 空配置。明确 model=deepseek-flash、effort=max，沿用既有鉴权且不打印/复制凭据。
- 第4轮通过显式 task contract 放行指定测试命令。Bash 的命令许可不是 OS 沙盒；Python/Swift/测试脚本能写文件，必须称“任务约束”。记录完整命令并对源码监视树前后做 manifest，不承诺强隔离。
- 如果 Bash 匹配只能做到前缀，禁止把宽泛 python3*/Tests/* 说成精确命令；优先窄的预置测试入口，其参数由 runner 固定。业务源码越界变化使验证 incomplete/运行 failed，不自动覆盖恢复（防止破坏其他代理改动）。
- 正常 JSON 事件先递归去掉 thinking/redacted_thinking 再落盘；敏感键 Authorization/api_key/token/password/secret 与 bearer/sk 形式统一脱敏，stderr 同样处理；不要保存环境全集、HTTP headers、完整 wrapper 代码。
- 流式读取 stdout/stderr，不能 communicate 完成后才保存。超时必须终止整个进程组。stdout 若无换行也需有有界缓存，超限记录协议错误，防止内存失控。

### 预算

- 旧 Claude 入口修复但本轮不发付费请求；要求显式 `--budget` 与可信账本预算上限/基准，禁止沿用旧 CAP/到期日或零费用默认值。
- 单个本地锁中完成“可信已结算额 + 所有在途预留额 + 新预算 ≤ 显式上限”的检查和预留，写成功后才发请求；结算在同锁内以 run_id 幂等写入，不做读旧累计后再加。
- 缺最终费用为 null，保留预留并冻结该计费域自动消费，直到显式对账。收到 SDK/CLI 费用与实际账单分层存放，DeepSeek CLI estimate 不能结算真实费用。成本未知不能自动转 0。
- 按 USD 余额自动分配预算与用户已授权的明确轮数/时限调用分开：前者遇 unknown 冻结；后者 DeepSeek 成本可持续记 unknown，不声称金钱封顶。用户已授权修复—复测闭环及必要合理重试，每轮新建记录写明理由、max-turns/timeout 和重试上限；unknown 不额外阻止该授权范围内的 bounded run。禁止无界重试或换账本绕过实际 USD 约束。

### 快照和恢复

- 修改前先快照显式允许写范围；需包括未跟踪、已暂存内容和不存在的允许新路径。manifest 保存 relpath/type/sha256/size/mode/symlink target；保留内容副本，可生成 before→after diff。
- 记录新增/删除/修改清单。源码监视范围和允许写范围分开；日志与 build/cache 输出从源码越界检测排除并明确列出。并行共享文件发生变化只报告冲突/需核对，不宣称自动归因。
- Native 自己记录 before/after，runner 支持统一命令补齐。恢复先读旧 task/progress/result/manifest 后新 run；会话恢复仅在 transport 支持且安全时使用，其余明确是重新提示恢复。永不自动重放有副作用工具。

### 离线验收（本轮先完成）

1. 同秒同名两次创建不覆盖；native 登记能显示未运行/运行/最终状态。
2. 假 CLI 正常 final、非零退出、错误 final、轮数截止、空结果、坏 JSON、无 final、超时和 TERM 均匹配状态与退出码。
3. 流式进度在子进程结束前可见；超时无孤儿进程；SIGKILL 后面板显示失联。
4. 人造 token/header/嵌套工具输出与 stderr 均脱敏，不留 thinking；非敏感正常输出/工具结果完整保留。
5. 同时申请两份越过预算的预留只能成功一个；重复结算幂等；unknown 保留/冻结；不发真实 API 验证。
6. 预存未跟踪文件修改、新增、删除、权限/链接变化可识别；只读任务源码越界不可判 passed。
7. status --json 可被 JSON parser 解析，含 native/CLI/SDK 和未知状态，历史账本明确标历史且不称实时余额。

## 备选与代价

只修旧脚本行数较少，但三套状态/恢复语义会再次分叉；采用两个小模块统一真源。完整调度框架、OS 强制隔离、自动副作用重放本轮不做。默认只读工具能减少风险，授权执行测试仍依赖清晰范围、快照和主代理核验；若将来要求强隔离，再单独增加系统沙盒或可丢弃工作区。
