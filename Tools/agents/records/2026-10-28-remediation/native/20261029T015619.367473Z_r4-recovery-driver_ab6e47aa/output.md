# R4 剩余阶段恢复 helper 实现

执行正常完成，独立验收 pending；本轮没有运行真实 app/UI/API、编译或R4 suite。

新增文件仅为 `r4-final-recovery/driver.py`、`test_driver.py`、`README.md`；原 driver、原中断 run、产品、Tests 和工具均未改写。开始时该目录不存在；新增/删除/修改清单、最终完整副本、SHA256和全新增patch见 artifacts/allowed-file-changes.json、after-source/、implementation.patch。

## 行为

唯一CLI命令为 `python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-final-recovery/driver.py run`。使用当前runner提供的唯一新 GPXPV_AGENT_RUN_DIR；拒绝原run、祖先/后代、旧执行证据、非空或符号链接artifacts，排他建立invocation。CLI无sleep/轮询/等待模型入口。

只读bootstrap锁定原driver/build/source/result/changes/state六个证据哈希、固定exe，核验50源码输入；原prep和11个UI结果必须有非空全true断言、fails空、完整结果/日志相符。原prefs副本及文本/日志也复核哈希。成功后复制prep+reg1..11，每项明确imported/origin_run/original_phase_id/executed_in_this_run=false，保留原偏好与PID基线绝对路径，旧partial synth不算passed。

直接复用惰性导入的原phase函数，按synth/selftests/sec2/sec3/sec4/sec5三语言/sec6/docs/cleanup顺序执行十一项；原断言、预算、命令日志和截图不变。每phase完整stdout/stderr另存recovery日志，外层输出一行完成进展；结果与attempt保留真实rc/fails/异常/命令退出证据。普通失败继续，信号中断停止剩余业务项，finally尝试原cleanup并保存remaining-summary；结束再核验immutable输入。cleanup读取原prep中的prefs/PID，而非新baseline。摘要保持acceptance=pending、截图pending主代理像素审查，费用/token/实际模型未知记null。

## 验证

- 最终14/14纯离线mock通过，退出0：artifacts/offline-tests-scoped.log。所有执行接口mock，不运行真实业务suite；最终fixture仅在helper目录内临时创建并自动清理。
- 覆盖旧结果不合格、原phase失败/空检查、driver/build/source/exe/prefs/result漂移、旧/复用/符号链接输出拒绝、完整继承原prefs/PID、11phase顺序、异常继续、失败不冒充成功、中断finally cleanup、cleanup失败证据与原cleanup真实函数读取继承baseline。
- 真实输入只读检查通过：50输入、83项证据哈希、prep+reg1..11全通过、原正式PID基线=[]。见artifacts/real-input-readonly-receipt.json和real-input-readonly-result.json。没有configure/bootstrap/execute真实run。
- 两个Python文件ast.parse通过。
- 首轮13项中11项通过，两个测试fixture断言（macOS /var路径别名、JSONDecodeError继承ValueError类型）失败；原日志保留offline-tests-first.log/json，修正测试断言后13/13通过，再加输出symlink范围用例后14/14通过。最初三轮fixture位于系统临时目录且已清理，最终版本把fixture限定到本helper目录。

## 交接

主代理须独立审查helper和证据，之后新建DeepSeek Flash/max任务执行唯一命令；不能复用本实现run或原run。原阶段budget总和7220秒，外层时限需留足余量，正规CLI等待由另一任务审查。真实执行后主代理核对新summary、每phase结果、原偏好差异、正式PID与截图像素。bootstrap拒绝不会执行cleanup，因为不合格的基线不能作恢复依据；SIGKILL/断电无法保证finally。保留原cleanup的语义：记录偏好文本差异，而非声称逐字节恢复。
