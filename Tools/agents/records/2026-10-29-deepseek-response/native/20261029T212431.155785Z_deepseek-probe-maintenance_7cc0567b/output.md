# deepseek-small runner 收敛完成

仅修改 `Tests/probes/deepseek-small/run.py`，新增该目录 `README.md`。未改产品或 `main.swift`。请求Sol/ultra，实际服务端model/effort/token/费用工具未暴露，unknown/null。

旧脚本完整保留 `artifacts/run-before.py`。新入口删除OLD_RUN、TARGET_FILES、固定文档句子/翻译清单/源码调用行计数等静态审查；只从RoadNetwork抽取实际Valhalla状态表达式与RailPath guard，生成支持源码，与main.swift快照编译一次、运行一次。

参数改为证据父目录：每次以UTC微秒+随机后缀创建唯一子目录并打印绝对路径，重复同父目录不覆盖。保存原始来源hash、提取内容、main快照、实际argv、每阶段stdout/stderr/返回码/耗时与汇总。编译失败不运行；PASS/FAIL真实输出与唯一RESULT行共同判定，不硬编码19或按源代码行数推算。失败不会自动重编译/重跑，汇总失败仍保留独立阶段证据。

## 本轮验证（全部fake/静态）

`artifacts/fake-checks.py` 使用fake subprocess拦截全部子进程入口；Python语法解析与 **136个工具断言通过，exit0**，**实际swiftc/产品probe调用均为0**。覆盖参数与快照、单次编译/执行、非零和启动失败/超时、缺失/重复/不一致RESULT、空检查不能通过、汇总写入失败保留阶段日志且不重跑、同父目录两次产生不同子目录及旧产物字节不变。完整脚本/命令/输出见 `fake-checks-result.json`、`fake-checks.stdout`、`fake-checks.stderr`、`fake-checks.json`、`fake-evidence/`。

给相同已知两片段，新extract与旧备份build_support生成逐字节相同支持源码，SHA256为 `1e6a61743e865390a794a0e8130d4582832ab5f1470bd25bb0198a07ed2b790b`，精确匹配root提供旧产物hash；生成物为 `artifacts/generated-support.swift`。当前整份RoadNetwork读取与旧恢复目录扫描各10秒超时，已报告root并停止重试，详见 `02-current-source-and-prior-paths.json`。这轮不声称新runner已对当前产品源码执行；root会以最终build的源hash归属既有产品结果。

## 历史重复执行据实记录

根据root任务输入，旧恢复轮 `deepseek/20261029T210624.045916Z_deepseek-bounded-finish_ecbb20c9/` 中产品19项已过，静态源码计数误为22导致汇总失败后，确实又编译/运行了这19项。原 `report.firstrun-static-count-bug.json`、最终 `report.json` 与events应保持原样；不能说从未重复。本轮不再重跑该产品目标，README明确只读整理/修汇总应复用阶段日志，不调用runner。

当前脚本验证仅属于本轮mock；旧脚本的产品19通过结果仍属于旧执行。源/文档hash见 `assessment.json`，前后快照/变化清单由runner保存。完成状态succeeded，独立验收pending。
