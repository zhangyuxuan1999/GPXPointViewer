# 进度：日期导航新文案与文档说明

## 已完成
- 已读取 AGENTS、Tests/l10n/RULES.md、chunk_31.json、本批 12 个新键清单、四份目标文档、docs/local-install-signing.md 与 coordinator/architecture-review.md。
- 已确认 runner 的 `snapshots/before/files/` 保存了四份现有文档的编辑前快照；before manifest 记录：
  - README.md `ed9e78439e026c01254d1eaaeebedc0d9b2e9f5a965b06c7cc33f376b330a102`
  - Tests/README.md `26c8a670b20bf185799e50bf984fa136afb26dd2a3a9d2c935326951f7be0ddc`
  - docs/journey-summary-guide.md `40e301731704ee20497fc7a707df69218ba714e1db47b110874e0d164953ebe0`
  - docs/journey-summary-date-navigation-design.md `652e1431ced2683ebec0bbe67dd4de0a98a6e625987f514601611244bc4d04ec`
- 已核对实现：`JourneySummaryWindow` 用固定 DatePicker（UTC 仅作 civil YMD 适配）和“查看”按钮；`TrackStore.openSummaryFromMainFilter()` 每次显式入口更新导航，未选/年/月/多日进入 chooseDate，空日不跳转。
- 未修改任何产品源码、Tools、现有 catalog、其他 chunk 或真实偏好。

- 阶段 1 已完成：新增 `Tests/l10n/translations/chunk_32.json`，12 条唯一键（合并重复的「请选择日期后查看摘要。」位置），table/key/comment/en/de/zh-Hant 结构，保留 `%@`，沿用 chunk_31 的摘要=Summary/Übersicht/摘要、行程=Journey/Fahrt/行程、主地图=main map/Hauptkarte/主地圖等术语。

- 阶段 2 已完成：README 摘要入口与 `docs/journey-summary-guide.md` 已改为「主面板明确选一天→点击直接打开该日；已开窗口再次点击更新；未选/年/月/多日先选年月日并查看/回车；空日保留并提示不跳转」，并写明固定日期控件、当日完整指标/关联行程、跨日行程完整指标、整源缓存只用于计算而浏览跟随所选日、浏览不改主地图（仅地图按钮改）。数值规则未改。

- 阶段 3 已完成：README 与 Tests/README 的当前推荐构建命令均为 `python3 Tools/build_release.py --arch arm64`（必要时 `--no-icloud-coordination`）；清除默认正式示例中的 `--no-sign`，并说明它仅为显式诊断、`installable=false`、不可安装。补上 `archive_build.py --validate --for-install` 与 `Tools/install_release.py … --execute --authorized-target /Applications/GPXPointViewer.app` 的已授权安装流程和 `docs/local-install-signing.md` 链接；历史 `--no-sign` 仅作为诊断证据注明。声明新构建/跨进程结果待 `docs/journey-summary-date-persistence-acceptance.md`，旧 core22/Store70/功能12 证据继承。

- 阶段 4 已完成：ADR 表头 `Status: Proposed` 改为 `Accepted（root 已验收）`；在 DatePicker／控件契约后新增一段 UTC 编辑适配，说明 UTC 仅作 civil YMD 编辑载体、统计/校验/显示仍用实际 IANA 时区、非法实际日保留输入并报错不跳日；其他架构契约未改。

## 正在做
- 阶段 5：保存 after 快照/精确 diff，运行唯一验证命令，输出 `artifacts/validation.json`，完成报告。

## 下一步
- 读取验证输出与当前文件哈希，写 after 快照记录和最终报告；交由 root 验收。
- 阶段 3：更新 README.md 与 Tests/README.md 的正式构建/签名/授权安装说明，保留历史证据。
- 阶段 4：ADR Status 改 Accepted 并补 UTC civil YMD 编辑适配段。
- 阶段 5：保存 after 快照与精确 diff，运行唯一验证命令，输出 `artifacts/validation.json`，完成报告。

## 未做/声明
- 不抽键、不编译、不组装 catalog、不跑 App/构建/产品测试，不改真实偏好。
- 不宣称新的真实构建或跨进程测试已通过；本轮结果待 root 与后续 `docs/journey-summary-date-persistence-acceptance.md` 验收。
- 实际服务端模型回执、token、费用：unknown/null（无回执，不冒造）。


## 阶段更新 2026-10-31T01:38:53.591097+00:00
### 已完成
- 已持久记录 `snapshot`，完整输入/结果见 events.jsonl。
### 正在做
- runner 状态：running。
### 下一步
- 继续当前任务；恢复前核验既有产物与最后正常工具结果。


## Runner 收尾 2026-10-31T01:38:53.592862+00:00
- provider=interrupted，验收=pending。
- 下一步：核验 output/result/events/changes；未完成项须新建关联轮次恢复。
