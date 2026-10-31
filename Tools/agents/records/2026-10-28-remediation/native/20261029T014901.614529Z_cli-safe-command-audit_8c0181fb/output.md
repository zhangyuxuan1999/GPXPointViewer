# DeepSeek 真实 CLI 命令许可语义核验

核验执行登记：GPT-6.1 Sol / ultra；native 工具未提供独立服务端模型、token 或费用回执，observed model=unknown、cost_usd=null。仅调查本地工具与已保存 R4 调用；本报告不是 R4 完成验收。

## 结论

`--allowedTools` 为已暴露工具追加预授权规则，不是 Bash 的封闭命令白名单。当前安装 Claude Code 2.1.310 确实内置自动允许安全只读命令的路径；`--permission-mode dontAsk` 只将需要询问的操作拒绝，`--safe-mode` 保持正常权限语义。因而 R4 的 `sleep; date; stat` 能执行，与当前 CLI 机制相符，不能据此声称危险命令逃逸、文件写越界、凭据泄漏或公共网络请求。

但 R4 task.md 明确规定“唯一执行入口是 driver”和“不得使用任意 shell 命令”。实际安全 shell 等待命令仍是任务偏差，必须在最终报告和独立验收中保留。CLI 自动批准不等于用户授权额外任务范围。README 现“Bash 命令必须显式授予”容易被读成硬白名单，需要精确化；当前已写“任务约束、不是 OS 文件系统隔离”这一点是正确的，应保留并补充命令边界。

## 直接证据

1. `Tools/agents/agent_run.py:62-68` 默认 tools/allowed 均只有 Read/Glob/Grep；存在 allow_command 时将完整 Bash 工具加入 tools，并把每项放进 `Bash(pattern)` 预授权。`:89-96` 传 `--tools ...Bash...`、`--allowedTools`、空 setting sources、safe-mode 和 dontAsk，没有额外宿主层逐命令校验。R4实际 argv 存于本run的 `r4-command-evidence.json`，唯一四个Bash预授权都是 driver.py 的绝对/相对、带不带-u模式。
2. 本地 `/opt/homebrew/bin/claude` 解析到 `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`；package.json 与内嵌源码版本均为2.1.310。精确binary SHA256见 `local-cli-identity.json`。
3. 本地 `claude-ds --help` 说明：`--tools` 定义可用内置工具集合；`--safe-mode` 关闭CLAUDE.md、技能、插件等自定义，但 built-in tools 和 permissions 正常。帮助内容、返回0和stderr保存在 `command-results.jsonl`。帮助本身没有证明allowedTools严格排除未匹配命令。
4. 二进制内嵌官方checkup文档 byte offset 235402970 明确说明许多裸只读命令如ls/cat/git status由Claude Code自动允许且不会询问（`cli-readonly-documentation.txt`）。这是本地已安装一级材料，没有联网查资料或调用模型服务。
5. 内嵌read-only analyzer函数xGn，byte range 226255426..226261794，解析单条/组合命令并检查变量、重定向、子shell等；全部满足时返回`behavior:"allow"`。表内包含sleep/stat/head/tail等，glob分支亦包含stat。Bash.isReadOnly通过Tht连接此分析器。原片段见 `cli-readonly-analyzer.js.txt`、`cli-decision-key-evidence.json` 和 `cli-readonly-callsite-snippets.json`。这些是静态机制证据；并未执行抽出的代码，也未探测危险命令。
6. dontAsk主流程片段只在已有`behavior:"ask"`分支下返回deny；已得到allow的结果在此前直接返回。对应片段见 `cli-decision-key-evidence.json`。结合帮助、内嵌文档、分析器和真实执行，足以否定“allowedTools硬白名单”这一解释；本次没有运行时每次许可决策理由，不能独立断定所有选中调用逐项经过了哪条内部实现分支。

## R4 实际偏差与计数

冻结读取 `/deepseek/20261029T011600.159549Z_r4-final_fa1fd007/transcript.jsonl` 的前12221行，提取 tool_use/tool_result，未保留thinking/reasoning。原行号、完整安全命令输入及关联正常输出存于 `r4-safe-command-evidence.json`，汇总见 `r4-safe-command-summary.json`。

- 选中53条包含sleep或stat的Bash调用：50条`tool_result.is_error=false`，2条被CLI明确Blocked，1条在固定快照时尚无返回。48条输入包含`sleep 20`。这是时点证据，不是当前R4最终计数。
- 代表调用：transcript行12170的`sleep 20; date; stat -f "%Sm %z" <自己run的reg9日志glob> 2>/dev/null | tail -1`，行12176正常返回时间和日志mtime/字节数。没有写文件、外部请求或凭据访问内容。原正常tool_result未单独暴露shell exit_code字段，因此本报告以is_error=false准确描述，不能虚构“明确exit0回执”。
- 行6766/6767的`sleep 90`组合、行8935/8936的`sleep 25`组合被拒绝。错误要求使用Monitor或后台命令，并明说不要串联更短sleep绕过block。之后重复`sleep 20`轮询与该提示不符，且超出task唯一driver限制，属于应保留的执行/等待策略偏差；不是危险副作用证据。
- 在本次选中并核对的命令/结果内，没有证据表明凭据读取、额外网络请求或任务外写入。此结论只覆盖选中安全等待行为，不把缺少证据升级为全运行安全证明。

