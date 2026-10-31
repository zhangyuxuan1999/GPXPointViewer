# Progress — Return 修正后剩余日期验收（deepseek-flash/max）

Run dir: `.../deepseek/20261031T022543.791110Z_summary-date-return-remaining_89a17b6d`

## 已完成（收尾）
- 已核对冻结配置 `coordinator/final-date-acceptance-config.json`（仅 3 阶段：navigation-remaining zh-Hans、visual-only en、visual-only de）与 wrapper `coordinator/run-date-acceptance.py`（单次执行保护、driver hash 断言、隔离 signed-copy prepare）。
- **恰好一次**执行唯一预授权命令（无 env 前缀、无 `env`、无重定向、无额外参数、未设置 dangerouslyDisableSandbox）：
  `python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/coordinator/run-date-acceptance.py`
  前台 timeout 360000；wrapper 退出码 **1**；未重试、未执行任何其他 Bash 命令。
- 已读取本轮阶段输出、`acceptance-execution.json`、各阶段 results/execution-result/cleanup/provenance；失败后立即停止，未重跑已通过的 navigation-remaining-zh，未启动 visual-de。
- 未改动源码；未触碰正式 `/Applications` 应用进程或真实偏好域；未安装；未运行旧 settings/navigation 功能套件。

## 各阶段实际结果

### 1) navigation-remaining-zh（zh-Hans）— exit 0，3/3 功能检查 PASS，5 张 PNG
- 起止：`2026-10-31T02:26:06.358726+00:00` → `2026-10-31T02:26:14.989919+00:00`，wrapper 记录 pid 49121。
- stdout：3 条 PASS（见下）；`results.json` 3/3 passed；`execution-result.json` completed=true、functional_checks_executed=3、functional_checks_failed=0。
  1. PASS `Native date field plus one Return jumps ten years`（native field + 单次 `summarykey return`；hook 010 `summarydatecontrol 2016 1 1`、hook 011 `summarykey return`；wait 得到 `selectedDay="2016-01-01"`，builds 不变）。
  2. PASS `Empty date stays selected without fallback`（`summarydatecontrol 2015 1 1` + 单次 Return；wait 得到 `selectedDay="2015-01-01"`，`currentDay={}`、`currentDayJourneys=[]`，builds 不变）。
  3. PASS `Day-specific journey retains full cross-midnight metrics`（单条 day-specific journey，`currentJourney == before.currentDayJourneys[0]`，`end > before.currentDay.end`）。
- 实际 app 进程 pid 49157，正常退出 exit 0（`normal_quit=true`）；唯一测试 bundle：`de.wayne.GPXPointViewer.test.t20261031t022606z-edf78d910a9d`；`formal_preference_domain_accessed=false`、`formal_app_process_touched=false`；隔离域保留。
- 证据目录：`artifacts/navigation-remaining-zh/20261031T022606.441568Z-65f24671/`；prepare `exit_code=0`。

### 2) visual-en（en）— exit 1，未完成；0 张 PNG
- 起止：`2026-10-31T02:26:14.990327+00:00` → `2026-10-31T02:26:54.936317+00:00`，wrapper 记录 pid 49321。
- visual-only 模式按设计 functional_checks_executed=0；但初始 setup wait 失败（真实错误）：
  `run_summary_navigation_tests.py` line 289 `session.wait(lambda s: s['ready'] and s['selectedDay'] == '2026-10-16')` → line 153 `RuntimeError: Summary state wait timed out`。
- 最后一条 hook（096 `summarystate`）实际状态：`ready=true`、`builds=1`、`totalPoints=11`、`draftDay="2026-10-16"`、`draftEdited=false`、`selectedDay=""`、`zone="GMT"`；即等待条件中的 `selectedDay` 始终未变为 `2026-10-16`。
- 失败发生在任何截图与 date-field 动作之前；`results.json=[]`；`execution-result.json` completed=false、functional_checks_executed=0。无 PNG 产出。
- app 进程 pid 49363 异常清理（SIGTERM，exit -15，`normal_quit=false`，`failure_cleanup=true`）；唯一测试 bundle：`de.wayne.GPXPointViewer.test.t20261031t022615z-6744fa17839e`；未触碰正式偏好域/正式 app；隔离域保留。
- 证据目录：`artifacts/visual-en/20261031T022615.087118Z-16f7083b/`；prepare `exit_code=0`。

### 3) visual-de（de）— **未启动**
- wrapper 在 visual-en 非零退出后 break；无 `artifacts/visual-de/`、无 command.json/result.json/stdout/stderr/截图/退出码。

## 实际存在的 5 张 PNG（driver 断言存在且 size>0；像素内容未由本任务判定）
1. `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/deepseek/20261031T022543.791110Z_summary-date-return-remaining_89a17b6d/artifacts/navigation-remaining-zh/20261031T022606.441568Z-65f24671/choose-date-return-header.png`
2. `.../20261031T022606.441568Z-65f24671/ten-year-jump.png`
3. `.../20261031T022606.441568Z-65f24671/empty-day.png`
4. `.../20261031T022606.441568Z-65f24671/cross-midnight-journey-top.png`
5. `.../20261031T022606.441568Z-65f24671/cross-midnight-journey-lower.png`

