# 清理异常不得阻止API任务终结留档

模型GPT-6.1 Sol / ultra。先完成Git metadata/显式watch任务再执行本任务；新唯一run另行登记。只拥有Tools/agents/api_run.py、agent_run.py中必要清理调用、Tests/agents相关回归、Tools/agents/README.md说明。不要改产品、真实调API/凭据、另派代理；可离线mock和受控自己创建的进程。

实际失败证据：native/20261029T000837.189066Z_git-metadata-bound_afb6d28f/evidence/20261029T001308_126579_test_sdk_turn_budget_and_timeout_are_interrupted_bd16abc4/records/20261029T001308.180631Z_sdk-test_d06a2d75/。真实worker已写ResultMessage(error_max_turns,total_cost0.25)及query_completed true，主runner最后event wall_clock_timeout，随后PermissionError EPERM从finally退出，缺result.json/预算结算。发生在本轮run_store修改前。完整测试log command-output/20261029T001245_844771_bc95985e.txt，55中54过1失败；保持原件。

主代理源码定位：api_run._stop_worker的两次os.killpg及worker.terminate/kill/join只处理ProcessLookupError；execute finally调用它不隔离异常，故清理被系统拒绝时所有后续证据都丢。agent_run.terminate_group同样只有ProcessLookupError，需检查实际callsite是否同类丢终态。不能把偶发EPERM简单归环境后重跑变绿。

目标：清理为有界、记录可审查的结果；捕获并保存准确清理错误/未确认存活状态，绝不能把无法终止说成已清理。后续快照、已有最终回执、实际/未知费用结算、result/output/退出码必须仍能完成。保留原timeout/turns/取消原因与清理错误，不以finally异常替代。只终止自己创建且可验证归属的进程/组；不为了EPERM更改目标PID、全局kill或提升到无关进程权限。不要误将worker尚未setsid时父进程组作为目标。

请先用精确异常注入复现两个入口的清理拒绝后丢结果；再加有界验证：killpg EPERM、ProcessLookupError、直接terminate/kill失败、worker已正常结束但组不存在、短timeout启动竞争等。保留正常成功/错误/超时/turn预算/子进程回收与长日志55+新增回归。测试仍纯离线，不真实供应商、不打印key。供应商实际费用未知仍null，已mock回执的0.25只是测试fixture不能混入真实账本。

完整任务、补充消息、执行/错误/退出、前后快照/patch/正常结果、进度event和最终output存盘。先说明最小改法与实际根因证据，完成finish acceptance pending，主代理独立复验后才恢复下轮DeepSeek。
