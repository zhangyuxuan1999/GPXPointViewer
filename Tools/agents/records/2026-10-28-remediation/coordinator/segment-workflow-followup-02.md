# Astra已确认的retime最小修复

Astra /root/remediation_design 本轮实际源码审查决策：可采用7行提案 artifacts/retime-coverage-proposal.patch（位于native/20261028T232721.100499Z_r4-risk-audit_9c4dd021）。在既有投影、严格改时、15–350 km/h守卫之后，检查当前原位置→下一保留点/B的真实距离与新dt；触发GapDetector.isBreakStep时break。这补上“保留尾链无需再插点”的必要不变量；A侧后续removeLast只延长插值前缀，不破坏尾链。无需多区间补点/加风险分/放宽min>50。

这是已选择stale替换区间中的保留优化，不能扩成删除全轨迹稀疏点规则。timeGap及非stale保持原语义。P4仅允许同段local view，并将结果映射回global；实际删除/新增和修改记录必须一致。请将最小算法合入你当前分段实现；已验证97/84两个实际反例的测试fixture与复现代码在风险审计run，整合后用生产链重新检测确认两窗口不再遗留长gap，单段51自测/125考卷和其余98分数保持。

完整设计与必须边界测试矩阵由Astra保存在native/20261028T234643.994660Z_retime-design_3b343b89/output.md，当前正在定稿；主代理稍后补转最终矩阵。不得用废弃旧task-expectation.patch；最终r2只修错误说明，原vMinRisk>50保留。
