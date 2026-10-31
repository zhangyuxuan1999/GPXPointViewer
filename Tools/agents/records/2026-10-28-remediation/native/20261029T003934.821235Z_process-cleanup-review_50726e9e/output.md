# T10 调用清理独立审查

发现三个实质问题，均已交实现者修复并由本代理用原反例独立关闭。当前冻结版本未留开放 finding；验收保持 pending，由主代理核验完整 suite 和实际调用前提。本代理没有修改实现源码/Tests/README，没有重跑完整 suite，没有供应商调用、凭据读取、产品 app、网络或再派 agent。全部写入仅本 run。

请求模型 GPT-6.1 Sol / ultra；服务端独立模型/强度回执、token、费用均 unknown/null。采用本地 engineering:code-review 技能，依据实际源码、进程/终态契约及聚焦执行证据判断，未以技能推导额外审批。

## 被审查版本

首次输入保存在 `artifacts/frozen-01/`，随后冻结 SDK 费用增量 frozen-02、身份/drain 修复 frozen-03、EOF 修复最终 frozen-04。完整输入哈希各有 manifest；增量 patch 在 `increment-02-to-03.patch`、`increment-03-to-04.patch`。不是把实现者并发写入归为审查者修改。

最终代码 SHA-256：

- agent_run.py：`8a290ab33b4f9f3bb4b358c51832295be08764dd5aa77a495cf3663c3786156d`
- api_run.py：`35e86465b14293b729f4a62ba77c004bf551212615543d18692d25cfcc5ca91f`
- run_store.py（依赖，仅审阅未修改）：`05ad0abdc88779ef1094a8376308d44d3c794ed06b07b64a9ea2ad7ad184d11b`
- test_process_cleanup.py：`cad67d28f4df0c998ce442251df7b38e23012d135670dfec59a24a352ad1683c`

`artifacts/final-source-check.json` 证明最终快照与工作区对应输入相同。实现者报告其16项 targeted通过、全81 suite正在执行；这是实现者证据，本审查没有冒称亲自执行其全量 suite。

## 三个发现与关闭证据

| 严重性 | 触发条件与原行为 | 最终修复与独立复核 |
| --- | --- | --- |
| P1 | 旧 leader 已 reap，PID 可复用为新 session leader，expected/current identity 缺失时，owns_pid仍允许；实际 terminate_group 注入会发 TERM+KILL并最终confirmed。 | 已reap且身份不可验证的现存PID不再接收PID/组信号；仅仍存活且未reap的直接child可回退存活证据，可靠identity失配一律拒绝。四控制（双方缺身份、旧expected/current缺失、身份失配、父组）均无信号且incomplete。 |
| P2 | DeepSeek已进入drain，重复SIGTERM不断重置deadline、重跑cleanup并覆盖首个timeout。配置20信号的实际循环注入从首截止1.2虚拟秒延至4.4秒、cleanup20次，返回1而非原timeout124。 | 首停止分支仅进入一次；追加信号只记事件。原反例最终1.2虚拟秒截止、cleanup1次、首因wall_clock_timeout与返回124保留，stream_incomplete明确为true。 |
| P2 | 真实自建CLI先关闭stdout/stderr再sleep10；--timeout0.8绕到固定proc.wait(timeout=5)，实际5.328秒后failed/interrupted=false/reason=null/返回1。 | EOF后仍轮询leader与原deadline/signals，复用同一停止逻辑。相同实际CLI最终1.044秒返回124/interrupted/wall_clock_timeout/error=null，cleanup confirmed。 |

第一项是对实际helper的可执行控制流注入，不是宣称操作系统现场真的碰巧复用PID；没有向真实无关PID发信号。第一项原证据在 `ownership-probes.py/.json`，修后在 `ownership-after04.py/.json`。第二项原证据 `drain-signal-probe.py/.json`，修后 `drain-after04.py/.json`；mock的是时钟、pipe、signal接收、进程外壳，执行的是实际 run_deepseek 循环，没有将另写算法当生产代码。

