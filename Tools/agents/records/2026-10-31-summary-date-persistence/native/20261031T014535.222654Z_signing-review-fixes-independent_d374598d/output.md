# F1–F3 定向复审完成：原三条问题关闭

请求模型 gpt-6.1-sol / ultra；原生 agent `/root/signing_independent_review`，服务端实际模型／强度回执 unknown，费用 null。此次只复查原三条 P2 的冻结修复差异和新增九项既有原始日志，未发现新的阻断问题。该结论仅接受修复代码及离线证据，真实签名构建／去签名归一化证明／跨进程设置／正式安装仍待 root 完成。未运行测试、编译、codesign、App、安装、网络或偏好写入；仅写本 run 记录。

## 三项关闭依据

**F1 执行内容归属：关闭。** `Tools/archive_build.py` 的 `compare_executable_payloads()` 保存并按已验证父 manifest 逐个 hash 约束三个父执行快照。准备派生副本及每次 validate 都将父／派生执行文件复制到全新 TemporaryDirectory，再分别交系统 codesign --remove-signature；系统工具失败即拒绝，去签名结果完整逐字节比较，代码没有忽略任何代码、数据或 load-command 范围。真实父归档、父快照及实际测试包均不被 remove-signature 改写；每次 validate 重算证明，不信任 manifest 内旧 proof。有效重签且重写派生全部 hash 仍需通过此比较。新增三项 fixture 覆盖纯签名差异接受、重签后代码变化拒绝、父快照 hash 绑定。系统实际 Mach-O 的去签名归一化结果尚未证明；若实际结果不等，代码会拒绝归属，不能为让验证通过而放宽比较范围。

**F2 安装原子性：关闭。** `Tools/install_release.py` 将新包暂存到同卷预告备份位置，以一次系统 renameatx_np(RENAME_SWAP) 交换正式目标和暂存路径，旧包直接留在另一侧；不再预先移走正式目标。不支持交换时拒绝，不回退两次 rename。新装无旧目标时仅一次 rename。提交前收据保存两侧 dev/inode 和预告位置，原子发布完整收据；若内核交换后 Python 尚未赋值即抛异常，目录身份可识别已提交，正常回滚仍使用一次 swap。新增四项 fixture 含临时目录真实系统交换、交换后标志前异常的原子回滚、真实子进程交换后立即 os._exit(73) 两侧仍完整、不支持交换的旧目标保全。文档准确限定为路径交换原子性，未声称断电持久性或未完成事务自动恢复。已核对作者保存的本地 SDK 常量/声明证据，值与 ABI 一致。

**F3 收据写入边界：关闭。** 现在在任何 mkdir/write 前生成目标/暂存/备份路径，canonical resolve 后做与源/正式目标/暂存/备份的双向重叠检查，并拒绝收据位于任何 .app/.appex 内；源 App 和正式目标也做双向分离。新增两项 fixture 的子用例覆盖源内、正式目标内、source symlink、祖先、暂存/备份及其他 bundle，拒绝后源/旧目标树及路径存在性不变；没有提前创建锁或收据目录。

## 证据与来源

修复 run：`../20261031T013830.330949Z_signing-review-fixes_cb1bcb2b/`。已完整读其 task、最终 progress/output/result、精确 source/test/docs diff、执行前 targeted-verification-plan 和原始命令记录。最终 changes.json 只列 archive_build.py、install_release.py、test_release_install.py、local-install-signing.md 四项修改，无新增／删除／越界；build_release.py 未变。当前五个源文件 hash 全部匹配该 run `artifacts/frozen-file-sha256.json`，详细本地核对见本 run `artifacts/targeted-evidence-audit.json`。

新增证据原文：修复 run `artifacts/capture/commands/20261031T014509_review-f1-f2-f3-targeted-fixtures_c75e8587/{result.json,stderr.log,stdout.log}`，实际命令 rc=0、九个逐项 outcome 全为 ok，Ran 9 tests / OK。三项 F1 的 codesign 仍为 mock；真实 ditto/xattr/RENAME_SWAP 仅临时 fixture 目录。fixture 测试定义和驱动均已读，没有把模拟代码签名当真实产物通过。作者 syntax/diff/hash 原始记录及本地 ABI/man 证据也已读。

此前十六项通过继续使用 `../20261031T013319.027045Z_signing-install-independent-review_db34a088/artifacts/evidence-inheritance-audit.json` 的既有逐项继承；本次未重跑，也不把它们称作新修复版本的整套执行。三个既有 P2 的原失败报告、实现和审查均保留。

## 限制与后续

root 已告知真实构建 `Builds/20261031T014533Z_release_7bd34ec7` 的 GPXThumbnail 因 FinderInfo 签名失败并保留 rc65/log；这是 root 传入的新状态，本复审没有检查或诊断该新失败，也未改变本次已冻结源码范围。应另建修复/定向验证 run。真实 Release 和实际 remove-signature proof 仍 pending，不能凭此次九项模拟/临时 fixture 宣称正式 App 已可安装或设置域已恢复。

本审查任务完成，F1–F3 修复可由 root 独立 verify；后续仅补 root 所需真实产物证据及新构建失败的最小修复验证，保留本次代码与九项证据，不重跑无关产品功能。完整读命令/正常 stdout/stderr/退出码位于本 run artifacts/capture；每主要阶段有 agent_run progress event。
