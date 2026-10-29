# API 任务：隧道补点 5 处问题的修正（trimEnds/taper 伪影、假点链、过时点保留改时、短断档门槛）

记录日期 2026-10-26。模型：claude-fable-5-1。权限：`--write`（改源码、xcodebuild、跑离线测试）。**不联网、不安装到 /Applications、一次只跑一个 xcodebuild 和一个测试副本**。用中文写 output.md 与进度。

## 0. 项目与背景

GPXPointViewer：macOS SwiftUI + MapKit + Metal 的 GPX/CSV 轨迹查看器（仓库根目录就是当前目录，App Sandbox，四语本地化：zh-Hans 源 + en/de/zh-Hant）。
「断档补点」：时间空洞两端锚点 A/B 向 OSRM / Valhalla（都用 OpenStreetMap 数据）取道路几何，裁剪、贴路、渐进靠拢后按原始点距沿路插点；精确模式两路同取并比对。
设计文档 `docs/cross-check-design.md`、`docs/batch-review-design.md`；README「断档补点（隧道）」段；自测说明 `Tests/README.md`（§2–§3 必读）。

**先读诊断报告 `Tests/reports/20261026_1500_tunnel_diagnosis.md`（全文）**。它用真实数据（`data/compare/Muenchen_Roma_Garmin.gpx`，33,496 点，Garmin，1 s / 28 m）钉死了用户指出的 5 处问题的根因，本任务就是把报告 §7 的修改方案做出来。报告的中间文件（OSRM 原始几何 `gap14_osrm_ctx.json` 等、逐点距离 `gapNN_compare.json`、GapDetector 的 python 复现 `detector/`、冻结扫描 `freeze/`）在
`/Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/20261026_143424_tunnel-diagnosis-2/work/`（只读参考，测试需要的数据拷进仓库 `Tests/synth/fixtures/tunnel/`）。

根因摘要（细节以报告为准）：
1. 第 14/16/19 处（A22 Tusch、A22 Trento、A1 Monzuno）：`RoadNetwork.trimEnds`（RoadNetwork.swift 约 :1245）把离锚点 A <30 m 的首顶点（裁剪投影点）删掉，隧道 way 只有 2 个节点时下一顶点在 155 m 外，整条直边丢失；随后 `taper`（约 :1593–:1648）对剩余折线的**首段无限延长线**量垂距 d（算了 `along` 却不检查），得出「A 离路 32 m」（真实 12 m），把首点平移到 152 m 外。结果前 34–145 m 的补点横向偏 16–32 m，看着像跑到旁边的路上 / 中途换路。两路一致是因为同走这段后处理。
2. 第 14 处 A 前 4 点（9729–9732）是设备进隧道后的外推假点（航向 225.7°、步长 28.6 m 锁死）；现在 A 取在假点上。
3. 第 14 处区间内点 9733 是过时时钟点：位置在出口车道上（离路 3.3 m）是对的，时间戳滞后 7–8 s；现在被整点替换，用户说「删了不该删的点」。
4. 第 33 处附近 21647→21648（1 s 跳 109 m + 4 s 跳 27 m 的微型隧道）没成候选：卡 `GapDetector` 的 minMeters 150 / staleMinJump 5 s 等；全文件同类 6 处（8783、9808、9920、20908、21465、21647）。
5. fb_49 的「离路远」是 Apple 底图不画隧道，补点在 OSM 隧道 way 上 0 m —— **不改**。

另一个 API 任务（route-cache）刚在同一仓库改完「路网结果缓存 + 重新获取 + 修改记录两路切换」，先 `git diff --stat` 看清现状，**不要回退它的改动**；本地化块它用了 `Tests/l10n/translations/chunk_21.json`，你用下一个未用编号。

## 1. 要改的点（按优先级，全部要做）

