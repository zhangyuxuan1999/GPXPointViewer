# 签名／安装工具独立审查：Request Changes

请求模型 gpt-6.1-sol / ultra，原生 agent `/root/signing_independent_review`；服务端实际模型／强度回执 unknown，费用 null。审查任务已完成，产品验收尚不能通过；发现 3 个 P2 问题，已逐条通知 root 与实现作者。仅写本审查 run 记录，未写产品源码，未重跑测试、编译、实际 codesign、App、安装、偏好或联网测试。

## 发现

### F1 [P2] 隔离副本允许整个可执行文件变化，无法证明只改签名

位置：`Tools/archive_build.py:294–295`（判定 `303–310`）。

`validate_test_copy()` 将主 App 和两个扩展的完整 `Contents/MacOS/*` 文件加入允许改动集合。它仅对 Info.plist 做了语义受限比较；执行文件只有最终整文件 hash、自洽的 bundle_changes 和最终签名校验。

最小触发逻辑（仅静态推导，未执行）：对一个正常派生副本改变任意有效 Mach-O 代码／数据，再保留测试 ID 与期望 entitlement 进行 ad-hoc 重签，并更新派生 manifest 的 bundle_files、executable_sha256、bundle_changes 和真实 signing 字段。所有变化仍落在当前 allowlist，`verify_sandbox_signatures()` 也只证明改后包签名有效；父归档原文和父 Info 快照可以完全不变。该副本仍能被作为原验收构建的“仅改 Info 与签名”派生品接受，实际测试代码已变化。

建议：从经验证父产物保存并核对三个执行文件的签名之外内容（包括每个架构），只允许 Mach-O 签名所必需的受限变化；校验原父文件的 hash 与父 manifest 一致。加入“有效重签后的代码／数据改变仍拒绝”的一个定向 fixture。父 manifest 的自校验 hash 仅证明副本记录内部一致，不应代替父产物或执行内容的来源证明。

既有隔离第 3 项只改变 `Contents/UnexpectedResource`，其通过不覆盖允许路径内的可执行代码变化；父证据篡改 fixture 只把原文改成 `{}`，不覆盖此分支。

### F2 [P2] 两次 rename 之间会让正式安装路径缺失

位置：`Tools/install_release.py:92–98`。

实现先 `target.rename(backup)`，校验／写盘后才 `stage.rename(target)`。两次操作单独原子，并不是旧新安装之间的原子交换。进程在两者之间收到默认 SIGTERM、崩溃或系统中断时，Python 的 `except BaseException` 不会执行，`/Applications/GPXPointViewer.app` 将缺失；旧包虽可在收据记录的备份恢复，但本工具没有自动恢复下一次启动的未完成事务。因此现有流程不可称“原子安装”。

建议：在 macOS 使用具备原子交换语义的同卷交换，或采用另一种能确保正式路径始终指向完整旧／新包的提交协议；保留可恢复旧包和失败新包。把提交前／后状态持久化，并在离线 fixture 中模拟交换／提交边界故障，验证正式路径不缺失。普通 post-validation exception 回滚测试继续继承。

### F3 [P2] 收据目录可写进原归档或旧正式 App

位置：`Tools/install_release.py:49–55`。

`receipt_dir.resolve()` 后直接创建目录和写 `install-result.json`，发生在源验证之前；代码未拒绝该目录位于源 App 或正式目标 App 内。

最小触发逻辑（仅静态推导，未执行）：用正常源归档，将 `--receipt-dir` 设为 `<源归档.app>/Receipts/new`，脚本先改写输入包，随后来源 hash 校验拒绝；或者设为 `/Applications/GPXPointViewer.app/Receipts/new`，会先修改旧正式包并使原签名资源集合变化，再把修改过的树作为 previous_bundle_files／备份基线。后者后续写原目标路径收据还可能失败，但回滚也只能恢复已被收据污染的旧包。两者都违反输入／旧包保持不变的保证。

建议：任何 mkdir/write 之前对解析后的收据路径做不重叠守卫，拒绝落入输入、正式 App 或其他受保护 bundle 内；错误路径必须在无 bundle 副作用时失败。加入源内和旧目标内收据路径的两个临时 fixture，核对原树不变，不接触真实 /Applications。

