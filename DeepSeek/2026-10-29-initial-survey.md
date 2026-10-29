# 2026-10-29 · 接手梳理与首轮问题清单

- **时间**：2026-10-29 18:54–19:20（Europe/Berlin）
- **发起**：用户"看看这个项目，熟悉一下"，随后要求把发现持久化到项目内专门目录
- **执行**：DeepSeek Harness 主代理（只读调查）
- **产出**：[issues.md](issues.md) 的 N-01 … N-18；本记录

## 范围与方法

只读调查，不构建、不运行产品测试、不联网、不安装、不改产品源码。顺序：

1. 读入口文档：[README.md](../README.md)、[AGENTS.md](../AGENTS.md)、[docs/codex-handover-2026-10-28.md](../docs/codex-handover-2026-10-28.md)、[Tests/README.md](../Tests/README.md)、[Tools/agents/README.md](../Tools/agents/README.md)、[docs/segment-topology-design.md](../docs/segment-topology-design.md)。
2. 读结构与关键源码：`GPXPointViewerApp`、`TrackStore` 的加载与发布段、`TrackData` 的 `TrackTopology`/SoA 字段、`GapFill` 的 `GeoCoord`、`FogArchive` 的 `genTimes`、`FillPlausibility` 的 `tunnelShare`、`MetalPointRenderer` 的 `PointColorBuffers`。
3. 核对工程与构建：`xcodebuild -version`、scheme、项目设置、DerivedData、`/Applications`、`/private/tmp/gpxpv-*`。
4. 核对测试证据：最后一次完整 UI 全套日志、exam baseline、R4 验收报告与构建清单。
5. 复核旧结论：逐条对照 10-28 接手记录里的静态风险与 R4 之后的代码现状。

## 核验到的事实（原始输出摘要）

### 工程与源码

| 项 | 结果 |
|---|---|
| Xcode / Swift | Xcode 26.6 (17F113)；Swift 6.3.3；target `arm64-apple-macosx26.0` |
| 部署目标 / 语言版本 | macOS 14.0 / Swift 5.0 |
| Bundle ID | `de.wayne.GPXPointViewer`（扩展加 `.GPXQuickLook` / `.GPXThumbnail`） |
| 主 app 源码 | 34 个 `.swift`，30,447 行；另有 [Shaders.metal](../GPXPointViewer/Shaders.metal) 1,201 行 |
| 扩展源码 | 458 行 |
| 内置数据 | [Regions.bin](../GPXPointViewer/Regions.bin) 29,411,770 字节（约 28 MiB）；[data/](../data) 1.3 GB（git 忽略） |
| 巨型文件 | `TrackStore` 4,547、`PointMapViewer` 3,560、`ContentView` 2,858、`MetalPointRenderer` 2,268、`GapFill` 2,156、`RoadNetwork` 2,065 行 |

### Git

```
4c8eed5 initial commit
b8927ed quicklook           2026-08-16 19:35:58 +0200
```

- 分支 `main`，远程 `git@github.com:zhangyuxuan1999/GPXPointViewer.git`。
- `git status --short` 64 项；`Tests/`、`Tools/`、`docs/`、多数 10 月新增源码未跟踪。
- 结论：**没有可用的版本基线**（N-01）。

### 构建

| 构建 | 路径 | mtime | 可执行文件 | sha256 |
|---|---|---|---|---|
| 最终验收 | `/private/tmp/gpxpv-label-build/…/Release/GPXPointViewer.app` | 10-29 14:14 | 12,336,224 B | `22e77c20…`（与 manifest 一致，完好） |
| DerivedData | `~/Library/Developer/Xcode/DerivedData/GPXPointViewer-ggblzdt…/Build/Products/Release/` | 10-29 01:34 | 25,040,544 B | 未记 |
| 已安装 | `/Applications/GPXPointViewer.app` | 10-28 14:12 | — | `a901e819…` |

