# API 任务：写 DeepSeek 第 2 轮测试任务书（路网缓存 / 两路切换 / 隧道补点修正）

记录日期 2026-10-26。模型：claude-opus-5-5。权限：**只读**（不改仓库文件、不构建、不跑 app、不联网）。产出只写进运行器给你的运行目录：`deepseek_task.md`（任务书正文）和 `output.md`（一句话说明）。用中文。

## 0. 背景

GPXPointViewer（macOS，当前目录是仓库根）。项目用 DeepSeek 做机械化测试：主会话写一份**自洽**的任务书放 `Tests/tasks/<日期>_<名>.md`，`Tests/run_deepseek.sh` 把它交给 DeepSeek（只读 + 可运行命令，不能改代码），报告落 `Tests/reports/`。
任务书的写法与硬规则**必须照搬** `Tests/tasks/2026-10-26_batch_review_r1.md`（上一轮，读全文：背景 / 范围 / 硬规则 / 准备（完整写法）/ 逐项步骤 / 报告格式）。禁止写「同前」「见上一轮」；每条命令完整可复制；期望值要具体数字。

本轮要测的三块改动（都在工作区，已构建、已装到 /Applications；DeepSeek 测 `/Applications/GPXPointViewer.app`）：
1. **路网结果缓存 + 重新获取 + 修改记录两路切换**：实现说明在 `docs/batch-review-design.md` 末尾「路网结果缓存」「两路切换」两节；钩子与期望见 `Tests/ui/run_route_cache_tests.py`（D0–D6）；README「断档补点（隧道）」段。
2. **隧道补点修正**：诊断报告 `Tests/reports/20261026_1500_tunnel_diagnosis.md`（§7 列了改什么），实现说明 `docs/cross-check-design.md` 末尾四节（后处理伪影修正 / 冻结假点链 / 过时点保留改时 / 短断档门槛 V1）；钩子与期望见 `Tests/ui/run_tunnel_fix_tests.py`（T0–T7）、`Tests/synth/runner/main.swift` 的 `--portal-selftest`、`Tests/synth/check_garmin_tunnel.py`（若存在；否则看 `Tests/synth/` 下同名脚本）。
3. 相关回归脚本：`Tests/ui/run_batch_review_tests.py`、`run_crosscheck_tests.py`、`run_route_cache_tests.py`、`run_tunnel_fix_tests.py`、`run_fill_tests.py`、`run_profile_tests.py`（P2 期望已改为 100）、`Tests/synth/runner/run_all.sh`（114 文件）。

钩子总说明：`Tests/README.md`（§2–§3，含「依赖已起副本的脚本要各自新起副本」规则）和 `GPXPointViewer/UITestHook.swift`（`case "…"` 列表；新钩子：routecache、batchrefetch、routerefetch、reviewdraft、pointat、pointfind、selectnear、reviewrevert 等——以源码为准）。测试数据：`data/Garmin_Roma_Da_copy.gpx`（97 处候选的常规数据）和 `data/compare/Muenchen_Roma_Garmin.gpx`（33,496 点；要拷进容器 `$HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/`）。

## 1. 任务书要包含

- 背景（这次改了什么、为什么，3–6 行）；范围（要测 / 不用测）；硬规则（照搬上一轮：离线、`autotripmap 0`、`fakeroute`、一次一个副本、不 kill /Applications 实例、结束复位偏好 `crosscheck 0` `fakeroute all off` `reviewmap standard light 1` `fillpoints 0`、锁屏截图全白）。
- 准备：测的是 /Applications 那份（`GPXPV_APP` 不设、DerivedData 已删，`app_source()` 会落到 /Applications），记录可执行文件修改时间；副本放 `Tests/ui/app.noindex/`；容器目录与数据拷贝命令完整写出。
- 逐项步骤（每项：命令 → 期望 → 怎么算通过），至少覆盖：
  1. 先跑 7 个脚本（各自新起副本的要分别起），末行 `FAILS: none` 为通过；`run_all.sh` 期望「114/114」。
  2. 缓存：精确模式假引擎跑第 2 步两次，`requestsByHost` 第二次不变、`cacheHits` = 公路项数；`batchrefetch all` / `batchrefetch <i>` 的请求计数变化；换文件后 `routecache stats` 的 entries 为 0；单处 `routecross` 两次 + `routerefetch`。
  3. 两路切换：`batchreview` 进预览、`reviewdraft valhalla|osrm|next`、`reviewstate.shownDraft`/`sameGeometry`；`fakeroute valhalla offset 30` 后重取 `sameGeometry` 为 false。
  4. 隧道修正：用 Muenchen_Roma_Garmin：候选数 50（原 44）；`selectnear 46.503401 11.457193` 后 anchorA 9728 / anchorB 9734；`route car` → 确认框 retimed 1；落地后 `pointfind`/`pointat` 看 9733 时间 23:12:21 ±1 s（UTC）、`reviewstate` 的 retimed 1 / removed 4；`reviewrevert` 回原值。具体命令参数按 `run_tunnel_fix_tests.py` 里的写法抄。
  5. 手工走一遍用户路径（不靠截图判对错）：批量窗口右键「重新获取这一处」、第 2/3 步「重新获取全部…」确认弹层、修改记录详细页的 OSRM | Valhalla 分段、「两路几何完全相同」提示——用钩子 `shotviewwin` 或 state 字段确认存在即可。
- 报告格式：每项 ok/FAIL + 原文输出；结论「可以发布 / 不可以」+ 产品缺陷数；DeepSeek 发现任务书本身的问题也要列出。

## 2. 硬规则（给你）
- 只读；不要运行任何脚本或 app（期望值从脚本源码、docs、报告里取，标明出处）；不联网。
- 任务书里所有路径/命令必须在仓库里核实存在（Glob/Grep），不要凭记忆写钩子名。
- 写完自查一遍：有没有「同前」类引用、有没有没给期望值的步骤。
