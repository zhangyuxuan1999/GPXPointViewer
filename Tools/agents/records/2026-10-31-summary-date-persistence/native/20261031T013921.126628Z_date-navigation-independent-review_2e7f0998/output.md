# 日期导航与持久化接线独立审查

结论：本次冻结源码与已有导航证据可接受；未发现需要修改的明确 P0/P1/P2/P3 缺陷。实际日期字段键入、三语像素、唯一沙盒 A/B/C 持久化与最终构建/安装仍由主代理后续验收，本报告不是发布或 UI 通过结论。

请求模型 GPT-6.1 Sol / ultra。原生工具未暴露服务端实际模型/强度、token 或账单，actual model/effort 为 unknown、费用为 null。应用工程与测试源码没有改写，本 run 只写自身记录；没有执行测试、编译、App/UI、网络、安装，没有读取真实轨迹或真实偏好。使用 engineering:code-review 技能整理 correctness/performance/security 审查。

## 归属与证据

审查作者 run：native/20261031T012543.656242Z_summary-date-navigation-implementation_a203875d。已直接读取 task/progress/output/result、exact-file-changes/exact-changes、原始测试正常输出与编译/退出回执，不仅复述作者结论。当前九个关键源码/测试哈希和三次 compiled-source 哈希已另存本 run 的 artifacts/source-hash-lineage.json；当前文件对应最终 013601 编译输入。最终 source-stability 的所有项为 true。

首次到最终，State/Window/ExportSheet/ContentView 不变；Store 仅增加 ensure 中 O(1) 的草稿/已选日有效性校验，UITestHook 增加原生日期 action/键盘事件/正常退出桥接；测试改变为异步等待、有限续跑和 chip/Apia 检查。最终编译没有改核心数值。旧已验收归档 Builds/20261030T060514Z_release_4bd65c63/archive/build-manifest.json 的 JourneySummary.swift、GPXPointViewerApp.swift 与当前哈希相同；AppLanguage 所在 App 源及 L10nSupport 也未改变。没有设置保存逻辑重构。

已有导航输出按事件准确继承：

| 原始组 | 实际终态 | 可接受部分 |
|---|---|---|
| 首次 binary 的 PTY 诊断 stdout（013138_failed-run-output） | 测试异步 report 强解 trap；旧失败保留 | 27 PASS 事件中 4 readiness、23 功能；其中旧 chip 断言作废，保留22功能 |
| 013333 navigation-continuation/run.stdout.txt | rc=1，26检查、25通过、1失败 | 7 readiness、18功能通过；唯一 UTC 枚举拼写断言由 chip 组替代 |
| 013601 navigation-chip/run.stdout.txt | rc=0，9检查、0失败 | 4 readiness、5功能通过 |

接受45个功能通过事件、44个唯一名称；两个午夜夹具各有一次相同名称的当前日归属断言。15 readiness 另计。不能声称某次44/44或45/45整组执行通过。UTC/GMT旧断言替代合理：生产 named UTC 的 identifier 可规范化，而独立新断言检查实际捕获区与精确自然日界。报告保存的是 snapshot 输入 zone，cache/seed/report 对同一 snapshot 使用相同字符串，并未发现该别名导致报告/索引串版。

继承旧核心22、Store70和原实际12的历史证据；没有重跑。旧 UI 交互中的全部日期列表、默认第一行、顶部布局和实际日期输入已改变，不能用旧截图或原12项报告声称这些新交互已实际通过。原数值、来源、地图筛选、交通 override 等未改核心功能可继承相应证据。

## 源码核对