- `find … -newermt '2026-10-29 14:14'` 在三个 target 的源码/资源中返回 **0 个文件** → 最终构建与当前源码一致。
- `Tests/ui/app.noindex/GPXPointViewer.app` 存在且是 14:14 的副本；但 `run_suite.sh` 会被 `app_source()` 覆盖成 01:34 的 DerivedData 构建（N-02）。
- 两份构建体积差约一倍，配置是否一致未核对（N-16）。

### 测试证据

- 最后一次完整 UI 全套：[Tests/ui/perf/suite_2245.log](../Tests/ui/perf/suite_2245.log)，**2026-10-24 22:45**，18 个脚本；15 个 `FAILS: none`；`run_route_tests` R8c、`run_rail_tests` R2 失败（联网限流特征）；`run_drift_tests` 不打印 FAILS。
- 现在全套是 25 个脚本，未在最终构建上跑过（N-08）。
- R4 验收报告结论：合成 114/114、自测 51/51、考卷两引擎各 121/125、11 组 UI 继承通过；明确"没有安装或覆盖正式 app"。

### 环境观察

- `timeout` 命令不存在（非 GNU coreutils）；写脚本别用，改用 `gtimeout` 或 shell 自身机制。
- `xcodebuild -list -project GPXPointViewer.xcodeproj` 运行 60 s 无输出，转入后台后手动取消；`xcodebuild -version` 正常。后续若再现，检查索引/首次启动，不影响 `-scheme` 构建。

## 对 10-28 接手记录中四项风险的复核

| 旧结论 | 现状 | 处置 |
|---|---|---|
| `ChangeRevert` 对依赖链语义不明 | 入口 `TrackStore.revertChanges:3078` → `ChangeRevert.apply`；未找到针对"补 P→删 P→还原"序列的用例 | 保留为 **N-06 review** |
| 通用加载/显示的过期任务保护弱于批量/地区 | `TrackStore.swift:133–160` 已有 `DataPublicationToken`/`beginDataOperation`/`owns`/`publishData`；约 30 处异步入口、49 处 token 调用；覆盖未逐一审计 | 收窄为 **N-07 review** |
| GPU 共享颜色缓冲原地写入与在途绘制所有权 | 已有 `PointColorBuffers`（[MetalPointRenderer.swift:157](../GPXPointViewer/MetalPointRenderer.swift#L157)、`:362`、`:544`），每帧 `let frameColors = colorBuffers` 本地捕获（`:868`、`:1719`）；R4 报告 M4 实机 17/17 | **认为已处理**，不单列问题；需要时引用 `Tests/segments/render` 证据即可 |
| 原始 GPX 分段没有完整保留 | R4 已引入 `segmentID` + `TrackTopology`，`trkseg`/`rte`/`trk`/`wpt` 有独立段身份；剩余是"XML 扩展与节点顺序不保留"（归一化导入，文档已声明） | 性质变更，不按缺陷登记 |

> 结论：10-28 手记里的四项里，两项已被后续代码/验收覆盖，两项仍需定向复核。旧文档没有回写，读的时候要对照当前源码。

## 本次没有做的事

- 没有构建（`xcodebuild build`）或运行任何产品测试 / 探针。
- 没有请求 OSRM / Valhalla / Overpass，没有打开 app。
- 没有安装或覆盖 `/Applications`。
- 没有修改产品源码、测试期望值、`data/`。
- 没有 `git add/commit/push`。
- 唯一写入：`DeepSeek/` 下本文件、`issues.md`、`README.md`，以及 `AGENTS.md` 中新增的一行入口指引。

## 建议的下一步顺序

1. **N-02 + N-08**：先让 UI 测试能选中正确构建，再决定是否补跑全套。
2. **N-01**：向用户申请一次基线提交；这是其他改动可回滚的前提。
3. **N-03**：用户授权后安装最终构建，再跑 1–2 个定向脚本。
4. **N-06 + N-07**：一次只读定向审查，把两条 `review` 定性。
5. 其余 P1（N-04、N-05、N-09、N-10、N-11）按用户优先级排期；P2 可随手做（N-12、N-14）。
