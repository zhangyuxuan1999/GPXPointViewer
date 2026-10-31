# P4-C Metal 分段线路与迷雾交付

**P4-C 已在共享 scratch 完成，Apple M4 实际 GPU 最终 94/94 检查通过；P3 真实颜色在途回归另为 17/17。** 使用 A 已冻结的实际 GPXParser/TrackData/GeoCompute，完整测试输入在运行前后哈希一致。主产品工作区 MetalPointRenderer.swift 与 Shaders.metal 仍为原哈希，本任务未写回。

代码已经位于 `/private/tmp/gpxpv-segment-integration-o3kf8civ`，只修改了独占的 MetalPointRenderer.swift、Shaders.metal 和新增 Tests/segments/render。当前结论是渲染流实现与无窗口 GPU 验证通过；P4 全部业务/UI/导出整合仍由主代理与 B 完成，不能用本报告代替整体 P4 验收。

## 实现

- CPU 不展开每条边的坐标。TrackTopology 给出 16 字节 PathDrawRun，renderer 仅按 track/setData、time range、stride、pass 和 soft-break 模式缓存描述符。镜头和文件显隐不重建。line/fog 分别使用自己的软断点 runs，硬段永不合并；大 stride 保留尾边，fog 保留孤点。
- 多 run 的 GPU 端点经段内 order 映射回时间序 SoA。一个 instanced draw 处理全部 run，箭头开启另加一个 draw；不按 segment 逐次调用 draw。普通 identity 单 run 使用独立 segmentIdentityVertex 快路，仍保留最后不足 stride 的边。
- 线路按实际边 AABB 剔除，identity 快路沿用原生 clipper；迷雾按半径扩张的边 AABB 剔除。全部不再用可见 Morton 点锚点决定边集合，因此两端在屏外的穿越边仍可绘制。点云/热力图原空间路径保持。
- topology order 是 TrackGPUBuffers.pathOrder，区别于 Morton order；在后台预建并由两个 renderer 只读共享，setData 领养不增加主线程大数组复制。draw plan 的 order/runs 均不可变，completed handler 保留到 GPU 完成；原 P3 成对颜色版本也完整保留。
- LineParams 新增 fileMask 默认全显。没有 fileID 时按隐式文件 0 处理，避免 partial mask 读取两字节占位缓冲；球面 flags bit3 同样标识 implicit fileID，mask/flash 不再读占位数组。球面仍只绘制点，未新增球面轨迹线。
- 主渲染与测试离屏复用同一 encodeLinePaths/encodeFogPaths。截图/视频原调用继续进入 render；新增 topologyDrawStats 暴露缓存段/run/primitive、plan rebuild 与实际 draw-call 计数供现有诊断钩子使用。计数是 eligible cached geometry，非最终可见像素数。

## 可证伪验证

最终编译：`command-output/20261028T234048_550575_6303a909.txt`，退出 0。最终 GPU：`command-output/20261028T234218_835264_7247d94d.txt`，退出 0，SEGMENT_SUMMARY 94/94 PASS，P3 SUMMARY 17/17 PASS。94 是包含命令健康断言与预热迭代的检查数，不是 94 个独立输入文件。

| 覆盖面 | 实际结果 |
|---|---|
| A0 B0 A1 B1 | GPU 展开恰为 (0,2)/(1,3)，line/fog 在 stride1、2、100 都成立。离屏像素为两条平行真实走廊，中心没有跨段桥。 |
| 筛选与孤点 | global[1,4) 的 line 只留 B 边，fog 同时保留 A1 孤点；排除的 A0 不复活。单点段 line 为0，fog 每段保留圆。 |
| LOD 尾端 | 单段5点 stride3 保留0→3和3→4；实际 fast vertex 的可见尾端像素通过，旧 draw-count 负对照确实遗漏。 |
| 软断点 | 时间和距离两类 fog 软断点均不能被 LOD 跨过；line 采用独立阈值。预览禁 soft-break 时仍不跨 hard segment。 |
| 视口与显隐 | 两端超出旧1.6裁剪窗的穿越边仍在离屏 line/fog 中可见；隐藏一个真实文件保留另一段；implicit file0 的mask1/0均正确。 |
| 球面 | 实际 globePointVertex/Fragment 离屏保持点模式，不制造连接；真实 fileID 与 implicit file0 的 mask 都通过。 |
| 在途资源 | shared-event gate 令旧 GPU command 等到 cache 已换为新 plan 后才读取；旧 descriptor 引用/字节不变，旧/新端点集合各自正确。P3 同时验证旧颜色组跨两次 CPU 换色仍读原组、第二分配失败整体不发布。 |
| 旧 shader 负对照 | 使用保存的真实旧 Shaders.metal，而非 Python 模型。旧 line/fog 画出跨段桥，旧 fog 丢失两端屏外穿越边，旧 LOD line 漏尾边；新实现对应像素均修正。 |
| 缓存与规模 | 镜头 scale 改变复用同一 plan；百万点 identity 仅一个描述符、一实际线路 draw；10,000交叠短段的全部真实边经一次GPU dispatch核对，并以一个实际生产 instanced draw 绘制。 |

