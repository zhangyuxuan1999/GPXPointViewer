# 代理调用与留档工具修复完成

本任务由按任务书指定的 GPT-6.1 Sol / ultra 实现；模型、token、费用没有独立服务端回执，实际模型字段与费用保持 unknown/null。Astra 的架构契约见上级 design/tool-contract.md；独立测试由另一个 Sol / ultra 编写并复核，我另外亲自重跑并核对源码与关键失败路径。

## 改动

新增 `Tools/agents/run_store.py` 与 `Tools/agents/agent_run.py`；重写 `api_run.py`、`api_run.sh`、`status.sh`、`Tests/run_deepseek.sh`、`Tests/run_deepseek_dev.sh`。没有改产品源码、AGENTS.md、README、测试实现、旧 Claude 历史或 deepseek_probe.py；未派发其他模型/API，未运行产品 app、构建、公共路网或安装操作。

- 每次尝试唯一目录、独占创建原任务/meta/progress，正常事件与完整工具输入/返回逐行 flush/fsync；保存会话、进程、参数、未知费用和恢复来源。默认关闭 Skill/Agent/MCP/默认配置与隐式插件，DeepSeek 固定 deepseek-flash / max。
- 新 DeepSeek runner 流式接收 stdout/stderr，普通诊断不当失败；坏 JSON、错误 final、非法 final 字段、空报告、非零退出、越界改动均不能成功。轮数/预算/timeout/TERM/INT 中断单列，无 final 为 unknown。真实 DeepSeek 费用为 null，CLI 估价单列，明确有界的每次授权调用不借此声称 USD 余额/封顶。
- 运行前输出 RUN_DIR 并注入 GPXPV_AGENT_RUN_DIR；只给自身 progress.md 和 artifacts/** 的 Write 许可，保留代理已有语义进度。默认 Read/Glob/Grep；Bash、产品文件写入须显式授予。许可是任务约束，不是 OS 文件系统隔离。
- 源码 watch 与 allow-write 分开，before/after 保存文件内容、hash、文件模式、链接目标、Git 暂存/未暂存/未跟踪证据，覆盖未跟踪与已有脏文件；生成新增/删除/修改/越界清单。源码变化不自动归因给当前代理，也不自动恢复覆盖他人改动。
- 默认排除 records/runs/reports、node_modules/sdkenv/缓存、UI 测试 app/perf/synth.gpx、exam/results、synthrunner/build.log 和 6 族生成 GPX/CSV/FIT/BIN；源码、gen.py、expect.json、考卷 baseline 与录音仍监视。可用 --exclude-path 明确增加生成物排除；建议第4轮显式 watch 源码/期望文件清单。
- SDK 改为独立 spawn worker + setsid；外层 timeout/信号终止整组并等待。此处理针对本地 SDK 源码明确记载的 raw asyncio cancellation 可能跳过子 CLI 清理缺口；脱敏 stderr 回调已接入。没有读取真实凭据，真实调用才会在预登记与预算预留后使用现有钥匙串 API key。
- API 去掉旧 CAP/default model，强制明确 model/budget/budget-config；预算同锁检查、预留、结算，重复同值幂等，冲突拒绝。未知最终费用保留预留并冻结该 USD 域自动分配，损坏账本不当新空账本。CLI 不自动重试；恢复须新轮次、旧任务/进度/结果与明确 recovery-plan，不盲重放副作用。
- Native CLI 支持 init/event/bind/snapshot/finish/verify。执行终态与独立验收分开；verify 保留原 result、保存证据及 hash。已存在同稿 output 可收尾，异稿保留原文与 output-conflict-UUID.md 并拒绝覆盖；已存在 result 不再改写。
- status 使用正规 JSON，保留面板 time/running/ledger_usd/items/aux 字段，显示项目记录、失联 unknown 与历史来源。macOS 用 libproc 的 PID+启动秒/微秒核验身份，Linux 用 bootid/start tick；不把无所有者证据当 running。离线归档 `.offline-fixture` 不混入项目面板；显式指定其 records-root 仍能单独检查。项目总索引必须显式 --project-index，测试默认只写自身 root 索引。

## 验证与历史对账

最终固定 7 个实现文件 hash 前后完全相同，`python3 -m unittest discover -s Tests/agents -v` **54/54 通过，12.128 秒**。完整输出：`command-output/20261028T225732.071955Z_bc001cb6.txt`；hash：`final-verification-before.json`、`final-verification-after.json`。Python 编译检查、4 个 zsh 入口语法检查通过。独立 Sol 的最终同 hash 复验另见 runner-tests/output.md。

覆盖：同秒同名并发、真实流式中间日志、192KB 普通工具输入/返回、JSON 字符串凭据与 thinking 去除、普通 stderr、错误/预算/轮数/未知/空稿/坏协议、timeout 与 TERM 组终止、SDK 后代清理、SIGKILL 后 unknown、alive/dead/reused PID、恢复新轮次、预存同稿/异稿、verify 不覆盖、stage/untracked/binary/删除/权限/链接/越界快照、并发预算与 unknown 冻结、损坏账本、包装器退出传播、fixture 索引隔离。

本地只读重算旧账已保存 `legacy-reconciliation.json`：19 行，已知 SDK 费用列合计 **148.7722 USD**，1 条旧异常 0 转为 unknown；旧末尾累计 **133.13 USD**，差 **15.6422 USD**。这是历史 SDK 算术对账，不是实际扣费或当前余额；旧账本未改写。

开发中发现并修复的真实边界均保留了失败输出。一次 SDK 后代断言曾因 sandbox 禁 ps 失败，改用同用户 signal 0 证明退出；不把它当产品失败。早期合成 run 曾自动追加项目索引，已交主代理标注为离线 fixture 历史，未删除证据；后续索引改为显式目标。

## 可直接使用

第4轮 DeepSeek 示例（主代理提供真实任务与明确入口/产物）：

```sh
python3 Tools/agents/agent_run.py deepseek deepseek-r4 TASK.md \
  --project-index Tools/agents/AGENT_LOG.md \
  --records-root Tools/agents/records/2026-10-28-remediation \
  --max-turns 60 --timeout 3600 \
  --allow-command 'python3 -I 本轮预建调度脚本.py' \
  --watch GPXPointViewer --watch GPXQuickLook --watch GPXThumbnail \
  --watch 明确的测试源码或期望文件 --allow-write 本轮预建工作目录
```

`Tests/run_deepseek.sh TASK.md ...` 与 `run_deepseek_dev.sh TASK.md --allow-write PATH ...` 转发上述选项并传播退出码。普通完成时 exit 0 只证明 provider/协议/报告/范围检查完成，产品验收仍为 not_run。主代理核验后：

```sh
python3 Tools/agents/agent_run.py verify RUN_DIR --status passed --evidence 主代理验收报告.md
Tools/agents/status.sh --json
```

Native：`init NAME TASK --model gpt-6.1-sol --effort ultra ...` 返回 JSON run_dir；然后 `event RUN --type TYPE --json JSON`、`bind RUN --agent-id ID`、`snapshot RUN after`、`finish RUN --provider-status succeeded --acceptance pending --output RUN/output.md --exit-code 0`。真实项目调用需显式 --project-index。

SDK：`api_run.sh NAME TASK --model 明确Claude模型 --budget 数额 --budget-config CONFIG.json [--ledger FILE] ...`；配置必须有 capacity_usd/source，可有 baseline_known_usd/baseline_unknown_costs，历史未知须先显式对账，runner 不猜余额、不静默改域。

## 留档与恢复

改前/改后内容在 before/after，哈希在 before-manifest.json/after-manifest.json；source-changes.json 列出新增2、修改5、删除0，implementation.patch 是相对原工作区内容的完整差异。commands.jsonl 与 command-output 保存命令、退出和完整正常输出；输入审查全文在 input-*.txt，后半程逐 patch 原文也已记录。未覆盖其他代理记录或原历史。

本实现没有剩余已确认缺陷。真实 API 路由、真实账单与产品第4轮不属于本实现的离线验证；按任务禁止发付费 API/启动 app，已交主代理继续既有授权的 DeepSeek 第4轮。若新运行中断，先读该轮 task/progress/result/events/manifest，再以新目录 --resume 旧目录 --resume-mode context|native --recovery-plan FILE；native 模式必须有已记录 session，不会声称“重新提示”等同会话恢复。

## R4 运行中的版本边界

主代理告知第4轮于22:57启动，使用最后队列背压改动以前版本：`queue.Queue()`；最终54项验证版为 `queue.Queue(maxsize=64)`。未将最终hash冒称运行中进程代码。依据该明确说明重构保留的源码、hash、单一差异见 `versions/r4-launch/`，元数据注明此为启动声明重构而非进程内独立证明。不得改动运行中的runner。

## R4真实权限发现与后续最小补修

首轮R4的自身progress/artifacts Write被拒是真实集成失败，原54项mock只验证参数/记录结构，未证明真实CLI权限命中；不可把首轮说成通过。已依据[官方权限文档](https://code.claude.com/docs/en/permissions#writepath-notebookeditpath-and-globpath-rules-never-match)定位：文件修改统一匹配Edit(path)，Write(path)规则接受但不会命中。自身两条规则改为精确Edit(progress.md)、Edit(artifacts/**)；cwd外用官方//绝对锚点，未增加裸Edit/Write或整个records许可。主代理授权补的Tests/agents结构回归已加入，最新55/55离线通过（12.350s，command-output/20261028T230514.894147Z_2584f1cb.txt）。前后版本/补丁/hash在versions/和live-permission-evidence.json；旧54项版本证据保留。实际Write命中仍由主代理后续有界DeepSeek回合核验，本实现代理未发模型API。当前R4继续用已授权r4-work/progress_current.md记语义进度，不中止/重跑整轮。

主代理在state-correctness/followup-01.md明确反馈后续真实回合已完成3次Write+1次Read、0拒绝，并独立验收自身日志权限。该真实验证由主代理执行，本实现代理没有另发API；第一轮Write拒绝证据仍保留。