## 等待策略、追加指令与最小建议

重复短等待每次占工具/模型往返，48次sleep20输入约对应960秒请求等待量（含待返/执行重叠，不冒称额外总耗时）；加上读取、汇报会消耗220轮限额。实际模型turn数量、供应商token和账单在本审查里没有独立结算，因此不能推算费用或断言已耗尽。

root追加指令见root-followup-wait-recovery.md：已按PID与启动身份核验停止R4，11/11 UI通过、synth中断原件保留。此状态来自root补充；本项没有代root重验全部测试。旧稿曾提driver waitsecs，现明确撤回，旧稿保留在output-r1-before-followup.md。不能通过waitsecs、短sleep或换名等待器规避已出现的Block。

后续恢复优先直接使用现有Bash的run_in_background:true启动每个固定driver阶段一次，等待CLI完成通知，再Read真实阶段结果。没有收到完成/失败通知前不启动依赖阶段或出完成报告；通知不可用时将未完成状态交宿主观察，不自行补轮询。一次性完成等待无需TaskOutput或Monitor。完整任务文字、最小可选参数和未执行的离线验证提案见background-wait-proposal.md。

本地工具事实经2.1.310内嵌一级源码核对：

- TaskOutput已移除。内嵌settings schema在byte offset216524727明确说改用Read读取后台输出文件；不要向runner添加此过期名字。
- Monitor真实内置，常量名Monitor（221040715）、MonitorTool注册（234090667/234093219），isEnabled连接wd在非Windows平台返回true（221185497）；schema支持command/ws二选一、description、timeout_ms、persistent。完整module保存在cli-monitor-tool-module.js.txt。这里只证明本地版本定义/注册/平台条件，不证明DeepSeek远端兼容。
- TaskStop真实存在，只负责停止task_id，不是等待工具。
- Bash内嵌说明在226620836附近明确：一次性等结束用run_in_background，完成会通知，不poll；Monitor用于流式条件/事件。当前R4 init确实只有Bash/Glob/Grep/Read/Write；其归档已有68个task_started和68个task_notification，包括synth stopped，保存于r4-background-notification-evidence.json。这证明事件存盘，不单凭SDK system事件声称通知已进入模型可消费上下文。

如果root另行选择Monitor参数支持，最小是opt-in `--enable-monitor`只把Monitor加入tools，保留现有精确Bash(driver *)预授权，不无条件将Monitor加入allowedTools。Monitor.command的权限实现（module的Le）会在Monitor整体allow存在且Bash只是ask时返回Monitor allow，所以整体授予会放宽命令限制。当前恢复单纯等待driver完成不需要此扩张。若需额外条件脚本，仍须新的明确授权，不能暗中扩大driver任务。

README最小替换建议完整保存在README-proposal.md，本轮没有修改README、runner、driver、产品、期望、测试脚本或历史R4结果。若未来确实需要技术上强制所有Bash只匹配所列命令，需另行宿主逐调用校验/执行环境隔离并测试；不据安全只读偏差升级为紧急危险漏洞。R4各阶段的退出码、断言、像素和清理仍按原始证据分别验收，另列命令偏差，不能因provider完成就写成任务完全合规。

## 本次审查自身的操作偏差与限制

为获取本地帮助执行了一次`/Users/zyx/bin/claude-ds --help`。包装器先尝试既有钥匙串认证查询，stderr返回`SecKeychainSearchCreateFromAttributes`参数无效及`SecKeychainSearchCopyNext`未找到项目；没有取得、打印或保存凭据。该查询是帮助入口的意外副作用，应如实记录，不能称“从未尝试认证读取”。发现后没有再次调用包装器，后续仅直接读取非敏感已安装CLI二进制/包版本。本地帮助执行本身没有启动模型任务；本次未主动调用API、app、测试或build，也未查网络。记录没有环境全集或内部思维链。

实际正常子进程argv/stdout/stderr/退出码保存在command-results.jsonl；派生提取的正常tool字段、二进制片段和统计另以命名证据文件保存。初次AGENTS/task/工具README读取随后补存原文与哈希，明确不是当时自动截获。native运行器状态事件已按阶段写入。最终provider succeeded仅表示本项审查结束，独立验收pending交root。
