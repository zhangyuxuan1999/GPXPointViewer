# R4 复测报告

## 0. 版本、环境与证据总览

- 测试 app：`/Applications/GPXPointViewer.app`
- `ui.app_source()` 输出：`/Applications/GPXPointViewer.app`
- 可执行文件：`/Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer`
  - mtime：`2026-10-28T14:12:04.417336`
  - size：`11590960` 字节
- Bundle 版本：`CFBundleShortVersionString = 1.0`，`CFBundleVersion = 1`
- 源码：`HEAD = b8927ed1c5071be57a974e10100f1ab09dfbb1de`
  - 测前工作区本来就有未提交修改/未跟踪文件，完整 `git status` 见 `artifacts/results/prep.json`。
  - 本代理没有修改产品源码、现有测试脚本、期望值或 `Tests/exam/baseline.json`；只使用/生成了本轮 `r4-work`、artifacts、测试副本及 synthrunner 构建产物。
- 屏幕：`1440×932`；测试期间未锁屏，`info` 的 `front=` 均为产品窗口标题，不是 `loginwindow`。
- 每次启动测试副本后第一条命令均为 `autotripmap 0`；所有 UI 子进程都继承 `GPXPV_APP=/Applications/GPXPointViewer.app`。
- 本轮调度脚本：`Tools/agents/records/2026-10-28-remediation/r4-work/driver.py`
  - 每个子进程的 argv、开始/结束时间、退出码、完整 stdout/stderr 记录在：
    - `artifacts/commands.jsonl`
    - `artifacts/logs/<phase>/`
- 本轮结果根目录：
  - `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/`

### 0.1 「准备」第 3 步 5 个字符串结果

| 字符串 | `grep -rlaF` 结果 | 补充证据 |
|---|---|---|
| `重新比对这一处（两路重取）` | 命中 `Contents/MacOS/GPXPointViewer` | — |
| `全部重新比对` | 命中 `Contents/MacOS/GPXPointViewer` | — |
| `取路中…` | UTF-8 grep **MISSING** | `diag` 在 `Contents/Resources/{de,en,zh-Hant}.lproj/Localizable.strings` 命中 **UTF-16LE** |
| `已扣除端部允许的` | 命中 `Contents/MacOS/GPXPointViewer` | — |
| `主地图跟随` | UTF-8 grep **MISSING** | `diag` 在 `Contents/Resources/{de,en,zh-Hant}.lproj/Localizable.strings` 命中 **UTF-16LE** |

结论：5 个字符串全部有证据，安装包不是旧版。UTF-8 `grep` 只命中 3/5 是搜索方法问题，不是版本缺失；`diag` 还确认二进制含 `recrossBatchItem`、`recrossUnverifiedAll`、`crossProgressLine`、`fillRouteBusy` 等新符号。证据：

- `artifacts/results/prep.json`
- `artifacts/results/diag.json`
- `artifacts/logs/diag/0001_nm_binary.log`

### 0.2 实际网络 / 回放计数

| 场景 | 计数 | 说明 |
|---|---|---|
| 合成考卷 | `requests sent 0 replayed 255 missing 0` | `run_all.sh` 末行原文 |
| 回归 `run_plausibility_tests.py` R1a | `netRequests 100 → 100` | replay 下单处 `route car` 不出网 |
| 回归 R1b | `replayHits 0 → 1`，`misses 3` | 命中录音并取到草稿 |
| 第 2 节 UI 假引擎 | `netRequests = 200` | 100 项 × 2 个假引擎 |
| 第 3 节 UI 假引擎 | `netRequests 104 → 106 → 304` | 初始 104、单处重取 +2、全部重取 +198 |
| 第 4 节单处 | `netRequests 304 → 306` | `routecross` 两路各一次 |
| 第 5 节三语言 | 每语言 `netRequests = 1` | 每次新副本单处 `route car` |
| 第 6 节 UI 假引擎 | `netRequests = 100` | 100 个公路项 |
| 真实公共路网请求 | **0** | `fakeroute` 的 `routeOverride` 在进入 URLSession 前返回假结果；`UITestHook.swift` 第 49 行明确假请求也计入 `netRequests` |
| 真实瓦片 / Overpass | **0** | `autotripmap 0` 已发；`run_map_sources_tests.py` 使用假瓦片（`tileRequests=96`）和 `faketunnels` |

