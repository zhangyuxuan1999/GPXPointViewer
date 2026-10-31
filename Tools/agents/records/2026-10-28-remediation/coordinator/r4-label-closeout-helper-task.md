# R4 标签修复后的新构建定向复测工具

模型：Sol Ultra。用户已要求修复所有问题、完整留档、已通过11组不重跑；DeepSeek数据发送许可仅限本项目复测文件。当前只有ContentView.swift中EngineLabel几何将在独立Sol任务修复，原始R4构建与历史证据必须保持。

在新目录 `Tools/agents/records/2026-10-28-remediation/r4-label-closeout/` 实现严格、可测试的定向复测封装，供DeepSeek Flash/max执行一次后台命令。读现有r4-visual-closeout/driver.py与r4-final-recovery/driver.py、原始driver，只运行sec2标签与cleanup；不可重跑11组、数值套件或已通过三语页脚。复用原始phase_sec2断言与实际shotwin截图，以及当前visual helper安全的屏幕检查/单键窗口恢复/精确进程检查。

新版本必须明确记录：继承的11组、剩余数值结果和三语截图来自旧可执行文件445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb；本次仅标签阶段在新构建执行，不能篡改原build字段。新输入由root稍后生成新的source/build manifest；严格要求旧50构建输入仅ContentView.swift一个不同，新输入和新app与固定hash匹配，旧记录/旧app仍验证。旧manifest与helper不可修改。允许设计一个明确的固定policy JSON，由root填写新构建hash，不要弱化校验或接受任意app。

建议复用已验证helper并为本次显式定制新版本policy：原始recovery.validate_immutable_inputs可读取新source manifest（同root且差异白名单已验证），仍验证旧build与继承phase；运行driver.MANIFEST_FILE指定新build manifest。必须在继承报告分开old/new，并复用前后全输入完整性校验。请自己评估实现正确性，不必照搬建议。

权限：只写新目录与本native run。不得改产品、旧helper、旧证据；不得build、运行真实app/UI、API或偏好写入。定向单元测试覆盖新旧build归属、唯一源变更限制、hash漂移、只执行sec2+cleanup和完整恢复。全部命令日志/进度/结果保存本run；完成后finish pending由root审核。及时报告需要root填写的policy/schema。
