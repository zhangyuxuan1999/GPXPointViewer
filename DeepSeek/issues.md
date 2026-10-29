# 问题与改进登记

> 状态与严重度定义见 [README.md](README.md)。本表只放"结论 + 证据 + 下一步"，过程见对应的会话记录。
> 标 `review` 的条目来自文档或静态阅读，尚未实测，不能当作已复现缺陷。

## 汇总

| ID | 级别 | 状态 | 主题 |
|---|---|---|---|
| N-01 | P0 | fixed | 版本控制基线缺失：已于 2026-10-29 建立基线/修复两个提交 |
| N-02 | P1 | open | UI 测试会静默选中旧构建（DerivedData 早于最新源码） |
| N-03 | P1 | open | `/Applications` 里是 10-28 旧版，未安装最终构建 |
| N-04 | P1 | open | GCJ-02 未实现，`GeoCoord` 恒等；中国大陆底图整体偏移 |
| N-05 | P1 | open | `.fwdb` 时光机时间线只是区块同步时间近似 |
| N-06 | P1 | checked | `ChangeRevert` 对依赖链的语义：静态跟踪未发现缺陷，缺专门回归 |
| N-07 | P1 | checked | 异步发布 token 覆盖：29 处入口全部有归属校验 |
| N-08 | P1 | open | 25 脚本 UI 全套没有在最终构建上的完整证据 |
| N-09 | P1 | open | 地区边界数据已知错误（阿鲁巴、繁体名、佛罗伦斯等） |
| N-10 | P1 | open | 三处文档与实现漂移 |
| N-11 | P1 | open | `run_regions_stats_tests.py` 不在全套，也未在文档标明 |
| N-12 | P2 | open | 全套日志名 `suite_HHMM.log` 无日期，会互相覆盖 |
| N-13 | P2 | open | `/private/tmp` 245 个 `gpxpv-*` 目录，3.4 GB，无清理策略 |
| N-14 | P2 | open | 工作区杂物：177 个 `__pycache__`、17 个 `.DS_Store`，根 `.gitignore` 有缺口 |
| N-15 | P2 | open | 六个巨型源文件（2k–4.5k 行）阻碍维护与拆分 |
| N-16 | P2 | open | DerivedData 与最终构建体积差一倍，配置是否一致待核对 |
| N-17 | P2 | open | 唯一与源码一致的构建只在 `/private/tmp`，随时可能丢 |
| N-18 | P2 | open | README 的性能数字没有可复现基线 |
| N-19 | P0 | fixed | 部分点缺时间/海拔时，时间/海拔着色触发 `Int(NaN)` 崩溃（2026-10-29 修复） |
| N-20 | P1 | open | `.fwdb` 目录里长"密码字母"文件名导致 UInt64 溢出崩溃 |
| N-21 | P1 | open | README「多窗口互不影响」与共享 TrackStore 实现不符 |
| N-22 | P2 | open | 多段 GPX 导出走串行路径，且每段多一次复制 |
| N-23 | P2 | open | `MetalPointRenderer.upload` 用点数 `n` 而不是数组长度做拷贝 |
| N-24 | P2 | open | 每个 `.fwdb` 区块文件都先清零 8.4 MB 解压缓冲 |
| N-25 | P2 | open | Valhalla 错误码映射有不可达分支 |
| N-26 | P2 | open | `GPXWriter` 静默丢弃越界下标（导出可能少点不报错） |
| N-27 | P2 | open | 导出文件名递增依赖轨迹名，与 README 描述不符 |
| N-28 | P2 | open | `RailPath` 对空路径会构造非法 Range（防御性） |
| N-29 | P2 | open | 单文件载入做两次整列拷贝（slice + merge） |
| N-30 | P2 | fixed | 合成回归不覆盖 `TrackData` 着色路径，导致 N-19 漏检（core 已补） |
| N-31 | P2 | open | `UITestHook` 有重复的 `case "screens"`，第二个分支永远不执行 |

---

## P0

### N-01 版本控制基线缺失

