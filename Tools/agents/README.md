# 代理调用与留档

项目协作要求见 [AGENTS.md](../../AGENTS.md)。统一入口是 `agent_run.py`，记录默认写到 `Tools/agents/records/` 下带 UTC 微秒和随机后缀的唯一目录。旧 Claude 账户目录只读保留。

## 模型与执行入口

- 架构：原生 `gpt-6-astra` / `ultra`。
- 重要实现、调研、独立审查：原生 `gpt-6.1-sol` / `ultra`。
- 步骤明确的复测：`deepseek-flash` / `max`，调用已有 `~/bin/claude-ds`。请求参数、CLI 回执与供应商底层模型证明分别记录。

原生代理先注册，再调用 collaboration 工具，把原文任务、补充消息和返回的 agent ID 保存下来：

```sh
python3 Tools/agents/agent_run.py init NAME TASK.md \
  --provider codex-native --model gpt-6.1-sol --effort ultra \
  --watch GPXPointViewer/FILE.swift --allow-write GPXPointViewer/FILE.swift \
  --project-index Tools/agents/AGENT_LOG.md
python3 Tools/agents/agent_run.py bind RUN_DIR --agent-id AGENT_ID
python3 Tools/agents/agent_run.py event RUN_DIR --type progress --json '{"completed":"检查输入","next":"执行验证"}'
python3 Tools/agents/agent_run.py finish RUN_DIR \
  --provider-status succeeded --acceptance pending --output RUN_DIR/output.md
python3 Tools/agents/agent_run.py verify RUN_DIR --status passed --evidence REVIEW.md
```

`succeeded` 只描述代理执行正常完成；独立验收单独保存，不能覆盖原执行结果。原生工具未暴露的 token、实际费用和服务端模型回执保持未知。原生代理执行的命令及 stdout/stderr 仍需代理自行存盘；登记器不会自动截获 Codex 会话里的全部工具。

DeepSeek 使用有截止时间和轮数上限的运行器：

```sh
python3 Tools/agents/agent_run.py deepseek NAME TASK.md \
  --max-turns 60 --timeout 1800 \
  --watch GPXPointViewer --watch Tests/ui \
  --allow-command 'python3 Tests/ui/EXPLICIT_TEST.py' \
  --project-index Tools/agents/AGENT_LOG.md
```

`Tests/run_deepseek.sh TASK.md ...` 与 `Tests/run_deepseek_dev.sh TASK.md --allow-write PATH ...` 转发到同一运行器，保留真实非零退出码。默认不暴露 Bash；传入 `--allow-command` 后会开放 Bash 工具，并把所列命令模式加入 CLI 预授权规则。CLI 自身仍可自动批准内置的安全只读 Bash 命令，因此 `--allowedTools` 不是只准所列命令运行的硬白名单。`--permission-mode dontAsk` 拒绝需要询问的操作，`--safe-mode` 关闭自定义扩展；二者都不取消 CLI 的正常内置权限判定。写入路径必须显式授予。当前 run 的 `progress.md` 和 `artifacts/` 自动授予记录权限，绝对路径通过提示和 `GPXPV_AGENT_RUN_DIR` 传入。插件、MCP、Skill 和再派发 Agent 默认关闭。

CLI 的明确 `error_max_turns` / `error_max_budget_usd` 或对应结构化上限原因记为 `interrupted`，即使子进程以 1 等正数非零退出；原始退出码仍保留。普通非零、子进程信号退出、runner/协议/API 错误不因此变成上限中断。供应商完成、清理结果和任务验收仍分别记录。

CLI 的 `result` 是一轮的结果。后台命令可以先产生等待报告，再在完成通知唤醒后产生下一轮报告；runner 持续读取到进程退出和流结束，最后一轮的报告才写入 `output.md`。单结果兼容旧格式；多结果必须锁定同一非空 session，`result_index` 从 0 连续递增且每条结果有不同 UUID。每个续轮还须用 `origin.kind=task-notification`、`producer=session-task` 和 `runId`，消费一个已由 `task_started` 登记、随后终结且尚未消费的通知；task ID、session 必须匹配，start 与通知都提供相同非空 run ID，双方都有 `tool_use_id` 时也必须匹配。只有完整的 `is_backgrounded=true`、`task_type=local_bash` start 可为续轮提供认证。同 session 重复 `init` 不清空状态；通知先于前一结果输出的合法竞态也允许。

