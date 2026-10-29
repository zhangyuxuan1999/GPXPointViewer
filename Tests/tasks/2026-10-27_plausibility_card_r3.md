# 任务：落地前自检 / 考卷 / 单处卡片 / 在主地图上看 / 翻页跟随 / 界面待办四项 · 2026-10-27 · 第 3 轮（全部离线，不许联网）

## 背景（这次改了什么）
1. **落地前自检**（FillPlausibility，`docs/fill-plausibility-design.md` §1、§3）：每处补点落地前按几何打分 0–100，`riskLevel` low / medium（≥20）/ high（> 门槛，默认 50）。high 默认不勾选。界面：批量表格「风险」列徽标（high「要看一眼」、medium「留意」）、质量条「只看要看一眼的 N 处」、第 3 步汇总「要看一眼 N · 留意 M」、单处卡片和补点操作条上的徽标、修改记录详细页「落地前自检：风险 N（等级）」。
2. **考卷**（`Tests/exam/`）：125 道断档题，两个引擎的录音离线回放、判卷，与 `Tests/exam/baseline.json` 对照（设计文档 §2、§5）。
3. **单处卡片**：批量窗口折叠成宽 560 的卡片，高度按卡片内容算（`docs/batch-review-design.md`「单处卡片」「卡片高度按内容算」两节）。
4. **在主地图上看**：修改记录详细页一键让主地图飞到这一处（同文档「修改记录『在主地图上看』」节）。
5. **翻页跟随**：详细页勾选框「主地图跟随」（偏好 `reviewFollowMap`，默认关），开着时 ‹ › 翻页后主地图跟着飞（同文档「修改记录翻页时主地图跟随」节）。
6. **界面待办四项**（`Tools/agents/runs/20261027_224806_plausibility-ui-backlog/output.md` §2）：卡片高度按内容算；主窗口底行按钮三档（图标+文字 → 只文字 → 只图标），不出现省略号；补点模式下性能面板收成一行，放在候选面板下面，不重叠；翻页跟随。

## 范围
- 要测：上面 6 项的钩子字段和数值；8 个回归脚本加合成套件（含考卷汇总行）；三种语言主窗口补点模式的截图。
- 不用测：联网的路网 / 瓦片 / Overpass（一律用假引擎 `fakeroute`）；nanoGPT（和本项目无关）；本地化文字措辞（只看有没有省略号、有没有重叠，不评翻译）；Apple MKDirections；`--record` 录制。
- **锁屏时截图全白**（`python3 Tests/ui/ui.py info` 输出里是 `front=loginwindow`）。这时截图项写「锁屏，不判」，只抄 `shotwin` 返回的尺寸行，不算缺陷。

## 已知数据事实（免得误判）
- `data/Garmin_Roma_Da_copy.gpx` 与 `data/Garmin_Roma_Da.gpx` 内容完全相同，候选数 **100**。来源：`Tests/ui/run_profile_tests.py` 第 21 行 `check(s['candidates'] == 100, …)`。
- `data/compare/Muenchen_Roma_Garmin.gpx` 候选数 **50**。来源：`Tests/synth/runner/check_garmin_tunnel.py` 文档串第 8 行「候选 50 处」。
- `fakeroute valhalla offset 30` 会把 Valhalla 做的那些项判成 high（「要看一眼」）、默认不勾选。这是**预期**，正是要测的功能，不是缺陷。来源：设计文档 §4 第 2 条；`Tests/ui/run_plausibility_tests.py` 文档串 P2。上一次实测：Garmin_Roma_Da_copy 100 项里 risk ≥ 20 的有 58 项（`run_plausibility_tests.py` U1a，backlog output.md §4）。
- `fakeroute all ok` 下**允许少量 medium**：假引擎给的是直弦，弯道或带停车的长断档会被扣 10–25 分。判据以脚本为准：有草稿的项 low ≥ 75%、high ≤ 2%（`run_plausibility_tests.py` 第 63–65 行）。设计文档 §4 第 1 条写的「全部 low」比实际严，不按它判。
- 考卷：OSRM、Valhalla 都是 **121/125**。4 道未通过：`rd_1-3min_0093`、`rd_20-60s_0091`、`rd_3-8min_0092`、`rd_1-3min_0120`。原因是匝道处 OSM 中心线和 Garmin 轨迹有 10–20 m 的系统偏差（数据偏差），**不是缺陷**。`baseline.json` 里这 4 题两个引擎都是 `false`，其余都是 `true`。来源：设计文档 §5 表格与其后一段；`Tests/exam/baseline.json`。
- 单处卡片：宽固定 560；高 = 卡片内容高 + 标题栏，代码限制在 160…560（`TrackStore.swift` 第 3093–3104 行）。上一次实测内容 207、窗口 **560×239**（`docs/batch-review-design.md`「卡片高度按内容算」节）。