第三项是受控真实子进程，仅运行本 run 内自行创建的Python CLI，无供应商。原件 `eof-before-exit-r2/` 与最终 `eof-after04/` 保存完整命令、stdout/stderr、result、after快照和清理回执。另0.15秒启动耗时先触发timeout的对照正常返回124，也保留在 `eof-before-exit/`。已对这些真实自建child用signal0核对退出，不能用“发送了kill”替代状态；见 `owned-real-child-final-state*.json`。

每项发现均立即通知root及/root/runner_tests。实现者写修复，本代理只写自身快照、探针与报告。

## SDK final、费用与异常收尾

最终 api_run + 共用helper执行三条独立聚焦路径：

1. fake worker已有完整query_completed=true final，killpg、direct terminate/kill、join均EPERM：保留output、after、result、首个wall_clock_timeout与CLI124；cleanup_complete=false，0.25 synthetic SDK estimate正常settled。
2. final存在但query_completed=false、清理也未确认：保留sdk_reported_cost_usd=0.25，cost_usd=null，ledger保持unknown_cost_hold，未把未完成查询的金额冒充可结算最终成本。
3. 整个_stop_worker意外抛PermissionError：helper escape被隔离，仍保留已有final、快照、输出、result、timeout124及已完成查询的费用结算。

执行的是实际 execute/RunStore/BudgetLedger；multiprocessing worker、SDK入口和信号动作是离线注入，未导入/调用真实SDK。最终同版证据为 `sdk-final-after04.py/.json` 与 `sdk-final-after04/`。所有0.25都是fixture，不是真实费用，actual_billed_cost_usd始终null；整个artifacts带 `.offline-fixture` 标记，防止父级状态扫描将合成records/账本混作真实调用。

还实际执行无worker的invalid budget-config路径，failed result/after/output可持久，不因新的receipt字段触发未初始化finally异常；见 `invalid-budget-config/`。这条路径发生在任何凭据/worker派发前。

## 已检查的安全与真实性边界

- 所有mutating信号须匹配本runner创建child的pid/parent及可靠identity，或仍活的未reap直接child证据。父进程/父组/0/1明确排除；SDK尚未setsid时getpgid/getsid不匹配，不能向父组发送TERM/KILL。
- SDK worker在setsid后写pid/pgid/sid/start identity回执；缺receipt不会通过改目标PID、提升权限或全局kill兜底。leader不存在时仅使用已知自身组回执处理残留；现存复用leader且身份无法验证时拒绝，不能拿旧group_created冒充新leader身份。
- 每个killpg/terminate/kill/wait/join异常进入结构化attempt/error；两次wait分别0.2/0.5秒；异常helper仍有外层保护。清理confirmed必须同时确认leader与组消失且无清理错误；leader死、kill已发送、EPERM或无法probe都不能单独宣称组清空。
- DS pipe有64块队列背压、1秒有界drain、残存bytes独立归档；首次停止原因固定。双EOF不证明leader已退出，仍保持原总时限。自然非零exit仍与final分开核验，不能只因收到success文本判成功。
- SDK先收回已持久worker final/error，再做after/合法final判断与费用结算；query完成与cleanup状态分别记录。拒绝清理不覆盖原timeout/turn/budget原因，不将unknown费用变0，也不把SDK estimate说成实际账单。

## 结论与交接

当前最终哈希未发现需要继续修改的开放问题，三条反例均关闭。原SDK EPERM导致缺终态的实现者复现、三个审查before、探针参数错误以及所有后续关闭证据均原样保留；没有把失败改写通过。主代理仍须核验实现者完整81 suite、终态与记录器版本后再恢复真实DeepSeek。本审查不替代完整suite或真实供应商验证，不宣称穷举所有OS/文件系统故障。

正常命令/完整输出/退出码保存在commands.jsonl和command-output；progress和native events记录各阶段。finish provider succeeded / acceptance pending。
