# 公路补点「精确模式」（两路交叉验证）设计

记录日期 2026-10-25。用户需求原文：「现在公路补点是两个路网数据来源同时做（为了快），我希望加一种"精确模式"，
每条断点都用两个路网的数据来源做一遍，并交叉验证，如果两个路网给出的结果一致，就正常，不一致就报警，人工审核，
总之就是用时间换精度。」

## 现状（2026-10-25 安装版）
- 批量取草稿（TrackStore.runBatch）：一个共享队列，两个 worker 各绑一个引擎（OSRM = routing.openstreetmap.de，
  Valhalla = valhalla1.openstreetmap.de，FOSSGIS 两台不同机器）。谁空闲谁取下一处 → **每处只由一个引擎算**。
  每台服务器一个在途请求 + ≥1.05 s 间隔（RateLimiter.perform）。公路走 carRoute(economy: true)：上下文够干净即止，
  否则 匹配（仅 OSRM）→ 约束 → 直接 比绕路比。铁路走 railRoute（Overpass，唯一来源）。
- 单处补点：「路网草稿」菜单分别有 OSRM 公路 / Valhalla 公路 / Overpass 铁路，一次只请求一个来源。
- 两个引擎用的都是 OpenStreetMap 数据，但路由算法、代价模型、吸附逻辑不同：同一条路的几何来自同一批 OSM 节点
  （理论偏差 ≈ 0 m，Valhalla polyline6 精度 0.1 m），不同的路（对向车道、平行匝道、另一条道路）偏差 ≥ 15 m。

## 目标行为
1. 新开关 **精确模式**（批量第 1 步，与「只补公路」并列；UserDefaults 键 `fillCrossCheck`，默认关；钩子 `crosscheck 0|1`）。
2. 精确模式下每处**公路**断档同时向 OSRM 与 Valhalla 请求（两台不同机器，各自仍是 1 客户端 1 秒 1 次），两路都仍用
   economy（已验证的"够干净即止"规则），得到两份 RouteDraft 后做几何比对：
   - **一致** → 状态 done，采用其中一份（优先：警告少 → 残余偏移 snapA+snapB 小 → OSRM），notes 开头加一条
     「交叉验证：两路一致（重合 xx%，最大偏差 x m，长度 a / b m）；采用 OSRM」；另一份存 `BatchItem.altDraft`。
   - **不一致** → 新状态 `.conflict(summary)`：不勾选落地，两份草稿都保留（draft = OSRM 份、altDraft = Valhalla 份），
     「状态」列显示「两路不一致 · OSRM 1.2 km（上下文）/ Valhalla 2.4 km（直接）· 重合 40%」，悬停给出两边的 notes；
     主地图把这一处的两条线都画出来（OSRM 橙 + Valhalla 紫，选中时加粗）；「落地」列出现「用 OSRM」「用 Valhalla」
     两个按钮，点了就把选中的那份设为 draft、状态改 done、勾选落地（notes 记「人工选择 Valhalla」）。
   - **只有一路成功**（另一路 allEndpointsFailed / 超时 / NoRoute）→ 也进 `.conflict`，摘要写「只有 OSRM 给出结果
     （Valhalla：连不上）」，用户可一键采用那一份；不自动落地（精确模式下没经过比对的都要人看）。
   - 两路都失败 → 与现在相同（failed）。
   - 乱跳簇的本地「只删点」判定不涉及路网，照旧；铁路只有 Overpass 一个来源，照旧取一次，notes 加「铁路只有一个来源，
     未做交叉验证」。
3. 质量条新增「两路不一致、待审核 N」（紫色图标）+ 「只看待审核的」过滤；第 3 步摘要加「待审核 N」；
   「全部勾选成功的」不碰待审核项。紧凑卡片 statusText 同样显示。