## 硬规则
- **不联网**。测试副本起来后第一条命令就是 `python3 Tests/ui/ui.py "autotripmap 0"`（不关的话 `batchplan` 会去查 Overpass）。任何 `batchrun` / `batchrefetch` / `route car` / `routecross` 之前，必须已经设好 `fakeroute all ok` 或本文指定的假模式。**不要运行**：`run_batch_drift.py`、`run_crosscheck_online.py`、`run_route_tests.py`、`run_drift_tests.py`、`run_network_tests.py`、`Tests/ui/run_suite.sh`（列表里有联网脚本）、`Tests/exam/run_exam.sh --record`。
- **一次只开一个测试副本**：`Tests/ui/app.noindex/GPXPointViewer.app`，关它只用 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。`/Applications/GPXPointViewer.app` 是用户在用的实例：**不要 kill、不要覆盖、不要安装**。
- 自己起副本的脚本每个都**各自新起**，跑之前先 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`，不并行。这类脚本是：`run_plausibility_tests.py`、`run_batch_card_tests.py`、`run_batch_review_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`、`run_map_sources_tests.py`。`run_fill_tests.py`、`run_profile_tests.py` 要先有副本在跑。
- **结束必须复位偏好**（测试副本和 /Applications 共用容器偏好），中途失败也要做：
  `python3 Tests/ui/ui.py "batchriskonly 0" "batchcompact 0" "reviewfollow 0" "riskthreshold off" "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "set mapStyle 标准" "set showStats 1"`
  （`showStats` 默认值是 true，见 `GPXPointViewer/TrackData.swift` 第 124 行；第 7 节截图要打开它。）
- 不改代码、测试脚本、期望值、`baseline.json`；不构建 Xcode 工程；**不要**带 `--baseline` 跑考卷。

## 准备（完整写法）
1. 所有命令都在仓库根执行：`cd /Users/zyx/Documents/GPXPointViewer`。
2. 确认测的是 /Applications 那份。先在当前 shell 执行 `export GPXPV_APP=/Applications/GPXPointViewer.app`，后面所有命令都在**同一个 shell** 里跑（另一个任务可能正在往 DerivedData 构建没完成的版本；`app_source()` 的顺序是 `GPXPV_APP` > DerivedData Release > `/Applications`）：
   ```sh
   export GPXPV_APP=/Applications/GPXPointViewer.app
   echo "GPXPV_APP=[$GPXPV_APP]"
   python3 -c "import sys; sys.path.insert(0,'Tests/ui'); import ui; print(ui.app_source())"
   ls -l /Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer
   pgrep -fl /Applications/GPXPointViewer.app || echo "no /Applications instance"
   ```
   期望：第二行打印 `/Applications/GPXPointViewer.app`。把可执行文件的修改时间、`pgrep` 的输出抄进报告；`info` 和 `front=` 在「准备」第 5 步起测试副本之后再取（副本没起来时 `info` 只会 TIMEOUT）。
3. 确认装上的是新版本（包内要有新字符串）：
   ```sh
   for s in '主地图跟随' '只看要看一眼的' '落地前自检' '单处卡片' '要看一眼'; do printf '%s: ' "$s"; grep -rlaF "$s" /Applications/GPXPointViewer.app/Contents | head -1; echo; done
   ```
   期望：5 个都打印出路径。缺任何一个就停下，报「/Applications 不是新版本」。
4. 容器与数据：
   ```sh
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   mkdir -p "$C/uitest"
   zsh Tests/ui/setup_data.sh
   [ -f "$C/uitest/Garmin_Roma_Da_copy.gpx" ] || cp data/Garmin_Roma_Da_copy.gpx "$C/uitest/"
   [ -f "$C/uitest/Muenchen_Roma_Garmin.gpx" ] || cp data/compare/Muenchen_Roma_Garmin.gpx "$C/uitest/"
   ls -l "$C/uitest/Garmin_Roma_Da.gpx" "$C/uitest/Garmin_Roma_Da_copy.gpx" "$C/uitest/Muenchen_Roma_Garmin.gpx" "$C/uitest/stepLife.csv"
   ```
   期望 4 个文件都在。变量 `C` 不跨命令保留，下面每条命令里都重新赋值。
5. 「**起副本（语言 L）**」= 整段执行（L 默认是 `zh-Hans`）：
   ```sh
   L=zh-Hans
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
   mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
   open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages "($L)"
   ```
   每秒跑一次 `python3 Tests/ui/ui.py state`，直到返回含 `"points"` 的 JSON（最多等 40 s）。然后执行 `python3 Tests/ui/ui.py "autotripmap 0" "place 0" "front"`，再执行 `python3 Tests/ui/ui.py info`，把 `front=` 抄进报告。
6. 发命令：`python3 Tests/ui/ui.py "cmd1" "cmd2" …`（`sleep 800` 的单位是毫秒）。
7. 「**打开 Garmin 并进补点模式**」= 整段执行：
   ```sh
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"
   ```
   每秒看 `state`，直到 `loading` 为 false 且 `points` > 0。再执行 `python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500"`，等到 `refreshing` 为 false 且 `candidates` = **100**。
