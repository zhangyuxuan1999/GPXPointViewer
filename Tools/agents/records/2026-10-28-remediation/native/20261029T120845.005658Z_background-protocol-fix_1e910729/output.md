# CLI 后台多结果协议修复完成（r4b）

实现按请求模型 GPT-6.1 Sol / ultra 执行；服务端模型回执与实际费用未暴露，保持 unknown/null。最终执行成功，提交 root 独立验收，acceptance pending。

原runner把第二条result一概判为multiple final results；现在区分辅助任务遥测、唯一通知关联和后台续轮认证。多result需同session、从0连续index、唯一UUID、完整local_bash/显式后台/两端run一致和未消费终结通知。跨session、孤立/歧义/重复、同已知run跨task、前序错误、空成功报告仍失败。

前景和缺后台标志的合法事件独立留证；缺run/type/tool可作辅助，弱匹配不补造认证。显式后台即使证据不足仍有EOF义务，未完成/缺认证续轮为unknown。failed/stopped任务通知与provider状态分别保存，验收不由provider成功代替。末limit、超时、信号和非零原分类保留。CLI最后累计费用不相加；实际cost_usd仍null。

## 修改范围

- Tools/agents/agent_run.py：结构化reducer与runner集成、锁定session、逐结果与task证据。
- Tests/agents/test_agent_run.py：新增23方法，含64辅助字段组合、后台正反例、真实runner转发。
- Tools/agents/README.md：协议与费用说明。
- Tools/agents/run_store.py：未修改。产品源码、capture.py、原失败记录未修改；未运行产品测试、app、网络/API。

## 验证

- 冻结r4b完整109/109通过，33.302s，exit0（054）。包含原86和新增23方法。
- 独立Sol审查85/85及3项weak/strong/no-backfill回执检查通过；审查源与最终四文件hash一致。root仍须独立验收。
- 真实11989行后台流：parser及真实runner只转发重放16/16断言通过（056）；两结果、末报告精确相同、累计CLI估价1.467793保留、原4文件hash不变、原failed不改写。
- 真实旧12480行流：57前景/11后台事件接纳，原无result保持unknown；独立最小真实前景对+明确合成single报告对照12/12通过（057）。该合成探针不证明原整轮完成。原4文件hash不变。
- 初始86探索轮一次Git收尾elapsed断言失败（12.0784s要求<7）；原child3.5028s、Git内部3.3896s，额外耗时在invoke归档/调度范围，准确外部原因未证明。孤立复测3.311s通过；阈值未改。原失败和r1–r4中间独立缺陷证据均保留，不以最后通过覆盖。

## 留档与独立复核

全部正常命令参数/stdout/stderr/退出码在 artifacts/commands。最终hash：artifacts/frozen-source-r4b.json；完整前后文件与hash：artifacts/source-before、artifacts/source-after及对应hash JSON；新增/删除/修改：artifacts/validation-summary.json；完整改动：artifacts/implementation-final.patch。runner finish自动保存after快照和changes。

独立命令见 [independent-verification.md](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/native/20261029T120845.005658Z_background-protocol-fix_1e910729/artifacts/independent-verification.md)。完整机器结论见 [validation-summary.json](/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/native/20261029T120845.005658Z_background-protocol-fix_1e910729/artifacts/validation-summary.json)。架构最终契约为 Tools/agents/records/2026-10-28-remediation/native/20261029T123126.015757Z_protocol-optional-schema_7cdcd40f/decision.md。