4. 进度文字：「已完成 n/N · 精确模式（OSRM + Valhalla 交叉验证）· 正在取 公路 · …」。
5. 单处补点：「路网草稿」菜单加「公路 · 两路交叉验证」：同时请求两路，一致则应用采用的那份并在状态行标
   「两路一致」；不一致则应用 OSRM 份，警告「两路不一致：…（可从菜单改取 Valhalla 对比）」。

## 几何比对（纯函数 `RouteCrossCheck.compare`，放 RoadNetwork.swift，离线 harness 可编）
输入：两份 RouteDraft + 原锚点 a/b + 匹配半径 r。各自组成完整折线 [anchorA ?? a] + coords + [anchorB ?? b]。
- 容差 tol = max(15, r)（专用记录仪 15 m；手机 20–30 m）。对向车道中心线相距 15–40 m、平行匝道 ≥ 20 m，
  同一条路两引擎的节点坐标相同 → 15 m 能分开"同路/不同路"。
- 把 P 每 10 m 重采样，算每个样点到 Q 折线的最近距离；coverP = 距离 ≤ tol 的样点占比；对 Q 同样算 coverQ。
  maxDev = 两个方向最近距离的最大值（Hausdorff），meanDev = 均值。
- **一致**：min(coverP, coverQ) ≥ 0.97 且 未重合长度 ≤ max(40 m, 3% 长度)，且 |lenP − lenQ| ≤ max(50 m, 5%)。
  （两端渐进靠拢段两边都是向同一锚点靠，差异小；若一方外推了锚点而另一方没有，未重合长度 = 外推段长度 → 判不一致，
  这是真实分歧：两路对"隧道口在哪"看法不同。）
- 输出：CrossCheck { agree: Bool, coverP, coverQ, maxDev, meanDev, lenP, lenQ, summary: String }。
- 兜底：任一方 coords 为空（直线即可）→ 用两端直连比；两方都空 → 一致。

## 并发与失败
- 精确模式仍开 2 个 worker，但每个 worker 对一处同时发两路（`async let`），RateLimiter 保证每台主机只有一个在途、
  ≥1.05 s 间隔；吞吐约为普通模式一半（每处 ≈ max(两路耗时)）。
- 连续传输失败按引擎分别计数（actor 共享）：某一路连续 3 处 allEndpointsFailed → 该路停用，剩余各处只走另一路、
  全部进 conflict（「只有 X 给出结果（Y 已停用：连不上）」）；两路都停用 → 与现在相同，停止并标失败。
- 取消：两路请求都要收到 cancel（async let 任务随父任务取消）。

## 测试
- 离线：synthrunner 里加 `crosscheck` 子命令跑合成折线用例（相同几何、Valhalla 节点抽稀、对向车道 25 m、匝道分叉、
  一方外推锚点、一方空 coords）——由 Claude 做。
- 在线：Garmin_Roma_Da_copy 公路断档批量（精确模式）——用户的实数据，一次只一个客户端；统计一致/不一致数并逐处看
  不一致的是否真有分歧——由 Claude 做。
- 对抗复审工作流（verify-cross-check）：并发/取消/世代号、状态机、UI 文案、i18n。
- DeepSeek：钩子级机械回归（开关持久化、状态 JSON 字段、选用按钮、普通模式不受影响）。


## 2026-10-25 评审后的修订（三视角评审 wf_feca8d26-6fb：几何 / 并发 / 交互）
以下取代上文相应段落：
- **容差固定 10 m，与匹配半径无关**。两份都是 OSM 中心线、锚点共用，GPS 噪声不进这个比较；按半径放宽只会把 10–30 m 的
  同向平行路（集散车道、辅路、匝道、新旧线；护栏分向车道 11–15 m）判成同一条。对向车道沿 A→B 方向本来路由不上去，
  真正会漏的是同向平行路。自测可用 `crosstol` 覆盖。
