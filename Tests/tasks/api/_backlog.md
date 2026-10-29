# Claude API 任务待办（已记录、未启动）

记录日期 2026-10-25。用户要求：先记下来，不要启动。额度：订阅附带的 $100 API 额度，**2026-10-28 到期**，
台账 `~/.claude/projects/-Users-zyx-Documents-GPXPointViewer/saved-agent-results/api-runs/LEDGER.md`（2026-10-25 19:20 累计 $5.42，脚本上限 $96）。
不买额度；到期后不再用 Claude API。

启动方式（每项都要先在 AGENT_LOG.md 写「计划」）：
```bash
Tools/agents/api_run.sh <名> Tests/tasks/api/<任务书>.md --model claude-opus-5-5 --budget <美元> [--write]
```
记录自动落在 `saved-agent-results/api-runs/<时间>_<名>/`（task.md / transcript.md / progress.md / changes.diff / output.md / result.json）；
中断后 `--resume <该目录>` 续跑。任务书要完整自洽（输入文件、期望产出、禁止事项），不能写「同前」。

## ① Opus 对抗复审：断档补点 / 批量补点 / 路网
- 目的：对 `GPXPointViewer/GapFill.swift`、`BatchFill.swift`、`RoadNetwork.swift`、`TrackStore.swift` 补点相关段落做一次独立的对抗式审查（正确性、边界、并发/取消、UI 状态一致性），每条发现附复现输入。
- 权限：只读（不 --write）；不联网（不要碰 FOSSGIS OSRM）；不构建。
- 产出：`output.md` 按严重度列发现 + 复现步骤；主会话逐条核实后再修。
- 预算：$15–25（文件约 1 万行，Opus 读全量 + 多轮推理）。
- 参考：之前的工作流复审 verify-gap-fill-8…13 的结论在 AGENT_LOG.md，避免重复已确认/已驳回的条目（任务书里要把这些列出来）。

## ② Opus 当「全应用测试员」
- 目的：用 UITestHook（`GPXPV_UITEST_DIR` 环境变量 + 沙盒容器通信，见 `GPXPointViewer/UITestHook.swift` 和 `Tests/ui/ui.py`）驱动 Tests/ui/app.noindex 的测试副本，像用户一样走一遍主要功能：打开 GPX/CSV、三种模式、找不同、补点、批量补点、修改记录、导出、地区统计、语言切换（钩子 setlang + relaunch），记录异常与可用性问题。
- 权限：只读代码；允许运行钩子/脚本；**一次只跑一个测试副本**；结束必须 `setlang system` 或恢复用户原语言（容器 plist 与 /Applications 共用）。
- 产出：`output.md`（问题清单 + 截图路径 + 复现命令）。
- 预算：$10。

## ③ en / de / zh-Hant 界面文案审校
- 目的：通读 `Tests/l10n/translations/chunk_*.json`（933 键）与 `GPXPointViewer/Localizable.xcstrings`，找术语不一致（如 app/App、Nebel/迷雾、工作階段/會話）、语法错误、占位符顺序、过长文案；给出逐条修改建议（不直接改 xcstrings，改 chunk 后由 `Tests/l10n/assemble.py` 组装）。
- 权限：可 `--write`，只允许改 `Tests/l10n/translations/*.json`；改完由主会话跑 assemble.py（期望 missing 0 / specifier problems 0）并重建。
- 产出：changes.diff + `output.md` 变更说明。
- 预算：$5。

## 界面待办（2026-10-26 记录，暂不做；用户决定何时做）
- **【已做 2026-10-27 Opus，`Tests/tasks/api/2026-10-27_*plausibility-ui*`：底行 ViewThatFits 三档 图标+文字 / 只文字 / 只图标（help 带全名），「退出」fixedSize；截图 Tests/reports/plausibility_ui_shots/】** 主窗口 290 pt 控制面板最底一行「导出 / 图片 / 删除点 / 补点」在德文下截成 `Exp… / Pun… / Lüc…`，简中也有 `删… / 补…`；补点底栏「退出」在简中截成 `退…`。要修得重排整行（图标 + 悬停全名，或两行），可能影响 800 pt 高度布局。
- **【已做 2026-10-27 Opus：补点模式性能面板收成一行（点 ⌄ 展开）、堆在右列候选面板下面；右列停在底部操作条上面，候选列表自己缩短】** 补点模式下右侧候选面板底部的说明文字与右下角性能面板重叠（窗口高 800 pt 时）；性能面板可以默认收起或挪到左下。
- 修改记录窗口 de/en 顶栏已改两行；若以后再加按钮要先量宽度（最小 1000 pt）。
来源：Tests/reports/20261026_1749_2026-10-26_ui_truncation_fixes.md「没做到的项目」。
- **【已做 2026-10-27 Opus】** 单处卡片高度按内容算（原固定 300、下方约 50 pt 空白）：`onGeometryChange` 实测卡片高度 + 标题栏，见 docs/batch-review-design.md「卡片高度按内容算」。来源：上一任务（单处卡片）报告。
- **【已做 2026-10-27 Opus】** 修改记录翻页时主地图跟随：详细页「主地图跟随」勾选框（偏好 reviewFollowMap，默认关），见 docs/batch-review-design.md「修改记录翻页时主地图跟随」。来源同上。
- **【已做 2026-10-28 Opus loose-ends：左面板在补点模式下停在底部操作条上面（padding = 底部浮层高度），放不下时整块 ViewThatFits 换成可滚动；截图 Tests/reports/loose_ends_shots/】** 补点模式、窗口高 800 pt 时，横贯底部的补点操作条盖住左侧控制面板最底一行（导出/图片/删除点/补点 与「修改记录」）；德文、英文明显，简中「修改记录」被盖一半。控制面板不可滚动，要修得让面板可滚动或让操作条避开左面板。截图 Tests/reports/plausibility_ui_shots/main_fill_de.jpg。

