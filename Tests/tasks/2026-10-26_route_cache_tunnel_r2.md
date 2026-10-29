# 任务：路网结果缓存 / 重新获取 / 修改记录两路切换 / 隧道补点修正 · 2026-10-26 · 第 2 轮（全部离线，不许联网）

## 背景（这次改了什么、为什么）
用户反馈两类问题：① 批量补点第 2 步每次都重新向公共 OSRM / Valhalla 请求，关掉批量窗口重开又全部重来，公共服务容易限流；落地后在修改记录里看不到 OSRM 和 Valhalla 各给了什么路线。② Muenchen_Roma_Garmin 隧道补点有 5 处问题：补点被推到旁边的路上（第 14/16/19 处）、进隧道后设备外推的假点被当成锚点、位置对但时间滞后的点被整点删掉、1 s 跳 ~110 m 的短隧道没检出（诊断报告 `Tests/reports/20261026_1500_tunnel_diagnosis.md`）。
这次改动：
- **路网结果缓存（按文件）**：同一处断档、同样输入第二次直接用缓存，不再请求；换文件清空。批量第 2/3 步有「重新获取全部…」（确认弹层「重新获取全部？」），第 3 步表格右键「重新获取这一处（忽略缓存）」；单处有 `routerefetch`。缓存命中时说明里带「来自缓存」。
- **修改记录两路切换**：详细页有 OSRM | Valhalla 分段控件（只在该处有两份草稿时出现），只切换显示、不改采用；两路坐标逐点相同时显示「两路几何完全相同」。
- **隧道修正**：trimEnds/taper 不再丢掉稀疏隧道 way 的投影点；A 侧冻结假点链（3–6 个航向/步长锁死的外推点）并入替换区间（A 前移）；staleClock 候选的过时出口点「保留位置、只改时间」（修改记录里记 `retimed`）；短断档门槛 V1（Muenchen_Roma_Garmin 候选 44→50，Garmin_Roma_Da 97→100）。

## 范围
- 要测：缓存命中/重取的请求计数；两路切换的钩子字段；隧道修正在 Muenchen_Roma_Garmin 上的具体数字；7 个回归脚本；合成套件 114 文件；用户路径上的新控件存在（靠 state 字段与 app 包内字符串确认，不靠看图）。
- 不用测：真实路网请求（一律用假引擎 `fakeroute`）；地区统计、导出、本地化文字；Apple MKDirections。
- **锁屏时截图全白**（`python3 Tests/ui/ui.py info` 里 `front=loginwindow`）：本轮不靠截图判对错；`shotviewwin` 只做存证，报告里写出返回的尺寸行即可。

## 已知数据事实（免得误判）
- `data/Garmin_Roma_Da_copy.gpx` 与 `data/Garmin_Roma_Da.gpx` **内容完全相同**。短断档门槛 V1 之后它的候选数是 **100**（原 97；来源 `docs/cross-check-design.md` 末节「短断档门槛 V1」、`Tests/ui/run_profile_tests.py` 第 19–21 行）。看到 100 是对的。
- `data/compare/Muenchen_Roma_Garmin.gpx`：33,496 个 trkpt；候选 **50**（原 44；来源 `Tests/synth/runner/check_garmin_tunnel.py` 文档串）。第 14 处（Tusch 隧道）原锚点 9732→9734，现在 A 前移 4 点到 **9728**；trkpt 9733 原时间 **23:12:14 UTC**，修正后 **23:12:21 ±1 s**；落地「+11 −4、改时间 1 点」（来源 `docs/cross-check-design.md`「过时点保留改时」节）。