- **判定看最长连续超容差段**，不看百分比：ln = 较短者长度，步长 5 m（<1 km）/10 m，允许的分歧段 R = clamp(0.15·ln, 15, 40) m；
  一致 ⇔ 两方向最长连续超容差段 ≤ R，且超容差总长 ≤ R + min(120, 0.2%)，且长度差 ≤ max(25 m, 1%)。
  外推点数不同时无条件判不一致，几何只比两边都覆盖的内段，原因写成「两路对隧道口位置判断不同；中间路段几何一致/也不一致」。
- **一致 ≠ 正确**：两个服务用同一份地图、同一组锚点，锚点漂到旁边路上时会一起接错。一致项保留采用份的警告；
  没外推的锚点离路 > max(1.5·r, 20) m 时另加一条疑点（橙色「有疑点」，仍勾选）。economy 规则不改（两路都「达标即止」，
  结果与普通模式可比；关掉要多发 /match，OSRM 被节流到 7–9 s 一次）。
- **状态模型**：待选项 `draft = nil`，两份草稿放 `BatchItem.crossDrafts`（OSRM 在前），`cross` 存比对结果；
  `BatchStatus.conflict(.disagree)` = 两路不是同一条路，`.conflict(.unverified(原因))` = 只有一路有结果、没比成。
  选定（`resolveBatchConflict`：选一路 / 直线 / 都不补）后才写 draft、置 done、`userPicked = true`；一致项的另一份也留在 crossDrafts，
  done 项可「改用另一条」。`isFinished` 统一进度口径。setBatchInclude/Straight/DeleteOnly 对待选项不生效；「取消勾选直接」不碰用户手选过的。
- **并发**：`RateLimiter.perform` 重写——检查与占位同一同步段、睡醒重检（原先先占槽再睡，两路同打一台主机时会放出两个在途请求）；
  429/5xx 设按主机共享的冷却（max(Retry-After, 10 s)，连续指数加倍到 120 s），fetch* 的各自 5 s 退避删掉；取消不记进 NetworkHealth。
  `BatchCoordinator`（队列 + 引擎健康一个 actor）：take() 原子给出下一处与此刻未停用的引擎；传输失败连续 3 次或一次 429 冷却中 → 停用（粘滞）；
  两路都停用时公路项不再发出、铁路照常。精确模式 carRoute 传 `failFast`：任一候选传输失败/429 立刻放弃这一腿。
  取消只认 `Task.isCancelled`（LegOutcome.classify）。
- **界面**：开关放在开始按钮旁并显示预计用时；质量条分「两路一致 / 两路不一致、要你选 / 只有一路有结果、没比对」三计数；
  待选行用 Menu「选一条…」（宽度不受语言影响），紧凑卡片也有，并有「下一处要选的 ›」；地图上待选项两路都画成"待你选"蓝：OSRM 实线、
  Valhalla 长虚线（[10,4]，与红失败线 [5,5] 分开），不按未勾选淡化；落地按钮旁提示「还有 K 处等你选，落地后这些不补」；
  第 3 步有「只有一路结果的 M 处全部采用」。用词：不用「待审核」「报警」「冲突」「已验证」；摘要给「分歧段 x m」而不是百分比。
- **可测性**：钩子 `crosscheck 0|1`、`fakeroute <osrm|valhalla|all> <ok|offset m|noroute|fail|slow ms|off>`（假引擎，不联网）、
  `crosstol <m>|off`、`batchpick <i> osrm|valhalla|straight|none`、`batchswap <i>`、`batchnextconflict`、`batchincludeall`、
  `batchstraightall`、`batchuncheck`、`batchacceptunverified`、`routecross`、`routeswap`；状态 JSON 每项 `source/cross/routes/picked/coverage/maxDev/diverge/lenO/lenV`，
  batch 层 `crossCheck/engineDisabled/counts/requestsByHost`。离线自测：`synthrunner --crosscheck-selftest`、`--ratelimit-selftest`。
  **纪律**：DeepSeek 只跑假引擎（不联网）；在线验证只由 Claude 跑一次、限制约 15–20 处公路；测试结束 `crosscheck 0`（设置与 /Applications 共用）。