- JourneySummaryState.swift:17–26 使用指定 Gregorian calendar 的 noon→YMD 回读与自然日 interval，拒绝非法 Gregorian 日期和实际时区跳过日；没有用 86400 秒猜日或移动日。mainFilter:50–64 先验证明确 day/同日 custom 语义及当前有效 range，再转换同一真实日的 Gregorian YMD。非 Gregorian 输入经真实日期转换；year/month/多日/all/陈旧 spec 不自动提交。
- TrackStore.swift:4608–4661 的主面板/菜单入口每次处理新请求，包括窗口已打开；有效 day chip 验证报告 track/source/日行/range 归属。revision 递增、切每日并清旧行程。ContentView.swift:1590 与 JourneySummaryCommands 共用此生产方法；GPXPointViewerApp 保持原共享 Store/单窗口。
- JourneySummaryWindow.swift:20–37、143–174 固定 date-only .field DatePicker，以 Gregorian UTC 仅作 civil YMD 编辑适配，实际摘要 zone 在顶部显示。草稿与 selectedDay 独立；查看/Return 提交实际 zone 校验。未提交不出正文，空白日保持所选日期，没有 days.first 回退。对非法日期的实际键入行为本审查没有 UI 证据，不从 Date 的程序赋值推断。
- State:85–108 构造 report 日/行程索引，二分首重叠日，遍历实际报告日，保留取消检查。关联条件 start < dayEnd && end >= dayStart 与设计一致；跨午夜投影保持完整原行程。Window 只用当天投影；每日交通候选也使用当天关联行程，没有 body 全源 journeys.filter。
- Store:4664–4716 的日期编辑/提交、行程选择和投影不扫描点列，不 invalidate、不触发 builder；SummaryCacheKey 仍没有日期/草稿/选中行程/页签。异步报告按当前 selectedDay 解释，未捕获启动时日期。只有实际 source/zone/data key 变化重算。
- Store:4755–4879 保留 publicationClock、request UUID、cacheKey 与 currentKey 全部校验；worker 建 report+index 包，发布时先安装 index 再 report；撤销路径同时清理。实际 track/files/mode/compare/clear 生命周期入口已核对。迟到成功/失败均先过原归属验证；clear/fwdb 清日期，改区/换源/编辑保留已确认 civil YMD并清旧行程 ID；窗口关闭撤销工作和待种子。
- late draft seed 使用 revision/source/zone/未编辑/未提交联合条件；报告晚到不能覆盖用户草稿或新入口。切区使 Apia 日不可用时即时提示并保持 YMD；换回有效区会清该错误。来源/区域缓存与导航索引未混用。

## 测试隔离与执行边界

UITestHook 仅由显式 GPXPV_UITEST_DIR 或既有短时 handoff 启用。persistsettings:335–351 进一步要求 test bundle 前缀、GPXPV_TEST_BUNDLE_ID 完全相等及 NSHomeDirectory 位于同名沙盒，使用生产 AppLanguage.apply/TrackStore.updateSetting。settingsJSON:864–879 只导出 AppleLanguages 和三个 idle 键及必要身份/运行态，没有整域内容。

新 driver 通过 archive_build --prepare-isolated-test-copy 获得独立主 App/两 appex ID 和签名验证；不启动输入归档。启动后核对实际 bundle ID 与 home 完全等于自己的唯一 sandbox Data，再执行命令。停止/失败清理只处理自己的 Popen 子进程；没有正式进程或正式偏好目标。唯一测试容器保留供证据。

persistence 分支 A/B/C 均调用 session.start 不带 language，且 start 再验证 argumentLanguages 为 null。A 生产 API 写 zh-Hans/true/7/13并正常退出；B 新进程检查 stored/launch/persistent/localization/idle，再写 system/false/11/17并正常退出；C验证 AppleLanguages 删除、false与数值持久保存。该方案能够补证，但尚未实际执行，不能提前宣称通过。

navigation 与 visual-only 与 persistence 的选择清晰。en/de visual-only 只有 readiness/setup/截图，不重复中文功能断言；日期控件 helper 是 NSDatePicker.dateValue+action 与 Return，脚本头、ui-contract及 manual-native-keyboard-check 均明确字面键入 pending，未伪装 literal keyboard 证据。旧全套 summary driver 新增 test-ID和实际domain/home护栏；本次不调用它重跑12项。

## 仍待主代理完成

1. 用最终正确 sandbox 签名归档执行一次新 navigation 子集，以及三语 visual-only，逐图判断；不再复跑旧全套。
2. 独立实际键入年/月/日分段并 Return，确认与输入 civil YMD相同、待选/空白日无另一日正文；程序设 dateValue 不满足这项。
3. 执行独立唯一沙盒的 A/B/C persistence，检查真实三次进程与无语言参数证据。
4. 完成本地化最终归档、实际验收和安装；本只读审查没有授权替这些结果盖通过章。

本审查未发现需要额外产品复测的具体源码矛盾；剩余执行均为本轮新行为已有任务书明确列出的缺证，不是为独立核验重复测试。