## 硬规则
- **不联网**。启动测试副本后第一条命令先 `python3 Tests/ui/ui.py "autotripmap 0"`（否则 `batchplan` 会去查 Overpass）；任何 `batchrun` / `routecross` / `route car` / `batchrefetch` / `routerefetch` 之前必须已设 `fakeroute all ok`（或本文指定的假模式）。**不要运行** `run_batch_drift.py`、`run_crosscheck_online.py`、`run_route_tests.py`、`run_drift_tests.py`、`run_network_tests.py`（联网）。
- **一次只开一个测试副本**：`Tests/ui/app.noindex/GPXPointViewer.app`，只用 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app` 关它。`/Applications/GPXPointViewer.app` 是用户正在用的实例，**不要 kill、不要覆盖、不要安装**。
- 自己起副本的脚本（`run_batch_review_tests.py`、`run_crosscheck_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`）每个都**各自新起**：跑之前先 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`，不并行。依赖已起副本的（`run_fill_tests.py`、`run_profile_tests.py`）要先有副本在跑。
- **结束必须复位偏好**（与 /Applications 共用容器偏好）：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "fillpoints 0"`；中途失败也要做。
- 不改代码、测试脚本、期望值；不构建 Xcode 工程。

## 准备（完整写法）
1. 所有命令在仓库根执行：`cd /Users/zyx/Documents/GPXPointViewer`。
2. 确认测的是 /Applications 那份（`app_source()` 顺序：`GPXPV_APP` > DerivedData Release > `/Applications`）：
   ```sh
   echo "GPXPV_APP=[$GPXPV_APP]"
   ls -d ~/Library/Developer/Xcode/DerivedData/GPXPointViewer-*/Build/Products/Release/GPXPointViewer.app 2>/dev/null || echo "no DerivedData Release"
   python3 -c "import sys; sys.path.insert(0,'Tests/ui'); import ui; print(ui.app_source())"
   ls -l /Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer
   ```
   期望：打印 `/Applications/GPXPointViewer.app`；把修改时间抄进报告。**无论 DerivedData 里有没有 Release，本轮一律先 `export GPXPV_APP=/Applications/GPXPointViewer.app`（在同一个 shell 里跑后面所有命令），测的必须是 /Applications 那份**（另一个任务可能正在往 DerivedData 构建未完成的版本）。
3. 容器与数据：
   ```sh
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   mkdir -p "$C/uitest"
   zsh Tests/ui/setup_data.sh
   cp data/compare/Muenchen_Roma_Garmin.gpx "$C/uitest/"
   ls -l "$C/uitest/Garmin_Roma_Da.gpx" "$C/uitest/Garmin_Roma_Da_copy.gpx" "$C/uitest/Muenchen_Roma_Garmin.gpx" "$C/uitest/stepLife.csv"
   ```
   期望 4 个文件都在。变量 `C` 不跨命令保留，每条命令里都重新赋值。
4. 「**起副本**」= 整段执行：
   ```sh
   C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp
   pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
   mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
   open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages '(zh-Hans)'
   ```
   每秒 `python3 Tests/ui/ui.py state` 直到返回含 `"points"` 的 JSON（≤40 s），再 `python3 Tests/ui/ui.py "autotripmap 0" "place 0" "front"`。
5. 发命令：`python3 Tests/ui/ui.py "cmd1" "cmd2" …`（`sleep 800` 是毫秒）。
6. 两条只读查询：
   - **批次摘要**：
     ```sh
     python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);b=s['batch'] or {};it=b.get('items',[]);r=[i for i,x in enumerate(it) if x['kind']=='road' and len(x['routes'])==2];print('phase',b.get('phase'),'road2',len(r),'road2idx',r[:3],'requests',b.get('requests'),'byHost',b.get('requestsByHost'),'cacheHits',b.get('cacheHits'),'routeCache',s['routeCache']);print('status',[(i,it[i]['status'],it[i]['source'],it[i]['include'],it[i]['picked']) for i in r[:3]])"
     ```
   - **单处摘要**：
     ```sh
     python3 Tests/ui/ui.py state | python3 -c "import sys,json;s=json.loads(sys.stdin.read().strip().splitlines()[-1]);r=s['route'] or {};print('routeBusy',s['routeBusy'],'cross',s['cross'],'source',r.get('source'),'cacheNote',any('来自缓存' in n for n in r.get('notes',[])),'routeCache',s['routeCache'])"
     ```
7. 本轮钩子（已在 `GPXPointViewer/UITestHook.swift` 核实）：`open`、`fill`、`exit`、`select <i>`、`selectnear <lat> <lon>`、`route car`、`apply`、`confirm replace`、`pointat <i>`、`pointfind <lat> <lon>`、`crosscheck 0|1`、`fakeroute <osrm|valhalla|all> <ok|offset <米>|noroute|fail|off>`（换模式会清空路网缓存）、`autotripmap 0|1`、`batchplan`、`batchall road`、`batchrun`、`batchclose`、`batchswap <i>`、`batchrefetch all|<i>`、`batchreview`、`openbatch`、`routecache stats|clear`（返回 `entries=N hits=M`）、`routecross`、`routerefetch`、`reviewstate`、`reviewselect <i>`、`reviewnext`、`reviewprev`、`reviewdetail off`、`reviewdraft osrm|valhalla|next|default`、`reviewrevert <i>`、`windows`、`shotviewwin <标题> <文件>`、`state`、`info`。
   - `state` 相关字段：`points loading candidates refreshing anchorA anchorB prompt promptInsert promptRetimed routeBusy cross route{source,notes[]} routeCache{entries,hits} batch{phase,requests,requestsByHost,cacheHits,items[]{kind,status,source,include,picked,routes[]}}`。
   - `reviewstate`：`detail selected preview shownDraft sameGeometry changes[]{added,removed,retimed,drafts[],cross}`（`removed` 不含改时点）。

## 测试项

### 1. 回归脚本（7 个 + 2 个合成自测）
每条抄最后 5 行；末行 `FAILS: none` 为通过。
1. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_batch_review_tests.py 2>&1 | tee /tmp/r2_br.log | tail -5` → `FAILS: none`。
2. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_crosscheck_tests.py 2>&1 | tee /tmp/r2_cc.log | tail -5` → `FAILS: none`。
3. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_route_cache_tests.py 2>&1 | tee /tmp/r2_rc.log` → D0a–D0d、D1a–D1d、D2a–D2c、D3a–D3e、D6a–D6k、D4a–D4c、D5a–D5e 全 ok，末行 `FAILS: none`。抄 D0b、D1a、D1b、D2a、D3b、D4b、D5c；D0b 里的公路项数记为 **n**。
4. `pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_tunnel_fix_tests.py 2>&1 | tee /tmp/r2_tf.log` → T0、T1、T2a、T2b、T3、T4、T5、T6、T7a–T7d 全 ok，末行 `FAILS: none`。抄 `data …` 行、`candidates=…`（期望 50）、T1、T2b（retimed=1）、T3、T4（time 23:12:20–23:12:22）、T5（retimed=1 removed=4）、T6。脚本结束副本留着，紧接着跑 5、6。
5. `python3 -u Tests/ui/run_fill_tests.py 2>&1 | tail -5`（若 `state` 不返回 JSON 先起副本）→ `FAILS: none`。
6. `python3 -u Tests/ui/run_profile_tests.py 2>&1 | tail -8` → 含 `ok   P2 Garmin 候选 100（隧道群合并后；实际 100）`，末行 `FAILS: none`。
7. `sh Tests/synth/runner/run_all.sh 2>&1 | tail -15` → 有 `build ok`；`summary: 114 entries in … families, ok 114 …`（**114/114**），各家族 `N/N ok`，**无** `FAILED:` 行。
8. `Tests/synth/runner/synthrunner --portal-selftest Tests/synth/fixtures/tunnel; echo "exit=$?"` → 8 行 JSON 全 `"ok":true`，`exit=0`。
9. `python3 -I Tests/synth/runner/check_garmin_tunnel.py Tests/synth/runner/synthrunner data/compare/Muenchen_Roma_Garmin.gpx` → 全 ok，末行 `FAILS: none`。
- 失败时附 `tail -30 $HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/log.txt`。

