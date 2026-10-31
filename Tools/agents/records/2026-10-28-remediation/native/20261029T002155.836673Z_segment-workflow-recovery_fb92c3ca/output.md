# P4-B 段工作流实施与恢复收尾

实施已冻结于 `/private/tmp/gpxpv-segment-integration-o3kf8civ`，未写回主工作区产品源码。本恢复任务只核对后台结果、补跑未执行的兼容验证并归档；原任务 `20261028T234103.668824Z_segment-workflow_e62fc474` 的原生模型 capacity 失败/partial 原件保留，没有倒填成功或换模型。请求模型为 GPT-6.1 Sol / ultra；服务端独立模型/强度回执、token、费用均 unknown/null。

本代理实际执行最终完整生产 Swift **202/202 断言通过**，冻结九产品文件哈希与该套测试输入完全一致。旧 114 门真实结果为 **110 通过、4 失败**，不改期待值；4 项均为多段输入，待主代理安排的独立语义真值核定。51 自测通过。125 考卷经归档 harness 一行段列迁移后全部完成、无原 baseline 回归，两路仍各 121/125，通过率与既有基线相同；API/公共路网请求为 0。最终产品 UI/三语截图、本地化装配及整个 P4 的验收归主代理，本报告不将 B 实施完成等同 P4 全部完成。

## 冻结产物

- `artifacts/after/GPXPointViewer/`：九个最终产品文件完整副本；`before/` 保留本次 P4-B 的实施前版本（包含已整合 R1/R2），不会把恢复开工状态当实施前状态。
- `artifacts/after/Tests/segments/workflow/`：新增 `WorkflowRegression.swift`、`run.py` 两文件。
- `artifacts/final-manifest.json`：9 修改、2 新增、0 删除的完整前后 SHA-256、大小与来源目录。
- `artifacts/segment-workflow.patch`：完整可审查 patch。
- `artifacts/final-tested-source-check.json`、`recovery-freeze-check.json`：九产品与最终 202 套输入匹配、全部 11 文件恢复收尾时未漂移。
- `artifacts/localization-keys.json`：新增 3、移除 3 的完整源键清单。
- `artifacts/workflow-final-202/`：最终实际编译的完整 34 产品 Swift、测试主程序、原 retime 对照副本、输入哈希、命令、stdout/stderr/退出码、Garmin 实际落地报告。

可复验入口为 `Tests/segments/workflow/run.py --source-dir <scratch>/GPXPointViewer --repository /Users/zyx/Documents/GPXPointViewer --evidence <新唯一证据目录>`。该脚本编译完整生产源码；测试副本仅去掉 App 的 `@main`、开放 TrackStore/UITestHook 私有方法访问。dense-tail 对照由同一生产 enum 删除本轮连续尾链检查后生成，不以手写模型代替生产实现。没有构造或启动 NSApplication，没有运行产品 app。

## 实施结果与接口

1. `SegmentColumn`、`SampleTrack`、`SegmentSamples` 提供共享数组的轻量段视图；检测、replay、jitter、profile、trip、context/heading/trace、frozen chain、retime 在 local 顺序中运行，边界统一映射一次 global。没有逐段重建完整 TrackData；单段保留数组 unsafe-buffer 快路。profile 兜底逐段计算，Trip 查找按 segment + pathRange 分组后二分。
2. `GapID(trackID, segment, a, b)` 替代 tA 身份；sampling/classify、批量选择/重取 owner、preview UUID、地图路径缓存和 UI 字典保持一致。JSON 的 `items[].id`、selected 是完整字符串；`batchdeleteonly` 接受精确输出 ID、原序号，并仅在唯一时兼容旧 tA。两个同 tA 段的操作不会串项。
3. `GapSplice.membership(to:job:)` 返回经核对的段、rank、inner、removed；`plan(to:jobs:) -> Result<ParsedTrack,Conflict>` 整笔验证 track owner、同段锚点、keep 子集、严格内部时间、同段重叠。跨段全局时间区间重叠可同时落地；非法作业整笔拒绝。预览、实际删除记录和落地共用 membership。App 使用 checked plan，兼容 `apply` 只供既有合法 harness 调用。
4. 所有新增、删除、retime、ParsedTrack、undo/精确会话基线、部分还原、preview/review 保留 segmentID。ChangePoint/完整位键/增量 PointKey 包含 segment。`GapFill.segment` 与按段 mergedWindows/segmentIndices 防止同时间、同坐标跨段串入 GPX/迷雾增量。CSV 保留平面时间顺序与同秒首点策略，距离/航向/速度使用本段前驱，段首归零。GPXWriter 的必要窄查询适配由主代理/A owner 负责，B 未抢改该文件。
5. PointMapView 给 C 的 LineParams 传源可见 mask，增加小数据 topology hook、接入 cached topologyDrawStats，取消旧“多日全部时禁线”启发式；来向/去向、内点粉色与地图缓存也按真实段归属。
6. 侧栏保留 290 pt 和固定两行 footer，内容限制 262 pt；颜色选项与显示开关在横向不足时改为两列，原字体/选项与辅助功能保留，避免过宽原生控件把整个面板中心向左挤出。实际 en/de/zh 截图由主代理整合后验证，本代理未冒称已看修后 UI。

## 连续出口 retime 与合并链修复