8. 「**跑批次**」= `python3 Tests/ui/ui.py "batchclose" "sleep 300" "batchplan" "sleep 800" "batchall road" "sleep 200" "batchrun"`。之后每 2 s 看一次批次摘要，直到 `phase preview`（最多 150 s）。
9. 三条只读查询（下文直接用名字）：
   - **批次摘要**：
     ```sh
     python3 Tests/ui/ui.py state | python3 -c "import sys,json,collections;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);b=s['batch'] or {};it=b.get('items',[]);d=[x for x in it if x['kind']=='road' and x['status']=='done' and x['source'] in ('osrmCar','valhallaCar')];print('phase',b.get('phase'),'items',len(it),'drafted',len(d),'counts',b.get('counts'));print('riskOnly',b.get('riskOnly'),'visibleCount',b.get('visibleCount'),'compact',b.get('compact'),'windowSize',b.get('windowSize'),'cardH',b.get('cardContentHeight'));print('keys_ok',all(all(k in x for k in ('risk','riskLevel','riskReasons')) for x in it),'riskNull',sum(1 for x in d if x['risk'] is None));print('src/level/include',sorted(collections.Counter((x['source'],x['riskLevel'],x['include']) for x in d).items()));print('nHigh',sum(1 for x in d if x['riskLevel']=='high'),'nLook(med+high,all items)',sum(1 for x in it if x['riskLevel'] in ('medium','high')),'maxLow',max([x['risk'] for x in d if x['riskLevel']=='low'] or [None]),'minMedHigh',min([x['risk'] for x in d if x['riskLevel'] in ('medium','high')] or [None]),'risk0WithReasons',sum(1 for x in d if x['risk']==0 and x['riskReasons']));print('status',collections.Counter(x['status'] for x in it),'cross',collections.Counter(x['cross'] for x in it))"
     ```
   - **单处摘要**：
     ```sh
     python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);r=s['route'] or {};print('points',s['points'],'routeBusy',s['routeBusy'],'source',r.get('source'),'keys',all(k in r for k in ('risk','riskLevel','riskReasons')),'risk',r.get('risk'),'level',r.get('riskLevel'),'reasons',r.get('riskReasons'))"
     ```
   - **审阅摘要**（打印当前选中项、主地图中心到选中项的距离）：
     ```sh
     python3 Tests/ui/ui.py reviewstate | python3 -c "import sys,json,math;r=json.loads(sys.stdin.read().strip().splitlines()[-1]);ch=r.get('changes',[]);i=r.get('selected',-1);c=r.get('mainMapCenter');it=ch[i] if isinstance(i,int) and 0<=i<len(ch) else None;f=lambda a,b,x,y:12742*math.asin(math.sqrt(math.sin(math.radians(x-a)/2)**2+math.cos(math.radians(a))*math.cos(math.radians(x))*math.sin(math.radians(y-b)/2)**2));print('detail',r.get('detail'),'preview',r.get('preview'),'selected',i,'n',len(ch),'followMap',r.get('followMap'),'center',c,'spanKm',r.get('mainMapSpanKm'),'distKm',round(f(c[0],c[1],it['lat'],it['lon']),3) if c and it else None);print('riskKeys',all('risk' in x and 'riskLevel' in x and isinstance(x.get('riskReasons'),list) for x in ch),'sel risk',it and (it.get('risk'),it.get('riskLevel')))"
     ```
10. 本轮钩子（都已在 `GPXPointViewer/UITestHook.swift` 的 `case "…"` 里核实）：`open`、`fill`、`exit`、`select <i>`、`route car`、`apply`、`confirm replace`、`crosscheck 0|1`、`fakeroute <osrm|valhalla|all> <ok|offset <米>|noroute|fail|off>`、`autotripmap 0|1`、`batchplan`、`batchall road`、`batchrun`、`batchclose`、`batchrefetch all|<i>`、`batchselect <i>`、`batchnext`、`openbatch`、`closebatchwin`（等于点批量窗口的红色关闭按钮，批次留着）、`batchcompact 0|1`、`batchriskonly 0|1`（回显 `visible=N`）、`riskthreshold <n>|off`（回显当前门槛）、`riskpopover 1|0`、`resizewin <标题子串> <宽> <高>`、`frame <x> <y> <w> <h>`、`batchreview`、`reviewstate`、`reviewselect <i>`、`reviewnext`、`reviewprev`、`reviewgoto`（等于详细页「在主地图上看」）、`reviewfollow 0|1`（回显当前值）、`reviewrevert <i>`、`reviewmap standard light 1`、`set mapStyle 标准`、`set showStats 0|1`、`routecache clear`、`windows`、`shotwin <标题子串> <png 路径>`（标题前加 `+` 表示连同本 app 的 popover 一起截）、`state`、`info`。
    - `state.batch`：`phase compact windowSize[宽,高]（外框含标题栏；窗口没开时为 null） cardContentHeight riskOnly warnedOnly conflictOnly visibleCount counts{high,medium,…} items[]{kind,status,cross,source,include,risk,riskLevel,riskReasons}`。
    - `state.route`：`source notes risk riskLevel riskReasons`。
    - `reviewstate`：`detail preview selected followMap mainMapCenter[lat,lon] mainMapSpanKm changes[]{i,lat,lon,risk,riskLevel,riskReasons,…}`。

