# R4 真实补点覆盖缺陷最小设计审查

模型 GPT-6 Astra / ultra。用户指定底层/重要设计由你。只读代码和证据，不实现、不调API/网络/app、不另派代理；输出本run/artifacts中的分析与最终output/progress，执行命令输出保存。

独立Sol已通过真实生产Swift+实际fake路由/landingJob/GapSplice链确认：当前安装基线R4 candidate tA1792256646（stale，inner7）在Valhalla offset30普通模式中risk0。risk0对实际几何正确：StaleRetime保留近A两个仅改时+2s点和近B五个约+110s点，首保留点在第一个偏移顶点前，plan.vertices=[]，仅加2点；全落地窗口偏离raw线最大1.561m。但实际splice后重新生产computeCandidates还剩tA1792256650→1792256759，109s/4195.402666m timeGap，补点没有完成。

证据与提案：/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/native/20261028T232721.100499Z_r4-risk-audit_9c4dd021/。读output（若尚未定稿则progress/对应artifacts和命令记录）、artifacts/retime-coverage-proposal.patch及对照结果。Sol正验证提案：倒扫出口保留点时按改时后的dt和原位置，用已有GapDetector.isBreakStep判断连续性；一旦当前点到更晚已保留点仍形成大gap，就停止收更早点，仅保留连续出口后缀，让A→真实出口沿完整route插值。预先验收目标：目标候选变5retimed和>100synthetic、无残余gap；其它99项risk不变。完整未裁route及保留2点真正offset30两个负对照均risk85，证明评分未忽略stale。

请判断该最小修法是否符合“只保留真实连续出口点、补点覆盖整个候选、预览=落地、避免乱删有效原点”的既有语义，和P4段内index/view迁移如何兼容。严查边界：连续出口/只有1个出口/重复时间/缺时/停留/停车/真实长采样间隔/分段边界；是否需要更保守拒绝或多区间补点，而不是只看一个fixture通过。不要把这个任务扩展为新路由系统；在证据足够时给明确可实施决策与必须测试。

实施owner为/root/runner_implementation，正做P4-B shared scratch /private/tmp/gpxpv-segment-integration-o3kf8civ，暂未采用此算法提案。你只给设计与接口，主代理转发。保留目前时间规范化/GPX分段语义，不能加风险分来掩盖underfill，也不能只修任务书min阈值后宣布产品无缺陷。

最新实测修正（优先于上面的99项预期）：coverage-proposal-r2已完成。97项改为112合成+5改时、risk85；负对照发现另一处同类underfill：84项/1792244850（OSRM，chain2）旧计划13合成，早期1点与出口3点之间仍152s，修为169合成+3出口改时、risk10（实际max8.414m、median约0，仍low）。两处splice后均无残余候选；其余98项分数精确不变、四项55不变。现有51自测和125录音考卷都通过（pass121/125、artefact123/125、parallel125/125、high∧pass0；requests0/replayed255/missing0）。旧task-expectation.patch不得采用；r2任务patch保留原vMinRisk>50，修复后实际min55。7行算法patch仍等待你的边界审查，不能因测试通过而免审。
