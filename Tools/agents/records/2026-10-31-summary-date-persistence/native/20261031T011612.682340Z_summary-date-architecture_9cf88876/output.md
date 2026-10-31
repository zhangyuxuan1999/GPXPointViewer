# 日期入口与摘要导航架构交付

已交付 `docs/journey-summary-date-navigation-design.md`，状态 **Proposed**，供主代理独立验收后交 Sol 实施。请求模型为 `gpt-6-astra`、强度 `ultra`；实际 provider 模型证明、token 和费用未暴露，保持 unknown/null。native agent ID 由主代理 bind 记录，不把请求参数冒充模型回执。

## 结论

采用固定年月日控件＋当天内容，删除全日期侧栏。统一 `openSummaryFromMainFilter()` 入口每次处理用户意图：主面板明确选日时直接定位并切每日；窗口已开也生效。未明确选日时已提交日期为 nil，先显示选择提示，草稿不能冒充已确认日期。空白日保持用户日期并明确无记录，不回退第一条。

源码确认：日期 UI 的实际私有状态位于 `ExportSheet.swift/TimeFilterSection`，由 `push()` 写入 `ViewFilterSpec`；现有按钮和 Commands 没有传日期，摘要 UI 默认回退 `rows.first`。设计以 spec 的 day/同日custom 证明意图，捕获计算时 Calendar、校验生效范围，再转换为同一区的 Gregorian 自然日。明确主入口固定捕获 IANA 区；新日期使用自然日日界，保留 DST 23/25 小时及无效民用日期校验。

新增导航状态与报告索引不改变核心引擎。日期、草稿、模式和行程选择不进入统计缓存键，不扫描轨迹点；一次后台报告附带日／关联行程索引，同版发布与撤下。发布只解释当前导航日期，避免晚到结果恢复旧日期。跨日行程仍展示完整原行及明确说明，不按午夜另拆核心统计。

ADR 已列出明确接口、字段、文件所有权、来源/时区/模式/清空/关闭处理以及最小新验证。主代理已接纳固定控件方向，并确认日期实现与构建签名工作文件无冲突。

## 已做核验与证据

- 使用 engineering:architecture 技能；读取 AGENTS、README 摘要段、原摘要设计、Tests README 摘要验证段和当前窗口/State/Store/TimeFilterSection/App/核心类型/交通关联源码。
- 所有 capture 已知后的命令 argv、完整 stdout/stderr、真实退出码在本 run `artifacts/capture/`。阶段 progress 事件已写入 runner，补充指令原文在 `artifacts/bootstrap-and-messages.md`。
- 仅通过源码阅读核对设计契约；没有运行核心、Store、UI、规模或网络测试，没有构建、启动/关闭 App、修改偏好或安装。
- 核心22／Store70／实际功能12为任务明确提供及 Tests README 记录的既有证据，本轮继承而非重新执行。新导航测试计划明确未执行；实施后仅验证受影响行为。
- init 的 before 快照及 finish 的 after 快照/变化清单负责记录文档完整字节与哈希。产品源码未被本任务改动。

## 一次启动错误

首次误把 `capture.py --help` 当帮助命令，脚本不支持该参数，空 argv 在创建子进程前触发 IndexError，exit 1。误新增目录 `Tools/agents/records/2026-10-30-journey-summary/coordinator/commands/20261031T011631_--help_ce8eeaca/` 已保留并报告；其中不存在实际运行子进程，残留 running meta 不代表活动。初次 task/capture 源码读取及完整错误已补记本 run，不伪装为通过，不覆盖旧证据。

## 移交

由主代理 review ADR 后 `verify`；实现交 GPT-6.1 Sol / ultra，按当前授权验收并最终覆盖安装。架构任务至此没有产品实施或安装待办；文档仍 Proposed 直至主代理决定。
