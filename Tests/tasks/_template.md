# 任务：<功能名> · <日期>

## 背景（这次改了什么、为什么）
<两三句>

## 范围
- 要测：<列出>
- 不用测：<列出不受影响的部分及理由>

## 准备（完整写法，不要去翻以前的文档）
- 构建：`xcodebuild -project GPXPointViewer.xcodeproj -scheme GPXPointViewer -configuration Release build`，必须出现 `** BUILD SUCCEEDED **`。
  测的 app 由 `Tests/ui/ui.py` 的 `app_source()` 决定：环境变量 `GPXPV_APP` > DerivedData 里刚构建的 Release > `/Applications/GPXPointViewer.app`；报告里写清测的是哪份、可执行文件修改时间。
- 测试副本放 `Tests/ui/app.noindex/GPXPointViewer.app`（从上面那份整体复制）。**一次只开一个**测试副本；`/Applications` 里用户正在用的实例**不要 kill**，只 `pkill -f Tests/ui/app.noindex/GPXPointViewer.app`。
- 容器目录 `C=$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp`：钩子通信目录 `$C/uitest`；测试数据放 `$C/regions/`（`python3 Tests/ui/run_regions_stats_tests.py` 会自动拷入合成边界、合成轨迹和 `data/2026.fwdb`；
  其它数据自己拷：`cp data/Garmin_Roma_Da1.gpx "$C/regions/"`、`cp -R data/2026_fog_new_db "$C/regions/"`、`cp -R data/Sync_all "$C/regions/"`、`cp "data/backUpData-all 6.gpx" "$C/regions/backUpData-all6.gpx"`）。
- 启动测试副本（钩子 + 钉简体中文；用内置边界数据就不加 `GPXPV_REGIONS_BIN`）：
  ```sh
  pkill -f Tests/ui/app.noindex/GPXPointViewer.app; sleep 1.5
  mkdir -p Tests/ui/app.noindex && rm -rf Tests/ui/app.noindex/GPXPointViewer.app && cp -R /Applications/GPXPointViewer.app Tests/ui/app.noindex/
  open -n --env GPXPV_UITEST_DIR=$C/uitest Tests/ui/app.noindex/GPXPointViewer.app --args -AppleLanguages '(zh-Hans)'
  ```
  要合成边界就再加 `--env GPXPV_REGIONS_BIN=$C/regions/regions_synthetic.bin`。等 `python3 Tests/ui/ui.py state` 返回含 `points` 的 JSON 就是起来了。
- 发命令：`python3 Tests/ui/ui.py "cmd1" "cmd2" …`（每个参数一条，结果按行返回；`sleep 800` 这类是毫秒）。
- 本功能用到的钩子：`open <路径>`（GPX/CSV/存档目录）、`regions`（开地区统计窗口）、`regionsmode points|fog`、`regionstate`（JSON：index/regions/mode/modes/selection/highlightPolys/ready/totals/countries 嵌套，节点含 name/localizedName/level/iso/points/days/timed/cells/km2/lv/areaKm2/childTotal/children）、
  `regionselect <id>|off`、`regionlookup <lat> <lon>`（返回 `id:名 < 父 < 国`）、`fogstats`（迷雾统计卡 JSON）、`set fogMap 0/1`、`set heatMap 0/1`、`windows`、`info`、`shotview <png绝对路径>`、`shotviewwin <标题子串…> <png>`、`state`。
- 同一副本里再 `open` 第二个存档会取**并集**（多存档勾选是功能），要测单档数字就用新副本。
- **锁屏提示**：`python3 Tests/ui/ui.py info` 里 `front=loginwindow` 表示屏幕锁着：`shotwin`/`shot` 全白、MapKit 相机动画不走、`shotviewwin` 只有布局块（文字常渲不出来）。遇到就写进「没做到的项目」，**不要当作功能失败**。

## 测试项（每项给命令 + 期望）
1. <名称> — 命令：`…` — 期望：`…`
2. …

## 报告要求（完整写法）
- 每项：做了什么命令、关键输出（JSON 可只抄相关字段）、通过/失败。数字原样抄录，不要四舍五入。
- 失败或任何不符合预期的地方：现象、**精确到命令和参数的复现步骤**、期望 vs 实际、相关日志（`$C/uitest/log.txt`）/截图路径。
- 没做到的项目写清原因（锁屏、网络、数据缺失、权限等）。
- 不要为了变绿改期望；不要安装到 /Applications；不改任何代码或测试脚本。
- 最后一句话结论：可以发布 / 需要修复 N 处。
