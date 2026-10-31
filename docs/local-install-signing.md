# 本地 Release 签名与覆盖安装

2026-10-31 的设置审计发现：旧安装带 `com.apple.security.app-sandbox=true`，以 `--no-sign` 构建的新包没有 entitlement。相同 bundle ID 在这两种运行环境下会使用不同的偏好域；不能把未签名包当成保持原沙盒语义的安装版。旧备份的严格签名检查还受到 FinderInfo 扩展属性拒绝，因此这里不声称旧备份严格验证通过。

正常本地构建使用工程已有的三个 target 签名配置（当前 identity 为 `-`，即 ad-hoc），分别使用主 App、Quick Look、Thumbnail 自己的 entitlement 文件，无须新证书或 Team：

```sh
python3 Tools/build_release.py --arch arm64
```

必要时可追加 `--no-icloud-coordination`。构建器保留 Xcode 原有的由内向外签名，不执行手工 `--deep` 重签名。成功复制到新归档后，仅在这个新副本清除 `com.apple.FinderInfo` / `com.apple.ResourceFork`，保留 quarantine；原输入包、正式安装和旧备份不变。若 Xcode 本身或归档严格校验失败，保留失败产物，不能继续安装。

构建命令显式设置 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`，防止本机Xcode默认注入源码未声明的 `com.apple.security.get-task-allow` 调试权限；build-command.json记录实际开关。三target最终安全权限仍须精确匹配各自源码entitlements，不能通过放宽归档守卫来接受额外权限。

Xcode 的 DerivedData 默认位于 `/private/tmp/GPXPointViewer-<唯一构建名>-<随机值>/DerivedData`，使用权限700的独立本地目录。项目位于 Documents/iCloud 时，FileProvider 可能在新 `.app` / `.appex` 目录上添加 FinderInfo，导致归档之前的 Xcode CodeSign 失败；中间产物因此放在同步范围外，源码元数据不清理、签名不关闭。可运行archive也保留在同一本地staging的 `archive/` 下，防止iCloud稍后再次给已签名appex添加FinderInfo。项目 `Builds/<唯一构建名>/` 保存完整build.log、实际命令、源码输入；其 `archive/` 只保存持久ZIP、manifest、签名proof和路径收据，不存放运行App；build-command.json记录 `local_staging_path`、`derived_data_path` 和保留策略，命令行也打印 `DERIVED_DATA`。成功或失败都不自动删除本地中间产物；系统临时目录可能被OS清理，长期证据以项目Builds内的日志/manifest/ZIP为准。运行、测试和安装必须使用命令打印JSON中的 `app` 与 `manifest` 绝对路径；`durable_zip` / `durable_manifest` 是项目内持久副本，不能把旧固定项目路径当运行入口。已有失败记录不覆盖。

`--no-sign` 仅用于明确的研发/诊断，其 manifest 标记 `signing.policy=development-unsigned`、`installable=false`，安装入口会拒绝。README/Tests README 中历史的 `--no-sign` 示例不能作为正式安装指令。旧 manifest 仍可按原方式做来源与文件校验，但未知或历史签名不能通过安装守卫。

实际构建成功且相应功能验收通过后，保存未保存编辑并**正常退出所有 GPXPointViewer 实例**，再使用JSON输出 `app` 的精确本地归档路径（下方PRINTED_APP表示该输出的父目录）：

```sh
python3 Tools/archive_build.py /ABS/PRINTED_APP/GPXPointViewer.app --validate --for-install
python3 Tools/install_release.py /ABS/PRINTED_APP/GPXPointViewer.app \
  --execute --authorized-target /Applications/GPXPointViewer.app
