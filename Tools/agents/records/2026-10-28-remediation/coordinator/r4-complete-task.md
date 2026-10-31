# DeepSeek R4 派发与权限补充

用户已授权修复代理工具后让 DeepSeek 完成 R4。此轮用 deepseek-flash / max，最多 180 turns、5400 秒，一次有界运行；费用未知保留 null。不是 USD 余额授权，不改旧账本。无公共路网测试授权。

完整主任务见 Tests/tasks/2026-10-28_loose_ends_threshold_r4_codex.md。执行顺序优先源码离线 synth + 四项自测，然后 UI/手工钩子。只有此轮一个 UI 客户端；正式 app 不关闭、不覆盖。始终 GPXPV_APP=/Applications/GPXPointViewer.app。

允许在 Tools/agents/records/2026-10-28-remediation/r4-work/ 创建本轮 Python 执行脚本 driver.py；通过 python3 该精确脚本运行任务书已列命令、准备数据、控制 Tests/ui/app.noindex 副本、读取只涉及本任务的源码/文档/日志。不要调用任意外部网络、安装软件、访问凭据或运行别的 agent。Python 能操作文件，命令授权不是 OS 隔离；任务边界及源码前后快照用于复核。

driver 中子进程必须记录 argv、开始/结束时间、退出码、完整 stdout/stderr 到本 run artifacts 或 r4-work/logs，终端可只输出摘要。每阶段更新本 run progress.md。长任务必须有截止时间；失败也要 cleanup。脚本可以使用 pathlib/subprocess/ui.send 等正常 Python 功能；不能修改生产源码、现有脚本或任何期望值以通过测试。

禁止用 shell 管道 tail 的退出状态当测试结果；不得因单条脚本失败就跳过所有独立检查。脚本返回退出 0 但 FAILS 非 none，仍算测试失败。API 正常完成与 R4 验收分开。

截图生成后报告 PNG 的绝对路径；最终视觉验收由主代理读取图片完成。DeepSeek 不需要把图片送到不支持视觉的 API，也不能将未读到的图片标为通过。

结束给完整逐项结果、证据路径、app/source 版本、实际网络/回放计数、问题分类、清理与偏好恢复情况。所有未完成项明确列出。禁止编造“已全部通过”。


# 任务：第 4 轮复测 · Codex 接手执行版（产品路网离线）

## 本次执行与留档补充（优先于旧命令示例）

- 完整复测范围仍为下文第1–8节。主应用测 `/Applications/GPXPointViewer.app` 的测试副本；合成runner从当前源码编译，分别记录版本与结果。不要自己构建或安装主应用。
- 模型使用 DeepSeek V4.1 Flash / max，由主代理以修复后的runner派发；代理API联网是已授权的，本文“不联网”约束指产品路网/瓦片/Overpass测试。禁止真实公共路网请求，禁止完整run_suite和record模式。
- 执行前先读runner给出的记录目录与允许命令。每完成一节更新本轮progress（已完成/正在做/下一步）。所有脚本完整stdout/stderr写入本轮目录，记录真实退出码；下文tail只是“报告应摘哪些行”，不能只保存tail或依赖管道最后一段的退出码。
- 可用新建于本轮目录的Python调度脚本将命令逐项subprocess执行并实时写完整日志，但不得改产品、现有测试脚本和期望。新增脚本内容也须留档。若工具命令许可挡住某步骤，记录精确拒绝与未完成项，通知主代理处理，不擅自绕过权限。
- 同一时间只跑一个产品测试副本；不关闭正式应用。先记录正式应用PID及偏好文件副本，结束执行第8节并记录原设置差异；不要直接导入整个偏好文件覆盖用户可能同时改变的设置。
- 每个回归不止看exit，也要检查FAILS/failed断言。如果系统锁屏、截图白图或无法看图片，标为未验收，交主代理检查；不得声称视觉检查通过。
- 取路前确认假引擎或录音回放已生效，记录实际网络计数。每节完成后可将一句摘要输出给runner，便于实时落盘。
- 结论分为：执行完成状态、产品断言通过/失败、环境未验收项、任务书问题。存在未验收项目时不能笼统写“可以发布”。

## 背景（这次改了什么）
1. **收尾八项**（`Tools/agents/runs/20261028_120149_loose-ends/output.md`；`docs/cross-check-design.md` 延后清单已标「已做」）：
   - 补点模式下左面板不再被补点操作条盖住：中段可以滚动，底部两行（「导出/图片/删除点/补点」和「修改记录」）固定不动。代码在 `ContentView.swift` 第 97、119 行（`padding(.bottom, bottomStackHeight - 2)`）和第 1632 行起的 `controlPanelFooter`。
   - 精确模式下两条分歧线的中点各标一个引擎名（OSRM / Valhalla）。钩子字段 `state.batch.lineLabels`。
   - 单处精确模式取路时，两路的进度合成一行，例如「OSRM ✓ · Valhalla 取路中…」（`TrackStore.crossProgressLine`，第 1654 行）。钩子字段 `state.routeProgress`、`state.crossLegs`。
   - 「只有一路结果」的项可以一键重新比对，两路都重取。钩子 `batchrecross all|<i>`。
   - 从 OSRM 回复的 `intersections[].classes` 算隧道占比。自测 `synthrunner --tunnel-selftest`。
   - replay 钩子新增测试 R1（在 `run_plausibility_tests.py` 里）。
   - `Tests/ui/run_suite.sh` 补到 25 个脚本。
