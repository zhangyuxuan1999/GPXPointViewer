# 清理错误隔离完成；执行成功，验收交Root

请求模型 GPT-6.1 Sol / ultra；未暴露服务端实际模型/强度回执、token或费用，保持unknown/null。只修改Tools/agents/api_run.py、agent_run.py、Tools/agents/README.md，新增Tests/agents/test_process_cleanup.py。产品和原65项测试未改；没有真实模型/API/凭据访问、app、公共路网、安装或另派代理。测试中的0.25是公开SDK fixture，不是真实账单。

## 真实根因与先行反例

原失败run为20261029T001308.180631Z_sdk-test_d06a2d75：worker已原子保存error_max_turns、total_cost0.25、query_completed=true，最后event却停在wall_clock_timeout；_stop_worker的os.killpg抛EPERM从finally逃出，after快照/result/output/预算settle全跳过，ledger仍reserved。原件及摘要在artifacts/original-eperm/、actual-failure-summary.json，未修改旧失败。

修前精确注入日志003148_188658_49536e10、evidence/precise-refusal-before/counterexample.json分别证明：

- SDK：CLI2，final存在但result/after/结算缺失。
- DeepSeek：finally其实仍写interrupted结果，不能冒称也丢result；但第二次cleanup异常逃出把实际timeout退出码124覆盖成2，并留下活mock child。该fixture由其同parent验证私有组后收尾，独立留档。

## 最小隔离行为

agent_run共享terminate_group返回可审查回执，每次TERM后等待≤0.2秒、KILL后≤0.5秒。信号、direct terminate/kill、join/wait、状态探测逐个隔离异常并记录类型/errno；ESRCH表示目标已不存在，EPERM/未知存活/归属不明为incomplete，不能当已清理。两调用入口还隔离helper意外抛错，cleanup错误不代替原timeout/turns/预算/取消原因。

parent创建child后保存启动身份；SDK worker在setsid后写sdk-worker-owner.json。组信号必须指向自己的child PID独立session/group，启动尚未setsid绝不取父组当目标。已reaped而当前PID身份不可核验时，旧group_created不能授权向现存新PID/group发信号；live未reaped直接child可安全fallback；PID确已不存在时可依据原归属清理残留组。重用身份、父组、未知身份控制均有无真实信号模型回归。

SDK finally即使清理拒绝，也继续读取完整worker final、保存process-cleanup事件/JSON、after快照、结算、result/output及实际runner_exit_code。child_exit_code单列；原结构化turns/budget及wall timeout原因保留。完整query回执的SDK估计仍可结算；query未完成且cleanup未确认时，sdk_reported_cost_usd单存，费用null并保持USD预留，actual_billed_cost_usd始终不伪造。

DeepSeek首次停止原因和drain截止固定，后续信号只追加事件，既不再次cleanup也不延长等待。清理后最多再drain1秒；无法确认结束则stream_incomplete、保留收到的未解析字节及清理证据，不等活子进程无界关管道。双EOF仅代表pipe结束，等待leader仍用相同原timeout/信号控制，实际超时返回124。

另以真实、仅本run创建的sleep子进程确认：bounded helper虽0.706秒返回，multiprocessing默认退出仍会再次无界join；stdlib源码和1秒同parent救援实证在artifacts/multiprocessing-runtime-exit.py、runtime-shutdown-counterexample.json（005632_591186_9293e9b5）。现在仅将未确认worker实例从当前stdlib_children退出登记移除并记录automatic_exit_join，不改PID、不清空别的child、不把取消自动join称为清理成功；新真实子进程回归证明_exit_function立即返回，fixture仍由其原parent最后reap。这是针对当前Python标准库的明确适配，不承诺未知存活进程已经终止。

## 独立审查反例与保留的失败

独立Sol review run20261029T003934.821235Z_process-cleanup-review_50726e9e发现并关闭三例，原脚本/JSON及关闭证据在artifacts/independent-review与对应review run：

1. 已reaped且identity缺失仍向复用组发信号：补强上述归属判断，新模型拒绝全部信号。
2. 20个追加信号把虚拟drain拖至4.4秒、cleanup20次并覆盖timeout：现首deadline1.2秒、cleanup1次、timeout124，stream_incomplete=true。
3. 双EOF、child sleep10、timeout0.8：旧固定wait5实际5.328秒后failed/CLI1/首因null；修后独立1.044秒返回124/interrupted/wall_clock_timeout/errornull。

EOF helper重构曾有AST合法但函数缩进逻辑错误，被三个targeted断言真实捕获；原123.388秒失败（004830_894895_7ab60b22）、有限60秒mock现场、只对已核验自己fixture PID的手动SIGKILL遇OS EPERM均留档，无提升权限或改目标。缩进修正后16/16通过。另一次全81有80ok和1个证据copytree的OS60超时（31ba6584），没有删除失败或放宽测试；最终换本run内新证据目录重跑全部。

## 最终验证与版本边界

最终82/82，exit0，26.491秒，完整日志command-output/20261029T010419_556192_544b204f.txt。精确命令：

`env PYTHONDONTWRITEBYTECODE=1 GPXPV_TEST_RECORD_SUBDIR=final-82-evidence python3 <本run>/journal_command.py python3 <本run>/run_regressions.py`

原65项完全未改，新增17方法涵盖EPERM/ESRCH、direct三方法失败、未知及完整费用、helper逃逸、parent-group/重用PID/identity缺失、固定重复信号截止、真实短timeout启动竞争、早EOF、真实runtime退出。每个mock/真实局部子进程的命令、正常stdout/stderr、事件/结果、预算和快照均在final-82-evidence/evidence/；旧轮次也保留。harness仅在内存重定向helpers.RECORD，未改原测试或期望。

Root已独立81/81、38.322秒通过，peer已分别关闭上述三反例；但这些证据对应runtime join小段加入前的API35e。最新API47b的runtime增量由本轮17 targeted及完整82覆盖，仍交Root独立验收，不混称旧审查已验新API。

82输入RunStore为05ad0abdc88779ef1094a8376308d44d3c794ed06b07b64a9ea2ad7ad184d11b。Root现另派structured-limit任务改classify_result及其测试/fixture；本82不能冒称其新版分类器已验。依赖说明见artifacts/final-suite-input-dependencies.json，Root须在合并后另跑最终套件。

## 交付

完整补丁artifacts/process-cleanup.patch，before/与runner before、最终after/、after-manifest.json、artifacts/independent-changes.json完整记录3修改1新增0删除。最初冻结/审查前快照也保留，未覆盖失败。最终四文件SHA256在artifacts/frozen-source-manifest.json：API47b8a70d…，agent8a290ab3…，README505c4a93…，新测试e8b8b203…。构建及真实R4未在本轮执行。

本轮按provider succeeded、acceptance pending收尾。Root独立验收最新runtime增量及后续分类器合并后，决定下一真实DeepSeek调用；本代理没有代发或绕过该门。
