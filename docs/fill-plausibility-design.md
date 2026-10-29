# 补点「落地前自检」（FillPlausibility）与「合成断档考卷」（GapExam）设计

日期 2026-10-27 · 模型 claude-fable-5-1 · 任务文档 `Tests/tasks/api/2026-10-27_fill_plausibility_and_exam.md`。
前置阅读：`docs/cross-check-design.md`（精确模式、后处理伪影）、`Tests/reports/20261026_1500_tunnel_diagnosis.md`（上周 5 处补错点的根因，本文第 1 关的指标全部来自它的 §1–§3）。

## 0. 两道关各解决什么

| 关 | 问题 | 做法 | 联网 |
|---|---|---|---|
| 1 落地前自检 | 补点结果明显不对（跑到路外、绕路、换路、起始段被后处理推偏）时，程序自己要能发现，而不是靠人翻截图 | 每处补点算一组纯几何指标 → 0–100 的 `risk` 分 + 人话原因；high 默认不勾选落地 | 否 |
| 2 合成断档考卷 | 第 1 关的阈值要有「标准答案」才能调；以后改取路/后处理也要有回归 | 从完整轨迹里挖掉一段造成断档，补完和挖掉的真实点比；路网回复录一次、永远离线回放 | 只在「录制」一步 |

## 1. 第一关：FillPlausibility

### 1.1 输入（`FillPlausibility.Input`）

| 字段 | 含义 | 批量里从哪来 |
|---|---|---|
| `a`, `b` | 最终落地锚点（草稿外推后的） | `landingJob` 的 ia/ib |
| `points` | 将落地的合成点序列（不含锚点）；P = [a] + points + [b] | `FillPath.interpolate` / `StaleRetime.landingPoints` |
| `routeRaw` | 路网原始折线 R：**clip 的输出、trimEnds/taper 之前** | `RouteDraft.rawCoords`（新字段） |
| `routeMeters` | 路网长度 | `RouteDraft.meters` |
| `seconds` | 空洞时长（最终锚点） | tB − tA |
| `bearingA`, `bearingB` | A 侧行进方向（进入 A）、B 侧（离开 B） | `GapRouteInputs` heading |
| `refSpeedMps` | 前后真实车速中位（m/s） | 候选的单步/窗口速度中位 |
| `snapA`, `snapB` | 锚点到路网起终点距离 | `RouteDraft.snapA/B` |
| `residualA/B`, `taperA/B` | 残余偏移 / 实际 taper 用的 d | `RouteDraft` |
| `legs`, `roadBeforeA`, `roadAfterB` | 路线沿途道路编号/名称（含长度）；A 侧 / B 侧所在道路（上下文路由 A–B 之外那一步） | `RouteDraft.legs / roadBeforeA / roadAfterB`（新字段） |
| `crossMaxDev` | 精确模式两路最大偏差（nil = 没比） | `RouteCrossCheck.Result.maxDev` |
| `innerMaxOff` | 区间内被保留/改时的真实点到 P 的最大距离（nil = 没有） | keptInnerPoints / StaleRetime.plan |
| `tunnelShare` | 隧道占比（nil = 未知，不扣分） | 本期恒 nil（公路引擎不带 tunnel 属性） |
| `matchRadius` | 匹配半径（容差基准） | 采样画像 |
| `stepA`, `stepB` | 锚点外侧局部步长 | portal 样本 |

### 1.2 指标（`FillPlausibility.Metrics`，全部可离线算）

| 指标 | 定义 | 抓什么 |
|---|---|---|
| `devRouteMax` / `devRouteMedian` | P 每 5 m 取样到 R 的距离；在 taper 区（首/末 L = clamp(6d, 80, 400) m，d = taperA/B）内允许 d + 5 m，超出部分才计。**补点 < 4 个时**（`Thresholds.sparsePointsBelow`）P 用补点所沿的折线顶点（`Input.vertices` = 后处理后的 `RouteDraft.coords`，有改时计划时裁到第一个保留点）代替补点：点少时推开的峰值会落在两点之间采不到（2026-10-28，§8）。`devRouteAllowance` = 最远那一处扣掉的允许量，写进原因文案；`devSampledVertices` 记是否按顶点采样 | 后处理把几何弄坏（上周 trimEnds+taper 伪影 32 m） |
| `detourRatio` | routeMeters ÷ A–B 直线 | 绕路 |
| `impliedSpeedKmh` | routeMeters ÷ seconds × 3.6 | |
| `impliedSpeedRatio` | (routeMeters ÷ seconds) ÷ refSpeedMps；= 任务文档里的 `detourVsExpected`（同一公式，只保留一个名字） | 换路/绕路/端点接错导致长度与时长不相称 |
| `headingA` / `headingB` | R 起始 ≥20 m 弦方向与 bearingA 夹角；R 末段与 bearingB 夹角（度；没有方向 = nil） | 反向出发 / 吸到对向车道 |
| `roadRefChanges` | legs 相邻两步 ref 或 name 不同的次数（都为空的步跳过） | 沿途换路 |
| `roadMatchesContext` | 首步与 roadBeforeA、末步与 roadAfterB 一致（nil = 不知道） | 与两侧所在道路一致 |
| `snapA` / `snapB` | 原样 | 锚点接错路 |
| `taperExcessA/B` | taperA − residualA（>10 = 伪影信号，同 anchorWarning） | 起止段不是路网 |
| `crossMaxDev` | 原样 | 两路不一致程度 |
| `uTurnCount` | R 相邻两段（各 ≥10 m）方向翻转 >150° 的次数 | 折返 |
| `innerMaxOff` | 原样 | 保留的真实点离路线远 |
| `tunnelShare` | nil = 未知 | 本期不扣分 |

