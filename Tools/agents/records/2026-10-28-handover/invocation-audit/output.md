# agent / API 调用与持久日志独立审查

审查日期：2026-10-28。审查角色：Sol Ultra 独立审查；任务登记的模型为 `gpt-6.1-sol / ultra`。范围以本目录 [task.md](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-handover/invocation-audit/task.md) 为准。

本审查代理仅做本地只读审查和纯离线表达式复现，没有发网络请求、调用 API、启动 app、构建或修改共享脚本/产品代码。只写本目录 progress.md 和 output.md。后半程按主代理补充要求，还只读核对了新 AGENTS.md、deepseek_probe.py 和主代理已完成的 smoke test 原始记录。凭据相关行在输出前已整行遮蔽，没有输出 key、token、认证值，也没有访问钥匙串取值。

## 结论

当前应沿用用户新指定的分工：Astra Ultra 负责架构，Sol Ultra 负责重要独立调查和审查，DeepSeek V4.1 Flash max 负责范围明确的简单任务。旧 Claude memory 中的 fable/opus 和额度优先规则是历史背景，不能覆盖当前要求。

项目同时存在三套入口。**当前 Codex 原生子 agent 已实际运行；DeepSeek 的受限 Read 冒烟测试已通过并经本审查核对原始证据；旧 Claude SDK 没有重调。**新 AGENTS.md 已规定统一留档要求，但旧入口尚无覆盖三者的统一完成状态、费用和恢复实现。最需要处理的三项是：

1. **旧 Claude API 台账累计相对自身费用列已经少算 $15.6422**。SDK 台账费用列合计为 **$148.7722**，最后累计列却是 **$133.13**；旧 runner 读后者来计算下一次预算。这是台账内部算术差额，不是实际账单对账结果。并行任务拿启动时的旧累计值回写，是可从实现及时间记录相互印证的原因。
2. **失败可以被当成成功结束**。api_run.py 对非预算类 `ResultMessage.is_error` 仍可能写 `finished`，处理到的运行错误也不会使进程返回非零；两个 DeepSeek 包装脚本以 `|| true` 吞掉子进程失败。
3. **现有 changes.diff 不能完整恢复代码**。它只是整仓库当前 `git diff`；未跟踪文件、已暂存内容和修改前快照均不在其中。阈值 B 任务档案甚至只记了 `(no repo changes)`，相关主要源文件当前却没有被 Git 跟踪。

这些问题不妨碍保留旧报告作为历史证据，但在修复前，不能把 `finished`、累计列、`changes.diff` 或旧 registry 单独作为“任务成功、预算可靠、代码可恢复”的证明。

## 路由与证据强度

| 入口 | 本地实际配置 | 已有证据 | 当前可以确定的边界 |
|---|---|---|---|
| Codex 主会话/子代理 | config 主模型 `gpt-6-astra`、effort `ultra`；默认子模型 `gpt-6.1-sol`、effort `ultra` | [config.toml:2](/Users/zyx/.codex/config.toml:2)、[config.toml:133](/Users/zyx/.codex/config.toml:133)；本轮 architecture/history/invocation-audit 的任务、派发元数据、实际进度和本报告 | 原生子 agent 已实际运行，配置和本轮派发符合 Astra/Sol 分工；模型请求参数与服务端独立回执仍须区分。主配置没有 `model_provider` 或 `model_providers` 自定义段，未配置把 Codex 模型路由到 DeepSeek 的 provider |
| DeepSeek，经 Claude Code | `~/bin/claude-ds` 设置 `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`、主模型 `deepseek-flash[1m]`、effort `max`；最后 `exec claude` | [claude-ds:2](/Users/zyx/bin/claude-ds:2)、[claude-ds:4](/Users/zyx/bin/claude-ds:4)、[claude-ds:9](/Users/zyx/bin/claude-ds:9)；本轮 [r3 events.jsonl:2](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-handover/deepseek-smoke-r3/events.jsonl:2)、[r3 result.json](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-handover/deepseek-smoke-r3/result.json) | 现已核实实际出站 `deepseek-flash`、`output_config.effort=max`，两次 HTTP 200，Read 和答案校验通过。只证明此受限诊断任务成功；后端精确版本 V4.1 不是该别名或回执单独提供的独立版本证明 |
| 旧 Claude API runner | `api_run.sh` 取 Anthropic 凭据、清除 DeepSeek base URL/auth/model 环境；`api_run.py` 默认 `claude-opus-5-5`，可传 `--model`；本地 SDK 版本 0.2.174 | [api_run.sh:5](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.sh:5)、[api_run.py:45](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:45)；19 次历史运行的 meta/result/output | 历史 Claude SDK 路由曾成功运行；本次未验证当前余额、服务可用性或旧模型别名可用性。把 Astra/Sol 名字传给此入口不会自动切到 Codex |

