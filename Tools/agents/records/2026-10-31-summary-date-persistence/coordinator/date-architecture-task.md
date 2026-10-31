# 日期入口与摘要导航设计 — Astra ultra
请求模型gpt-6-astra，ultra。只写 docs/journey-summary-date-navigation-design.md 及本run证据，不改产品/测试。
用户原话：主面板明确指定日期后再点每日与行程摘要，应直接打开指定日期；没有选定日期，应提供年月日选择框，不能把所有日期列出来拖滚动条。截图主面板日筛选为2026年10月16日，跨十年约201万点。
先读README、docs/journey-summary-design.md、Tests/README.md摘要节与当前JourneySummaryWindow/State、TrackStore摘要块、ContentView.TimeFilterSection/入口、App window入口；旧报告可用Tools/agents/records/2026-10-30-journey-summary/coordinator各review。核心22/Store70/实际功能12通过已继承，不重复执行。
设计具体可实施的日期选择UX和状态模型：主面板日筛选的精确日期入口（打开已存在窗口也应重新定位），未选择/年/月/自定义多日如何提示与初始化；年月日选择器可直接键入/选择并跳转，数据空白日提示，不静默跳别日；摘要/主地图时区一致性和DST；来源/报告异步更新、取消/清空/模式切换保持安全；每日详情与该日关联行程（跨午夜不改核心统计定义）；窗口菜单直接打开也有日期选择。不要将用户要求误缩成只滚动到列表某行，默认不展示十年全部日期列表；可用日期控件+当天内容，保留必要行程选择。
报告仍可复用整源缓存，日期导航不得重算百万点；核心距离等算法不要改。给出足够清晰的接口契约/拥有文件/影响范围/最小测试点，让Sol直接实施。比较2个合理选项后给明确决定，不把所有设计问题交回用户。优先用户已明确需求，旧设计的全日期列表已经被纠正。
使用engineering:architecture技能，写简短可追溯ADR。Status先Proposed，主代理验收后实施。

## 协作留档与禁止项
先读项目AGENTS.md，遵守原始证据复用；只有具体矛盾/缺证/修复后受影响行为才做最小定向验证，理由预先写入本run。所有命令通过项目已有capture.py保存正常argv/stdout/stderr/exit，环境GPXPV_COMMAND_RECORD_ROOT设成本run/artifacts/capture。帮助脚本路径：/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-30-journey-summary/coordinator/capture.py。任何新脚本先保存再执行，不经未留档stdin。读大文件分段，完整输出存盘。
每主要阶段写progress.md并调用 python3 Tools/agents/agent_run.py event RUN --type progress --json ...。记录请求模型强度、实际agentID，供应商模型/费用未暴露unknown/null。不索取/记录思维链。不创建侧栏聊天或其他代理。保存完整output.md/result证据后调用finish(provider succeeded, acceptance pending)，主代理独立verify。
保留工作区大量既有改动，无gitreset/清理/commit/push。不得运行正式App、修改真实偏好、关闭用户App、安装应用、跑UI、调用公共路由；安装由主代理最终协调。任何允许修改文件必须前后逐字节快照/哈希及新增删除清单，记录不覆盖失败。
