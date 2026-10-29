# 任务：地区边界数据第 3 次抽查（只读；用探针，不启动 app，不跑 xcodebuild，不改任何文件）

你是这个项目的审查员。仓库 /Users/zyx/Documents/GPXPointViewer，索引 GPXPointViewer/Regions.bin。前两次抽查的报告在
saved-agent-results/api-runs/*_spotcheck-world*/output.md（只读参考；路径前缀 /Users/zyx/.claude/projects/-Users-zyx-Documents-GPXPointViewer/），这次改了：
法/意/西/英按大区分组（省作二级）、简体名清洗、台湾名、地级名、缝吸附两层。探针：
  Tests/probes/regions/run.sh --real GPXPointViewer/Regions.bin --lookup <lat> <lon> …
  Tests/probes/regions/run.sh --real GPXPointViewer/Regions.bin --audit
  Tools/regions_debug.py GPXPointViewer/Regions.bin lat lon   （列出数据里包含该点的全部环，不经裁决规则）
请做：
1. 法/意/西/英各 8 个城市（含海外省、北爱、威尔士、加那利、科西嘉、撒丁、西西里）：期望「省 < 大区 < 国家」或「大区 < 国家」（单省大区），逐点判定。
2. 复测前两次的 80 点里所有曾出错或存疑的点（巴尔勒、北塞海岸、克里米亚、康斯坦茨、格尔利茨、费尔内、戈里齐亚、基亚索、威尼斯、朗伊尔城、香港机场、路氹、直布罗陀、关岛、法罗、马恩、泽西、根西、波多黎各、阿鲁巴首府与岛内一点、坎皮奥内、布辛根、圣马力诺城、台北）。
3. 名称体检：用 python 只读解析 bin 的名称池（格式见 docs/regions-design.md）或从探针输出里，找出所有仍含繁体字、全角连字符、台湾译名或明显错别字的简体名；检查新建的大区名四语是否齐全。
4. 再抽 30 个你能确定的世界城市（亚非拉为主）。
5. 输出 Markdown 报告：表格（期望/实际/判定）、不符项原因分析、名称问题清单、一句话结论与最该先修的 3 件事。规则同前：不启动 app、不跑 xcodebuild、不写文件。