`claude-ds` 的认证赋值使用钥匙串命令替换，没有把认证值作为非空字面量写在该脚本里；临时 probe 包装脚本也沿用此方式。本报告只记录这一结构事实。

旧 `/private/tmp/deepseek-codex-check/` 现有内容只有 `probe.py`、`claude-ds-probe` 和 `sample.txt`。其中 [probe.py:7](/private/tmp/deepseek-codex-check/probe.py:7) 会打印请求中的 model/thinking/output_config/stream，[probe.py:28](/private/tmp/deepseek-codex-check/probe.py:28) 会启动一个最多 4 轮的工具任务。该旧目录没有持久保存的请求输出或结果日志，不能单独证明检查已通过。当前通过结论来自下面的项目内 r3 记录，本审查没有执行任何 probe。

### 本轮新诊断和协作规则的补充核对

主代理补充要求审查后，已只读核对 [deepseek_probe.py](/Users/zyx/Documents/GPXPointViewer/Tools/agents/deepseek_probe.py)、[AGENTS.md](/Users/zyx/Documents/GPXPointViewer/AGENTS.md) 及 r3 事件/结果/工具记录：

- [r3 events.jsonl:2](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-handover/deepseek-smoke-r3/events.jsonl:2) 和第 4 行的请求均为 `deepseek-flash`、`output_config.effort=max`、最大输出 2048；第 3、5 行 HTTP 状态均为 200。
- [r3 transcript.jsonl:3](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-handover/deepseek-smoke-r3/transcript.jsonl:3) 实际调用 Read 读取本轮 fixture.txt，第 4 行成功返回含随机校验标记的内容；第 55 行终态为 subtype=success、terminal_reason=completed、is_error=false、num_turns=2。答案 `total=17 / guarantee_pair=4 / marker=GPXPV_HANDOVER_20261028_K9` 与合成输入一致，CLI 退出 0。
- r3 result 的 `cost_usd=null` 与说明是正确的；`cli_reported_cost_usd=0.011012` 只能当 CLI 估价字段，**不能当作 DeepSeek 实际扣费或账单**。
- 首次 `deepseek-smoke` 保留了沙盒拒绝本地监听的失败，r2 保留了解析器 KeyError，r3 为独立新目录；没有把前次失败覆盖成成功。
- 新 probe 以独占创建 events/transcript 防止覆盖，用最多 4 轮、180 秒外层等待并杀进程组，限制 Read 工具、禁用 MCP/默认设置源并保留结构化记录；它声明自己是诊断工具而非通用 runner/计费器，表述正确。[deepseek_probe.py:32](/Users/zyx/Documents/GPXPointViewer/Tools/agents/deepseek_probe.py:32)、[deepseek_probe.py:95](/Users/zyx/Documents/GPXPointViewer/Tools/agents/deepseek_probe.py:95)、[deepseek_probe.py:114](/Users/zyx/Documents/GPXPointViewer/Tools/agents/deepseek_probe.py:114)。

