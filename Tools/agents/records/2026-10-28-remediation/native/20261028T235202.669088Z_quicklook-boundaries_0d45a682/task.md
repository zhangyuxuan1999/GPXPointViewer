# P4-A 独立复核发现的预览边界修复

模型 GPT-6.1 Sol / ultra。先收尾 r4-risk-audit，再执行本任务；注册后的唯一run目录为所有记录归宿。只修改共享scratch /private/tmp/gpxpv-segment-integration-o3kf8civ 的 GPXQuickLook/TrackShape.swift 和 Tests/segments/core/必要回归；确需parser采样改动先给主代理证据。产品主工作区仍不写回。

主代理源码复核证据：新TrackShape.swift draw仍只描线，最后只画scaledPts[0]绿点/last红点。P4把每个wpt标为独立段后，中间无边的孤立点不会被任何stroke或dot画出；3个孤立点即可出现中点消失。必须以真实无窗口bitmap/CG或NSGraphicsContext像素测试先证明，修成所有被保留的孤立点可见而不跨段连接，首尾标记语义保留。

另init里每段至少保留首/尾、按全局stride各段抽稀，1万两点段/大量wpt输出点数可远超原6000预算；且单隐式段建立Array(0..<n)多分配O(n)索引，median计算还会采到跨显式段距离。请修为有明确全局预算的段感知预览采样：允许预算不足时漏掉部分短段（预览原有采样语义），禁止把剩余不同段连线；每个被保留多点段保留真实首尾，孤点不凭空造边。median/softbreak只取真实同段邻接。不要为了预览重建完整主app拓扑或扩大预览点数预算。

测例：3个不同段孤立点真实像素均可见且桥不存在；1点/2点/交叠段；≥1万两点段与≥1万wpt预算；单段大输入不分配完整索引数组（结构检查/内存测量合理证据）；显式硬断与软断结合。按原顺序读入的预览无需做主app时间排序，不能声称原XML无损还原。保持QuickLook/Thumbnail原32MB分支策略。

所有实际命令、正常stdout/stderr、退出码、基线反例和修后结果、前后快照落盘。允许无窗口像素测试，不启动产品app/不联网/API/不安装，不另派代理。完成输出patch/完整报告。P4-C仅Metal/Shader不碰本文件；P4-B业务工作流也不碰本文件。

整合补充：B的GapFillExport.PointKey现计划含segment UInt32（默认0兼容单段），主代理已在GPXWriter.swift的synthetic.contains查询传真实segment，并同步Tests/segments/core/Support.swift的PointKey等值stub，窄改原件在coordinator/writer-segment-key.patch。请勿覆盖这两处；core测试增加实际GPXWriter两段有完全相同time/lat/lon但仅一段为synthetic的回归，检查输出标记<src>GPXPointViewer-fill</src>只能对应那一段，不能跨段误标。可在Tests/segments/core中补测试，但不编辑Writer其它实现；若发现问题反馈主代理。更新README明确stub与新增synthetic覆盖边界。
