# 日期导航新文案与相关使用/构建说明 — DeepSeek Flash max
模型deepseek-flash/max。只做明确的翻译/文档工作，不改产品/Tools/现有catalog，不跑App/构建/产品测试，不改真实偏好。不创建侧栏/会话持久化或代理。
允许改：新增Tests/l10n/translations/chunk_32.json；README.md；Tests/README.md；docs/journey-summary-guide.md；docs/journey-summary-date-navigation-design.md（后者仅Status改Accepted及下面的UTC编辑适配一段，不重写架构）。
输入：当前AGENTS；Tests/l10n/RULES.md与chunk_31.json术语/格式（其中旧全套测试/安装审批流程是历史，不执行）；native/20261031T012543.656242Z_summary-date-navigation-implementation_a203875d/artifacts/new-localization-keys.json（13位置/12唯一key）；当前上述文档；docs/local-install-signing.md；coordinator/architecture-review.md。
1. 写chunk32数组12条精确去重，table/key/comment/en/de/zh-Hant格式，沿用chunk31术语，保留%@。不抽键、不编译、不覆盖别的chunk或Localizable.xcstrings，root之后增量组装。
2. 使用指南和README摘要入口改：主面板明确选一天再点击直接打开该日，已开窗口再次点击更新；未选/年/月/多日先选择年月日并“查看”/回车；无记录日明确提示不跳别日；固定日期控件，当日完整指标/关联行程，跨日行程保持完整指标。整源缓存用于计算，但浏览跟随入口所选日；浏览不自动改主地图，地图按钮才改。移除旧“摘要打开忽略主面板日”和全日期列表交互表述，数值规则不改。
3. README构建示例与Tests/README当前推荐构建命令应使用保留项目签名的 python3 Tools/build_release.py --arch arm64（必要时--no-icloud-coordination），--no-sign仅显式诊断且不可安装。保留历史证据但不能让它成为默认正式安装示例。说明最终签名/权限验证及新Tools/install_release.py的已授权安装命令，详情链接docs/local-install-signing.md；不宣称新真实构建/跨进程测试已经通过，当前结果由后续docs/journey-summary-date-persistence-acceptance.md给出。旧核心22/Store70/功能12证据继承，不要求无差别再跑。
4. ADR表头Status改Accepted（root已验收），DatePicker编辑说明补小适配：UTC只作日期字段civil YMD编辑载体，以表示实际区跳过的日期；统计/校验仍用实际IANA区，显示实际区；非法实际日保持输入并报错，不跳日期。其他契约不动。
可运行唯一验证命令（原样，不加env前缀或shell重定向）：
python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-31-summary-date-persistence/coordinator/validate-date-docs.py
运行器已注入GPXPV_AGENT_RUN_DIR。只验证新翻译结构/键/占位符并保存当前允许文件hash；不执行旧RULES全套gate。运行一次，失败仅修具体新翻译问题后再运行且留失败。
记录before/after快照/精确diff（runner也会保存），progress阶段/完整output，验证输出在artifacts/validation.json；如果无法计算某些字段记unknown/null，不冒造。实际模型/费用无回执记unknown/null，完成报告给root验收。
