# API 任务：补点「落地前自检」（合理性打分）+「合成断档考卷」（有标准答案的回归测试）

记录日期 2026-10-27。模型：claude-fable-5-1（设计 + 核心实现）。权限：`--write`。预算 ≤ $40。**不安装到 /Applications；一次只跑一个 xcodebuild 和一个测试副本；联网只在「录制考卷」这一步、按 §4 的纪律做。** 用中文写设计文档、output.md 与进度。
后面还有一个 Opus 任务接着做界面（风险列、排序、筛选、详细页文案）和一个 DeepSeek 任务跑机械测试，所以本任务的产出要让它们能直接接上：**数据结构、钩子字段、文档都要写清**。

## 0. 项目与背景

GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX/CSV 轨迹查看器（仓库根目录就是当前目录）。「断档补点」：轨迹时间空洞两端锚点 A/B 向 OSRM / Valhalla（都用 OpenStreetMap 数据）取道路几何，裁剪、贴路、渐进靠拢后按原始点距插点；精确模式两路同取并比对。关键代码：`GPXPointViewer/GapFill.swift`（候选检测、采样画像、GapRouteInputs、FillPath.interpolate、GapSplice）、`GPXPointViewer/RoadNetwork.swift`（取路 carRoute、候选比较、clip/trimEnds/taper、RouteCrossCheck、`routeOverride` 假引擎 :390、OSRM 请求 :456、匹配请求 :515）、`GPXPointViewer/BatchFill.swift`（BatchItem/BatchState、RouteCache/RouteCacheKey :245）、`GPXPointViewer/TrackStore.swift`（requestRouteDraft / requestCrossCheckedDraft / runBatch / routeBatchItem / landBatch / landingJob）、`GPXPointViewer/UITestHook.swift`（钩子 + state JSON）。离线合成回归：`Tests/synth/runner/main.swift`（命令行 runner，能 `GPXParser.parse` 真实 GPX；已有 `--crosscheck-selftest` `--portal-selftest` `--ratelimit-selftest`），`Tests/synth/runner/run_all.sh`（114 文件）。
设计文档：`docs/cross-check-design.md`、`docs/batch-review-design.md`；**必读**：`Tests/reports/20261026_1500_tunnel_diagnosis.md`（上周 5 处补错点的根因诊断，§1–§3 的量化方法就是本任务特征的来源）。测试与钩子说明：`Tests/README.md` §2–§3。

**为什么做**：用户多次看到补点结果明显不对（跑到路外、绕路、换路、短断档没补）。根因已修，但用户要的是**以后再出同类问题时程序自己能发现**，而不是靠人眼翻 50 处截图。两道关：
1. **落地前自检**：每处补点算出一组可量化的「合理性指标」，合成 0–100 的风险分并附原因；高风险的在批量窗口里标出来、排前面、默认不勾选落地。纯几何/规则，不用模型。
2. **合成断档考卷**：从用户自己的**完整**轨迹里挖掉一段造出「已知答案」的断档，让补点流程去补，再和挖掉的真实点比，自动打分。考卷录制一次路网回复后**永远离线回放**，成为回归测试；同时用考卷评估第 1 关的命中率与误报率。

## 1. 第一关：落地前自检（FillPlausibility）

### 1.1 指标（每处一组，全部可离线算；名字可改，含义不能少）
以最终将落地的补点序列 P（含锚点）、路网原始折线 R（裁剪后、后处理前，即 clip 的输出）、两端上下文真实点为输入：
- `devRouteMax` / `devRouteMedian`：P 到 R 的最大/中位距离（米）。抓「后处理把几何弄坏」（上周 trimEnds/taper 伪影 32 m）。
- `detourRatio`：路网长度 ÷ A–B 直线距离；再给一个 `detourVsExpected`：路网长度 ÷（空洞时长 × 前后真实车速中位）。
- `headingA` / `headingB`：路线起始方向与 A 侧轨迹行进方向的夹角；路线末段方向与 B 侧的夹角（度）。
- `impliedSpeedRatio`：路网长度 ÷ 空洞时长，再除以前后真实车速中位。
- `roadRefChanges`：路线沿途道路编号/名称变化次数，以及是否与 A、B 两侧所在道路一致。需要在取路时把 OSRM 的 `steps=true`（每步 `ref`/`name`）或 Valhalla 的 maneuvers 带回来并存进 `RouteDraft`（新字段，例如 `legs: [(ref, name, meters)]`）；缓存键不变，缓存值随之多存。
- `snapA` / `snapB`：锚点到路网起终点距离（已有）。
- `crossMaxDev`：两路比对的最大偏差（已有，精确模式才有）。
- `tunnelShare`（有就用：Valhalla/OSM 的 tunnel 属性；没有就标「未知」，不扣分）。
- `uTurnCount`：路线上相邻段方向翻转 > 150° 的次数。
- `innerPointsOffRoute`：区间内被保留/改时的真实点到路线的距离最大值。