2. **落地前自检阈值方案 B**（`Tools/agents/runs/20261028_132305_plausibility-threshold-b/output.md`；`docs/fill-plausibility-design.md` §1.3、§5、§8）：
   - `taperExcess` 阶梯改为：≤10 扣 0；10–18 扣 30；>18 扣 50。
   - 补点少于 4 个时，按折线顶点采样。
   - 新增自测 `synthrunner --plausibility-selftest`，7 个用例。
3. **文档刷新**（`Tests/reports/20261028_1257_2026-10-28_docs_refresh.md`）：README 的「文件结构」一节、`docs/regions-design.md` 的内置数据现状。

## 范围
- **要测**：
  - 11 个钩子回归脚本、合成套件（含考卷汇总行）、4 个 synthrunner 自测；
  - 分歧线标签、一键重比对、单处进度合一行、左面板底两行、阈值 B 下 offset 项的分数；
  - 文档抽查 3 处。
- **不用测**：
  - 联网的路网 / 瓦片 / Overpass（一律用假引擎 `fakeroute`）；
  - 真实数据复核（只抄「已知数据事实」里的数字，**不要**自己联网复核）；
  - 本地化措辞（只看有没有省略号、有没有被遮挡，不评翻译）；
  - Apple MKDirections；`--record` 录制；`--baseline`。
- **锁屏时截图全白**：`python3 Tests/ui/ui.py info` 的输出里会有 `front=loginwindow`。这时截图项写「锁屏，不判」，只抄 `shotwin` 返回的那一行，不算缺陷。

## 已知数据事实（免得误判）
- `Garmin_Roma_Da_copy.gpx` 候选数 **100**。来源：`Tests/ui/run_profile_tests.py` 的 P2（`check(s['candidates'] == 100, …)`）。
- `Muenchen_Roma_Garmin.gpx` 候选数 **50**。来源：`Tests/synth/runner/check_garmin_tunnel.py` 文档串「候选 50 处」；`run_tunnel_fix_tests.py` 的输出里也有 `candidates=50`。
- **`fakeroute valhalla offset 30` 下，Valhalla 做的项判成 high（界面上是「要看一眼」）、默认不勾选，这是预期行为，不是缺陷。**
  - 原因：假引擎的「路网原始折线」就是直弦，offset 模式把补点整体平移 30 m，于是 devRouteMax 落进 >30 m 档，扣 60 分。
  - 来源：`GPXPointViewer/UITestHook.swift` 第 61–70 行注释；设计文档 §1.3 表格 devRouteMax 一行；`Tests/ui/run_plausibility_tests.py` 第 83 行注释（「偏 30 m 的项 risk 约 95–100」）。
- **`fakeroute all ok` 下允许少量 medium。** 判据以脚本为准：有草稿的项里 low ≥ 75%、high ≤ 2%（`run_plausibility_tests.py` 第 67 行）。
- **考卷数字（方案 B 之后）**：
  - OSRM、Valhalla 都是 pass **121/125**；伪影 `perturb artefact` **123/125** 判 high；平行路 `parallel` **125/125** 判 high；误报为 0（`high∧pass 0`）。
  - 4 道未通过的题是 `rd_1-3min_0093`、`rd_20-60s_0091`、`rd_3-8min_0092`、`rd_1-3min_0120`，原因是数据偏差，不是缺陷。
  - 来源：阈值 B 的 output.md §2「改后」那一行；设计文档 §5 表格。
- **真实数据基线**（只作记录，**不要**联网复核）：Muenchen_Roma_Garmin 50 处，精确模式下 high 0 / medium 4 / low 46，两路 agree 50。来源：阈值 B 的 output.md §4。
- 精确模式下 `fakeroute valhalla fail` 会让公路项全部变成 `conflict:unverified`，`engineDisabled` 里含「Valhalla」。这是原有行为。来源：`run_crosscheck_tests.py` 的 C1/C2。
- **锁屏时 `run_map_sources_tests.py` 的 M1c 会假失败**（截图全白）。如果 `info` 显示 `front=loginwindow`，M1c 的 FAIL 记作「锁屏，不判」，不算缺陷。来源：`Tests/ui/run_suite.sh` 第 21 行注释；`Tests/README.md` §3.6。
- **文档期望已修正**：Tests/README.md 的相关三处当前均已是 25 个脚本。旧待办中 19 vs 25 的条目已过时；本轮以当前实际列表核对，不把已经改成 25 当成异常。

## 硬规则
- **不联网。**
  - 每次起测试副本后，第一条命令就是 `python3 Tests/ui/ui.py "autotripmap 0"`（不关的话 `batchplan` 会去查 Overpass）。
  - 任何 `batchrun` / `batchrecross` / `route car` / `routecross` 之前，必须已经设好 `fakeroute all ok`，或者本文指定的假模式。
  - **不要运行**：`run_batch_drift.py`、`run_crosscheck_online.py`、`run_route_tests.py`、`run_drift_tests.py`、`Tests/ui/run_suite.sh`（列表里有联网脚本）、`Tests/exam/run_exam.sh --record`。
