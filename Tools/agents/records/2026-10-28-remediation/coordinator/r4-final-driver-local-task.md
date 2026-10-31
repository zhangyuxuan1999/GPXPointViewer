# 准备第4轮修后复测调度脚本（不执行app或测试）

模型 GPT-6.1 Sol / ultra。原DeepSeek准备调用在进程创建前被自动审批拒绝，等待用户确认外部处理范围；本地native Sol准备脚本是获准工作的独立部分，不会调用DeepSeek或绕过该拒绝。本任务步骤明确，只准备脚本并复核，不运行任何Bash、app、测试、网络/子agent，不编辑产品或既有测试。完整最终报告由runner保存；progress和artifacts用runner提供的唯一目录。

输入：
- 旧基线脚本 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-work/driver.py
- 复测任务 Tests/tasks/2026-10-28_loose_ends_threshold_r4_codex.md
- 旧基线独立复核 coordinator/r4-baseline-review.md，及风险审计 native/20261028T232721.100499Z_r4-risk-audit_9c4dd021/output.md（均位于当前remediation批次）。

唯一允许脚本写入目录：Tools/agents/records/2026-10-28-remediation/r4-final-work/。请创建driver.py及README.md。完整复制旧脚本功能，做以下精确修改：

1. RUN从必需环境变量GPXPV_AGENT_RUN_DIR读取，不可硬编码旧run或当前准备任务run；每次实际复测的日志属于该次runner。
2. APP从同目录build-manifest.json的app字段读取；该manifest将由主代理在构建后创建，现在不得捏造。启动前验证路径存在、Contents/MacOS/GPXPointViewer的SHA256与manifest.executable_sha256一致，拒绝/Applications原包作为本轮测试来源。ENV的GPXPV_APP固定为这个APP；所有复制来源均为APP，/Applications只作正式进程的观察对象。
3. prep关于ui.app_source的检查文案改为固定新构建，记录manifest/二进制hash；允许manifest尚不存在时在脚本真正运行时给清楚错误。本任务只准备，不能启动prep。
4. 已知旧误报修复：字符串确认需保留现有UTF16LE/BE/plist支持（如旧脚本某路径缺，补齐）；cleanup比较生产app测前PID集合是否仍在测后集合，测前本来为空且测后为空应通过，不能要求bool(prod)。不能关闭正式app。
5. docs不再断言README固定行号160或185，只判断内容/实际文件列表和计数，保留31个run_及25suite数值契约；有计数变化必须报告，不能自动改期望。
6. §6严格vMinRisk>50保持；55是合法high，不再记偏差。其余比例/候选/分数基线绝不放宽。关于覆盖，README明确本脚本§6只检UI分数，两个underfill落地回归由主代理新增独立生产测试并另交结果，不假装脚本已经覆盖。
7. sec5仍输出zh-Hans/en/de真实截图及windows 960×800证据；要求最后报告交主代理看像素，不能仅靠PNG存在宣称没有裁切。文件名不得复用旧run输出。
8. 完整日志、实际退出码、timeout、commands.jsonl、阶段结果/状态和cleanup保留。不能保存凭据。sync_progress若保留只允许读取本新工作目录或当前run内.md，防止误写旧run。不要删除任何原始失败记录。

README写明实际运行步骤prep、11reg、synth、selftests、sec2/3/4、sec5三语言、sec6、docs、cleanup，说明需要root先提供真实build-manifest.json且只能一个测试副本。只调用已有离线脚本/假引擎，完整run_suite/record/真实公共路网仍禁止。无需额外自主发散或写新框架。

请在最终答案列出改动点、明确未运行app/脚本、文件路径，以及需主代理检查的语法/范围事项。不要把仅准备完成写成R4通过。

运行记录要求：本任务目录由agent_run init提供；正常命令/输出/退出码/前后快照必须存盘，阶段event和progress维护，finish acceptance pending。可运行仅AST语法解析和无副作用单元检查（例如导入不应启动app/没有manifest给出清楚错误），不得实际执行prep/reg/app/模型API，不派子代理。其余原任务限制保持。
