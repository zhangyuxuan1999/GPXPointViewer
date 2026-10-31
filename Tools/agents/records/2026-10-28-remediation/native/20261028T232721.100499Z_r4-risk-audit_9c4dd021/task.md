# R4 offset 风险得分异常独立复核

模型 GPT-6.1 Sol / ultra。用户要求发现的问题都修，不能为了测试通过改预期。此任务先独立定位，证据支持产品缺陷则修其最小逻辑；支持任务书不成立则修任务书/回归判据并保存反例证明，不拍脑袋归类。

R4当前安装版（2026-10-28 14:12 Berlin，exe 11590960字节）已通过11组UI脚本和114合成/125题考卷/51自测。手工§6 fake OSRM ok + Valhalla offset30, 普通模式、riskthreshold50：Valhalla50项，49 high且有原因不勾选（98%，符合≥95%），1项risk0/include true；4项risk55。任务书另要求所有Valhalla最小值>50，与比例容许及已知停留可能矛盾，需要实际验证。

原始证据目录 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/deepseek/20261028T225704.094186Z_r4-baseline_b44e2242。全量状态 artifacts/logs/sec6/0047_state.log，结果 artifacts/results/sec6.json，reg1原脚本也记录同一outlier。它id/tA=1792256646、ckind=stale、inner7、nature=lol、auto=rail、kind=road、source=valhallaCar、meters4541、shiftA/B0、warnings0、risk0、riskReasons[]。完整任务 Tests/tasks/2026-10-28_loose_ends_threshold_r4_codex.md §6；源FillPlausibility.swift、TrackStore.landingJob/风险计算、StaleRetime、UITestHook/RoadNetwork fake实现和设计文档。

实施规则：仅在 /private/tmp 唯一scratch做实际生产Swift局部probe/回归，主产品未整合新分段前保持原源码基线可用于对照。可以读取合成/本地Garmin数据；优先纯CLI重放相同candidate/route/retime/splice链，输出addedPoints、vertices、routeRaw、fillB、retime keep/removed、actual metrics与risk，查明offset是否在真实要落地几何中保留。风险0若对应没有偏离的落地geometry不能强行加分；若实际偏移被漏采样需修逻辑并补可失败用例。4项55也必须按实际allowance/score来源解释，不凭“约95”注释修改阈值。

无公共路网/API，无产品app/Applications安装。需要UI诊断必须先向主代理说明并取得唯一测试副本时段，不能与R4/其它UI并发；优先不需要。不要另派agent。你不拥有P4-A/B/C的共享scratch文件，产品修复若需GapFill/TrackStore提供局部patch和接口协调，不能抢写。允许修scratch FillPlausibility和新增独立回归，并在本run给任务书修改建议/patch。

记录所有消息、命令stdout/stderr/退出码、原源码hash/前后快照、输入输出/完整结论。输出明确产品bug/任务预期bug/环境情况，不能因CLI正常结束判通过。主代理负责整合/复核与最后DeepSeek重跑。