## 测试项

### 1. 回归脚本（8 个 + 合成套件）
每个脚本抄最后 5 行，末行 `FAILS: none` 算通过。第 1–6 条每条前面都带 `pkill`，各自新起副本。
1. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_plausibility_tests.py 2>&1 | tee /tmp/r3_pl.log | tail -20` → P0、P1a、P1b、P2a、P2b、P2c、P3a、P3b、P4a、P4b、P4c、U1a、U1b、U2a、U2b、U3a、U3b、U4 全部 `ok`，末行 `FAILS: none`。抄 P1a（期望以 `counts.high=1` 结尾）、P2a（期望以 `counts.high=49` 结尾）、P3b（期望以 `50` 结尾）、U1a（上次 `visibleCount=58，risk ≥ 20 的项 58（共 100）`）、U2a（上次 `windowSize=[560, 239]，卡片内容高 207`）、U3a。来源：脚本本身；backlog output.md §4。
2. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_batch_card_tests.py 2>&1 | tee /tmp/r3_card.log | tail -20` → K3a、K0、K1a、K1b、K1c、K1c'、K1d、K1d'、K3b、K2a、K2b、K2c、K2d 全部 `ok`，末行 `FAILS: none`。抄 K1a（上次 `[560, 239]`）、K1d、K1d'、K2a、K2b。脚本最后会 pkill 副本。
3. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_batch_review_tests.py 2>&1 | tee /tmp/r3_br.log | tail -5` → `FAILS: none`。
4. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_route_cache_tests.py 2>&1 | tee /tmp/r3_rc.log | tail -5` → `FAILS: none`。
5. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_map_sources_tests.py 2>&1 | tee /tmp/r3_map.log | tail -5` → `FAILS: none`。
6. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_tunnel_fix_tests.py 2>&1 | tee /tmp/r3_tf.log | tail -12` → 全部 `ok`，含 `candidates=50`，末行 `FAILS: none`。脚本结束后副本还开着，紧接着跑 7。
7. `python3 -u Tests/ui/run_fill_tests.py 2>&1 | tail -5` → `FAILS: none`（如果 `python3 Tests/ui/ui.py state` 不返回 JSON，先按「准备」第 5 步起副本）。
8. **单独新起副本**跑（不接在第 6、7 条用过的副本后面，避免 171 MB CSV 的重算抢跑）。按「准备」第 5 步的写法起副本：
   ```sh
   L=zh-Hans
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
   mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
   open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages "(zh-Hans)"
   ```
   每秒跑一次 `python3 Tests/ui/ui.py state`，直到返回含 `"points"` 的 JSON（最多等 40 s）；然后执行 `python3 Tests/ui/ui.py "autotripmap 0" "place 0" "front"`。再跑 `python3 -u Tests/ui/run_profile_tests.py 2>&1 | tee /tmp/r3_profile.log | tail -8` → 含 `ok   P2 Garmin 候选 100（隧道群合并后；实际 100）`，末行 `FAILS: none`。
9. `sh Tests/synth/runner/run_all.sh 2>&1 | tail -15` → 有 `build ok`；有 `summary: 114 entries in 6 families, ok 114`（**114/114**；来源 backlog output.md §4）；没有 `FAILED:` 行；**最后一行**以 `exam summary: questions 125 · detected 110 · osrm: pass 121/125` 开头，含 `valhalla: pass 121/125`、`agree 125 disagree 0 agreeButFail 4`、`requests sent 0 replayed 255 missing 0`，**不含** `REGRESSIONS`。末行整行原文抄进报告。
   - 注意：`run_all.sh` 第 56–57 行里考卷那一步的退出码取的是管道里 `tail -1` 的退出码，考卷就算有回归也不会让 run_all 返回非 0。所以本项**只按末行文字判**；考卷的退出码在第 6 节单独看。
- 任何脚本失败，附上 `tail -30 $HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/log.txt`。