- 未做（记录）：待选项「对这 N 处重新交叉验证」；单处模式两路进度合成一行；选中待选项时在两线相距最远处贴引擎名标签。

## 2026-10-25 实现后的对抗复审修订（verify-cross-check wf_7a0181ca-ce2：34 条确认，全部已修）
- **限流礼仪**：`carRoute(failFast:)` 现在一路贯穿到 `fetchOSRM/fetchValhalla/fetchMatch(failFast:)`——精确模式下 429/5xx 不重发；
  `RateLimiter.perform(failIfCooling:)` 主机冷却中直接抛 `HostCooling`，在途的腿也不会再打被限流的主机。冷却 = max(服务器 Retry-After（秒或 HTTP 日期）, 指数退避 10·2^(n−1) 封顶 120 s)。
- **队列**：`BatchCoordinator.take(worker:)` 一步到位（无 putBack）：需要公路引擎的项只给引擎活着的 worker，铁路/本地只删点谁都能做；两路都停用只拦需要引擎的项。
- **状态**：「都不补」= 待选 + `declined`（两份草稿和地图线都留着，`pickMenu` 变成「不补（改选…）」）；已选定的项也能「改选…」；一致项两份草稿都带说明和锚点提醒；
  `pendingPickCount` 驱动「还有 K 处等你选」「下一处要选的」；直线（人工选择）不计入成功；`fillCrossDrafts` 在撤销/丢弃/放弃批量后与画面对齐。
- **文案**：悬停标题整句键「— %@：%@」；「直线」动作用 `batch.pick.straight`（de Gerade；列头仍是 Luftlinie）；「两路一致」帮助改为与规则一致的说法；第 2 步说明补上「只有一路有结果」。
- ~~仍未做：选中待选项时在两线相距最远处贴引擎名；单处两路进度合成一行；对「只有一路结果」的处一键重新交叉验证。~~ **2026-10-28 已做**（见下节）。

## 2026-10-28 延后项收尾（loose-ends 任务）
- **【已做】分歧线上标引擎名**：`TrackStore.FillOverlay.engineLabels(_:)`（ContentView.swift）对等你选的两路（覆盖层 status 4 = OSRM 实线、5 = Valhalla 虚线）在每条线的**屏幕弧长中点**放一个蓝底白字小标签「OSRM」「Valhalla」，沿该点法向错开 11 pt（OSRM 一侧、Valhalla 另一侧，两线重合时也不叠）；线在屏幕上短于 90 pt（缩小到看不清）就不标。画在 SwiftUI 补点覆盖层（FillOverlayView，与线同一层、同一套屏幕坐标），不加 MKAnnotation、不动 Metal。选了中点而不是「相距最远处」：最远处要两线配对求距离，中点对单条线就能算，且线一短就整体隐藏。钩子 `state.batch.lineLabels` = 同一函数对 `lastOverlay.batchLines` 的计数。
- **【已做】单处两路进度合成一行**：单处「沿公路取路径并交叉验证」时操作条只显示一行 `TrackStore.crossProgressLine`：「OSRM ✓ · Valhalla 取路中…」（每路 取路中… / ✓ / 没有结果）；每路的 carRoute 返回时（含缓存命中）更新 `fillCrossLegStatus`。引擎内部细节进度（「请求 OSRM 上下文…」之类）不再抢那一行，改进悬停提示（`fillRouteProgressDetail`）。文字栏宽 190 → 240 pt。钩子：`state.routeProgress`（合成行）、`routeProgressDetail`、`crossLegs`（`[OSRM, Valhalla]`，0 取路中 1 有结果 2 没有结果）。
- **【已做】「只有一路结果」一键重新比对**：`TrackStore.recrossBatchItem(id)` / `recrossUnverifiedAll()`：只对 `unverified` 且没选「都不补」的项，复用 `refetchBatchItem(id, forceCross: true)` 的 ignoreCache 路径（两路都取，不管当前「精确模式」勾没勾；新建 BatchCoordinator，之前批次里停用的引擎这次照样请求——是用户明确要求的重试）。界面：「选一条…」菜单底部「重新比对这一处（两路重取）」、表格右键同名项（多选时「重新比对这 N 处」）、质量条「只有一路有结果、没比对 N」旁「全部重新比对 N 处」（只在第 3 步显示）。钩子 `batchrecross all|<i>`（返回 `started=`）。

