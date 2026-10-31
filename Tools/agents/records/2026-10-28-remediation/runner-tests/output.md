# 代理工具离线故障回归与独立审查

最终结论：**54/54 个测试方法通过，退出码 0，耗时 12.036 秒**。其中 5 项是旧缺陷证据复现，49 项验证修复后的实际 RunStore、DeepSeek CLI 和 Claude SDK 适配器。最后一轮七个实现文件在运行前后哈希相同，见 `tested-source-before.json`、`tested-source-after.json`、`tested-source-comparison.json`。范围内无尚未解决的审查发现。

任务登记请求为 GPT-6.1 Sol / ultra；原生工具没有提供独立服务端模型回执、token 或费用，实际回执保留 unknown/null。主代理派发、实现 Sol、设计 Astra 与本独立测试的职责分开；本报告只对自己读取源码、构造并实际执行的离线验证负责。

## 修改与留档

新增 `Tests/agents/`：四组测试（legacy、store、CLI、SDK）、共用 evidence helpers、mock CLI、mock SDK、阻止真实钥匙串访问的 fake security、合成历史账本和说明。改前目录不存在，`before-manifest.json` 为空；全部新增文件的最终内容、权限与哈希已保存在 `after/`、`after-manifest.json`、`changes.json`。没有修改工具实现、产品源码、旧 Claude 历史或安装应用。

完整命令、开始/结束时间、退出码、正常输出保存在 `journal.jsonl` 和 `command-output/`；每次 mock 的完整 stdout/stderr、result、events、transcript、before/after 文件快照和合成 Git 证据保存在 `evidence/`。长工具输入与结果未截断：CLI 场景各含约 192KB 普通数据，store 场景超过 260KB，均逐字核对。后续指令与协作消息保存在 `messages.jsonl`、`followup-06.md` 及本目录任务记录。

## 实际验证

最终命令：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/agents -p 'test_*.py' -v
```

最终完整输出：`command-output/20261028T225721_277902_28de8bc4.txt`。

| 验证面 | 已验证结果 |
|---|---|
| 唯一目录与登记 | 同名并发 24 次不覆盖；完整 task/meta/progress/events 存在；native ID、session ID、请求模型与未知费用分开保存。 |
| 错误与协议 | provider/is_error/轮数/预算、无 final、坏 JSON、空报告、非文本 result、缺 is_error、子进程非零及成功 final 后非零均不能误判成功；正常 stderr 可成功。 |
| 过程恢复 | 工具结果在子进程未结束时即可读取；SIGKILL 后显示 unknown；TERM 和 timeout 有持久 interrupted 收尾；context recovery 新建 run、读取旧 task/progress/result，保留旧结果。 |
| 运行目录 | child 收到精确 GPXPV_AGENT_RUN_DIR，RUN_DIR 在 child 结束前可见；允许写自身 progress/artifacts，语义进度不被收尾覆盖，其他 run 不被污染。 |
| SDK 隔离 | fake SDK 保留所有 UserMessage tool_result；异常、轮数、预算、超时及未知成本正确记录；SDK stderr 持久脱敏；timeout-spawn 创建本地 sleep 子进程后超时，signal 0 确认后代 PID 消失。 |
| 脱敏与完整性 | 合成 bearer/API key、嵌套字段、SDK/CLI stderr 和序列化 JSON 字符串中的 password/api_key 被脱敏；author、usage、普通 JSON 字段与长工具内容完整保留；thinking canary 不落日志。 |
| 快照与范围 | tracked/staged/untracked/新增/删除/二进制/权限/软链接变化可重建与识别；保留 staged diff 和 untracked 清单；绝对越界、父目录越界与登记后替换为越界软链接均受控；显式根允许范围覆盖后代。 |
| 预算 | 12 个并行进程申请 3 美元、总上限 10 美元，只预留 9；同值结算幂等、冲突结算拒绝；损坏账本拒绝分配；unknown 留住预留并冻结自动 USD 分配；合成历史费用重算保留 unknown 且不改原件。 |
| 授权 bounded 调用 | 两次明确 max-turns/timeout 的 DeepSeek mock 均新建独立目录，费用持续 null；没有宣称美元封顶，也没有用新账本绕过 USD 冻结。 |
| 状态与验收 | 引号、反斜杠和换行名字输出合法 JSON；当前真实 owner PID 身份匹配为 running、死 PID/身份改变及 stale native 为 unknown；verification 不覆盖原 result，失败 execution 不可验收 passed。 |
| native 收尾 | run/output.md 已有同稿可 finalize；异稿保留原件并拒绝静默覆盖；已有 result 不得重写；真实 CLI finish --output 同文件可用。 |
| 测试隔离 | 父级 project status 跳过 .offline-fixture 归档，显式指定 fixture records-root 时仍能单独检查状态。 |

## 已发现并修复复验的问题

本独立测试首轮发现：损坏预算账本被当新账本、历史 unknown 费用行被跳过、author 误脱敏、软链接父路径逃逸；后续补充登记后软链接替换、watch 根回归、允许根范围误报、缺 is_error 仍成功、非文本 final 收尾、SDK stderr、序列化 JSON 敏感值等边界。每项均通知实现 Sol 并在修复后复验。主代理发现的 native 预写 output 收尾问题由本任务独立复现并加入三项回归。

实现 Sol 从真实 SDK 源码定位取消可能遗漏 CLI 后代的问题，修为 spawn worker + setsid；本任务用真实本地后代进程验证超时清理。sandbox 禁 ps 的现象没有误记为产品失败，改用 signal 0 检查后代；随后 libproc 实现已用当前真实 PID 实测 running。

早期失败和中间通过证据完整保留，没有覆盖成最终通过。例如：`20261028T223954_537343_bf51e201.txt`（首轮四缺陷）、`20261028T224110_349590_6440ce21.txt`（watch 根回归）、`20261028T225037_862032_9c1aaa37.txt`（ps 被 sandbox 拒绝）、`20261028T225354_514337_8b247423.txt`（native 预写 output 与 JSON 字符串脱敏）。这些文件都在 `command-output/`。

## 限制、记录副作用与恢复

本任务没有调用真实 API、启动/关闭 app、构建产品、安装 /Applications 或请求公共路网。SDK 仅导入 fake transport，使用公开非凭据 canary；fake security 会拒绝并记录意外钥匙串访问，全部相关检查确认未调用。仅只读检查真实 SDK 构造参数兼容性，未执行其 query。模型出站映射、实时余额、真实账单、产品第4轮 UI/联网结果属于主任务后续验证，不由这些 mock 证明。

最初 fixture records 位于本任务 evidence 目录，曾由被测旧 create 自动追加项目总索引，已立即报告；主代理决定保留并注明仅 offline fixture、未派发模型/API。之后全部合成运行迁入已授权 /private/tmp，证据复制回本任务；实现改为显式项目索引，并用 .offline-fixture 排除归档 mock。未删除或改写历史索引。

当前范围内没有未完成的修复/测试项。恢复时先读 task.md、progress.md、result.json、tested-source-comparison.json 与最终输出，再用上述命令运行新一轮；新失败须保留独立记录。不得把本测试通过当成产品第4轮通过，不自动重做任何有副作用操作。生成的本任务测试 __pycache__ 已清理，源码和证据保留。

最后补充：实现最后一行 stdout/stderr queue 背压限制变更后，重新运行完整54项并再次确认七个实现源文件前后哈希一致。前一版完成报告与结果保存在 output-r3.md/result-r3.json，不覆盖其证据。
