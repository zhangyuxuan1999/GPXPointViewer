# P4-B容量中断恢复计划

继续原任务范围，不换模型：GPT-6.1 Sol / ultra。原run 20261028T234103.668824Z_segment-workflow_e62fc474 因原生模型capacity错误结束，原件保留。shared scratch /private/tmp/gpxpv-segment-integration-o3kf8civ已有实施，不能从头重做或覆盖。

先读取旧task、followup-01..05、progress、interrupted-output、commands.jsonl及artifacts。核验源hash和已完成测试，检查旧114/125兼容门真实结果；有还在跑的自身CLI先取回/等待输出，不重启同套，不触碰其他进程。已完成175首套、独立reviewer重跑增强183/183及自写29/29；这些报告归属区分准确，不能冒称自己执行他人的探针。

剩余只做必要收尾：如新反例确需修产品先通知root与reviewer（root正在scratch Release构建）；否则保存9拥有文件最终快照、Tests/segments/workflow源文件清单/patch、3新增3移除本地化以及完整输出、已执行/未验边界；给正式冻结hash。不要再次重复无变化的通过测试。当前root产品源码未写回，l10n/newbuild/DeepSeek最终UI由root协调。

新run与旧run以context recovery关联，原容量失败不覆盖为成功；阶段event和progress、正常命令/错误/退出保存。完成provider succeeded、acceptance pending，独立审查与主代理验收另记。
