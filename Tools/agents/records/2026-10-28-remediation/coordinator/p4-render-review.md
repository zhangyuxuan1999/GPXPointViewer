# P4-C主代理独立验收

主代理阅读完整交付、局部patch、缓存/不可变资源/完成回调实现，并从shared当前3个core源码重新swiftc编译生产MetalPointRenderer/Shader与冻结无关依赖，再在实际Apple M4执行。完整命令记录commands/20261028T235420_segment-render-independent_3e2b7eab；可持久证据拷入render-independent-evidence（输入hash、编译/GPU正常输出/错误/退出、原始PNG）。编译0、GPU0，实际94/94及P3 17/17通过。

主代理实际查看自己本次生成的before/after fog及crossing四张PNG：旧实现产生N形假连接，新实现为两条水平真走廊且无中间桥；旧穿屏边图全黑，新实现画出完整水平走廊。数值像素检查与可视证据一致。

本次百万identity交替warm中位新3.7093/旧3.7031ms（约+0.17%），单次冷新11.7446/旧5.8630ms，冷顺序/资源热度未配平，不能称冷性能相同或整体FPS无回归。万段实际1次draw，160000B descriptors+80000B order；旧GPU资源门控反例和LOD尾端/硬断/软断/隐藏file/球面点均通过。

这是C局部实现验收通过，不替代B文件显隐调用/主app三目标构建、UI、导出/视频链验证。编译保留旧冻结RouteReplay依赖的async锁警告，不冒称零警告或已迁移Swift6。
