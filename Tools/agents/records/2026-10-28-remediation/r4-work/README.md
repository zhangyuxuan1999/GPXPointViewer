# R4 唯一执行工作目录

仅允许当前 DeepSeek R4 代理在此编写执行任务书的 driver.py 和保存过程产物。实际 API 调用记录在相邻 deepseek/ 下的唯一 run 目录，运行时环境 GPXPV_AGENT_RUN_DIR 指向它。完整权限见 coordinator/r4-dispatch-contract.md。