`artifacts/gpu-images-final/` 保存 before/after line/fog、crossing 和 globe PNG；已实际查看 before/after fog 与 crossing，图像符合数值断言。产品 UI 窗口没有启动。

## 性能记录与限制

| 样本 | 记录 |
|---|---|
| 百万 identity 纯 plan | 约0.002209 ms，1个run，order隐式，不创建百万条端点数组。 |
| 万个短段 topology+plan | 约0.733 ms；GPU descriptors 160,000 B，order 80,000 B。实际单draw首样本 GPU约12.596 ms，含高度重叠走廊的过绘；不是产品整体FPS。 |
| 百万点单段 warm GPU | 六组交替样本中位数：新5.864854 ms、旧5.860979 ms，差约+0.07%。该夹具边长低于亚像素，主要比较vertex/LOD成本。 |
| 冷样本 | 同次运行新13.720 ms、旧5.859 ms。样本顺序/资源热度未配平，不能据此断言稳定回归，也不能宣称冷帧完全一致。原始值和全部warm数组保留。 |
| 内存采样 | color stress前device allocation约57,294,848 B；含多个保留fixture与P3三组百万点颜色版本后约81,379,328 B。不是整个产品最坏内存界限。 |

发现首个百万点新通用路径样本偏慢时没有直接当作通过；保留了记录，增加单identity专用入口，并收集交替warm样本。初始单样本没有隔离冷帧原因，报告不把它冒称为已证明的某一种根因。多段查找路径没有退回跨段或逐帧 O(n) 边数组。

## 交付与复现

- `artifacts/render-topology.patch`：仅两个产品文件的局部patch，基于已整合P3的scratch原件。先合入A拓扑契约，再与B调用整合。
- `after/`：两个完整修改源与19个测试/夹具/实际依赖文件，21个源文件的内容/权限/哈希在 after-manifest.json；before/保留原件，changes.json列新增/修改/删除。编译缓存排除，已测二进制另存 artifacts/bin。
- `Tests/segments/render/run.py --current-core --output NEW_DIR`：重编当前三个core源码并执行。默认不用current-core时可重现已冻结依赖；所有源hash与完整命令/stdout/stderr落盘，无设备退出77。重现脚本实际 current-core build-only已运行通过，日志为 command-output/20261028T234934_844394_e5577ee6.txt。
- `artifacts/validation.json`：结构化结果与全部GPU metrics；api-contract.md给B列出 fileMask、diagnostic stats、flags与缓存约定。
- final-test-inputs-before/after/comparison.json证明最终测试代码版本稳定；product-workspace-check.json证明本任务未动主产品两个源文件。

首个沙盒运行没有Metal设备，退出77，证据在 command-output/20261028T232557_318945_6c5078a1.txt；之后仅按授权在沙盒外运行无窗口GPU CLI，才取得真实通过。所有编译警告/中间结果保留，未改旧依赖去压掉警告。

## 尚需主代理处理

B需在UI调用传实际 LineParams.fileMask，并按完整P4范围调整旧禁用条件及可选诊断hook；本流没有抢改PointMapView/ContentView。完整Release、真实截图/视频导出工作流、产品UI和全产品性能需在整合后的指定构建验证。本流已审查其共同render入口，并实测该入口共用编码helper，不冒称完整GUI或视频编码已验。

没有调用模型API、公共路网、其他代理或安装/覆盖Applications；没有启动/关闭产品app。模型请求为Sol Ultra，独立模型回执/费用/token未提供，仍为unknown/null。主代理可读本报告与validation后独立verify；恢复先读task/progress/output/changes，勿重放源码修改脚本覆盖其它流。
