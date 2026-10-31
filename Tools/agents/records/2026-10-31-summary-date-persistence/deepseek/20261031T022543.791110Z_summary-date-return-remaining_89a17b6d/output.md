# 本轮最终报告 — Return 修正后剩余日期验收（deepseek-flash/max）

## 1. 执行摘要

- 本轮目录：`.../deepseek/20261031T022543.791110Z_summary-date-return-remaining_89a17b6d`
- 已核对冻结配置与 wrapper；配置确认为 3 个阶段：`navigation-remaining-zh`（zh-Hans）、`visual-en`（visual-only）、`visual-de`（visual-only）。
- **恰好执行一次**唯一预授权命令，无 env 前缀、无 `env`、无重定向、无额外参数、未设置 `dangerouslyDisableSandbox`：

```bash
python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/coordinator/run-date-acceptance.py
```

- wrapper 退出码：**1**（因 visual-en 失败，wrapper 在 visual-en 后停止，visual-de 未启动）。
- 未重试、未执行任何其他 Bash 命令；未重跑已通过的 navigation-remaining-zh；未运行任何旧 settings/navigation 功能套件。
- 未修改源码、未安装、未触碰正式 `/Applications` 进程或真实偏好域、未使用真实 tracks。所有测试均使用新的唯一隔离 bundle 与 `/private/tmp` 复制。

## 2. 各阶段实际结果

| 阶段 | 模式 | 退出码 | 功能检查 | PNG | 实际结果 |
|---|---|---:|---|---:|---|
| navigation-remaining-zh | navigation-remaining | **0** | **3/3 PASS** | 5 | 本轮缺失的 3 项导航检查全部通过 |
| visual-en | visual-only | **1** | 0（按设计） | 0 | 初始 `selectedDay=2026-10-16` 状态等待超时，未到截图步骤 |
| visual-de | visual-only | — | — | 0 | wrapper 在 visual-en 后 break，阶段未启动 |

### 2.1 navigation-remaining-zh（zh-Hans）— exit 0，3/3 PASS

起止：`2026-10-31T02:26:06.358726+00:00` → `2026-10-31T02:26:14.989919+00:00`，wrapper pid 49121。

stdout 实际 3 条 PASS：

1. `Native date field plus one Return jumps ten years`
   - hook `010`：`summarydatecontrol 2016 1 1`
   - hook `011`：`summarykey return`（单次 Return）
   - 实际状态：`selectedDay="2016-01-01"`，`builds` 不变，`currentDay` 非空。
2. `Empty date stays selected without fallback`
   - `summarydatecontrol 2015 1 1` + 单次 `summarykey return`
   - 实际状态：`selectedDay="2015-01-01"`，`currentDay={}`、`currentDayJourneys=[]`，`builds` 不变。
3. `Day-specific journey retains full cross-midnight metrics`
   - `currentDayJourneys` 恰好 1 条；`currentJourney == before.currentDayJourneys[0]`；`end > before.currentDay.end`。

证据：

- `results.json`：3/3 `passed=true`
- `execution-result.json`：`completed=true`、`functional_checks_executed=3`、`functional_checks_failed=0`
- app 进程 pid 49157，正常退出 **exit 0**（`normal_quit=true`）
- 唯一测试 bundle：`de.wayne.GPXPointViewer.test.t20261031t022606z-edf78d910a9d`
- `formal_preference_domain_accessed=false`、`formal_app_process_touched=false`
- 隔离域保留：`/Users/zyx/Library/Containers/de.wayne.GPXPointViewer.test.t20261031t022606z-edf78d910a9d/Data/tmp/summary-navigation`
- 证据目录：`artifacts/navigation-remaining-zh/20261031T022606.441568Z-65f24671/`
- prepare 隔离签名复制：`exit_code=0`

### 2.2 visual-en（en）— exit 1，未完成，0 张 PNG

起止：`2026-10-31T02:26:14.990327+00:00` → `2026-10-31T02:26:54.936317+00:00`，wrapper pid 49321。

真实错误（driver stderr）：

```
File "Tests/ui/run_summary_navigation_tests.py", line 289
  session.wait(lambda s: s['ready'] and s['selectedDay'] == '2026-10-16')
File "Tests/ui/run_summary_navigation_tests.py", line 153
  raise RuntimeError('Summary state wait timed out')
RuntimeError: Summary state wait timed out
```

最后一条 `summarystate`（096-hook）实际状态：

- `ready=true`
- `builds=1`
- `totalPoints=11`
- `draftDay="2026-10-16"`
- `draftEdited=false`
- `selectedDay=""`
- `zone="GMT"`

即：等待条件要求 `selectedDay == "2026-10-16"`，但最终仅 `draftDay` 被设置，`selectedDay` 始终为空；失败发生在**任何截图和 date-field 动作之前**，不是 Return 修正后的日期提交检查失败，也不能据此判定英文界面像素。

其他事实：

- `results.json=[]`
- `execution-result.json`：`completed=false`、`functional_checks_executed=0`、`functional_checks_failed=0`
- 无任何 PNG 产出
- app 进程 pid 49363 异常清理：SIGTERM，exit -15，`normal_quit=false`，`failure_cleanup=true`
- 唯一测试 bundle：`de.wayne.GPXPointViewer.test.t20261031t022615z-6744fa17839e`
- `formal_preference_domain_accessed=false`、`formal_app_process_touched=false`
- 隔离域保留：`/Users/zyx/Library/Containers/de.wayne.GPXPointViewer.test.t20261031t022615z-6744fa17839e/Data/tmp/summary-navigation`
- 证据目录：`artifacts/visual-en/20261031T022615.087118Z-16f7083b/`
- prepare 隔离签名复制：`exit_code=0`

