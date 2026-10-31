# R4 新构建双路标签定向复测报告

## 结论摘要

- 已按授权只执行一次经独立核验的 helper（`run_in_background=true`），未重试、未轮询、未 sleep。
- 新构建的两个阶段本身均通过：
  - `label_sec2`：exit 0，fails=[]，status=passed，13/13 自动检查通过。
  - `label_cleanup`：exit 0，fails=[]，status=passed，3/3 自动检查通过。
- 但 helper 的**全局 closeout 实际失败**：`status=failed`、`exit_code=1`、`blocked=false`。summary 中唯一 `passed=false` 的项为 `window_restore`，原因是窗口帧值 drift，helper 拒绝覆盖（`write_attempted=false`）。
- 最终像素结论：**PENDING_MAIN_AGENT_PIXEL_REVIEW**。PNG 已生成不等于不重叠，必须由 root 实际查看 PNG 决定。
- 未重跑旧证据；11 组 UI、114 合成、51 自测、125 题基线、sec3/4/6、三语固定页脚仍全部归属旧构建 `445940ea...`。

## 执行与范围

- 唯一 Bash 命令（后台执行，收到正规完成通知）：
  `python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-closeout/driver.py run`
- run 目录：
  `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c`
- 范围：仅新构建 sec2 标签阶段 + cleanup；未执行构建、全 UI、合成/考卷、自测、三语、sec3/4/6、docs；未修改源码/probe/helper/policy/manifest/旧 run/期望/数据；未安装/关闭正式 app；未调用其他 API/agent 或公共路网。
- 未回传服务端模型/费用信息：`observed_model=null`、`cost_usd=null`、`token_usage=null`（unknown/null）。

## 阶段结果（exit / fails / checks）

| 阶段 | phase_id | exit | fails | status | 自动检查 | 耗时 |
|---|---|---|---|---|---|---|
| `label_sec2` | `20261029T132241_023228Z_37fee15a` | 0 | [] | passed | 13/13 true | 46.2s |
| `label_cleanup` | `20261029T132327_268104Z_40cbc027` | 0 | [] | passed | 3/3 true | 3.6s |
| 全局 closeout | — | **1** | 阶段内均空 | **failed** | — | 至 13:23:32Z |

- sec2 关键自动检查均通过：候选 100、road=100、`conflict:disagree=100`、cross `disagree=100`、`counts.disagree=road=100`、lines=200；`batchnextconflict` 回显 selected；选中后 `lineLabels=2`；`mapgoto` 后 `lineLabels=0`/`lines=200`。
- cleanup 关键自动检查均通过：复位偏好命令有回显、测试副本已关闭、正式 app PID 集合 `before=[] after=[]`。
- 命令级可见非零仅为 `pkill_before_launch_zh-Hans` 与清理后的 `pgrep_*` 退出 1（无匹配进程，属预期“空→空”），未计为 phase fails。
- 全局失败项（如实保留）：
  - `window_restore.passed=false`，错误 `window value drift; refusing to overwrite`；当前值 `240 60 960 800 0 0 1440 903` 不在允许值 `60 21 1320 860 ...` / `1320 -740 1320 860 ...` 内；`write_attempted=false`，因此未覆盖任何窗口帧值。
  - `frame_tracker` 首条 `accepted=false`，错误 `preference file changed while reading`。
- 全局摘要字段：`blocked=false`、`error=null`、`interruption=null`、`executed_phase_count=2`、`not_executed=[]`、`acceptance_status=pending`。

## 截图与像素结论

- 本 run 唯一双路标签 PNG（绝对路径）：
  `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c/artifacts/shots/20261029T132227.123510Z_r4-label-final_9d13dc4c_20261029T132241_023228Z_37fee15a_line_labels.png`
- 属性：size=1,103,234 bytes，dim=2864×1944；shot 命令 exit 0。
- helper 记录的容器内原始截图：
  `/Users/zyx/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/20261029T132227.123510Z_r4-label-final_9d13dc4c_20261029T132241_023228Z_37fee15a_line_labels.png`
