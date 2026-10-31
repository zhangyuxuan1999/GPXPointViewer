# ADR-2026-10-31：摘要的日期入口与当天导航

**Status:** Accepted（root 已验收）  
**Date:** 2026-10-31  
**Deciders:** 主代理核对契约后验收；架构请求模型 GPT-6 Astra / ultra，服务端模型回执与费用未知。  
**Supersedes:** [摘要原设计](journey-summary-design.md)的全日期列表和“打开时忽略主地图日期”交互；保留其统计、来源、缓存、取消及发布归属契约。

## Context

用户明确要求：主面板已选日期时，点击摘要直接查看该日；没有选定日期时，提供年月日选择框，不能把十年全部日期列出来拖滚动条。用户截图选定 **2026-10-16**，数据约 201 万点。这里的“选定日期”指用户界面的日期意图，不能靠筛选范围恰好有 86,400 秒来猜测。

2026-10-31 当前源码依据：

- `ContentView.swift` 的按钮与 `JourneySummaryCommands` 都只设置 `summaryWindowOpen` 再 `openWindow`，没有传递日期；已经打开的窗口也没有新的导航事件。
- `JourneySummaryWindow.swift` 的 `rows` 为报告全部日／行程，`selected` 在没有有效选择时回退到 `rows.first`，这会显示与主面板日期无关的第一日。
- 日期控件实际在 `ExportSheet.swift` 的 `TimeFilterSection`，其 `mode/day/rangeStart/rangeEnd` 为私有 `@State`；`push()` 已将语义写入 `TrackStore.viewFilterSpec`，同时写入 `[start,end)` 的 `viewFilter`。`ViewFilterSpec` 尚未保存计算时的日历／时区。
- 主面板用 `Calendar.current`，摘要引擎固定 Gregorian 加明确时区；入口必须传递同一真实自然日，不能直接把非公历系统的年份当公历年份。
- `SummaryReport.days` 已按时间排序且有 `dayStart/dayEnd`，行程有稳定版本内 ID；Store 具有独立请求、publication lane、整源缓存和 `summaryBuildCount`。现有引擎及通过证据可复用。

## Decision

采用**固定日期控件＋当天内容**。顶部始终显示可键入年／月／日的原生日期控件和“查看”按钮，旁边显示实际 IANA 时区；正文只展示已确认日期的每日摘要，或该日关联行程。删除全日期侧栏，不提供将全量日期列表作为默认导航的路径。

主面板按钮、窗口菜单和测试入口统一调用 `TrackStore.openSummaryFromMainFilter()`，然后由各自 View 执行 `openWindow(id:)`。每次显式点击都会更新导航状态，不能依赖 `onAppear` 才接收日期。窗口创建／系统恢复的 `onAppear` 只接续已有请求；没有请求时进入“请选择日期”。

### 入口与未选日期

| 打开时的主面板语义 | 日期状态与正文 | 控件初值（仅草稿） |
|---|---|---|
| `.day`，且 spec 与当前生效范围一致 | 直接选该真实自然日，切到“每日”，即使窗口已开、之前在看行程也一样 | 同一日 |
| `.custom` 且起止年月日相同，spec 与范围一致 | 同上；这是显式选择一个自然日 | 同一日 |
| 有效“摘要时间筛选”chip，匹配当前报告的日行 | 直接选 chip 的日与时区；不从行程 chip 猜单日 | 同一日 |
| `.year` | 不提交日期；提示“已选择年份，请选择具体日期” | 该年的 1 月 1 日 |
| `.month` | 不提交日期；提示“已选择月份，请选择具体日期” | 该月 1 日 |
| 多日 `.custom` | 不提交日期；提示“当前范围包含多日，请选择其中一天” | 排序后的起始日 |
| 全部／没有一致 spec／行程 chip／菜单无主日期 | 不提交日期；提示“请选择日期后查看摘要” | 当前来源报告最新记录日；报告未就绪时用当前日期 |