### 2. 路网结果缓存（精确模式 + 假引擎）
起副本并 `autotripmap 0`。
1. `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"`，等 `loading` false。
2. `python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500" "crosscheck 1" "fakeroute all ok" "routecache clear" "batchplan" "sleep 800" "batchall road" "sleep 200" "batchrun"`；每 2 s 批次摘要直到 `phase preview`。期望 `road2`=n（>10，与 1.3 相同）；`byHost` 两台各 n；`cacheHits 0`；`routeCache {'entries': 2n, 'hits': 0}`；`python3 Tests/ui/ui.py "routecache stats"` → `entries=2n hits=0`。
3. `python3 Tests/ui/ui.py "batchclose" "sleep 300" "batchplan" "sleep 800" "batchall road" "sleep 200" "batchrun"`，等 preview。期望 `requests 0`、`byHost {}`、`cacheHits`=n、`routeCache {'entries': 2n, 'hits': 2n}`。
4. `python3 Tests/ui/ui.py "batchrefetch all"`，等 preview 且 `requests`>0。期望 `byHost` 两台各 n、`cacheHits 0`、entries 仍 2n。
5. 取 `road2idx` 前两个为 i0、i1。`python3 Tests/ui/ui.py "batchswap <i0>"`，批次摘要记 o0/v0；`python3 Tests/ui/ui.py "batchrefetch <i1>"`，等 i1 不是 `running`。期望两台各 +1；i1 `done`、include True；i0 仍 `valhallaCar`、picked True；`cacheHits 0`；`phase preview`。
6. `python3 Tests/ui/ui.py "routecache stats"`（entries>0）；`C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "batchclose" "exit" "open $C/uitest/Garmin_Roma_Da.gpx"`，等 `loading` false，**先**执行 `python3 Tests/ui/ui.py "routecache stats"` → `entries=0 hits=0`；`state.routeCache` = `{"entries":0,"hits":0}`。
7. `python3 Tests/ui/ui.py "fakeroute all ok" "fill" "sleep 1500" "select 0" "sleep 500" "routecross"`，每秒单处摘要直到 `routeBusy None` 且 source 非 None → `agree: True`、`cacheNote False`、`{'entries': 2, 'hits': 0}`；再 `routecross` → `cacheNote True`、hits 2；`routerefetch` → `cacheNote False`、hits 2、entries 2；`route car` → `source osrmCar`、`cacheNote True`、`{'entries': 2, 'hits': 3}`。
- 来源：`run_route_cache_tests.py` D0–D5；`docs/batch-review-design.md`「路网结果缓存」。