### 1.1 trimEnds / taper 伪影（RoadNetwork.swift）
- `trimEnds`：删掉近点后若新首点离 A > max(60 m, 2×局部步长) 就不删（保留裁剪投影点 pa.pt，只删 pa.pt 与下一顶点之间 <30 m 的中间点）；B 侧对称。
- `taper`：`along < −10 m`（垂足在首点后方）时不是「锚点离路」而是「首点在锚点前方」，直接不 taper；d 改用锚点到**原始 raw 折线**的距离（clip 已算出 snapA/snapB），不要再对单段延长线量。
- 事后自检：A→coords[0] 距离 > max(30, 2×点距) 或方向与 bearingA 差 >30° 时加 warning「首段不是路网几何」（B 侧同）。
- `anchorWarning`（约 :1834）同时看 taper 的 d：d − residual > 10 m 就是伪影信号，也要报。
- **纯函数测试**（放进 `Tests/synth/runner/main.swift` 的自测，新开关 `--portal-selftest`，照 `--crosscheck-selftest` 的写法）：raw = `gap14_osrm_ctx.json` 的 10 个顶点、a=9732 (46.503401, 11.457193)、b=9734 (46.501949, 11.454516)：期望 coords[0] 距 (46.503487, 11.457094) ≤5 m、8 个补点到理想折线 ≤3 m、notes 不含「A 离路 32 m」。第 16（gap15_osrm_ctx.json，a=12013、b=12015）/ 19（gap18_osrm_ctx.json，a=20893、b=20895）处：顶点到 OSM way 最大距离 ≤10 m（现在 24 m）。再加 2 个反例保证正常情况不退化（锚点真离路 40 m 的合成例子仍要 taper；锚点旁真打小折 <30 m 的点仍要删）。

### 1.2 A 侧冻结假点链前移（GapFill.swift，`GapRouteInputs.build` 约 :1142 之前）
只对采样画像为专用记录仪（deviceLogger）的 staleClock 候选生效，规则（报告 §1.3）：
- 前提：A 往前 9 步都 dt=1 s，且 A−1 步长 20–80 m；
- 从 A−1 往回数连续步，相邻航向差 ≤0.2° 且步长差 ≤0.2 m，链长 n ∈ [3, 6]（n>6 当真实直路，不动）；
- 链起点前 5 步内最大 |Δ航向| ≥1.0°/s（冻结前在转弯）；
- 命中：A 前移 n 点，原 A−n+1…A 随区间替换（落地口径与现有「区间内点替换」一致），notes 加一行「A 前 n 个点是进隧道后的外推点，已并入替换区间」；B 侧不做。
- 测试（离线，用 Garmin 文件，可以在 runner 里直接跑检测，也可以用钩子 `state` 的候选表）：9732→A 前移到 9728；全部 44 处命中 12 处（9050 −4、9323 −4、9468 −3、9732 −4、10021 −5、20885 −5、21242 −3、21385 −3、21448 −3、21730 −3、31246 −5、31290 −5）；23756（12 步直路）不动；21676 不动。

### 1.3 过时时钟点保留位置、回推时间（TrackStore.swift `applyRouteDraft` 约 :2216、落地 job 约 :2389 / `landingJob`，GapSplice，ChangeLog.swift）
- staleClock 候选的区间内点，若离最终路线 ≤ max(匹配半径, 10) m，且按回推时间算车速在 15–350 km/h：**保留位置，只改时间**。t′ = tB − Σ(到 B 的沿路距离)/v_B（链式多点从 B 往回按累计距离依次回推）；不满足条件的退回现在的整点替换。
- 补点区间随之变成 A→(第一个保留点)：新增点只填 A 与保留点之间（第 14 处约 7 个）。
- 修改记录：改时间的点在 `TrackChange` 里按「removed(旧) + added(新)」表示（这样 `ChangeRevert.apply` 按值还原不用改），另加 `retimed` 标记用于显示：摘要显示「+7 点 · 改时间 1 点」而不是「−1」；详细页图例/说明加「改时间的点」（颜色自选，和红/绿/蓝区分）。导出增量（GapFillExport）同样按新旧两条记。
- 测试（离线钩子，`fakeroute all ok`；文件在容器 `~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/Muenchen_Roma_Garmin.gpx`，若缺就从 `data/compare/` 拷进去）：选中 ia=9732 的候选、`route car` 或 `routecross`、应用并落地；期望点数变化 = +新增 −0，9733 仍在且时间 23:12:21 ±1 s（UTC），修改记录 `changes[]` 对应项有 `retimed:1`。需要的话加钩子 `pointat <i>`（返回该下标的 time/lat/lon）和 reviewstate 里的 `retimed` 计数。

