# 第4轮最后单键偏好恢复，不重跑测试

DeepSeek V4.1 Flash/max；用户已允许仅本项目复测必需文件。项目/Users/zyx/Documents/GPXPointViewer。本轮只执行已由Sol和root独立核验的固定失败现场恢复工具，不构建、不运行UI、不截图、不重跑11组或任何已经通过阶段。

前run deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c 已通过新构建标签和cleanup自动检查，root实际看新标签PNG通过，源码与新旧bundle完整。唯一未恢复的是测试后窗口frame，旧工具因观察到与预期不同的frame而安全拒绝。新工具严格核对固定失败run、快照SHA、唯一frame值、其他偏好typed-equal、进程为空、磁盘/CFPreferences稳定；全部匹配才单键还原，并验证完整原始字节hash。不要读完整prefs/进程列表，也不要向外发送这些内容。

先Write自己progress.md三栏，不要预建artifacts。唯一Bash命令执行一次，run_in_background:true：

python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-cleanup-recovery/driver.py run

仅等待CLI正规完成通知；禁止sleep/短sleep/waitsecs/TaskOutput/Read或stat轮询/重试/绕过Block。通知后Read本run的artifacts/cleanup-recovery-summary.json（只此精简summary，不读其指向的完整prefs/raw进程日志），更新progress并报告status/exit、restored、other_keys_preserved、baseline_byte_hash_restored、integrity_after及未重跑任何阶段。原失败保持原样，不能改旧result或假称原run成功。像素此前root已单独通过，本次无需评论或重看。

禁止修改源码、helper、manifest、policy、旧run、期望/数据；只能写自己progress/report。不得安装/关闭正式app、调用其他API/agent、读取密钥/全环境或无关私人文件。没有路网请求。未知实际模型回执/费用为unknown/null。任何失败如实报告并停止，不能自行换命令恢复。