### 3. 修改记录两路切换
1. `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"`，等 loading false；`python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500" "crosscheck 1" "fakeroute all ok" "batchplan" "sleep 800" "batchall road" "sleep 200" "batchrun"`，等 preview；记第 0 项 source 为 S0。
2. `python3 Tests/ui/ui.py "batchreview" "sleep 1200" "reviewselect 0" "sleep 400" reviewstate` → `preview:true`、`detail:true`、`shownDraft`=S0、`sameGeometry:true`、`changes[0].drafts` 两份。
3. `python3 Tests/ui/ui.py "reviewdraft valhalla" reviewstate` → `valhallaCar`；批次摘要第 0 项 source 仍 S0。
4. `reviewdraft osrm` → `osrmCar`；`reviewdraft next` → `valhallaCar`。
5. `python3 Tests/ui/ui.py "reviewnext" "sleep 300" reviewstate` → `selected:1`、shownDraft = 第 2 个两路公路项的 source；`reviewprev` → `selected:0`、shownDraft=S0。
6. 取 `road2idx[0]`=f；`python3 Tests/ui/ui.py "fakeroute valhalla offset 30" "batchrefetch <f>"`，等第 f 项非 running → `conflict:disagree`；`python3 Tests/ui/ui.py "reviewselect 0" "sleep 500" reviewstate` → `sameGeometry:false`、drafts 两份；`reviewdraft valhalla` → `valhallaCar`。
7. 存证 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotviewwin 修改记录 $C/uitest/r2_review_toggle.png"`；然后 `python3 Tests/ui/ui.py "reviewdetail off" "fakeroute all ok"`。
- 来源：`run_route_cache_tests.py` D6a–D6k；`docs/batch-review-design.md`「两路切换」。

