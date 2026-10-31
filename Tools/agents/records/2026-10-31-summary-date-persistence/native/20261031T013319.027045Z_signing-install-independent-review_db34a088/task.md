# 独立审查签名/安装/隔离测试工具 — Sol ultra
请求gpt-6.1-sol/ultra。只读已冻结源和已有正常日志；仅写自己的run记录。不得重跑已经通过的16个工具fixture，也不构建、codesign实际App、启动/关闭App、安装、写真实偏好。需要重测必须先指出具体矛盾/缺证/修复影响并向root说明，默认只读。
根因报告 native/20261031T011612.884046Z_settings-persistence-audit_060da613/output.md（其runner因共享日志与DSStore宽watch失败保留，证据可核对）。实现 native/20261031T012023.801942Z_signing-install-persistence-fix_6b832b3d/output.md 和artifacts正常测试/快照。检查Tools/build_release.py、Tools/archive_build.py、Tools/install_release.py、对应Tests/agents新增差异、docs/local-install-signing.md。不读其他用户私有文件，不需要再次读真实pref。
重点：默认Xcode既有adhoc sandbox配置；no-sign开发归档不可安装；最终签名后manifest真实性；严格主App+两appex identifier/恰当entitlements；signed/unsigned/历史/隔离副本边界；source/bundle归属；备份/暂存/原子交换/失败回滚/已运行拒绝；路径、symlink与误覆盖；安装不得加权限或覆盖用户settings；xattr清理只限自有副本；唯一测试bundleID族/各自entitlement签名与实际prefs隔离正确；不得让testderived包通过正式安装。
核对已有测试日志覆盖和失败保留/继承关系，报告具体bug严重度/路径/行号、最小复现逻辑；无发现时写范围与未执行项，不用空报告代替审查。不要为读审再编译执行fixture。建议修复消息root/作者，由作者另存对应修复+定向验证，审查者不写产品。
遵守AGENTS，完整task/progress/output，正常命令用旧journey-summary/coordinator/capture.py（label+argv；GPXPV_COMMAND_RECORD_ROOT=本run/artifacts/capture），每阶段event progress。请求实际模型/费用未知null。不派代理/侧栏聊天。finish后rootverify。