## 未生成的 6 张预期 PNG（缺失）
- visual-en 证据目录 `artifacts/visual-en/20261031T022615.087118Z-16f7083b/` 下：`main-selected-16.png`、`choose-date.png`、`cross-midnight-journey-top.png`。
- visual-de：阶段未启动，无证据目录；预期 `main-selected-16.png`、`choose-date.png`、`cross-midnight-journey-top.png` 均不存在。
- 合计实际 5/11 张；缺失 6 张。

## 构建（exact，config 与两阶段 provenance 一致）
- App：`/private/tmp/GPXPointViewer-20261031T022013Z_release_622cc5f4-41jxc2qk/archive/GPXPointViewer.app`
- Manifest：`/private/tmp/GPXPointViewer-20261031T022013Z_release_622cc5f4-41jxc2qk/archive/build-manifest.json`
- Durable ZIP：`/Users/zyx/Documents/GPXPointViewer/Builds/20261031T022013Z_release_622cc5f4/archive/GPXPointViewer.app.zip`
- Durable manifest：`/Users/zyx/Documents/GPXPointViewer/Builds/20261031T022013Z_release_622cc5f4/archive/build-manifest.json`
- executable SHA-256：`eb52d08767443f1d1ee967b994f485731785e111685bef903688366bb8884265`
- source SHA-256：`d22ea9dc6cd7c993429da024b03e99d2958b3bb4a4d6f7f67a08f459ecd401ab`
- driver SHA-256（config；wrapper 断言通过）：`2119b111eb34470f67bb39a8d1dbab6c7b29e45aa3d3623eade5619502471659`
- signing_policy `sandboxed-local`、installable=true；provenance `source_association=build-completed-between-identical-input-snapshots`。

## 继承（未重跑）
- 上一轮 `20261031T020552.680246Z_summary-date-settings-stable_97f68227`：settings-abc **4/4 accepted**（A/B/C 实际三进程 readback；唯一隔离 bundle；正式域未访问），本轮未重跑。
- 上一轮 navigation-zh 前 **3 项 date-entry checks accepted**（主窗口 10/16 日行；已开窗口接收 10/17 不重建 day；全数据入口需显式确认），本轮未重跑。
- 既有 Store/core/AppLanguage 证据 **44/70/22** 继续继承；本轮无源码/Store/settings 逻辑改动。
- `acceptance-execution.json`：`old_functional_suite_rerun=false`。

## `acceptance-execution.json` 关键值
- `all_requested_completed=false`、`passed=false`
- `pixel_verdict=PENDING_MAIN_AGENT_REVIEW`
- `literal_keyboard_verdict=PENDING_SEPARATE_MISSING_EVIDENCE_CHECK`
- `actual_bill=null`（实际 provider 模型/计费 unknown/null）
- `phases` 仅 navigation-remaining-zh（exit 0）与 visual-en（exit 1）；visual-de 未包含。

## 其他产物 / 清理
- `artifacts/execution-started.json`（单次执行保护已消耗）。
- `artifacts/display-assertion.json`：caffeinate pid 49120，argv `/usr/bin/caffeinate -d -u -t 1200`，temporary=true；由 wrapper finally 负责终止（未另运行进程检查命令）。
- 两阶段 prepare 均 `exit_code=0`，未再出现 iCloud FinderInfo/签名准备失败。
- 本轮未手动执行 snapshot/status/git 命令；runner before/after、events、normal tool logs 由 runner 保留。

## 未做 / 保留失败项
- visual-en 未完成：初始 `selectedDay=2026-10-16` 状态等待超时；3 张 PNG 未生成。
- visual-de 未启动：3 张 PNG 未生成。
- 截图实际像素判定：PENDING_MAIN_AGENT_REVIEW（未声称良好；本任务未查看像素）。
- 字面键盘输入、单次 Return/View flush 的人工复核：PENDING_SEPARATE_MISSING_EVIDENCE_CHECK；自动化 native dateValue action 不等于字面键盘证据；`manual-native-keyboard-check.json` status=PENDING。
- 未重试任何已通过检查或失败阶段。

## 下一步（交给 root 的有界恢复）
- root 审阅已存在的 5 张 navigation-remaining PNG。
- 为 visual-en 的初始 `summarymaindate`/`selectedDay` 等待超时另建关联轮次处理；不得在本轮重试；visual-de 待解除阻塞后另行执行。
- 新 widget 实现已变更，root 需补做一次字面键盘 + 单次 Return/View flush 的实际人工复核。
- 保留本轮全部产物与隔离域证据，不清理。


## 阶段更新 2026-10-31T02:28:46.513618+00:00
### 已完成
- 已持久记录 `snapshot`，完整输入/结果见 events.jsonl。
### 正在做
- runner 状态：running。
### 下一步
- 继续当前任务；恢复前核验既有产物与最后正常工具结果。


## Runner 收尾 2026-10-31T02:28:46.518196+00:00
- provider=succeeded，验收=pending。
- 下一步：核验 output/result/events/changes；未完成项须新建关联轮次恢复。