`is_backgrounded=false` 的 `local_bash` 前景任务也会产生通知，身份与通知同样登记并校验，保存到 `foreground_tasks`。省略可选 `is_backgrounded` 的任务另存 `unqualified_tasks`，继续匹配通知；这两类不授予后台续轮权限，也不列入 EOF 后台未完成条件。只有显式 `true` 可授权后台续轮。缺少旧版可选字段仍兼容，但显式存在的 `is_backgrounded` 必须是布尔值，`session_id`、结果 UUID 或 `result_index` 不能是 `null` 或错误类型。

任务辅助事件的 `session_id`、`task_id` 仍须非空且属于锁定 session；可选 `run_id`、`task_type`、`tool_use_id` 缺键合法，存在时必须是非空字符串。通知依据同 session/task ID 在全部历史 start 中唯一匹配，双方都提供 run ID 时必须相等；缺 run ID 的弱匹配不补造缺失字段，也不授予续轮认证，`notification_match` 明记 `weak`/`strong`。已终结 start 也参与候选匹配，避免重复通知被错误转给新任务。同一已知非空 run ID 不能对应不同 task，缺 run ID 的不同 task 可以并存。显式后台 `true` 即使缺 run ID/type，也保留 EOF 完成/报告义务：任务未终结或通知不能由已认证结果消费时为 `unknown`。

无关联重复结果、跨 session、序号缺失/重复、重复通知和被后续成功覆盖的错误结果均失败。流结束仍有后台任务未终结，或通知缺少对应结果时记 `unknown`；超时、信号和明确上限仍按原规则记中断。后台通知的 `completed`、`failed`、`stopped` 都是合法唤醒来源，任务失败另列 `background_task_failures`，不冒充供应商失败或任务验收通过。`result_count`、`turn_results`、`background_tasks` 与 `background_incomplete` 保留关联证据，验收保持独立。最后一条 `total_cost_usd` 是 CLI 累计估价，保存为 `cli_reported_cost_usd`，不把逐轮累计值相加；`usage` 保留末结果原口径，实际 `cost_usd` 仍为 `null`。

任务中的命令限制与写入清单必须遵守，并由 transcript 和前后快照独立验收；CLI 内置的安全命令自动授权不能视作额外任务授权。当前配置**不保证所列命令以外的 Bash 都被拒绝，也不是 OS 文件系统隔离**。授权 Python 或 shell 时尤其要限定任务并检查源文件前后快照。生成物排除清单写入 meta；额外排除用 `--exclude-path`，不能排除为了审查而必须监控的源码/期望值。

长命令使用有截止时间的前景调用，或 `run_in_background` 后等待 CLI 完成通知，再用 Read 读取真实结果；收到完成前不启动依赖阶段或宣布完成。不得在等待被阻止后改用短 sleep、`waitsecs` 或改名等待器轮询。通知不可用时如实报告未完成，由宿主检查。2026-10-29 本机 Claude Code 2.1.310 已移除 TaskOutput；无需为一次命令完成而扩大 Monitor 权限。该版本的本地证据与一次真实偏差保存在本批次 `native/20261029T014901.614529Z_cli-safe-command-audit_8c0181fb/`，恢复任务必须另建记录，不能覆盖原中断。

## 留档与恢复

每个 run 包含完整 task/prompt、meta、command、progress、正常事件与工具结果、stderr、输出、结果、前后文件快照与变化清单。快照覆盖监控目录中的未跟踪、暂存、新增、删除、符号链接和文件权限；差异不自动归属于某个并发代理。凭据和内部思考内容被移除，正常输出不因长度而截掉。

文件 manifest 和新增/修改/删除清单先持久保存，Git只作附加证据。Git进程等待总预算12秒、单条最多3秒；超时只终止本次新建的独立进程组，清理等待另限每次0.2秒。每条精确argv、起止/耗时、真实退出码、timeout/skipped/unavailable及正常部分输出保存在 `snapshots/<label>/git.json` 与对应 `.txt`；`_meta.complete=false`明确表示证据不全，不能把空/缺失日志当干净diff。缺Git、非repo或Git超时不丢文件manifest/changes，也不把真实provider成功改成失败；独立验收须查看这些不完整证据。持久写盘时间与操作系统创建进程的延迟不冒称硬实时保证。

status/diff/staged/untracked按watch的literal路径采集（包括已删除路径），head仍取仓库HEAD。每次Git禁用optional locks、fsmonitor与untracked-cache，仅作用于子进程，不改.git配置/索引；diff禁用外部diff/textconv。没有watch时明确跳过四种全仓扫描。默认宽范围扫描继续排除历史records和其他默认生成物；新run显式watch或allow-write指向默认排除前缀内的具体源文件/子目录时，只对该明确范围启用覆盖，并将 `default_prefixes/user_prefixes/explicit_overrides` 写入meta。敏感parts、本run目录递归保护和用户 `--exclude-path` 始终优先，指定一个work不会启用整个records；旧run缺少覆盖字段时保持其原排除规则，不倒填历史空快照。混合宽watch与显式子目录使用分别有界的Git作用域，避免Git排除路径覆盖明确源目录，也避免枚举无关历史记录。

