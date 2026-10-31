# 独立审查日期导航与持久化测试接线 — Sol ultra
请求gpt-6.1-sol/ultra。只读已冻结源、原始新navigation证据和差异；只写自己的记录，不跑产品测试/重编译/App/UI/安装。
用户要主面板指定日直接进入摘要（窗口已开也要跳转），未选日固定年月日输入，不列全部日期。读docs/journey-summary-date-navigation-design.md（已root接纳），coordinator/architecture-review.md与UTC编辑适配记录；实现run native/20261031T012543.656242Z_summary-date-navigation-implementation_a203875d/output.md和全部新验证原始结果。继承原核心22/Store70/实际12通过，不复跑它们。
审查Window/State/TrackStore摘要与viewFilter/ContentView入口/ExportSheet日历spec/App命令/UITestHook和新navigation测试/驱动。重点：明确日语义与有效range一致而非86400猜测；Gregorian转换/DST/Apia跳过日；固定可编辑草稿+提交，未提交或空日无first回退；已开窗口新revision；跨日完整行程；日期不入cache、不扫描点/全部行程；导航索引与report共同发布/清理、取消及source/timezone/late result不串状态；没有不必要核心数值变动。
持久化本轮根因在构建失sandbox，不重构原AppLanguage/idle逻辑。新增persistsettings只能测试模式+唯一测试bundleID+实际sandbox容器下写生产API；settingsstate限定必要键；第二/第三进程不得带语言覆盖参数冒充保存。驱动只能唯一测试域，不碰真实偏好/正式App。日期UI实际输入/截图仍待root后续一次执行，不能从hook直接setdate就宣称键盘控件已测。旧UI功能组如有行为变化需准确标继承范围。
复用原始编译/断言输出而非复跑。报告具体缺陷严重度/源码/证据，必要复测先指出原因。任何作者修复由root另派记录，你只复查diff/evidence。不额外读真实轨迹/私有prefs；完整capture/event/progress/output/finish，费用actualmodelunknown。禁止子代理/侧栏聊天。
