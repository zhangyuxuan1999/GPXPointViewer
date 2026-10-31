# R4 剩余十一阶段的一次性恢复入口

本目录由 GPT-6.1 Sol / ultra 编写并做纯离线 mock 验证。原生工具未提供服务端模型/强度回执，实际 token 和费用未知。此处的 helper 测试不能代替真实 R4；真实执行、截图像素和独立验收由后续新任务完成。

原 run 是 `../deepseek/20261029T011600.159549Z_r4-final_fa1fd007`。它已被主代理安全 SIGINT 停止，`provider_status=interrupted`、`runner_terminal_reason=signal_2`、`cleanup_complete=true`，文件 changes 为空。原 prep 与 reg1…reg11 全部通过；synth 到 79/114 后中断，没有已通过的 synth phase，因此必须完整重跑。

## 后续 DeepSeek 任务唯一执行命令

先通过 `Tools/agents/agent_run.py deepseek` 创建**全新 run**，模型 `deepseek-flash`、强度 `max`，明确授权下面这一个 Bash 命令。由 runner 自动提供该 run 的绝对 `GPXPV_AGENT_RUN_DIR`；不要手填旧 run 或本实现 run。

```sh
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-final-recovery/driver.py run
```

CLI 只接受 `run`，不提供 sleep、waitsecs、progress 或阶段选择入口。用 CLI 正规的完成等待机制接收此单命令的结果；不要派发另一个测试客户端或让模型用重复 sleep/轮询等待。原阶段 budget 合计 7,220 秒，原 command timeout 和阶段内条件等待原样保留；这些 budget 不是单命令总耗时的硬上界，外层时限应由主代理据此留足余量。

bootstrap 完全只读地确认六个固定证据哈希、原中断/清理状态、changes、原十二阶段的结果/断言/日志、原偏好副本、固定构建 executable 与 50 个 source 输入哈希。固定 executable SHA256 为 `445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`；原 driver SHA256 为 `2e639226b2bf69e7dfdb24ab04ab75245842ef3265dd2677f8cc6a7ae51e5d79`。bootstrap 失败返回 2，不启动 app，也不执行 cleanup，因为不合格的原基线不能作为恢复依据。

输出必须是新建 runner 目录，存在 `meta.json` 与 `task.md`，没有既有 `result.json` 或执行证据；`artifacts` 必须为空或不存在，不能是符号链接。拒绝原 run、其祖先/后代和任何已执行的输出目录。通过检查后排他创建 invocation receipt；同一 run 不能再运行第二次。重试必须另建 run，保留失败证据。

## 继承和执行内容

新 `artifacts/state.json` 只复制原 prep、reg1…reg11。每个 phase 显式标出 `imported=true`、`executed_in_this_run=false`、`origin_run`、`original_phase_id`。原 prefs 的 `copy`/`.txt`/plutil 日志和 UI 日志保留指向原不可变证据的绝对路径；`inheritance-receipt.json` 保存这些文件哈希和完整原 prefs/PID 基线。原 prep 不重新执行，原 UI 不重跑。

依次直接调用原 `r4-final-work/driver.py` 的原函数与预算：

1. synth（1,000 秒）
2. selftests（400 秒）
3. sec2（900 秒）
4. sec3（1,000 秒）
5. sec4（400 秒）
6. sec5 zh-Hans（700 秒）
7. sec5 en（700 秒）
8. sec5 de（700 秒）
9. sec6（900 秒）
10. docs（120 秒）
11. cleanup（400 秒，finally）

所有原断言、命令、截图与原始 command 日志保持不变。普通失败与异常会保存本 phase 的真实结果和 attempt，继续其他独立阶段。SIGINT/SIGTERM/KeyboardInterrupt 会停止后续业务阶段，仍尝试 finally cleanup，并记明未执行项。cleanup 继续由原函数读取导入 prep 的 `production_pgrep_before` 与 `prefs_before`，不重新建立基线；原函数保留偏好文本差异供主代理判断，其成功不等于偏好文件逐字节恢复。

不得安装/覆盖 `/Applications`、关闭正式 app、改产品/Tests/原 driver/原 run/工具，或连接公共 OSRM/Valhalla/Overpass。运行原 R4 的 UI 均沿用其 fake route 机制；测试副本、通信目录和测试生成物权限需与原任务相同。runner 至少应 watch 产品、Quick Look、Thumbnail、工程、README、docs、Tests 及本 helper 和原 driver，并遵守原生成物排除。不要为了通过而改期待值或 helper。

## 产物和判断

每阶段结束标准输出一行 `RECOVERY <phase> rc=… fails=… result=…`。原函数的完整标准输出和异常在 `artifacts/recovery/<phase>_<id>.log`，原 commands 完整日志仍在 `artifacts/logs/…` 与 `commands.jsonl`，结果仍在 `artifacts/results/…`。每阶段独立 `*.attempt.json` 记原函数返回码、有效返回码、真实失败、异常、命令 exit/timed_out/log；没有完整通过断言的空结果不能算成功。原失败文件不覆盖，所有新 phase ID 唯一。

末尾 `artifacts/remaining-summary.json` 分开列出 11 个继承 UI、12 个继承 phase、11 个本轮新 phase、未执行项、cleanup 和终轮源码/构建完整性。退出码 0 表示这十一阶段及终轮完整性检查均通过；1 表示有失败/不完整；2 表示 bootstrap 配置拒绝；显式信号中断返回 128+signal。无论命令返回码为何，任务验收仍是 `pending`，截图始终 `PENDING_MAIN_AGENT_PIXEL_REVIEW`，由主代理查看像素。无法写盘或进程被 SIGKILL/系统断电时，finally 无法保证，不能声称已清理。

## 本地纯离线 helper 验证

```sh
python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-final-recovery/test_driver.py
```

仅使用本目录内自动清理的 `.offline-fixture-*` 临时 fixture 和惰性导入的原 driver，执行入口全部 mock。覆盖原状态不合格、源码/构建/driver 漂移、旧/复用/符号链接输出拒绝、原 prefs/PID 原样继承、十一项次序、失败不冒充成功、异常继续、信号 finally cleanup、cleanup 失败保留、原 cleanup 读取继承基线。不会启动真实 app、UI、suite、编译器或网络客户端。实现过程与完整输出另见本实现的 native run。