- **一次只开一个测试副本**，即 `Tests/ui/app.noindex/GPXPointViewer.app`。关它只用 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。
  - `/Applications/GPXPointViewer.app` 是用户在用的实例：**不要 kill、不要覆盖、不要安装**。
- **会自己起副本的脚本**，每个跑之前先 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`，一个接一个跑，不并行。这类脚本有 7 个：`run_plausibility_tests.py`、`run_crosscheck_tests.py`、`run_batch_review_tests.py`、`run_batch_card_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`、`run_map_sources_tests.py`。
  - 另外 4 个要先有副本在跑：`run_fill_tests.py`、`run_review_tests.py`、`run_network_tests.py`、`run_profile_tests.py`。
  - `run_profile_tests.py` 已改为自己等重算结束，可以接在别的脚本后面跑（见第 3 轮任务书文末「2026-10-28 修订记录」第 8 条）。
- **结束必须复位偏好**。测试副本和 /Applications 那份共用容器偏好，所以中途失败也要做：
  `python3 Tests/ui/ui.py "batchriskonly 0" "batchcompact 0" "reviewfollow 0" "riskthreshold off" "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "set mapStyle 标准" "set showStats 1"`
  - `showStats` 默认就是 1（`GPXPointViewer/TrackData.swift`），第 5 节截图要打开它。
- 不改代码、测试脚本、期望值、`Tests/exam/baseline.json`；不构建 Xcode 工程。
- 窗口尺寸不超过本机屏幕（1440×932）：本文用到的最大窗口是 960×800。

## 准备（完整写法）
1. 所有命令都在仓库根执行：`cd /Users/zyx/Documents/GPXPointViewer`。
2. **确认测的是 /Applications 那份。** 先在当前 shell 执行 `export GPXPV_APP=/Applications/GPXPointViewer.app`，后面所有命令都在**同一个 shell** 里跑。原因：`ui.app_source()` 的查找顺序是 `GPXPV_APP` > DerivedData Release > `/Applications`，另一个任务可能正往 DerivedData 构建没完成的版本。
   ```sh
   export GPXPV_APP=/Applications/GPXPointViewer.app
   echo "GPXPV_APP=[$GPXPV_APP]"
   python3 -c "import sys; sys.path.insert(0,'Tests/ui'); import ui; print(ui.app_source())"
   ls -l /Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer
   pgrep -fl /Applications/GPXPointViewer.app || echo "no /Applications instance"
   ```
   期望：
   - 第二条命令打印 `/Applications/GPXPointViewer.app`。
   - 把可执行文件的修改时间和 `pgrep` 的输出抄进报告。
   - `info` 和 `front=` 要等第 5 步起了副本之后再取（副本没起来时，`info` 只会返回 TIMEOUT）。
3. **确认装上的是新版本**（包里要有本轮新加的字符串）：
   ```sh
   for s in '重新比对这一处（两路重取）' '全部重新比对' '取路中…' '已扣除端部允许的' '主地图跟随'; do printf '%s: ' "$s"; grep -rlaF "$s" /Applications/GPXPointViewer.app/Contents | head -1; echo; done
   ```
   期望：5 个都打印出路径。缺任何一个就停下，报告「/Applications 不是新版本」。
   来源：loose-ends output.md「本地化」节；阈值 B output.md §1.4。
4. **容器与数据：**
   ```sh
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   mkdir -p "$C/uitest"
   zsh Tests/ui/setup_data.sh
   [ -f "$C/uitest/Garmin_Roma_Da_copy.gpx" ] || cp data/Garmin_Roma_Da_copy.gpx "$C/uitest/"
   [ -f "$C/uitest/Muenchen_Roma_Garmin.gpx" ] || cp data/compare/Muenchen_Roma_Garmin.gpx "$C/uitest/"
   ls -l "$C/uitest/Garmin_Roma_Da.gpx" "$C/uitest/Garmin_Roma_Da_copy.gpx" "$C/uitest/Muenchen_Roma_Garmin.gpx" "$C/uitest/stepLife.csv"
   ```
   期望 4 个文件都在。变量 `C` 不跨命令保留，下面每条要用它的命令里都会重新赋值。
5. **「起副本（语言 L）」**：整段执行（L 默认 `zh-Hans`）：
   ```sh
   L=zh-Hans
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
   mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
   open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages "($L)"
   ```
   然后：
   - 每秒跑一次 `python3 Tests/ui/ui.py state`，直到返回含 `"points"` 的 JSON（最多等 40 s）。
   - 执行 `python3 Tests/ui/ui.py "autotripmap 0" "place 0" "front" "set mapStyle 标准"`。
   - 再执行 `python3 Tests/ui/ui.py info`，把 `front=` 抄进报告。
6. **发命令**：`python3 Tests/ui/ui.py "cmd1" "cmd2" …`。其中 `sleep 800` 的单位是毫秒。
7. **「打开 Garmin 并进补点模式」**：整段执行：
   ```sh
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"
   ```
   - 每秒看 `state`，直到 `loading` 为 false 且 `points` > 0。
   - 再执行 `python3 Tests/ui/ui.py "batchclose" "exit" "sleep 300" "fill" "sleep 1500"`。
   - 等到 `refreshing` 为 false 且 `candidates` = **100**。