没有发现会推翻本次 r3 通过结论的明显缺陷。可以顺手补强两点，但不需要为此重跑 API：其一，当前 pass 条件只检查观察到 Read 的 tool_use，未校验它关联的成功 tool_result、fixture 路径，也未直接把 HTTP 状态数组列入结果/判定；本次原始 transcript/events 已人工证实这些条件成立。其二，result.json 可以直接带上最终 subtype、terminal_reason、session_id，减少下次需要去 transcript 里找的步骤。[deepseek_probe.py:140](/Users/zyx/Documents/GPXPointViewer/Tools/agents/deepseek_probe.py:140)、[deepseek_probe.py:157](/Users/zyx/Documents/GPXPointViewer/Tools/agents/deepseek_probe.py:157)。此诊断不应被当作一般写代码任务的全事件持久恢复器：stdout 目前在子进程结束后才统一落盘，且刻意设置 no-session-persistence；它没有声称满足一般任务续跑能力。

新 [AGENTS.md:17](/Users/zyx/Documents/GPXPointViewer/AGENTS.md:17) 对启动前登记、unknown/null、过程日志、失败保留、唯一目录和文件前后快照的要求，覆盖了本审查的主要缺口；[AGENTS.md:28](/Users/zyx/Documents/GPXPointViewer/AGENTS.md:28) 明确旧包装器不能直接视为符合规则，结论准确。这里是规则已补齐，不能因此认为旧脚本实现也已经修好。本审查没有改动这些新文件。

## 持久记录现状

Claude 项目 memory 明确要求每个 agent/task/workflow/API 任务启动前登记目的、输入、产出和恢复方式，持续更新“已完成 / 正在做 / 下一步 / 中间结论”，完成后保存结果；中断和空结果不能被解释成没有问题。证据：[agent-logging-rule.md:11](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/memory/agent-logging-rule.md:11)、[agent-logging-rule.md:18](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/memory/agent-logging-rule.md:18)、[agent-task-registry.md:8](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/memory/agent-task-registry.md:8)。

审查时的清点结果：

- `saved-agent-results/api-runs/` 有 19 次运行，均保留 task/meta/transcript/output/result；7 次没有 progress，其中 4 次是早期运行，另 3 次是后续只读文档任务。最早 3 次没有 status。当前归档没有标记为 running 的 API 任务。
- 后续 3 次缺 progress 的运行是 `20261026_161738_deepseek-doc-r2`、`20261027_232342_deepseek-doc-r3`、`20261028_135558_deepseek-doc-r4`；对应的仓库 `Tools/agents/runs/<同名>/progress.md` 也不存在。历史日志确认 r2、r3 发生过进度/文件写权限被拒；不应假定改成相对 Write 规则后已经得到可靠恢复材料。[AGENT_LOG.md:431](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/AGENT_LOG.md:431)、[AGENT_LOG.md:457](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/AGENT_LOG.md:457)。
- 旧 `registry/TASK_REGISTRY.json` 有 44 个 Workflow：36 done、5 partial、3 not-started；它不含 API 或 DeepSeek 条目。8 个非 done 是历史生成结果，不能直接断言它们仍是当前待办，需要和历史完成/替代记录核对。
- `Tests/reports/` 有 23 份 Markdown 报告、22 份 stderr 日志，清点到的 Markdown 没有空文件；这些数量不是“所有调用均完整记录”的证明。两个 DeepSeek runner 没有生成中间进度、结构化最终状态、session ID、费用、完整事件流或恢复命令。
- 本轮新增的 [Tools/agents/AGENT_LOG.md:3](/Users/zyx/Documents/GPXPointViewer/Tools/agents/AGENT_LOG.md:3) 和 `Tools/agents/records/...` 已把任务书、派发信息和进度放回项目内，是合理的接手方向；当前完成状态和旧状态面板还没有接通。

## 逐项发现与最小修复

### 1. P1：并行累计丢账，且没有在途预算预留（已发生）

