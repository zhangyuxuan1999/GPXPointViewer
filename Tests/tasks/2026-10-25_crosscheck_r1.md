# 任务：公路补点「精确模式」（两路交叉验证）· 2026-10-25 · 第 1 轮（全部离线，不许联网）

## 背景（这次改了什么、为什么）
批量补点原来是 OSRM 与 Valhalla 两个路线服务「分头取」（每处断档只由其中一个算）。新加「精确模式」：每处公路断档同时发给两个服务，取回后比对几何——
是同一条路才自动采用；不是同一条路的、或只有一路给出结果的，不勾选落地，等用户在地图上选一条（「选一条…」菜单：选 OSRM / 选 Valhalla / 直线 / 都不补）。
同时重写了请求限速器（同一主机同一时刻只许一个在途请求 + 429 后冷却）。为了不打公共服务，app 里有**假引擎**钩子 `fakeroute`，本轮所有批量请求都必须先设假引擎。

## 范围
- 要测：离线自测（几何比对、限速器）；精确模式的批量状态机（一致 / 不一致 / 只有一路 / 两路都连不上 / 普通模式不受影响 / 单处交叉验证）；设置持久化；钩子 JSON 字段。
- 不用测：地区统计、修改记录、导出、本地化文字（本轮 Claude 已自验编译后的 en/de/zh-Hant 目录含新键）；**真实路网请求**（Claude 已单独做过一次在线验证：16 处公路 16 处一致、34 个请求；DeepSeek 一律不联网）。

## 第 1 轮结果（2026-10-25 22:19 报告）与修正
- 结论「可以发布」，功能断言全过。三条流程问题已修（2026-10-25 22:50 重装）：`relaunch` 现在通过容器 tmp 里的交接文件把钩子目录传给新实例（NSWorkspace 新实例拿不到环境变量和启动参数，实测被剥掉）；钩子读 `cmd` 偶发 ENOENT 改为下一拍重读；
  新钩子 `autotripmap 0|1`——离线测试一律先 `autotripmap 0`，否则 `batchplan` 会自动查 Overpass（真实联网）。`run_crosscheck_tests.py` 已自带 `autotripmap 0`。

## 硬规则
- **启动测试副本后先 `python3 Tests/ui/ui.py "autotripmap 0"`**（关掉进入批量时自动查 Overpass 判段），否则不算离线。
- **任何 `batchrun` / `routecross` / `route` 之前必须先 `fakeroute all ok`（或任务项指定的假模式）**；不要运行 `Tests/ui/run_batch_drift.py`、`Tests/ui/run_crosscheck_online.py`、`Tests/ui/run_route_tests.py`、`Tests/ui/run_drift_tests.py`（这些会联网）。
- 结束前必须执行 `python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "crosstol off"`：精确模式开关存在容器偏好里，与 /Applications 里用户在用的 app 共用。

## 准备（完整写法，不要去翻以前的文档）
- 构建：`xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build`，必须出现 `** BUILD SUCCEEDED **`。
  测的 app 由 `Tests/ui/ui.py` 的 `app_source()` 决定：环境变量 `GPXPV_APP` > DerivedData 里刚构建的 Release > `/Applications/GPXPointViewer.app`；报告里写清测的是哪份、可执行文件修改时间（`ls -l <app>/Contents/MacOS/GPXPointViewer`）。
- 离线自测程序：
  ```sh
  cd /Users/zyx/Documents/GPXPointViewer && swiftc -O -o Tests/synth/runner/synthrunner Tests/synth/runner/main.swift GPXPointViewer/GPXParser.swift GPXPointViewer/TrackData.swift GPXPointViewer/GapFill.swift GPXPointViewer/RoadNetwork.swift GPXPointViewer/GeoCompute.swift GPXPointViewer/MetalPointRenderer.swift GPXPointViewer/Colormaps.swift GPXPointViewer/Heat3D.swift GPXPointViewer/BatchFill.swift GPXPointViewer/PixelGlobe.swift GPXPointViewer/GPXWriter.swift GPXPointViewer/L10nSupport.swift 2>&1 | grep -c error:
  ```
  （约 30 s；输出 `0` 表示没有 error）。
