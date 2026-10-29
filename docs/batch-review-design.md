# 批量补点：落地前审阅 / 落地记录保留路网证据 / 落地提示 / 修改记录可见度（2026-10-26）

用户反馈（Muenchen_Roma_Garmin 落地 44 处之后）：
1. 落地后批量窗口停在空页「在主窗口进入补点模式后…」——应该弹一个提示「落地成功」就完事。
2. 修改记录窗口里蓝色轨迹点在深色底图上看不清；加底图透明度条会把路也压暗。
3. 图 3–7：几处补点不在路上 / 中途换路又换回。
4. 落地之后查不到当时 OSRM / Valhalla 各给了什么——必须留着，能回查。
5. 落地前看不到总体效果，得一处处点；要一个像修改记录那样的页面：总览 + 逐处（‹ ›）看补出来的点，能把某些处设为不落地，再决定落地。

## 设计
### A 落地后的反馈
- `landBatch` 落地完成（performFills 回到主线程后）：关闭批量窗口（`NSApp.window(scene: SceneID.batchFill)?.performClose`），主窗口顶部出现 4 秒自动消失的横幅
  「已落地 N 处 · 新增 X 点 · 替换 Y 点 · 在「修改记录」里可逐处查看、还原」+「查看」按钮（开修改记录窗口）。横幅模型：`TrackStore.toast: Toast?`（文字 + 可选动作），`ContentView` 顶部 overlay。

### B 修改记录窗口的可见度
- 点一律带白描边（审阅图不受主窗口「白描边」设置影响），点径 ×1.3（总览）/ ×1.6（详细）。
- 窗口顶栏加「底图」分段：标准 / 卫星 / 混合（独立于主窗口设置；隧道段在卫星图上能看到洞口），以及「浅色」开关：MKMapView 用浅色外观（`appearance = NSAppearance(named: .aqua)`），深色点在浅色图上最清楚，路也看得清。
  不加透明度条：压暗层会把路一起压掉。

### C 路网证据随落地记录保留
- `GapFill` 加 `drafts: [RouteDraft]`（采用的那份在前；精确模式还有另一路）、`cross: RouteCrossCheck.Result?`、`adopted: RouteSource?`；`TrackChange` 加同样字段（从 GapFill 拷过去）。
- 修改记录详细页：地图上除绿点/红点外，画出每一份草稿的折线（采用的 = 绿细线，另一路 = 蓝长虚线），右侧（或详细页头下方）一个可折叠「依据」面板：来源 · 依据（匹配/上下文/…）· 长度 · 两路一致/不一致（分歧段）· 警告 · 说明（notes 全文）。
- 单处补点落地也记（fillRouteInfo → drafts/notes）；手动描线的记「纯手动」。

### D 落地前审阅（批量第 3 步）
- 批量窗口第 3 步加按钮「审阅落地效果…」（紧凑卡片也有）：打开修改记录窗口的「预览」模式——同一个窗口、同一套地图/合成轨迹机制，数据源换成 `batchPreviewChanges`：
  对每个 `willLand` 的批量项按落地口径（`spacingFor`、`keptInnerPoints`、外推锚点）算出 新增点 / 将替换的点 / 锚点，组成 `TrackChange`（kind .fill，`previewItemID = item.id`）；
  不落地的项也列出来（灰、标「不落地」），能在页面里切换。
- 预览模式的详细页头：‹ › 翻处、「不落地 / 落地」切换（= `setBatchInclude`）、来源与依据面板（同 C，直接读 BatchItem.draft/crossDrafts/cross）、精确模式待选项显示「等你选」并给「选一条…」。
- 顶栏按钮：「返回批量窗口」「落地 N 处」（= landBatch；落地后进入真实的修改记录模式）。
- 合成轨迹：`ChangeRevert.reviewParsed(current, previewChanges)`——现有函数即可（新增点追加、删除点标红）；键 = 轨迹 id + 各项 (id, include, draft.source, straight)。
- 键盘 ← → 翻处（两种模式通用）。

### E 图 3–7 的补点质量
- 先用真实数据复现那 5 处（Trentino A22 10-01 01:12、Trento 01:51、Monzuno A1 05:17、Calenzano A1 05:45、05:50），把两路草稿坐标 dump 出来，混合底图截图看是隧道段（Apple 地图不画隧道几何）、平行老路，还是路由本身选错。结论写回这里，再决定是否改路由规则。

