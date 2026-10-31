# P1/P2 轨迹还原与异步发布正确性修复

模型 GPT-6.1 Sol / ultra。用户要求所有已确认问题修复。先读 AGENTS.md、design/product-design.md 的 R1/R2、对应实际源码和 Tests/README.md。主代理正在冻结工作区源码供 DeepSeek R4 基线复测，因此本任务只能在自己 /private/tmp 下唯一 scratch 副本实现和测试，不能修改工作区产品文件。

请修 P1 ChangeRevert：全部还原精确会话基线、部分还原完整字段位键多重集、依赖/顺序不确定时显式安全拒绝，标志和数据一次提交，真实 Swift 回归。修 P2：TrackStore 所有异步轨迹/文件/比较/编辑发布都带统一 owner/revision 守卫，包含 progress/error/loading；clear/close/模式切换/输入变化撤销旧 owner。可控完成顺序验证，不能用 sleep 碰运气。

设计已给出细节和可证伪测试，不要做泛化服务拆分。当前无 segmentID；P4 后续会扩充它，设计接口时记录需要传播的地方，但不要抢 P4 文件。主要拥有 TrackStore.swift、ChangeLog.swift、必要 UITestHook/局部 UI 提示与新增状态回归测试；不要修改 MetalPointRenderer、GPXParser、TrackData、GeoCompute、GapFill、GPXWriter。如必须碰共同文件，先把具体依赖通知主代理。

scratch 从当前源码复制必要文件，完整保存复制清单/原哈希。已有未跟踪源码必须保留，不能 git checkout/reset。日志在本次唯一 run 目录，执行命令 stdout/stderr、退出码、源码前后快照都落盘。可本地编译、纯测试；禁止 API、公共路网、启动 app、安装 Applications。不要另派代理。不要为了过测试改旧期望。

交付可审查 patch、修改文件副本和新增测试（放本 run artifacts）、完整 output.md，逐项列基线复现、修后验证与未验证。不要自动把 scratch 拷回工作区；主代理在 R4 基线结束后整合并构建。progress.md 阶段更新，native 调用 token/费用未知保留 null，不编造。