### 1.4 staleClock 入口门槛 V1（GapFill.swift `GapDetector`，约 :292 / :327 / :341 / :390）
只对 dt<20 s 且隐含速度 >350 km/h 的 staleClock 入口生效：入口 `d ≥ max(60, 3.5×局部中位步长)`（前 12 步中位）；staleMinJump 5→4 s；A→B 距离用同一 gate；上下文 `5×typical → 3.5×typical`。
- 测试：Garmin 文件候选 44→50，新增正好 8783、9808、9920、20908、21465、21647 六处；Inntal 2759–3012 一处都不新增。
- **合成套件** `Tests/synth/runner/run_all.sh`（114 个文件，期望在 `Tests/synth/gen.py` 里）必须仍 114/114；若某个期望因门槛变化而改变，逐个说明为什么新结果更对，才允许改期望（写进 output.md）。

### 1.5 文案与说明
- 批量窗口 / 单处 notes 里新增的说明要让用户看得懂：「首段不是路网几何」「A 前 n 个点是进隧道后的外推点，已并入替换区间」「保留 1 个位置正确但时间滞后的点，时间按出口速度回推」等。
- UI 禁词：待审核 / 报警 / 冲突 / 已验证 / 失锁（代码注释可用）。

## 2. 回归与构建

1. `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` 必须 BUILD SUCCEEDED。
2. `Tests/synth/runner/run_all.sh` 114/114（**命令字符串必须以 `Tests/` 开头**直接调用，不要加 `bash`/`zsh`/`cd`，否则权限系统会拦；上一个任务就是这样被拦住没跑成）；新自测 `--portal-selftest` 全过；`--crosscheck-selftest`、`--ratelimit-selftest` 仍过。
3. 钩子回归（各自新起副本，见 Tests/README.md；默认通信目录 `tmp/uitest`）：`Tests/ui/run_crosscheck_tests.py`、`run_batch_review_tests.py`、`run_fill_tests.py`、`run_route_notes_tests.py`、`run_profile_tests.py` 末行都要 `FAILS: none`；route-cache 任务新加的 `Tests/ui/run_route_cache_tests.py`（D0–D6）也要过。
4. 结束复位偏好：`python3 Tests/ui/ui.py "crosscheck 0" "fakeroute all off" "reviewmap standard light 1" "fillpoints 0"`，`pkill -f app.noindex`。

## 3. 本地化与文档
- 新增文案：`xcodebuild -exportLocalizations …` → `python3 Tests/l10n/extract_keys.py <export dir> <out dir>` → 翻译写进下一个未用编号的 `Tests/l10n/translations/chunk_NN.json`（格式照 chunk_20.json）→ `python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`（missing 0 / specifier problems 0）→ 重建。导出产物放 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api3/`。流程细节见 Tests/README.md 第 410 行附近。
- `docs/cross-check-design.md` 加「后处理伪影（trimEnds/taper）与修正」「冻结假点链」「过时点保留改时」「短断档门槛 V1」四节，引用报告；README 功能段补一句；Tests/README.md 补新钩子/自测开关。

## 4. 产出与硬规则
- `output.md`（中文）：改了什么（文件/函数）、每条测试期望 vs 实际原文、合成套件结果、构建结果、没做或存疑的点。
- 不联网（所有钩子测试 `fakeroute all ok`，`autotripmap 0`）；不安装；不动 /Applications；一次一个 xcodebuild；不回退 route-cache 的改动；不改 `RouteCrossCheck` 的判定规则。
- 进度随时写 progress.md，中断续跑要能接上。

## 5. 续跑说明（2026-10-26 15:50 补）
上一次运行（20261026_151311）在阶段 1 的 A、B 两个子 agent 完成后，把子 agent C（1.3 过时点保留改时 + 钩子测试）放到后台就结束了自己的回合，运行器把这当成任务完成，C 被中途杀掉。续跑时：
- 先读运行目录 `Tools/agents/runs/20261026_151311_tunnel-fix/` 里的 progress.md、result_A.md、result_B.md、brief_C.md、progress_C.md（若有），再 `git diff` 看 C 留下的半成品（TrackStore.swift / ChangeLog.swift / UITestHook.swift / ChangeReviewWindow.swift），决定接着改还是收拾干净重做；先确认 Release 能构建。
- **子 agent 一律前台等待（run_in_background: false），或者自己做；绝不能把工作放后台然后结束回合**——回合一结束运行就被判完成。
- 其余按 §1–§4 执行：1.3 做完 → 复审 → 回归（xcodebuild、run_all.sh 114/114、--portal-selftest、钩子脚本各自新起副本）→ chunk_22 → 文档 → output.md。