### 1.3 阈值与打分（`FillPlausibility.Thresholds.current`，可整体替换，考卷调参改这里）

每条规则按档位累加，总分封顶 100。表里的初值按诊断报告：Garmin 真实点离 OSM 线 0–7 m、分向车道中心线相距 11–30 m、伪影 16–32 m。

| 指标 | 档位 → 分 | 原因文案（例） |
|---|---|---|
| devRouteMax | ≤5 → 0；5–15 → 10；15–30 → 30；>30 → 60 | 补点离路网原始折线最远 32 m（应 ≤5 m）；在端部区时：补点离路网原始折线最远 14 m（已扣除端部允许的 12 m；应 ≤5 m） |
| devRouteMedian | ≤3 → 0；3–10 → 10；>10 → 25 | 补点离路网原始折线中位 12 m |
| taperExcess（max 两端） | ≤10 → 0；10–18 → 30；**>18 → 50**（2026-10-28 方案 B，原 >10 → 30；档位取 18 而非 20 的理由见 §8 末尾） | 起始段向 A 靠拢了 32 m，比 A 离路的 8 m 多出 24 m：起始几何可能不是路网 |
| detourRatio | ≤1.3 → 0；1.3–1.8 → 10；1.8–2.5 → 25；>2.5 → 50 | 路网长度是直线的 2.4 倍 |
| impliedSpeedRatio | 0.6–1.5 → 0；0.4–0.6 或 1.5–2.0 → 15；其它 → 40（refSpeed 缺失 → 不算） | 按时长算 240 km/h，是前后车速的 2.3 倍 |
| headingA / headingB | ≤30 → 0；30–60 → 10；60–120 → 25；>120 → 45（各一次） | 路线起始方向与 A 侧行进方向差 140° |
| roadRefChanges | 0 → 0；1 → 10；≥2 → 20 | 路线沿途道路从 A22 换到 SS12 |
| roadMatchesContext == false | 20 | 路线起点所在道路（SS12）与 A 侧所在道路（A22）不同 |
| snapA / snapB | ≤ max(1.5×半径, 20) → 0；≤60 → 10；≤150 → 25；>150 → 40（各一次） | 锚点 A 离路网 180 m |
| crossMaxDev（有才算） | ≤10 → 0；10–30 → 10；>30 → 25 | 两路最大相差 35 m |
| uTurnCount | 每次 25，封顶 50 | 路线上有 1 处折返 |
| innerMaxOff（有才算） | ≤ max(半径,10) → 0；≤30 → 10；>30 → 25 | 保留的真实点离路线最远 40 m |

等级：`low` < 20 ≤ `medium` ≤ 50 < `high`。high 门槛可被钩子 `riskthreshold <n>` 临时改（`FillPlausibility.highThresholdOverride`）。

### 1.4 数据结构与接线

```swift
struct RouteLeg: Equatable, Sendable { var ref: String; var name: String; var meters: Double }
struct RouteDraft {  // 新增
    var rawCoords: [CLLocationCoordinate2D] = []   // clip 输出（后处理前）；直接/约束候选 = 原始几何
    var legs: [RouteLeg] = []                       // 采用候选的 A–B 段道路序列
    var roadBeforeA: RouteLeg? = nil                // 上下文路由 A 之前那一步（直接/约束/匹配 = nil）
    var roadAfterB: RouteLeg? = nil
}
struct FillPlausibility: Equatable { var metrics: Metrics; var risk: Int; var level: Level; var reasons: [String] }
enum FillPlausibility.Level: String { case low, medium, high }   // rawValue 进钩子 JSON
struct BatchItem { var plausibility: FillPlausibility? }
struct BatchState { var highRiskCount: Int; var mediumRiskCount: Int }   // 只数 status.isDone 的
struct FillRouteInfo { var plausibility: FillPlausibility? }   // 单处
struct GapFill / TrackChange { var plausibility: FillPlausibility? }   // 落地后可回查
```

