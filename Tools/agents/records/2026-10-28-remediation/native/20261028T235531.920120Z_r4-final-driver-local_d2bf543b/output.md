# R4 最终调度脚本本地准备完成；R4尚未执行

请求模型 GPT-6.1 Sol / ultra；服务端实际模型/强度回执、token与费用未暴露，保持unknown/null。仅在允许的r4-final-work及本run内写入。未创建真实build-manifest，未运行调度器任何阶段、app、既有测试、Bash、网络或模型API，未另派agent，也未代发原先被审批阻止的DeepSeek调用。

## 交付

- `Tools/agents/records/2026-10-28-remediation/r4-final-work/driver.py`
- 同目录 `README.md`：真实manifest前提、prep→11reg→synth→selftests→sec2/3/4→sec5三语言→sec6→docs→cleanup的串行步骤及验收边界。
- 本run `after/`为完整交付快照，`after-manifest.json`记录文件hash/size/mode，`artifacts/prepared-changes.json`为新增2、修改0、删除0（runner的changes.json可能受records默认排除策略影响，独立manifest是本任务完整证据）。`artifacts/driver.patch`是相对旧driver的完整差异。输入快照与 `input-after-comparison.json`确认旧driver、风险审计未变；R4任务与主代理基线复核在本任务期间并发更新（本Sol未写），新旧全文及差异均保留于input-after和artifacts。新增内容为55合法high和两例underfill落地验证，与本任务边界一致。

## 指定修正

1. import无配置/启动副作用；实际阶段前强制从GPXPV_AGENT_RUN_DIR取得初始化run，日志属于该次运行。APP只从同目录真实build-manifest.json读取，要求绝对app路径、64位SHA256、实际可执行文件存在且hash相同，拒绝正式/Applications源和测试副本作为源。强制ENV.GPXPV_APP；复制前重验，复制后再验binary。prep和所有阶段结果记录manifest及binary hash，不伪造构建清单。
2. 五个字符串统一支持UTF8、UTF16LE/BE、嵌套XML/二进制plist；无关或损坏plist不会中断扫描。cleanup比较测前PID集合是否为测后子集，空→空通过，缺少测前证据失败；不关闭正式app。
3. 文档核对内容、真实文件名单与数量，不要求README160/185行。保留主app34 Swift、31个run_、suite25个与全部原候选/比例/分数/考卷/自测基线。§6仍vMinRisk>50、95%、OSRM high0；55合法high不再记偏差。
4. §5保留zh-Hans/en/de真实截图、windows960×800和front证据；截图名含当前run与阶段唯一ID。PNG存在不等于无裁切，结果明确PENDING_MAIN_AGENT_PIXEL_REVIEW。§6只检UI分数；两个underfill落地重检由主代理另做生产回归，不冒充本脚本覆盖。
5. 原有子进程argv、完整stdout/stderr、实际退出码/timeout、commands.jsonl、阶段结果/state、cleanup保留；日志、结果、数据、截图和偏好快照唯一化，progress替换前备份，读取仅限新工作目录或当前run内.md并检查resolve后的范围。不记录环境全集/凭据，不删除旧失败。

## 实际验证（限AST/纯函数）

最终命令：`python3 <本run>/validate_static.py`，exit0，**53项纯检查通过**；完整日志 `command-output/20261029T000304_415860_5cfc4866.txt`，结构结果 `artifacts/static-validation.json`。测试配置、app二进制、manifest均仅为内存mock，无真实合成app文件或manifest创建；audit guard确认被检代码零进程创建/文件写入。

覆盖语法、惰性import、必需run环境、缺manifest清楚报错、真实字节流hash比较、错误hash/非法源拒绝（含软链接别名）、GPXPV_APP覆盖、UTF16和plist、正式PID子集/空集合、progress范围与软链接逃逸、唯一截图及窗口尺寸。对phase_reg/synth/selftests/sec3/sec4/open_garmin_fill/plan_and_run/batch_summary与REG_TIMEOUTS/REG_SCRIPTS/SELFTESTS/TITLES做AST/常量对照，严格旧逻辑不变。

失败证据保留：第一轮mock patch.dict退出时恢复整个模块字典导致检查自身断言失败（`000235_474394_dec08c91`），修正纯检查上下文；第二轮捕获损坏XML在plistlib.loads抛ExpatError（`000247_826884_92506350`），新增精确异常处理后重跑53项通过。旧检查源码、修前driver均在artifacts，不覆写失败日志。收尾首次全输入不变断言捕获并发文档修改（`000422_192605_96008128`）；据实保存差异并修正汇报，不回写他人文档。后一条prepared_handoff事件过早写了inputs unchanged/output saved，已立即追加progress_correction事件澄清当时报告尚未写成。prepare_driver.py只记录初次生成过程；恢复以after快照为准。

## 主代理后续检查

- 可独立AST解析driver.py及复核driver.patch/after-manifest；目前只新增两个允许文件，真实manifest仍不存在。不要执行本准备run的prep。
- 构建后创建真实manifest，再在新runner和明确授权下串行执行。README列明只允既有离线脚本/假引擎，禁止run_suite、record、真实公共路网与安装。
- 必须独立查看三语言页脚及双路标签像素，另收两个underfill生产回归结果；未执行的UI/实际R4行为没有验收证据。

本任务provider执行完成，acceptance保持pending；不能写成R4通过或可以发布。
