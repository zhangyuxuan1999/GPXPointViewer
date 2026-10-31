# 真实 DeepSeek 轮次上限终态分类修复

GPT-6.1 Sol / ultra。先读run_store.classify_result及现有tests。真实新DS任务已经把批准的8源写入scratch，然后达到CLI --max-turns30，退出1、final subtype error_max_turns / terminal_reason max_turns / errors Reached maximum number of turns(30)，result却provider_status failed。该字段应区分有结构化证据的预算/轮次中断与普通执行错误。原失败必须保留，不倒改旧result。

实际证据：deepseek/20261029T010037.881134Z_synth-migration_5cb2a1a8/result.json、changes.json、artifacts/synth-migration-receipt.json。完整前缀/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/。classify_result当前先判exit_code !=0后判结构化limit，疑似顺序根因；没有要求把非结构化任意非零当中断。SDK/API错误、解析/协议错误、无final、空输出和信号等原契约必须保留。

仅允许改Tools/agents/run_store.py、Tests/agents/test_run_store.py、Tests/agents/test_agent_run.py及现有fixture mock_cli.py必要最小部分、Tools/agents/README.md必要说明。自己run记录正常执行/错误/输入前后hash/patch/结果。先精确离线复现实际final+exit1，不发API，不读密钥、不启动app、不改产品、不改其它原run文件，不重放已写8文件。

当前T10 agent_run最终hash8a290ab33b4f9f3bb4b358c51832295be08764dd5aa77a495cf3663c3786156d，api_run另补multiprocessing未确认worker退出自动join、当前hash47b8a70db0066f36190ebfdb76b75bb246ea9cf23f2c9bd7d3a3f7f8b22de74c；82 suite实施者正在最终重验。勿改这两个文件。本轮独立完成自己的新增targeted测试即可，root最终合并全suite一起跑，避免并发重复写fixture旧日志。用自己的unique evidence目录，不写原runner-tests日志。

只修确定根因，增加真实CLI非零limit及非limit非零对照，保存实际runner输出、after与退出码；API完成与任务验收仍分开。完成尽快冻结报告finish pending。Root在本轮验收后才开始最终R4 DeepSeek；已有translation及migration原件保持。
