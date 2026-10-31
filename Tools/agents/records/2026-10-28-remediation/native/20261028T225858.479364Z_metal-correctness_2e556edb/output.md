# P3 Metal 颜色缓冲发布修复与真实 GPU 验证

已在唯一 scratch 实现修复，并用 **Apple M4 实际 Metal CLI 完成 17/17 检查**。受控 shared-event gate 让旧帧先提交但延迟读取，CPU 连续发布两次新色后再放行：旧 GPU 帧读到原始 temporal/spatial 颜色对，新帧读到完整最新颜色对。旧式原地 memcpy 的负对照确定读到被覆盖的新色，说明该测试能暴露原问题。

产品工作区的 MetalPointRenderer.swift SHA256 与任务开始时一致，未写回产品源码。完整 patch、修改副本和测试复现材料已保存到 artifacts，交主代理审查整合；不自动应用 patch。

## 改动

- 在同一文件加入不可变 PointColorBuffers（temporal、spatial、version）。updateColors 只构建全新缓冲，全部分配/填充成功后单次替换组引用。第二分配失败、非法长度时整体保留旧引用和版本；无空间副本时仅更新 temporal。
- TrackGPUBuffers 初始颜色只读领养。两个真实 renderer 经 setData 领养相同初始 MTLBuffer 时，单个 renderer 换色不再污染 cache 或另一 renderer。
- 平面与球面渲染各捕获一组局部引用，全部颜色绑定使用该组；completed handler 显式保留颜色组至 GPU 完成。没有新增逐帧 waitUntilCompleted，没有颜色池复用或修改单段 line/fog 拓扑。
- 增加可选 library 注入供无窗口 renderer 初始化，正常初始化仍取默认 library。分配器可注入第二次失败；测试状态接口在 GPXPV_METAL_COLOR_TESTS 条件下编译。

## 实际验证

最终编译日志：command-output/20261028T230645_037946_00baf87c.txt。编译的是完整实际 MetalPointRenderer.swift 和十三个实际依赖源码副本，没有用简化 renderer 替代。旧依赖中的未使用返回值、Swift 6 并发与 macOS 26 弃用警告保留，未顺带修改。

最终 GPU 日志：command-output/20261028T230749_798079_6a17a8b9.txt，退出码 0，SUMMARY 17/17 PASS。覆盖新旧引用、旧字节不变、已知 Morton 置换、两 renderer 的真实 TrackGPUBuffers 领养、第二分配失败、非法长度、仅 temporal、延迟旧帧、最新帧、GPU 在途旧组弱引用仍存活、原地改写负对照和百万点连续更新。

百万点单次完整颜色对构建 1.052 ms，两次实际 renderer.updateColors 分别约 0.978 / 0.879 ms。保留三份百万点版本时，device.currentAllocatedSize 采样为 24,559,616 B（基线 475,136 B）。这是该 CLI 的采样值，不是整个产品的最坏峰值或跨机器保证；正常队列完成后旧组由资源生命周期释放。

沙盒内首次运行无法取得 Metal device，退出 77，记录保留于 command-output/20261028T230539_309004_f2829379.txt。随后使用用户任务已授权的无窗口 CLI，在受控沙盒外访问 GPU，才得到真实通过结果。首次编译缓存路径拒绝和 harness 字符串错误、缺 RouteReplay 依赖也都保留，没有把失败覆盖为通过。

## 交付与恢复

- artifacts/metal-colors.patch：仅 MetalPointRenderer.swift 的局部 unified patch，便于与 P4 合并。
- artifacts/modified/GPXPointViewer/MetalPointRenderer.swift：最终完整源码；before/ 保存原件。
- artifacts/harness/main.swift、dependencies/、run-metal-tests.py：自包含实际源码回归；脚本在自身 build 目录编译，运行限时 30 秒。需要可访问 GPU 的权限上下文；无设备退出 77。
- artifacts/bin/metal-colors：本机已验证二进制；validation.json 与 artifacts-manifest.json 保存结果和哈希。
- scratch-path.txt、source-before.json、dependency-before.json、changes.json、journal.jsonl：恢复与归因材料。

本子任务未调用 API、公共路网或其他代理，未启动/关闭产品 app，未安装 /Applications。正常配色、补点高亮、删除灰显、空间 LOD 和截图导出的产品 UI 回归须在主代理整合后的指定构建上另行验证；本任务的禁启 app 范围内没有冒称做过。当前实现和受控 GPU 验证已完成，产品整合与 UI 验证状态明确保留待主代理处理。
