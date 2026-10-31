# R4剩余阶段一次性恢复入口
模型 GPT-6.1 Sol / ultra。工作区 /Users/zyx/Documents/GPXPointViewer。只允许修改/新建 Tools/agents/records/2026-10-28-remediation/r4-final-recovery/ 内文件及本native run归档；不得改产品、Tests、原driver、原run、工具；不得运行app/UI/build/API/公共路网。
原DeepSeek最终R4 run deepseek/20261029T011600.159549Z_r4-final_fa1fd007已由root安全SIGINT停止：11/11 UI全部真实通过；synth执行至79/114后中断。原因是DeepSeek在CLI Block sleep90/25后改短sleep20轮询，不能延续该等待方式。result为interrupted/signal_2，cleanup_complete=true，changes空，无源码漂移。原prep的正式PID/偏好备份必须跨恢复保留。root已归档stop证明。
需编写新恢复driver，复用原 r4-final-work/driver.py，不改原文件。固定现有build-manifest（exe445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb）；用当前GPXPV_AGENT_RUN_DIR唯一新run，禁止旧run作为输出目录。
单一命令 `python3 -u .../r4-final-recovery/driver.py run`：
1 bootstrap只读核验原result中断且清理完成、changes空、prep及reg1..11全passed；核对原driver hash/固定构建/当前源码50输入hash，保存继承receipt。将原prep和11成功phase结果copy进新artifacts/state.json，但每phase明确origin_run/original_phase_id、imported=true，不冒称新执行。日志及偏好copy路径可链接原不可变证据；cleanup必须读取原prep偏好/PID基线，不能重新baseline掩盖测试改动。
2 从synth起顺序执行原driver main的 synth/selftests/sec2/sec3/sec4/sec5 zh-Hans/en/de/sec6/docs/cleanup，每阶段完整沿用原断言/命令日志/截图。旧partial synth不算passed，需要完整重跑；11 UI不重复。
3 正常失败不中断所有独立剩余项；异常也在finally执行cleanup并保存汇总；保留每次失败不覆盖。原driver自己的阶段/命令时限照常。每phase输出一行进展，最后remaining-summary.json指出11继承UI与本轮新执行phase、真实rc/fails、图像仍pending主代理。不含轮询或sleep等待模型的方案。
4 写自洽README，给root新task调用所需信息。只做离线helper mock自测，至少验证旧状态不合格/漂移/旧输出目录拒绝、正确继承原prefs/PID、异常仍cleanup、失败不冒称成功；不要启动真实app或重跑suite。
调用工具的等待机制由另Sol审查当前CLI Monitor可用性；你不需要改agent_run或调用CLI。root随后让DeepSeek Flash/max执行这个入口，并通过CLI正规等待机制接收完成。
留档按AGENTS：开始与每主要阶段event进度，完整命令/错误/正常输出、所有允许文件前后副本/hash/patch、output、finish succeeded/pending；未知服务端模型/token/cost=null。
