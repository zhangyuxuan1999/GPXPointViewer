# 日期 UI 与设置验收 — 执行结果报告（deepseek-flash/max）

## 结论摘要

- 唯一预授权命令已**恰好执行一次**（无 env 前缀、无 `env`、无重定向、无额外参数、未设置 `dangerouslyDisableSandbox`）：
  `python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/coordinator/run-date-acceptance.py`
- 后台任务 `bi4jib41y`，wrapper 退出码 **1**；**未重试、未执行其他命令**。
- 结果：**部分失败**。`settings-abc` 通过（exit 0，4/4，含实际 A/B/C 三进程 readback）；`navigation-zh` 在已执行 3/3 检查通过后，因 `selectedDay=2016-01-01` 状态等待超时而失败（exit 1，completed=false）；`visual-en`、`visual-de` 未启动。
- `acceptance-execution.json`：`all_requested_completed=false`、`passed=false`、`old_functional_suite_rerun=false`、`pixel_verdict=PENDING_MAIN_AGENT_REVIEW`、`literal_keyboard_verdict=PENDING_SEPARATE_MISSING_EVIDENCE_CHECK`、`actual_bill=null`。

## 各阶段实际退出码与结果

| 阶段 | 模式 | exit | 功能检查 | 截图 | 状态 |
|---|---|---:|---|---:|---|
| settings-abc | persistence | 0 | 4/4 通过 | 0（该模式无截图） | 完成，含实际 3 进程 readback |
| navigation-zh | navigation, zh-Hans | 1 | 3/3 已执行通过；completed=false | 2/6 | **失败：状态等待超时** |
| visual-en | visual-only, en | 未启动 | 无 | 0 | 未执行 |
| visual-de | visual-only, de | 未启动 | 无 | 0 | 未执行 |

### 1) settings-abc — exit 0，4/4

起止 `2026-10-31T02:06:05.322825+00:00` → `2026-10-31T02:06:11.519587+00:00`，pid 37084。

stdout PASS：
1. A has unique actual sandbox and no language argument
2. B reads saved language and idle values across process exit
3. B actual bundle localization reflects saved language
4. C verifies language-key removal and explicit false persisted

**实际 3 进程 readback 证据（A/B/C 均正常退出 0）：**

- A pid 37116：`storedLanguage=""`、`idleDisabled=false`、idle 3/5、`argumentLanguages=null`。
- B pid 37174：`storedLanguage="zh-Hans"`、`preferredLocalizations=["zh-Hans"]`、`idleDisabled=true`、idle 7/13、`persistent.AppleLanguages=["zh-Hans"]`。
- C pid 37177：`persistent.AppleLanguages=null`（语言键移除）、`idleDisabled=false`、idle 11/17。
- 唯一测试 bundle：`de.wayne.GPXPointViewer.test.t20261031t020605z-ef08c31faea3`；`formal_preference_domain_accessed=false`、`formal_app_process_touched=false`；隔离域保留供证据。
- 证据目录：`.../artifacts/settings-abc/20261031T020605.407999Z-58a011d4/`；`results.json` 4/4 passed；`execution-result.json` completed=true、failed=0。

### 2) navigation-zh — exit 1，未完成

起止 `2026-10-31T02:06:11.519910+00:00` → `2026-10-31T02:06:53.021672+00:00`，pid 37208。

已执行并通过的 3 项（stdout）：
1. Main October 16 opens its actual daily row
2. Already-open window receives October 17 without day rebuild
3. All-data entry requires explicit date confirmation

`results.json` 3 项均 passed；`execution-result.json`：`completed=false`、`functional_checks_executed=3`、`functional_checks_failed=0`。

**精确失败点（stderr，驱动第 298/226/153 行）：**
```
date_control(2016, 1, 1)
→ session.wait(lambda s: s['selectedDay'] == '2016-01-01')
→ RuntimeError: Summary state wait timed out
```
发生在上述 3 项之后、剩余导航检查与截图之前。

