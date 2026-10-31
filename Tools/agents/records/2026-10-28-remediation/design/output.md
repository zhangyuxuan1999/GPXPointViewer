# 本轮架构决策结果

设计任务已完成；本任务未修改产品源码或代理工具实现。

## 交付

- [tool-contract.md](tool-contract.md)：`run_store.py` + `agent_run.py` 的最小契约，包括唯一目录、native登记、状态与验收分离、事件脱敏、权限、预算预留、未知费用、快照、恢复及7组离线验收。第一阶段已及时发送主代理供Sol实现。
- [product-design.md](product-design.md)：R1–R4源码核对、最小修复和可证伪测试。R1建议精确会话基线+部分还原多重集/依赖预检；R2统一发布owner并守住progress/error/final；R3使用不可变成对颜色buffer；R4独立段身份贯穿变换、连接前缀/检测/测速/导出，并明确交叠段完整渲染需要edge列表。

## 关键决策与实施限制

1. 运行成功不表示产品测试通过；错误final、空结果、损坏JSON、超时/轮数/预算终止必须保留真实状态，不能以exit0或最后一段文字代替验收。
2. unknown费用冻结依赖USD余额的自动预算。按主代理补充的既有用户授权，有明确轮数/时限/合理重试上限的DeepSeek调用可继续；每次登记原因，费用仍为unknown，不能宣传金钱封顶。
3. R1仅把Set换为倒序仍不足：同批多记录共享旧下标，部分还原也可能依赖后续编辑。全部还原采用基线可精确；无法判定的部分还原应拒绝并解释，不能静默级联或近似成功。若要求任何选择都必成功，则需要稳定实例身份/事务重放，超出最小补丁。
4. R2旧回调不能清理新请求的loading；所有异步编辑发布出口都要覆盖，不只load/build。
5. R3GPU旧帧可以继续读取旧buffer；新颜色先完整生成再成组替换。不能靠主线程串行或waitUntilScheduled认定安全。
6. R4fileID不是segmentID。仅阻止跨段连接能保证不误连；交叠段完整线/迷雾还需段内edge列表。这个范围选择和未验证项应进入主代理最终报告，不能把保守断连算作完整拓扑修复。

## 真实验证

已只读核对 README、Tests/README、docs/batch-review-design.md、上轮 invocation-audit/architecture 输出，以及 ChangeLog、TrackStore、MetalPointRenderer、GPXParser、TrackData、GeoCompute、GPXWriter、GapFill、Shaders 中相关路径。

运行 `r1-counterexamples.py`（exit 0）确认3个与当前源码逻辑一致的反例：补→删→全还原残留中间点、相同值重复点被过删、海拔不同但旧键相同的原点被过删。完整结果在 `r1-counterexamples.out`。这是Python逻辑模型，**没有编译或执行生产Swift，也没有运行app/Metal/UI测试**；产品修复完成与否必须由实现后真实测试决定。

所有读取与执行结果已落 `journal.jsonl` 及引用文件。一次read_ranges因行号超过文件末尾出现IndexError，已记录失败并用边界检查重试；没有改动源码。没有联网、调用API、取凭据、安装/覆盖/关闭正式app，也没有改旧Claude历史。

## 未完成与恢复

本任务是设计任务；代理工具实现、mock故障验收、DeepSeek第4轮、产品修复与真实测试由主代理及其已登记Sol任务继续。产品尤其仍需实际Swift多重集/基线验证、受控异步发布测试和GPU在途测试。恢复时先读本文件、progress.md及两份设计；无需重做本任务已完成的源代码检索。

模型请求为 GPT-6 Astra / ultra；本工具未提供服务端独立模型回执、token或费用，相关字段保持null，不把请求配置当作实测凭证。