采用 Astra 批准的局部检查：旧投影、单调、新时间和 15–350 km/h 条件通过后，检查当前点到“下一实际 kept 或 B”的原位置与**改后 dt**，若既有 `isBreakStep` 为真则 `break`。未改 150m/20s/350km/h 边界、评分或非 stale 路径。被截掉的早期点作为 removed 记录，完整还原可恢复其原四列与段号。

真实原数据经过生产 fake route → landingJob/assessBatchItem → GapSplice → TrackData → computeCandidates → ChangeRevert：

| 项 | 新合成 | 改时 | 实际风险 | 原窗残余候选 |
| --- | ---: | ---: | ---: | ---: |
| 84 / tA 1792244850 | 169 | 3 | 10 | 0 |
| 97 / tA 1792256646 | 112 | 5 | 85 | 0 |

100 项来源身份逐项相同，其余 98 风险不变。没有给原先短前缀几何硬加分；完整插值覆盖恢复后再按实际落地点评估。正常密集出口与原生产 Plan 一致；single/manual、batch、preview 点数组位级一致。边界覆盖单出口到 B、跳过坏观察后的实际 kept、重复位置/改时、无时间、无本段出口速度、停车、非 stale、阈值等号、A 侧裁退、交叠另一段与原点还原。

主代理 followup-05 指出的机械 GapID 合并资格问题另有真实 Swift 反例：四个合格候选旧实现得到 `[2,2]`，修后为 `[4]`。`mergeChains.canMerge` 现在始终接收相邻两个**原候选**；单独维护 tail，cur 仅作聚合输出。每个原候选必须合格才延伸，稀疏/暂停候选不能跨过，同 tA 跨段不合并。证据在原 run `artifacts/merge-before-r3.*`、`merge-after.*`，三/四/混合链已并入最终生产测试。

## 验证归属与保留失败

- 本代理原首次 175/175、最终加强 202/202 是同一实施者的两阶段实际验证，最终数据含非零 replay/jitter/stale 真实合成 fixture 的双段对照，不以空候选作通过依据。
- 独立 Sol `20261029T001008.666518Z_segment-workflow-review_9b5a389a` 报告自写 29/29（15 行为 + 14 异步完成）及复跑 B 当时版本 183/183；这些属于独立审查者，未冒称由本代理撰写/执行。其 finish 因注册后共享文件并行变化被记录器强制 acceptance failed，原状态保留；该归属冲突不改写其 CLI 通过证据，交主代理核对。
- 本代理完整产品 typecheck exit0。开发阶段类型接线错误、harness 参数错误、无 app 的 hook 窗口空值崩溃及修复、旧模型 capacity 中断均在原 run 保留。未用后续通过覆盖失败产物。
- 旧 selftest 四套为 crosscheck31、portal8、tunnel5、plausibility7，共51/51，见 `remaining-compat/`。
- 原 114 门未通过：见 `legacy-114-original/114-results.json`。没有删除失败、改期望或把 110/114 报成 114/114。

| 旧门失败输入 | 实际段数 | 保留数据四列、只移除段列的反事实控制 | 新段模型实际结果 |
| --- | ---: | --- | --- |
| g13_multi_trk_seg | 5 | gap1且跨段、trips4 | gap0、trips5 |
| s1_device_1M_11d | 12 | trips48（旧期待） | trips61 |
| s3_merged_garmin_phone | 2 | gap2、trips1 | gap150，148个时间相邻腿在 global 中交错，trips2；旧global相邻 invariant 不适用 |
| s4_backup_3y_30s | 1576 | gap51364，含52个跨段 gap | gap51312 |

上述是实际生产 local kernel 与 flat-control 的观测证据，**不是自行核准新期望**。每段计数和数据位级相同检查在 `legacy-gate-audit/audit.stdout.txt`，独立语义核定与正式 harness 迁移归主代理。

旧 exam 首题 SIGTRAP 已留 `remaining-compat/exam.*`：synthetic 挖洞仅过滤四列，漏过滤 parser 新的非空 segmentID，违反数组同长前提。按恢复 followup-01，只在 `exam-harness-migration/compiled-source/exam.swift` 的既有 keep 旁同步 segmentID 一行，完整前后源码/hash/patch 保存；未改正式 exam、题、baseline、评分或产品。修后125题离线 replay exit0、baseline regression0；OSRM/Valhalla各121/125，artifact123/125、parallel125/125，requestsSent0/replayed255/missing0，与已有基线一致。

## 本地化与后续验收

新增：`无法应用补点：锚点或区间已改变，请重新选择。`；`若后续修改依赖此处，请一并还原相关修改。`；`轨迹线沿各段内的时间顺序连接；不同轨迹段不相连，超过 30 分钟或 10 km 的间隔断开；地球视角只显示点云`。

移除：旧“逐处还原其它修改不受影响”帮助、旧“多日全部禁线”帮助、旧“超过10km跨段直连”帮助。完整精确字符串见 localization-keys.json，主代理处理翻译与组装。

本任务没有 UI/app 启动、安装、外部模型 API、真实公共路网或额外子代理。9 产品 + workflow 2 源已正式冻结，无待继续修改的 B owner 代码发现；旧114四项仍需独立真值核定，最终三语 UI、Release/GPX端到端、DeepSeek闭环与验收由主代理处理。新恢复 run 按要求 provider succeeded / acceptance pending，原 capacity failed/partial 不变。