没有运行 `run_batch_drift.py`、`run_crosscheck_online.py`、`run_route_tests.py`、`run_drift_tests.py`、`Tests/ui/run_suite.sh`，也没有运行 `--record`。

### 0.3 机器检查总览

共 132 项 driver 检查：128 `ok`、4 `FAIL`；4 个 FAIL 均不是已确认的产品缺陷：

- 2 项：准备阶段 UTF-8 `grep` 未命中，后续 `diag` 已用 UTF-16LE 证明存在 → 任务书方法问题。
- 1 项：第 6 节 `vMinRisk > 50` 严格判据实际为 0 → 任务书判据冲突（见第 6 节）。
- 1 项：收尾检查「正式 app 仍在运行」→ 测前本来就没有 `/Applications` 实例，环境基线不适用（见第 8 节）。

---

## 1. 回归脚本（11 个）+ 合成套件 + 4 个自测

实际调度命令均通过：

```sh
python3 -u Tools/agents/records/2026-10-28-remediation/r4-work/driver.py reg <1..11>
```

内部脚本 argv 与完整 stdout/stderr 见 `artifacts/commands.jsonl`、`artifacts/logs/reg*/`。

### 1.1 11 个回归脚本

| # | 脚本 | exit | 末行原文 |
|---|---|---:|---|
| 1 | `run_plausibility_tests.py` | 0 | `FAILS: none` |
| 2 | `run_crosscheck_tests.py` | 0 | `FAILS: none` |
| 3 | `run_batch_review_tests.py` | 0 | `FAILS: none` |
| 4 | `run_batch_card_tests.py` | 0 | `FAILS: none` |
| 5 | `run_route_cache_tests.py` | 0 | `FAILS: none` |
| 6 | `run_map_sources_tests.py` | 0 | `FAILS: none` |
| 7 | `run_tunnel_fix_tests.py` | 0 | `FAILS: none` |
| 8 | `run_fill_tests.py` | 0 | `FAILS: none` |
| 9 | `run_review_tests.py` | 0 | `FAILS: none` |
| 10 | `run_network_tests.py` | 0 | `FAILS: none` |
| 11 | `run_profile_tests.py` | 0 | `FAILS: none` |

关键行原文：

- `ok` **P2a**：`P2a Valhalla 偏 30 m 的 50 处 ≥95% high + reasons 非空 + 默认不勾选（49）；counts.high=49`
- `ok` **R1a**：`R1a replay 下 route car 不出网：netRequests 100 → 100`
- `ok` **R1b**：`R1b 取到草稿：replayHits 0 → 1，misses 3，route={'source': 'osrmCar', 'meters': 373, 'method': None} vertexCount=3，A=9728 B=9734`
- `ok` **B15**：`B15 选中待选项后 lineLabels 2 ≥ 2（lines 2）`
- `ok` **B16**：`B16 缩到 3000 km：lineLabels 0 = 0（lines 197 仍画）`
- `ok` **R1**：`R1 batchrecross 0：batchrecross 0 started=true status=Optional(GPXPointViewer.BatchStatus.running) → requests 101→103 status=done cross=agree`
- `ok` **R2**：`R2 已不是 unverified 的项不重取：batchrecross 0 started=false status=Optional(GPXPointViewer.BatchStatus.done)`
- `ok` **R3**：`R3 batchrecross all：batchrecross all started=96 requests 103→295（+192）unverified 96，已一致的那处不动`
- `ok` **E5**：`E5 合并进度行：'OSRM ✓ · Valhalla 取路中…' crossLegs=[1, 0]`
- `ok` **E6**：`E6 取完进度清空、两路一致：None {'agree': True, 'shown': 'osrmCar', 'other': 'valhallaCar', 'otherMeters': 424}`
- `ok` `run_tunnel_fix_tests.py`：`candidates=50 profile={'kind': 'deviceLogger', ...}`
- `ok` `run_network_tests.py`：`N0`、`N1`、`N2` 全 `ok`
- `ok` `run_profile_tests.py`：含 `ok P2 Garmin 候选 100`
- `ok` `run_map_sources_tests.py`：M1c 通过，未出现锁屏假失败

