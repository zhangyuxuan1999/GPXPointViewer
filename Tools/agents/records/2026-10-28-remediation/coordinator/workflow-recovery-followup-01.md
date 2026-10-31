# 114/125新证据与后续范围

已确认4个114失败输入均为真实多段：g13=5段、s1=12段、s3=2段、s4=1576段，其余110已过。不要修改旧期望；主代理另派独立Sol从生成器/各段真值核定预期语义，后续有据迁移。

125首题trap已由你定位到exam.swift synthetic挖洞漏滤新segmentID列，违反数组同长，是测试harness迁移缺口。允许你只在当前run artifacts中的归档harness副本加同一keep过滤segmentID的一行，编译并执行尚未完成的125考卷（replay、真实requests0）。不改正式exam、不改题/分数/基线、不动9产品文件；将原SIGTRAP、补丁前后hash和修后输出保留。正式main+exam的窄迁移会交DeepSeek待工具T10收尾后完成。

你的增强202/202已找到并保存。先把原首次175、最终202、独立审查者183+29归属区分清楚，兼容门4多段预期问题与exam harness trap分开，不把它们混称产品缺陷或直接放行。其余收尾继续，若正式产品源必须变更先通知root与reviewer。
