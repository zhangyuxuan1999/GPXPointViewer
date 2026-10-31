# 新构建标签定向复测封装交付

实现冻结，provider执行成功，独立验收pending。仅新建r4-label-closeout内driver、test、README、schema/template，并接收root提供policy.json；不改产品、旧helper/manifest/run，不运行真实app/UI/API/build/defaults，不读取live prefs。

## 唯一执行入口

`python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-closeout/driver.py run`

只读取本目录固定policy.json，CLI不接受任意app/policy/manifest覆盖。七字段schema/template已提供，实际policy由root从coordinator原样复制；文件SHA256=a6e2da22ffb71453a362744c72b10ab602752e29020565480f66a65b38f0cdb1。

driver SHA256=37d32fde516f317c6c0dde493cbdec60c1f60d2a8568ed253dd87ae0129353e9。

## 版本与阶段

严格核验旧新source同root/同50key，差异必须且仅ContentView.swift；policy固定newsource/newbuild文件hash，newbuild.source_manifest精确绑定，当前50输入逐文件匹配。旧source/build文件和旧app仍核验；新旧app分离，不接受/Applications或测试目的app。新exe22e77c206e74eb6a88d1a9b56cf1a3d6dc7b0928e7d1784cd1e29943c91d0cf2，旧exe445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb。

继承26phase，包括原prep+11UI、剩余十一自动阶段、三语页脚。原build字段及origin/phaseID全部保留旧exe，三语来自125630 visual-retry旧app；不要求这个run整体视觉acceptance passed，因为标签碰撞失败与三语单独接受要分开。其state/原summary/结果/三张PNG只读核验，主代理像素判断不冒称由helper执行。

独立惰性模块实例仅把原driver.MANIFEST_FILE指向新固定manifest，实际sec2和cleanup使用新BUILD_INFO/GPXPV_APP，phase名label_sec2/label_cleanup。只在当前源验证视图使用已白名单核验的新source；旧helper源码和历史证据不改。屏幕门禁、精确comm进程检查、原shotwin与异常finally/单键窗口恢复完全复用固定visual helper。不重跑11UI/数值/selftests/三语，不重apply labels。

前后校验policy/source/build/app/旧证据。label-version-receipt.json与label-closeout-summary.json分开old/new归属；复用的raw visual summary保留。新结果必须保存新exe身份，旧结果不可改成新构建通过。自动返回0仍acceptance pending/labels pixel pending主代理。

## 验证与证据

- 11/11定向全mock通过，退出0：artifacts/offline-tests-first.log/json。覆盖新旧身份、唯一源差异/无变化/增输入/第二处变化、当前源/旧新app/manifest漂移、固定schema/目录边界、build-source绑定、新runtime拒绝旧身份、仅sec2+cleanup和异常后完整恢复、旧phase build保留。
- root提供真实policy后只读preflight通过：50输入仅ContentView变化，旧新exe都匹配，26继承phase及三张旧三语PNG通过身份验证。artifacts/real-readonly-preflight.json；未configure/bootstrap/execute任何真实runtime。
- Python AST与全部JSON解析通过，旧三个helper hash未变。完整输入input-*、前状态before-files.json、最终副本after-source/、全新增patch implementation.patch、文件hash/provenance file-changes.json、root策略副本root-policy-copy.json均保存。

主代理可独立运行 `python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-closeout/test_driver.py`，随后新DeepSeek Flash/max唯一run只做新标签场景+cleanup；实际PNG须主代理验像素。费用/token/实际模型回执未知均null。