### 1.2 打分
`risk ∈ 0…100`，由各指标按阈值分档累加（阈值集中在一个结构里，带注释说明来源，例如 devRouteMax：≤5 m 0 分、5–15 m 10 分、15–30 m 30 分、>30 m 60 分）；每条扣分都生成一行**用户能看懂的原因**（例：「补点离路网原始折线最远 32 m（应 ≤5 m）」「路线沿途道路从 A22 换到 SS12」「路网长度是直线的 2.4 倍」）。
等级：`low`（<20）/ `medium`（20–50）/ `high`（>50）。**high 的默认不勾选落地**，并在 notes 里说明。阈值不要求一次调准：第二关的考卷会给出命中率/误报率，按考卷调到「真实错误 ≥90% 命中、好结果误报 ≤10%」。

### 1.3 接线（数据层由本任务做；视觉层留给 Opus）
- 新文件 `GPXPointViewer/FillPlausibility.swift`：`struct FillPlausibility { metrics…, risk: Int, level, reasons: [String] }` + `static func assess(...)` 纯函数（离线 runner 也要能编，只依赖 Foundation/CoreLocation）。
- `RouteDraft` 加 `legs`（道路编号序列）；`BatchItem` 加 `plausibility: FillPlausibility?`；单处补点（`fillRoute…` 状态）与 `GapFill`/`TrackChange` 记录也带上（落地后可回查）。
- 批量：`routeBatchItem` 出结果后立即评估；high → `include = false`（用户可手动勾回）；`BatchState` 加 `highRiskCount / mediumRiskCount`。
- 钩子/state JSON：items 加 `risk, riskLevel, riskReasons[]`，`batch.counts` 加 `high/medium`；根 `route` 加同样字段；`reviewstate.changes[]` 加 `risk/riskLevel`。新钩子 `riskthreshold <n>`（临时改 high 门槛，测试用）。
- 批量窗口只做最小改动：行上一个风险徽标（文字「要看一眼」/「留意」，颜色区分）+ 排序默认把 high 排前面；其余界面（筛选「只看要看一眼的」、原因弹窗、详细页文案）**留给 Opus**，但把需要的数据都暴露好。

## 2. 第二关：合成断档考卷（GapExam）

### 2.1 出题
- 来源：用户完整轨迹 `data/compare/Muenchen_Roma_Garmin.gpx`（33,496 点，1 s/28 m）、`data/Garmin_Roma_Da_copy.gpx`（46,267 点）；可选手机数据 `data/2026.01.01-2026.12.31.csv`（一生足迹导出，采样稀疏）。
- 题目 = 在**没有断档**的连续路段里挖掉一段：按时长分档（10–20 s、20–60 s、1–3 min、3–8 min），按路型分（高速隧道段优先：Overpass 的 tunnel way 可用 `Tests/reports/20261026_1500_tunnel_diagnosis.md` 附件目录 `~/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/20261026_143424_tunnel-diagnosis-2/work/all_osm_ways.json` 里 5 个包围盒的 way 几何做判定；其它按直路/弯路/出入口附近分）。每题存：源文件、挖掉的下标区间、挖掉的真实点（标准答案）、题目元数据。
- 规模：第一版 **≤ 150 题**（联网录制成本所限），分布写进 output.md。额外把上周确认过的 5 处真实问题（第 14/16/19/33/34 处，锚点下标见诊断报告）作为「真实题」收进考卷（答案 = 诊断报告确认的 OSM 隧道 way 几何）。
- 存放：`Tests/exam/questions/*.json`（小文件，入库）。

