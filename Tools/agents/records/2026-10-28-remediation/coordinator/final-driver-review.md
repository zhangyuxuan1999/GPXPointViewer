# 最终R4脚本准备独立验收

主代理读driver入口、构建manifest/hash校验、PID/编码/progress路径实现及Sol完整53项纯检查证据。另独立执行coordinator/verify_final_driver.py：无副作用导入、缺run配置拒绝、测前为空PID正确、UTF16/坏XML、8段原回归逻辑AST不变、严格min>50/95%/OSRM0均通过；没有启动app或任何调度阶段。

新增范围仅r4-final-work/driver.py与README.md，独立manifest/prepared-changes记录两文件。默认runner排除records导致自动changes为空这一点已如实记录，不能把空清单冒充无改动。真实build-manifest尚未创建，最终复测尚未执行。

用户后来明确授权仅本项目复测必要文件由DeepSeek处理；README中「待授权」为准备时状态，将由主代理更新为指向真实授权记录。先前被拒绝的调用仍未执行，不会被倒填成功。