- **状态**：fixed（2026-10-29 DeepSeek 建立基线） ｜ **级别**：P0 ｜ **发现**：2026-10-29
- **证据**
  - `git log --oneline` 只有两个提交：`b8927ed quicklook`（2026-08-16 19:35 +0200）、`4c8eed5 initial commit`。
  - `git status --short` 64 项已跟踪改动；另有整批未跟踪源码：`GPXPointViewer/` 下 24 个 `.swift`/资源、`Tests/`、`Tools/`、`docs/` 整个目录。
  - [AGENTS.md](../AGENTS.md) 已写明"仓库已有大量未跟踪文件，单独 `git diff` 无法完整记录更改"。
- **影响**：8 月以后的全部开发没有版本历史。一次误删、误覆盖、工具自动改写都无法从 git 恢复，也无法用 diff 界定"这次改了什么"。`Tools/agents/` 下的逐 run 快照是任务级证据，不构成仓库基线。
- **建议**：经用户授权后做一次基线提交并打 tag（如 `baseline-2026-10-29`），排除 `data/`、`Tests/ui/perf/`、`Tests/ui/app.noindex/`、`Tests/ui/GPXPointViewer.app/`、构建产物、`.DS_Store`、`__pycache__/`；之后保持一个逻辑改动一个提交。**代理不得擅自提交或推送。**
- **下一步**：先问用户是否授权提交；若暂不提交，至少把当前源码树打成一个带哈希的归档放项目外。
- **2026-10-29 解决（用户授权后由 DeepSeek 执行）**
  - 基线提交 `f6a9049`（tag `baseline-2026-10-29`，819 个文件，N-19 修复前的状态）；
  - 修复提交 `4ab625e`（tag `n19-fix-2026-10-29`，N-19 + 记录）；`origin/main` 仍在 `b8927ed`，**未 push**；
  - 新增排除项：`Tools/agents/records/`（约 1 GB）、`__pycache__`、`.DS_Store`、`*.lock`、`.build/`；
  - 取消跟踪两个 `.DS_Store`；`data/` 与测试副本/生成物仍按原规则排除。
  - 范围、排除理由与四种回滚方式见 [Git 基线与回滚](git.md)。

---

## P1

