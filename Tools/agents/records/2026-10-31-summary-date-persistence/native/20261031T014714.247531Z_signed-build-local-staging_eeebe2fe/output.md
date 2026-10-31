# 本地 DerivedData 签名构建路径修复完成

请求 gpt-6.1-sol / ultra；原生 agent /root/signing_persistence_fix。实际服务端模型/强度 unknown，费用 null。仅修改允许3文件，已freeze并通知root继续必要真实build；本run没有实际构建、codesign、App运行/安装或用户偏好写入，没有清理源/旧包/原失败产物元数据。

## 实证与修复

原始失败 `Builds/20261031T014533Z_release_7bd34ec7` 真实rc65。build.log:632–645显示Thumbnail使用工程原有ad-hoc+runtime+独立xcent签名，但新生成的appex有FinderInfo而被拒绝。只读精确检查该run三个新bundle根：都有com.apple.FinderInfo、com.apple.fileprovider.fpfs#P；相关QuickLook/Thumbnail源目录和全部源文件只有provenance，无FinderInfo/ResourceFork。证据在本run capture/commands/20261031T014733_failed-owned-product-metadata_7139552b。此证据支持生成目录的FileProvider属性干扰；没有证据需要改源属性。已完整读原coordinator/signed-release-build-reason.md，并按要求等前轮审查finish、root明确go后才改源码。

`Tools/build_release.py` 现在通过 `tempfile.mkdtemp(dir="/private/tmp")` 建立权限700的唯一本地staging，Xcode `-derivedDataPath` 和成功后所取App都使用该目录下的DerivedData。中间目录不在Documents同步范围内；签名策略、源码输入hash检查、归档三target签名守卫均不变，不存在unsigned回退。

持久的Builds/RUN/build.log、build-command.json、inputs-before/after以及最终archive仍留项目。build-command新增实际local_staging_path、derived_data_path、intermediates_retention；stdout新增DERIVED_DATA。成功或失败均不自动清理本地中间产物。系统可能清理临时目录，长期构建证据/成功归档以项目Builds为准；原rc65失败没有被覆盖或删改。

`Tests/agents/test_release_install.py` 只新增一个构建路径mock fixture及所需import；`docs/local-install-signing.md` 增补默认路径/保留边界。没有其他Tools或产品文件更改。

## 定向验证

执行前理由与最小范围在artifacts/targeted-verification-plan.md，链接原rc65和具体新目录属性。只运行新 `test_staging_local_derived_data_argv_and_record`：1/1通过，rc0；记录 `capture/commands/20261031T014903_local-derived-data-one-fixture_0ca359c6`。mock校验mkdtemp请求/private/tmp、唯一run前缀、xcodebuild argv的DerivedData、build-command实际路径、archive输入App来源一致，默认sandboxed-local仍启用，并确认中间产物不自动清理。没有调用真实Xcode或归档/codesign。

旧16+9共25项继承前两run证据，不整套重跑。当前3文件源码compile、before/after逐文件diff与冻结hash记录在 `capture/commands/20261031T014932_local-staging-final-diff_f693d67f`（rc0）和artifacts/frozen-file-sha256.json。原始普通命令完整stdout/stderr/退出码在artifacts/capture/journal.jsonl。

## root下一步

接口不变：`python3 Tools/build_release.py --arch arm64 --no-icloud-coordination`，继续不传--no-sign。root下一次实际signed Release检验本地生成目录是否解决真实CodeSign失败；本mock不冒充真实构建成功。真实三target签名、派生副本payload/唯一身份行为及安装仍按已记录最小范围验收。本run不再次执行任何产品构建或测试。