```

用户已在 AGENTS.md 中持续授权验收后覆盖安装；`--authorized-target` 记录本次使用的目标路径，不要求重复向用户确认。省略 `--execute` 时只校验输入归档，不改安装。脚本不退出或启动应用，不强杀进程，不修改真实偏好，也不为任何现有包签名。运行中会拒绝安装，由操作者先正常退出。

安装前必须同时符合：完整 bundle 哈希及当前源码/资源/工程输入与 manifest 一致；manifest 明确记录可安装的本地沙盒签名；主 App 和两个 appex 各自的 `codesign --verify --strict` 成功，Info 与实际签名的 bundle ID 正确，实际安全 entitlement 与各 target 的源码文件一致，CDHash 与归档记录相同。TeamIdentifier 缺失的本地 ad-hoc 签名本身不被错误拒绝。

安装器只接受 `/Applications/GPXPointViewer.app`。它把新副本暂存到同卷唯一的 `GPXPointViewer-backup-时间_随机值/GPXPointViewer.app`，完成完整校验后，用 macOS `renameatx_np(RENAME_SWAP)` 将正式目标和该副本**一次原子互换**。正式路径始终指向完整旧包或新包；互换后的另一侧直接成为旧安装备份，保留原字节、权限及扩展属性。不支持原子互换的卷会拒绝安装，不降级为两次 rename。首次安装没有旧目标时使用一次 rename。

提交前以完整JSON替换并 fsync 收据文件，记录旧目标/新暂存目录的设备及inode身份、交换类型和预期备份位置；提交后记录实际交换及校验结果。进程在交换附近突然退出时，正式路径仍存在，旧包保留在收据预告的另一侧；`commit-prepared` 不等于已安装，需据目录身份核对实际状态。此保证是同卷路径交换原子性，不声称断电持久性或自动恢复未完成收据。正常异常会用同一原子交换恢复旧包，保留失败新包供诊断。原备份不清理扩展属性，也不宣称其现有签名通过。新暂存副本会记录所清理的 FinderInfo/ResourceFork；最终实际签名和文件哈希均需匹配构建归档。

每次执行在唯一 `Builds/*_install_*/install-result.json` 留档源归档、manifest SHA、原包完整文件哈希、备份/暂存路径、安装前后的校验归属、正常进程探测及回滚结果；也可用 `--receipt-dir /ABS/NEW/RECEIPT` 指定新的空目录。任何 mkdir/write 前先解析符号链接，拒绝收据路径与源App、正式目标、暂存/备份路径双向重叠，也拒绝收据位于其他 `.app` / `.appex` 中。备份与失败生成物保留，由操作者在确认恢复无误后另行管理。

离线工具验证：`python3 -m unittest discover -s Tests/agents -p test_release_install.py -v`。它模拟 codesign，只用临时目录，不编译或运行 App，不接触真实偏好和 `/Applications`。真实 Release 的签名和设置域保持仍需主代理在统一的新构建/安装阶段记录；这套 fixture 不能代替实际产物验收。

## 用独立身份验证设置持久化

UI 及跨进程设置测试必须使用唯一测试 bundle ID，改变通信目录不等于隔离 UserDefaults。下列入口只从已通过正式安装签名检查的归档派生新副本，不修改或启动原归档，不安装应用：

```sh
python3 Tools/archive_build.py /ABS/PRINTED_APP/GPXPointViewer.app \
  --prepare-isolated-test-copy --destination /ABS/NEW_TEST_COPY_DIR
```

默认生成 `de.wayne.GPXPointViewer.test.t时间-随机值`，也可显式传 `--test-bundle-id de.wayne.GPXPointViewer.test.<唯一slug>`（slug 需8–64个小写字母/数字/连字符，首字符为字母或数字）。工具拒绝正式ID、其他ID族及已存在容器/偏好文件的复用测试ID；只检查该新ID路径是否存在，不读取或修改真实偏好。

副本保留各自权限，两个 appex 的ID依次为 `<测试主ID>.GPXQuickLook`、`<测试主ID>.GPXThumbnail`。它仅改三个 Info.plist 的 CFBundleIdentifier，再按各自源 entitlement 文件依次对两个扩展、主App进行ad-hoc签名。签名命令不使用 `--deep`；副本必须通过三target独立严格验证，正式归档字节和manifest必须保持不变。

输出包含 `app`、`manifest`、`test_bundle_id`。副本旁保存原构建manifest原文、原Info.plist、三个原执行文件快照、允许范围内的改动清单、签名命令/回执及实际新hash。原执行文件快照必须逐个匹配父构建manifest的hash。准备及每次验证时，系统 `codesign --remove-signature` 仅操作全新临时proof副本，再逐字节比较父/派生完整执行内容（含全部架构）；去签名结果必须完全相同。不会手工忽略代码、数据或load-command范围，也不会改写输入归档、父快照或实际测试App。失败拒绝归属；首次真实系统工具验证由主代理记录，离线fixture只模拟codesign。

派生来源明确标为 `isolated-test-copy-derived-from-verified-build`，可由现有 `validate_bundle` / `ui.app_source()` 检查；不能作为正式安装输入。去签名proof及实际命令/hash在 `test-executable-payload-proof.json` 和验证返回的 `test_executable_payload_proof` 中留证。测试驱动必须从 `test_bundle_id` 确定容器和UserDefaults域，不能继续硬编码生产ID；跨进程读回不得用 `-AppleLanguages` 参数覆盖来冒充语言持久化。

项目持久ZIP用标准ditto保留资源/扩展属性，在 `zip-command.json` 保存真实命令/退出码，并逐个检查ZIP文件内容hash、字节数、symlink类型/目标、完整成员列表和ZIP SHA。`archive-receipt.json` 保存本地运行入口、项目manifest/ZIP及源码构建归属；原归档/失败记录不被覆盖。若系统清理了临时目录，只将ZIP解包到新的非同步本地目录，然后用持久manifest重新完整检查（仍要求对应源码输入）：

```sh
mkdir /private/tmp/GPXPointViewer-restored-UNIQUE
ditto -x -k /ABS/Builds/RUN/archive/GPXPointViewer.app.zip /private/tmp/GPXPointViewer-restored-UNIQUE
python3 Tools/archive_build.py /private/tmp/GPXPointViewer-restored-UNIQUE/GPXPointViewer.app \
  --validate --for-install --manifest /ABS/Builds/RUN/archive/build-manifest.json
```

摘要导航测试驱动同样在 `/private/tmp` 唯一私有目录准备隔离副本；项目任务记录内的 `isolated-copy-paths.json` 和prepare输出保存实际App/manifest路径。断言、语言、设置持久化阶段和正式偏好隔离规则不变。测试副本保留，不为清理而删除失败证据。
