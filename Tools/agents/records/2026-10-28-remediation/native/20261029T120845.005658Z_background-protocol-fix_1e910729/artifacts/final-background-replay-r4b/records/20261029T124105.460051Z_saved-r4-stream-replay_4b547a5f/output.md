# R4 最终构建剩余十一阶段恢复复测报告

**Run 目录**：`/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e`

**模型/强度**：DeepSeek V4.1 Flash / max（runner 配置；本 run 结果内 `observed_model=null`，服务端模型回执未提供）
**执行命令（仅启动一次，后台）**：

```sh
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-final-recovery/driver.py run
```

**task_id**：`b18mgaxzi`
**output_file**：`/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/81257d1d-9a6e-4d92-a98e-30f715dc6132/tasks/b18mgaxzi.output`

**总览**：CLI 后台 task 正常结束，`exit code 0`。`artifacts/remaining-summary.json` 记录 `exit_code=0`、`status=passed`、`executed_phase_count=11`、`failed_phase_count=0`、`not_executed=[]`、`cleanup_passed=true`、`fatal_error=null`、`cleanup_error=null`、`interruption=null`。本轮新执行的 11 个 phase 全部 `rc=0`、`fails=0`、`status=passed`。**任务验收仍为 `pending`，视觉结论仍为 `PENDING_MAIN_AGENT_PIXEL_REVIEW`**；不将本次结果表述为“可发布”。

---

## 1. 执行边界与完整性

- 开始前仅写本 run `progress.md`，未写任何 artifacts 文件；artifacts 由 helper 创建。
- 除上述唯一 driver 命令外，未运行任何其他 python/shell 程序，未启动第二个客户端，未运行 `reg1..reg11`，未连接公共 OSRM/Valhalla/Overpass，未写产品、Tests、driver、其他 run、工具、期待、数据或本地化。
- 等待期间未使用 sleep/短 sleep/重复 Read/ls/stat/date/waitsecs 轮询；仅接收 CLI 完成通知后读取本 run 结果。
- helper bootstrap 通过（否则会返回 2）：固定构建 exe SHA256 `445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`；原 driver SHA256 `2e639226b2bf69e7dfdb24ab04ab75245842ef3265dd2677f8cc6a7ae51e5d79`；manifest SHA256 `91c3093f8fd36f0da151ebd2378d1e91d31c28e1cc8fc6de3c7d2c474987e631`；6 个固定证据哈希、原中断/清理状态、原 12 阶段结果、原偏好副本、固定构建与 50 个源码输入均由 `inheritance-receipt.json` 记录并核验。
- 原 prep、正式 PID 空基线、偏好基线均继承，未重建基线；`source_input_count=50`。
- 终轮完整性：`integrity_after.passed=true`、`source_input_count=50`。
- 原 run `deepseek/20261029T011600.159549Z_r4-final_fa1fd007` 保持原样（`interrupted`/`signal_2`/cleanup confirmed/changes 为空）；其 synth 到 79/114 的部分输出仍不算通过，未被覆盖或改写。

---

## 2. 继承的 11 组 UI（本轮未重跑）

来源 run：`/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T011600.159549Z_r4-final_fa1fd007`
以下均 `imported=true`、`executed_in_this_run=false`，由主代理在 `coordinator/r4-final-partial-review.md` 中独立核对接受；本轮未执行、未改原结果。原证据均为原 run 下绝对路径。