证据：

- `artifacts/results/reg1.json` … `artifacts/results/reg11.json`
- `artifacts/logs/reg1/0002_reg1_run_plausibility_tests.log`
- `artifacts/logs/reg2/0002_reg2_run_crosscheck_tests.log`
- 其余 `artifacts/logs/reg3/` … `artifacts/logs/reg11/`

### 1.2 合成 runner `run_all.sh`

实际命令：

```sh
python3 -u Tools/agents/records/2026-10-28-remediation/r4-work/driver.py synth
# driver 内部：sh Tests/synth/runner/run_all.sh
```

结果：

- `exit=0`
- `build ok (38 warnings; log: Tests/synth/runner/build.log)`
- `summary: 114 entries in 6 families, ok 114  (32.3 s)`
- 无 `FAILED` 行，无 `REGRESSIONS`
- 考卷末行逐字匹配：

```text
exam summary: questions 125 · detected 110 · osrm: pass 121/125 noRecording 0 error 0 | high∧fail 0 high∧pass 0 → hit 0% falseAlarm 0% | perturb artefact 123/125 parallel 125/125 high · valhalla: pass 121/125 noRecording 0 error 0 | high∧fail 0 high∧pass 0 → hit 0% falseAlarm 0% | perturb artefact 123/125 parallel 125/125 high · agree 125 disagree 0 agreeButFail 4 · bands 1-3min 78/82 10-20s 30/30 20-60s 82/84 3-8min 50/52 <10s 2/2 · requests sent 0 replayed 255 missing 0
```

证据：`artifacts/results/synth.json`、`artifacts/logs/synth/0001_run_all.log`。

### 1.3 四个 synthrunner 自测

| 自测 | exit | `"ok":true` | `"ok":false` | 末行原文 |
|---|---:|---:|---:|---|
| `--portal-selftest` | 0 | 8 | 0 | `{"case":"anchor_warning_taper_vs_residual","ok":true,"warning":"两路一致，但补点起始段向 A 靠拢了 32 m、远多于 A 离路的 12 m：起始几何可能不是路网，请在地图上看一眼","normal":null}` |
| `--crosscheck-selftest` | 0 | 31 | 0 | `{"case":"drafts_shift_differs_inner_agrees","agree":false,"expect":false,"ok":true,"reasons":["两路对隧道口位置判断不同：A 外推 3 / 0 点，B 外推 0 / 0 点；中间路段几何一致"]}` |
| `--tunnel-selftest` | 0 | 5 | 0 | `{"case":"plausibility_tunnel_waive","ok":true,"riskNil":10,"riskLow":10,"riskHigh":0}` |
| `--plausibility-selftest` | 0 | 7 | 0 | `{"case":"retarget_clips_vertices","ok":true,"vertices":1}` |

附加逐字结果：

- `{"case":"taper_excess_ladder","ok":true,"excess8":0,"excess15":30,"excess18":30,"excess20":50,"excess25":50}`
- `archetype_taper32_snap12_is_high`：`risk=70`（> 50）
- 7 个 case 顺序：`taper_excess_ladder, archetype_taper32_snap12_is_high, taper_excess_reason_mentions_excess, artefact_profile_is_high, dev_reason_mentions_allowance, sparse_points_sample_vertices, retarget_clips_vertices`

证据：`artifacts/results/selftests.json`、`artifacts/logs/selftests/0001..0004_*.log`。

---

## 2. 分歧线引擎名标签（精确模式，Valhalla 偏 30 m）

实际调度：`python3 -u .../driver.py sec2`

启动与设置回显：

```text
riskthreshold 50
crosscheck true
fakeroute OSRM=ok Valhalla=real
fakeroute OSRM=ok Valhalla=offset 30
routecache cleared
```