`ledger_total()` 取最后一个能解析的累计单元格，并不对费用列求和；每个任务在启动时读取一次 `spent`，结束时直接写 `spent + cost`，全程无锁和预算预留。[api_run.py:28](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:28)、[api_run.py:52](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:52)、[api_run.py:104](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:104)、[api_run.py:109](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:109)。

现有台账的首个明显分歧如下：

| 运行 | 启动与结束时间 | 本次费用 | 写下的累计 |
|---|---|---:|---:|
| tunnel-diagnosis-2 | 10-26 14:34:24 → 15:00:52 | $14.2185 | $19.64 |
| route-cache | 10-26 14:31:01 → 15:12:15 | $19.9711 | $25.39 |

两者均在旧累计约 $5.42 时启动，后结束的 route-cache 没有加上先结束任务的费用。后续 deepseek-doc-r2 与 map-sources 时间也重叠，再丢约 $1.41。证据：[LEDGER.md:10](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/LEDGER.md:10)、[LEDGER.md:14](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/LEDGER.md:14)，以及对应运行的 meta.txt/status.txt。

19 条费用相加为 $148.7722；[最后一行](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/LEDGER.md:23) 累计为 $133.13，差 $15.6422。当前静态 CAP 为 $197.5：旧算法会显示剩 $64.37，按费用列只能得出账面剩 $48.7278。这两个数都不是当前账户实时余额，也没有覆盖未知扣费、额度到期或 SDK 费用与实际扣费差异。

最小修复：先把费用列作为不可变事实重算累计；短期串行启动旧 API 任务。若要并行，必须在同一个锁内检查“已结算费用 + 在途预留预算”，原子预留后才启动，结算时释放预留并重算；只在结束时加锁仍不能防止多个任务同时花同一份余额。

### 2. P1：没有最终 ResultMessage 时把未知费用记为零（已有实例）

`final` 不存在时，cost/usage 被直接记为 0，然后仍追加到账本。[api_run.py:101](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:101)。现有 `20261026_143049_tunnel-diagnosis` 因 1 MiB JSON 缓冲溢出运行约 103 秒后失败，transcript 已有 13 次工具调用，但 [result.json](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/20261026_143049_tunnel-diagnosis/result.json) 记录 cost 0、turns null。这里的 0 是“没收到费用结果”，不能证明没有扣费。

最小修复：费用用 `null` / `unknown` 表示，保留运行预算或冻结进一步预算分配，直到人工对账；把“实际消费 0”和“无法得知消费”分开。SDK 提供预算字段，但它的本地类型说明是预算超出后终止查询，不能据此保证银行式精确封顶；[api_run.py:79](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:79) 对预算属性设置异常也不应静默忽略。当前安装版本确实支持 `max_budget_usd`，本次未发现该字段缺失。

### 3. P1：错误状态与退出码不可信（离线确认）

[api_run.py:108](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:108) 只把 Python 异常标成 error，把无 final 或文字含 budget 的部分错误标成 interrupted；其他 `final.is_error=True` 会标为 finished。脚本写完记录后也不根据 `is_error` 返回失败退出码。

本次从 AST 中单独取出该状态表达式离线求值，没有导入/运行 SDK：`is_error=True + maximum turns reached` 和 `is_error=True + provider error` 均得到 finished。当前 SDK 的 ResultMessage 本来有 subtype、terminal_reason、stop_reason、errors、api_error_status、permission_denials、session_id；旧 runner 只存了少量字段。SDK 明确把预算耗尽表示为 `error_max_budget_usd` subtype，但 runner 不保存 subtype，且只搜 result 字符串，result 缺失时同样可能误标。

DeepSeek 的失败路径则直接被 [run_deepseek.sh:29](/Users/zyx/Documents/GPXPointViewer/Tests/run_deepseek.sh:29) 和 [run_deepseek_dev.sh:28](/Users/zyx/Documents/GPXPointViewer/Tests/run_deepseek_dev.sh:28) 的 `|| true` 吞掉。上层看到报告路径/退出 0，不能知道 API、工具权限、轮数限制或进程是否失败。

