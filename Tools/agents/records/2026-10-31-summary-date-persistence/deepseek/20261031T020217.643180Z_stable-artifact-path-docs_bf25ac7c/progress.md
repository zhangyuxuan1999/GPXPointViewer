# Progress — Signed artifact path documentation

## Status
- 已完成:
  - README.md: 命令行 Release 构建与 UI 测试归档段（约 20-37 行）——通用 `/ABS/Builds/RUN/archive/GPXPointViewer.app` 改为 `/ABS/APP_FROM_BUILD/GPXPointViewer.app`；manifest 占位改为 `/ABS/APP_FROM_BUILD/build-manifest.json`；新增一段说明 build_release.py 打印的实际 app/manifest/durable_zip/durable_manifest 路径、iCloud 外唯一本地暂存目录、项目 `Builds/<RUN>/archive/` 的 durable ZIP/manifest/proof/paths 记录，并链接 docs/local-install-signing.md；安装示例同步使用打印 app 占位。
  - Tests/README.md: 速查（第 14、23 行）、2.2 构建与归档（第 76-92 行）、3.2 跑全套（第 176-177 行）、第 7 节推荐顺序与安装（第 532-547 行）——所有通用归档 app/manifest 示例改为 `/ABS/APP_FROM_BUILD/…` 占位；补充与 README 一致的 printed paths / durable ZIP / project records 说明及 docs/local-install-signing.md 链接。
  - 保留未改：`/ABS/OLD/GPXPointViewer.app`、`Builds/TIME_historical_UUID/`、日期导航“未宣称通过”说明、25 个 suite 脚本/114 项/2026-10-24 历史证据、统计规则与通过计数。
- 正在做: final report (no further edits)
- 下一步: none

## Verification performed
- Grep: no remaining `/ABS/Builds/RUN/archive` or `/ABS/build-manifest.json` generic examples in README.md / Tests/README.md.
- Grep/Read: remaining `archive/GPXPointViewer.app` mentions are intentional “不要假设项目内存在” guidance.
- No Bash, no build/compile/test/App/UI/network executed; docs/local-install-signing.md not read.

## Intermediate results
- Files touched: README.md, Tests/README.md, this progress.md only.
- Actual model/cost: unknown / null.


## 阶段更新 2026-10-31T02:03:51.912524+00:00
### 已完成
- 已持久记录 `snapshot`，完整输入/结果见 events.jsonl。
### 正在做
- runner 状态：running。
### 下一步
- 继续当前任务；恢复前核验既有产物与最后正常工具结果。


## Runner 收尾 2026-10-31T02:03:51.914238+00:00
- provider=succeeded，验收=pending。
- 下一步：核验 output/result/events/changes；未完成项须新建关联轮次恢复。