8. **「跑批次」**：执行 `python3 Tests/ui/ui.py "batchclose" "sleep 300" "batchplan" "sleep 800" "batchall road" "sleep 300" "batchrun"`。之后每 2 s 跑一次「批次摘要」，直到打印 `phase preview`（最多 240 s）。
9. **只读查询**（下文直接用名字）：
   - **批次摘要**：
     ```sh
     python3 Tests/ui/ui.py state | python3 -c "import sys,json,collections;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);b=s['batch'] or {};it=b.get('items',[]);rd=[x for x in it if x['kind']=='road'];st=lambda x:x['status'] if x['status'].startswith('conflict') else x['status'].split(':')[0];print('phase',b.get('phase'),'items',len(it),'road',len(rd),'counts',b.get('counts'));print('requests',b.get('requests'),'lines',b.get('lines'),'lineLabels',b.get('lineLabels'),'selected',b.get('selected'),'engineDisabled',b.get('engineDisabled'));print('status',dict(collections.Counter(st(x) for x in it)),'cross',dict(collections.Counter(x['cross'] for x in it)));print('firstUnv',next((i for i,x in enumerate(it) if x['status']=='conflict:unverified'),None),'firstDis',next((i for i,x in enumerate(it) if x['status']=='conflict:disagree'),None));v=[x for x in rd if x['status']=='done' and x['source']=='valhallaCar'];o=[x for x in rd if x['status']=='done' and x['source']=='osrmCar'];print('valhalla',len(v),'vHighExcl',sum(1 for x in v if x['riskLevel']=='high' and not x['include'] and x['riskReasons']),'vMinRisk',min([x['risk'] for x in v if x['risk'] is not None] or [None]),'vRisk',sorted(collections.Counter(x['risk'] for x in v).items()));print('osrm',len(o),'oHigh',sum(1 for x in o if x['riskLevel']=='high'),'nHigh',sum(1 for x in rd if x['riskLevel']=='high'))"
     ```
   - **第 i 项**（把 `I=` 后面换成序号）：
     ```sh
     I=0; python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);b=s['batch'];x=b['items'][int(sys.argv[1])];print('requests',b['requests'],'status',x['status'],'cross',x['cross'],'routes',len(x['routes']),'source',x['source'],'counts',b['counts'])" $I
     ```
   - **单处进度**：
     ```sh
     python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);print('routeBusy',s.get('routeBusy'),'crossLegs',s.get('crossLegs'),'routeProgress',repr(s.get('routeProgress')),'cross',s.get('cross'))"
     ```
10. **本轮用到的钩子**（都已在 `GPXPointViewer/UITestHook.swift` 的 `case "…"` 里核实）：
    - 文件与模式：`open`、`fill`、`exit`、`select <i>`。
    - 取路与假引擎：`crosscheck 0|1`、`fakeroute <osrm|valhalla|all> <ok|offset <米>|noroute|fail|slow <毫秒>|off>`（回显形如 `fakeroute OSRM=… Valhalla=…`）、`routecross`、`routecache clear`、`autotripmap 0|1`。
    - 批次：`batchplan`、`batchall road`、`batchrun`、`batchclose`、`batchnextconflict`（选中下一处「要你选的」项，主地图飞过去）、`batchrecross all|<i>`（回显 `batchrecross all started=N` 或 `batchrecross <i> started=true|false status=…`）。
    - 门槛与地图：`riskthreshold <n>|off`（回显当前门槛）、`mapgoto <lat> <lon> <km>`。
    - 复位：`batchriskonly 0`、`batchcompact 0`、`reviewfollow 0`、`reviewmap standard light 1`、`set mapStyle 标准`、`set showStats 0|1`。
    - 窗口与截图：`frame <x> <y> <w> <h>`、`windows`、`shotwin <标题子串> <png 路径>`。
    - 其它：`state`、`info`、`front`、`place 0`。
    - `state.batch` 的字段：`phase counts{agree,disagree,unverified,pending,declined,high,medium} requests lines lineLabels selected engineDisabled items[]{kind,status,cross,source,include,routes,risk,riskLevel,riskReasons}`。
    - `state` 顶层字段：`routeBusy routeProgress routeProgressDetail crossLegs cross route candidates points loading refreshing`。

## 测试项

### 1. 回归脚本（11 个）+ 合成套件 + 4 个自测
每个脚本抄最后 5 行，末行是 `FAILS: none` 就算通过。第 1–7 条每条都带 `pkill`，各自新起副本。
1. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_plausibility_tests.py 2>&1 | tee /tmp/r4_pl.log | tail -25`
   - 期望：P0…P4c、U1a…U4、R1a、R1b 全部 `ok`，末行 `FAILS: none`。
   - 抄这几行：P2a（以 `counts.high=<数字>` 结尾）、R1a（期望 `netRequests N → N`，前后相等）、R1b（期望 `source': 'osrmCar'`、`replayHits` 增加）。
   - 来源：脚本第 76、158–159 行；loose-ends output.md §6。
2. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_crosscheck_tests.py 2>&1 | tee /tmp/r4_cc.log | tail -40`
   - 期望：全部 `ok`，末行 `FAILS: none`。
   - 抄这几行原文：B15（上次 `lineLabels 2 ≥ 2`）、B16（上次 `lineLabels 0 = 0`）、R1（上次 `requests 101→103 status=done cross=agree`）、R2（`started=false`）、R3（上次 `started=96 requests 103→295（+192）`）、E5（上次 `'OSRM ✓ · Valhalla 取路中…' crossLegs=[1, 0]`）、E6。
   - 来源：脚本第 105–178 行；loose-ends output.md「测试结果」。
3. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_batch_review_tests.py 2>&1 | tee /tmp/r4_br.log | tail -5` → 末行 `FAILS: none`。
4. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_batch_card_tests.py 2>&1 | tee /tmp/r4_card.log | tail -5` → 末行 `FAILS: none`。
5. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_route_cache_tests.py 2>&1 | tee /tmp/r4_rc.log | tail -5` → 末行 `FAILS: none`。
6. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_map_sources_tests.py 2>&1 | tee /tmp/r4_map.log | tail -8` → 末行 `FAILS: none`。
   - 如果只有 M1c 一项 FAIL，而且锁屏（见「已知数据事实」），就记「M1c 锁屏，不判」。
7. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_tunnel_fix_tests.py 2>&1 | tee /tmp/r4_tf.log | tail -12`
   - 期望：全部 `ok`，含 `candidates=50`，末行 `FAILS: none`。
   - 脚本结束后副本还开着，紧接着跑第 8 条。
8. `python3 Tests/ui/ui.py "autotripmap 0" "set mapStyle 标准"; python3 -u Tests/ui/run_fill_tests.py 2>&1 | tail -5` → 末行 `FAILS: none`。如果 `python3 Tests/ui/ui.py state` 不返回 JSON，先按「准备」第 5 步起副本再跑。
9. `python3 -u Tests/ui/run_review_tests.py 2>&1 | tail -5` → 末行 `FAILS: none`。
10. `python3 Tests/ui/ui.py "autotripmap 0" "set mapStyle 标准"; python3 -u Tests/ui/run_network_tests.py 2>&1 | tail -6`
    - 期望：N0、N1、N2 都是 `ok`，末行 `FAILS: none`。
    - 这个脚本用 `netfail`/`netok` 注入失败，自己不发网络请求；但它会调 `batchplan`，所以前面必须先发 `autotripmap 0`。来源：脚本第 14–22 行。
11. `python3 -u Tests/ui/run_profile_tests.py 2>&1 | tee /tmp/r4_profile.log | tail -8`
    - 期望：含 `ok   P2 Garmin 候选 100`，末行 `FAILS: none`。
    - 这个脚本会自己等重算结束，可以接在第 10 条后面跑。
12. `sh Tests/synth/runner/run_all.sh > /tmp/r4_all.out 2>&1; echo "exit=$?"; grep -E 'build ok|summary: |FAILED' /tmp/r4_all.out; tail -1 /tmp/r4_all.out`
    - 期望：
      - `exit=0`（`run_all.sh` 末尾会把考卷的退出码传出来；有回归时是 1）；
      - 有 `build ok`；
      - 有 `summary: 114 entries in 6 families, ok 114`；
      - 没有 `FAILED` 行；
      - **末行逐字等于**：
        `exam summary: questions 125 · detected 110 · osrm: pass 121/125 noRecording 0 error 0 | high∧fail 0 high∧pass 0 → hit 0% falseAlarm 0% | perturb artefact 123/125 parallel 125/125 high · valhalla: pass 121/125 noRecording 0 error 0 | high∧fail 0 high∧pass 0 → hit 0% falseAlarm 0% | perturb artefact 123/125 parallel 125/125 high · agree 125 disagree 0 agreeButFail 4 · bands 1-3min 78/82 10-20s 30/30 20-60s 82/84 3-8min 50/52 <10s 2/2 · requests sent 0 replayed 255 missing 0`
      - 不含 `REGRESSIONS`。
    - 末行整行原文抄进报告。如果 `artefact` 是 109/125，说明本步骤所编译的工作区源码/考卷结果未达到方案 B，判 FAIL；这个源码runner不能单独证明 /Applications 二进制版本。
    - 来源：阈值 B output.md §2「改后」与 §3；`run_all.sh` 第 56–61 行。
