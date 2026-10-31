# R4 视觉补拍与精确窗口偏好清理

本入口只准备四张缺失的有效截图，以及清理测试遗留的一个窗口位置键。实现由 GPT-6.1 Sol / ultra 执行，实际服务端模型/强度、费用和 token 回执未暴露。实现与 mock 不构成真实视觉验收；主代理须独立审查代码，再授权后续 DeepSeek Flash/max 执行。

原 final run `20261029T011600.159549Z_r4-final_fa1fd007` 的 prep 和 11 个 UI 回归通过。剩余 run `20261029T112901.777425Z_r4-remaining_d3ab729e` 的十一阶段实际结果全部通过，但 runner 的 provider 终态因 `multiple final results` 仍为 failed，这两层事实分别保留。四张旧截图前台为 loginwindow，全黑，不能作为产品像素验收。

## 两个固定命令

每次通过 agent_run 创建唯一新 run。`GPXPV_AGENT_RUN_DIR` 必须由 runner 提供，指向存在 task.md/meta.json、artifacts 为空的新目录。命令执行后不复用该 run；恢复/重试另建 run，保留旧证据。

只恢复前轮遗留窗口位置，可以锁屏执行，不启动或关闭任何 app，也不调用 UI：

```sh
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/driver.py restore-window
```

等用户解锁后，重建必要场景并补拍四图，最后做原 cleanup 和精确窗口键恢复：

```sh
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/driver.py run
```

`run` 仅执行原 driver 的 sec2、sec5 zh-Hans/en/de 与 cleanup 五个阶段；前四项为重建截图场景所必需的原断言/假路由操作。阶段名加 `visual_` 前缀，避免覆盖导入结果。不会重跑 11 UI、synth、自测、sec3、sec4、sec6 或 docs。五阶段预算合计 3,400 秒，保留原命令和阶段预算，外层时限需留足余量；预算不是完整命令的硬上界。后台命令使用正规通知等待机制，不让模型用 sleep/轮询等待。

新 run 的 `artifacts/visual-closeout-summary.json` 与单键恢复 `artifacts/preferences/restore_<id>.json` 是给执行代理读取的精简回执，只包含目标键/允许窗口值、结果、哈希和本地证据路径，**不含其他偏好值**。完整偏好与 defaults 导出仅在本地 artifacts 保存；DeepSeek 不得读取/上传这些完整文件。可在同一收尾 run 中先运行 restore-window，再运行经主代理批准的 fixture 标签更新脚本；后续脚本应使用其独立 artifacts 子目录，不再次调用本 helper。

## 继承、锁屏和像素

bootstrap 只读核验原恢复入口的固定哈希、原 50 个 source 输入、指定 executable SHA256 `445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`、原 prep/11 UI 和剩余十一阶段的结果与原始断言。23 个继承 phase 均标 `imported=true`、`executed_in_this_run=false`、`origin_run`、`original_phase_id`。原 prep/PID/prefs 直接沿用，不建立新基线。拒绝旧/原 run、其祖先/后代、有旧结果或非空/symlink artifacts 的目录。

`run` 在任何测试副本启动、复制、终止或 UI 操作前，先用只读 AppKit/NSWorkspace 查询前台进程。loginwindow、屏保或未知前台会明确 blocked、返回 75，零 UI、零 kill、零偏好写入。执行中每次 UI 命令、launch/open 也先查询前台。原 `shotwin` 仅从本进程 `NSApp.windows` 中按可见/标题匹配取得 window ID，再通过 `CGWindowListCreateImage(.optionIncludingWindow)` 捕获该窗口；Safari或Harness等其他正常 app 在前台仍允许，不要求整台Mac被GPX独占。原窗口捕获命令和调用保持不变，图像仍由主代理验像素。若中途锁屏，停止其余截图，finally 不通过 UI 重新启动 app，只关闭固定测试副本路径并尝试安全单键恢复，清理未完成如实列出。不会解锁屏幕、安装到 /Applications、关闭正式 app 或访问公共路网。