## 2026-10-26 隧道补点 5 处问题的修正（诊断：Tests/reports/20261026_1500_tunnel_diagnosis.md）

### 后处理伪影（trimEnds / taper）与修正
- **根因**（报告 §1.2、§2.2，第 14/16/19 处）：`RoadNetwork.trimEnds` 把离锚点 A <30 m 的首顶点（裁剪投影点）当"锚点旁的小折"删掉；隧道 way 只有 2 个节点时下一顶点在 155 m 外，整条直边一起丢失。随后 `PortalDrift.taper` 对剩余折线**首段的无限延长线**量垂距 d（算了 `along` 却不检查），得出「A 离路 32 m」（真实 12 m），把首点平移到 152 m 外：前 34–145 m 的补点横向偏 16–32 m，看着像跑到旁边的路上。两路一致是因为同走这段后处理，交叉验证抓不到。
- **修正**：
  - `trimEnds(_:a:b:stepA:stepB:)`：只有「下一顶点离锚点 ≤ max(60 m, 2×局部步长)」时才删近点；否则保留投影点。步长 = 锚点外侧第一个真实点的距离（portal 样本），钳 10–100 m。
  - `PortalDrift.taper(_:a:b:dA:dB:minOffset:)`：`along < −10 m`（垂足在首点后方 = 首点在锚点前方，锚点旁的路网点被 trimEnds 删了）时分两种：首段延长线量出的垂距与 snap 对不上（|差| > max(5, 0.3×snap)，第 14 处 32 对 12）= 伪影，不 taper；量出的垂距 ≈ snap = 首段直线确实从锚点旁经过，把垂足补回当首点再照常 taper（复审补的，否则锚点离路 15–28 m、节点密时会留一条斜线）。d 用 clip 已算出的锚点到原始 raw 折线的距离（snapA/snapB），不再对单段延长线量；门槛由固定 8 m 改为 `max(8, tolOn)`（tolOn = max(匹配半径, 10)）——锚点在匹配半径内就是"在路上"，路网几何比锚点准，不该把路往 GPS 噪声弯；超出半径且漂移判定没挪锚点时才有真实残余偏移需要渐进靠拢。`RouteDraft.taperA/taperB` 记录实际用的 d。
  - 事后自检：A→首顶点距离 > max(60, 2×步长)（与 trimEnds 允许首点停下的 reach 一致，比它低会把城市慢速断档全误报），或距离 >30 m 且方向与 bearingA 差 >30° → warning「补点起始段不是路网几何（…），请在地图上看一眼」；B 侧对称。trimExcursion 是否截过端按 <0.05 m 判同点（坐标经局部平面来回换算，位级未必相等）。
  - `RouteCrossCheck.anchorWarning` 同时看 taper 的 d：`taperA − residualA > 10 m` 也报（伪影信号；判定规则 compare 未动）。