## 测试
- 离线（假引擎）：落地提示与关窗、预览窗口翻阅/切换落地/计数、记录里的 drafts 字段、修改记录底图切换钩子。
- 真实数据：5 处复现（Claude，唯一客户端）。
- 对抗复审工作流一轮；DeepSeek 一轮离线回归。

## E 的结论（2026-10-26 04:10，真实数据复现 Muenchen_Roma_Garmin 的 5 处，唯一客户端、12 个请求）
全部 5 处 OSRM 与 Valhalla 完全一致（最大相差 0 m）、贴路 2–12 m、候选绕路比 ≈1.0，补的点都在**隧道**里，卫星图上一目了然：
- #14 Trentino（01:12，261 m）：A22 在 Tusch 山下的隧道；#16 Trento（01:51，869 m）：SS12 Galleria Doss Trento（穿山隧道，标准底图只画山外的 Via Piedicastello）；
- #19 Monzuno（05:17，1.2 km）：A1 Variante di Valico 的隧道/高架段（标准底图画的是旁边老路 Vado）；#33/#34 Calenzano（05:45 7.8 km / 05:50 2.0 km）：A1 Variante di Valico 的长隧道（Galleria di Base 一带，8.6 km；271 s 走 7.8 km ≈ 104 km/h 吻合）。
Apple 标准底图不画隧道几何（或画得极淡），所以看起来像"不在路上 / 中途换路又换回"。**路由本身没错**。对策：审阅地图可切卫星/混合（看到洞口），并把两路的依据、贴路距离、一致性保留在记录里。

## 路网结果缓存（2026-10-26，用户反馈：取消落地又反悔不该再从路网读）

- 模型：`RouteCacheKey` / `RouteCache`（`GPXPointViewer/BatchFill.swift`，无 UI 依赖，synth runner 也编）。`TrackStore.routeCache` 持有一份，主线程与批量 worker（nonisolated）通过锁访问（与 `OverpassCache` 同模式）。
- **键** = 一处断档向某来源取路的全部输入：`source`（OSRM 公路 / Valhalla 公路 / Overpass 铁路）、`economy`（批量省请求候选集 vs 单处交互候选集；单处的普通取路与交叉验证同为 false，共用）、锚点下标 `ia/ib` 与坐标 `a/b`、断档时长 `seconds`、两端行进方向 `bearingA/B`、近/远上下文 `contextA/B` `farContextA/B`（坐标 + 方向）、匹配轨迹 `trace`（每点下标/坐标/时间）、匹配半径 `radius`、隧道口外侧点 `portalA/B/FarA/FarB`、左行/右行 `leftHand`。**不参与**：点距、精确模式开关、勾选/落地状态、failFast、轨迹 id。
- **值**：`.draft(RouteDraft)`（carRoute/railRoute 的原始返回，不含输入说明与交叉验证标注——命中时重新拼）或 `.noRoute(RouteError)`（路网明确回答的确定性错误：没路 / 太远 / 铁路不像隧道 / 太长 / 拿不准 / 附近无铁路 / 连不通）。传输失败（`allEndpointsFailed` / `badResponse`）、429 冷却（`HostCooling`）、取消一律不缓存；非 failFast 下部分候选传输失败仍选出的草稿（`RouteDraft.partial`）与「没路但另有候选传输失败」（`RouteError.noRoute(_, partial: true)`）也不缓存——它们不是完整答案，下次照常重请求。精确模式的比对结果用两份草稿现算。
- 铁路键的 `economy`：批量的 `railRoute` 带 `OverpassCache`、包围盒 ≥6 km，单处 ≥1.5 km，结果可能不同，所以批量用 true、单处用 false 分开缓存。
- 单项重取：`BatchItem.cached` 记这一处是否整处命中（重取时从 `cacheHits` 扣回）；`BatchItem.refetchCount` 进主地图折线签名与预览列表缓存键（草稿点数/来源/外推都相同但坐标不同也要重画）；重取在途（`BatchState.refetchingCount > 0`）时三个「落地」按钮禁用、`landBatch` 拒绝，免得那一处被悄悄漏掉。
- **生命周期**：`load(urls:)` / `loadFwdb` / `clearTrack` 清空；`apply()`（落地 / 撤销 / 还原）、关批量窗口、取消批量、退出预览都不清。只在内存。
- **命中**：草稿说明首行「路网结果来自缓存（本文件打开以来取过）」；`BatchState.cacheHits` = 整处（所有腿）都命中的项数，第 2 步进度文字与第 3 步统计附「命中缓存 N 处」。命中的腿不参与引擎健康统计（没真问过服务器），限速器 / 冷却 / 停用规则照旧只看真实请求。
- **重取入口**（都走 `ignoreCache: true`，结果覆盖缓存）：批量第 2/3 步「重新获取全部…」（确认弹层：处数、公路/铁路、预计用时；等同忽略缓存重跑第 2 步，勾选与手选重置）→ `refetchBatchAll()`；第 3 步右键一行「重新获取这一处（忽略缓存）」（多选逐个）和紧凑卡片的 ↻ → `refetchBatchItem(id)`：只这一项回到「请求中」、旧草稿/两路/手选清掉，普通模式沿用它原来的引擎、精确模式两路都取，其它项不动；单处补点操作条「重新取（忽略缓存）」→ `refetchRouteDraft()`（有两份对照时两路都重取）。取路入口统一加了 `ignoreCache` 参数（`runBatch` / `routeBatchItem` / `requestRouteDraft` / `requestCrossCheckedDraft`），逻辑不复制。
- 钩子：`routecache stats`（`entries=N hits=M`）/ `routecache clear`；`batchrefetch all` / `batchrefetch <i>`；`routerefetch`；`state.batch.cacheHits`、`state.routeCache{entries,hits}`。假引擎（`fakeroute`）现在也按主机计 `requestsByHost`，用来证明命中时没再请求。
- 测试：`Tests/ui/run_route_cache_tests.py`（D0–D6，全离线）。