1. `ok` 批次到达 `preview`，公路项全部 `conflict:disagree`
   - `counts.disagree = road = 100`
   - `status_counter = {"conflict:disagree": 100}`
   - `cross_counter = {"disagree": 100}`
   - `lines = 200`（≥ 2 × road）
   - `requests = 200`
2. `ok` `batchnextconflict` 回显 `batchnextconflict selected=1792183278.0`；选中后：
   - `lineLabels = 2`
   - `lines = 2`
   - 满足 `lineLabels ≥ 2`
3. `ok` `mapgoto 45 11 3000` 回显：
   - `mapgoto 45.0000,11.0000 span=26.9950,60.8796`
   - 之后 `lineLabels = 0`，`lines = 200`（线仍画着）
4. `ok`（截图生成）/ `不判（视觉未读取）` 存证：
   - 先执行 `batchnextconflict selected=1792183333.0` 重新聚焦
   - `shotwin 2864x1944`
   - artifact PNG：
     `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/artifacts/shots/r4_line_labels.png`
   - size `3036175`，dim `2864×1944`
   - `info` 原文：`active=true hidden=false key=true visible=true mini=false onActiveSpace=true occl=8194 screen=(0.0, 0.0, 1440.0, 932.0) front=GPX 点位查看器`
   - 视觉判据（两个蓝底白字标签、分别 OSRM/Valhalla、不重叠）**未由本代理读取图片验收**，交主代理检查。

证据：`artifacts/results/sec2.json`、`artifacts/logs/sec2/0052_sec2_refocus.log`、`0053_shot_line_labels.log`、`0054_info_sec2.log`。

---

## 3. 「只有一路结果」一键重比对

实际调度：`python3 -u .../driver.py sec3`

1. `ok` `fakeroute valhalla fail` + 批次：
   - `fakeroute OSRM=ok Valhalla=fail`
   - 公路项全部 `conflict:unverified`（100）
   - `cross` 全部 `unverified`（100）
   - `counts.unverified = road = 100`
   - `engineDisabled = Valhalla 连续连不上，已停用；后面只用 OSRM，结果标为「没比对」`
   - 记下 `firstUnv = 0`、`R0 = 104`、`U0 = 100`
2. `ok` `fakeroute valhalla ok` 回显含 `Valhalla=ok`
3. `ok` `batchrecross 0`：
   - 回显 `batchrecross 0 started=true status=Optional(GPXPointViewer.BatchStatus.running)`
   - 完成后该项：`status done`、`cross agree`、`routes 2`
   - `requests 104 → 106`（R0 + 2）
   - `counts.unverified = 99`（U0 − 1）
   - `R1 = 106`、`U1 = 99`
4. `ok` 再次 `batchrecross 0`：
   - `batchrecross 0 started=false status=Optional(GPXPointViewer.BatchStatus.done)`
5. `ok` `batchrecross all`：
   - 回显 `batchrecross all started=99`
   - 最终 `requests = 304`（106 + 2 × 99）
   - `counts.agree = 100`，`counts.unverified = 0`
   - 公路项 `status` 全部 `done`
6. `ok` `batchclose`、`crosscheck 0` 回显正常。

证据：`artifacts/results/sec3.json`、`artifacts/logs/sec3/`。

---

## 4. 单处两路进度合成一行

实际调度：`python3 -u .../driver.py sec4`

设置回显：

```text
crosscheck true
fakeroute OSRM=ok Valhalla=ok
fakeroute OSRM=ok Valhalla=slow 4000
select 0
routecross busy=true
```

1. `ok` `routecross busy=true`
2. `ok` 命中中间态，原文：
   ```json
   {"routeBusy": "osrmCar", "crossLegs": [1, 0], "routeProgress": "OSRM ✓ · Valhalla 取路中…", "cross": null}
   ```
   - `crossLegs = [1, 0]`
   - `routeProgress = 'OSRM ✓ · Valhalla 取路中…'`
   - 只有一个 ` · `，无换行