## 已核对且无新增问题的范围

- `build_release.py` 默认不再覆盖 `CODE_SIGNING_ALLOWED=NO`，沿用当前工程三个 target 的 identity `-`、各自 entitlement 与 Hardened Runtime 配置；`--no-sign` 明确记录为 development-unsigned／不可安装。
- 新归档先复制到新目录，复制保留元数据；仅在新副本清理 FinderInfo／ResourceFork，清理使用 xattr 的 symlink 模式，未删除 quarantine，未清理旧备份或输入 App。三个 target 独立严格校验、Info 与签名 Identifier、一致的源码安全 entitlement 和 CDHash 均留证；主 App 权限不会用于扩展签名。
- 正式安装拒绝 unsigned、历史／未知签名和测试派生 association；当前源码完整输入、bundle 内容与最终 executable hash 校验都保留。测试副本 ID 族严格限制 `.test.<slug>`，扩展 ID 随主 ID 分离，签名顺序为 QuickLook→Thumbnail→主 App，无 `--deep` 重签。默认 UUID ID 的主设置域分离合理；显式复用 ID 只检查主容器和非容器主偏好存在，实际新进程域读写仍待 root 验收。
- 安装目标固定、要求明确 target 参数、拒绝直接 symlink 目标及被重定向父目录；源包与目标分离；两次停止检查和安装锁存在。正常异常路径保留失败新包并 rename 恢复旧包，旧包未被重签。F2 仅指出无法执行 Python 回滚的中断窗口。
- 工具没有退出／启动／强杀用户 App、增加用户设置值或覆盖真实 preferences 的代码。F3 仅涉及 bundle 内收据路径。

## 证据与继承

实现归属：`../20261031T012023.801942Z_signing-install-persistence-fix_6b832b3d/`。审查时五个文件 SHA256 与实现 finish 后 verification-summary 的冻结 hash 全部一致（本 run `artifacts/evidence-inheritance-audit.json`）。已读实现 before／after manifest 和 changes.json：修改 build_release.py、archive_build.py；新增 install_release.py、test_release_install.py、local-install-signing.md，无删除，无记录中的越界改写。

已逐条核对原始 capture result.json 和测试 stderr 的实际 outcome。16 项唯一通过集合成立，但不是最终源的整套重跑：

| 原始命令记录（实现 artifacts/capture/commands/） | 命令真实 rc | 当前继承通过 |
|---|---:|---:|
| 20261031T012613_offline-release-install-fixtures-r2_e35d0db6 | 1 | 2／12 |
| 20261031T012659_offline-release-install-failed-only-r3_a322f9ea | 1 | 6／10 |
| 20261031T012718_offline-release-install-failed-only-r4_469c8183 | 0 | 4／4 |
| 20261031T013032_isolated-release-copy-fixtures_9ab8b9c6 | 0 | 4／4 新隔离项 |

早先未通过结果保留，没有把命令整体 rc=1 说成通过。r2 的 2 项和 r3 的 6 项是相应单项原始通过，后续修复范围与定向验证计划一致；合并为基础 12 项＋隔离 4 项。源码 compile／CLI help rc=0 也已读原始回执。全部 codesign 是 fixture 模拟，ditto/xattr 仅临时 fixture；不证明真实签名 App、真实跨进程偏好往返或正式安装。

本次 read-only 命令的完整 argv、stdout、stderr、退出码保存在 `artifacts/capture/journal.jsonl` 与 commands；开始前 4 次 bootstrap 读取另存 `artifacts/bootstrap-reads.json` 与完整输出。进度通过 agent_run event 写入。

## 结论与后续最小范围

Request Changes。请作者修复 F1–F3 后另存新实现／定向验证证据；无需重跑已经通过且不受影响的 16 项或产品功能／截图。root 对本次审查执行独立 verify；之后才对修复后的具体版本作验收决定。真实 Release 构建、三目标真实签名、唯一身份的跨进程设置验证及正式安装都仍属于 root 的后续阶段，本审查未执行，也未作通过声明。