| 组 | 脚本 | rc / FAILS | 验收状态 | 原 result.json | 原 command log |
|---|---|---|---|---|---|
| reg1 | run_plausibility_tests.py | 0 / none | 已独立接受，不重跑 | `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T011600.159549Z_r4-final_fa1fd007/artifacts/results/reg1_20261029T011922_839711Z_513fe5c8.json` | `.../artifacts/logs/reg1/20261029T011924_372382Z_f7c3b61e_0002_reg1_run_plausibility_tests.log` |
| reg2 | run_crosscheck_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg2_20261029T013301_840140Z_1860ec08.json` | `.../logs/reg2/20261029T013303_376120Z_9e208b7a_0002_reg2_run_crosscheck_tests.log` |
| reg3 | run_batch_review_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg3_20261029T013955_664249Z_8d117f6b.json` | `.../logs/reg3/20261029T013957_200728Z_29184770_0002_reg3_run_batch_review_tests.log` |
| reg4 | run_batch_card_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg4_20261029T014111_239355Z_2f7d9514.json` | `.../logs/reg4/20261029T014112_775319Z_620cfcf9_0002_reg4_run_batch_card_tests.log` |
| reg5 | run_route_cache_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg5_20261029T014228_002677Z_7400999d.json` | `.../logs/reg5/20261029T014229_539241Z_2b9af189_0002_reg5_run_route_cache_tests.log` |
| reg6 | run_map_sources_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg6_20261029T014757_399214Z_05310582.json` | `.../logs/reg6/20261029T014758_926259Z_7ddd1bcf_0002_reg6_run_map_sources_tests.log` |
| reg7 | run_tunnel_fix_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg7_20261029T014828_832532Z_6dab279b.json` | `.../logs/reg7/20261029T014830_358802Z_44d91b9e_0002_reg7_run_tunnel_fix_tests.log` |
| reg8 | run_fill_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg8_20261029T014858_260976Z_22bcdcb7.json` | `.../logs/reg8/20261029T014858_526002Z_3cab6f6d_0003_reg8_run_fill_tests.log` |
| reg9 | run_review_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg9_20261029T014927_830065Z_aa49d46f.json` | `.../logs/reg9/20261029T014928_315627Z_6695b3fb_0003_reg9_run_review_tests.log` |
| reg10 | run_network_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg10_20261029T014957_702257Z_2e6bb1d6.json` | `.../logs/reg10/20261029T014958_119565Z_6a140b07_0003_reg10_run_network_tests.log` |
| reg11 | run_profile_tests.py | 0 / none | 已独立接受，不重跑 | `.../results/reg11_20261029T015028_714220Z_78df7a95.json` | `.../logs/reg11/20261029T015029_163804Z_52522287_0003_reg11_run_profile_tests.log` |

注：表中 `...` 均代表 `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T011600.159549Z_r4-final_fa1fd007/artifacts`。继承的 prep（`prep_20261029T011811_558571Z_58717b14`，8 checks / 0 fails）同样为 `imported=true`、未重跑；其证据结果路径为 `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T011600.159549Z_r4-final_fa1fd007/artifacts/results/prep_20261029T011811_558571Z_58717b14.json`。原 prep 记录正式 PID 空、版本 `1.0`/`1`、偏好副本 SHA256 `54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8`。

---

## 3. 本 run 新执行的 11 个 phase

结果根目录：`/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/artifacts/results/`

| phase | phase_id | rc | fails | 用时 / budget | 断言状态 | 验收状态 |
|---|---|---|---|---|---|---|
| synth | `20261029T113052_648223Z_0cb031e6` | 0 | 0 | 1289.4 s / 1000 s | passed | 断言通过 |
| selftests | `20261029T115222_052700Z_92a3a64e` | 0 | 0 | 0.1 s / 400 s | passed | 断言通过 |
| sec2 | `20261029T115222_151537Z_231e6391` | 0 | 0 | 90.6 s / 900 s | passed | 像素待主代理 |
| sec3 | `20261029T115352_807841Z_56770c6d` | 0 | 0 | 118.3 s / 1000 s | passed | 断言通过 |
| sec4 | `20261029T115551_120311Z_3b3c28b6` | 0 | 0 | 13.8 s / 400 s | passed | 断言通过 |
| sec5_zh-Hans | `20261029T115604_901079Z_4976318f` | 0 | 0 | 15.7 s / 700 s | passed | 像素待主代理 |
| sec5_en | `20261029T115620_576280Z_4145cf36` | 0 | 0 | 13.9 s / 700 s | passed | 像素待主代理 |
| sec5_de | `20261029T115634_469595Z_adaa80d3` | 0 | 0 | 13.5 s / 700 s | passed | 像素待主代理 |
| sec6 | `20261029T115647_956606Z_836698e2` | 0 | 0 | 91.0 s / 900 s | passed | UI 风险断言通过；underfill 覆盖不在本脚本 |
| docs | `20261029T115818_912722Z_ad735d25` | 0 | 0 | 0.0 s / 120 s | passed | 断言通过 |
| cleanup | `20261029T115818_930640Z_fe4678a7` | 0 | 0 | 4.2 s / 400 s | passed | 偏好差异待主代理判断 |

各 phase 的 result JSON：上表 phase_id 对应 `.../artifacts/results/<phase>_<phase_id>.json`；每 phase 原始 stdout/stderr 与 `RECOVERY <phase> rc=0 fails=0` 行见 `.../artifacts/recovery/` 与 `.../artifacts/logs/`。

### 3.1 synth
- `run_all.sh` exit 0、`timed_out=false`；build ok（38 warnings，`Tests/synth/runner/build.log`）。
- `summary: 114 entries in 6 families, ok 114`（93.3 s）→ **114/114**。
- 考卷 125：**OSRM pass 121/125**、**Valhalla pass 121/125**、noRecording 0、error 0；**artefact 123/125 high**、**parallel 125/125 high**；`high∧fail 0`、`high∧pass 0`（hit 0% / falseAlarm 0%）；**agree 125 / disagree 0 / agreeButFail 4**；bands `1-3min 78/82、10-20s 30/30、20-60s 82/84、3-8min 50/52、<10s 2/2`；**requests sent 0 / replayed 255 / missing 0**。
- 无 `FAILED` 行、无 `REGRESSIONS`，exam summary 末行逐字匹配通过。
- 四个已知未 pass 考卷仍为保留基线（`agreeButFail 4`），未调分、未改 baseline。
- 观察：本 phase 用时 1289.4 s，超过其记录的 1000 s budget，但命令 `timed_out=false`、真实 rc 0；按原 helper 语义 budget 非硬上界，记录为事实而非失败。

### 3.2 selftests
- portal **8/0**、crosscheck **31/0**、tunnel **5/0**、plausibility **7/0**，合计 **51/51**，全部 exit 0。
- case 顺序、末行匹配、`taper_excess_ladder` 阶梯 `0/30/30/50/50`、`archetype_taper32_snap12_is_high risk=70 > 50` 等原断言均通过。

### 3.3 sec2（双路分歧标签 / 视口隐藏）
- 测试副本语言 zh-Hans，打开 `Garmin_Roma_Da_copy.gpx` **46267 点**，补点 candidates=100。
- 公路项 `conflict:disagree=100`，cross `disagree=100`，`counts.disagree=100=road`，`lines=200 ≥ 2×road`。
- `batchnextconflict selected=` 回显选中项；选中后 `lineLabels=2`（≥2）；`mapgoto 45.0000,11.0000 span=26.9950,60.8796`；缩小视野后 `lineLabels=0` 且 `lines=200`。
- 双路标签截图已生成（绝对路径见第 4 节）；像素待主代理，PNG 存在不等于标签不重叠。

### 3.4 sec3（停用一路 / 一键重取）
- `fakeroute Valhalla=fail` 后公路项全部 `conflict:unverified=100`，`counts.unverified=100=road`；停用提示含“Valhalla 连续连不上，已停用；后面只用 OSRM，结果标为「没比对」”。
- `batchrecross 0 started=true`，requests `104→106`（R0+2），该处 `done`、`cross agree`、`routes 2`，unverified `100→99`。
- 已完成项 `batchrecross 0 started=false status=done`；`batchrecross all started=99`，requests `106→304`，最终 `agree=100`、`unverified=0`、`done=100`；`counts.agree=100=road`。

### 3.5 sec4（双路进度合一行）
- `routecross busy=true`；采样到 `crossLegs=[1,0]`、`routeProgress='OSRM ✓ · Valhalla 取路中…'`。
- 取完 `routeBusy=null`、`crossLegs=[1,1]`、`routeProgress=null`；`cross.agree=true`（shown `osrmCar`，other `valhallaCar`，otherMeters 362）。

### 3.6 sec5 三语
- zh-Hans / en / de 各自启动对应语言测试副本，均打开 `Garmin_Roma_Da_copy.gpx` 46267 点、candidates=100、单处取路完成。
- `windows` 证据三者主窗口均为 **w=960 h=800**：
  - zh-Hans：`GPX 点位查看器: x=240 y=60 w=960 h=800 ...`
  - en：`GPX Point Viewer: x=240 y=60 w=960 h=800 ...`
  - de：`GPX-Punktbetrachter: x=240 y=60 w=960 h=800 ...`
- `frame (240.0, 60.0, 960.0, 800.0)` 回显；`windows_text` 另记录“修改记录/Change Log/Änderungsprotokoll”1159×903 与“批量补点/Batch Gap Fill/Stapel-Lückenfüllung”1130×903（位于屏幕外坐标）。
- **front 证据**：三语 `first_cmds` 均含 `place (60.0, 21.0, 1320.0, 860.0) key=false occluded=true`、`front key=false occluded=true`，`info_front = "loginwindow"`。即宿主前置进程显示为 loginwindow、窗口标记 occluded；窗口尺寸断言通过但屏幕是否锁屏/截图为白图必须由主代理看图确认，不能据此宣称视觉通过。
- 三语 PNG 绝对路径、尺寸与大小见第 4 节；**视觉结论保持 `PENDING_MAIN_AGENT_PIXEL_REVIEW`**。

### 3.7 sec6（严格风险 UI）
- 补点 candidates=100；`riskthreshold off` 回显 50。
- 批次到达 preview；`valhalla=50`（>0）；`vHighExcl=50`，即 **50/50 = 100% ≥ 95%**（high + reasons + 默认不勾选）。
- `vMinRisk=55`（严格 > 50）；`vRisk={"55":4,"85":26,"95":10,"100":10}`；55 为合法 high。
- `osrm=50`、`oHigh=0`；`counts.high=50=nHigh`（counts 一致），`medium=9`，全部 `done`。
- 本节只检 UI 风险；两处实际 underfill 的生产 Store 补满与还原证据由主代理另交，本 driver 未测试该覆盖，不冒称。

### 3.8 docs
- README 列出 Swift 38 个，全部存在，缺 0；`GPXPointViewer/*.swift` 数量 **34**，且 34 个均出现在 README。
- `Regions.bin` 实际大小 **29,411,770 字节**；文件头 `[827213650, 1, 5319, 14275, 3496861, 64800]`；README 与 `docs/regions-design.md` 均命中 29,411,770 与 5319（移动后的行号仅记录，不作失败）。
- `Tests/ui/run_*.py` 数量 **31**，README 提到 31 个 run_；`run_suite.sh` 中脚本数 **25**，`Tests/README.md` 三处说明均为 25。未执行整个 `run_suite`。

### 3.9 cleanup
- 复位偏好命令有回显：`batchriskonly false visible=-1`、`batchcompact false`、`reviewfollow false`、`riskthreshold 50`、`crosscheck false`、`fakeroute OSRM=real Valhalla=real`、`reviewmap 标准 light=true`、`set mapStyle = 标准`、`set showStats = 1`、`exit`。
- 测试副本已关闭：`none`。
- 正式 app PID 集合：`before=[]`、`after=[]` → 测前空、测后仍空，通过；未关闭/未重启正式 app。
- 偏好差异：`prefs_diff_lines=11`；after 副本 SHA256 `9eb6d6d63b276c27e6cf38ff5291d8dd3d6759d16e36f79c9526b77be35dfcf0`（size 2759），before 为 `54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8`（size 2755）。
  - diff 路径：`/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/artifacts/prefs_diff_20261029T115818_930640Z_fe4678a7.txt`
  - 实质差异为主窗口 frame 键：`"60 21 1320 860 0 0 1440 903 "` → `"1320 -740 1320 860 0 0 1440 903 "`；其余为上下文行。
  - 因此 cleanup 通过不等于偏好逐字节恢复；该差异保留给主代理判断，本轮未修改任何偏好文件。

---

## 4. 截图绝对路径、尺寸与视觉状态

1. **双路标签 PNG（sec2）**
   `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/artifacts/shots/20261029T112901.777425Z_r4-remaining_d3ab729e_20261029T115222_151537Z_231e6391_line_labels.png`
   size=76,328 bytes；dim=[2500, 1672]；`shotwin 2500x1672` 回显。
2. **三语 zh-Hans PNG（sec5）**
   `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/artifacts/shots/20261029T112901.777425Z_r4-remaining_d3ab729e_20261029T115604_901079Z_4976318f_main_fill_zh-Hans.png`
   size=53,916 bytes；dim=[1852, 1564]；窗口按 `windows` 为 960×800，`info_front=loginwindow`、`front key=false occluded=true`。
3. **三语 en PNG（sec5）**
   `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/artifacts/shots/20261029T112901.777425Z_r4-remaining_d3ab729e_20261029T115620_576280Z_4145cf36_main_fill_en.png`
   size=53,916 bytes；dim=[1852, 1564]；窗口 960×800，front 证据同上。
4. **三语 de PNG（sec5）**
   `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/artifacts/shots/20261029T112901.777425Z_r4-remaining_d3ab729e_20261029T115634_469595Z_adaa80d3_main_fill_de.png`
   size=53,916 bytes；dim=[1852, 1564]；窗口 960×800，front 证据同上。

**观察**：三张 sec5 PNG 的字节数均为 53,916、尺寸均为 1852×1564；是否内容不同、是否存在同图/本地化未生效，需主代理看像素（必要时核文件哈希）。**最终视觉结论：`PENDING_MAIN_AGENT_PIXEL_REVIEW`**，必须由主代理真实看图；本报告不宣称三语页脚、英文/德文中段侧栏或双路标签已视觉通过。front/occlusion 证据（`loginwindow`、`occluded=true`）也提示可能存在锁屏/遮挡，需主代理确认。

---

## 5. 实际网络计数与外部请求边界

- synth：**requests sent 0 / replayed 255 / missing 0**（离线录音回放，无真实外网）。
- UI 阶段使用 driver 内置 fake route/fake tiles 机制；sec3 的 requests 104→106→304 为测试副本内部假引擎请求计数，不是公共 OSRM/Valhalla/Overpass 流量。
- 本轮未配置或访问公共 OSRM、Valhalla、Overpass，未联网搜索，未再派 agent/API 客户端。

---

## 6. 失败、未验收项与保留基线

- **phase 失败**：无（11/11 rc=0、fails=0）。
- **未执行 phase**：`not_executed=[]`。
- **未验收/待主代理**：
  1. sec2 双路标签 PNG 的像素（标签是否重叠/可读）— pending。
  2. sec5 zh-Hans/en/de 三张 PNG 的像素（960×800 底两行固定页脚、英/德文中段侧栏是否完整、是否锁屏/白图/省略号）— pending；三张 PNG 同 size 需核内容。
  3. cleanup 的 11 行偏好差异（主窗口 frame 变化）— 需主代理判断；不是逐字节恢复。
  4. sec6 两处 underfill 的生产 Store 补满/还原证据 — 本 driver 不覆盖，由主代理另交。
  5. 整体 `acceptance_status=pending`；本 run 的 CLI 正常结束与任务断言通过是两件事，均不构成最终发布结论。
- **保留基线**：考卷 OSRM/Valhalla 各 121/125、`agreeButFail 4` 为四个已知未 pass 题，按原任务保持，未调分数或改 baseline。
- **原 run 失败保留**：原 run 仍为 interrupted/失败记录，其 synth 79/114 部分输出永久保留且不计通过。

---

## 7. API/进程结束与任务断言（分开记录）

- **API/CLI 正常结束**：后台 driver 命令完成通知 `completed`，`exit code 0`；`remaining-summary.json` 的 `exit_code=0`、`status=passed`、`cleanup_passed=true`。
- **任务断言**：11 个 phase 的原断言均通过（各 phase `fails=[]`）。
- **验收状态**：`acceptance_status=pending`、`visual_verdict=PENDING_MAIN_AGENT_PIXEL_REVIEW`；独立主代理验收尚未完成，不能写“可发布”。
- **费用/用量**：`cost_usd=null`、`token_usage=null`、`observed_model=null`；实际 DeepSeek 服务端费用未知，CLI 估价不作为账单。

---

## 8. 证据索引

- 本 run 进度：`/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/progress.md`
- 总汇总：`.../artifacts/remaining-summary.json`（`not_executed=[]`、`cleanup_passed=true`、`failed_phase_count=0`、`status=passed`）
- 继承回执：`.../artifacts/inheritance-receipt.json`（固定哈希、50 源码输入、原 prefs/PID 基线、原证据路径）
- 状态：`.../artifacts/state.json`（原 prep + reg1..reg11 `imported=true`，本轮 11 phase）
- 各 phase 结果：`.../artifacts/results/`
- 各 phase 恢复日志：`.../artifacts/recovery/`
- 原始命令日志与 `commands.jsonl`：`.../artifacts/logs/`、`.../artifacts/commands.jsonl`
- 偏好差异：`.../artifacts/prefs_diff_20261029T115818_930640Z_fe4678a7.txt`
- 截图目录：`.../artifacts/shots/`（上述 4 个 PNG 绝对路径）

**最终结论**：本 run 的 11 个新 phase 全部真实执行并通过各自断言，终轮源码/构建完整性通过、cleanup 通过；但像素视觉、偏好差异判断与 sec6 underfill 外部证据仍待主代理，整体验收保持 `pending`，视觉结论保持 `PENDING_MAIN_AGENT_PIXEL_REVIEW`。