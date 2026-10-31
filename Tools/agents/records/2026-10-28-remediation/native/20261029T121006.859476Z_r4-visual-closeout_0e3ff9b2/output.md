# R4 视觉补拍与窗口偏好清理 helper

实现已冻结，执行状态 succeeded，独立验收 pending。本轮仅实现及离线验证；未运行真实 UI/app/API/defaults，未读取或修改当前 live prefs。用户已通过主代理明确回复解锁，真实补拍由主代理验收后派发，不由本实现任务执行。

## 文件与调用

只新增 r4-visual-closeout/driver.py、test_driver.py、README.md；未修改原 pinned helper、原 run、产品、Tests 或工具。前目录不存在；完整新增清单/SHA256/after-source/implementation.patch 已保存。当前driver SHA256：3f08c7f23752d5f88e2d3094ead391991427c822e42dd826941113dbe6d93648。

新 DeepSeek Flash/max run 的视觉单命令：
`python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/driver.py run`

备用、可锁屏独立清理窗口键的单命令：
`python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/driver.py restore-window`

每次使用runner提供的GPXPV_AGENT_RUN_DIR唯一新目录，artifacts须为空。可在该命令完成后由已授权的另一个脚本写同run artifacts/fixture-labels；不要再次调用本helper。新run拒绝复用原/旧执行目录，排他invocation，保留23个继承phase的origin/imported标记。

## 行为和边界

run只重新构造sec2标签场景、sec5三语言场景并cleanup，调用原phase函数/断言/截图，共五phase，预算合计3400秒。不会重跑11UI/synth/selftests/sec3/4/6/docs。50源码与固定exe复核；原prep/PID/prefs原样继承。remaining十一phase实际passed与provider因multiple final results为failed分别记录。

任何UI前读取NSWorkspace front；loginwindow/屏保/未知前台blocked返回75，无UI/kill/prefs写入。每次UI/launch/open重新门禁，截图要求测试bundle在前台；中途锁屏停止后续截图，不用UI重新launch，只关闭固定测试副本，finally尝试精确window恢复。自动成功仍acceptance pending，四图须主代理验像素。

精确恢复只允许原task指定的一个NSWindow Frame键，原baseline必须60 21 1320 860 0 0 1440 903含尾空格；standalone只允许当前为该baseline或已归档验证的1320 -740遗留值。视觉cleanup还可允许本轮受控frame/place后、坐标回显一致且CFPreferences/磁盘一致记录的精确after，不猜测异值。所有/Applications、DST、任意路径GPXPointViewer executable都必须不存在，否则拒绝写且不杀它。全路径guard为(^|/)GPXPointViewer([[:space:]]|$)。

唯一写接口是/usr/bin/defaults write <固定完整plist路径> <完整key> -string <原baseline>，argv传参。defaults export与磁盘typed plist一致；写前重读并再次验证无进程/无漂移，写后验证实际key与其他所有键/类型不变。无整份覆盖/import/delete/kill cfprefsd/回滚其他键；已经baseline时no-op并留after回执。完整偏好只存本地artifacts；stdout和summary/restore receipt不含其他偏好值，执行代理仅读简要回执。存在CFPreferences与磁盘不一致/延迟落盘或并发漂移则fail closed。

## 验证证据

- 最终23/23全mock通过，退出0：artifacts/offline-tests-process-guard.log/json。覆盖精确目标argv、已恢复no-op、原/当前/读写间/写后漂移拒绝、CFPreferences/磁盘不一致、typed其他键保留、运行中任意路径build拒绝、锁屏零UI、截图前台、受控after验证、异常finally、中途锁屏不relaunch、信号130及只运行五阶段。
- 首轮17项16通过，唯一失败是测试Mock被guard包装后的引用断言，原失败日志offline-tests-first.log保留；修正测试引用后20/20通过，再补适配器/信号22/22及全路径guard23/23。
- 归档只读preflight通过：50source、23继承phase、33个原baseline键，原PID=[]；不执行configure/bootstrap/execute，不读live prefs。见artifacts/archived-readonly-preflight.json。
- 两个Python文件ast.parse通过。原输入全文input-*、正常输出/退出码、后续原文指令、源文件副本/哈希和完整新增patch已归档。

实际服务端模型/强度、token、费用未知均null。SIGKILL/断电和defaults最后检查至单键写之间的并发写不能保证排除；后验失败保留证据，不覆盖其他键。原UI cleanup仍有其测试开关复位语义；run启动前要求其他键等于原baseline，结束检查其他键等于本轮开始，避免掩盖用户后续偏好变化。