3. `ok` 取完：
   ```json
   {"routeBusy": null, "crossLegs": [1, 1], "routeProgress": null, "cross": {"agree": true, "shown": "osrmCar", "other": "valhallaCar", "otherMeters": 362}}
   ```
   - `routeProgress = None`
   - `cross.agree = true`
4. `ok` `fakeroute all ok`、`crosscheck 0` 回显正常。

证据：`artifacts/results/sec4.json`、`artifacts/logs/sec4/`。

---

## 5. 三种语言主窗口补点模式（960×800）

实际调度：`python3 -u .../driver.py sec5all`（依次 `zh-Hans`、`en`、`de`）

每种语言均先执行：

```text
autotripmap false
set showStats = 1
frame (240.0, 60.0, 960.0, 800.0)
front key=true occluded=false
riskthreshold 50
crosscheck false
```

打开 `Garmin_Roma_Da_copy.gpx`：`46267` 点，补点模式 `candidates=100`。单处取路回显均为：

```text
fakeroute OSRM=ok Valhalla=ok
select 3
slept
route osrmCar busy=true
```

最终 `routeBusy = null`、`crossLegs = [0, 0]`、`routeProgress = null`（本节 `crosscheck 0`，不要求两路比对）。

| 语言 | 标题 / `info front=` | `windows` 尺寸 | 截图 | 截图尺寸 / 大小 | 视觉判据 |
|---|---|---|---|---:|---|
| `zh-Hans` | `GPX 点位查看器` | `w=960 h=800` | `.../artifacts/shots/r4_main_fill_zh-Hans.png` | `2144×1824` / `2511280` | 不判（未读图） |
| `en` | `GPX Point Viewer` | `w=960 h=800` | `.../artifacts/shots/r4_main_fill_en.png` | `2144×1824` / `2470319` | 不判（未读图） |
| `de` | `GPX-Punktbetrachter` | `w=960 h=800` | `.../artifacts/shots/r4_main_fill_de.png` | `2144×1824` / `2489244` | 不判（未读图） |

绝对路径：

- `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/artifacts/shots/r4_main_fill_zh-Hans.png`
- `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/artifacts/shots/r4_main_fill_en.png`
- `/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/artifacts/shots/r4_main_fill_de.png`

`shotwin` 原文示例：

- `zh-Hans`: `shotwin 2144x1824 -> /Users/zyx/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/r4_main_fill_zh-Hans.png`
- `en`: `shotwin 2144x1824 -> .../r4_main_fill_en.png`
- `de`: `shotwin 2144x1824 -> .../r4_main_fill_de.png`

每种语言结束均执行 `fakeroute all off`、`exit`，回显正常。  
视觉判据（左面板最底下两行完整可见、位于补点操作条上方、无省略号；德文左侧贴边只记录）**未由本代理读取图片验收**，交主代理检查。

证据：`artifacts/results/sec5_zh-Hans.json`、`sec5_en.json`、`sec5_de.json`；截图日志在 `artifacts/logs/sec5_zh-Hans/0015_shot_main_zh-Hans.log` 等。

---

## 6. 阈值方案 B：offset 项的分数（普通模式）

实际调度：`python3 -u .../driver.py sec6`

1. `ok` `riskthreshold off` 回显 `riskthreshold 50`
2. `ok` 批次到达 `preview`
   - `valhalla = 50`
   - `vHighExcl = 49`（≥ 95% × 50）
   - `oHigh = 0`
   - `counts.high = 49`，`nHigh = 49`
   - `counts`：`{'agree': 0, 'disagree': 0, 'unverified': 0, 'pending': 0, 'declined': 0, 'high': 49, 'medium': 9}`
3. **FAIL（严格按任务书判据）** `vMinRisk > 50`
   - 实际：`vMinRisk = 0`
   - `vRisk = {"0": 1, "55": 4, "85": 25, "95": 10, "100": 10}`
   - 原因：Valhalla 50 项中有 1 个 `ckind=stale` 的项 `risk=0`、`level=low`、`include=True`、`riskReasons=[]`，id `1792256646.0`。
   - 该 stale 项正是回归脚本 P2a 允许的「≤5% 非 high」项：P2a 为 49/50 high，已通过。
   - 剔除该 stale 项后，`vMinRisk = 55`，落在任务书自己定义的 `51–59`「偏差，交主会话，不算 FAIL」带内。
   - 因此这是**任务书严格判据与 P2a 95% 阈值/已知 stale 项之间的冲突**，不判为产品缺陷；但严格命令结果确实为 0，不能写成通过。