### 4. 隧道修正（Muenchen_Roma_Garmin，单处）
起副本并 `autotripmap 0`。
1. ```sh
   python3 -c "import re;t=open('data/compare/Muenchen_Roma_Garmin.gpx',encoding='utf-8').read();P=re.findall(r'<trkpt[^>]*lat=\"([-\d.]+)\"[^>]*lon=\"([-\d.]+)\"[^>]*>(.*?)</trkpt>',t,re.S);print(len(P));[print(k,P[k][0],P[k][1],re.search(r'<time>(.*?)</time>',P[k][2]).group(1)) for k in (9728,9732,9733,9734)]"
   ```
   → 第一行 `33496`；9733 时间 `…T23:12:14Z`；记 LAT33/LON33。
2. `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "fakeroute all ok" "crosscheck 0" "open $C/uitest/Muenchen_Roma_Garmin.gpx"`，等 loading false → `points:33496`。
3. `python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500"`，等 `refreshing` false 且 candidates>0 → `candidates:50`。
4. `python3 Tests/ui/ui.py "selectnear 46.503401 11.457193" "sleep 500" state` → `anchorA:9728`、`anchorB:9734`。
5. `python3 Tests/ui/ui.py "route car"`，单处摘要等到 `routeBusy None`；`state` 锚点仍 9728/9734。
6. `python3 Tests/ui/ui.py "apply" "sleep 600" state` → `prompt:true`、`promptRetimed:1`、`promptInsert`>0（docs 为 11，记 INS）。
7. `python3 Tests/ui/ui.py "confirm replace"`（返回含「替换」），等 points≠33496 且 loading false → points = 33496+INS−4（INS=11 时 **33503**）。
8. `python3 Tests/ui/ui.py "pointfind LAT33 LON33"` → `dist`<1；`python3 -c "import time;print(time.strftime('%H:%M:%S',time.gmtime(<time>)))"` → **23:12:20–23:12:22**。
9. `python3 Tests/ui/ui.py reviewstate` → changes 1 条，`retimed:1`、`removed:4`、`added`=INS。
10. `python3 Tests/ui/ui.py "reviewrevert 0"`，等 points=33496；`python3 Tests/ui/ui.py "pointat 9733"` → lat=LAT33（差<1e-7）、时间 **23:12:14**。
- 来源：`run_tunnel_fix_tests.py` T0–T6；`docs/cross-check-design.md` 末四节；诊断报告 §1.4、§7。