- OSRM 请求改 `steps=true`（/route 与 /match），Valhalla 解析 `maneuvers`；`OSRMAnswer` 多带 `steps`（沿几何的累计位置）与 `rawCoords`。上下文候选裁剪后按弧长比例把 steps 映射到 A–B 段。路网缓存键不变，缓存值随之多存。
- 批量：`applyBatchOutcome` 收到 `.draft` 后立刻 `assessBatchItem`（用 `landingJob(forPreview:)` 算出将落地的点）；high → `include = false` 并在 notes 加一句「合理性 risk 分 N：默认不勾选落地，看过地图后可手动勾上」；`.conflict` 也按 OSRM 份评估（只做展示）；`resolveBatchConflict` / `swapBatchCross` 后重评。
- 单处：`applyRouteDraft` 后评估写进 `fillRouteInfo.plausibility`；用户手改顶点后置 nil（已不是那条路线）。
- 记录：`landingJob` / `confirmApplyFill` 把它写进 `GapFill.plausibility`，`performFills` 与 `previewChange` 转进 `TrackChange.plausibility`。
- 批量窗口（本任务只做最小改动）：第 3 步表格加「风险」列：high → 「要看一眼」（红），medium → 「留意」（橙），low → 空；help 列原因；行顺序 high → medium → 其它（各自保持原时间序）。

### 1.5 钩子 / state JSON（给 DeepSeek 与 Opus）

- `state.batch.items[]` 加 `risk`（int，无评估 = null）、`riskLevel`（"low"/"medium"/"high"/null）、`riskReasons`（字符串数组）。
- `state.batch.counts` 加 `high`、`medium`。
- `state.route` 加 `risk`、`riskLevel`、`riskReasons`。
- `reviewstate.changes[]` 加 `risk`、`riskLevel`。
- 新钩子 `riskthreshold <n>|off`：临时改 high 门槛（分 > n 为 high），回显当前门槛。已有批次不重算；新评估生效。
- 新钩子 `replay <dir>|off`（可选，app 内回放录音；考卷主要在 synthrunner 里跑）。

## 2. 第二关：GapExam

### 2.1 题目格式 `Tests/exam/questions/<id>.json`

```json
{"id":"mr_tun_0001","kind":"synthetic","source":"data/compare/Muenchen_Roma_Garmin.gpx",
 "band":"20-60s","roadType":"tunnel|straight|curve|unknown",
 "anchorA":{"time":1761000000,"lat":46.5,"lon":11.4},"anchorB":{"time":1761000045,"lat":46.49,"lon":11.39},
 "seconds":45,"straightMeters":1230,"truthMeters":1260,
 "removed":[[lat,lon,ele,time],...],          // 挖掉的真实点 = 标准答案（synthetic）
 "truthPolyline":[[lat,lon],...], "truthWays":["30838319","30838322"],   // real 题：OSM 隧道 way 几何
 "notes":"..."}
```
- 锚点按**时间**定位（runner 里 `track.time == anchor.time`），不信任下标（落地/排序后下标会变）。
- synthetic：runner 把 (A, B) 之间的点全部去掉再跑完整流程；real：轨迹原样（断档本来就在）。
- 出题规则（`Tests/exam/make_questions.py`，离线、固定种子）：窗口两端 ±300 s 内没有 dt > 3 s 或步长 > 150 m 的步（连续路段）；窗口内车速中位 ≥ 40 km/h；seconds ≥ 20 时 A–B 直线 ≥ 150 m；窗口互不重叠且相隔 ≥ 120 s。路型：tunnel = 挖掉的点 ≥30% 在诊断附件 `all_osm_ways.json` 的 tunnel=yes way 25 m 内（只有 5 个包围盒有数据）；straight = 累计转向 ≤ 20°；curve = 其它；junction 没有 OSM 数据，本期标 unknown。分档 10–20 s / 20–60 s / 1–3 min / 3–8 min。
- real 题 5 处（诊断报告）：第 14（9732→9734）、16（12013→12015）、19（20893→20895）、33（21676→21678）、34（21730→21732），答案 = 报告确认的 way 几何按顺序拼接，判卷前裁到 A/B 投影之间。

### 2.2 录制与回放（`RouteReplay`，RoadNetwork.swift）

