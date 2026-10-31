# F1–F3 修复完成，等待独立复查

请求 gpt-6.1-sol / ultra；原生 agent /root/signing_persistence_fix。实际模型/强度回执 unknown，费用 null。旧实现run完整保留；本新run只修独立审查的3条P2，未实际构建、签署、启动或安装App，未写真实偏好，也未修改源归档或旧正式安装/备份。源码已经freeze并通知root可以统一构建一次真实Release。

## 修复

**F1：派生执行内容归属。** 新副本准备阶段保存三个父执行文件的完整快照到 `parent-executables/`，逐个hash必须匹配已验证父manifest的bundle_files。prepare和每次validate都在全新临时proof文件上分别执行系统 `codesign --remove-signature`，然后逐字节比较父/派生完整执行文件，保存去签名hash和完整命令/退出码。没有手工忽略代码、数据、Mach-O load-command或任意整文件改动；输入包、父快照和实际副本均不被去签。系统工具失败或完整内容不一致均拒绝。准备时输出 `test-executable-payload-proof.json`，验证返回 `test_executable_payload_proof` 供调用方保存。自洽的重签名+重写manifest不再足以绕过父payload证明。

**F2：安装提交可用性。** 新包直接暂存到同卷唯一 `GPXPointViewer-backup-TIME_UUID/GPXPointViewer.app`，验证完成后对正式target和该位置调用单次 `renameatx_np(RENAME_SWAP)`。交换后正式路径为完整新包，另一侧直接是完整旧包备份，不再出现先移走target的缺失窗口。卷不支持就失败，不降级两次rename；首次无旧target使用一次rename。提交前收据记录两侧dev/inode、交换类型/预期备份位置，完整JSON临时文件fsync后replace发布；提交后保存实际操作和检查。交换刚发生但尚未来得及设Python标志的异常，通过目录identity识别；正常回滚同样原子swap，失败新包留在peer位置。无条件进程退出时target仍在，收据commit-prepared需根据identity判断是否已交换；不声称自动恢复未完成事务或断电持久性。

**F3：收据写入边界。** 在任何mkdir/write之前生成暂存/备份路径并解析canonical路径；收据与输入App、正式target、暂存/备份路径双向重叠均拒绝，包括祖先、后代和symlink跳转，也拒绝收据位于其他.app/.appex内。目标App内容不再先被收据污染后才进入验证。

修改仅 Tools/archive_build.py、Tools/install_release.py、Tests/agents/test_release_install.py、docs/local-install-signing.md；Tools/build_release.py未变。before/after文件快照、全量diff和hash留档，精确冻结hash在artifacts/frozen-file-sha256.json。

## 新增定向证据

执行前理由：artifacts/targeted-verification-plan.md，直接链接独立审查 `../20261031T013319.027045Z_signing-install-independent-review_db34a088/output.md` 及review-result。旧16项继承，不整套复跑。

本次新增9项全部通过，实际命令rc=0：

- F1 3项：只变签名仍保持完整payload；有效签名mock+代码改变+重写所有相关manifest/hash仍拒绝；父执行快照替换被父manifest hash拒绝。
- F2 4项：临时目录真实内核swap保留两侧完整内容；模拟内核交换后Python标志设置前异常能识别并再次原子swap回滚；新子进程真实交换临时目录后立即os._exit(73)，父进程仍看到target/new与peer/old；不支持swap时原target完整保留且拒绝。
- F3 2项（含子用例）：源内、旧target内、source symlink别名、源/target祖先，以及暂存/备份及其他bundle收据路径均在写前拒绝，原树/路径存在性不变。

原始记录：artifacts/capture/commands/20261031T014509_review-f1-f2-f3-targeted-fixtures_c75e8587（完整stdout/stderr/result，rc0）。新增fixture只模拟codesign；真实ditto/xattr和rename-swap仅操作一次性临时fixture。没有真实Mach-O签名或App行为通过声明，root后续真实副本验证负责检验系统去签名的实际归一化行为。旧16项为前轮已审计的继承证据，非本run重跑。

源码compile、从before逐文件生成diff及冻结hash：capture/commands/20261031T014533_final-fix-diff-and-syntax_3fcf8fb8，rc0。本地SDK声明/常量与codesign man读取同在capture，未网络查找。初期一个空白apply_patch导入上下文不存在，失败无改动，随后使用实际import区完成正确patch；没有把失败编辑当成功。普通工具命令及真实退出码持续保存在artifacts/capture/journal.jsonl。

## root下一步与接口

原接口不变：

```sh
python3 Tools/build_release.py --arch arm64
python3 Tools/archive_build.py FINAL_ARCHIVE_APP --prepare-isolated-test-copy --destination UNIQUE_NEW_DIR
python3 Tools/install_release.py FINAL_ARCHIVE_APP --execute --authorized-target /Applications/GPXPointViewer.app
```

实际构建/三target签名/去签名payload证明/唯一测试身份行为由root统一进行；本run不重复产品构建或既有业务验证。正式安装仍须独立复查通过、保存编辑并正常退出App，随后使用持续授权。新receipt有commit_prepared/commit/rollback和实际备份位置。旧历史归档签名边界与真实偏好白名单处理规则保持前轮审计结论，不能凭fixture声称已修好用户当前运行环境。