错误结果、非法协议、空报告和超范围改写不能算成功。超时、轮数上限、预算上限和信号中断单列；没有终结回执为 unknown。进程身份含启动时间，旧 PID 被复用不会变成运行中；原生任务需更新活动事件。运行状态：

```sh
Tools/agents/status.sh --json
```

恢复创建新目录并关联旧轮次，必须给出恢复计划，先核验旧 task/progress/result 和既有副作用：

```sh
python3 Tools/agents/agent_run.py deepseek RETRY TASK.md \
  --resume OLD_RUN --resume-mode context --recovery-plan RECOVERY.md \
  --max-turns 40 --timeout 1800 --project-index Tools/agents/AGENT_LOG.md
```

`context` 是有证据的重新提示；`native` 才会使用已有 provider session 并 fork session，不能混称。每轮仍需重新授予明确命令与写入范围。

## 进程清理证据

SDK与DeepSeek清理共用有界回执：TERM后最多等待0.2秒，KILL后最多等待0.5秒，每个信号、直接terminate/kill、join/wait与状态探测单独记录异常类型/errno，保留于 `process-cleanup.json`、事件和result。EPERM、未确认存活或归属无法确认会记 `cleanup_complete=false`，不能当作清理成功；ESRCH可证明目标组已不存在。若worker仍活着或状态未确认，仅将此worker对象从multiprocessing的退出自动join登记移除，并记录automatic_exit_join；否则解释器退出还会再次无界join。此适配针对当前stdlib的_children登记，不能把脱离自动join说成已清理，其PID/身份和预算预留仍保留。清理拒绝或helper意外异常不替代原timeout/轮数/预算/取消原因，也不跳过最终回执、after快照、费用结算与result/output。stdout/stderr均EOF也不代表leader已退出，等待leader仍遵守原wall timeout和信号。DeepSeek首次停止原因和截止时间固定，后续信号只追加事件、不再次清理或延长截止。DeepSeek清理后管道最多再排空1秒；仍未结束会记录stream_incomplete并保留已收到的未解析字节，不无限等待活子进程关管道。

只处置本runner创建的child，比较PID启动身份；发组信号要求当前独立session/group与child PID一致，或使用其先前已保存的归属回执。child已reap且当前启动身份不可核验时，即使旧回执记过group_created也不向现存PID/session发信号；仍存活、尚未reap的直接child可作安全fallback。SDK worker在setsid后写 `sdk-worker-owner.json`，启动未完成时只可直接处置自己的Process对象，绝不把父进程组当目标。worker已退出也要检查其已登记的后代组；确认不存在不算错误。清理状态与provider/独立验收分开，无法确认的活进程/组留待有权限的操作者核查，不改目标PID、不全局kill。

有完整SDK query完成回执时仍按已保存SDK费用字段结算（只是SDK估计）；query未完成且清理未确认时，已报告的费用另存sdk_reported_cost_usd，实际ledger费用保持null并保留USD预留。result中runner_exit_code记录包装器实际退出码，child_exit_code/exit_code按各入口保留子进程或包装器字段语义，timeout仍返回124。

## 费用与旧 SDK

DeepSeek CLI 的估价不等于实际账单；实际费用未知记 `null`。用户授权的有界任务可继续，但未知费用不能冒充零、实时余额或无限重试授权。

`api_run.sh/py` 为旧 Claude SDK 的显式入口，必须给 model、budget、budget-config；不再自动选旧模型、旧到期日或安装依赖。USD 账本用锁完成检查、预留和结算；未知费用保留预留并停止该 USD 域的自动分配，不能换账本逃避。SDK 测试用 mock，不代表旧服务的实时连通性。

历史台账只读对账：

```sh
python3 Tools/agents/agent_run.py reconcile OLD_LEDGER.md --output NEW_REPORT.json
```

2026-10-28 修复时，旧记录的已知费用重算为 148.7722 USD，旧末行累计为 133.13 USD；另有 1 条旧零费用应为未知。对账保留矛盾与原件，不把重算值当供应商账单。

## 离线回归

```sh
python3 -m unittest discover -s Tests/agents -p 'test_*.py' -v
```

覆盖结构化终态、实时日志、脱敏、进程组清理、并发预留、未知费用、恢复、文件快照和原生报告定稿。测试在临时目录运行；归档测试样本带 `.offline-fixture`，不混入真实任务面板。修复及失败证据位于 `records/2026-10-28-remediation/`。
