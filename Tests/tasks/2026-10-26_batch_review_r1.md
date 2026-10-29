# 任务：落地前审阅 / 落地提示 / 路网证据留档 / 修改记录底图 · 2026-10-26 · 第 1 轮（全部离线，不许联网）

## 背景（这次改了什么、为什么）
用户用 Muenchen_Roma_Garmin 批量落地 44 处后反馈：落地后批量窗口停在空页；修改记录地图上蓝点看不清；落地后查不到当时两路路网各给了什么；落地前看不到总体效果。
这次改动：① 落地后关闭批量窗口，主窗口顶部横幅「已落地 N 处 · 新增 X 点 · 替换 Y 点」+「查看修改记录」；② 修改记录窗口有自己的底图（标准/卫星/混合）和「浅色」开关（默认开），点一律白描边；
③ 每条落地记录带两路路网草稿、比对结果、依据、警告、说明（详细页画折线：绿细线 = 采用、蓝虚线 = 另一路；「说明…」弹出全文）；④ 批量第 3 步「审阅落地效果…」= 修改记录窗口的预览模式：总览 + ‹ ›/← → 逐处看将新增（绿）/将替换（红）的点，逐处落地开关联动批量勾选，「落地 N 处…」直接落地。
另外：补点点距严格按原始点距；单处交叉验证后 OSRM/Valhalla 分段切换；「显示补的点」开关；第 1 步地图判段可跳过的提示。

## 范围
- 要测：上面 ①–④ 的状态机与钩子字段（全部可离线）；点距；显示补的点；相关回归脚本。
- 不用测：地区统计、导出、本地化文字（Claude 已核对编译后的 en/de/zh-Hant 目录）；真实路网请求（Claude 已用真实数据做过一次复现：5 处两路一致、都是隧道）。
- **锁屏时截图全白**（`python3 Tests/ui/ui.py info` 里 `front=loginwindow`）：本轮不靠截图判对错；`shotviewwin` 只能看布局块。

## 第 1 轮结果（2026-10-26 03:57 报告 Tests/reports/20261026_0357_2026-10-26_batch_review_r1.md）
- 结论「可以发布，产品缺陷 0 处」；唯一问题是本文档第 7/8 项排在第 5 项全量落地之后、没有候选可选——已在第 7 项开头加恢复步骤。

## 硬规则
- 启动测试副本后先 `python3 Tests/ui/ui.py "autotripmap 0"`；任何 `batchrun` / `routecross` 前先设 `fakeroute`（见下）。不要运行 run_batch_drift.py / run_crosscheck_online.py / run_route_tests.py / run_drift_tests.py（联网）。
- 结束必须：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "fillpoints 0"`（这些设置与 /Applications 的 app 共用容器偏好）。

## 准备（完整写法，不要去翻以前的文档）
- 构建：`xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build`，必须出现 `** BUILD SUCCEEDED **`。
  测的 app 由 `Tests/ui/ui.py` 的 `app_source()` 决定：环境变量 `GPXPV_APP` > DerivedData 里刚构建的 Release > `/Applications/GPXPointViewer.app`；报告里写清测的是哪份、可执行文件修改时间（`ls -l <app>/Contents/MacOS/GPXPointViewer`）。
- 测试副本放 `Tests/ui/app.noindex/GPXPointViewer.app`（从 app_source() 那份整体复制）。**一次只开一个**测试副本；`/Applications` 里用户正在用的实例**不要 kill**，只 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。
- 容器目录 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp`：钩子通信目录 `$C/uitest`；测试数据：`cp data/Garmin_Roma_Da_copy.gpx "$C/uitest/"`。
- 启动测试副本（钩子 + 钉简体中文）：
  ```sh
  pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
  mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
  open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages '(zh-Hans)'
  ```
  等 `python3 Tests/ui/ui.py state` 返回含 `points` 的 JSON 就是起来了。`run_*.py` 脚本里凡写了"自己重启测试副本"的，跑之前先 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。
- 发命令：`python3 Tests/ui/ui.py "cmd1" "cmd2" …`（每个参数一条，结果按行返回；`sleep 800` 这类是毫秒）。
- 本轮用到的钩子：`open <路径>`、`fill`、`exit`、`select <i>`、`crosscheck 0|1`、`fakeroute <osrm|valhalla|all> <ok|offset <米>|noroute|fail|off>`、`autotripmap 0|1`、`batchplan`、`batchall road`、`batchrun`、`batchpick <i> osrm|valhalla|straight|none`、`batchreview`（进预览模式并开修改记录窗口）、
  `reviewstate`（JSON：`detail/selected/building/preview/mapStyle/light/reviewPoints/trackPoints/fills/loading/visible/changes[]`，每条 `changes[]` 含 `i/kind/added/removed/reverted/lat/lon/bbox/trackTime/place/included/pending/straight/drafts[]/cross/warnings`）、
  `reviewselect <i>`、`reviewnext`、`reviewprev`、`reviewdetail off`、`reviewinclude <i> 0|1`、`reviewmap standard|imagery|hybrid [light 0|1]`、`batchland`、`toastdismiss`、`windows`（可见窗口列表）、`fillpoints 0|1`、`routecross`、`routeswap`、`routedump <容器内路径>`、`relaunch`、`state`（根里有 `toast`、`spacing`、`localStep`、`showPoints`、`previewPoints`、`cross`、`route`、`fills`、`batch{…}`）。