13. **四个自测**。都用第 12 条编好的 `Tests/synth/runner/synthrunner`，在仓库根执行（portal 的夹具路径是相对 cwd 的 `Tests/synth/fixtures/tunnel`，见 `main.swift` 第 374 行）。这几个自测**没有「x/x ok」汇总行**：每个用例输出一行 JSON，结果只看退出码（`main.swift` 第 366、527、629、695 行）。每条单独执行：
    - `Tests/synth/runner/synthrunner --portal-selftest > /tmp/r4_portal.out 2>&1; echo "exit=$?"; grep -c '"ok":true' /tmp/r4_portal.out; grep -c '"ok":false' /tmp/r4_portal.out; tail -1 /tmp/r4_portal.out`
      → `exit=0`、`8`、`0`；末行含 `"case":"anchor_warning_taper_vs_residual"` 和 `"ok":true`。
    - `Tests/synth/runner/synthrunner --crosscheck-selftest > /tmp/r4_cross.out 2>&1; echo "exit=$?"; grep -c '"ok":true' /tmp/r4_cross.out; grep -c '"ok":false' /tmp/r4_cross.out; tail -1 /tmp/r4_cross.out`
      → `exit=0`、`31`、`0`；末行含 `"case":"drafts_shift_differs_inner_agrees"` 和 `"ok":true`。
    - `Tests/synth/runner/synthrunner --tunnel-selftest > /tmp/r4_tunnel.out 2>&1; echo "exit=$?"; grep -c '"ok":true' /tmp/r4_tunnel.out; grep -c '"ok":false' /tmp/r4_tunnel.out; tail -1 /tmp/r4_tunnel.out`
      → `exit=0`、`5`、`0`；末行是 `{"case":"plausibility_tunnel_waive","ok":true,"riskNil":10,"riskLow":10,"riskHigh":0}`（loose-ends output.md §5）。
    - `Tests/synth/runner/synthrunner --plausibility-selftest > /tmp/r4_plaus.out 2>&1; echo "exit=$?"; grep -c '"ok":true' /tmp/r4_plaus.out; grep -c '"ok":false' /tmp/r4_plaus.out; cat /tmp/r4_plaus.out`
      → `exit=0`、`7`、`0`。7 个 case 依次是：`taper_excess_ladder`、`archetype_taper32_snap12_is_high`、`taper_excess_reason_mentions_excess`、`artefact_profile_is_high`、`dev_reason_mentions_allowance`、`sparse_points_sample_vertices`、`retarget_clips_vertices`。另外：
      - `taper_excess_ladder` 那一行应为 `"excess8":0,"excess15":30,"excess18":30,"excess20":50,"excess25":50`；
      - `archetype_taper32_snap12_is_high` 那一行的 `risk` > 50。
      - 来源：`main.swift` 第 656–694 行；阈值 B output.md §1.2、§3。
    - 数量 8 / 31 / 5 / 7 的来源：阈值 B output.md §3。
- 任何脚本失败，都附上 `tail -30 $HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/log.txt`。

### 2. 分歧线引擎名标签（精确模式，Valhalla 偏 30 m）
先「起副本（zh-Hans）」，再「打开 Garmin 并进补点模式」。然后执行 `python3 Tests/ui/ui.py "riskthreshold off" "crosscheck 1" "fakeroute osrm ok" "fakeroute valhalla offset 30" "routecache clear"`。
1. 「跑批次」，等到 preview，跑「批次摘要」。
   - 期望：公路项全部是 `conflict:disagree`；`cross` 全部是 `disagree`；`counts.disagree` = road；`lines` ≥ 2 × road。
   - 第 3 轮实测是 100 项 `conflict:disagree`。
   - 来源：第 3 轮任务书 §2 第 3 条；`run_crosscheck_tests.py` 的 B1/B5。
2. `python3 Tests/ui/ui.py "batchnextconflict"`：回显含 `selected=`。然后每 0.5 s 跑一次「批次摘要」，最多 15 s，直到 `lineLabels` ≥ 2。
   - 期望：`lineLabels` ≥ **2**，实际数字照抄。如果视野里相邻的分歧线也够长，可能大于 2，这是正常的。
   - 来源：B15（`run_crosscheck_tests.py` 第 105–106 行）；loose-ends output.md §2（屏幕上短于 90 pt 的线不标）。
3. `python3 Tests/ui/ui.py "mapgoto 45 11 3000" "sleep 1500"`，回显以 `mapgoto 45.0000,11.0000 span=` 开头。再跑「批次摘要」。
   - 期望：`lineLabels` = **0**，`lines` ≥ 2（线还画着，只是不标）。来源：B16（第 107–108 行）。
4. 存证（锁屏就写不判）：
   - 先执行 `python3 Tests/ui/ui.py "batchnextconflict" "sleep 2500"`。
   - 再执行 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotwin GPX $C/uitest/r4_line_labels.png"`。
   - 看图判据：两条蓝线中点附近各有一个蓝底白字标签，分别是「OSRM」和「Valhalla」，两个标签不重叠。看不了图片就写「交主会话看」。

### 3. 「只有一路结果」一键重比对
接第 2 节（副本、精确模式都不变）。
1. `python3 Tests/ui/ui.py "fakeroute valhalla fail" "routecache clear"`，再「跑批次」，等到 preview，跑「批次摘要」。
   - 期望：公路项全部是 `conflict:unverified`；`cross` 全部是 `unverified`；`counts.unverified` = road；`engineDisabled` 里含 `Valhalla`。
   - 记下 `firstUnv` = I、`requests` = R0、`counts.unverified` = U0。来源：C1/C2。
2. `python3 Tests/ui/ui.py "fakeroute valhalla ok"`：回显含 `Valhalla=ok`。
3. `python3 Tests/ui/ui.py "batchrecross <I>"`（把 `<I>` 换成上一步记下的数字）：回显含 `started=true`。
   - 然后每 0.5 s 跑一次「第 i 项」（`I=<I>`），最多 60 s，直到 `status` 既不是 `running` 也不是 `conflict:unverified`。
   - 期望：`requests` = R0 + **2**；`status done`；`cross agree`；`routes 2`；`counts.unverified` = U0 − 1。
   - 来源：R1（`run_crosscheck_tests.py` 第 126–130 行）。