PNG 存在、命令返回 0、窗口尺寸正确都不能替代像素审核。summary 始终 `acceptance_status=pending`、`visual_verdict=PENDING_MAIN_AGENT_PIXEL_REVIEW`，主代理须查看标签重叠、三语言底部两行、遮挡、字体与省略号。即使自动步骤成功，尚未验图也不叫视觉验收通过。

## 精确单键恢复的边界

唯一允许通过 defaults 写入的路径是 `/Users/zyx/Library/Containers/de.wayne.GPXPointViewer/Data/Library/Preferences/de.wayne.GPXPointViewer.plist`，唯一 key 是：

```text
NSWindow Frame SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<GPXPointViewer.ContentView, SwiftUI._FlexFrameLayout>, SwiftUI._AppearanceActionModifier>-1-AppWindow-1
```

原 prep 中基线必须逐字等于 `60 21 1320 860 0 0 1440 903 `。遗留测试值必须逐字等于 `1320 -740 1320 860 0 0 1440 903 `，并由剩余 run 已留存、哈希一致的 after 证明。原正式 PID 基线必须为空，当前任何路径的 GPXPointViewer executable 都必须不在运行。只读 `/bin/ps -axww -o pid=,comm=` 只取 PID 与 executable name/path，不取 args/env，逐行解析后精确匹配 basename=`GPXPointViewer`；/Applications、DST、固定 build 或其他副本任一匹配都拒绝恢复，不终止它。命令失败、超时、空输出、记录无法解析或重复 PID 均保守拒绝。完整进程名列表只留本地 command log，摘要仅保留筛选后的匹配。不会把 runner 的 `--cwd /Users/zyx/Documents/GPXPointViewer` 参数误当 app；旧 `pgrep -f` 全 argv 规则的这一误报及修复另有独立 run 归档。

单独 restore-window 只接受基线或该已知遗留值。run 的最终恢复还可接受本轮受控 frame/place 操作后，通过成功坐标回显与 CFPreferences/磁盘一致快照明确记录的精确 after 值；不接受任意“刚刚读到”的值。缺键、类型变化、其他窗口位置、原备份变化、应用在运行、读写间漂移都会 fail closed。

正确接口依据本机 Apple defaults(1) 手册的 filepath 域与单键 `-string` 写法：

```text
/usr/bin/defaults write <上述完整plist路径> <上述完整key> -string <原基线含尾空格>
```

所有参数通过 argv 传递，无 shell 拼接。`defaults export <同一绝对域> -` 读取 CFPreferences 视图，再用 plistlib 独立读取磁盘；两者及读前/读后的 typed plist 必须一致。写前再次检查完整偏好与进程，写后再次核对 CFPreferences/磁盘的键值以及**其他全部键和值与写前相等**，包括类型区别（True 与 1 不混同）。不用直接写 plist、不整域 import、不删除任何键、不 kill cfprefsd、不覆盖或回滚其他键。已经是基线时只读 no-op，也留 before/after 回执。

原 UI cleanup 仍用于复位其测试开关；精确 defaults 恢复是其之后增加的独立一步。run 开始前，其他键须与原 prep 基线一致，避免原 cleanup 复位用户后来修改的偏好；结束检查其他键与本轮开始一致。失败时不通过修改其他键来伪装成功。SIGKILL、掉电或其他工具在最后检查与单键写之间同时修改偏好，不能由无原子 CAS 的 defaults 保证排除；写后完整核对若发现漂移则失败并保留证据，不覆盖其他键补救。

## 离线验证与回执

```sh
python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/test_driver.py
```

仅在本目录内 `.offline-fixture-*` 建临时样本，全部进程/UI/defaults 接口 mock，结束删除临时样本。不会运行真实 app/UI/API、修改真实偏好或改原 helper/pinned 文件。完整测试输出、实现前后哈希/副本/新增清单、patch 和只读归档 preflight 见本实现 native run。实际服务端模型、token、费用未知保持 null。

每个实际 phase 沿用原恢复入口的完整 command 日志和独立 attempt；最终 summary 记录继承数量、本轮新阶段、未执行项、锁屏门禁、窗口恢复与完整性。返回 0 表示本模式自动步骤通过，1 表示失败/不完整，2 表示配置拒绝，75 表示锁屏/前台阻塞，显式信号为 128+signal。主代理独立验收仍是 pending。
