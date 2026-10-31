# 构建签名、安装守卫与隔离测试副本完成

请求模型 gpt-6.1-sol / ultra；原生 agent /root/signing_persistence_fix。实际服务端模型/强度回执 unknown，费用 null。实现完成，独立验收 pending，由 root 负责。未构建、签署、启动或安装实际App；未写真实偏好、未改旧备份/正式App，未调用外部服务。

## 改动与依据

复用设置审计run ../20261031T011612.884046Z_settings-persistence-audit_060da613/output.md：既有no-sign新包缺sandbox entitlement，改变偏好域；旧备份严格校验受FinderInfo拒绝，不能说旧包严格签名通过。产品AppLanguage/TrackStore无本run修改。

- Tools/build_release.py：正常Release保留Xcode原有三target ad-hoc签名及各自entitlements，不传CODE_SIGNING_ALLOWED=NO；记录requested_no_sign与signing_policy。--no-sign保留，仅用于诊断，manifest明确不可安装。
- Tools/archive_build.py：新归档以ditto保留macOS元数据，只在新副本清理FinderInfo/ResourceFork，保留quarantine。三个target分别严格验证、Info与签名Identifier核对、各自安全entitlements精确匹配源码、保存真实CDHash/签名命令输出。签完后的实际全bundle/主exe hash入manifest；for-install拒绝unsigned、历史或未知签名。旧manifest正常来源检查仍兼容。
- Tools/install_release.py：必须--execute和显式--authorized-target /Applications/GPXPointViewer.app，拒绝运行中主App，先完成暂存和当前来源/严格签名检查，再rename保留旧包完整可恢复备份；失败保留新包并回滚。锁覆盖提交与回滚；正常进程探测、复制/xattr/签名及安装前后hash落盘。没有退出/启动/强杀、真实偏好写入或签署旧App功能。
- root补充要求：archive_build.py提供唯一ID族隔离副本。仅从已签名可安装的原归档复制，改三个CFBundleIdentifier，逐target各自entitlement按QuickLook→Thumbnail→主App ad-hoc+runtime签名；不使用--deep签名。保存原manifest原文、原Info快照、限定Info/签名范围的副本变化、命令与hash；与生产ID严格分离。派生manifest可被validate_bundle/ui.app_source识别，拒绝正式安装。默认生成唯一测试ID，也拒绝已存在容器/偏好路径的复用ID，只做新ID路径存在探测。
- 新增 Tests/agents/test_release_install.py 与 docs/local-install-signing.md。既有README/Tests README历史no-sign示例未在本run拥有范围内修改；新文档明确它们不是正式安装指令。

## root可直接使用的命令

```sh
python3 Tools/build_release.py --arch arm64
# 若已证实iCloud协调卡住，可追加 --no-icloud-coordination
python3 Tools/archive_build.py /ABS/Builds/RUN/archive/GPXPointViewer.app --validate --for-install

# 保持原归档只读；输出JSON含app/manifest/test_bundle_id
python3 Tools/archive_build.py /ABS/Builds/RUN/archive/GPXPointViewer.app \
  --prepare-isolated-test-copy --destination /ABS/NEW_TEST_COPY_DIR

# 当前用户编辑保全、正常退出主App、最终验收通过后：
python3 Tools/install_release.py /ABS/Builds/RUN/archive/GPXPointViewer.app \
  --execute --authorized-target /Applications/GPXPointViewer.app
```

隔离准备可选 --test-bundle-id de.wayne.GPXPointViewer.test.<唯一slug>；默认生成更稳妥。副本最终身份在manifest.test_copy.bundle_id及validate_bundle返回的test_bundle_id；两扩展加.GPXQuickLook/.GPXThumbnail。已把接口同步/root/summary_date_implementation。测试驱动必须据此设置容器及偏好域，跨进程语言读回不能用-AppleLanguages强制覆盖。

源归档artifact含signing-checks.json、copy-result.json、metadata-cleanup.json及build-manifest.json.signing（policy/installable/bundles中的entitlements/CDHash/实际命令结果）。安装默认receipt位于唯一Builds/*_install_*/install-result.json，含实际旧包文件hash、备份路径、三阶段签名JSON、源/暂存/安装后来源与实际exe hash；备份的旧签名不被清理/冒称通过。

## 验证结果与继承关系

16项覆盖通过，但**不是最终源码整套重跑16项**：基础12项中的2项继承早先已通过证据，6项r3通过，4项r4通过；隔离能力新增4项单独通过。重测具体原因和范围在artifacts/targeted-verification-plan.md，全部旧失败保留。

- 首轮：12项，10 error（错误采用Darwin Python不存在的os.listxattr/setxattr）；2项通过。
- r2：新代码改用xattr/ditto，但-p读取不存在属性会非零；10项未过，另2项通过。保留真实失败。
- r3：改为递归列属性名后仅删已出现的明确属性；仅重测此前未过10项，6通过，4项fixture问题（/var别名触发正确路径守卫、FinderInfo全零值被macOS视空）。
- r4：仅修fixture真实路径与非零FinderInfo值，仅重测剩余4项，4/4通过。
- 新隔离派生能力：4/4通过；验证原归档不变、ID族独立、签名顺序/各自entitlement、unsigned/正式ID/越界改动/父证据篡改拒绝及不可正式安装。
- Python源码compile及三个CLI --help通过。codesign全部由fixture模拟；ditto/xattr仅操作临时fixture。未重跑产品/UI/Store/核心路由既有测试。

原始命令、完整stdout/stderr/真实退出码：artifacts/capture/journal.jsonl及commands/。精确证据索引和本run修改/新增/删除/后hash见artifacts/verification-summary.json。初始只读定位中一个假定coordinator/capture.py路径和未完成审计output不存在，原工具exit1未被视为成功；后续使用实际2026-10-30 coordinator capture，并读取已完成审计output。一次apply_patch因上下文末尾空行不匹配失败，无部分改动，随后精确修正。修改前快照为snapshots/before，finish将保存after/changes。

## 尚需root完成

统一一次真实signed Release构建、实际产物三target签名及归档验收、唯一测试ID下所需行为验证，然后按持续授权保全编辑/正常退出并覆盖安装。此run fixture不证明真实新签名包或跨进程用户设置已通过；真实偏好白名单比对及是否迁移仍归root最终阶段处理。安装脚本不代替编辑保全，也不启动任何应用。