### 2.3 visual-de（de）— 未启动

- wrapper 在 visual-en 非零退出后 break。
- 无 `artifacts/visual-de/` 目录，无 command.json / result.json / stdout / stderr / 截图 / 退出码。

## 3. 构建身份（exact）

- App：`/private/tmp/GPXPointViewer-20261031T022013Z_release_622cc5f4-41jxc2qk/archive/GPXPointViewer.app`
- Manifest：`/private/tmp/GPXPointViewer-20261031T022013Z_release_622cc5f4-41jxc2qk/archive/build-manifest.json`
- Durable ZIP：`/Users/zyx/Documents/GPXPointViewer/Builds/20261031T022013Z_release_622cc5f4/archive/GPXPointViewer.app.zip`
- Durable manifest：`/Users/zyx/Documents/GPXPointViewer/Builds/20261031T022013Z_release_622cc5f4/archive/build-manifest.json`
- executable SHA-256：`eb52d08767443f1d1ee967b994f485731785e111685bef903688366bb8884265`
- source SHA-256：`d22ea9dc6cd7c993429da024b03e99d2958b3bb4a4d6f7f67a08f459ecd401ab`
- driver SHA-256（config；wrapper 断言通过）：`2119b111eb34470f67bb39a8d1dbab6c7b29e45aa3d3623eade5619502471659`
- `signing_policy=sandboxed-local`、`installable=true`
- 两阶段 provenance 一致：`source_association=build-completed-between-identical-input-snapshots`

## 4. 继承证据（本轮未重跑）

- **settings-abc 4/4** 沿袭上一轮 `20261031T020552.680246Z_summary-date-settings-stable_97f68227` 的实际 A/B/C 三进程 readback 证据；本轮未重跑。
- **navigation-zh 前 3 项 date-entry checks** 沿袭上一轮已接受结果（10/16 日行、10/17 不重建 day、全数据入口需显式确认）；本轮未重跑。
- 既有 **Store/core/AppLanguage 证据 44/70/22** 继续继承；本轮无 Store、settings 或 source 逻辑改动。
- 本轮 wrapper 记录：`old_functional_suite_rerun=false`。

## 5. 11 张预期 PNG 的实际状态

### 实际存在：5 张（driver 已校验文件存在且 size>0；像素内容未由本任务判定）

1. `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T022543.791110Z_summary-date-return-remaining_89a17b6d/artifacts/navigation-remaining-zh/20261031T022606.441568Z-65f24671/choose-date-return-header.png`
2. `.../navigation-remaining-zh/20261031T022606.441568Z-65f24671/ten-year-jump.png`
3. `.../navigation-remaining-zh/20261031T022606.441568Z-65f24671/empty-day.png`
4. `.../navigation-remaining-zh/20261031T022606.441568Z-65f24671/cross-midnight-journey-top.png`
5. `.../navigation-remaining-zh/20261031T022606.441568Z-65f24671/cross-midnight-journey-lower.png`

### 未生成：6 张

6. `.../artifacts/visual-en/20261031T022615.087118Z-16f7083b/main-selected-16.png` — **不存在**
7. `.../artifacts/visual-en/20261031T022615.087118Z-16f7083b/choose-date.png` — **不存在**
8. `.../artifacts/visual-en/20261031T022615.087118Z-16f7083b/cross-midnight-journey-top.png` — **不存在**
9. `.../artifacts/visual-de/<未创建证据目录>/main-selected-16.png` — **不存在（阶段未启动）**
10. `.../artifacts/visual-de/<未创建证据目录>/choose-date.png` — **不存在（阶段未启动）**
11. `.../artifacts/visual-de/<未创建证据目录>/cross-midnight-journey-top.png` — **不存在（阶段未启动）**

合计：**实际 5/11 张；缺失 6 张**。

## 6. `acceptance-execution.json` 关键值

- `all_requested_completed=false`
- `passed=false`
- `old_functional_suite_rerun=false`
- `pixel_verdict=PENDING_MAIN_AGENT_REVIEW`
- `literal_keyboard_verdict=PENDING_SEPARATE_MISSING_EVIDENCE_CHECK`
- `actual_bill=null`（实际 provider 模型与权威计费 unknown/null）
- `phases` 仅含 navigation-remaining-zh（exit 0）与 visual-en（exit 1）

## 7. 未做 / 明确待定

- **visual-en 未完成**：初始 `selectedDay=2026-10-16` 等待超时；3 张 PNG 未生成。
- **visual-de 未启动**：3 张 PNG 未生成。
- **截图像素判定：PENDING_MAIN_AGENT_REVIEW**。本任务未打开/查看 PNG，不声称任何截图良好。
- **字面键盘输入与 View flush：PENDING_SEPARATE_MISSING_EVIDENCE_CHECK**。`manual-native-keyboard-check.json` 记录 status=PENDING；本轮自动化 `summarydatecontrol` + `summarykey return` 是 native dateValue 动作，不等于字面键盘证据。
- 未重试任何已完成或失败阶段；未清理隔离域。
- 未手动执行 snapshot / git / 进程检查命令；runner before/after、events 与 normal tool logs 由 runner 保留。

## 8. 给 root 的有界后续

1. 审阅已存在的 5 张 navigation-remaining-zh PNG。
2. 为 visual-en 的初始 `summarymaindate` / `selectedDay` 等待超时另建关联轮次处理；不得在本轮重试；visual-de 待阻塞解除后另行执行。
3. 由于 native widget 实现已变更，root 需补做一次**字面键盘输入 + 单次 Return + View（无 Return）flush** 的实际人工复核（单次 Return 的自动化检查已通过，但不能替代字面键盘证据）。
4. 保留本轮全部产物与隔离域证据，不清理。