# N02 / N08 / N11 / N12 / N16 / N17 / N23 处理与证据

执行者：按本任务请求的 GPT-6.1 Sol / ultra 原生子代理 `/root/deepseek_harness`。工具没有暴露服务端模型回执、token或实际费用，均为 unknown/null；不以请求参数冒充模型证明。执行正常结束，独立验收保持pending，交root基于已存证据verify。

## 逐项结论

| 条目 | 结论 | 变更/证据与限制 |
|---|---|---|
| N02 UI静默选旧构建 | 已修复 | `Tests/ui/ui.py` 强制 `GPXPV_APP`，不自动选DerivedData或/Applications；校验完整bundle文件清单+当前源码/资源/工程SHA manifest，mtime不作为源码一致证明。无manifest、源变化、bundle变化拒绝；显式旧版对照须 `GPXPV_ALLOW_UNVERIFIED_BUILD=1`，输出SHA与 `UNVERIFIED_EXPLICIT_OVERRIDE`，不归属当前源码。suite校验先于停止/删除副本。假bundle探针覆盖源mtime保持但内容变化、嵌套bundle变化、历史manifest拒绝、明确override。 |
| N08 测试证据口径 | 不因缺全套而重跑 | 旧R4与N19测试仅证明原记录的源码/构建。新工具/harness/Metal变更有各自最小定向验证，本轮没有真实UI/网络/全产品回归，也不把旧整套结果追认为当前新源码通过。文档文案已交root。 |
| N11 地区统计不在suite | 保留独立运行策略 | 25脚本列表保持原范围，`run_regions_stats_tests.py`明确独立（脚本会启动两次副本），suite源码注释+JSON separate_scripts标明。RegionIndex/RegionStats/地区窗口/Regions.bin相关变更才按影响单跑；不为扩coverage执行真实脚本。TestsREADME表题/独立命令文案交root，未越权修改README/TestsREADME。 |
| N12 日志覆盖/结果不精确 | 已修复 | UTC日期时间+mktemp随机目录，`perf/suite_TIME_RANDOM/suite.log`及同目录suite.json，启动失败也保存；每脚本真实exit/子进程exit/FAILS/用时/清理回执。非零、FAILS非none、非诊断脚本缺汇总均失败；drift记diagnostic。超时/中断或清理不明立即停止后续脚本，防止遗留公共服务客户端和后续脚本并行。仅mock验证，未运行真实suite。 |
| N16 两构建体积近倍 | 已核清主要原因，不是已确认配置缺陷 | 只读file/lipo：DerivedData SHA037eee38…，25,040,544B，x86_64+arm64 universal；旧label SHA22e77c20…，12,336,224B，arm64。架构数足以解释主要倍数差，大小本身不能证明优化/strip有错。未运行showBuildSettings/重建，也没有证明两份所有编译设置相同。 |
| N17 验收bundle只在tmp | 归档机制已实现；最终新Release由root统一 | 新 `Tools/build_release.py` 在项目Builds/唯一目录执行Release并保存命令/退出/build.log、构建前后输入manifest；只有成功+输入一致+owned group清理确认才颁发archive/current-source manifest。新 `Tools/archive_build.py`可备份旧bundle，但只标historical-unverified-source。未自行build、归档旧bundle或安装；新构建/最终归档由root待源码冻结后统一执行。Builds/忽略项由root文档代理处理。 |
| N23 Metal按n拷贝列越界 | 已防御修复且最小验证通过 | `TrackGPUBuffers.validationIssue`明确几何6列=n、颜色=4n、可选列=0或n、拓扑/空间列/索引边界。预建与setData均先守卫；非法输入记录列名/实际/预期NSLog，预建返回nil、renderer清空draw状态；不会只缩短buffer继续按n读。两个upload也在闭包内守卫baseAddress和真实count，指针不逃逸。19 CPU检查由本Sol执行；root只补51 GPU检查通过，cpu_checks=0。无窗口/实际draw/像素/性能全套。 |

## 定向验证与版本关系

