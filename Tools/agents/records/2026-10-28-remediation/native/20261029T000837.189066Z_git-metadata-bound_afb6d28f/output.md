# Git元数据有界采集与显式watch修复完成，交独立验收

请求 GPT-6.1 Sol / ultra；服务端模型/强度回执、token、实际费用不可得，保持unknown/null。本轮只修改Tools/agents/run_store.py、Tools/agents/README.md，新增Tests/agents/test_git_metadata.py与fixtures/mock_git.py；产品、既有55项测试、其他工具与旧run结果均未改。只有本地离线mock/真实合成Git回归，无真实模型/API/app、公共路网、安装或再派发。

## 先保存反例

上次r4-final-driver-local的finish从00:05:10.168919到00:06:29.423770，共79.254851秒后exit0；期间文件manifest/head已保存而Git/status receipt及result未完成。旧代码五条subprocess.run都没有timeout，且无watch pathspec。旧版没有单独计时，因此不声称某一条精确耗时79秒，也没有证据将B的event等待归为同因。原journal摘录及旧result只读副本在artifacts/actual-counterexample.json、previous-result.readonly.json，收尾又核对旧result字节未变。

reproduce_before.py加载完整旧run_store快照，以假Git的status及其子进程长眠复现：2秒看门狗触发时文件manifest存在、git.json和result均不存在；只SIGKILL该worker新建的自身进程组。结果evidence/old-hang-reproduction/repro-result.json、日志001316_844144_793c3ee9完整保留。

补充指令也先保存真实文件反例：明确watch/allow-write指向Tools/agents/records/batch/work，其中driver.py实际存在，旧snapshot仍files={}；记录artifacts/explicit-watch-counterexample.json。未倒填任何旧空快照。

## 实现行为

- 文件manifest与added/modified/deleted/out_of_scope清单先持久保存，再采集辅助Git。Git进程等待总预算12秒、每条≤3秒，超时只终止Popen(start_new_session=True)建立的本次Git进程组，后续communicate/wait各限0.2秒。磁盘持久写入和系统创建进程延迟不冒称硬实时保证。
- 每条保存精确argv、scope/pathspec、起止时间、实际耗时、attempted、真实exit_code（未运行/无回执为null）、timeout/status/error/cleanup与完整正常部分stdout/stderr。非成功日志有明确说明，git.json的_meta.complete=false不等于干净diff。缺Git、非repo、卡住Git都不丢主要快照/changes，不把真实provider成功改成失败；独立验收可以看到证据不全。
- head取仓库HEAD，status/diff/staged/untracked用literal watch pathspec，已删除路径也保留。默认宽扫描排除无关历史records/生成物，空watch不回退全仓扫描。每次Git禁用optional locks、fsmonitor/untracked-cache，diff禁用external/textconv；不改.git配置/index，回归以真实文件hash证明。
- 新run将默认prefix、用户prefix与explicit_overrides分开写meta。明确watch或allow-write落在默认generated前缀/明确生成文件内，只启用所指源文件或子树；祖先只为遍历开放，不重启用整个records。敏感parts、本run递归和用户exclude（含根目录.）优先。混合宽watch和明确子树的Git调用分作用域、共享同一个12秒预算，防止Git exclude规则吞掉明确工作目录。旧meta没有覆盖字段则保持旧规则。

## 回归结果与未解决项分开

首次修前55项基线：54通过、1失败（SDK turns场景PermissionError EPERM从清理逃逸，没有result），日志001245_844771_bc95985e。主代理核对api_run._stop_worker确认为真实另项缺陷，已安排新run，本轮不越界修改，也没有把重跑通过当该缺陷修复。原失败及全部fixture均保留。

新针对性首轮9/9通过，补根目录用户exclude优先后，完整65/65通过（旧55逐字未改+新增10），exit0，用时18.293秒。精确命令：

`env PYTHONDONTWRITEBYTECODE=1 python3 <本run>/journal_command.py python3 <本run>/run_regressions.py`

完整输出command-output/20261029T002113_540121_078b0704.txt。run_regressions仅在内存将既有helpers.RECORD重定向本run，避免向旧runner-tests日志写入；模型CLI/SDK全为原离线fixture，没有真实API或钥匙串读取。首次证据harness祖先路径错误与首个实现脚本路径错误均在写拥有源码前失败，原命令/退出码及脚本也保留。

10项新增覆盖：挂起Git及忽略TERM的后代、部分stdout/stderr、独立无关哨兵不受影响；总预算耗尽与未执行null回执；缺Git不丢changes/provider终态；非repo和exit23错误；真实Git的staged/untracked/deleted、literal特殊文件名、只读index/config与禁fsmonitor；宽watch+显式records子树、兄弟历史不纳入、敏感/userexclude/本run递归保护；allow-write覆盖；用户根exclude；空watch；真实agent_run CLI finish在Git超时后保存succeeded/pending。

最终本地测量见artifacts/final-metrics.json：默认CLI的status在3.004710秒超时、Git总3.262215秒且CLI exit0/result成功；0.5秒缩短预算实际总0.507133秒，后两条明确skipped/exitnull；0.4秒status场景实际0.403548秒终止，后代死亡与独立哨兵存活断言通过。

## 交付与范围

artifacts/git-metadata-and-watch.patch是完整两修改/两新增补丁；原始13文件before与15文件after均有自动/独立manifest，新增2、修改2、删除0见artifacts/independent-changes.json。已有test_run_store.py/test_agent_run.py/test_api_run.py/test_legacy_repros.py/helpers.py及fixture源均保持原样。完整改后源码在after/；精确SHA256在artifacts/frozen-source-manifest.json，收尾再次对照冻结hash一致。

run_store.py SHA256：05ad0abdc88779ef1094a8376308d44d3c794ed06b07b64a9ea2ad7ad184d11b。

本轮按provider succeeded、acceptance pending收尾；主代理独立审查/verify另记。65/65是本次离线观测，不能用它抹去已确认的SDK清理EPERM缺陷，下一run仍需强制异常回归。本轮没有启动或替代后续DeepSeek实际复测。
