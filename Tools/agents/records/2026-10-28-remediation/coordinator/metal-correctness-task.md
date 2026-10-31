# P3 Metal 颜色缓冲发布修复

模型 GPT-6.1 Sol / ultra。先读 AGENTS.md 与 design/product-design.md 的 R3、当前 MetalPointRenderer.swift/TrackGPUBuffers。工作区源码正在给 DeepSeek R4 做基线，禁止改动；只在 /private/tmp 唯一 scratch 副本实现、编译与受控 Metal 测试。

修复 updateColors 对 GPU 在途/共享颜色 buffer 原地写：构建新 temporal/spatial 成对完整版本，分配失败保留旧组，渲染捕获一致组，旧资源留到 GPU 完成。不要每帧 waitUntilCompleted，不改变单段线/fog拓扑（P4 另一个任务处理）。主要拥有 MetalPointRenderer.swift 和新回归 harness；如依赖 TrackData 新测试接口，先通知主代理，不修改工作区共同文件。

必须用实际 Swift/Metal 验证旧字节不变、Morton 重排、新旧引用、两个 renderer 共享初始资源互不污染、第二次分配失败整体保持、受控 GPU 延迟读取的旧帧结果正确。可以运行无窗口 Metal CLI，不启动产品 app、不调 API/公共路网、不安装 Applications。环境不支持时保留失败证据并告知主代理，不把未验证当通过。

记录 task、scratch 原文件清单/哈希、命令完整 stdout/stderr/退出码、阶段 progress、修改前后快照。完成提供 patch 与修改文件/测试副本到本 run artifacts、完整 output.md；主代理整合，禁止直接写回工作区产品或自动 git 操作。不要另派代理。后续 P4 可能也修改 MetalPointRenderer，输出易于单独审查的局部 patch。