最小修复：统一保存 `exit_code`、`is_error`、`subtype`、`terminal_reason`、`errors`、`session_id`，完成必须同时满足成功终止和有预期产物；用结构化字段区分 succeeded/failed/interrupted/unknown。始终先写出最终状态及日志，再返回非零退出码。错误或轮数/预算终止不能与完成共用 finished。

### 4. P1：changes.diff 不包含本次完整改动（已有实例）

`git_diff()` 只调用 `git diff`；运行前结果仅保存在内存，最终 changes.diff 写的是整仓库运行后的 diff，而不是本任务相对运行前的变化。[api_run.py:38](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:38)、[api_run.py:75](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:75)、[api_run.py:98](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:98)。已有脏改动及其他并行任务的改动可能被算进本次；新建未跟踪文件、暂存区变化不在默认 diff 中，原来的未跟踪文件即使被修改也可能让前后 diff 相同。

审查时 `git ls-files` 未包含 `GPXPointViewer/FillPlausibility.swift`、`GapFill.swift`、`Localizable.xcstrings`、`docs/fill-plausibility-design.md`。阈值 B 运行的 [changes.diff](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/20261028_132305_plausibility-threshold-b/changes.diff) 只有 18 个字符 `(no repo changes)`。因此脚本头部“API 改了什么代码，一字不漏”的承诺不成立。

DeepSeek 开发包装保存 before/after 两份 `git diff`，比单份 after 好，但仍有同样的未跟踪/暂存遗漏和共享工作区归因问题。[run_deepseek_dev.sh:13](/Users/zyx/Documents/GPXPointViewer/Tests/run_deepseek_dev.sh:13)、[run_deepseek_dev.sh:29](/Users/zyx/Documents/GPXPointViewer/Tests/run_deepseek_dev.sh:29)。

最小修复：对任务允许修改的文件建立运行前后内容快照、哈希和路径清单，明确记录新增/删除/修改；同时保存 base commit、工作区状态、暂存 diff、未跟踪清单。既有目录含大量未跟踪文件时，不能只补一条 git diff 选项就宣称具备恢复能力。独立 checkout/worktree 可以帮助归因，但不会自动带入现有未跟踪文件；迁移前仍需保存快照。

### 5. P2：所谓 resume 是重新提示，进程中断还可能丢失最后进度（实现确认）

api_run 的 `--resume` 只把旧 progress 和最后 8000 字 transcript 追加到一个新 prompt，没有使用 SDK 原生 session resume，也没有已完成工具操作的缓存。[api_run.py:57](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:57)。transcript 只写助手文本及工具输入的前 600 字，不保存工具返回、用户消息、完整 Write 内容、时间/事件 ID；即便最后 8000 字存在，也不一定含关键结论和已产生文件。

progress 的主要副本在仓库 `Tools/agents/runs/`，只有查询正常走出后才复制到外部归档；没有 `finally` 或信号收尾。SIGTERM/SIGKILL、KeyboardInterrupt 或进程崩溃可能留下永久 running，归档里没有最新 progress/result/output；续跑时虽然会尝试仓库路径兜底，但仓库目录一旦被清理就失去该依据。[api_run.py:64](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:64)、[api_run.py:82](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:82)、[api_run.py:93](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:93)。

两个 DeepSeek runner 连阶段进度和 session ID 都没有保存，不能从半途只输出最终文本的报告可靠恢复。它们还用“分钟 + 任务名”作为报告名，同一分钟重跑同一任务会覆盖原报告、stderr 以及开发 diff，违背“每轮保留不覆盖”的 [Tests/tasks/README.md:6](/Users/zyx/Documents/GPXPointViewer/Tests/tasks/README.md:6) 规则。