### 2. 落地前自检（设计文档 §4 第 1–7 条，逐条）
先按「准备」第 5 步起副本（zh-Hans），再做第 7 步「打开 Garmin 并进补点模式」，然后执行 `python3 Tests/ui/ui.py "riskthreshold off" "crosscheck 0" "fakeroute all ok" "routecache clear"`。
1. **§4-1 假引擎全对**：「跑批次」，等 preview，跑批次摘要。期望：`drafted` > 10；`riskNull 0`；`nHigh` ≤ drafted × 2%；low 项数 ≥ drafted × 75%；`maxLow` ≤ 19；`risk0WithReasons 0`；`counts.high` = `nHigh`。来源：`run_plausibility_tests.py` P1a/P1b（设计文档 §4-1 写的「全部 low」比实际严，见「已知数据事实」）。
2. **§4-2a 普通模式 Valhalla 偏 30 m**：`python3 Tests/ui/ui.py "fakeroute valhalla offset 30"`，再「跑批次」，等 preview，跑批次摘要。期望：`src/level/include` 里 `valhallaCar` 的项 ≥ 95% 是 `('valhallaCar','high',False)`；`osrmCar` 的项没有 `high`；`counts.high` ≥ 1，且等于 `nHigh`；`minMedHigh` ≥ 20。来源：P2a/P2b/P2c。
3. **§4-2b 精确模式两路不一致**：`python3 Tests/ui/ui.py "crosscheck 1" "fakeroute osrm ok" "fakeroute valhalla offset 30" "routecache clear"`，再「跑批次」，等 preview，跑批次摘要。期望：`status` 行是 `Counter({'conflict:disagree': 100})`（100 项 status 为 `conflict:disagree`）、`cross` 行是 `Counter({'disagree': 100})`、`counts.disagree=100`（两路不一致 > 0，这是原有行为，不应变）。此模式下摘要里的 `drafted`/`src` 会打印 0，因为 `d` 只收 `status=='done'` 的项；判据只看 `status`/`cross`/`counts`。**不要**读 `conflict` 字段：精确模式不一致时它是 null。来源：设计文档 §4-2；`Tests/tasks/2026-10-26_route_cache_tunnel_r2.md` 第 3 节第 6 步的 `conflict:disagree`。做完执行 `python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all ok" "fakeroute valhalla offset 30"`。
4. **§4-3 改门槛**：「跑批次」，等 preview。然后 `python3 Tests/ui/ui.py "riskthreshold 5"` → 回显 `riskthreshold 5`。再 `python3 Tests/ui/ui.py "batchrefetch all"`（已有批次不会重算，要重取一次才用新门槛），每 2 s 看一次，直到 `phase preview`。用下面这条核对，期望打印 `bad 0`：
   ```sh
   python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);d=[x for x in s['batch']['items'] if x['kind']=='road' and x['status']=='done' and x['source'] in ('osrmCar','valhallaCar')];bad=[(x.get('id'),x['risk'],x['riskLevel'],x['include']) for x in d if x['risk'] is not None and x['risk']>5 and not (x['riskLevel']=='high' and not x['include'])];print('drafted',len(d),'risk>5',sum(1 for x in d if (x['risk'] or 0)>5),'bad',len(bad),bad[:5])"
   ```
   再执行 `python3 Tests/ui/ui.py "riskthreshold off"` → 回显 `riskthreshold 50`。来源：设计文档 §4-3、§1.5；`UITestHook.swift` `case "riskthreshold"`。