### 2.2 录制路网回复（唯一联网步骤）
- 对每题按 app 现有流程发请求（用 `GapRouteInputs` 同一套输入，两个引擎都录），把**原始 HTTP 回复**（OSRM/Valhalla JSON）按 `RouteCacheKey` 的内容哈希存到 `Tests/exam/recordings/<hash>.json`。
- 纪律：`routing.openstreetmap.de` 与 `valhalla1.openstreetmap.de` 是同一台机器，**串行、每秒 ≤ 1 次、User-Agent `GPXPointViewer-exam/1.0`**，收到 429/5xx 立刻停 60 s 再继续，总请求 ≤ 700。录制前确认没有别的客户端在用（`Tools/agents/status.sh`）。录制用一个命令行入口（`synthrunner --exam-record Tests/exam`），中断可续（已有录音的题跳过）。
- 回放：`routeOverride`/新的 `replay` 引擎按同一哈希读录音，**不出网**；找不到录音 = 该题「无录音」而不是失败。

### 2.3 判卷
- 对每题跑完整补点流程（候选检测 → 取路（回放） → 后处理 → 插点），得到补点序列；与标准答案比：补点到答案折线的最大/中位距离，答案点到补点折线的最大距离（双向），`within20m` 比例，长度比。**通过**：双向最大距离 ≤ 20 m 且 within20m ≥ 95%（阈值写进文档，可调）。
- 同时记录第一关对该题的 risk：汇总成混淆矩阵（真实错误 vs risk≥high）、命中率、误报率，并给出按考卷调整后的阈值建议（或直接调好）。
- 入口：`synthrunner --exam Tests/exam`（离线），输出每题一行 + 汇总；`Tests/exam/run_exam.sh` 包一层；结果 JSON 存 `Tests/exam/results/<时间>.json`。加进 `Tests/synth/runner/run_all.sh` 的末尾（离线、几秒）。

## 3. 文档
- `docs/fill-plausibility-design.md`：指标定义与阈值表、打分规则、数据结构、钩子字段、考卷格式、录制/回放流程、判卷标准、当前考卷成绩与混淆矩阵、已知局限（录音只覆盖当时的 OSM 数据；考卷来自一个用户的几条路线）。**先写设计再写代码**，设计里要有一节「给 Opus 的界面接线清单」和一节「给 DeepSeek 的可测项清单」。
- `docs/cross-check-design.md` 末尾加一段指向新文档；`Tests/README.md` 加「考卷」一节与新钩子。

## 4. 验证与交付
- `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` BUILD SUCCEEDED。
- `Tests/synth/runner/run_all.sh`（命令字符串以 `Tests/` 开头直接调用）114/114 且末尾考卷汇总；`--portal-selftest`、`--crosscheck-selftest` 仍过。
- 钩子回归（各自新起副本、离线、`fakeroute all ok`、`autotripmap 0`）：`Tests/ui/run_batch_review_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`、`run_crosscheck_tests.py` 末行 `FAILS: none`；新加 `Tests/ui/run_plausibility_tests.py`：假引擎 `fakeroute valhalla offset 30` 下某项 risk 升高且 reasons 非空、`fakeroute all ok` 下 risk 为 low；`riskthreshold` 生效；state 字段齐全。
- 本地化：新文案走 `Tests/README.md` 第 410 行附近的流程（下一个未用编号 chunk；assemble missing 0）。
- `output.md`：设计要点、考卷分布与成绩表、第一关混淆矩阵、阈值调整说明、测试末行原文、联网请求用量、未做/存疑。
- 硬规则：不安装、不动 /Applications、UI 禁词（待审核/报警/冲突/已验证/失锁）、不回退工作区已有改动、子 agent 一律前台等待（放后台就结束回合会被判完成）。进度随时写 progress.md。
