# 最终独立留档验收审查
模型 GPT-6.1 Sol / ultra。工作区 /Users/zyx/Documents/GPXPointViewer。
用户要求修好代理/API调用与留档，再由DeepSeek补完第4轮，全部任务/过程/结果保存。
目前产品57文件已hash门控写回根目录，Release构建成功，DeepSeek final R4正在唯一run `deepseek/20261029T011600.159549Z_r4-final_fa1fd007` 执行。不得运行app、UI、xcodebuild、测试套件或API，不可改产品、测试、工具、历史结果、docs、总索引；只写本任务run内归档。主代理负责最终docs和验收。
目标：独立只读抽查本批次留档是否满足用户要求；核对重要修复是否有自洽任务、执行与结果、source快照、独立验证，尤其T9/T10/T11、P4-B恢复、4case合成迁移真实失败与实际side effect、最终root57files integration/build。不能为制造整齐结果改旧failed为passed。最终R4仍运行中，明确pending，不跟踪或重复它的测试。
输入：AGENTS.md、Tools/agents/README.md、records/2026-10-28-remediation/{issues.md,progress.md,coordinator/*review*.md,coordinator/final-tools-verification.md,coordinator/product-integration-applied.json,coordinator/final-build-bundle-manifest.json}及相应native/deepseek run中必要元数据。不读庞大events全文；不读凭据/环境全集；不搜索其他私人内容。
特别核对：未知token/cost=null；请求model/effort不可当服务端证明；旧失败保留；根目录当前源hash与最终freeze/build声明一致；日志是否误把mock当真实API或被拒调用当运行；早期fixture污染AGENT_LOG应保留原件但给出正确摘要方法。
开始先读取run task/meta，将进度写progress并通过agent_run.py event RUN --type progress --json更新。每个主要命令/正常工具结果写command-output；保存自己的artifact和output，结束finish succeeded / acceptance pending，主代理verify。不要索取/保存内部思维。
产出output.md：真实发现（若无则写无，不能为了审查臆测）；每个证据结论对应路径；可由主代理直接用于最终摘要的状态表。任何重要未闭项立即通知root。费用/服务端模型不可得写unknown/null。
