# 调用清理修复独立审查

GPT-6.1 Sol / ultra。用户要求先修调用与留档后继续DeepSeek，此为独立关键审查。实现者/root/runner_tests正在完成T10，run为native/20261029T002615.038848Z_process-cleanup_30cb5eef，任务coordinator/process-cleanup-task.md。已复现SDK killpg EPERM导致finally逃出，丢result/快照/结算；DeepSeek虽写result但清理异常改变真实CLI返回码并留下未确认child。原失败不得改写。

实际代码在root Tools/agents/agent_run.py、api_run.py；新增共用有界cleanup、进程归属、SDK setsid收据、finally隔离、DS drain截止。独立读取并冻结必要输入到自己run；不改实现者的源码/Tests/README，不调用API/app/网络/新agent。所有写入仅自己run，登记watch任务书，真实被审查代码另存完整hash快照，避免将实现者并发修改误归到只读审查者。首次和最终hash不同则审增量并说明。

审查PID/group归属与启动竞态、父组/无关进程安全、所有terminate/kill/join异常隔离、有限等待、pipe drain、已有worker final恢复、actual/null费用与reservation settle、timeout/turns/取消真实exit、结果状态不可误成功。不能以kill sent/leader dead冒称整个进程组终止；不能因helper异常丢after/result/settlement。重点找最小实际反例，必要时在自己run做离线注入；root会另跑完整suite，不重复实现者全量测试。无findings则给明确已检查的边界和源码hash，不泛泛批准。

先保存task、执行参数、正常输出/错误；阶段event/progress。发现重要问题及时回报root和实现者（本任务授权工具内collaboration），并保留反例。结束写output并finish pending，root独立核验。native服务端模型、token、费用不可得保持unknown/null。