### 5. 用户路径上的新控件（不靠截图判对错）
1. `for s in '重新获取这一处' '重新获取全部' '两路几何完全相同' '来自缓存'; do printf '%s: ' "$s"; grep -rlaF "$s" /Applications/GPXPointViewer.app/Contents | head -1; echo; done` → 4 个都打印出路径。
2. `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"`，等 loading false；`python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500" "crosscheck 1" "fakeroute all ok" "batchplan" "sleep 800" "batchall road" "sleep 200" "batchrun"`，等 preview；再 `python3 Tests/ui/ui.py "batchclose" "sleep 300" "batchplan" "sleep 800" "batchall road" "sleep 200" "batchrun"`，等 preview；`python3 Tests/ui/ui.py "openbatch" "sleep 800" windows` → 有 `批量补点:` 窗口；批次摘要 `cacheHits`>0（第 3 步「…请用「重新获取全部…」或右键某一行」说明的显示条件，`BatchFillWindow.swift:590`）。存证 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotviewwin 批量补点 $C/uitest/r2_batch_step3.png"`。
3. 右键「重新获取这一处」和「重新获取全部…」弹层调用的 store 函数，分别和钩子 `batchrefetch <i>` / `batchrefetch all` 相同（`refetchBatchItem` / `refetchBatchAll`），第 2 项已验证；报告里注明即可。
4. `python3 Tests/ui/ui.py "batchreview" "sleep 1200" "reviewselect 0" "sleep 400" reviewstate` → `changes[0].drafts` 两份（分段控件显示条件 drafts>1，`ChangeReviewWindow.swift:312`），`sameGeometry:true`（提示显示条件，同文件 :321）。存证 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp; python3 Tests/ui/ui.py "shotviewwin 修改记录 $C/uitest/r2_review_seg.png"`。

### 6b. 底图来源与隧道叠加层（新功能，全部离线）
实现说明 `docs/map-sources.md`。钩子：`faketiles 0|1`（假瓦片、不出网，`state.tileRequests` 计数）、`tunnels 0|1`、`faketunnels <n>`（注入 n 条合成隧道）、`tunnelrefresh`、`mapnotice`、`mapgoto`；`state` 里有 `baseMap`、`fakeTiles`、`tileRequests`、`attribution`、`tunnelOverlay{on, ways, …}`，`reviewstate` 里有 `baseMap`、`attribution`、`tunnelOverlay`。
1. 新起副本后跑 `python3 Tests/ui/run_map_sources_tests.py 2>&1 | tee /tmp/ds_map.log | tail -30` — 期望末行 `FAILS: none`（M1–M4 共 24 项，脚本自己起副本）。
2. 手工核一遍（**脚本结束时会 pkill 副本，先按「准备」重新起一个副本并打开 Garmin_Roma_Da_copy.gpx**；隧道层只在视野 ≤40 km 时取，所以先 `mapgoto` 到轨迹附近的小视野）：`python3 Tests/ui/ui.py "mapgoto 42.0 12.5 10" "faketiles 1" "faketunnels 3" "tunnels 1" "sleep 1500" state`（`mapgoto` 参数顺序以 `UITestHook.swift` 的 `case "mapgoto"` 为准） — 期望 `tunnelOverlay.on == true`、`tunnelOverlay.ways == 3`、`fakeTiles == true`；再 `python3 Tests/ui/ui.py "tunnels 0" "faketunnels 0" "faketiles 0" state` — 期望 `tunnelOverlay.on == false`。
3. 报告里记录 `state.attribution` 在三种外部底图下的文字各是什么（用脚本日志 M4 那行即可），有没有空的。
**这一节的收尾也要做**：`python3 Tests/ui/ui.py "set mapStyle 标准" "reviewmap standard light 1" "tunnels 0" "faketiles 0"`。

### 6. 收尾（必须）
`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "fillpoints 0" "exit"`；`pkill -f Tests/ui/app.noindex/GPXPointViewer.app`；`pgrep -fl /Applications/GPXPointViewer.app` 若测前有输出，现在应仍有。

## 报告格式
- 开头：测的 app 路径、可执行文件修改时间、`python3 Tests/ui/ui.py info` 的 `front=`。
- 每个小步一行：`ok` / `FAIL` + 实际命令 + 关键输出原文（数字原样）。
- FAIL：现象、精确复现命令、期望 vs 实际、`log.txt` 末 30 行。
- 没做到的项写原因。
- **任务书本身的问题**单列一节（命令错、期望与行为矛盾但像是任务书写错、步骤顺序导致前提不成立）；不算产品缺陷。
- 不改期望、不装 /Applications、不改代码、**不联网**。
- 最后一句：「可以发布」或「不可以发布」+ 产品缺陷数 N（任务书问题另计）。
