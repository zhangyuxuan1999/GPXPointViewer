# 后台多 result 协议独立审查

结论：**r4b 在本次明确的协议范围内可以验收，未发现未修复的阻塞问题。**本项执行完成，最终验收保持 pending，交 root 结合完整工具套件与原产品证据决定。本结论不把 provider 成功等同于任务断言、产品回归或可发布。

请求模型为 GPT-6.1 Sol / ultra；原生工具没有独立服务端模型/强度、token、费用回执，observed 均 unknown/null。审查应用 engineering:code-review 技能，只读共享源码和已归档正常事件；没有改根工具、测试、README、旧 run 或产品，没有运行 API、网络、app、build 或完整工具套件。

## 审查版本与边界

最终所审源码逐一复制到 `frozen-r4b/`，独立计算并匹配实施者冻结回执；最终漂移检查均相同。

| 文件 | SHA256 |
|---|---|
| Tools/agents/agent_run.py | c1c3a7a5a88c5c88efde796b79dc5fd18cde0b3cf6bd45c741cfbfeaf4278ed3 |
| Tests/agents/test_agent_run.py | 7a2fea6f5e7bf3b26daed9844b728bf9e9d4700ec89ca80bf2bca05200a0847e |
| Tools/agents/README.md | cd85af53c6084988989fb0285ced8a287ffe70a62b39a70337d53718d1d3a8d1 |
| Tools/agents/run_store.py（未修改） | 645ce840224051135000b7d2f8962464e63ff0218cf9746b0ef38f402a44fccc |

契约依据为 Astra 原 ADR 及补充收口：`native/20261029T120826.125375Z_background-protocol-design_945fc96b/decision.md`、`native/20261029T123126.015757Z_protocol-optional-schema_7cdcd40f/decision.md`。本机 CLI 2.1.310 schema 的 task_started.run_id/tool_use_id/is_backgrounded/task_type 均可选；一级摘录已保存在本 run 的 `cli-start-optional-schema.json`，精确来源为二进制偏移218145655。契约不要求本次实现完整CLI JSON schema validator，也不扩大命令、工具或文件权限。

## 独立发现与关闭证据

| 发现 | 修复前事实 | 最终核验 |
|---|---|---|
| F1 / P1：前景通知误拒绝 | r1忽略foreground start，却把其合法notice判为孤立。真实旧R4有57对这种遥测；一对加合成普通single success也failed。 | r4b登记前景并验证通知；前景合法/failed/stopped、重复/错身份、不能背书续轮均符合契约。全部真实136条task遥测重放无协议错误。 |
| F2 / P2：显式null当作缺省 | r1接受single result的session_id/uuid/result_index显式null。 | r4b按key存在校验；省略字段legacy继续兼容，显式null被拒绝。 |
| F3 / P2：可选遥测与认证混淆 | r2/r3对缺flag、run/type的合法辅助事件施加后台认证要求。 | Astra统一分层后，合法缺字段先留证；弱关联不回填start.run；只有完整local_bash+显式True+两端同run可授权续轮；任何显式True后台缺闭合链仍使成功候选unknown。38场景矩阵全过。 |
| F4 / P1：跨task复用已知run | r4重构遗漏全局已知run唯一性。两个不同task同run依次通知/消费，完整伪链可succeeded且errors空。 | r4b恢复已知非空run全局冲突，缺run辅助任务不被误杀。原85场景和额外完整伪链均正确，冲突不能被后续结果或EOF状态洗白。 |

修复由实施者完成，审查者没有抢改根源。r1/r2/r3/r4失败、对应快照与探针预期均保留；没有因最终通过覆盖原失败或调整预期。

## 独立验证

- 核心26场景、生命周期21场景、统一可选schema38场景全部通过，加上完整run复用伪链反例，共**86/86**。脚本分别为 `independent_probes_r4b.py`、`lifecycle_probes.py`、`optional_schema_probes.py`，逐case输入、实际分类、错误和关联证据均有JSON。
- 另外3项回执核验通过：start缺run、notice缺run均标weak且原run不被补造；完整后台缺可选tool_use仍标strong并由认证结果消费。
- 直接读源码并测试确认：中间success通过原classify_result，要求`is_error is False`；缺失/0/字符串不能代替False；bool index被拒；index/UUID/session/origin精确链、同session重复init、通知早于前一result、通知唯一消费、孤立/歧义/重复和工具ID冲突均按契约处理。
- 全部历史start参与缺run通知匹配；已终结A与未终结B同task仍有两个候选，不能让A的重复无run通知误绑B。
- 前序error/limit/空报告不可被末success洗白。明确末limit、runner信号、普通非零/API错误保持原分类优先级；后台不完整只将本来succeeded降为unknown。failed/stopped通知是任务状态，不自动改成provider错误。

这些是本地JSON/冻结class探针，不执行流中的工具payload。完整带时限工具套件由实施者/root串行执行，本审查没有并行重跑，不能把其套件数量或耗时冒充本审查实测。

## 真实流重放与费用

直接重放原 `deepseek/20261029T112901.777425Z_r4-remaining_d3ab729e/transcript.jsonl` 的11989事件：r4b得到succeeded、2个结果、0协议错误；session/两UUID/0→1序号及task-notification来源均能闭合。末报告SHA256为 `82f1ac96ef206700e1ee08ac890210ab26ff86df6f1abb4addbf4826512bcfce`。

末CLI累计估价为1.4677930000000001，未与首轮0.137745相加。末usage为86590 input /22682 output，末modelUsage累计98022 /25099；两种口径保持原意，实际费用仍null，不能称供应商账单或后端精确模型证明。raw transcript保留各轮原字段，turn_results只作关联元数据，不对usage累计。

还按原顺序重放旧 `20261029T011600.159549Z_r4-final_fa1fd007` 的全部136条task start/notification遥测：57前景、11后台、0协议错误；因为此被中断原流没有result，结果仍unknown。没有伪造该旧R4通过；最小正例补的single result已明确标为合成。

原剩余流transcript SHA256仍 `712b4c722a20c6724d6dea61934d5675e04481ef01af578da9118d4144277cd8`；原result SHA256仍 `1863fec91201484cb58c1de599bcd29feb2085917fe44d5998a711ee04f22378`，保留failed / multiple final results / CLI exit0。复判是本run的新证据，不倒改历史。

## 留档与限制

最终证据索引为 `review-result.json`、`frozen-source-r4b.json`、`final-source-drift-check.json`、`r4b-real-stream-replay.json`、`r4b-known-run-reuse-complete-chain.json`、`r4b-real-foreground-telemetry-replay.json`、`r4b-correlation-receipt-checks.json`。正常命令/输出/退出码保存在commands；初次结构提取helper因tuple JSON键序列化失败，attempt01错误保留，之后自洽_r2正常完成，该helper错误未当被审程序失败或通过。

共享源码由实施者在审查期间修订；本run的前后watch差异不能自动归因审查者。审查者所有写入均限本run，最终审查以独立冻结源码与最终hash为准。没有新的服务调用或UI复测，精确后端、实际费用及一般CLI所有未来版本兼容性均不在本项证明范围。