## 修改记录详细页：两路切换（2026-10-26，用户反馈：看不到 OSRM 和 Valhalla 各自的数据）

- 背景：精确模式两路几何常完全相同（最多相差 0 m），原来另一路画成蓝虚线被绿线盖住，看不出有两份。
- `TrackStore.reviewShownSource: RouteSource?`（nil = 采用的那份 / 第一份；`reviewSelect` 换处时复位）；`reviewShownDraft(_:preferred:)`、`reviewSameGeometry(_:)`（`cross.maxDev == 0` 或 锚点与坐标逐点相等）。
- 详细页依据行：`drafts.count >= 2` 时显示分段控件「OSRM | Valhalla」（采用的那份名字后带 ✓）；切换只改**显示**：地图上显示的那份粗实线（采用 = 绿、未采用 = 蓝），另一份细虚线（同色）；来源·方式·长度·贴路跟显示份；「说明…」弹出显示份的警告与说明；⚠ 计数也按显示份。几何相同时控件旁标「两路几何完全相同」。不改采用、不改勾选/落地；预览模式与已落地记录模式都适用。
- 钩子：`reviewdraft osrm|valhalla|next|default`；`reviewstate` 加 `shownDraft`（RouteSource rawValue）与 `sameGeometry`。

## 单处卡片（2026-10-27，用户反馈：批量窗口折叠后大片空白、「莫名其妙冒出来」）
- **入口**：批量窗口表格点一行 / 卡片 ‹ › / 「下一处要选的」 → `selectBatchItem` → `batchCompact = true`。主窗口候选列表原来只调 `selectGap`、不碰批量；现在**仅当批次存在、处于预览阶段且这处在批次中**时转成 `selectBatchItem`（选中 + 折叠），其它情况照旧只选断档。
- **大片空白的根因**：① 折叠中关掉批量窗口不清 `batchCompact`（只有 phase 变 nil/running 才清），重开时 SwiftUI 恢复大窗口框、折叠标志仍为 true、didSet 不再触发 → 大窗口中间一张卡片；② `dockBatchWindow` 的位置校正有 `width < 600` 守卫，窗口被撑大后不再校正；③ 折叠标志为 true 但没有选中项时窗口仍是完整表格（最小 820×680），缩小会被 SwiftUI 撑回去。
- **现在**：进入折叠时**无论窗口多大**都缩成宽 560、高按卡片内容（240…420）的卡片，停到主窗口顶部居中往下 40；0.15/0.4/0.9 s 再校正尺寸与位置。离开折叠（「展开列表」、批次重跑、关窗）放回进入前的框；关窗时先放回原框再退出折叠（SwiftUI 记住的是关窗时的框）。没有可显示的卡片（无选中项、非分类/预览阶段）时不缩。卡片内容 `frame(maxHeight: .infinity, alignment: .top)`，万一没缩成也贴顶。
- **有名字、有来由**：卡片顶部一行「单处卡片 · 点列表某一行后窗口折叠，方便看主地图」，右侧「展开列表」。
- 钩子：`batchcompact 0|1`（无选中项时先选第一处）、`closebatchwin`、`resizewin <标题> <宽> <高>`；`state.batch.windowSize` = `[宽, 高]`（整数，外框含标题栏，窗口没开为 null）、`state.batch.dock`（最近一次停靠诊断）。