- 所有公路 HTTP（fetchOSRM / fetchMatch / fetchValhalla）经 `RoadNetwork.transport(host:request:failFast:)`：`RouteReplay.mode == .off` 时走原 RateLimiter；`.record(dir)` 真发请求并存盘；`.replay(dir)` 只读盘，**不出网**。
- 文件：`Tests/exam/recordings/<keyHash>.json`，keyHash = `RouteCacheKey` 全部字段的规范化字符串的 FNV-1a 64 位（进程间稳定；Swift 的 hashValue 每次运行不同所以不用它）。文件内按请求哈希（method + URL + body 的 FNV-1a）存每次 HTTP 的 `{url, body, status, response}`；一处断档一个引擎一个文件，里面 1–5 个请求。回放时还建一张全局 请求哈希 → 回复 的索引（扫全部文件），`GapRouteInputs` 的键字段以后变了也不至于全部变成「无录音」，只有请求本身变了才会。
- 找不到录音 → 抛 `RouteReplay.Missing`，runner 记该题 `noRecording`（不是失败）。
- 录制纪律：串行、任意两次请求 ≥ 1.0 s（两个域名同一台机器，按全局算）、User-Agent `GPXPointViewer-exam/1.0`、429/5xx 停 60 s 再重试一次、总请求 ≤ 700（超出即停止，剩下的题无录音；中断可续：已有录音的题跳过）。
- 回放/录制里 `TrafficSide.leftHand` 不查地理编码（那也是联网），用 `leftHandByBox`（欧洲 = 靠右，与 app 里查出来的一致）。
- 入口：`synthrunner --exam-record Tests/exam [--max-requests N]`（联网）、`synthrunner --exam Tests/exam`（离线）。

### 2.3 判卷

对每题、每个引擎（OSRM、Valhalla，经济模式 = 批量同一口径），跑：载入 → 检测候选（记 `detected`）→ `GapRouteInputs.build` → `carRoute`（回放）→ 落地点（`StaleRetime` + `FillPath.interpolate`，点距 = 两侧局部步长中位、夹 5–100）→ 与答案比：
- `pMaxToTruth` / `pMedianToTruth`：补点折线采样（5 m）到答案折线的最大/中位距离；
- `truthMaxToP`：答案点到补点折线的最大距离；
- `within20m`：补点采样中 ≤ 20 m 的比例；`lengthRatio`：补点长度 ÷ 答案长度。
- **通过** ⇔ max(pMaxToTruth, truthMaxToP) ≤ 20 m 且 within20m ≥ 0.95（`ExamThresholds`，可调）。
- 同时记第 1 关的 risk / level，汇总混淆矩阵：真实错误（未通过） × risk high。命中率 = high ∧ 未通过 ÷ 未通过；误报率 = high ∧ 通过 ÷ 通过。目标：命中 ≥ 90%、误报 ≤ 10%。
- 两路比对（`RouteCrossCheck.compare`）也记 `agree`，统计「一致却答错」的题数（交叉验证抓不到的那类）。
- 输出：每题一行 JSON + 末尾 `exam summary: …`；`Tests/exam/results/<yyyyMMdd_HHmm>.json`；`Tests/exam/run_exam.sh` 包一层；`run_all.sh` 末尾追加（离线，几秒）。

## 3. 给 Opus 的界面接线清单（**已做**，2026-10-27 Opus）

### 3.0 落地情况（控件位置）

| 项 | 控件 | 代码位置 |
|---|---|---|
| 徽标 | `RiskBadge`（high「要看一眼」红、medium「留意」琥珀色 `RiskBadge.mediumColor`，和「疑点」列的系统橙区分；low 不显示）。可点，popover = `RiskReasonsView`：每条原因前 ⚠︎，底行「风险 N / 100 · 等级」。批量表格、紧凑卡片、补点操作条三处共用 | `BatchFillWindow.swift` 文件末尾 |
| 批量筛选 | 第 2/3 步质量条末尾「只看要看一眼的 N 处」（medium + high；与「只看有疑点的」「只看要你选的」互斥；N = 0 时不出现）。三个开关从视图 `@State` 挪进 `TrackStore.batchWarnedOnly / batchConflictOnly / batchRiskOnly`，表格行由 `store.batchVisibleRows(st)` 给出（过滤 + 风险排序，过滤为空回全表） | `BatchFillWindow.qualityBar`、`TrackStore.batchVisibleRows` |
| 第 3 步汇总 | 标题行右侧 `previewSummary` 多一段「要看一眼 N · 留意 M」（两者都 0 时不出现） | `BatchFillWindow.previewSummary` |
| 紧凑卡片 | 状态行（来源 · 距离 · 点数 · 依据）后面同一枚徽标 | `BatchFillWindow.compactView` |
| 单处操作条 | 补点底栏 `routeStatusLabel` 状态文字后；`fillRouteInfo.edited == true` 不显示 | `ContentView.routeStatusLabel` |
| 修改记录详细页 | 依据行下面 `plausibilityRow`：盾牌图标 +「落地前自检：风险 N（等级）」（low 灰色）+ 前 3 条原因；多于 3 条时右侧「说明…」弹出全部 | `ChangeReviewWindow.plausibilityRow` |
| 钩子 | `batchriskonly 0|1`（回显 `visible=N`）；`state.batch` 多 `riskOnly / warnedOnly / conflictOnly / visibleCount`；`reviewstate.changes[]` 用 `riskJSON`，多了 `riskReasons`；`riskpopover 1|0`（打开/关上卡片或操作条上的徽标弹窗，截图用） | `UITestHook.swift` |