- 测试副本放 `Tests/ui/app.noindex/GPXPointViewer.app`（从 app_source() 那份整体复制）。**一次只开一个**测试副本；`/Applications` 里用户正在用的实例**不要 kill**，只 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。
- 容器目录 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp`：钩子通信目录 `$C/uitest`；测试数据：`cp data/Garmin_Roma_Da_copy.gpx "$C/uitest/"`。
- 启动测试副本（钩子 + 钉简体中文）：
  ```sh
  pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
  mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
  open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages '(zh-Hans)'
  ```
  等 `python3 Tests/ui/ui.py state` 返回含 `points` 的 JSON 就是起来了。`Tests/ui/run_crosscheck_tests.py` 会**自己**启动/关闭测试副本（从 app_source() 复制），跑它之前先 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。
- 发命令：`python3 Tests/ui/ui.py "cmd1" "cmd2" …`（每个参数一条，结果按行返回；`sleep 800` 这类是毫秒）。
- 本功能用到的钩子：
  `open <路径>`、`fill`（进补点模式）、`exit`（退出补点模式）、`select <i>`（选第 i 处候选）、
  `crosscheck 0|1`（精确模式开关，持久化）、`fakeroute <osrm|valhalla|all> <ok|offset <米>|noroute|fail|slow <毫秒>|off>`（假引擎：ok = 两点直连弦上 3 个中间点；offset = 整条向右平移；noroute = 没路；fail = 连不上；off = 恢复真实请求），
  `crosstol <米>|off`（覆盖比对容差，默认 10 m）、`batchplan`（建表）、`batchall road|rail|skip`、`batchkind <i> road|rail|skip`、`batchrun`、`batchcancel`、`batchclose`、`batchland`、
  `batchselect <i>`、`batchpick <i> osrm|valhalla|straight|none`（等你选的那处做决定）、`batchswap <i>`（已选定/一致项改用另一条）、`batchnextconflict`、`batchincludeall`、`batchstraightall`、`batchuncheck`（取消勾选「直接」）、`batchacceptunverified`、
  `routecross`（单处：同时请求两路并比对）、`routeswap`（单处换看另一路）、`relaunch`（重开 app，钩子目录经交接文件传给新实例；-AppleLanguages 启动参数不会保留，存储的语言仍生效）、`autotripmap 0|1`（进入批量是否自动查 Overpass 判段）、`state`。
- `state` JSON 里与本功能有关的字段：根 `crossCheck`（开关）、`cross`（单处交叉验证：agree/shown/other/otherMeters 或 null）、`route`（单处草稿：source/warnings/…）、`fills`；
  `batch`：`phase`、`crossCheck`、`engineDisabled`（停用提示或 null）、`counts{agree,disagree,unverified}`、`requests`、`requestsByHost`、`included`、`lines`（覆盖层线数）、
  `items[]`：`status`（`pending|running|done|skipped|failed:…|nottunnel:…|conflict:disagree|conflict:unverified`）、`kind`、`meters`（-1 = 没有采用的草稿）、`source`（采用的来源 osrmCar/valhallaCar/空）、`cross`（agree/disagree/unverified/none）、
  `routes[]`（两路各自：engine/meters/method/warnings/shiftA/shiftB）、`picked`、`coverage/maxDev/diverge/lenO/lenV`、`include`、`straight`。
- **锁屏提示**：`python3 Tests/ui/ui.py info` 里 `front=loginwindow` 表示屏幕锁着：截图全白、地图相机动画不走。遇到就写进「没做到的项目」，**不要当作功能失败**。本轮不依赖截图。

## 测试项（每项给命令 + 期望）
1. 几何比对自测 — 命令：`Tests/synth/runner/synthrunner --crosscheck-selftest; echo exit=$?` — 期望：31 行 JSON，每行 `"ok":true`，最后 `exit=0`。把 `parallel_12m_300m`（agree false）、`one_stray_node_15m`（agree true）、`chord_vs_arc_sagitta5`（agree true）三行原样抄进报告。
2. 限速器自测 — 命令：`Tests/synth/runner/synthrunner --ratelimit-selftest; echo exit=$?`（约 8 s）— 期望：`"ok":true,"maxInFlight":1`，`minGapSeconds` ≥ 1.0，`cancelledQuickly":true`，`exit=0`。
3. 离线 UI 回归（核心）— 命令：`pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_crosscheck_tests.py 2>&1 | tee /tmp/xc_ui.log`（约 4–5 分钟）— 期望：第一行 `文件 46267 点 · 候选 97`；A0–A7、B1–B14、C1–C3、D1–D3、N1–N2、E1–E4 全部 `ok`，最后 `FAILS: none`，退出码 0。把 A4、B4、B10、C2、D2 五行原样抄进报告。
4. 开关持久化 — 启动测试副本后：`python3 Tests/ui/ui.py "crosscheck 1" "relaunch"`；等 10 s；`python3 Tests/ui/ui.py state` — 期望：JSON 根里 `"crossCheck":true`。再 `python3 Tests/ui/ui.py "crosscheck 0" "relaunch"`，等 10 s，`state` 里 `"crossCheck":false`。
5. 待选项不能被勾选/直线/只删点开关改动 — 命令（接上一步的副本）：
   `python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"`，等 `state` 的 `loading` 为 false；`python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500" "crosscheck 1" "fakeroute osrm ok" "fakeroute valhalla offset 30" "batchplan" "sleep 1000"`；等 `state.tripMapRunning` 为 false（最多 60 s）；`python3 Tests/ui/ui.py "batchall road" "batchrun"`；每 2 s 读 `state` 直到 `batch.phase` 为 `preview`。
   然后：`python3 Tests/ui/ui.py "batchincludeall" "batchstraightall" "state"` — 期望：`batch.included` 仍为 0，所有公路项 `status` 为 `conflict:disagree`、`include` 为 false、`straight` 为 false（这两个批量按钮不碰等你选的项）。
   再 `python3 Tests/ui/ui.py "batchpick 0 valhalla" "batchuncheck" "state"` — 期望：第 0 项 `status=done`、`source=valhallaCar`、`include=true`、`picked=true`（「取消勾选直接」不覆盖手选），`batch.included` = 1。
   再 `python3 Tests/ui/ui.py "batchswap 0" "state"` — 期望：第 0 项 `source=osrmCar`、`include=true`。
   `python3 Tests/ui/ui.py "batchclose"`。
