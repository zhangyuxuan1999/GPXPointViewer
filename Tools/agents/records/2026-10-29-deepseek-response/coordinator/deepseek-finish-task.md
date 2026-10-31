# 只完成上一轮剩余验证与报告
模型deepseek-flash/max。旧轮已写完产品/文档，但70轮上限中断。先读本目录recovery计划、旧run result/changes、现Tests/probes/deepseek-small/main.swift。不要重读全项目和大篇README；不要再次编辑产品/文档。用户要求复用证据、只补未完成项。
旧run：Tools/agents/records/2026-10-29-deepseek-response/deepseek/20261029T205753.317876Z_deepseek-bounded-fixes_3c79b2ac。原task/progress及正常调用都在该处，根因非模型容量、非产品失败。只继承原13文件变动；当前root/Sol继续整合，不碰他们的文件。
只允许写Tests/probes/deepseek-small/run.py（必要时修新测试main.swift）、本run progress/artifacts。命令只python3/xcrun swiftc局部离线探针及只读；不读凭据、不再调用agent/API、不启动app/UI/路网/全工程构建、不提交/安装/清理旧文件。不要用shell复合变量赋值/shasum，之前CLI拒绝；用python3读hash和subprocess记录stdout/stderr/argv/真实exit。必要时-module-cache-path放本run可写目录。
剩余工作：
1. 创建run.py，接收证据目录参数。读取实际RoadNetwork.swift，从fetchValhalla里精确抽 `return .status(...)`表达式成 `func valhallaStatus(_ ec:Int,_ err:String)->String`，从 `let path = ids.compactMap { coord[$0] }` 及后置guard抽生产两行成 `func railPathExcerpt(ids:[Int],coord:[Int:Int]) throws -> [Int]`，定义测试RouteError.noRailPath；同已有main.swift编译执行。必须实际抽产品表达式而非写一份独立实现来测镜像。断言提取唯一并记录完整源码hash/提取文本/编译和运行输出及退出码。main.swift的19项预期来自Sol核对官方Valhalla 170/442→NoRoute、171→NoSegment、172保留fallback；N28空/单/缺中间坐标拒绝、正常链保序。之前从未执行这目标，不是重复测试。
2. 只读静态核对：screens剩一分支且原协议；fwdb时才加≈/说明，普通GPX不加；chunk30恰两键且三语齐全；关键doc更正已在。保存源码hash、检查结果。没有真实视觉、全工程编译就明确未做，root统一完成。
3. 旧轮progress因max-turns未完善，结果要引用其变化清单和所有13文件；新轮输出给root：修哪些N项、19项真实结果（若数量不同按实际）、静态检查、范围/未测与有无发现需修。如产品异常只报root，不擅自改产品。不要为测试或文档反复做冗余断言，不把CLI估价当实际费用。
任务执行前写新artifacts/retest-reason.md：上一轮验证未执行，原记录链接，范围仅上述。使用1-2个批量读取和1个编译运行，少量步骤足够，控制在本轮40轮内，给最终正常报告。完整events由runner存；手工progress仍维护已完成/正在做/下一步。