数据层已全部暴露，界面只需读：
1. `BatchItem.plausibility?.risk / .level / .reasons / .metrics`；`BatchState.highRiskCount / mediumRiskCount`。
2. 批量窗口：风险列已有最小版（文字徽标 + help）。待做：筛选「只看要看一眼的」（与现有 `warnedOnly`/`conflictOnly` 同一机制）、原因弹窗（popover 列 `reasons`，每条前加 ⚠︎）、第 3 步汇总行加「要看一眼 N · 留意 M」、紧凑卡片同步。
3. 补点操作条（单处）：`store.fillRouteInfo?.plausibility`，建议在状态行后加徽标；`edited == true` 时 plausibility 为 nil（手改过就不再打分）。
4. 修改记录详细页：`TrackChange.plausibility`，文案建议「落地前自检：风险 N（等级）」+ 原因列表；落地前预览（`previewChange`）同字段。
5. 文案禁词：待审核/报警/冲突/已验证/失锁。徽标文字已定「要看一眼」「留意」。
6. 颜色建议：high 红、medium 橙、low 不显示；与「疑点」列的 orange 区分开。

## 4. 给 DeepSeek 的可测项清单

全部离线（`fakeroute all ok` / `offset`），新起测试副本：
1. `fakeroute all ok` → `batchplan`/`batchrun` → `state.batch.items[*].riskLevel == "low"`，`risk ≤ 19`，`riskReasons == []`，`counts.high == 0`。
2. `fakeroute valhalla offset 30`（普通模式两路分活，Valhalla 做的项）→ 该项 `risk ≥ 20`、`riskReasons` 非空；精确模式下两路 offset 不同 → disagree（原有行为不变）。
3. `riskthreshold 5` 后重跑 → 所有 risk > 5 的项 `riskLevel == "high"` 且 `include == false`；`riskthreshold off` 恢复 50。
4. `state.route`（单处 `route car` 后）含 `risk/riskLevel/riskReasons`；`reviewstate.changes[].risk` 落地后非 null。
5. 字段齐全性：items 每项三个键都在（无评估为 null）。
6. 批量窗口截图：high 行在前、徽标文字「要看一眼」。
7. 离线：`Tests/synth/runner/synthrunner --exam Tests/exam` 退出码 0，末行 `exam summary:`；`run_all.sh` 末尾有同一行。

## 5. 当前成绩（2026-10-27 录制；`Tests/exam/results/20261027_2324.json`，基线 `Tests/exam/baseline.json`）

录制：255 次请求（OSRM 130、Valhalla 125；每题每引擎 1–2 次，经济模式上下文候选够干净就停），0 次 429/5xx，约 7 分钟。

| | OSRM | Valhalla |
|---|---|---|
| 判卷 | 121/125 通过 | 121/125 通过 |
| 按档 | 10–20 s 15/15 · 20–60 s 41/42 · 1–3 min 39/41 · 3–8 min 25/26 · real 5/5 | 同 |
| 两路一致 | 125/125（一致却答错 4） | |
| 落地前自检 | 通过题：121 low、0 medium、0 high；未通过题：2 low（risk 10）、2 medium（20、30）、0 high | 同 |
| 混淆矩阵（high 为阳性） | fail∧high 0 · fail∧¬high 4 · pass∧high 0 · pass∧¬high 121 → 命中 0%、误报 0% | 同 |
| 扰动题（已知错误类，见下） | 伪影 ~~109/125~~ **123/125**（2026-10-28 方案 B 起；`Tests/exam/results/20261028_1332.json`）判 high、平行路 125/125 判 high | 同 |

4 道未通过题（`rd_1-3min_0093`、`rd_20-60s_0091`、`rd_3-8min_0092` 都在 RA 3；`rd_1-3min_0120` 在 A 5→B 31a 出口）：路线在正确的路上、两路一致、绕路比 1.02–1.13、方向对，只是补点与真实 GPS 点最大差 25–48 m（90%、80%、68%、78% 在 20 m 内）——匝道 / 分向车道处 OSM 中心线与这台 Garmin 的轨迹系统性差 10–20 m（锚点离路 10–19 m，通过题中位 2.5 m、p90 7 m）。这类「数据层面的偏差」从补点自身的几何看不出来；按它加了一条轻度规则（锚点离路 >10 m 扣 10，原因写明「补点沿路网走，会和真实轨迹差这么多」），4 题里 2 题升到 medium。**在这份考卷上第一关没有 high 可打**：修过 trimEnds/taper 之后，这两条路线上没有一处补错到「跑到路外 / 换路 / 绕路」的程度；5 道 real 隧道题（含上周的 14/16/19/33/34 处）全部通过。