6. 容差覆盖 — 命令：`python3 Tests/ui/ui.py "fakeroute all ok" "crosstol 0.001" "batchplan" "sleep 800"`；等 tripMapRunning 为 false；`python3 Tests/ui/ui.py "batchall road" "batchrun"`；等 preview；读 `state` — 期望：两路几何完全相同，所以即使容差 0.001 m 也全部 `cross=agree`（两份都是同一条弦）；`counts.agree` = 97。再 `python3 Tests/ui/ui.py "crosstol off" "batchclose"`。
7. 只有一路给出「没路」（不是连不上）— 命令：`python3 Tests/ui/ui.py "fakeroute osrm ok" "fakeroute valhalla noroute" "batchplan" "sleep 800"`；等 tripMapRunning false；`python3 Tests/ui/ui.py "batchall road" "batchrun"`；等 preview；读 `state` — 期望：所有公路项 `status=conflict:unverified`、`routes` 只有 osrm 一份、`batch.engineDisabled` 为 null（Valhalla 回答了「没路」，不算连不上，不停用）。`python3 Tests/ui/ui.py "batchclose"`。
8. 单处交叉验证 + 换看 — 命令：`python3 Tests/ui/ui.py "fakeroute all ok" "select 0" "sleep 500" "routecross"`；每秒读 `state` 直到 `routeBusy` 为 null — 期望：`cross.agree` 为 true，`route.source` 为 `osrmCar`。
   再 `python3 Tests/ui/ui.py "fakeroute valhalla offset 30" "routecross"`；等 `routeBusy` null — 期望：`cross.agree` false、`cross.shown=osrmCar`、`route.warnings` ≥ 1。`python3 Tests/ui/ui.py "routeswap" "state"` — 期望 `route.source=valhallaCar`；再 `routeswap` 回到 `osrmCar`。
9. 收尾（必须）— 命令：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "crosstol off" "exit"`；`pkill -f Tests/ui/app.noindex/GPXPointViewer.app` — 期望：返回 `crosscheck false`、`fakeroute OSRM=real Valhalla=real`、`crosstol 10.0`。

## 报告要求（完整写法）
- 每项：做了什么命令、关键输出（JSON 可只抄相关字段）、通过/失败。数字原样抄录，不要四舍五入。
- 失败或任何不符合预期的地方：现象、**精确到命令和参数的复现步骤**、期望 vs 实际、相关日志（`$C/uitest/log.txt`）。
- 没做到的项目写清原因（锁屏、权限、数据缺失等）。
- 不要为了变绿改期望；不要安装到 /Applications；不改任何代码或测试脚本；**不联网**。
- 最后一句话结论：可以发布 / 需要修复 N 处。