## 2026-10-28 文档刷新后仍待处理

> 来源：`Tests/reports/20261028_1201_2026-10-28_feature_ideas.md`（DeepSeek 建议书）§4 / P1–P5，以及 2026-10-28 文档刷新任务核对时发现、但不属于该任务（该任务只允许改 README / regions 设计 / Tests/README / 本文件）的点。以下按工作区现状复核过；已完成或已被后续任务修掉的条目不再列。

- **地区数据已知未修**（照抄建议书描述并补文档出处）：阿鲁巴首府点落在多边形外（CGAZ 自有的阿鲁巴多边形太粗，下次构建改用宗主国切出来的）；NE `name_zh` 夹带繁体字（下萊茵、日內瓦、戈里齊亞）；「佛罗伦斯省」应为佛罗伦萨；意/法/英一级粒度与世界迷雾不同。来源：建议书 §4「地区数据已知未修」与 P2；`docs/regions-design.md`「属地 / 飞地 / 缝的规则」末段（另列北塞浦路斯海岸 500 m 带归塞浦路斯、马祖缺连江县、圣马力诺城判到博尔戈马焦雷）。
- **`Tests/README.md` 的 19 vs 25 不一致**：§1 与 §3.2 仍写 run_suite 跑 19 个脚本，§3.6 标题写 25 个，`Tests/ui/run_suite.sh:19-20` 实际列 25 个。建议统一按实际列表计数。来源：建议书 P1；本次只按任务要求改了 §5 历史探针那一段。
- **QuickLook 源码头注释与实现不一致**：`GPXQuickLook/PreviewViewController.swift:6` 说超大文件 >48MB 降级，实际 `fullParseLimit` 是 32 MB（`:18`）；README 已按实际行为改成 32 MB，源码头注释待改。
- **`Tools/build_regions.py` 顶部用法注释过期**：docstring 的用法示例只写 `--countries/--admin1/--china-dir/--out`，没有 CGAZ 换源用的 `--countries-geom` 与 `--tolerance-m-l0`；实际 argparse 已支持，`Tools/fetch_regions_data.sh` 末尾的构建命令才是当前正确用法（已同步到 `docs/regions-design.md`「换源 / 重建」）。源文件不在本任务允许修改的范围。
- **两份设计文档内部仍有「未做」残留**：`docs/cross-check-design.md:94` 的「未做（记录）」仍列三项（同文档 :103 已划掉并注明 2026-10-28 已做）；`docs/fill-plausibility-design.md:31,51` 的 `tunnelShare` 仍写「本期恒 nil / 本期不扣分」（同文档 §7 与 `GPXPointViewer/FillPlausibility.swift:55` 已实现 OSRM 有值）。建议统一改成已做/现状。来源：建议书 P4 与当前代码。
- **全量 UI 回归的 `run_regions_stats_tests.py`**：建议书 P1 列了 7 个漏跑的脚本；2026-10-28 当前 `run_suite.sh:19-20` 已包含 tunnel_fix / crosscheck / batch_review / batch_card / route_cache / map_sources 六个，`run_regions_stats_tests.py` 仍不在全套（它自己起测试副本）。请决定加入全套，或在 Tests/README 明确列为“不在全套”。来源：建议书 P1。
- **中国大陆 GCJ-02 未实现**：`GeoCoord.mapToData/dataToMap` 仍恒等（`GPXPointViewer/GapFill.swift:18-22`），中国大陆 Apple 底图为 GCJ-02，WGS-84 轨迹在显示/拾取/草稿层会整体偏移；导出数据不受影响。来源：建议书 P3。
- **`.fwdb` 时光机时间线是近似**：`FogArchive.genTimes` 只有区块同步时间，不是逐格真实时间（`GPXPointViewer/FogArchive.swift:26-30`）。做年度回顾/时间线时要在界面说明“近似”。来源：建议书 §4。
- **`FogArchive` 只读**：能导入/统计/渲染 `.fwdb`，没有写回或导出格子的入口；建议在文档明确“永不写回”。来源：建议书 §4 的合理边界。
- **API 额度 2026-10-28 到期**：本文件开头记录的 $100 额度今天到期，②「全应用测试员」与③「en/de/zh-Hant 审校」仍未启动；到期后不再用 Claude API。来源：本文件开头与建议书 §4。