草稿不是已选择日期，未点击“查看”／回车前不得显示某日统计或自动选 `days.first`。无日期入口每次重新进入待选择状态，可保留同来源、同区域上下文的上次草稿便利输入，但不保留正文作为本次已明确选择的日期。年／月／多日上下文只解释建议初值，不限制用户跳转到其他日期。

若最新记录日只能在异步报告完成后取得，只能在该次入口仍有效且用户从未编辑草稿时更新初值。用户已输入、已点击查看或又点击入口后，旧完成回调不能改日期。正文注明“请选择日期”，不能用初值假装用户已确认。

日期确认后，顶栏持续显示明确年月日；空白日显示“该日期没有记录”以及所选来源／时区，保留输入，不跳最近有记录日、不显示另一日详情。前一天／后一天若实现，必须逐自然日移动，允许停在空白日；不可用上一条／下一条报告行伪装为昨天／明天。

### 选择控件与正文

- 使用 date-only 原生 `DatePicker`，明确 Gregorian 日历和当前摘要时区，支持键盘编辑年月日、Tab 切换与回车“查看”。如 SwiftUI 默认样式不能满足键盘输入，使用小范围 `NSDatePicker` bridge 的文本字段与步进样式；不得退回需要滚动多年日期的 `List`。
- 控件绑定草稿；按“查看”一次性校验、提交。可表示的日期不受报告有无数据限制。非法日期／时区显示就地错误，不静默规范化到另一日；YMD → Date → YMD 必须回读一致。日期控件的绝对 `Date` 只是适配值，业务身份是年月日。
- **UTC 编辑适配**：日期控件内部的绝对 `Date` 仅以 UTC 作为年／月／日字段的 civil YMD 编辑载体，用于表示实际时区跳过的民用日期；统计、日界校验与正文仍使用实际 IANA 时区，顶栏显示实际时区。实际时区中非法的日期保持用户输入并就地报错，不跳转到另一日。
- “每日／行程”保留为内容切换。每日正文使用唯一匹配的日行和现有指标卡片；每日交通候选使用同一组关联行程。行程页左侧最多列**所选日期关联的行程**，右侧使用现有完整行程详情。日期未选时两个模式都提示选日。
- 关联条件保持现有语义：`journey.startTime < dayEnd && journey.endTime >= dayStart`。午夜开始的行程不属于前一天；午夜有末点的行程属于后一天。跨午夜行程可在两个日期下出现，显示完整起止日期与“跨日行程；以下为完整行程统计”，不截断距离／时间，不改 `summary-v1`。
- 日期／来源改变时清除旧行程 ID。进入行程页时，可明确选择该日第一条关联行程；没有关联行程则为空，禁止回退到 `report.journeys.first`。同一日内切回每日再返回行程可保留仍有效的 ID。
- 窗口底部说明改为“按所选日期浏览；统计基于所选文件的全部记录。查看摘要不会改变主地图筛选。”已有“在主地图上查看”按钮才改变地图。空白日不提供指向别日的地图按钮。

## 可实施接口契约

### 1. 主筛选语义快照：`ExportSheet.swift` 与 `TrackStore.swift`

在 `ViewFilterSpec` 末尾添加有默认值的 `calendar: Calendar = .current`，其 `timeZone` 是实际计算范围时捕获的值；避免破坏现有成员初始化调用。`TimeFilterSection.push()` 在同一次调用内捕获一个 calendar，用它计算范围并写入 spec。不能分别取两次 system calendar 后假定时区不会变化。

新增纯 helper 读取 `ViewFilterSpec + viewFilter` 生成 `SummaryEntryRequest`：先根据 `.day`／同日 `.custom` 判定意图，再用 spec 的 calendar 和日期分量重建原范围，并验证两个端点与正在生效的 `viewFilter` 一致。只有通过验证才直接选日。接着将该范围开始转换为**同一时区的 Gregorian 年月日**，验证 Gregorian 自然日的边界也相等。此转换用于不同日历间表达同一天，不用于从范围时长猜用户意图。任何缺失／不一致都进入待选择提示。

