# 任务：三处界面文字截断修复（德文顶栏按钮 / 英文「Basemap」标签 / 补点模式「打开 GPX」）· 2026-10-26

## 背景
GPXPointViewer（macOS SwiftUI + MapKit，仓库根目录就是当前目录；四语本地化：zh-Hans 为源语言、中文原文即键，en/de/zh-Hant 翻译在 `Tests/l10n/translations/chunk_*.json`，由 `Tests/l10n/assemble.py` 组装进 `GPXPointViewer/Localizable.xcstrings`）。
刚修完底图控件撑爆图层面板的问题，顺带发现三处**原有**的文字截断，用户要求修掉。都是布局/文案问题，不涉及功能逻辑。
自测钩子与截图办法见 `Tests/README.md` §2.2–§2.5、§3（必读）：测试副本放 `Tests/ui/app.noindex/`，用 `open -n --env GPXPV_UITEST_DIR=<容器 uitest 目录> <副本.app> --args -AppleLanguages '(de)'` 指定语言启动；钩子 `shotwin <标题子串> <png 路径>` 截某个窗口（标题按当前语言，主窗口 zh-Hans「GPX 点位查看器」/ de「GPX-Punktbetrachter」/ en 用 `grep -n "GPX 点位查看器" Tests/l10n/translations/*.json` 查英文译名）；`review` 钩子打开修改记录窗口；`fill` 进入补点模式。截图 png 先 `sips -s format jpeg -s formatOptions 80 -Z 1600 in.png --out out.jpg` 再用 Read 看 jpg（**不要 Read 原始 png**）。

## 三处问题与要求

1. **德文下修改记录窗口顶栏按钮截成省略号**（`GPXPointViewer/ChangeReviewWindow.swift` 顶栏：「看已落地的记录」「看落地前预览」「返回批量窗口」「落地 N 处…」等按钮，德文如 "Zurück zum Stapelfenster"、"100 Lücken übernehmen…" 在窗口 1000–1160 pt 宽时被截断）。还有补点模式下主窗口右上角候选面板的分段「断档候选：全部 | 公路 | 疑似铁路」在德文下（"Lückenkandidaten: Alle | Straße | Vermutlich Bahn"）超出窗口右边（`GPXPointViewer/ContentView.swift`，`grep -n "疑似铁路" GPXPointViewer/ContentView.swift`）。
   - 做法任选其一或组合：缩短德文（和英文）文案（改 `Tests/l10n/translations/` 里对应键的 `de`/`en` 值，例如 "Zurück zum Stapel"、"Übernehmen (100)…"、"Vermutl. Bahn"）；把导航类按钮收进一个菜单；给分段控件加 `.fixedSize()` 以外的自适应（如 `labelStyle`/图标 + 文字）。**结果要求**：窗口在最小宽度（修改记录 1000 pt、主窗口 960 pt）下，zh-Hans / en / de 三种语言都没有省略号截断、没有超出窗口。
   - 改了 chunk 文件后必须重新组装：`python3 Tests/l10n/assemble.py <keys.jsonl> Tests/l10n/translations .`——keys.jsonl 用上一次导出的（`ls -t /private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/scratchpad/l10n_api*/ Tools/agents/runs/*/l10n_api4/ 2>/dev/null` 找最近的 `keys.jsonl`；找不到就按 Tests/README.md 第 410 行附近的流程重新导出一次）。组装输出必须 `missing 0 / specifier problems 0`。
2. **英文下主窗口图层面板的滑杆标签「底图」（en "Basemap"）在固定宽度里折成 "Basema / p"**（`GPXPointViewer/ContentView.swift`，`grep -n "底图" GPXPointViewer/ContentView.swift` 找滑杆标签那行，有固定 `.frame(width:)`）。做法：标签列宽按最长标签自适应（用 `fixedSize(horizontal: true, vertical: false)` 或 `.frame(minWidth:)`），或把英文改成 "Map"。三种语言都不能折行到字中间。
3. **补点模式下主窗口第一行「打开 GPX」被截成「GPX…」**（补点模式顶行多了按钮，宽度不够；`grep -n "打开 GPX" GPXPointViewer/ContentView.swift`）。做法：空间不够时该按钮退化为只显示图标（`help` 保留全名），或把补点模式的额外按钮换行。三种语言都不能出现省略号。

## 验证（都要做，写进报告）
1. `xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build` → `** BUILD SUCCEEDED **`。
2. 三种语言各启动一次测试副本（zh-Hans、en、de），每种语言截：主窗口普通模式、主窗口补点模式（先 `open` 容器里的 `Garmin_Roma_Da_copy.gpx`，再钩子 `fill`）、修改记录窗口（钩子 `review`；最好先把窗口缩到最小宽度：若钩子有 `frame`/窗口尺寸命令就用，没有就记录实际宽度）。用 Read 看 jpg，逐张写结论；有截断就继续改。截图放 `Tests/reports/ui_truncation_shots/`。
3. 回归：`python3 Tests/ui/run_map_sources_tests.py`、`python3 Tests/ui/run_batch_review_tests.py`、`python3 Tests/ui/run_fill_tests.py` 末行都要 `FAILS: none`（各自会起副本；一次只跑一个）。
4. 收尾：`python3 Tests/ui/ui.py "set mapStyle 标准" "reviewmap standard light 1" "exit"`，`pkill -f app.noindex`。语言只通过启动参数指定，**不要用 `setlang` 钩子**（它会改容器偏好、影响用户正在用的 app）。

## 硬规则
- 允许改的文件：`GPXPointViewer/ContentView.swift`、`GPXPointViewer/ChangeReviewWindow.swift`、`Tests/l10n/translations/chunk_*.json`（只改 en/de/zh-Hant 译文，不改 key）、`GPXPointViewer/Localizable.xcstrings`（只通过 assemble.py 生成）。需要改别的文件先在报告里说明理由再改。
- 不安装到 /Applications、不动 /Applications 里的 app（只 `pkill -f app.noindex`，不要 `killall GPXPointViewer`）、不联网、一次一个 xcodebuild。
- UI 文案禁词：待审核 / 报警 / 冲突 / 已验证 / 失锁。
- 做不到的项目如实写「没做到」和原因，不要把截断留着却说修好了。