- **测试**：`synthrunner --portal-selftest [Tests/synth/fixtures/tunnel]`（夹具 = 诊断的 OSRM 上下文几何 gap14/15/18 + 第 16/19 处的 OSM way 节点）：gap14 首顶点距 A 投影 0 m、8 个补点到理想折线 ≤0.3 m、notes 不含「A 离路 32 m」；gap16/19 顶点到 OSM way 0 m（修前 24 m）；反例：锚点真离路 40 m 仍 taper（d=40）、锚点旁 <30 m 的小折仍删、2 节点隧道保留投影点、A 离路 20 m + 节点每 10 m（投影点被删、along ≈ −30）补回垂足后 taper d=20；anchorWarning 条件。共 8 例。
- 已知取舍：taper 门槛 `max(8, tolOn)` 意味着锚点离路 8–15 m（手机 8–30 m）的普通断档不再渐进靠拢，A→首个补点是一段由 A 的定位误差决定的短斜线（补点全在路网上）；旧行为会把前 80 m 的补点往 GPS 噪声弯——按诊断「补点横向偏离像跑到旁边的路上」的用户诉求，选了前者。

### 冻结假点链（A 侧外推点前移）
- **现象**（报告 §1.3）：Garmin 进隧道后设备继续外推几个点（航向 225.7°、步长 28.6 m 锁死），锚点 A 落在假点上。纯冻结规则全文件误报 1962 段（高速直路定速巡航的真实点同样"冻"），有判别力的是"掐弯"：冻结前在转弯、冻结段突然变 0。
- **规则**（`GapDetector.shiftFrozenChains`，只对专用记录仪画像的 staleClock 候选、只在锚点 A 处判）：A 往前 9 步都 dt=1 且 A−1 步长 20–80 m；从 A−1 往回数连续步，相邻航向差 ≤0.2° 且步长差 ≤0.2 m，链长 n ∈ [3, 6]（n>6 当真实直路）；链起点前 5 步内 max|Δ航向| ≥1.0°/s；命中则 A 前移 n 点，`GapCandidate.frozenA = n`，原 A−n+1…A 随区间替换（不作派生顶点、不参与"保留改时"），notes 加「A 前 n 个点是进隧道后的外推点（航向/步长锁死），已并入替换区间」。B 侧不做（44 处 B 后冻结步数全 ≤1）。
- **验证**（Garmin 文件 44 处）：命中 12 处（9050 −4、9323 −4、9468 −3、9732 −4、10021 −5、20885 −5、21242 −3、21385 −3、21448 −3、21730 −3、31246 −5、31290 −5），23756（12 步直路）、21676 不动；`Tests/synth/runner/check_garmin_tunnel.py`。

### 过时点保留改时
- **现象**（报告 §1.4）：第 14 处区间内点 9733 位置在出口车道上（离路 3.3 m）是对的，时间戳滞后 7–8 s；原来整点替换，用户说「删了不该删的点」。
- **规则**（staleClock 候选、锚点未手动改过；`GapFill.swift` 纯函数，单处与批量共用）：区间内的过时出口点（排除冻结假点）若离最终路线 ≤ max(匹配半径, 10) m，且按回推时间算车速在 15–350 km/h，**保留位置、只改时间**：t′ = tB − Σ(到 B 的沿路距离)/v_B（链式多点从 B 往回按累计距离依次回推，取整秒，严格递增）；不满足的退回整点替换。补点区间随之变成 A→第一个保留点，新增点只填 A 与保留点之间。复审补的边界：A→第一个保留点的隐含车速也要在 15–350 km/h（出口单步速度偏低时 t′ 会贴近 tA，否则会铺出上千 km/h 的合成点），不满足就把最早的保留点退回替换再看下一个；锚点被路网草稿自动外推（shiftA/shiftB）时单处与批量都仍做（`StaleRetime.plan` 接受 ia ≤ A、ib ≥ B，过时点范围 (A+frozenA, min(ib−1, B)]），手动挪过锚点才按老规则；没取路网、顶点就是过时点派生的（离路恒 0）时不做；有改时计划时区间内其余点一律替换；「保留」（不删区间内点）时不改时、合成点铺满 A→B（确认框按钮用 `FillPrompt.insertKeep`）。
- **记录**：改时点在 `TrackChange` 里按「removed(旧) + added(新)」表示（还原使用包含段身份的完整位值键和多重集，全部还原恢复会话基线；有后续依赖时安全拒绝单独还原，见 [分段与编辑契约](segment-topology-design.md)），另加 `retimed` 计数与 `retimedKeys`（新点键）/ `retimedOldKeys`（旧点键）用于显示：摘要「+N 点 · 改时间 K 点」（added/removed 计数都不含改时点），详细页图例多一种颜色「改时间的点」（橙，fileID 3），审阅图按完整键隐藏改时点的旧点（不按坐标猜，同坐标的别的被删点照常标红）；导出增量同样按新旧两条记。确认框：过时点数不含冻结外推点，冻结点另起一句「另外 n 个点是进隧道后设备按最后航向外推出来的…」。
- **测试**：`Tests/ui/run_tunnel_fix_tests.py`（离线假引擎；9732 候选 → A 前移到 9728，+11 −4，9733 保留、时间 23:12:14→23:12:21，修改记录 retimed 1，还原回原值；对照 21676）。

