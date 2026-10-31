# 复测runner的分段身份窄迁移

模型DeepSeek V4.1 Flash / max。用户已明确允许DeepSeek仅处理本项目复测所需源码/脚本/任务/日志，证据coordinator/deepseek-data-authorization.md（完整前缀/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/）；禁止凭据、无关私有文件、其他项目、网络搜索或再派agent。

工作副本 /private/tmp/gpxpv-segment-integration-o3kf8civ。仅可改 Tests/synth/runner/main.swift 与 Tests/synth/runner/exam.swift；不用改产品、任何期望、baseline或数据。只使用Read/Glob/Grep/Write/Edit；不执行Bash/app/测试/API。主代理会单独编译/回归。记录progress及最终逐项改动/未测试边界，runner保存正常过程和结果。

本文件的process pipeline曾是TrackStore检测副本，产品已迁移显式段。请做以下精确且最小修改：
- 原encloses/overlaps helper加 `trackID`、`segment`相同前提，区间比较用 `pathA ?? indexA` 与 `pathB ?? indexB`，不能因global时间区间交叠把另一段候选吞掉。共端点仍不算overlap。
- nature字典从 `[Double: GapNature]` 改 `[GapID: GapNature]`，写入/查询用c.id，不用tA作唯一身份。
- `GapDetector.mergeChains`已由Sol明确修改契约：canMerge闭包传相邻的两个原始候选，累计合成candidate只用于输出，故nature可按原GapID查询；无需你改该函数或维护合成ID。
- 仔细核对profile/detect/jitter调用与当前TrackStore.computeCandidates的段内profile选择。如果保持旧全track profile会导致多段诊断与产品不一致，请按已经存在的产品公开helper作最小对齐，不复制/重写算法、不编辑产品。输出顶层profile字段保留原含义，机器JSON格式/时间/统计字段名称不变。如果不能仅改本文件完成，请停止这部分并准确报告，不擅自扩大范围。
- 所有现有单段114/125数字和JSON语义不能改，不修期望来迁就实现。不要把脚本改完声称测试通过。

exam.swift 还须一处机械修正：synthetic 的 keep 删除选点在同步过滤 lat/lon/ele/time 四列后，追加 `if !p.segmentID.isEmpty { p.segmentID = keep.map { p.segmentID[$0] } }`，保证显式段列与点数一致。此前真实125题会在首个synthetic因segmentID长度不一致触发precondition；Sol在归档副本补此一行后125题维持原基线。只做此行，不改考卷题意、评分、网络或其它算法。

只读必要输入main.swift、exam.swift相关keep过滤段、GPXPointViewer/TrackStore.swift的computeCandidates片段、GapFill.swift的相关公开helper与mergeChains；不要读取整个Claude聊天、凭据、数据文件或无关代码。产品已冻结，请记录读到的接口和假设，最终任务报告供主代理复核实际diff。