最小修复：每次启动使用唯一 run ID，以一个目录作为 progress 的唯一持久真源；调用开始前写 manifest，逐事件落地经过脱敏的结构化日志，完成/异常在 finally 原子写最终状态。保存 session_id 并明确支持的原生续跑；对重新提示式恢复写明“继续未完成工作，先核对产物，副作用操作不得盲重做”。同一分钟重跑不覆盖旧目录。对于无法捕获的 SIGKILL，由下一次启动/状态查询结合 PID、启动时间和心跳把遗留 running 转成 unknown/interrupted。

### 6. P2：只读权限是提示级限制，不能保护仓库文件（静态可触发）

api_run 的 READONLY_TOOLS 包含任意 `Bash(python3 *)`、`Bash(Tests/*)`、`open`、`pkill`、`cp -R` 等；DeepSeek 测试 runner 也放行任意 python3、xcodebuild 和测试路径命令。禁用 Edit/Write 不会阻止 Python 或已有脚本修改源文件、发网络请求或启动其他进程。[api_run.py:22](/Users/zyx/Documents/GPXPointViewer/Tools/agents/api_run.py:22)、[run_deepseek.sh:27](/Users/zyx/Documents/GPXPointViewer/Tests/run_deepseek.sh:27)。api_run 对 progress 目录还放行了通配 Write，范围大于提示里说的“只有这个进度文件”。

这并不是已经发现越权改动，而是现有工具权限无法兑现“不能改代码”的技术保证。最小修复：把只读测试任务放到独立、可丢弃的副本或受文件系统约束的工作区，对输出目录单独放行；按任务仅授予明确的测试入口。若仍放行通用解释器，文档应表述为“禁止改代码的任务约束”，不能把它当作文件系统只读隔离。调用工具参数/返回日志还应在落盘前脱敏，避免未来把钥匙串读取命令输出或认证头写入 transcript。

### 7. P2：DeepSeek 通用入口仍暴露已知不兼容工具，且缺少任务时限（历史失败与当前代码相符）

`~/bin/claude-ds` 的默认工具集合含 Skill、Agent、NotebookEdit、WebFetch 等，未自带 `--strict-mcp-config`。历史已有使用 Skill 后 422 `unknown variant tool_definition` 的明确失败；专用测试/开发 runner 则显式缩小了工具集合并带 strict-mcp-config。[claude-ds:11](/Users/zyx/bin/claude-ds:11)、[run_deepseek_dev.sh:5](/Users/zyx/Documents/GPXPointViewer/Tests/run_deepseek_dev.sh:5)、[历史 AGENT_LOG.md:442](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/AGENT_LOG.md:442)。直接运行 claude-ds 与专用 runner 的兼容保证不同，不能把一方通过推广为所有工具可用。

两个专用 runner 都没有 `--max-turns`、单次预算或外层超时；长任务没有统一停止条件或费用记录。最小修复：建立一个经 smoke test 的最小工具集合，以显式参数扩展；保留 strict-mcp-config，避免默认加载 Skill/Agent。为每项任务明确轮数和墙钟时限，费用字段可以是 unknown，但不能假装已经核算；模型别名和 effort 同时写入 manifest，出站字段单独留证。

### 8. P2：登记簿与“正在运行”面板覆盖范围不同，会漏掉新 Codex 任务（实现确认）

旧 [update_registry.py:23](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/registry/update_registry.py:23) 只扫描 Workflow journal；单 Agent、API、DeepSeek 依赖人工日志。其完成判定主要是同 key 有 result 或手工 done 标记，并不证明子结果内容成功；注释称会识别完成 output，但实际输出扫描只做复制，最终覆盖由 done.json 决定。[update_registry.py:35](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/registry/update_registry.py:35)、[update_registry.py:51](/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/registry/update_registry.py:51)。

