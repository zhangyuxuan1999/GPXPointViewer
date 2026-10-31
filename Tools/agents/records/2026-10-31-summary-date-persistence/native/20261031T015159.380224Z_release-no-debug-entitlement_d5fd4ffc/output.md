# Release基础调试权限注入开关修复完成

请求gpt-6.1-sol / ultra；实际服务端模型/强度unknown，费用null。实现完成、源码freeze，独立验收pending。本run无真实Xcode构建/codesign/App运行/安装/偏好写入，未改已有失败归档、正式包或源entitlements。

## 证据与最小改动

`Builds/20261031T014913Z_release_dd6307b2` Xcode真实rc0且源码before/after一致，wrapper因额外调试权限rc1。原archive/signing-checks显示实际主App严格签名成功，但含源码不存在的get-task-allow=true；三个已有xcent均含该键。root最初请求readonly分析早于新run init，指令与当时正常只读命令/结果如实另存artifacts/bootstrap-readonly.json，没有挪用或改写旧run。

读取本机Xcode `CoreBuildSystem.xcspec:2178-2181` 确认 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` 是Boolean，默认YES。实际spec证据见capture/commands/20261031T015233_xcode-inject-base-entitlements-spec_82b926c1。结合实际xcent额外权限证据，采用明确关闭该默认注入的最小修复；最终是否消除权限仍由root真实构建/签名守卫检验。

`Tools/build_release.py` 默认Xcode argv新增 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`，build-command.json新增实际布尔False记录。签名仍开启，三个target继续各自原entitlements；严格归档安全权限匹配逻辑不改，不往源码添加get-task-allow。没有新增resume/cache选项或额外架构功能。`docs/local-install-signing.md` 同步开关说明。

## 定向验证与范围

`Tests/agents/test_release_install.py` 只新增一个mock参数构造case：默认argv恰好包含一次NO、持久记录False，并且模拟Xcode失败时不归档。新1/1通过rc0，完整记录capture/commands/20261031T015327_no-injected-base-entitlements-one-fixture_5e523e80。执行前理由见artifacts/targeted-verification-plan.md；旧26项继承不重跑。mock没有真实执行Xcode，不能声称实际调试权限已移除。

当前3允许文件源码compile、before/after diff和冻结hash已保存capture/commands/20261031T015353_no-debug-entitlement-final-diff_f9cbd395，rc0；hash另见artifacts/frozen-file-sha256.json。全部普通命令/正常输出/真实退出码在artifacts/capture/，本run不含任何源产品改动。before/after完整快照及changes由runner保存。

## root下一步

接口仍为 `python3 Tools/build_release.py --arch arm64 --no-icloud-coordination`，不传--no-sign。root已选择下一次默认工具唯一新run真实构建，不新增恢复功能；实际编译/签名/xcent验证及最终archive守卫由root执行。若仍有额外安全权限，继续拒绝安装，不放宽守卫。原rc65/FinderInfo与本次Xcode rc0、wrapper rc1的失败证据均保持原状。