## 测试项（每项给命令 + 期望）
1. 审阅/落地离线回归（核心）— 命令：`pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_batch_review_tests.py 2>&1 | tee /tmp/br_ui.log`（约 3 分钟，脚本自己起副本）— 期望：A0–A9、B1–B3、C1–C6 全部 `ok`，最后 `FAILS: none`。把 A2、A3、A6、A7、C2、C5 六行原样抄进报告（C2 应为 `已落地 3 处 · 新增 46 点 · 替换 15 点`）。
2. 精确模式离线回归 — 命令：`pkill -f Tests/ui/app.noindex/GPXPointViewer.app; python3 -u Tests/ui/run_crosscheck_tests.py 2>&1 | tail -5` — 期望：`FAILS: none`。
3. 修改记录（已落地记录）回归 — 先按「准备」起副本并 `autotripmap 0`；命令：`python3 -u Tests/ui/run_review_tests.py 2>&1 | tail -4` — 期望：`FAILS: none`。
4. 审阅底图设置持久化 — 接上一步的副本：`python3 Tests/ui/ui.py "reviewmap hybrid light 0" "relaunch"`；等 10 s；`python3 Tests/ui/ui.py reviewstate` — 期望：`"mapStyle":"混合","light":false`。再 `python3 Tests/ui/ui.py "reviewmap standard light 1" "relaunch"`，等 10 s，`reviewstate` 里 `"mapStyle":"标准","light":true`。
5. 落地提示不会卡住后续操作 — 接上：`python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"`，等 `state` 的 `loading` 为 false；`python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500" "crosscheck 0" "fakeroute all ok" "batchplan" "sleep 800" "batchall road" "batchrun"`；每 2 s 读 `state` 直到 `batch.phase` 为 `preview`；`python3 Tests/ui/ui.py "batchland"`；每秒读 `state` 直到 `batch` 为 null 且 `fills` ≥ 97 —
   期望：`state.toast` 以 `已落地 97 处` 开头；`python3 Tests/ui/ui.py windows` 里没有「批量补点」窗口；等 8 s 后 `state.toast` 自动变为 null（6 s 自动消失）。
6. 落地记录带路网证据 — 接上：`python3 Tests/ui/ui.py review reviewstate`（`review` 开窗口）— 期望：`preview:false`，`changes` 有 97 条，每条 `drafts` 非空（普通模式一份 `["osrmCar"]` 或 `["valhallaCar"]`），`cross` 为 null（普通模式没比对）。
7. 点距按原始 + 显示补的点 — **第 5 项落地全部 97 处后已没有候选**（第 1 轮 DeepSeek 指出），先重开文件恢复候选：`python3 Tests/ui/ui.py "open $C/uitest/Garmin_Roma_Da_copy.gpx"`，等 `loading` 为 false，再 `python3 Tests/ui/ui.py "exit" "sleep 300" "fill" "sleep 1500"`；然后：`python3 Tests/ui/ui.py "select 0" "sleep 800" state` — 期望：`spacing` 等于 `localStep[0]` 四舍五入（Garmin 这份约 27）、`spacingManual:false`；`python3 Tests/ui/ui.py "fillpoints 1" state` → `showPoints:true`、`previewPoints` > 0；`fillpoints 0` 后 `previewPoints` 为 0。
8. 单处交叉验证切换 — 接上：`python3 Tests/ui/ui.py "fakeroute all ok" "routecross"`，每秒读 `state` 直到 `routeBusy` 为 null — 期望 `cross.agree:true`、`route.source:"osrmCar"`；`python3 Tests/ui/ui.py routeswap state` → `route.source:"valhallaCar"`；再 `routeswap` → 回 `osrmCar`。`python3 Tests/ui/ui.py "routedump $C/uitest/rd.json"` 后 `python3 -c "import json;d=json.load(open('$C/uitest/rd.json'));print(sorted(d), len(d['points']), d['cross']['agree'])"` — 期望：键含 `anchorA anchorB cross points route vertices`，`points` 数 > 0，`cross.agree` True。
9. 收尾（必须）— `python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "fillpoints 0" "exit"`；`pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。

## 报告要求（完整写法）
- 每项：做了什么命令、关键输出（JSON 可只抄相关字段）、通过/失败。数字原样抄录，不要四舍五入。
- 失败或任何不符合预期的地方：现象、**精确到命令和参数的复现步骤**、期望 vs 实际、相关日志（`$C/uitest/log.txt`）。
- 没做到的项目写清原因（锁屏、权限、数据缺失等）。
- 不要为了变绿改期望；不要安装到 /Applications；不改任何代码或测试脚本；**不联网**。
- 最后一句话结论：可以发布 / 需要修复 N 处。