## 修改记录「在主地图上看」（2026-10-27）
- 详细页顶部「回总览」左边（预览与已落地两种模式都有）。点一下：主窗口地图飞到这处修改 `TrackChange.bbox`（外扩 30%，最小宽度 max(800 m, spanMeters × 1.3)），与批量小卡片飞断档共用 `PointMapView.flyTo`（同一套外扩、按未遮挡区域长宽比补齐、避开批量窗口与主窗口浮层的 edgePadding）。
- 主窗口 `orderFront`（最小化则先还原），随后把修改记录窗口 `makeKey`：主窗口在上面可见，键盘焦点仍在修改记录窗口，‹ › / 方向键继续翻。只飞相机，不改主窗口的模式（补点 / 批量 / 筛选不动）；地球视角时切回平面。
- 实现：`TrackStore.reviewShowOnMainMap()` 写 `mapFocusRequest` 并递增 `mapFocusVersion`，地图协调器看到版本变化后执行 `focusMapRequest()`；新建协调器不重放旧请求。
- 钩子：`reviewgoto`（等价于点按钮）；`reviewstate` 多了 `mainMapCenter:[lat,lon]`、`mainMapSpanKm`（主地图当前 region；地球视角为 null）。
- 测试：`Tests/ui/run_batch_card_tests.py`（离线，自己起副本，约 2 分钟）。

## 卡片高度按内容算（2026-10-27 Opus）
- 原来卡片窗口高按 `contentView.fittingSize`（240…420）算，但折叠瞬间内容还是表格（≥680），落到默认 300，下方约 50 pt 空白。
- **现在**：`compactView` 末尾 `.fixedSize(vertical)` + `onGeometryChange` 把卡片自然高度写进 `TrackStore.batchCardContentHeight`；它的 didSet 在折叠中调 `applyBatchCard`，窗口高 = 内容高 + 标题栏（160…560），宽仍 560、左上角不动。内容变了（换一处、状态行变两行、出现「下一处要选的」等）跟着调；原因弹窗是 popover，不改卡片布局，不触发。
- 标题栏高度按 `win.frame.height − win.contentLayoutRect.height` 取：SwiftUI 的窗口是 fullSizeContentView，`frameRect(forContentRect:)` 不含标题栏（第一版按它算，底行被裁 28 pt）。
- 卡片根视图 `minHeight` 210 → 120，免得 SwiftUI 的最小尺寸把短卡片撑高。实测 Garmin_Roma_Da_copy：内容 207、窗口 560×239。
- 钩子：`state.batch.cardContentHeight`（整数，0 = 还没量到）。测试 `run_plausibility_tests.py` U2：窗口高 ∈ [内容高, 内容高 + 60]。

## 修改记录翻页时主地图跟随（2026-10-27 Opus）
- 详细页顶部「在主地图上看」左边加勾选框「主地图跟随」（偏好 `reviewFollowMap`，默认关，预览/已落地两种模式都有）。开着时 `reviewStep`（‹ › 按钮与 ← → 键）选中下一处后自动执行一次 `reviewShowOnMainMap()`；勾上那一下也飞一次当前这处。关着时维持点一次飞一次。
- 钩子：`reviewfollow 0|1`（回显当前值）；`reviewstate.followMap`。测试 `run_plausibility_tests.py` U3：开着翻页后主地图中心距该处 < 2 km；关着翻页中心不动。
