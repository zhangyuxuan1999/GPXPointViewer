# Valhalla / RailPath 离线小探针

本目标只从当前 `GPXPointViewer/RoadNetwork.swift` 抽取 Valhalla 状态表达式和 RailPath 重建守卫，与现有 `main.swift` 编译一次、运行一次。实际返回码及 `RESULT passed=… failed=…` 决定结果，不按源文件里的调用行数猜检查数，不依赖文档字句或历史代理记录。

```sh
python3 Tests/probes/deepseek-small/run.py /private/tmp/gpxpv-deepseek-small-evidence
```

参数是证据父目录。每次在其中创建 UTC 微秒时间与随机后缀组成的全新子目录，打印 `Evidence: /绝对路径`；重复传同一父目录也不会覆盖原证据。所有支持源码、main.swift快照、二进制、module cache和日志均在新目录内，不联网、不启动app、不构建整个工程。

每个目录含 `source-hashes.json`、`extraction.json`、`extracted-support.swift`、`compile-command.json` / `compile-result.json` / `compile.stdout` / `compile.stderr`、对应 `run-*` / `run.stdout` / `run.stderr`，以及 `report.json`。编译失败时不执行探针；超时、非零退出和无法提取均保留证据并返回失败。抽取依赖当前单行表达式/守卫的形状，未来重构改变形状时需明确更新提取器，不能静默使用手抄旧实现。

只读验收、修汇总、重新整理报告应读取已有命令与原始日志，**不要再次执行本脚本**。汇总写入失败不会自动重编译/重跑；阶段日志仍保留。仅在已有证据具体矛盾、缺失或产品修复影响行为时，先在任务记录说明原因、原证据与最小范围，才开始新执行。脚本哈希变化后，旧结果仍属于旧执行，不能冒称新脚本已跑过。

2026-10-29 的恢复轮曾因静态检查误计22而实际重复编译/运行已通过的19项；该重复执行已如实记录在本轮代理证据，不作为推荐流程。本次运行器维护只用fake subprocess、Python语法和既有支持源码静态比较，不重跑产品19项。