4. `python3 Tests/ui/ui.py "batchrecross <I>"`：回显含 `started=false`（已经不是 unverified 的项不再重取）。来源：R2。
5. 跑「批次摘要」，记下 `requests` = R1、`counts.unverified` = U1。
   - 执行 `python3 Tests/ui/ui.py "batchrecross all"`：回显是 `batchrecross all started=U1`。
   - 然后每 2 s 跑一次「批次摘要」，最多 120 s，直到 `status` 里没有 `running`，并且 `requests` ≥ R1 + 2×U1。
   - 期望：`requests` = R1 + 2×U1；`counts.unverified` = **0**；`counts.agree` = road；公路项 `status` 全部是 `done`。
   - 来源：R3（第 135–139 行）是 Valhalla 继续 fail 的版本，那时 unverified 数不变。这里 Valhalla 已恢复，按 `recrossUnverifiedAll` 的实现（loose-ends output.md §4）应全部变一致。
6. 执行 `python3 Tests/ui/ui.py "batchclose" "crosscheck 0"`。

### 4. 单处两路进度合成一行
接第 3 节（副本不变）。
1. `python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500"`，等到 `refreshing` 为 false 且 candidates = 100。
2. `python3 Tests/ui/ui.py "crosscheck 1" "fakeroute all ok" "fakeroute valhalla slow 4000" "select 0" "sleep 500" "routecross"`：回显含 `routecross busy=true`。立刻接着跑：
   ```sh
   for i in $(seq 1 30); do python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);print(s.get('routeBusy'),s.get('crossLegs'),repr(s.get('routeProgress')))"; sleep 0.25; done
   ```
   期望：至少有一行是 `crossLegs` = `[1, 0]`，同时 `routeProgress` = `'OSRM ✓ · Valhalla 取路中…'`。也就是：以 `OSRM ✓ · Valhalla` 开头、只有一个 ` · `、不含换行。把那一行原文抄进报告。
   - 来源：E5（第 172–176 行）；`TrackStore.swift` 第 1654–1661 行。
3. 再每秒跑一次「单处进度」，最多 40 s，直到 `routeBusy None`。
   - 期望：`routeProgress None`；`cross` 里 `'agree': True`。来源：E6（第 177–178 行）。
4. 执行 `python3 Tests/ui/ui.py "fakeroute all ok" "crosscheck 0"`。

### 5. 三种语言的主窗口补点模式：左面板底两行（960×800）
L 依次取 `zh-Hans`、`en`、`de`。主窗口标题 T 分别是 `GPX 点位查看器`、`GPX Point Viewer`、`GPX-Punktbetrachter`（来源：`Tests/ui/shots_plausibility_ui.py` 第 15 行）。**不要**运行 `shots_plausibility_ui.py` 本身，它会覆盖仓库里的样例截图。
1. 「起副本（语言 L）」。
2. `python3 Tests/ui/ui.py "autotripmap 0" "set showStats 1" "frame 240 60 960 800" "front" "riskthreshold off" "crosscheck 0"`，然后做「打开 Garmin 并进补点模式」。
3. `python3 Tests/ui/ui.py "fakeroute all ok" "select 3" "sleep 400" "route car"`。每秒跑「单处进度」，直到 `routeBusy None`。再执行 `python3 Tests/ui/ui.py "frame 240 60 960 800" "sleep 1500"`。
4. `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotwin <T> $C/uitest/r4_main_fill_<L>.png" "windows"`，然后执行 `python3 Tests/ui/ui.py info`，抄 `front=`。
   - 用 `windows` 的输出读主窗口 T 的尺寸，必须是 `w=960 h=800`。
   - `shotwin` 返回的尺寸只作记录：截图四边各带 34 pt 阴影，所以 960×800 的窗口会输出 2056×1736，不能拿它当窗口尺寸。来源：第 3 轮修订记录第 4 条。
5. 看图判据（锁屏或全白写「锁屏，不判」；看不了图片写「交主会话看」）：
   - a) 左面板最底下两行都**完整可见**，而且都在底部补点操作条的**上方**，没有被盖住：一行是「导出 / 图片 / 删除点 / 补点」（或对应译文，只显示图标也算对），另一行是「修改记录」按钮（en 为 `Change Log` 一类译文）。来源：loose-ends output.md §1；`ContentView.swift` 第 1632–1660 行。
   - b) 底行没有「…」省略号。
   - c) 中段如果放不下，可以出现滚动条或被截短，这是预期行为。
   - d) 德文面板内容贴着左边，这是改之前就有的问题（loose-ends output.md §1 最后一条），只记录，不算本轮缺陷。
   - 对比上轮的已知问题（操作条盖住底行，第 3 轮任务书 §7.5c）：**本轮应已修复**。还被盖住就判 FAIL。
6. 每种语言做完都执行 `python3 Tests/ui/ui.py "fakeroute all off" "exit"`。

### 6. 阈值方案 B：offset 项的分数（普通模式）
先「起副本（zh-Hans）」，再「打开 Garmin 并进补点模式」。
1. `python3 Tests/ui/ui.py "riskthreshold off" "crosscheck 0" "fakeroute all ok" "fakeroute valhalla offset 30" "routecache clear"`。
   - `riskthreshold off` 的回显必须是 `riskthreshold 50`（`UITestHook.swift` `case "riskthreshold"`；设计文档 §1.3「low <20 ≤ medium ≤ 50 < high」）。