**扰动题**（`exam.swift`，在每题录音上人为造出上周那两类错误，用来给命中率一个口径）：
- 伪影 = 起始 150 m 内补点横向推开 32 m 再线性回到路上、taperA 记 32（第 14 处原样；2026-10-28 起补点所沿的折线顶点也按同一公式推开）：2026-10-27 时 109/125 判 high，其余 16 判 medium（原因见 §8）；**2026-10-28 方案 B 后 123/125**，剩 2 题（mr_1-3min_0071、rd_10-20s_0095：锚点本来就离路 18–19 m、excess 只有 13–15）留在 medium（risk 40）；
- 平行路 = 整条补点平移 25 m、路网原始折线不变（吸到对向车道/集散车道）：125/125 判 high。

阈值调整记录（相对 §1.3 初值）：
1. 端部允许量改为 `min(taper, residual)`（taper 触发）/ `snap`（没触发，A→首顶点一段）线性递减 + max(5, 10%)；原来按 `taper + 5` 放过了伪影（扰动题 2/125 → 109/125）。
2. 新增 `snapMild`：锚点离路 >10 m（且在漂移容差内）扣 10。
3. `roadRefChanges` 只比相邻**有名字**的步（匝道常无名，夹在中间不算换路）。
4. （2026-10-28）`taperExcess` 加一档：≤10 → 0、10–18 → 30、>18 → 50（§8 方案 B；扰动题伪影 109 → 123/125）；补点 < 4 个时 devRoute 按折线顶点采样（§8）。基础题 125 题的 risk 分布与改前逐字相同（0 ×112、10 ×10、15、20、30 各 1），误报仍 0。
其余初值未动。设计目标「真实错误 ≥90% 命中、好结果误报 ≤10%」在本考卷上只能用扰动题验证（伪影 ~~87%~~ **98%**、平行 100%、误报 0%）；真实错误样本需要以后从用户报告的问题里补进 real 题。

## 6. 已知局限

- 录音只覆盖录制当天的 OSM 数据与两个 FOSSGIS 实例的行为；OSM 改了路、服务换了版本，录音仍是旧答案（这正是回归测试要的，但不能拿它当「现在的服务会怎么答」）。
- 考卷来自一个用户的两条 Garmin 路线（慕尼黑—罗马、罗马—达…），路型只有高速/国道/城市驾车；手机数据（一生足迹）本期没出题。
- tunnel 路型只能在诊断的 5 个包围盒里判；junction 没有 OSM 数据，标 unknown。
- synthetic 题的「答案」是 GPS 真实点，本身有 3–7 m 噪声；20 m 通过线已把它算进去。
- ~~`tunnelShare` 本期恒为未知~~（2026-10-28 起 OSRM 有值，见 §7）；`roadRefChanges` 依赖 OSRM/Valhalla 给的 ref/name，国道编号常空。
- 第 1 关是规则打分，不是概率；阈值只按本考卷调过一次。

## 7. tunnelShare（2026-10-28，loose-ends 任务）

- **来源**：OSRM 请求本来就带 `steps=true`，回复里 `steps[].intersections[]` 自带 `classes`（car 配置的类别 toll/motorway/ferry/restricted/tunnel；类别不同的边不会被压缩，所以隧道口一定有路口记录）。**请求 URL 没改**（改了考卷录音的请求哈希就全对不上）。
- **解析**：`RoadNetwork.parseOSRMTunnelSpans(legs)`——所有 intersections 按顺序排开，`classes` 含 `"tunnel"` 的路口到下一个路口算一段隧道；回复里**完全没有 intersections 字段**（旧录音 / 服务没给）→ `nil`（未知）；有但没有隧道 → `[]`。`/route`（直接、约束、上下文）与 `/match`（那一腿）都解析。
- **占比**：`RoadNetwork.tunnelShare(spans:along:)`——每段两端投影到草稿的路网原始折线 `rawCoords`（A–B 段，clip 输出）取弧长区间，端点都离折线 >60 m 的段丢掉（上下文路由 A′ 之前 / B′ 之后的隧道），合并重叠后 ÷ 折线长度，钳 0…1。在 `carRoute.finish` 里写进 `RouteDraft.tunnelShare`。Valhalla / 铁路 / 删点 = nil。路网缓存存的是整份 RouteDraft，字段随之缓存。
- **用法**（`FillPlausibility.assess` §5 锚点贴路）：`tunnelShare ≥ 0.5`（新常数 `Thresholds.tunnelShareWaive`）**且**补点离路网原始折线最远 ≤ devRouteMax 第一档上限（5 m）时，离路 ≤ 60 m（新常数 `tunnelSnapWaiveMax`）的锚点不扣「锚点 A/B 离路网」与轻度那条——隧道口 GPS 漂移让锚点看着在路外，补点本身在路网上；`Metrics.tunnelWaived` 记是否免过。tunnelShare 为 nil 时与之前逐字相同。**其它阈值一个没动**。
- **考卷不变**：250 份录音里 125 份（OSRM）有 intersections、0 份有 `classes` → 全部 tunnelShare = 0，不触发免扣；`run_all.sh` 末行与改前逐字相同（osrm/valhalla pass 121/125、perturb artefact 109/125 parallel 125/125），对 baseline 无回归。
- **自测**：`synthrunner --tunnel-selftest`（5 例）：自己构造的 OSRM 回复（45.000/45.003[tunnel]/45.006 三个路口）→ 1 段、占比 0.30；A–B 只取后半段 → 0.20；无 intersections → nil；有 intersections 无 classes → 0；免扣：snapA 15 m（轻度扣 10）在 tunnelShare nil / 0.3 时 risk 10、0.8 时 0。
- **局限**：没有在线核对 FOSSGIS 实例的 car 配置真的输出 `tunnel` 类别（本任务不联网）；考卷录音里一个 `classes` 都没有（连 motorway 都没有），可能是录制时回复就不带——若如此，线上 tunnelShare 也会是 0 而不是 nil，免扣永远不触发，但也不会多扣分。下次在线跑 `run_crosscheck_online.py` 时顺便看一眼 `routedump` 里有没有 classes。