### N-02 UI 测试会静默选中旧构建

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**
  - [Tests/ui/ui.py:15](../Tests/ui/ui.py#L15) `app_source()` 顺序：`GPXPV_APP` → DerivedData 最新 Release → `/Applications`。
  - 当前 DerivedData Release：`~/Library/Developer/Xcode/DerivedData/GPXPointViewer-ggblzdtkxuxzkzaeladpgtmyxpkq/Build/Products/Release/GPXPointViewer.app`，可执行文件 25,040,544 B，mtime **2026-10-29 01:34**。
  - 最终验收构建：`/private/tmp/gpxpv-label-build/Build/Products/Release/GPXPointViewer.app`，12,336,224 B，mtime **14:14**，sha256 `22e77c20…`。
  - 当前源码最新 mtime **14:09**（[ContentView.swift](../GPXPointViewer/ContentView.swift)），此后无文件更新。
  - [Tests/ui/run_suite.sh:7](../Tests/ui/run_suite.sh#L7) 会先 `rmtree` 再 `copytree(app_source())`；`Tests/ui/app.noindex` 里现存的 14:14 好副本会被 01:34 的旧构建覆盖。
- **影响**：直接跑 `Tests/ui/run_suite.sh` 测的是缺"标签避让"修复的旧二进制，结论不能归属当前源码；而日志第一行 `testing …` 很容易被忽略。
- **建议**：
  1. `run_suite.sh` 启动时打印目标二进制的 `shasum -a 256` 与 mtime，与最新源码 mtime 比较，旧于源码就拒绝（除非 `ALLOW_STALE=1`）。
  2. 默认把 `GPXPV_APP` 指向最终验收构建，或强制先重新构建。
  3. [Tests/README.md](../Tests/README.md) §2.2 补一句"DerivedData 可能比源码旧"。
- **下一步**：改脚本（低风险）；下次跑 UI 前先确认目标构建哈希。

### N-03 `/Applications` 与当前源码不一致

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**
  - `/Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer`：mtime **2026-10-28 14:12**，sha256 `a901e819…`。
  - 最终构建 sha256 `22e77c20…`；[completion-report.md](../Tools/agents/records/2026-10-28-remediation/coordinator/completion-report.md) 明确"没有安装或覆盖正式 app"。
- **影响**：用户日常运行的是 10-28 版本，不含 10-29 的标签修复，也不含 R4 整合后的最终验收构建。
- **建议**：取得用户授权后安装（见 [Tests/README.md](../Tests/README.md) §7 第 5 步）；安装后只跑受影响脚本（批量审阅 / 标签截图），不重跑全套。
- **下一步**：等用户决定。

### N-04 GCJ-02 未实现

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**
  - [GapFill.swift:26](../GPXPointViewer/GapFill.swift#L26) `enum GeoCoord` 的 `mapToData` / `dataToMap` 均直接返回入参，注释写着"届时在这里补 wgs↔gcj 转换并加设置开关"。
  - 数据内部恒为 WGS-84；Apple 中国大陆底图使用 GCJ-02。
- **影响**：在中国大陆，点位显示、悬停拾取、套索圈选、补点草稿与底图会整体偏移（城市尺度可达数百米）。导出、统计、迷雾格子用数据坐标，不受影响。
- **建议**：设置里加"中国底图偏移校正"开关；实现 WGS-84 ↔ GCJ-02 往返；用 3–5 个已知地标做单元测试；只改地图坐标转换层，不动数据列与导出。
- **下一步**：先确认用户是否需要在中国大陆使用，再排期。

### N-05 `.fwdb` 时光机时间线是近似

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**：[FogArchive.swift:26](../GPXPointViewer/FogArchive.swift#L26) 注释与 `levelGens`/`genTimes`：`.fwdb` 无逐格时间戳，区块同步时间是唯一真实时间线，一个区块的格子同代出现。
- **影响**：用 `.fwdb` 做时光机时，"什么时候探索了哪里"是按区块代近似；同代区块会同时点亮，年度回顾可能偏差明显。
- **建议**：回放界面或导出说明里标注"近似：按存档区块同步时间"；若做年度回顾，用代粒度提示而不是假装逐格时间。
- **下一步**：文案改动即可，先确认用户是否在意。

### N-06 `ChangeRevert` 对依赖链的语义

- **状态**：checked ｜ **级别**：P1 ｜ **发现**：2026-10-29（继承 10-28 接手记录）
- **原始证据**
  - [codex-handover-2026-10-28.md:94](../docs/codex-handover-2026-10-28.md#L94)：举例"先补点 P、再删除 P、最后全部还原"，担心恢复中间点。
  - 实现入口：[TrackStore.swift:3078](../GPXPointViewer/TrackStore.swift#L3078) `revertChanges` → `ChangeRevert.apply(to:changes:history:baseline:)`。
- **2026-10-29 复核（静态跟踪 [ChangeLog.swift:136](../GPXPointViewer/ChangeLog.swift#L136)）**
  - 选择集 == 全部未还原修改时直接返回 `baseline`（精确会话基线），"补 P→删 P→全部还原"不会复活中间点。
  - 部分还原时，后续未选修改若触及同一完整位值键 → `.laterDependency` 拒绝；同时间不同位值 → `.ambiguousOrder` 拒绝；找不到出现次数 → `.missingOccurrence`。都是显式失败，不会静默插错位置。
  - 结论：**未发现缺陷**。"补 P→删 P→只还原 P"会因后续删除依赖而被拒绝，这是设计上的安全行为。
- **残留风险**：没有针对这三条链的专门回归用例；实现依赖调用方完整传入 `history`。
- **建议**：补 (a) 补 P→删 P→全部还原；(b) 补 P→删 P→只还原 P（应拒绝）；(c) 两处交叠区间分别还原 三条用例到 `Tests/segments/workflow`。

### N-07 通用异步发布的 token 覆盖

- **状态**：checked ｜ **级别**：P1 ｜ **发现**：2026-10-29（继承 10-28 接手记录）
- **原始证据**
  - [codex-handover-2026-10-28.md:95](../docs/codex-handover-2026-10-28.md#L95) 指出通用加载/显示重建的过期任务保护弱于批量、地区统计。
- **2026-10-29 复核（逐入口审计）**
  - [TrackStore.swift:133](../GPXPointViewer/TrackStore.swift#L133)–`:160` 有 `DataPublicationToken` / `beginDataOperation` / `owns` / `publishData`；`beginDataOperation` 会 `invalidateDataOperations()`，同时撤销路线草稿、行程地图与批次。
  - 全文 29 处 `Task` / `Task.detached`：全部具备下列之一——publication token + `owns`/`publishData`、请求 ID（`fillRouteRequestID`）、`generation`（批量/地区/迷雾合并）、或按内容复核（地名回填检查 `changes`/`previewIDs` 仍含该 id）。渲染统计与 toast 两处是无状态 UI 更新，不需要归属。
  - 结论：**未发现遗漏入口**。
- **残留风险**：静态审计，没有逐个构造"换文件时正好在途"的并发用例；`Tests/segments/workflow` 只覆盖部分场景。
- **建议**：保留本条作为记录，不必再改代码；后续新增异步入口时按同一模式补 token。

### N-08 25 脚本 UI 全套没有在最终构建上的完整证据

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**
  - [Tests/ui/perf/suite_2245.log](../Tests/ui/perf/suite_2245.log) 是最后一次完整全套：**2026-10-24 22:45**，当时 18 个脚本，15 个 `FAILS: none`；`run_route_tests` 的 R8c、`run_rail_tests` 的 R2 失败（公共路网限流特征），`run_drift_tests` 不打印 FAILS。
  - 现在 [run_suite.sh:19](../Tests/ui/run_suite.sh#L19) 列 25 个脚本。
  - R4 验收的 11 组 UI 属于更早构建，且"恢复过程继承原始证据，0 组重跑"。
- **影响**：目前没有"25 脚本在最终构建上全过"的证据。汇报时必须说明这是继承结论，不能说全套通过。
- **建议**：下次动产品代码前，用 `GPXPV_APP` 指向正确构建跑一次全套（约 35–40 分钟、占屏、联网脚本串行），保存日志并记录构建 sha256 与源码 mtime。
- **下一步**：与 N-02 一起处理，先修脚本再跑，避免测错构建。

### N-09 地区边界数据已知错误

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29（来自 [Tests/tasks/api/_backlog.md](../Tests/tasks/api/_backlog.md) 2026-10-28 段）
- **证据**（backlog 原文归纳）
  - 阿鲁巴首府点落在多边形外（CGAZ 的阿鲁巴多边形太粗）。
  - Natural Earth `name_zh` 夹带繁体字：下萊茵、日內瓦、戈里齊亞。
  - "佛罗伦斯省"应为"佛罗伦萨"。
  - 意/法/英一级粒度与世界迷雾的口径不同。
- **影响**：地区统计卡片、地图高亮在这些位置显示错误归属或名称；不影响轨迹数据本身。
- **建议**：下次重建 `Regions.bin` 时改用宗主国切分的阿鲁巴边界 + 名称清洗表；粒度差异写进 [docs/regions-design.md](../docs/regions-design.md) 的"已知差异"。
- **下一步**：等用户决定是否重建数据（需要下载原始边界，需授权）。

### N-10 三处文档与实现漂移

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**
  1. [PreviewViewController.swift:6](../GPXQuickLook/PreviewViewController.swift#L6) 写"超大文件（>48MB）降级"，实际 [同文件:18](../GPXQuickLook/PreviewViewController.swift#L18) `fullParseLimit = 32 MB`。
  2. [cross-check-design.md:94](../docs/cross-check-design.md#L94) 仍列"未做（记录）"三项，而同文档 2026-10-28 一节已写明三项已做。
  3. [fill-plausibility-design.md:31](../docs/fill-plausibility-design.md#L31) / `:51` 仍写 `tunnelShare`"本期恒 nil / 本期不扣分"，实际 [FillPlausibility.swift:57](../GPXPointViewer/FillPlausibility.swift#L57) 有字段、`:327` 有隧道豁免逻辑（OSRM `intersections.classes`）。
- **影响**：后人会把旧句当现状，重复排查或误判"未实现"。
- **建议**：一次文档校对；把"历史决策"与"当前实现"分节，历史保留但标注日期与状态。

### N-11 `run_regions_stats_tests.py` 不在全套

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**：[run_suite.sh:19](../Tests/ui/run_suite.sh#L19) 的 25 个脚本不含它；它自己起两次测试副本，约 3 分钟。
- **影响**：地区统计的 UI 回归默认不会被跑到，改动 `RegionIndex`/`RegionStats`/窗口后容易漏测。
- **建议**：加入全套（排在最后）或在 [Tests/README.md](../Tests/README.md) §3.6 明确"不在全套，需单独跑"。

---

## P2

### N-12 全套日志名无日期

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[run_suite.sh:5](../Tests/ui/run_suite.sh#L5) `OUT=perf/suite_$(date +%H%M).log`。
- **影响**：同一天跑两次会覆盖；不同天同一时刻也会同名覆盖，违背"保留原始失败证据"的规则。
- **建议**：改成 `suite_$(date +%Y%m%d_%H%M).log`。

### N-13 `/private/tmp` 构建目录膨胀

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：`ls -d /private/tmp/gpxpv-*` 共 **245** 个目录，合计 **3.4 GB**（大量 `gpxpv-runner-tests-*`）。
- **影响**：占用磁盘；真正的验收构建（`gpxpv-label-build`、`gpxpv-remediation-build`、`gpxpv-segment-*`、`gpxpv-render-*`、`gpxpv-workflow-*`）淹没在噪音里，容易误删。
- **建议**：写一个带 `--dry-run` 的清理脚本放 `Tools/agents/`，按 mtime + 白名单（保留有证据引用的目录），清理前先列出并记录到本目录。

### N-14 工作区杂物与 `.gitignore` 缺口

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：177 个 `__pycache__` 目录、17 个 `.DS_Store`；根 [.gitignore](../.gitignore) 没有 `__pycache__/` 与 `.DS_Store`（[Tests/.gitignore](../Tests/.gitignore) 有 `__pycache__/`）。
- **影响**：一旦提交会把缓存带进仓库；目录遍历、搜索、快照也更慢更吵。
- **建议**：根 `.gitignore` 补两行，清一次现有缓存（不影响任何构建）。

### N-15 巨型源文件

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**（`wc -l`）：`TrackStore` 4,547、`PointMapViewer` 3,560、`ContentView` 2,858、`MetalPointRenderer` 2,268、`GapFill` 2,156、`RoadNetwork` 2,065。
- **影响**：单文件承担多重职责，改动相互牵连；审查和合并冲突成本高。
- **建议**：按工作流拆分（加载/显示、补点、批量、审阅、导出），但**顺序必须是"先固定基线并补测试，再拆"**（与 10-28 手记的建议一致）；一次只拆一个工作流。

### N-16 两份构建体积差一倍，配置是否一致待核对

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：DerivedData Release 可执行文件 25,040,544 B；最终验收构建 12,336,224 B。
- **影响**：如果差异来自 `STRIP_INSTALLED_PRODUCT` / `DEBUG_INFORMATION_FORMAT` / 优化级别，那么 UI 测试与验收构建就不是同一配置，性能与崩溃行为可能不同。
- **建议**：对两份构建跑 `xcodebuild -showBuildSettings`，比对 `SWIFT_OPTIMIZATION_LEVEL`、`DEBUG_INFORMATION_FORMAT`、`STRIP_INSTALLED_PRODUCT`、`ONLY_ACTIVE_ARCH`；把结论写回本条。

### N-17 唯一正确的构建只在 `/private/tmp`

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：与当前源码一致（0 个构建输入比它新）的构建是 `/private/tmp/gpxpv-label-build/.../GPXPointViewer.app`，sha256 `22e77c20…`；`/private/tmp` 重启或清理即丢失。
- **影响**：丢失后必须重新构建才能复现验收；而重新构建的结果需要重新核对哈希。
- **建议**：归档到固定位置（如 `~/Library/Application Support/GPXPV-builds/`），或重新构建到 DerivedData 并把 sha256 记在 `Tests/reports/`。

### N-18 性能数字缺可复现基线

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[README.md](../README.md) 有大量性能声明（500 万点、460 MB 解析 1–2 秒、GPU 2–7 ms、24 秒 720p 导出约 36 秒等），但仓库里没有"机器 + 构建 + 样本 + 命令 + 结果"的基线文件；`Tests/ui/run_perf_probe*.py` 是诊断脚本，只打印不设基线。
- **影响**：文档数字会随时间和硬件漂移，无法判断回归。
- **建议**：固定测试机、构建 sha、样本文件与命令，存一份 `Tests/reports/perf_baseline_<日期>.md`；README 的数字标注出处与测量日期。

---

## 2026-10-29 第二轮深度审查新增

> 本轮两条崩溃是用产品源码编命令行探针实际复现的；其余为静态推断，已在条目里注明。

### N-19 部分点缺时间/海拔时，时间/海拔着色触发 `Int(NaN)` 崩溃

- **状态**：fixed（2026-10-29 DeepSeek 修复） ｜ **级别**：P0 ｜ **发现**：2026-10-29
- **证据**（以下行号是**修复前**的版本；修复后 `Colormaps` 前移 5 行、`GeoCompute` 前移 4 行）
  - [Colormaps.swift:51](../GPXPointViewer/Colormaps.swift#L51) `let raw = Int(tBase[i] * 255.0 + 0.5)`：`tBase[i]` 为 `NaN` 时 `Int(NaN)` 直接 trap。
  - [GeoCompute.swift:253](../GPXPointViewer/GeoCompute.swift#L253) 的 `vDSP_vclipD` **实测不处理 NaN**（NaN 原样传出），所以 `normalized01` 不能保证输出有限。
  - [TrackData.swift:994](../GPXPointViewer/TrackData.swift#L994) 的 `values(for:)` 返回原始 `time`/`ele` 列，缺失值仍是 NaN；`resolveMode`（[:982](../GPXPointViewer/TrackData.swift#L982)）只在**全部**缺失时降级，`hasTime`/`hasEle` 是"任意一个点有值"（[:675](../GPXPointViewer/TrackData.swift#L675)、[:923](../GPXPointViewer/TrackData.swift#L923)）。
  - **真实数据复现**：`data/Garmin_Roma_Da1_GPVexported.gpx` 49,672 个点、5 个缺 `<ele>`；解析后 `recolor(preferred: .elevation)` → `Trace/BPT trap: 5`（SIGTRAP）。`compare/Da_Muenchen_Garmin_GPVexported.gpx` 同样（15,113 点 / 15,112 `<ele>`）。
  - 合成最小例：中间点 `time = .nan` 或 `ele = .nan`，`.time` / `.elevation` 均崩溃；`.speed` 不崩（`speedsKmh` 收尾清零 NaN，[GeoCompute.swift:171](../GPXPointViewer/GeoCompute.swift#L171)）。
- **影响**：应用当场退出，未落地的编辑丢失。项目自己导出的文件就可能触发（`GPXWriter` 对 NaN ele 不写 `<ele>`）。
- **建议**：`Colormaps.colorize` 对非有限值取 0；`normalized01` clip 后显式清 NaN；`Colormap.rgb` 同样加守卫；明确缺失值配色口径并补回归（见 N-30）。详见 [深度审查记录](2026-10-29-deep-review.md)。
- **2026-10-29 修复（DeepSeek）**：`Colormaps.colorize` / `Colormap.rgb` 对非有限值取最低档；`GeoCompute.normalized01` 在 clip 后把非有限值压到 0。回归加在 `Tests/segments/core`（11 项）。核心 112/112、真实文件四模式通过；用旧实现跑同一测试仍 exit 133（反证）。完整改动、哈希与命令见 [修复记录](2026-10-29-N19-fix.md)。

### N-20 `.fwdb` 目录里长"密码字母"文件名导致溢出崩溃

- **状态**：open（已复现） ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**：[FogArchive.swift:286](../GPXPointViewer/FogArchive.swift#L286) `num = num * 10 + d` 无溢出保护；`load` 会解析 `Sync/` 下所有非点开头文件（[:104](../GPXPointViewer/FogArchive.swift#L104)），不检查名字长度。文件名去掉前 4/后 2 后若 ≥20 位全是 `olhwjsktri`，`UInt64` 乘法 trap。用 36 字符的合成文件名实测 exit 133。
- **影响**：罕见的目录污染即可让导入崩溃；`looksLikeArchive` 的名字长度限制没有用在 `load` 上。
- **建议**：`guard core.count <= 18 else { return [] }`（区块号最大 6 位，18 只为兼容零填充），或改用 `&*` 并在循环内检查 `num < 512*512`。

### N-21 README「多窗口互不影响」与实现不符

- **状态**：open ｜ **级别**：P1 ｜ **发现**：2026-10-29
- **证据**：[README.md:68](../README.md#L68) 写"⌘N 可开多个窗口同时看多个 GPX，互不影响"；但 [GPXPointViewerApp.swift:120](../GPXPointViewer/GPXPointViewerApp.swift#L120) 在 App 级持有唯一 `TrackStore`，`WindowGroup` 所有窗口共用（[:128](../GPXPointViewer/GPXPointViewerApp.swift#L128)），[ContentView.swift:14](../GPXPointViewer/ContentView.swift#L14) 只是 `@ObservedObject`。
- **影响**：用户按文档预期开第二个窗口看另一个文件，实际会把所有窗口的文档一起换掉。
- **建议**：改文档为"多窗口查看同一份数据（共享文件/筛选状态）"；若确实需要独立文档，是另一个量级的改造（每个窗口一个 store）。

### N-22 多段 GPX 导出走串行路径

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[GPXWriter.swift:49](../GPXPointViewer/GPXWriter.swift#L49)：`segs.count > 1` 时逐点串行格式化，且每段先建 `[UInt8]` 再 `Data(bytes)` 复制；单段路径才用 `concurrentPerform` 分块。
- **影响**：重叠/对比模式导出、增量导出（每处补点一段）在百万点级明显慢于单段。
- **建议**：按段并行（每段独立缓冲，最后按顺序拼接），或把单段的分块写出复用为"每段一次"。

### N-23 `MetalPointRenderer.upload` 用点数 `n` 而不是数组长度做拷贝

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[MetalPointRenderer.swift:533](../GPXPointViewer/MetalPointRenderer.swift#L533)：`length: n * MemoryLayout<Float>.stride`，`n = track.count`，不是 `a.count`；`baseAddress!` 也没有空数组守卫。
- **影响**：当前所有列等长，暂不出错；一旦某个派生列变短（新字段/裁剪路径）就是越界读或读未初始化内存。
- **建议**：`guard !a.isEmpty`，`length: a.count * stride`。

### N-24 每个 `.fwdb` 区块文件都先清零 8.4 MB 解压缓冲

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[FogArchive.swift:293](../GPXPointViewer/FogArchive.swift#L293) `Data(count: 32768 + 515*16384)` ≈ 8.4 MB 且清零；典型区块解压后只有几十 KB。
- **影响**：世界级归档（上千区块）会产生数 GB 的无效清零写入；常见小归档不受影响（README 的 80 万格 65 ms）。
- **建议**：先按 `comp.count * 8` 估上限、失败倍增重试，或改用 `compression_stream` 流式解压。

### N-25 Valhalla 错误码映射有不可达分支

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[RoadNetwork.swift:542](../GPXPointViewer/RoadNetwork.swift#L542)：`ec == 442 || ec == 171 ? "NoRoute" : (ec == 170 || ec == 442 ? "NoSegment" : ...)`，第二个 `ec == 442` 永远不会命中。
- **影响**：某些错误被归到 `NoRoute` 而不是更具体的原因；不影响补点安全（失败同样不落地）。
- **建议**：对照 Valhalla 文档确认 170/171/172 的语义，去掉或改正死分支。

### N-26 `GPXWriter` 静默丢弃越界下标

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[GPXWriter.swift:41](../GPXPointViewer/GPXWriter.swift#L41) `for index in selection where index >= 0 && Int(index) < track.count` 静默跳过越界项。
- **影响**：调用方传错下标时导出会**少点且不报错**；导出属于写文件操作，静默缺数据比失败更糟。
- **建议**：改成 `precondition` 或抛错；至少在返回结果里带丢弃计数。

### N-27 导出文件名递增依赖轨迹名

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[TrackStore.swift:1313](../GPXPointViewer/TrackStore.swift#L1313) `exportedFileName` 只检查轨迹名是否已带 `_GPVexported`；[README.md:56](../README.md#L56) 说"再次导出自动递增 `_2`、`_3`…"。
- **影响**：同一份轨迹连续导出两次，第二次仍叫 `_GPVexported`，靠保存面板提示覆盖；只有重新导入导出文件才会递增。
- **建议**：按目标目录里已存在的文件自动选下一个编号，或改文档措辞。

### N-28 `RailPath` 对空路径会构造非法 Range

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[RoadNetwork.swift:1389](../GPXPointViewer/RoadNetwork.swift#L1389) `for k in 1..<path.count`；`path = ids.compactMap { coord[$0] }`，正常图非空，但若图里有节点没有坐标就可能为空，`1..<0` 构造即 trap。
- **建议**：`guard path.count >= 2 else { throw RouteError.noRailPath }`。

### N-29 单文件载入做两次整列拷贝

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：`load` 先用 `GPXParser.slice` 给每个文件留底（[GPXParser.swift:466](../GPXPointViewer/GPXParser.swift#L466)，整列复制），再 `rebuildDisplayTrack` 调 `mergeParsed`（[GPXParser.swift:483](../GPXPointViewer/GPXParser.swift#L483)，再整列复制）。单文件时两次都只是把同一份数据抄一遍。
- **影响**：1 个 190 万点文件多约 121 MB 峰值与两次内存带宽（几十毫秒）；5M 点更明显。
- **建议**：`urls.count == 1` 时直接用解析结果作为显示数据（名称/来源就地设置），跳过 slice+merge。

### N-30 合成回归不覆盖 `TrackData` 着色路径

- **状态**：fixed（2026-10-29 DeepSeek 补回归） ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：`Tests/synth` 的 `format-edge` 有"半有时间"的 GPX 夹具，但 synthrunner 只验证解析/检测结果；`TrackData.recolor` 只在 `Tests/segments/core` 里出现，且没有"部分缺失值 + 四种着色模式"的用例。N-19 因此长期漏检。
- **影响**：同类"数据边界 → 渲染派生"的缺陷还会漏。
- **建议**：在 `Tests/segments/core` 加一个夹具：部分点缺 `time`、部分缺 `ele`、全部缺、单点；四种模式各跑一次，断言不崩溃、`colors.count == 4n`、缺失点落在最低档（或约定的灰色）。

### N-31 `UITestHook` 有重复的 `case "screens"`

- **状态**：open ｜ **级别**：P2 ｜ **发现**：2026-10-29
- **证据**：[UITestHook.swift:565](../GPXPointViewer/UITestHook.swift#L565) 与 [:662](../GPXPointViewer/UITestHook.swift#L662) 各有一个 `case "screens"`；`swiftc -typecheck` 对第二个报 `literal value is already handled by previous pattern`。实际生效的是前者，返回 `frame=… visible=…`；后者想返回的 `序号: frame visible` 格式永远拿不到。
- **影响**：只影响自测钩子的诊断输出；如果有脚本依赖第二种格式，会解析失败。
- **建议**：删掉第二个分支，或把它改成别的命令名（如 `screens2`）按需保留。