摘要 chip 路径须先验证其 track/source/row 归属和当前报告日行；使用已有 dayStart/dayEnd/时区。行程 chip 进入待选择，不把恰好一天的行程范围当作日期选择。无主窗口时菜单仍可打开选择控件。

不要求本轮把主地图全部 `@State` 搬入 Store。`viewFilterSpec` 为现成的语义交接点；其新 calendar 快照只解决此入口的日期一致性。若实现同时修改导出预设，应复用这个 calendar，另记录受影响验证，不顺带改变导出规则。

### 2. 独立导航模型：`JourneySummaryState.swift`

建议接口名字可随项目风格小调，以下不变量必须保留：

```swift
struct SummaryCalendarDay: Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    // Gregorian components; checked interval(in:) uses Calendar, never +86400.
}

enum SummaryEntryRequest {
    case day(SummaryCalendarDay, timeZoneIdentifier: String)
    case chooseDate(seed: SummaryCalendarDay?, timeZoneIdentifier: String?, hint: SummaryDateHint)
}

struct SummaryDateNavigation {
    var revision: UInt64
    var selectedDay: SummaryCalendarDay?  // nil means no submitted date
    var draftDay: SummaryCalendarDay
    var draftEdited: Bool
    var hint: SummaryDateHint?
    var selectedJourneyID: String?
}

struct SummaryNavigationIndex: Sendable {
    let sourceID: UUID
    let trackID: UUID
    let timeZoneIdentifier: String
    let dayRowByStart: [Double: Int]          // report.days indices
    let journeyRowsByDayStart: [Double: [Int]] // report.journeys indices
}
```

`SummaryDateHint` 为明确的本地化提示 enum；不把文案字符串当业务状态。日期导航是会话内查询状态，本次不新增 UserDefaults 持久化。View 可以拥有文本编辑细节，但必须以 navigation.revision 接收新入口，并将“用户已编辑”反馈给 Store，防止报告晚到覆盖草稿。

### 3. Store 拥有操作与发布

```swift
@Published private(set) var summaryDateNavigation: SummaryDateNavigation
private var summaryNavigationIndex: SummaryNavigationIndex?

func openSummaryFromMainFilter()       // resolve entry; apply every invocation
func applySummaryEntry(_ request: SummaryEntryRequest)
func editSummaryDateDraft(_ day: SummaryCalendarDay)
func selectSummaryDate(_ day: SummaryCalendarDay) // validate then submit, no build
func selectSummaryJourney(_ id: String)          // only current day's IDs
// Read-only currentDayRow/currentDayJourneys/currentJourney projections for UI/tests.
```

`applySummaryEntry` 在主线程同一事务中先落实日期、来源上下文与时区，再打开／ensure；不要先置 `summaryWindowOpen=true` 触发旧时区计算后又取消。显式主日入口将摘要时区固定为捕获的 IANA 时区（`.named(identifier)`），顶栏注明来自主面板；即使系统时区随后变化，仍与主地图已生效范围相同。用户自行改摘要时区后，保留所选年月日，在新时区重新划日，移除“来自主面板同一范围”说明；它不偷偷修改主地图。

保留 `summaryCacheKey`、`summaryRequest` 和 publication token 的全部现有校验。**日期、草稿、选中行程、每日／行程切换都不进入统计缓存键，不调用 invalidate／builder，不扫描点数组。**同来源／同数据／同实际时区下反复跳日，`summaryBuildCount` 不增加。因入口对齐时区、换来源、编辑轨迹而重算是原有统计依赖变化，不应伪称零计算。

一次有效 report 的后台工作同时建立 `SummaryNavigationIndex`，不要在 SwiftUI `body` 内全量 `filter(report.journeys)`。日索引 O(D)；对每个已排序行程，用排序日界查找首个重叠日，再遍历实际报告日，直至 `dayStart > journey.endTime`，把 Int 下标追加到当日索引。复杂度 O(D + J log D + K)，K 为实际日／行程关联数量；不遍历多年空白日，不复制点数组、不重算指标。循环保留取消检查。该索引与报告共享 source/track/zone 归属，随报告一起发布与撤销，不能拿旧索引解释新报告。可在原 detached worker 中将 report＋index 作为结果包发布，无需改变 `JourneySummaryBuilder` 或 `SummaryReport` 的核心定义。