## 8. 扰动题「伪影」16/125 只到 medium 的原因（2026-10-28 分析；**同日下午按方案 B 改了阈值，结论见本节末尾**）

数据：`synthrunner --exam Tests/exam` → `Tests/exam/results/20261028_1215.json`（exam.swift 新增每题 `perturbArtefactDetail`：risk、L、点数、P 长度、devRouteMax/Median、taperExcessA、headingA、reasons；汇总行不变）。OSRM 与 Valhalla 是同一批 16 题（两路草稿几乎相同）。

| 题 | 档 | 点数 | snapA(=residual) | devRouteMax | taperExcessA | risk | 构成 |
|---|---|---|---|---|---|---|---|
| mr_1-3min_0071 | 1-3min | 153 | 18 | 1.5 | 14.5 | 40 | taper30 + 轻度贴路10 |
| rd_10-20s_0095 | 10-20s | 13 | 19 | 3.7 | 13.0 | 40 | taper30 + 轻度贴路10 |
| mr_10-20s_0018 | 10-20s | 5 | 2 | 12.2 | 29.5 | 40 | taper30 + dev10（只有 5 点，首点离 A 35 m，峰值采不到） |
| mr_10-20s_0030 | 10-20s | 6 | 7 | 12.6 | 25.1 | 40 | taper30 + dev10（同上） |
| mr_20-60s_0025 | 20-60s | 32 | 9 | 12.9 | 23.3 | 40 | taper30 + dev10 |
| mr_20-60s_0033 | 20-60s | 28 | 7 | 14.8 | 24.8 | 40 | taper30 + dev10 |
| rd_1-3min_0082 | 1-3min | 65 | 8 | 13.5 | 23.8 | 40 | taper30 + dev10 |
| rd_1-3min_0108 | 1-3min | 80 | 9 | 13.1 | 23.5 | 40 | taper30 + dev10 |
| rd_20-60s_0077 | 20-60s | 41 | 7 | 14.3 | 24.9 | 40 | taper30 + dev10 |
| rd_20-60s_0104 | 20-60s | 36 | 7 | 14.8 | 24.7 | 40 | taper30 + dev10 |
| rd_3-8min_0106 | 3-8min | 235 | 9 | 12.5 | 23.1 | 40 | taper30 + dev10 |
| real_16_trento | 20-60s | 34 | 10 | 10.1 | 22.1 | 40 | taper30 + dev10 |
| real_33_santalucia | 3-8min | 269 | 7 | 14.8 | 24.9 | 40 | taper30 + dev10 |
| rd_1-3min_0107 | 1-3min | 111 | 11 | 9.6 | 21.4 | 50 | taper30 + dev10 + 轻度贴路10 |
| rd_20-60s_0083 | 20-60s | 29 | 10 | 9.9 | 21.6 | 50 | taper30 + dev10 + 轻度贴路10 |
| rd_3-8min_0096 | 3-8min | 197 | 11 | 9.1 | 20.5 | 50 | taper30 + dev10 + 轻度贴路10 |

**机理**：扰动把起始 L = min(150, 45%·P) 内的补点横推 32 m、`taperA = 32`。评估时 taper 触发 → 端部允许量 = `min(taper, residual)·(1 − s/zone) + max(5, 10%)`，即**锚点离路越多，允许量越大**：residual 7–11 m 的题允许量 12–16 m，把 32 m 的推开吃掉一半，devRouteMax 落在 5–15 m 档（只扣 10）而不是 15–30 档（扣 30）；residual 18–19 m 的两题几乎全吃掉（dev 1.5/3.7 → 0 分）。taperExcess（32 − residual = 13–30）恒 >10，固定扣 30。于是 risk = 30 + 10 (+10) = 40/50，而 high 是 `> 50`。被判 high 的 109 题里 106 题 residual ≤ 7 m（允许量小，dev 落 15–30 档扣 30），另 3 题（residual 9.3 / 9.6 / 14.4 m）靠其它扣分项过线；high 题 risk 55–60（中位 60）。另有 2 题（0018/0030）只有 5–6 个补点、首点离 A 约 35 m，推开的峰值根本不在 P 上。

