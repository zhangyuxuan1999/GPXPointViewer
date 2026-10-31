# CLI消费者核对与授权状态

主代理搜索现有UI脚本，确认Tests/ui/run_crosscheck_tests.py:100会把state.batch.items[].id直接传 `batchdeleteonly <id> 1`。迁移GapID时请核对钩子解析可接受该真实唯一ID，同时保持原按序号的操作契约；不能只把JSON改成字符串却仍由Double解析。其他route_cache脚本仅以id作Python字典键，不要求数字。

另Tests/synth/runner/main.swift仍有原App检测流水线副本：encloses/overlaps只按global index，nature字典按Double tA。主代理会另协调这份测试工具的窄迁移，不要求B抢改主runner；你继续拥有9产品文件和workflow回归。

用户已明确回答允许DeepSeek仅处理本项目复测所需文件（含相关源码/脚本/任务/日志，排除凭据/无关私人文件），授权已归档coordinator/deepseek-data-authorization.md。下次最终DeepSeek复测可依法当前授权进行，B仍无需调用API。
