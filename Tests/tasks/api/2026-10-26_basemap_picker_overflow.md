# API 任务：底图分段控件撑爆图层面板（文字超出边界）修复

记录日期 2026-10-26。模型：claude-opus-5-5。权限：`--write`（改源码、xcodebuild、跑离线测试）。**不联网、不安装到 /Applications、一次只跑一个 xcodebuild 和一个测试副本。预算很紧（≤ $5），不要开子 agent，不要做无关重构。** 用中文写 output.md 与进度。

## 0. 现象（用户截图 `/private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/userfb/fb_50.jpg`，用 Read 看）

GPXPointViewer（macOS SwiftUI + MapKit，仓库根目录就是当前目录）。刚做完「底图来源」功能：`BaseMapStyle` 从 3 项（标准 / 卫星 / 混合）扩到 6 项（+ OpenStreetMap / OpenTopoMap / Esri 影像），实现见 `docs/map-sources.md`、新文件 `GPXPointViewer/MapSources.swift`。
用户一打开 app 就看到主窗口左侧图层面板**整体向左溢出**：第一行「打开 GPX」左边被裁、「海拔 | 时间 | 单色」只剩「拔 | 时间 | 单色」、「卫星 | 混合 | OpenStreetMap | OpenTopoMap | Esri 影像」这一行右端伸出面板之外、面板里其它行的左边也都被裁掉几个字。
根因（推测，请核实）：6 段的 segmented Picker 固有宽度 > 面板宽度（约 220 pt），SwiftUI 把超宽子视图居中放置，整个 VStack 被撑宽后两侧被裁。同样的 6 段控件还接到了：修改记录窗口顶栏（`GPXPointViewer/ChangeReviewWindow.swift`，与「浅色」「看已落地的记录」「返回批量窗口」「落地 N 处…」同一行）、对比双栏 / 找不同窗口（`GPXPointViewer/DiffWindow.swift` 或 map-sources 任务接的位置，`grep -n "BaseMapStyle" GPXPointViewer/*.swift` 找）。

## 1. 要做的

1. 主窗口图层面板（`GPXPointViewer/ContentView.swift` 里底图 Picker 的位置，`grep -n "mapStyle" GPXPointViewer/ContentView.swift`）：改成**两行**——第一行仍是 Apple 三段「标准 | 卫星 | 混合」；第二行外部底图三段，用短标签「OSM | OpenTopo | Esri」（`help` 工具提示给全名：OpenStreetMap 标准 / OpenTopoMap 地形 / Esri 世界影像），或者改成一个 `.menu` 样式的 Picker 显示当前来源——两种任选，但**必须在面板宽度内放得下，并且在 de（德语文案最长）和 en、zh-Hant 下也放得下**。面板里任何一行都不得超出面板宽度（给面板内容加 `.frame(maxWidth: .infinity, alignment: .leading)` 并检查没有别的固有宽度超宽的行，例如「无缝进入地球视角，放大自动返回」提示要允许换行）。
2. 修改记录窗口顶栏：窗口最小宽 1000 pt，6 段 + 4 个按钮放不下时同样处理（Apple 三段 + 外部来源菜单，或整体改菜单）；`reviewmap <style>` 钩子行为不变。
3. 对比双栏 / 找不同窗口：同样检查，最小宽 700 pt。
4. 截图验证（屏幕现在是解锁的）：起测试副本（`Tests/README.md` §2.5；默认通信目录 `~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest`），分别用 `--args -AppleLanguages '(zh-Hans)'`、`'(de)'`、`'(en)'` 启动三次，每次用钩子 `shotwin GPX <png>`（主窗口；窗口标题在 de/en 下不同，shotwin 的标题参数用本地化后的标题子串，见 `UITestHook.swift` 的 `case "shotwin"`）与 `shotwin 修改记录 <png>`（先 `review` 钩子打开窗口；标题同样按语言）截图，用 Read 看图确认没有裁切/溢出；把 png 转成 ≤0.6 MB 的 jpg 再 Read（`sips -s format jpeg -s formatOptions 80 -Z 1600 in.png --out out.jpg`），**不要 Read 原始 png**（运行器缓冲会撑爆）。截图存运行目录。
5. 回归：`xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` BUILD SUCCEEDED；`python3 Tests/ui/run_map_sources_tests.py`（M1–M4，`FAILS: none`）；`python3 Tests/ui/run_batch_review_tests.py`（`FAILS: none`）。
6. 新增/改动文案走本地化：`xcodebuild -exportLocalizations …` → `python3 Tests/l10n/extract_keys.py <export dir> <out dir>` → 新键写进下一个未用编号 `Tests/l10n/translations/chunk_NN.json`（格式照 `chunk_23.json`）→ `python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`（missing 0 / specifier problems 0）→ 重建。只改了标签的话优先复用现有键。
7. 结束：`python3 Tests/ui/ui.py "set mapStyle 标准" "reviewmap standard light 1"`，`pkill -f app.noindex`。

## 2. 产出与硬规则
- `output.md`（中文）：改了什么、三种语言的截图路径与结论、脚本末行原文、构建结果。
- 不安装、不动 /Applications、不联网（副本默认 faketiles 不出网）、不回退工作区里其它改动、不开子 agent。
- 进度随时写 progress.md。
