# 结构化上限非零退出分类修复

已修复并冻结：明确的 `error_max_turns` / `error_max_budget_usd` 或既有结构化上限原因，在 CLI 正数非零退出时记录为 `interrupted`。真实退出码照常保存，不把上限中断冒称成功。只改 task 指定五文件，没有改 agent_run.py/api_run.py、产品或已落地迁移；没有 API、凭据、网络、app 或重新派发。

请求 GPT-6.1 Sol / ultra；实际服务端模型/强度独立回执、token、费用 unknown/null。本任务 provider succeeded、acceptance pending，由root合并最终suite验收。

## 根因与精确复现

原 classifier 先执行 `error or exit_code != 0 -> failed`，使正常以1退出的 limit final 根本无法抵达后面的结构化上限分支。

取真实 `deepseek/20261029T010037.881134Z_synth-migration_5cb2a1a8/transcript.jsonl` 已存final（subtype error_max_turns、terminal_reason max_turns、errors包含Reached maximum number of turns(30)、num_turns31），由本run自建纯离线CLI原样输出并exit1。不是重放8文件迁移，也不是调用模型。

| 精确相同final + exit1 | 修前 | 修后 |
| --- | --- | --- |
| provider_status | failed | interrupted |
| child exit_code / runner_exit_code | 1 / 1 | 1 / 1 |
| subtype / terminal_reason | error_max_turns / max_turns | 原样保留 |
| 验收 | pending | pending，verification not_run |
| result/output/after | 均持久 | 均持久 |

before/after完整命令、stdout/stderr、result、after快照见 `artifacts/before-actual-final-cli/`、`after-actual-final-cli/`。真实原失败未改写，result SHA仍为 `181c8589cb83ce75a85e174d31a938bda32817b477755f54a3222e3b97920c19`；核对在 `original-failure-preservation.json`。

## 最小实现与保留契约

`classify_result` 保持已有显式 interrupted 标志的优先级。随后先拒绝runner/协议错误、无法核实exit、子进程负数信号退出、API错误，再识别结构化limit，最后处理普通非零失败与成功字段。无final的exit0仍unknown，非零仍failed；非limit非零、provider错误、坏JSON、空成功输出、缺成功字段均不能因此变成成功或limit中断。

limit final 的 `is_error=true` 与 `errors` 中的上限说明是正常结构化中断证据，不能据此把真实轮次上限重归一般失败。相反，外部解析/协议错误或明确API状态仍优先failed，避免合法limit字段掩盖另外的异常。父runner的timeout/取消路径保持原中断契约。

新增两项unit方法与两项CLI方法，fixture只扩展 `turns-nonzero`、`budget-nonzero`、`turns-nonzero-protocol`。README说明状态与真实退出码区别；未更改进程清理、runtime自动join或预算结算代码。

## 实际验证

本代理执行9个针对性方法，**9/9通过**（3.887s），输入前后hash完全相同。没有并发重跑T10全suite，也没有写原runner-tests日志；helpers的RECORD/TEMP_ROOT只重定向到本run唯一fixture/evidence目录，合成records带 `.offline-fixture` 标记。

- 分类器：正数非零 turns/budget、既有exit0上限、结构化budget别名；runner/协议/API错误；缺exit、负数信号、无final及普通success+exit17对照。
- 真实离线CLI：两个非零limit均interrupted，child/runner退出1、after/output/result完整、acceptance pending/verification not_run、费用null。
- 坏协议与limit同时出现仍failed；普通非零、provider、空成功输出、自发信号仍failed；no-final仍unknown；timeout仍124/interrupted；普通成功与stderr仍success。
- 另用真实已存final精确跑修前/修后两次独立CLI，结果如表；原迁移失败证据SHA未变。

完整9方法名、命令/结果、正常输出及stdout/stderr见 `artifacts/run-targeted.py`、`targeted-result.json`、`targeted-inputs-before/after.json`、`command-output/20261029T010951.490073Z_ca18455b.txt` 与本run `evidence/`。

## 冻结交接

5修改、0新增、0删除，完整前后副本、SHA与patch：`artifacts/before/`、`after/`、`final-manifest.json`、`structured-limit.patch`。

最终RunStore SHA-256：`645ce840224051135000b7d2f8962464e63ff0218cf9746b0ef38f402a44fccc`。

未改依赖输入：agent_run `8a290ab33b4f9f3bb4b358c51832295be08764dd5aa77a495cf3663c3786156d`；api_run（实现者runtime join增量）`47b8a70db0066f36190ebfdb76b75bb246ea9cf23f2c9bd7d3a3f7f8b22de74c`。本任务的针对性结果不冒充整套新组合已验；实现者旧82全量输入RunStore为05ad0abd，明确不同版本，root需合并最终suite。此前T10独立review只覆盖API35e，runtime join新增段的验收归root/实施者证据，本任务不倒填旧审查结论。

未留下本任务待修问题。完整新组合suite、后续真实DeepSeek及迁移验收由root负责。
