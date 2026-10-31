# 固定失败 run 的最后窗口恢复入口

实现冻结，provider执行成功，独立验收pending。只新增r4-label-cleanup-recovery/driver.py、test_driver.py、README.md及本run记录；不改旧helper、旧结果、产品、偏好或其他任务文件。未运行真实app/UI/API/build/defaults，未读live prefs。

## 已核对的事实

失败run 20261029T132227.123510Z_r4-label-final_9d13dc4c的label_sec2/label_cleanup原自动结果均rc0，新标签像素由root接受。本地观察FrameTracker读snapshot时遇到preference file changed while reading，未记录新的after；最终window240 60 960 800随后被原恢复拒绝。仅记录该观察，不推测系统缓存根因。

按root通知API结束后才pin最终result：4b118a12682c02be1dea08d5e813e7d3671ca9d177810cb7c7a3a4d2af7cb242；provider succeeded、cleanup_complete true。旧summary failed/exit1/恢复未写证据保持不动。

本地完整typed plist比较证明after a6af0275f47b1c1adb624817ac488cf7dc68a1e147cce1307997bd6868c89bf1与baseline54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8只有指定NSWindow Frame键不同。完整偏好不打印/不发送外部，诊断只含该键、hash和本地引用。

## 新入口

唯一命令：`python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-cleanup-recovery/driver.py run`。

需要runner唯一新GPXPV_AGENT_RUN_DIR和原task/meta、空artifacts；先拒绝旧/失败/复用输出。固定failedresult/changes/summary/state/原prep及after/baseline证据；不提供任意值或路径参数。

复用固定visual helper的精确comm无app检查、CFPreferences+disk稳定读、single-key defaults和完整本地日志；额外ExactPreferences只允许当前字节SHA和完整typed值精确等于这次失败after。写前再次核对字节；唯一defaults操作改该key为原baseline。写后字节SHA必须精确回54e413原baseline且完整typed值一致。其他key/值/类型、不同序列化、并发/缓存不一致、任何GPX进程、已经baseline状态都不冒充这次after，拒绝。写后异常不覆盖其他键回滚。没有扩大通用白名单，没有启动UI、关闭正式app或重拍重测。

新cleanup-recovery-summary.json是精简回执，偏好/进程全量只在本地日志/副本。标签与本次恢复分别接受，旧失败不抹去；自动成功仍独立验收pending。

## 验证与交付

8/8小范围mock通过，退出0；完整正常输出offline-tests.log/json。覆盖精确成功、语义相同字节不同拒绝、其他键/未知窗口/已baseline拒绝、写前竞态最终guard、写后其他键漂移保留、运行app/CF cache拒绝、旧/复用目录拒绝。全部mock在新helper目录临时假plist运行，默认执行任何非模拟命令都会报错。

真实归档只读validate_evidence通过（real-readonly-evidence.json）；无runtime/live prefs/process/defaults调用。AST通过，前目录不存在、完整新增源码副本/hash/patch见before-files.json、after-source/、file-changes.json、implementation.patch。首次最终provider结果来自root通知而非轮询，见final-result-pin.json。

Driver SHA256：466394755f887cb6b3fd22338dc17d2365930800f462cd313de1c227fb2fa88d。
独立测试：`python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-cleanup-recovery/test_driver.py`。

root独立核验后新DeepSeek仅运行单键恢复。实际服务端模型/强度/token/费用未知均null。
