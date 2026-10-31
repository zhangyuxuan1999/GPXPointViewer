# 最终构建R4已完成部分独立验收

本run整体interrupted，verification incomplete；以下11组实际结果已核对接受，恢复不重跑。新构建exe SHA256 445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb；原prep及偏好/PID基线必须继承。

| 组 | 脚本 | 真实结果 | 用时 |
| --- | --- | --- | --- |
| 1 | run_plausibility_tests.py | 0 / FAILS: none | 803.0 s |
| 2 | run_crosscheck_tests.py | 0 / FAILS: none | 394.5 s |
| 3 | run_batch_review_tests.py | 0 / FAILS: none | 58.6 s |
| 4 | run_batch_card_tests.py | 0 / FAILS: none | 63.4 s |
| 5 | run_route_cache_tests.py | 0 / FAILS: none | 314.2 s |
| 6 | run_map_sources_tests.py | 0 / FAILS: none | 24.9 s |
| 7 | run_tunnel_fix_tests.py | 0 / FAILS: none | 19.8 s |
| 8 | run_fill_tests.py | 0 / FAILS: none | 17.8 s |
| 9 | run_review_tests.py | 0 / FAILS: none | 17.8 s |
| 10 | run_network_tests.py | 0 / FAILS: none | 6.6 s |
| 11 | run_profile_tests.py | 0 / FAILS: none | 28.9 s |

原synth至79/114的部分输出保留，未形成完整phase结果，不算通过；恢复需完整重跑synth及以后阶段。中断缘由为CLI已明确阻止长sleep后代理仍以短sleep轮询，root得知后按已保存启动身份核验runner PID并发SIGINT。没有调用者不明的kill。实际runner退出1、CLI143、终态interrupted/signal_2、清理confirmed，stdout/stderr和after快照完整，changes为空；不把退出码改成0或130。

只读sleep/date/stat动作与任务唯一driver入口约束不符，原调用及Block证据保留；未发现危险写入或外部网络越界，不能据此臆称有凭据泄露。恢复将使用单一固定受控入口和CLI正常完成机制，不使用短sleep/waitsecs规避限制。