[status.sh:9](/Users/zyx/Documents/GPXPointViewer/Tools/agents/status.sh:9) 把 status.txt=running 的旧 API 目录直接计为运行，不检查 PID；若被杀后无收尾会永久显示。进程扫描规则也没有接入 Codex 子代理或本轮 records。它会按类型+名字合并同名任务，不能用任务数反推出独立 run 数。JSON 输出只对 detail 的双引号做了部分转义，路径/名字中的反斜杠、换行等不能靠 printf 保证有效 JSON。[status.sh:33](/Users/zyx/Documents/GPXPointViewer/Tools/agents/status.sh:33)、[status.sh:72](/Users/zyx/Documents/GPXPointViewer/Tools/agents/status.sh:72)。

最小修复：把新项目内每个 run 的 manifest/result 作为统一登记源，关联各路由自身的 session/task/process ID；状态面板显示来源和“状态未知/已失联”，对 Codex 采用其可用状态接口或主代理保存的结果。用标准 JSON 序列化输出；旧 Workflow registry 保留为历史来源，不能兼任当前所有任务总账。

## 建议执行顺序与验收

本次未修改上述实现。建议按以下最小闭环修复，不必先重建一个大调度系统：

1. **先保住事实和现有产物**：保存当前工作区允许范围内的完整快照；把旧台账费用列和未知费用单独导出核对；新任务全部使用项目内唯一目录，含 task/meta/progress/output/result。不要继续依赖旧累计列做预算判断。
2. **修复错误状态和持久记录**：取消吞错、保存结构化终止原因/退出码/session，异常与中断也有最终状态；使用唯一目录，避免覆盖；progress 直接写持久目录。
3. **修复预算一致性和改动快照**：串行是最小风险做法；确需并行时引入锁与预算预留。对所有允许修改文件保存前后快照，而不是只存 git diff。
4. **收窄路由并接入状态显示**：保持 Astra/Sol 使用 Codex 路由，DeepSeek 使用单独兼容入口；旧 Claude API 只保留历史兼容用途。把实际模型/effort、工具集合、时限、恢复方式写入每项任务记录。

本轮主代理的统一 smoke test 已覆盖请求 model/thinking/output_config（未记录认证头）、一次确定性的工具读取、完成与退出码、最终输出和可识别会话 ID。后续保持这一验收口径即可，失败记录继续保留。当前已实测的是 `deepseek-flash` 与 effort=max 的出站映射；“V4.1”是用户指定的产品版本称呼，精确服务版本不能仅从别名推断。无需为本审查重复调用付费 API。

后续若实施修复，必要的纯离线回归只有几项：两个并行任务不能覆盖累计或重复花同一预算；无最终费用不能记 0；provider/预算/轮数错误不能标成功；杀进程后能识别失联并继续未完成工作；同分钟重跑不能覆盖；修改未跟踪文件也能从快照恢复。这些检查应使用 mock/合成数据，无需为了验证包装逻辑重复付费调用。

## 本次验证方法和限制

- 直接读取指定脚本、任务说明、Claude 项目 memory、AGENT_LOG、registry、19 次 API 运行的非敏感元数据和文件清单；另核对主代理新建的 AGENTS.md、deepseek_probe.py 及 r3 完整证据。本审查没有执行 api_run.sh、claude-ds、任一 probe 或 DeepSeek runner。
- 用 Python AST 只提取 `ledger_total()` 和终态表达式，在内存中复现现有台账计算与错误分类，没有执行文件中的 main/query。
- 用只读 `git ls-files` / `git status --porcelain` 核对快照遗漏；没有切换分支、提交、暂存、恢复文件或改写 Git 状态。
- 本轮 Codex 原生子 agent 和主代理 DeepSeek 受限任务已有实际运行证据；旧 Claude SDK 当前远端可用性没有重测。精确后端版本、实时额度和实际账单没有验证；相关历史 memory 只作为规则和过去行为的来源。

共享脚本、产品代码和原始 Claude 记录均未被本次审查改动。完整发现已落盘，后续可从本报告和 progress.md 继续。