5. **§4-4 单处与修改记录**：`python3 Tests/ui/ui.py "fakeroute all ok" "batchclose" "sleep 300" "exit" "sleep 300" "fill" "sleep 1500"`，等 `refreshing` false 且 candidates 100；记下 `points` 为 N0。`python3 Tests/ui/ui.py "select 0" "sleep 300" "route car"`，每秒跑单处摘要，直到 `routeBusy None` 且 source 不是 None → `keys True`，`risk` 不是 None，`level` 是 `low` 或 `medium`（记为 LV）。`python3 Tests/ui/ui.py "apply" "sleep 600" state`：如果 `prompt` 为 true，再执行 `python3 Tests/ui/ui.py "confirm replace"`。等 `loading` false 且 `points` ≠ N0，执行 `python3 Tests/ui/ui.py "reviewselect 0"` 后跑审阅摘要 → `n 1`，`sel risk` 不是 None，等级 = LV。`python3 Tests/ui/ui.py "reviewrevert 0"`，等 `points` = N0。来源：P4a/P4b/P4c。
6. **§4-5 字段齐全**：上面每次批次摘要都要 `keys_ok True`；`counts` 里有 `high` 和 `medium` 两个键。来源：P0。
7. **§4-6 批量窗口截图**：`python3 Tests/ui/ui.py "fakeroute valhalla offset 30" "routecache clear"`，再「跑批次」，等 preview。然后 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "openbatch" "sleep 1500" "resizewin 批量补点 1130 900" "sleep 800" "shotwin 批量补点 $C/uitest/r3_batch_table.png"` → 返回 `shotwin <宽>x<高> -> …`。看图判据（锁屏就写不判）：表格最上面几行是红色「要看一眼」徽标，第 3 步标题行右侧有「要看一眼 N · 留意 M」，N = 批次摘要里的 `counts.high`。如果你看不了图片，就写「截图已存，交主会话看」，不算失败。
8. **§4-7 考卷离线**：放在第 6 节做。

### 3. 筛选「只看要看一眼的」
接第 2 节第 7 步（批次在 preview，偏 30 m，批量窗口开着）。
1. 跑批次摘要，记下 `nLook(med+high,all items)` = K、`items` = T。
2. `python3 Tests/ui/ui.py "batchriskonly 1" "sleep 300"` → 回显 `batchriskonly true visible=K`。批次摘要 → `riskOnly True`、`visibleCount` = K。来源：U1a（上次 K = 58，T = 100）。
3. `python3 Tests/ui/ui.py "batchriskonly 0" "sleep 300"` → 回显 `batchriskonly false visible=T`；批次摘要 → `riskOnly False`、`visibleCount` = T。来源：U1b。
4. 互斥：`python3 Tests/ui/ui.py "batchriskonly 1"` 后跑 `python3 Tests/ui/ui.py state | python3 -c "import sys,json;b=json.loads(sys.stdin.read().strip().splitlines()[-1])['batch'];print(b['riskOnly'],b['warnedOnly'],b['conflictOnly'])"` → `True False False`。来源：`UITestHook.swift` `case "batchriskonly"`（打开时把另外两个关掉）。最后 `python3 Tests/ui/ui.py "batchriskonly 0"`。

### 4. 单处卡片
接第 3 节（批量窗口开着，preview）。
1. 批次摘要记下 `windowSize` = S0（展开的大窗口）。
2. `python3 Tests/ui/ui.py "batchcompact 1" "sleep 2000"`，跑批次摘要 → `compact True`；`windowSize[0]` = **560**；`windowSize[1]` < **300**，并且落在 [`cardH`, `cardH` + 60] 之间；`cardH` > 60。上次实测 `[560, 239]`、cardH 207。来源：U2a；`TrackStore.swift` 第 3097、3104 行。存证 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotwin 批量补点 $C/uitest/r3_card.png"`（看图判据：底行按钮完整、卡片下方没有大片空白）。
3. 换一处，卡片高度应跟着内容变：`python3 Tests/ui/ui.py "batchnext" "sleep 1500"`，批次摘要 → 仍然 `compact True`、宽 560、高在 [cardH, cardH+60] 之间（cardH 用这次打印的值）。来源：`docs/batch-review-design.md`「卡片高度按内容算」（换一处会重新量）。
4. `python3 Tests/ui/ui.py "batchcompact 0" "sleep 1500"`，批次摘要 → `compact False`，`windowSize` = S0（每一维差 ≤ 3）。来源：U2b、K1b。
5. **关窗重开不再是卡片**：`python3 Tests/ui/ui.py "batchcompact 1" "sleep 1500" "closebatchwin" "sleep 1000"`（回显含 `closebatchwin`），批次摘要 → `compact False`、`windowSize None`。再 `python3 Tests/ui/ui.py "openbatch" "sleep 1500"`，批次摘要 → `compact False`，`windowSize` = S0（每一维差 ≤ 6），**不是** 560 宽的卡片。来源：K1d/K1d'；`docs/batch-review-design.md`「单处卡片」节「关窗时先放回原框再退出折叠」。
6. 大窗口也能缩：`python3 Tests/ui/ui.py "resizewin 批量补点 1130 880" "sleep 800"` → 回显 `resizewin now=1130x880`；`python3 Tests/ui/ui.py "batchcompact 1" "sleep 1800"` 后批次摘要 → `windowSize[0]` = 560、`windowSize[1]` < 300；`python3 Tests/ui/ui.py "batchcompact 0" "sleep 1500"` 后 → 回到 `[1130, 880]`（每一维差 ≤ 3）。若屏幕更小被夹取，以折叠前后一致为判据。来源：K1c/K1c'。

### 5. 在主地图上看 / 翻页跟随
接第 4 节（批次在 preview）。
1. `python3 Tests/ui/ui.py "batchreview" "sleep 1500" "reviewfollow 0" "reviewselect 3" "sleep 800"`，再跑审阅摘要，记下 `center` = C0。
2. `python3 Tests/ui/ui.py "reviewgoto" "sleep 2500"` → 回显 `reviewgoto v=<数字>`。审阅摘要 → `detail True`、`selected 3`、`distKm` < **2**、`spanKm` < **10**。来源：K2a/K2b/K2c；`docs/batch-review-design.md`「在主地图上看」节。
3. `python3 Tests/ui/ui.py "reviewfollow 1"` → 回显 `reviewfollow true`。`python3 Tests/ui/ui.py "reviewnext" "sleep 2500"`，审阅摘要 → `followMap True`、`selected 4`、`distKm` < **2**。来源：U3a。
4. `python3 Tests/ui/ui.py "reviewprev" "sleep 2500"`，审阅摘要 → `selected 3`、`distKm` < 2（反向翻页也跟）。来源：`TrackStore.swift` 第 2904 行（`reviewFollowMap && reviewDetail` 时飞）。
5. `python3 Tests/ui/ui.py "reviewfollow 0"` → 回显 `reviewfollow false`。记下审阅摘要的 `center` = C1；`python3 Tests/ui/ui.py "reviewnext" "sleep 2000"`，审阅摘要 → `followMap False`、`selected 4`，`center` 和 C1 相比移动 < 0.05 km（两组坐标都抄进报告）。来源：U3b。
6. 偏好：`defaults read de.wayne.GPXPointViewer reviewFollowMap 2>&1` → `0`（或 key 不存在）。来源：`TrackStore.swift` 第 2907–2909 行。沙盒 app 的 defaults 域可能读不到，读不到就注明，不算失败。
7. 存证：`C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotwin 修改记录 $C/uitest/r3_review_follow.png"`（看图判据：详细页顶部「在主地图上看」左边有勾选框「主地图跟随」，依据行下面有「落地前自检：风险 N（…）」一行）。