**阈值建议（供下一个调参任务决定，本任务不改）**——在本考卷上模拟（基础题 risk 分布：0 ×112、10 ×10、15、20、30 各 1；基础题 taperExcess >10 的 0 道）：
| 方案 | 扰动伪影 high | 基础题误报 |
|---|---|---|
| A. `highFrom` 50 → 39（risk ≥ 40 即 high） | 125/125 | 0（基础题最高 30），但离 30 只差一档，余量小 |
| B. `taperExcess` 加一档：≤10 → 0、≤20 → 30、>20 → 50 | 123/125（剩 0071、0095：excess 13–15） | 0 |
| C. 组合项：taperExcess > 10 **且** devRouteMax > 5 再加 15 | 123/125（剩 0071、0095：dev < 5） | 0 |
推荐 **B**：只动伪影信号本身，不碰全局等级边界；0071/0095 这种「锚点本来就离路 18 m、补点仍贴路网」的情形本来就更像隧道口漂移而不是伪影，留 medium 合理。另外可以考虑把端部允许量的 `min(taper, residual)` 在 `taper − residual > 10`（已判伪影）时改用 `min(taper, residual) / 2`，让 devRouteMax 也能看见推开——但这会影响所有真实草稿的 dev 计算，需要在考卷上单独验证。

**结论（2026-10-28 下午，plausibility-threshold-b 任务，已落地）**：按方案 B 实现，只把重扣档的上限从 20 调到 18，没有换别的变体——「按锚点离路距离分档」之类的变体都要碰端部允许量或 devRoute 的口径，影响所有真实草稿；B 只动伪影信号自己的阶梯，而且基础题 excess 全部 ≤ 0、真实数据（慕尼黑—罗马 50 处）excess ≤ 10，离 10/18 两个档位余量都大。改动：
- `Thresholds.taperExcess`：`[(10, 0)] over 30` → `[(10, 0), (18, 30)] over 50`。单项 50 正好到 medium 上沿，再加任何一项（dev 10 / 轻度贴路 10）就过 high 线；§8 表里 14 题 excess 20.5–29.5 → risk 60–70 → high；0071/0095（excess 13–15）仍 40 → medium。**为什么是 18 不是 20**：上周 5 处真伪影的原型（第 14 处）是 taper 32 对 snap 12，excess 正好 20；按「>20」它落在 30 分档，devRouteMax 又被允许量 12 吃到 ≈15（扣 10），risk 40 = medium，等于没改。18 与 20 在考卷和真实数据上结果完全一样（excess 在 (18, 20] 的扰动题没有；基础题 ≤ 0），只是把原型稳稳放进重扣档。`synthrunner --plausibility-selftest` 的 `archetype_taper32_snap12_is_high` 用例就是这个原型（补点每 55 m 一个、起始 150 m 内推开 32·(1−s/L)）。
- 0018/0030「补点太少采不到峰值」：方案 B 本身已把它们升到 60（excess 29.5 / 25.1 → 50 + dev 10）。另加一条通用规则：补点 < 4 个（`Thresholds.sparsePointsBelow`）时 P 用补点所沿的折线顶点（新字段 `Input.vertices`；`input()` 默认 = `RouteDraft.coords`，`retarget()` 按 StaleRetime 同一规则裁到第一个保留点）代替补点采样 devRoute。考卷里最少的题也有 5 个补点，这条对考卷无影响；由 `synthrunner --plausibility-selftest` 覆盖（3 个补点 + 顶点鼓出 30 m → dev 29.9 扣 30；5 个补点照旧按补点 → 0）。
- 文案：dev 原因在端部区写出扣掉的允许量（「补点离路网原始折线最远 14 m（已扣除端部允许的 12 m；应 ≤5 m）」）；taper 原因改为「起始段向 A 靠拢了 32 m，比 A 离路的 8 m 多出 24 m：起始几何可能不是路网」（差值就是阶梯用的 excess）。
- 考卷：`Tests/exam/results/20261028_1332.json`——osrm/valhalla pass 121/125 不变、perturb artefact **123/125**、parallel 125/125、high∧pass 0；基础题 risk 分布逐字不变；`baseline.json` 的通过/未通过与结果一致，内容无需改。扰动题的伪影 risk 分布：80 ×101、60 ×11、90 ×5、70 ×4、75、100 各 1、40 ×2。
- 边界备注：考卷的 `real_14_tusch` 是在录音的草稿上造扰动（residual 1、excess 31，risk 60），不是上周那个 snap 12 的原型；原型由自测覆盖（见上）。若以后真实伪影样本多落在 excess 12–18，再考虑把 30 分档也往下挪。
