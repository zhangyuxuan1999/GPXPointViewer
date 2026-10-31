# 精确可执行名进程防护修复

已冻结实现，provider执行成功，独立验收pending。只修改r4-visual-closeout/driver.py、test_driver.py、README.md；不改旧run/pinned helper/产品/Tests/工具。不运行真实app/UI/API/defaults，不读取真实偏好。

## 已复现与修复

代表runner argv：`/opt/homebrew/bin/python3 Tools/agents/agent_run.py deepseek r4-visual TASK.md --cwd /Users/zyx/Documents/GPXPointViewer --model deepseek-flash --effort max`，确被旧全argv regex误匹配。完整最小复现见artifacts/minimal-reproduction.json。

改为一次只读`/bin/ps -axww -o pid=,comm=`查询，仅PID与可执行名称/路径，不包含args/env。逐行解析后只匹配Path(comm).name严格等于GPXPointViewer，覆盖任意目录和有空格的app路径。runner的cwd参数不进入comm，因此不误判。命令非0/timeout、空输出、无法解析或重复PID均fail-closed；真实app存在时拒绝恢复，不终止额外进程。完整进程列表仅保留本地command log，精简receipt只包含筛选后的GPX匹配与日志路径。

新driver SHA256：`aa3f43137bfc32607c2982e921eaebb84a7e3c7f260cfb8f38871ac43c486451`。

## 验证

- 旧23项行为与4项新增用例全部通过，27/27，退出0：artifacts/offline-tests.log/json。新增覆盖runner cwd误报、任意路径精确basename/近似名称、命令失败/超时、空/坏/重复记录拒绝。
- 允许的只读ps comm探针：默认sandbox首次EPERM，失败如实保存ps-comm-probe-initial-error.json；申请仅该无args/env探针权限后退出0。真实输出解析通过，GPX匹配=[]。完整进程名列表只本地ps-comm-probe.log，筛选摘要ps-comm-parsed.json，未打印/外传其他进程列表。初始event误将探针失败尝试笼统写为已保存，随后已当前时间明确纠正进度与失败证据。
- 两Python文件ast.parse通过。前后完整源码副本、hash清单与精确diff分别在before-source/、after-source/、before-files.json、file-changes.json、implementation.patch。没有新增或删除helper文件。

## 独立复核/执行

独立测试命令：`python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/test_driver.py`。

主代理核对27项后可沿用已准备的唯一新DeepSeek视觉run命令；本修复不拓展视觉/偏好范围，不替代真实截图或像素审核。实际服务端模型/强度/token/费用未知，保持null。