### 6. 考卷（离线）
1. `SKIP_BUILD=1 sh Tests/exam/run_exam.sh > /tmp/r3_exam.out 2>&1; echo "exit=$?"; tail -1 /tmp/r3_exam.out` → `exit=0`（第 1 节第 9 步已经编译过 synthrunner；如果报 `SKIP_BUILD=1 but … does not exist` 或退出码 3，去掉 `SKIP_BUILD=1` 重跑）。末行逐项核对，每段都要对上：
   - 以 `exam summary: questions 125 · detected 110` 开头
   - `osrm: pass 121/125 noRecording 0 error 0 | high∧fail 0 high∧pass 0 → hit 0% falseAlarm 0% | perturb artefact 109/125 parallel 125/125 high`
   - `valhalla: pass 121/125 noRecording 0 error 0 | high∧fail 0 high∧pass 0 → hit 0% falseAlarm 0% | perturb artefact 109/125 parallel 125/125 high`
   - `agree 125 disagree 0 agreeButFail 4`
   - `bands …`：两个引擎合计（每题按两个引擎各算一次，见 `Tests/synth/runner/exam.swift` 第 270 行），期望 10–20 s **30/30**、20–60 s **82/84**、1–3 min **78/82**、3–8 min **50/52**、<10 s **2/2**（没有单独的 real 档：5 道 real 题按时长归入 `20-60s` / `1-3min` / `3-8min` / `<10s` 各档，两引擎合计 10 次通过已含在上述数字里）。数字以 `Tests/exam/baseline.json` 为准（档名按输出原样抄）。
   - `requests sent 0 replayed 255 missing 0`；**没有** `REGRESSIONS`，也没有 `baseline written`。
   来源：设计文档 §5 表格和录制段；backlog output.md §4 末行；格式见 `exam.swift` 第 320–353 行；退出码规则见第 356 行（无回归且 error 为 0 时返回 0）。
2. 和 `baseline.json` 逐题对照（用最新的结果文件）：
   ```sh
   python3 -c "import json,glob;f=sorted(glob.glob('Tests/exam/results/*.json'))[-1];r=json.load(open(f));b=json.load(open('Tests/exam/baseline.json'));q=[x for x in r['questions'] if 'id' in x];d=[(x['id'],e,x.get(e,{}).get('pass'),b.get(x['id'],{}).get(e)) for x in q for e in ('osrm','valhalla') if x.get(e,{}).get('pass')!=b.get(x['id'],{}).get(e)];fl=sorted(k for k,v in b.items() if not all(v.values()));print(f);print('questions',len(q),'baseline',len(b),'diff',len(d),d[:8]);print('baselineFalse',fl)"
   ```
   期望：`questions 125 baseline 125 diff 0 []`；`baselineFalse ['rd_1-3min_0093', 'rd_1-3min_0120', 'rd_20-60s_0091', 'rd_3-8min_0092']`。
3. 不联网：考卷只读 `Tests/exam/recordings/`，末行的 `requests sent 0` 就是证据。

### 7. 三种语言的主窗口补点模式截图（960×800）
每种语言 L 依次取 `zh-Hans`、`en`、`de`，主窗口标题 T 分别是 `GPX 点位查看器`、`GPX Point Viewer`、`GPX-Punktbetrachter`（来源：`Tests/ui/shots_plausibility_ui.py` 第 15 行）。**不要**运行 `shots_plausibility_ui.py` 本身，它会覆盖仓库里 `Tests/reports/plausibility_ui_shots/` 的样例。
1. 按「准备」第 5 步起副本，把 `L` 设成这一种语言。
2. `python3 Tests/ui/ui.py "autotripmap 0" "set showStats 1" "frame 240 60 960 800" "front" "riskthreshold off" "crosscheck 0"`；再做「准备」第 7 步打开 Garmin 并进补点模式。
3. `python3 Tests/ui/ui.py "fakeroute all offset 30" "select 3" "sleep 400" "route car"`，每秒跑单处摘要，直到 `routeBusy None`；然后 `python3 Tests/ui/ui.py "frame 240 60 960 800" "sleep 1500"`。
4. `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotwin <T> $C/uitest/r3_main_fill_<L>.png" "windows"` → 用 `windows` 读主窗口 T 的尺寸，必须是 `w=960 h=800`（第 2、3 步 `frame 240 60 960 800` 的回显也应与此一致）；`shotwin` 返回的截图尺寸只作记录：截图四边各带 34 pt 阴影边距，960×800 窗口会输出 2056×1736，不是 1920×1600/960×800，不能拿它当窗口尺寸。再跑 `python3 Tests/ui/ui.py info`，抄 `front=`。
5. 看图判据（锁屏 / 全白就写「锁屏，不判」；看不了图片就写「交主会话看」）：
   a) 左下控制面板底行（导出 / 图片 / 删除点 / 补点 / 退出那一行）**没有「…」省略号**；「退出补点」或 `Exit` / `Beenden` 完整显示。三档里任何一档都算对：zh-Hans 补点模式、en、de 上次都是只显示图标（backlog output.md §2-3）。
   b) 右列性能面板收成一行（「性能面板 · NN fps ⌄」或对应译文），在候选面板**下面**，两者不重叠；候选面板底部说明文字完整，没被补点操作条盖住。
   c) 已知未修问题，**不算本轮缺陷**，只记录：补点操作条盖住左侧控制面板最底一行，de/en 最明显（backlog output.md §6-1，已记进 backlog）。如果 a) 因为这一条看不见底行，就写「被操作条遮住，见已知问题」。