执行前的原证据、具体修复/缺口和最小范围保存在 `artifacts/verification-plan.md`。所有精确argv、时间、stdout/stderr和退出码保存在 `artifacts/commands/`；probe源码归属另有各自inputs.json。

1. `205656_harness-probe_db3f.*`：首次10项里9通过，1为测试预期未resolve macOS `/var`与`/private/var`。产品返回规范化路径正确；仅把测试预期改为resolve，再运行唯一失败用例，`205758_harness-path-correction_6ffa.*` exit0/1项通过。其他9不重复运行。
2. `205758_metal-contract_ab8b.*` / `artifacts/metal-contract-v1/`：实际MetalPointRenderer与既有隔离render依赖编译exit0；仅测试副本TrackData允许列变更以构造畸形输入。CPU19检查通过，列名/长度诊断保存。当前sandbox无Metal设备，GPU阶段exit77保留，不算通过。
3. root发现新增helper的timeout只杀leader，要求定向修复。新增 `archive_build.run_owned`，独立session/group、本次尚未reap的child身份、TERM宽限0.2秒、KILL后等待/排空最多0.5秒，拒绝/不明如实记录；不触旧agents运行器。`210156_cleanup-timeout-only_9bf4.*` 只运行新增4个mock分支，全部通过；没有重复原10。`artifacts/timeout-mocks/`保存超时/中断拒绝/构建不发manifest/suite停止的5份完整JSON。cleanup_complete只证明本次独立group，不冒称系统分离服务或所有后代均已清理；timeout后suite无条件停止。
4. 为避免重跑CPU19，测试入口增加`--gpu-only`，在`artifacts/metal-contract-v2/`只编译新测试入口（exit0），不执行CPU/GPU。产品Metal源未再改变。
5. **root执行GPU-only补缺**：`../../coordinator/commands/20261029T210223_n23-gpu-only_f72f63fb/`及`../../coordinator/gpu-only-result.json`：exit0，gpu_checks=51，cpu_checks=0。本Sol读取原始result确认，不重复运行。51项为17组有效数据→后台拒绝→setData清空，含产品NSLog；不是像素或实际draw测试。
6. 静态Python compile只读检查通过，`210259_final-evidence-read_0e09.*`同时记录root GPU结果和Metal最终SHA。旧隔离依赖编译警告保留在compile.stderr；未借本次范围修无关旧警告。

继承结果和本次执行分开表述：原10项归属首次harness版本，cleanup修复只补4个受影响分支；没有宣称最终源码重新跑过统一14项整套。root后续唯一Release构建将另有记录，本代理不冒称它已完成。

## 文件范围与交接

修改：MetalPointRenderer.swift、Tests/ui/ui.py、Tests/ui/run_suite.sh；新增Tools/archive_build.py、Tools/build_release.py及Tests/probes/deepseek-harness下4个文件。共9个文件，无删除；最终完整副本/补丁/前后SHA见 `artifacts/final-sources/`、`artifacts/final.patch`、`artifacts/final-manifest.json` 和runner snapshots。没有修改README、TestsREADME、.gitignore或其他产品源码；没有提交/push、安装/关闭正式app、真实UI、网络测试、全套或清理历史tmp。

精确工具接口、README/TestsREADME替换文案、N11独立运行说明、Builds/ignore交接：`artifacts/documentation-handoff.md`。最终Metal SHA：`6cb95af16fc5cad6feea237dd5e724ac1468ea3db30c26e0df0f1837819e971b`。9个源码/探针文件已冻结，不再改动，root可统一build。

## 非测试读取异常（不掩盖）

最初组合只读工具在dwarfdump附近无输出，由本代理Ctrl-C，exit130；另一只读rg/源读取批次超时60秒旧helper异常exit1；ps被sandbox拒绝exit1。记录007/009和tool-history.md，缺失的旧helper部分子输出明确未知。后续只读file/lipo证据完整成功；这些异常不当作产品缺陷或通过。最初一次apply_patch因同一路径Delete+Add被工具拒绝，无变更；拆分后成功，正常补丁/源码已保存。
