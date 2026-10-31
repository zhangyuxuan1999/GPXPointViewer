# 稳定签名归档及测试副本位置修复完成

请求gpt-6.1-sol / ultra；实际服务端模型/强度unknown，费用null。修改限task允许5文件；源码和固定恢复脚本已freeze。当前代理没有执行真实编译、codesign、App、设置写入或安装，也没有执行恢复脚本；旧失败归档/记录完整保留。root在freeze后已报告按脚本恢复一次rc0，并派发四个先前未执行的真实阶段，本代理不再操作或复测。

## 根因与改动

成功e8e131ea实际build三target签名已在01:55通过，但project/Documents归档中的appex稍后被iCloud重新添加FinderInfo。DeepSeek `deepseek/20261031T015641.718099Z_summary-date-settings-exact-command_31038c63/artifacts/settings-abc/20261031T015649.482508Z-a5f14084/prepare.stderr.txt` 在01:56正确拒绝，尚未启动App、尚未执行任何断言。只读输入记录在本run capture/commands/20261031T015931_stable-artifact-failure-and-build_15f54db3。

- `Tools/build_release.py` 正常future build的canonical可运行archive放在既有私有local_staging/archive，继续避开同步目录。项目Builds/RUN/archive现在只保留标准ZIP、manifest、签名/复制/元数据proof JSON和路径收据。build-command显式记录两类目录，stdout JSON的app/manifest是实际运行入口，durable_zip/durable_manifest是项目持久副本。
- `Tools/archive_build.py` 新小helper `preserve_archive_zip` 用ditto标准ZIP保留资源/扩展属性，保存真实argv/退出码，验证无危险/重复成员、root、完整文件集合、每个文件hash/字节数、symlink类型和目标。ZIP SHA/大小/成员清单、构建归属和恢复继承字段写archive-receipt.json。签名守卫不放宽；原compiledApp/旧archive不改。
- `Tests/ui/run_summary_navigation_tests.py` 仅把隔离副本destination移到/private/tmp的唯一私有目录，新增isolated-copy-paths.json把实际App/manifest位置链接回项目evidence。阶段、断言、语言、进程/偏好隔离及UI流程完全不变。
- `Tests/agents/test_release_install.py` 新增2项最小fixture，既有路径fixture只补mock新ZIP发布依赖以维持其原语义，未重跑旧27项。
- `docs/local-install-signing.md` 明确printed app/manifest才是运行/安装入口，项目ZIP用于持久恢复，并给出只在新本地目录解包后使用持久manifest严格检查的命令。README/TestsREADME由root另行机械更新，不在本run源范围。

## 固定恢复脚本与归属

`artifacts/recover-current-release.py`（SHA71228897ab3ebda84e6e03c969c95b71032f63aadb8fb0a656cecb805633117e）仅绑定成功 `Builds/20261031T015341Z_release_e8e131ea` 的原manifest SHA `3aa3460d8912c9ffdce3b5d89b9e9b90ef6634ec3e0c084fe8900f833410f87a`、主exe SHA `76578d2a74fd5549de967f7fef92dbf1b78af82525395b8a6734aae9882cec30`、source SHA `ad6b4f54617f6021eda1d08ae165146cb753f06e48b2b58e42a8f0699b985cff`，并要求DD完整bundle树等于原manifest、实际buildrc0/clean、原inputs前后=current。

脚本不调用Xcode、不重编译、不修改原DD/旧archive。只从原signed compiledApp新copy/archive/严格proof到原local staging下唯一stable-archive目录，另建唯一projectBuilds目录保存ZIP/manifest/原buildreceipt/input快照/原manifest和继承receipt；失败也留新诊断路径。新canonical manifest和ZIP收据都保存artifact_recovery（原manifest hash、exe/source、recompiled=false），避免当前任意源码与二进制混配。

root于freeze后明确报告已执行一次恢复rc0，receipt为 `Builds/20261031T020525Z_stable_signed_b3251cb3/recovery.json`，canonical目录为 `/private/tmp/GPXPointViewer-20261031T015341Z_release_e8e131ea-2iusydxs/stable-archive-b3251cb3`，exe/source不变、ZIP完成。此为root执行证据入口，本代理没有重新执行或重复检查。root随后派发四个pending阶段，最终行为/安装结论仍由root据实际结果判断。

## 本run验证与冻结

执行前具体理由/范围：artifacts/targeted-verification-plan.md。新增2项全通过、命令rc0：capture/commands/20261031T020418_stable-artifact-two-fixtures_d4e49c4d。

1. 一次性模拟bundle上真实ditto ZIP，helper验证文件数据/类型/symlink和完整成员/hash；项目持久目录中没有运行App，原本地bundle树不变。codesign仅mock。
2. mock默认build，确认打印App/manifest指向local staging，而ZIP/持久manifest指向项目run/archive。

旧27项工具fixture和产品测试继承，不整体重跑。没有真实App或设置断言在本run执行。5源文件和恢复脚本compile、逐文件diff及冻结hash保存在capture/commands/20261031T020501_stable-artifact-final-diff-and-recovery-script_6b7f7152（rc0）及artifacts/frozen-file-sha256.json。driver新SHA为 `9f821b3426295baa002bada3c06d6602b573440fc96ddec82f330b4c4ae5f64e`，已给root更新精确执行配置。

所有普通命令/完整stdout/stderr/真实退出码在artifacts/capture/journal.jsonl及commands；before/after快照与changes由runner保留。临时目录可能被OS清理，不能冒称永久存储；durable ZIP+manifest+签名proof+receipt用于后续严格恢复。root已开始所需实际验证，本代理仅finish，不继续恢复或复测。