2. 「跑批次」，等到 preview，跑「批次摘要」。期望：
   - `valhalla` > 0，而且 `vHighExcl` ≥ 95% × `valhalla`（high、原因非空、默认不勾选）。来源：P2a。
   - `vMinRisk` > **50**（判据），实际值照抄。参考值：这些项的 devRouteMax > 30 m，按设计文档 §1.3 表格扣 60 分，所以预期 ≥ 60；脚本第 83 行注释写的是「约 95–100」。如果 `vMinRisk` 在 51–59 之间，记「偏差，交主会话」，不算 FAIL。`vRisk` 的分布整行抄进报告。
   - `oHigh` = **0**（OSRM 做的项没有 high；P2c）。
   - `counts.high` = `nHigh`（P2b）。
3. 方案 B 本身（taperExcess 改档、顶点采样）不能靠假引擎触发：offset 模式不产生 taper。它由第 1 节第 12 条（`perturb artefact 123/125`）和第 13 条（`--plausibility-selftest` 7 例）验证，这里不再重复。
4. 执行 `python3 Tests/ui/ui.py "batchclose" "fakeroute all off"`。

### 7. 文档抽查 3 处（只读）
1. **README 列出的 Swift 文件都存在，而且 app 的每个 Swift 文件都在 README 里有一行：**
   ```sh
   grep -E '├──|└──' README.md | grep -oE '[A-Za-z0-9_+]+\.swift' | sort -u > /tmp/r4_readme_swift.txt; wc -l < /tmp/r4_readme_swift.txt
   while read f; do [ -n "$(find GPXPointViewer GPXQuickLook GPXThumbnail Tests Tools -name "$f" 2>/dev/null | head -1)" ] || echo "MISSING $f"; done < /tmp/r4_readme_swift.txt
   ls GPXPointViewer/*.swift | wc -l
   for f in GPXPointViewer/*.swift; do grep -qF "$(basename "$f")" README.md || echo "NOT_IN_README $f"; done
   ```
   期望：没有 `MISSING` 行；`ls` 打印 **34**；没有 `NOT_IN_README` 行。来源：文档刷新报告「验证」表「README 文件结构覆盖度」（34；34）。
2. **`Regions.bin` 的大小、文件头与文档一致：**
   ```sh
   stat -f '%z' GPXPointViewer/Regions.bin
   od -An -t u4 -N 24 GPXPointViewer/Regions.bin
   grep -n '29,411,770' README.md docs/regions-design.md
   grep -n '5319' README.md docs/regions-design.md | head -5
   ```
   期望：
   - `29411770`；
   - `827213650 1 5319 14275 3496861 64800`（空白个数不限）；
   - README 第 160 行和 `docs/regions-design.md` 都命中 `29,411,770`；
   - 两份文档都有 `5319`。
   - 来源：文档刷新报告「验证」表前两行；README 第 160 行。
3. **测试脚本数量：**
   ```sh
   ls Tests/ui/run_*.py | wc -l
   grep -n '31 个 run_' README.md
   grep -oE 'run_[a-z_]+\.py' Tests/ui/run_suite.sh | wc -l
   grep -n '25 个脚本\|19 个脚本' Tests/README.md
   ```
   期望：
   - `31`；
   - README 第 185 行命中；
   - `25`；
   - `Tests/README.md` 的对应说明均应与实际全套列表一致，当前为 25；旧任务书要求保留19已过时。
   - 来源：文档刷新报告「验证」表「Tests 数量」；`run_suite.sh` 第 19–20 行。

### 8. 收尾（必须做，中途失败也要做）
```sh
python3 Tests/ui/ui.py "batchriskonly 0" "batchcompact 0" "reviewfollow 0" "riskthreshold off" "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "set mapStyle 标准" "set showStats 1" "exit"
pkill -f Tests/ui/app.noindex/GPXPointViewer.app
pgrep -fl /Applications/GPXPointViewer.app || echo "no /Applications instance"
```
- 如果副本已经被上一个脚本关掉，复位命令会返回 `TIMEOUT`。这时先按「准备」第 5 步起副本，再把复位命令执行一次。
- 把复位命令的回显原文抄进报告。
- 测前 `pgrep` 有输出的，现在也应该还有。

## 报告格式
- 报告在本次runner的唯一运行目录 `output.md` 由runner保存；所有原始日志、截图副本、阶段结果写本轮目录。runner可额外导出 Tests/reports/ 唯一命名副本，禁止按分钟覆盖。
- 开头写：测的 app 路径（`ui.app_source()` 的输出）、可执行文件的修改时间、`info` 里的 `front=`、「准备」第 3 步 5 个字符串的结果。
- 每个小步一行：`ok` / `FAIL` / `不判（原因）`，加上实际执行的命令和关键输出原文（数字原样抄）。
  - 第 1 节每个脚本抄末行原文；
  - `run_all.sh` 的 `exam summary:` 整行照抄；
  - 4 个自测抄退出码、ok/false 计数和末行。
- FAIL 要写：现象、精确的复现命令、期望 vs 实际、`log.txt` 末 30 行。
- 没做到的项写原因。
- **任务书本身的问题**单列一节，比如命令写错、期望和行为矛盾但看起来是任务书写错、步骤顺序让前提不成立。这些不算产品缺陷。
- 不改期望、不改 `baseline.json`、不装 /Applications、不改代码、**不联网**。
- 最后一句写「可以发布」或「不可以发布」，加上产品缺陷数 N（任务书问题另外计数）。
