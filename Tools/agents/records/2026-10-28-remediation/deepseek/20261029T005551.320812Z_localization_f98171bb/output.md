# DeepSeek 本地化补齐报告 — chunk_29（4 条新 UI 文案）

## 1. 新增文件与范围

| 项目 | 结果 |
|---|---|
| 新增产品输入文件 | `Tests/l10n/translations/chunk_29.json`（4 个条目，UTF-8，2 空格缩进） |
| 写入前是否存在 | **不存在**，无覆盖冲突 |
| 已修改的其他文件 | 无（未改 `.xcstrings`、已有翻译块、Swift、任务/期望） |
| 进度记录 | `.../20261029T005551.320812Z_localization_f98171bb/progress.md` 已按「已完成／正在做／下一步」更新 |

条目字段顺序按本轮要求：`table`（固定 `Localizable`）、原样 `key`、`comment`、`en`、`de`、`zh-Hant`。既有块中没有出现过 `comment` 字段，本轮按明确要求为每条补了英文译者注释（说明出现位置与语义，不含内部位键/索引）。

## 2. 四条中译英／德／繁对照

### ① 无法安全还原这些修改。请连同后续相关修改一起还原，或还原全部修改。

- **en:** Cannot safely revert these changes. Revert them together with the related later changes, or revert all changes.
- **de:** Diese Änderungen können nicht sicher zurückgesetzt werden. Setzen Sie sie zusammen mit den zugehörigen späteren Änderungen zurück, oder setzen Sie alle Änderungen zurück.
- **zh-Hant:** 無法安全還原這些修改。請連同後續相關修改一併還原，或還原全部修改。
- **comment:** Change Log: error when a change cannot be reverted safely on its own because later changes depend on it; the user can revert the related later changes together or revert all changes. Use the existing Revert / Revert All wording; do not mention internal bit keys or indices.

### ② 无法应用补点：锚点或区间已改变，请重新选择。

- **en:** Cannot apply Gap Fill: the anchor or range has changed. Please select again.
- **de:** Lückenfüllung kann nicht angewendet werden: Anker oder Bereich haben sich geändert. Bitte erneut auswählen.
- **zh-Hant:** 無法套用補點：錨點或區間已改變，請重新選擇。
- **comment:** Gap Fill: shown when applying fails because the source track or anchor range has changed; asks the user to select the gap again. “Apply Gap Fill” writes the gap fill into the track, not an app install.

### ③ 若后续修改依赖此处，请一并还原相关修改。

- **en:** If later changes depend on this one, revert the related changes as well.
- **de:** Wenn spätere Änderungen hiervon abhängen, setzen Sie die zugehörigen Änderungen ebenfalls zurück.
- **zh-Hant:** 若後續修改依賴此處，請一併還原相關修改。
- **comment:** Change Log: per-change Revert button help; explains that later changes depend on this change.

### ④ 轨迹线沿各段内的时间顺序连接；不同轨迹段不相连，超过 30 分钟或 10 km 的间隔断开；地球视角只显示点云

- **en:** The track line connects points in chronological order within each segment; different track segments are not connected, intervals longer than 30 minutes or 10 km break the line; the globe view shows only the point cloud.
- **de:** Die Tracklinie verbindet die Punkte innerhalb der einzelnen Abschnitte in zeitlicher Reihenfolge; verschiedene Trackabschnitte werden nicht verbunden, Intervalle von mehr als 30 Minuten oder 10 km unterbrechen die Linie; die Globusansicht zeigt nur die Punktwolke.
- **zh-Hant:** 軌跡線沿各段內的時間順序連接；不同軌跡段不相連，超過 30 分鐘或 10 km 的間隔斷開；地球視角只顯示點雲
- **comment:** Track Line display help: within a real GPX segment, points connect in normalized time order; hard segments are not connected; soft gaps over 30 minutes or 10 km break the line; the globe view still shows the point cloud.

## 3. 术语对齐情况（基于既有块检索）

| 中文 | en | de | zh-Hant |
|---|---|---|---|
| 还原／全部还原 | Revert / Revert All | zurücksetzen / Alle zurücksetzen | 還原／全部還原 |
| 修改记录 | Change Log | Änderungsprotokoll | 修改記錄 |
| 补点／应用补点 | Gap Fill / apply Gap Fill | Lückenfüllung / Lückenfüllung anwenden | 補點／套用補點 |
| 锚点 | anchor | Anker | 錨點 |
| 区间 | range | Bereich | 區間 |
| 地球视角 | globe view | Globusansicht | 地球視角 |
| 点云 | point cloud | Punktwolke | 點雲 |
| 轨迹线 | track line | Tracklinie | 軌跡線 |
| 段 | segment | Abschnitt | 段 |

第 4 条末句直接复用既有 `chunk_09` 的「地球视角只显示点云」译法；「应用补点」与既有 `应用补点？`（Apply Gap Fill? / Lückenfüllung anwenden? / 套用補點？）一致；「还原」系列与 `chunk_02`/`chunk_11` 的 Revert / zurücksetzen / 還原 一致。繁体采用台湾用字（還原、補點、錨點、區間、點雲、軌跡線、一併、依賴）。

## 4. 检查情况（已执行与未执行）

**已执行的静态检查（仅 Read/Grep，未运行解析器）：**
- 文件中原样保留了四个 key，逐字核对：全角标点、`30 分钟`、`10 km`、末尾句号/无句号均与任务给定一致。
- 每条均含 `table`/`key`/`comment`/`en`/`de`/`zh-Hant`；`table` 全部为 `Localizable`。
- 4 个 `"table"`、4 个 `"key"`、4 个 `"comment"`、4 个 `"en"`、4 个 `"de"`、4 个 `"zh-Hant"`。
- 文件中无 `%`、无 `\u` 转义 ⇒ 四条均无格式占位符，不需要复数/变量；占位符集合为空、天然一致。
- `en`/`de` 值中未检出中文字符；英文/德文无中文标点（使用 ASCII 冒号、逗号、句号/分号）。
- 目视检查了 `[` … `]`、对象分隔逗号与末项无多余逗号。

**未执行（不得声称已测试）：**
- 未运行 JSON 解析/校验脚本（本工具集无 shell/执行能力），因此**结构仅经静态目视与 Grep 检查，未经解析器验证**。主代理仍需独立跑 `json.load` 与占位符奇偶校验。
- 未构建、未启动 app、未联网、未生成三语截图。
- 未改任何 xcstrings、已有翻译块、Swift、任务/期望。

## 5. 交主代理的下一步

1. 独立校验 `chunk_29.json` 的 JSON 结构与占位符（4 条均无占位符）。
2. 统一组装进 String Catalog，确认真实构建零 xcstrings/格式警告。
3. 完成 zh-Hans 回归与 en/de/zh-Hant 三语截图验收（含德文截断检查）。