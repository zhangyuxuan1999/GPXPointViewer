# R4 真实调用发现：自身留档写入权限

R4已正常与DeepSeek交互并成功Write/运行r4-work/driver.py；5类不在命令授权内的自由Bash被拒属预期。但自动授予的run/progress.md与artifacts/**的Write都被Claude CLI拒绝（绝对/相对路径均试过），造成语义progress不能保存。证据：coordinator/commands/20261028T230135_r4-denied-inputs_a265f54d/stdout.log；完整原始transcript在deepseek/20261028T225704.094186Z_r4-baseline_b44e2242/。

现存差异：r4-work允许Write+Edit且可工作，自身日志仅Write授权。请先暂停P1/P2修改，调查CLI实际权限语义（本地CLI或官方主源），最小修复自身progress/artifacts的权限，保持仅本run范围。可能Write实际由Edit规则匹配，不能只按推测通过。增加离线结构回归，真实回合由主代理有界R4恢复验证。不要自行付费探针/无限尝试/扩大为全目录写权限。修完给准确命令限制提示，代理应直接走已授权driver而非反复调用被拒自由Bash。

另任务书本身的UTF-8 grep错误：旧规则误报app缺两字符串，实际是UTF-16LE Localizable.strings，主代理已核实。此项主代理修恢复任务即可，不需改业务代码。原生当前task日志中记录暂回工具修复，随后继续P1/P2。