4. `ok` `batchclose`、`fakeroute all off` 回显正常。

证据：`artifacts/results/sec6.json`；stale 项明细见 `artifacts/logs/reg1/0002_reg1_run_plausibility_tests.log`。

---

## 7. 文档抽查 3 处（只读）

实际调度：`python3 -u .../driver.py docs`

1. `ok` README Swift 文件覆盖：
   - README 列出 `38` 个 Swift 文件，`missing=[]`
   - `GPXPointViewer/*.swift` 数量 `34`
   - `not_in_readme=[]`
2. `ok` `Regions.bin`：
   - `stat -f '%z'` → `29411770`
   - 文件头 → `[827213650, 1, 5319, 14275, 3496861, 64800]`
   - README 第 160 行命中 `29,411,770`
   - `docs/regions-design.md` 第 62/97 行命中 `29,411,770`
   - 两份文档均含 `5319`
3. `ok` 测试脚本数量：
   - `Tests/ui/run_*.py` → `31`
   - README 第 185 行命中 `31 个 run_`
   - `run_suite.sh` 中脚本名 → `25`
   - `Tests/README.md` 第 47/173/247 行均为 `25 个脚本`

证据：`artifacts/results/docs.json`。

---

## 8. 收尾：偏好复位、关闭副本、正式 app 检查

实际调度：`python3 -u .../driver.py cleanup`

### 8.1 `ok` 复位命令有回显，原文

```text
batchriskonly false visible=-1
batchcompact false
reviewfollow false
riskthreshold 50
crosscheck false
fakeroute OSRM=real Valhalla=real
reviewmap 标准 light=true
set mapStyle = 标准
set showStats = 1
exit
```

### 8.2 `ok` 测试副本已关闭

- `pkill -f Tests/ui/app.noindex/GPXPointViewer.app` 后 `pgrep` 结果：`none`
- 测试副本目录仍保留在任务指定路径 `Tests/ui/app.noindex/GPXPointViewer.app`，但进程已关闭。

### 8.3 `FAIL（环境基线不适用）` 「正式 app 仍在运行」

- 测前 `production_pgrep_before = []`
- 测后 `production_after = []`
- 即：测试前本就没有 `/Applications` 实例在运行，收尾时也没有；不是本轮关闭/覆盖造成的。
- 全程没有 kill、覆盖或安装 `/Applications/GPXPointViewer.app`，也没有启动正式 app。

### 8.4 `ok` 偏好恢复

- 偏好文件：`/Users/zyx/Library/Containers/de.wayne.GPXPointViewer/Data/Library/Preferences/de.wayne.GPXPointViewer.plist`
- 测前/测后 size 均为 `2755`
- 测前/测后 sha256 均为 `54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8`
- `artifacts/prefs_diff.txt`：`(no textual diff)`
- 已设置回：`riskthreshold 50`、`crosscheck false`、`fakeroute real`、`reviewmap 标准 light=true`、`mapStyle 标准`、`showStats 1`、`batchriskonly false`、`batchcompact false`、`reviewfollow false`。

证据：`artifacts/results/cleanup.json`、`artifacts/prefs_diff.txt`、`artifacts/prefs_before/`、`artifacts/prefs_after/`。

---

## 9. 问题分类

### 9.1 执行完成状态

- 第 1–8 节均执行；11 个回归脚本、合成 runner、4 个自测、UI 第 2–6 节、文档抽查、收尾复位均完成。
- 没有绕过权限，也没有执行任务书禁止的联网脚本 / `run_suite.sh` / `record`。
- 没有改产品源码、现有测试脚本、期望值、`Tests/exam/baseline.json`。
- 测试副本始终串行：回归脚本逐个 `pkill`/重起，UI 阶段一个副本一个语言。