实际截图仅 **2 张**（要求 6 张未达成）：
- `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T020552.680246Z_summary-date-settings-stable_97f68227/artifacts/navigation-zh/20261031T020611.604533Z-e837de34/main-selected-16.png`
- `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T020552.680246Z_summary-date-settings-stable_97f68227/artifacts/navigation-zh/20261031T020611.604533Z-e837de34/choose-date.png`

应用 pid 37242 异常清理：SIGTERM、exit -15、`normal_quit=false`、`failure_cleanup=true`。唯一测试 bundle：`de.wayne.GPXPointViewer.test.t20261031t020611z-403e4aea9ee1`；未触碰正式偏好域/正式 app。执行模式记录 `keyboard_typing_verdict=PENDING_MANUAL_NATIVE_DATE_FIELD_CHECK`、`pixel_verdict=PENDING_MAIN_AGENT_PIXEL_REVIEW`。

### 3) visual-en — 未启动

wrapper 在 navigation-zh 非零退出后 break。无 `command.json`、`result.json`、stdout/stderr、退出码、截图。

### 4) visual-de — 未启动

同上，无任何产物。

## 构建（exact）

- App：`/private/tmp/GPXPointViewer-20261031T015341Z_release_e8e131ea-2iusydxs/stable-archive-b3251cb3/GPXPointViewer.app`
- Manifest：`/private/tmp/GPXPointViewer-20261031T015341Z_release_e8e131ea-2iusydxs/stable-archive-b3251cb3/build-manifest.json`
- executable SHA-256：`76578d2a74fd5549de967f7fef92dbf1b78af82525395b8a6734aae9882cec30`
- source SHA-256：`ad6b4f54617f6021eda1d08ae165146cb753f06e48b2b58e42a8f0699b985cff`
- driver SHA-256：`9f821b3426295baa002bada3c06d6602b573440fc96ddec82f330b4c4ae5f64e`（wrapper 断言通过，已写入 `execution-started.json`）
- 恢复凭据：`/Users/zyx/Documents/GPXPointViewer/Builds/20261031T020525Z_stable_signed_b3251cb3/recovery.json`

两个已启动阶段均先经稳定签名归档 prepare 成功（`prepare.result.json` exit_code=0）；未再出现上一轮的 iCloud FinderInfo/签名准备失败。

## 其他产物与约束

- `artifacts/execution-started.json`：utc `2026-10-31T02:06:05.321205+00:00`，单次执行保护已消耗。
- `artifacts/display-assertion.json`：caffeinate pid 37083，argv `/usr/bin/caffeinate -d -u -t 1200`，temporary=true；wrapper finally 负责终止（未另行运行进程检查命令）。
- 未编辑源码，未触碰正式 `/Applications` 进程或真实偏好域，未清理生成的隔离测试域；原始失败轮次（`20261031T015641...`）与既有证据保持原样。
- 未重跑任何已通过阶段，未执行任何其他脚本或 settings/reset/cleanup 命令。

## 未完成 / 待 root 处理

- `navigation-zh` 剩余检查与 4 张截图未生成；完整 6 张未达成，需为 `selectedDay=2016-01-01` 状态等待超时单独记录有界恢复（新录制轮次），本轮不重试。
- `visual-en`、`visual-de` 未启动，待阻塞解除后另行执行。
- 截图实际像素判定：`PENDING_MAIN_AGENT_REVIEW`（未声称截图良好）。
- 字面键盘输入：`PENDING_SEPARATE_MISSING_EVIDENCE_CHECK`；native `dateValue` action 不等同于键盘输入。
- `settings-abc` 功能检查有实际 A/B/C 三进程 readback；整体验收仍为 `passed=false`，不得据此声称全部设置/验收通过。
- 实际 provider 模型/计费：**unknown/null**（`actual_bill=null`，无权威计费证明）。