6. 每种语言做完执行 `python3 Tests/ui/ui.py "fakeroute all off" "exit"`。

### 8. 收尾（必须）
```sh
python3 Tests/ui/ui.py "batchriskonly 0" "batchcompact 0" "reviewfollow 0" "riskthreshold off" "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "set mapStyle 标准" "set showStats 1" "exit"
pkill -f Tests/ui/app.noindex/GPXPointViewer.app
pgrep -fl /Applications/GPXPointViewer.app || echo "no /Applications instance"
```
如果测前 `pgrep` 有输出，现在应该还有。把复位命令的回显原文抄进报告。

## 报告格式
- 写到 `Tests/reports/<yyyyMMdd_HHmm>_deepseek_r3_plausibility.md`。
- 开头：测的 app 路径（`ui.app_source()` 的输出）、可执行文件修改时间、`info` 里的 `front=`、「准备」第 3 步 5 个字符串的结果。
- 每个小步一行：`ok` / `FAIL` / `不判（原因）` + 实际命令 + 关键输出原文（数字原样抄）。第 1 节每个脚本抄末行原文；`run_all.sh` 和 `run_exam.sh` 的 `exam summary:` 整行原文照抄。
- FAIL 要写：现象、精确复现命令、期望 vs 实际、`log.txt` 末 30 行。
- 没做到的项写原因。
- **任务书本身的问题**单列一节（命令写错、期望和行为矛盾但看起来是任务书写错、步骤顺序让前提不成立）。这些不算产品缺陷。
- 不改期望、不改 `baseline.json`、不装 /Applications、不改代码、**不联网**。
- 最后一句：「可以发布」或「不可以发布」+ 产品缺陷数 N（任务书问题另外计数）。
````

---

**progress.md**（也没写进去；续跑时按这个状态）：
- 已完成：读完全部来源，写好任务书和疑点。
- 下一步：主会话把上面两份存进运行目录，并把任务书拷进 `Tests/tasks/`。

---

## 2026-10-28 修订记录

对应 DeepSeek 第 3 轮报告（`Tests/reports/20261027_2334_2026-10-27_plausibility_card_r3.md`）的 T1–T7；`Tests/ui/run_profile_tests.py` 的健壮化同批完成。共 8 处：

1. **T1（§4-2b 摘要字段）**：「批次摘要」命令的 `conflicts` 一列不再读 `conflict` 字段（精确模式两路不一致时它是 null），改为按 `status`/`cross` 统计；§4-2b 期望写成 100 项 `status='conflict:disagree'`、`cross='disagree'`、`counts.disagree=100`，并说明该模式下 `drafted`/`src` 打印 0 的原因。「准备」第 10 条的 `state.batch` 字段说明同步订正为 `status,cross`。
2. **T2（§6.1 bands）**：删掉 `real` 档的期望；5 道 real 题按时长归入 `20-60s` / `1-3min` / `3-8min` / `<10s`，补上 `<10s 2/2`，其余数字不变，并注明以 `Tests/exam/baseline.json` 为准。
3. **T3（§4 第 6 条大窗口）**：尺寸由 1130×990 改成 1130×880（本机屏幕 1440×932，990 高的窗口会被系统夹到 903）；期望改为 `resizewin now=1130x880`、恢复 `[1130, 880]`，并加「若屏幕更小被夹取，以折叠前后一致为判据」。
4. **T4（§7.4 shotwin）**：窗口尺寸判据改为用钩子 `windows` 读主窗口 `w=960 h=800`（`frame` 回显一致）；`shotwin` 截图四边各带 34 pt 阴影边距，截图尺寸只作记录，不再要求宽高比 1.2。
5. **T5（§1 第 6–8 条顺序）**：`run_profile_tests.py` 改为**单独新起副本**跑，写出完整起副本命令，不再接在第 6 条之后；第 6 条结束只紧接着跑第 7 条。
6. **T6（准备第 2 步 info）**：`ui.py info` 与 `front=` 从准备第 2 步挪到第 5 步起测试副本之后（副本没起来时 `info` 只会 TIMEOUT）。
7. **T7（§1 第 1 条措辞）**：抄录说明改为 P1a 以 `counts.high=1` 结尾、P2a 以 `counts.high=49` 结尾、P3b 以 `50` 结尾。
8. **B（`Tests/ui/run_profile_tests.py`）**：`load()` 现在等 `loading=false`、`points>0`、`refreshing=false`（无该字段时退回 `profile` 非空）且 `candidates` 字段存在，最长 180 s；`fill` 后等 `profile` 非空且重算结束（最长 60 s），去掉固定 `sleep 1500`；期望值未改。
