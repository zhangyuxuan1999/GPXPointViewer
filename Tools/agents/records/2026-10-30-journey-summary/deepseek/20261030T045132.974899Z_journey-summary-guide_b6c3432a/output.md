# 行程／每日摘要用户指南：完成报告

## 结果

已完成已冻结架构下的中文用户说明，未做设计决定、代码、翻译、测试或新调研。

- **新增** `docs/journey-summary-guide.md`：面向使用者的摘要指南，开头注明本指南记录当前开发分支采用的 `summary-v1` 统计规则，最终交付状态以 root 稍后生成的 `journey-summary-acceptance.md` 为准，并非发布通过声明。
- **修改** `docs/journey-summary-design.md`：仅把 Status 行由 `Proposed（实现契约已定；交主代理验收后实施）` 替换为 `Accepted（2026-10-30主代理已验收，正在实施）`，未改接口、规则或其他字句。
- **留档** 本轮 `progress.md` 已按阶段更新；`artifacts/guide-result.json` 已生成，包含实际修改清单、依据、未运行测试／构建的事实与未知费用记录。

## 指南覆盖内容

指南按用户视角说明了：

- 打开摘要窗口后的来源文件选择、默认来源，以及“当前文件全部记录、不跟随主地图时间筛选”；
- 不同来源文件分别报告、不相加、不融合；
- 本机／UTC／指定 IANA 时区、计算时区标识、自然日边界、夏令时 23／25 小时、跨午夜按时间比例分摊；
- “每日／行程”切换、行程按硬源段和 30 分钟记录空白分段、跨午夜不拆行程；
- 长空白不生成中间 0 公里空日、日期未知点单列、单点行跨度为 0；
- “记录折线”与“补点估算”的区别，缺合格边时“距离不可计算”而不是 0；
- 跨度、观测间隔、估算时间、未覆盖时间、移动估计、低速间隔的口径，以及未覆盖时间只在首末贡献之间、不代表全天丢失；
- 单文件多源段时间重叠时距离可能重复、时长取并集；
- 爬升／下降的五点中位数与 3 米迟滞滤波、80% 海拔边覆盖且至少两条边的发布门槛、不保证真实高程且不外推；
- 记录位置到访与补点经过（估算）、离线边界、未归属与索引缺失；
- 交通自动结果仅为速度候选、未确认，手动模式仅本会话当前数据版本，不能凭速度断言火车或步行；
- 受限的“在主地图上查看”及“清除摘要筛选”；
- `.fwdb` 无逐点真实时间和连续路线、无法计算摘要；
- 未宣传摘要 CSV 导出、手动合并／拆分行程、多设备融合或项目持久化。

未凭空编写菜单快捷键或未冻结的 CLI 命令。

## 实际修改清单

| 路径 | 类型 | 范围 |
|---|---|---|
| `docs/journey-summary-guide.md` | 新增 | 用户指南正文 |
| `docs/journey-summary-design.md` | 修改 | 仅 Status 行文字替换 |
| `Tools/agents/records/2026-10-30-journey-summary/deepseek/20261030T045132.974899Z_journey-summary-guide_b6c3432a/progress.md` | 修改 | 本人 run 的语义进度 |
| `Tools/agents/records/2026-10-30-journey-summary/deepseek/20261030T045132.974899Z_journey-summary-guide_b6c3432a/artifacts/guide-result.json` | 新增 | 结果摘要 |

## 依据

`AGENTS.md`、`Tools/agents/README.md`、`docs/journey-summary-design.md`、`Tools/agents/records/2026-10-30-journey-summary/coordinator/architecture-evidence-review.md`、`README.md` 及本人 `task.md`。

未读取 `data` 真实轨迹、凭据、其他私人目录或旧账户聊天。

## 验证与限制

- **未运行任何测试、构建、联网、安装、删除或再派发操作。**
- 界面仍在并行实现；指南只记录已冻结的统计规则与当前设计中的交互限制，不声称功能已发布或验收通过。
- 请求模型为 `deepseek-flash` / `max`；无供应商模型回执或账单，服务端模型证明与实际费用均记 `null`，未冒称费用为 0。

任务写作已完成，等待 root 按已有文档验收。