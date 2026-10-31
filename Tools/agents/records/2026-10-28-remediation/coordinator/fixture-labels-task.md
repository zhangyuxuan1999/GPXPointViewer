# 四条测试描述元数据收尾
请求DeepSeek V4.1 Flash / max。用户已允许仅本项目复测所需文件。
工作目录/Users/zyx/Documents/GPXPointViewer。最终R4已结束后，补齐独立Sol审查发现的Tests/README日期/理由约定。只改4个已审提案文件（两个gen.py、两个expect.json）的四条desc，不改任何数值、程序逻辑、产品或基线。
主代理已在coordinator/fixture-label-proposal保存4文件提案、精确前后hash和patch，并用AST确认generator仅四段字符串变化、JSON除四个desc外全部相同。无需再次运行UI、build、REGEN或API。
先阅读本任务与proposal/manifest.json。然后只执行一次：
`python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/coordinator/apply_fixture_labels.py`
该脚本要求R4 result存在、当前文件hash匹配、只写4文件并保存本run下前后副本/patch/receipt。失败原样报告，不自行绕过precondition或重做迁移。成功后Read自己的receipt，写自己的progress/output简短汇总，真实执行/结果由runner全量留档。不要为了列目录运行未经允许的ls/find/bash组合。不要读取凭据/环境全集/无关文件；不要启动其他agent。
这只是说明文字收尾，不冒称重新完成了整套R4；主代理随后独立核验hash和说明之外的数据不变。
