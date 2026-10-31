# Root恢复入口验收

已阅读全文与全部helper源码。它直接复用原phase函数/阈值，导入prep+11个UI结果明确origin/imported，不重跑reg1..11；仅完整重做未完成synth并继续后续阶段。旧pref/PID基线与12phase原件逐hash校验，当前源码50输入及固定app均校验；单run单次入口拒绝复用。异常/返回非零不冒称成功，finally清理是软中断尽力行为，SIGKILL不保证，需真实cleanup回执另验。

主代理独立14/14 mock通过，4.413s，exit0；命令证据commands/20261029T112606_recovery-helper-independent_1ba430f2。此处验收实现，不替代DeepSeek真实R4及图像。

已单独保存日间恢复当前prefs，mtime仍在原任务执行期间，最终需核对原prep与当前差异。

```json
{
  "Tools/agents/records/2026-10-28-remediation/r4-final-recovery/test_driver.py": "575fc3368880234b8064dc4b8e8ff8cf117f9e37dd93d57a2b7ddbedfaf07e4c",
  "Tools/agents/records/2026-10-28-remediation/r4-final-recovery/README.md": "4ed82069ec3c2ab67d9db93cf5bb3a60abe49a324fadd5dd8d743e7b01dccf86",
  "Tools/agents/records/2026-10-28-remediation/r4-final-recovery/driver.py": "e40e4b998d98d21cdd4ec71b0bc353bc095af00d89dc9d94d5e032d8c38191a7"
}
```
