# 解除窗口捕获不必要的全局前台限制

执行成功，独立验收pending。收到root“已结束可编辑”后才改helper三文件；此前只读任务/source。未运行真实UI/API/defaults，未修改产品、原driver、旧run、prefs或四项已完成fixture labels。

## 原因与修复

我在helper额外加入的“截图时GPX必须全局前台”限制过严，导致已解锁桌面的Safari/DeepSeek Harness前台被误记blocked。真实hook UITestHook.swift第583行从本进程NSApp.windows按可见/标题匹配取得窗口，第592行按该windowNumber做CGWindowListCreateImage optionIncludingWindow。因此原shotwin无需全系统GPX前台，不会转而截其他app。原源码摘录和当前SHA256见artifacts/shotwin-source-evidence.txt、source-evidence.json。

仅移除ScreenGuard.check的require_test_front参数及bundle比较，install_guards仍在每次UI前执行锁屏/未知前台检查。原shotwin命令、窗口归属、产品截图API和测试断言均未变。Safari/Harness等正常前台允许转发；loginwindow/屏保/unknown仍在转发前拒绝。像素仍由root查看，不把命令通过当作截图通过。

## 验证与冻结

29/29离线mock通过，退出0：artifacts/offline-tests.log/json。原27项中原过严expectation依新合同改为Safari允许/unknown拒绝，新增两项验证同一shotwin在其他app前台原样转发、loginwindow/unknown在转发前阻止。其余进程、精确window恢复、finally、锁屏、CFPreferences等原用例全部通过。两Python文件ast.parse通过。

前后完整三文件副本、哈希与精确patch：before-source/、after-source/、before-files.json、file-changes.json、implementation.patch。无新增/删除helper文件。

最终driver SHA256：`184f7abb3b586c7f0b125629d4dc36bc815fbbab49d2d09e3e5de9aabdc7a93e`。

独立验证命令：`python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/test_driver.py`。

主代理核验后另建DeepSeek唯一新run只补四图并cleanup，不重apply已经完成的labels。旧blocked result/raw原样保留。实际服务端模型/强度/token/费用未知均null。