发布时先安装同版 index，再发布 report，并按**当前** navigation.selectedDay 解析正文；不得使用启动 worker 时捕获的日期。导航 revision 用于抑制过期草稿初值／入口副作用，不替代统计发布 token。日期在统计途中从 A 变 B 时不取消同 key 的统计；最终有效结果显示 B。已选日期在新报告无对应行时显示 B 的空状态。

### 4. 生命周期边界

| 事件 | 导航处理 | 报告／地图处理 |
|---|---|---|
| 当前窗口再次收到显式主日入口 | revision 递增，切每日、选新日期、清行程 ID | 同 key 复用；不同捕获时区按原规则重算 |
| 统计途中用户改日 | 保留最新年月日 | 不取消同 key；完成只解释最新日期 |
| 用户换来源／single-overlay-compare | 保留已确认年月日，清旧行程 ID | 原归属校验、立即撤下旧 report/index；新源该日无数据就为空 |
| 用户改时区 | 保留 civil YMD，清行程 ID，撤掉主范围同一性标识 | 原时区缓存失效；DST 按新 calendar 求日界 |
| 同源编辑／撤销更新 trackID | 保留日期，旧行程 ID 作废 | 原 provenance／revision 失效，后台重建；不回第一日 |
| 清空／移除全部数据／进入 fwdb | 清 selectedDay/行程 ID，撤销未完成入口副作用 | 原取消路径清 report/index；显示无轨迹／fwdb说明，晚到成功及失败均无效 |
| 关闭窗口 | 可保留草稿及已完成缓存；下次显式打开仍走新请求 | 原关闭取消；不得由迟到回调改导航／busy |
| 系统时区改变 | `.system` 模式保留 civil YMD，按新系统区重建；主日入口的 `.named` 不跟变 | 继续原通知机制；UI显示真实 report时区，加载时不混用旧正文 |

所有日界使用 Gregorian Calendar 和指定 TimeZone 的自然日 interval，23／25 小时自然日合法。年月日不存在（包括时区跳过的民用日期）应明示不可用，不将其跳成另一天。没有日期行只表示缺少该日可用记录，不生成零距离的伪日行。

## Options Considered 与 Trade-off Analysis

| 方案 | 复杂度／成本 | 规模与交互 | 结论 |
|---|---|---|---|
| A：保留日期侧栏，加日期输入后选中／滚动定位 | 较低；沿用本地 selectedID | 仍把多年日期当导航主体，容易出现 first 回退和窗口重开未定位；不符合用户否定全列表的要求 | 拒绝 |
| B：固定年月日控件＋当天详情／关联行程，共用整源报告 | 中等；新增少量导航状态、入口快照与报告索引 | 日期跳转与点数脱钩；空日和未选日可明确表达；每次入口可覆盖旧导航 | 采用 |

不选“每次只取当天点重新算报告”：它会损坏跨午夜行程的完整定义，并把日期导航变成百万点筛选／统计工作。所选方案继续利用现有核心算法，增加的索引只服务展示。

## 文件所有权与实施顺序

本 ADR 由架构代理独占；产品实施交 GPT-6.1 Sol / ultra。主代理统一分配下列文件，设置持久化调查代理不得同时写 Store／窗口：