- 最终像素判定：**PENDING_MAIN_AGENT_PIXEL_REVIEW**。本报告不声称标签已不重叠。

## 构建归属与 source integrity

- 旧构建：`445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`
  - 仅作为继承证据（`inherited_phase_count=26`、`inherited_ui_count=11`），本次未执行；三语页脚截图亦为旧构建归档身份，helper 只校验归档身份。
- 新构建：`22e77c206e74eb6a88d1a9b56cf1a3d6dc7b0928e7d1784cd1e29943c91d0cf2`
  - 本次实际执行的可执行文件 SHA-256 与期望值一致；app 路径 `/private/tmp/gpxpv-label-build/Build/Products/Release/GPXPointViewer.app`。
- manifests：
  - 新 source manifest sha256 `09ca42fb8bd41c07c7196330705212a3f4f706beb662bfeaf116fe0c05187c32`
  - 新 build manifest sha256 `e93ba2477dc290aa027d6a40942e9cb21edc564ca849f09d0ce8312083379406`
  - changed_inputs 仅 `GPXPointViewer/ContentView.swift`，source_input_count=50。
- `integrity_after=true`；summary 明确 `inherited_results_executable_sha256` 为旧值、`current_execution_executable_sha256` 为新值。

## 偏好恢复（精简 receipt 结论）

- 非窗口键：cleanup 的 `prefs_reset` 回显通过（batchriskonly=false、batchcompact=false、reviewfollow=false、riskthreshold=50、crosscheck=false、fakeroute OSRM=real Valhalla=real、reviewmap 标准、mapStyle=标准、showStats=1）；`visual_other_keys_restored=true`。
- 窗口帧：**未恢复**。`window_restore.passed=false`，现值 `240 60 960 800 0 0 1440 903` 发生 drift，helper 拒绝覆盖，`write_attempted=false`；receipt：
  `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c/artifacts/preferences/restore_20261029T132332_398507Z_5d0c1863.json`
- 测后偏好留档副本：
  `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c/artifacts/prefs_after_20261029T132330_852760Z_7de8012e/de.wayne.GPXPointViewer.plist`
  （size=2755，sha256 `a6af0275f47b1c1adb624817ac488cf7dc68a1e147cce1307997bd6868c89bf1`）
- `prefs_diff_lines=11`，diff 文件：
  `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c/artifacts/prefs_diff_20261029T132327_268104Z_40cbc027.txt`
  （仅报告行数，不复制完整 plist/defaults 导出）
- 正式 app 未安装/未关闭：PID 集合 before=[]、after=[]。

## 失败、未完成项与停止点

1. 整体 closeout 为 failed（exit 1），不能表述为整体通过；本轮未重试同一 run。
2. 窗口帧精确恢复未完成：`window value drift; refusing to overwrite`，helper 选择保留现值、不覆盖；这属于真实未完成项，需 root 另行决定是否授权处理。
3. `frame_tracker` 记录 `accepted=false`（`preference file changed while reading`），已保留在 summary。
4. 像素结论仍为 **PENDING_MAIN_AGENT_PIXEL_REVIEW**，依赖 root 查看 PNG；任何“重叠已修复”的结论均不在本报告范围内。

## 证据路径（本 run）

- 精简 summary：`artifacts/visual-closeout-summary.json`、`artifacts/label-closeout-summary.json`
- phase 结果：`artifacts/results/label_sec2_20261029T132241_023228Z_37fee15a.json`、`artifacts/results/label_cleanup_20261029T132327_268104Z_40cbc027.json`
- 截图：见上节 `artifacts/shots/..._line_labels.png`
- 恢复 receipt：见上节 `artifacts/preferences/restore_20261029T132332_398507Z_5d0c1863.json`
- 详细日志已由 helper 保存在 `artifacts/logs/`、`artifacts/recovery/`，未在本报告复制大段日志。