### 9.2 产品断言通过/失败

- 已确认通过：11 个回归脚本（`FAILS: none`）、合成考卷 114/114 与逐字 `exam summary`、4 个自测 8/31/5/7、第 2 节 13/13、第 3 节 18/18、第 4 节 5/5、第 5 节 UI 断言 18/18、第 7 节 12/12。
- 明确失败：第 6 节 `vMinRisk > 50` 严格判据实际 `0`。该失败有明确的任务书判据冲突：同节 `vHighExcl ≥ 95%` 允许 1/50 非 high，而 `vMinRisk` 取全量最小值又要求全部 >50；实际唯一 0 分项是 `ckind=stale`。剔除 stale 后 `55`，落在任务书 `51–59` 偏差带。
- 因此**可判定的产品缺陷数为 0**；第 6 节严格判据的最终处置建议由主代理按任务书问题处理，不能把它静默改成通过。

### 9.3 环境未验收项

1. **4 张截图视觉验收未完成**（本代理未读取图片，未把未读图片标为通过）：
   - `r4_line_labels.png`：两个蓝底白字标签是否分别为 OSRM/Valhalla 且不重叠。
   - `r4_main_fill_zh-Hans.png`、`r4_main_fill_en.png`、`r4_main_fill_de.png`：左面板最底下两行是否完整可见、未被补点操作条盖住、无省略号；德文是否左侧贴边（只记录，不算本轮缺陷）。
2. **正式 app 运行检查**：测前/测后均无 `/Applications` 实例，无法满足「仍在运行」；属于环境基线，不是本轮关闭。
3. **版本证据边界**：已证明 `/Applications` 包含新字符串/新符号，但无法离线证明二进制与当前源码 HEAD 一一对应；synthrunner 是从当前工作区源码编译的，不能单独替代 `/Applications` 二进制的构建来源证明。
4. 网络计数来自产品假引擎/回放计数，没有做系统级抓包；`fakeroute` 的 `routeOverride` 在 URLSession 前返回，配合 `autotripmap 0` 可判定真实公共路网/瓦片/Overpass 请求为 0。

### 9.4 任务书问题（不计产品缺陷）

1. **准备第 3 步的 `grep -rlaF` 只按 UTF-8 搜索**：2/5 字符串在 UTF-16LE `.strings` 中，命令本身未命中；`diag` 已用编码补查证实存在。任务书同段给了补查提示，但原命令/期望仍是方法问题。
2. **第 6 节 `vMinRisk > 50` 判据与同节 `vHighExcl ≥95%` 及已知 stale 项冲突**：严格 min=0；剔除 stale 后 min=55（任务书自己的 51–59 偏差带）；P2a 49/50 high 已通过。需要主代理决定按剔除 stale 口径还是修改判据。
3. **第 5 节截图尺寸示例偏差**：任务书写 960×800 应输出 `2056×1736`，实测 `2144×1824`；`windows` 明确主窗口为 `960×800`，`shotwin` 尺寸只作记录，属任务书数值示例不一致。

### 9.5 明确未完成项

- 4 张截图的视觉验收：**未完成**，交主代理读图。
- 第 6 节 `vMinRisk > 50`：严格判据**未通过**，需按任务书问题处置；不能声称通过。
- 正式 app「仍在运行」检查：**不适用**（测前即无实例）。
- 真实公网/瓦片/Overpass 未做系统级抓包：按假引擎计数为 0；任务书未要求抓包。
- 按任务书明确排除、未执行的项：`run_batch_drift.py`、`run_crosscheck_online.py`、`run_route_tests.py`、`run_drift_tests.py`、`Tests/ui/run_suite.sh`、`Tests/exam/run_exam.sh --record`、Apple MKDirections、`--baseline`、真实数据联网复核。

---

**最终结论：不可以发布（产品缺陷数 0；任务书问题 3 项；4 张截图视觉验收未完成，待主代理读图确认；第 6 节严格 `vMinRisk` 判据需按任务书问题处置）**