1. `JourneySummaryState.swift`：日期值、入口 helper、导航索引与校验；`TrackStore.swift`：导航状态、入口、与报告共同发布／清除。`ExportSheet.swift` 仅触及 `ViewFilterSpec` 和 `TimeFilterSection` 的 calendar 快照。
2. `JourneySummaryWindow.swift`：日期控件、提示、当天投影及关联行程；`ContentView.swift`／窗口 Commands／`UITestHook.swift` 统一入口。`GPXPointViewerApp.swift` 保持共享 Store 与单一摘要 Window；只有确需显式 restoration 接线才修改。
3. `UITestHook.swift` 的状态 JSON 增加 submitted day、draft、navigation revision、当前日／关联行程 ID；不得只输出 report 全量行数冒充屏幕选中结果。定向测试添加到现有 `Tests/summary/store/` 和摘要 UI 流程的新子集。
4. 新本地化文案先写新 `Tests/l10n/translations/chunk_*.json` 再组装，按 RULES 校验。更新 README／摘要指南的入口说明，移除“所有日期列表／打开忽略主日期”等过时交互描述；保留“整源计算”的准确限制。

不修改核心距离／时间／海拔／地区／行程分割与规则版本，不做设置持久化重构，不触发路由网络。本架构任务不运行 App、构建或测试。产品实施验收及 `/Applications` 覆盖安装由主代理依当前持续授权另行收尾。

## 最小定向验证计划

下表是新交互缺证／本轮修改所需验证，**不是已通过结果**。实施前写明受影响点、命令与输入版本，继承 [现有摘要验收](journey-summary-acceptance.md) 的核心 22／Store 70／实际功能 12 证据；不因此重跑其全套。

| 组 | 最小断言与独立预期 | 执行者 |
|---|---|---|
| 日期入口语义 | `.day=2026-10-16` 打开后选中该日；窗口已开再选 17 日点击入口更新；年／月／多日／all 均 selectedDay=nil；同日 custom 直接定位；陈旧 spec、行程 chip 不伪装日选择；菜单与按钮走同一生产方法 | Sol 的 Store 新 navigation 组 |
| 时区边界 | 主筛选在 Europe/Berlin 生成、摘要原先 UTC，入口后精确日界相同；2026-03-29 为 23h、2026-10-25 为 25h；输入无效日期不能静默改日；非 Gregorian 主 calendar 经明确 day 意图转换后仍对应同一绝对日界 | Sol，测入口 helper；不重跑核心 DST 计算 |
| 日期缓存与空日 | 同一真实报告连续跳多个有／无记录日，buildCount 不增加，没记录的日期保持且不回第一日；当天关联行程含跨午夜原 ID，完整指标与 report 原行一致；日／行程切换不扩大到全源列表 | Sol，生产投影断言；用现有小夹具扩充日期 |
| 异步归属与清理 | 挂起一次生产报告发布，连续 A→B 日期后释放只显示 B；换源／改区／清空时旧 report＋index 不能发布；当前报告无 B 时保持 B 空状态；新报告不覆盖用户编辑后的草稿 | Sol 复用 publicationGate，限新导航／索引接线 |
| 实际 UI 与像素 | 指定新归档 GPXPV_APP：主选 10-16 打开与已开再定位；无选择时键入年份／月／日并回车；选空日仍显示原日期；当天行程可点击。小夹具跨多年即可证明入口，不重复加载用户 201 万点。zh-Hans／en／de 检查日期行、提示、小窗口与跨日行程文案；截图必须逐图判读 | 一次定向 UI 子集；主代理像素验收 |

若索引构造引入实际性能疑问，先用已有规模报告和新索引计时补足该缺口，不无理由重跑百万点核心。性能合同是日期导航不启动 builder、不逐点扫描、body 不全量筛行程；不杜撰未经测量的毫秒承诺。

## Consequences 与行动项

用户可以从主面板直接进入指定日，也可以用固定控件跳到十年前某日；未选和无记录各有明确状态。代价是来源／报告旁增加一份不可变行索引，并需严格区分草稿与已提交日期。跨日行程继续保持完整统计，日界不影响其核心身份。

1. 主代理验收本 Proposed ADR 并在实施任务中锁定上述文件所有权。
2. Sol 先实现入口／导航／索引契约，再替换 UI 全日期列表，保存前后快照与新证据。
3. 主代理复用已有通过证据，审阅新导航和异步结论、实际像素，再按持续授权安装对应验收构建。