### 短断档门槛 V1（staleClock 微型入口）
- **现象**（报告 §3，第 33 处附近 21647→21648）：1 s 跳 109 m + 4 s 跳 27 m 的微型隧道，卡 `minMeters 150` / `staleMinJump 5 s` / A→B ≥150 / 上下文 5×typical；全文件同类 6 处。
- **规则**（`GapDetector.detect`，只对 d < 150 m、dt < 20 s 且隐含速度 >350 km/h 的入口生效，d ≥150 的老入口参数不变——与诊断 python 的 base ∪ v1 一致，只增不减）：入口 `d ≥ max(60, 3.5×前 12 步中位步长)`；时钟跳变 ≥4 s（`Options.staleMicroMinJump`）；A→B 距离用同一 gate；上下文 `d ≥ 3.5×typical`。
- **验证**：Garmin 文件候选 44→50，新增正好 iA = 8782、9807、9919、20907、21464、21646（报告按 1 s 大跳终点写作 8783…21647，是同一组 6 处）；原 44 处 iA/iB 不变；Inntal 2759–3012 无新增；合成套件 114/114 未变。Garmin_Roma_Da.gpx 候选 97→100（run_profile_tests P2 期望已改）：多出 14593→14599（9 s / 249 m）、29200→29206（10 s / 286 m）、29352→29358（10 s / 244 m）三处短隧道，原 97 处一处不少。

### 落地前自检与合成断档考卷（2026-10-27）
精确模式只能抓「两路选路不同」，抓不到几何同源的问题（同一份 OSM、同一组锚点、同一段后处理）。后续两道关在 `docs/fill-plausibility-design.md`：
(1) `FillPlausibility`——每处补点按纯几何指标（补点离路网原始折线、绕路比、隐含速度、起止方向、沿途换路、贴路、taper 伪影、折返、两路偏差）打 0–100 的风险分，high 默认不勾选落地；(2) `Tests/exam`——从完整轨迹挖段造「有标准答案」的断档，路网回复录制一次后离线回放，判卷并给出第一关的命中率/误报率。

## 2026-10-29 分段与改时覆盖修复

候选、采样、缓存、批次选择及预览统一使用 `GapID(trackID, segment, a, b)`。检测、上下文、行程和改时均按源段的真实邻接运行；即使全局时间范围交叠，编辑也只替换所选段的成员。合并链资格回调接收相邻原候选，避免聚合后身份变化吞掉三处以上的连续链。

改时保留点必须形成通向 B 的连续出口尾链；以改后时间和实际位置检查下一保留点，仍有长缺口则将未覆盖前缀交给路线插值。两处真实 underfill 已用实际 Store 落地、重检测及精确还原验证，评分阈值保持不变。详情及反例在 [分段设计](segment-topology-design.md)。
