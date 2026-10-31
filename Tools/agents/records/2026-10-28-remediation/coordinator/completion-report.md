# 第4轮复测与修复最终验收

**验收结果：本轮通过，所需复测已完成，本轮新发现问题均已关闭。已通过的11组UI没有重跑。** 125题继续保留两个引擎各121/125的四项既有基线；没有新增数值回归，也没有修改baseline或放宽阈值。本结论不声称125/125全正确。

## 验收结果

| 项目 | 实际结果 |
| --- | --- |
| 11组UI | 原固定构建已通过；恢复过程继承原始证据，0组重跑 |
| 合成回归 | 114/114，6个输入族全部通过 |
| 自测 | 51/51：portal8、crosscheck31、tunnel5、plausibility7 |
| 125题录音考卷 | OSRM和Valhalla各121/125，四项既有基线不变；回放255、缺失0、真实路网请求0 |
| 双路选择、重取、进度 | 原§2/3/4自动检查通过；单项重取增2请求、全重取100项agree/0项unverified；完成后清除进度 |
| 风险 | Valhalla50/50 high、有理由、默认排除，最低55；OSRM50项无high，风险阈值未降低 |
| 三语固定页脚 | root实际逐图检查zh-Hans/en/de，图标操作行与完整Change Log行均可见，无底部操作条遮挡 |
| 标签重叠 | Sol修复；root实际生产字体/几何24/24；DeepSeek新构建定向检查与root真实PNG检查通过 |
| 代理/留档工具 | root109/109，真实后台/前景流28项离线重放；修复后实际DeepSeek调用正确记录合法多轮结果、成功和失败任务通知 |
| 收尾 | 测试副本全部关闭；最终只写1次窗口frame，其他偏好不变，完整plist SHA精确恢复原值 |
| 完整性 | 当前57份整合输入按后续标签/描述元数据层逐hash一致；50构建源无漂移；新旧bundle各38文件一致 |

Root核验剩余轮416条命令、100项阶段断言和50源输入，见[剩余复测独立核验](r4-remaining-independent-review.json)。最终机器可读结论为[acceptance.json](acceptance.json)。

## 本轮修复

- 精确会话基线还原、多重集部分还原、修改依赖及异步修订/来源归属；root48/48。
- GPU颜色不可变双缓冲与在途版本保留；Apple M4实际17/17。
- 显式segmentID、真实邻接、GapID与编辑membership在解析、计算、导出和业务链传播；核心101/101、生产业务202/202，独立Sol Store29/29及当时183项回归。
- Quick Look跨段断笔、孤点可见、全局6000采样预算，实际像素24/24；地图draw runs、单段快路、裁剪和LOD，root94/94。
- 两处实际补点不足candidate84/97通过连续出口尾链修复，落地重检测无残留缺口、可精确还原；另外98项风险不变。
- 三语侧栏布局、四条翻译、四项多段测试真值及描述日期/理由完成。描述修改经JSON递归/Python AST检查，仅语义说明变化；JSON另有缩进格式化，未改变数值或算法。
- 实际截图发现竖直重合路由标签约20.93×15pt重叠。新实现共用真实字体和显示外框，只在碰撞时沿原侧法向避让，保留90pt门、文字、数量及未碰撞位置；修后间隔明确可见。[修复核验](label-fix-root-review.json) · [新标签像素验收](label-final-pixel-review.json)。

上述计数各自对应其固定源码/构建与范围，不相加成全产品覆盖率。[业务验收](workflow-recovery-final-review.md)保存202项测试与最终业务源的归属核对。

## 构建和继承关系

原完整R4构建：`/private/tmp/gpxpv-remediation-build/Build/Products/Release/GPXPointViewer.app`，SHA256 `445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`。11组UI、数值回归及三语页脚图片属于此构建。

最终标签修复构建：`/private/tmp/gpxpv-label-build/Build/Products/Release/GPXPointViewer.app`，SHA256 `22e77c206e74eb6a88d1a9b56cf1a3d6dc7b0928e7d1784cd1e29943c91d0cf2`。三个Release目标构建成功，50源码中仅ContentView的标签几何/显示不同，其余49源不变；全部65构建输入前后核验一致。本构建实际执行标签定向阶段和cleanup，没有冒称11组或数值套件在此二进制重跑。[新构建清单](label-build-manifest.json) · [当前整合输入](final-project-input-check.json)。

## 真实调用与恢复链

| 原始run | 结论与后续 |
| --- | --- |
| `20261029T011600.159549Z_r4-final_fa1fd007` | prep及11UI通过；后续中断保留，仅已完成项继承 |
| `20261029T112901.777425Z_r4-remaining_d3ab729e` | 剩余11阶段全过；旧parser误报multiple final results，原provider failed保留，由T13修复及独立原始日志核验闭环 |
| `20261029T124907.453283Z_r4-visual-final_dd903ac7` | 窗口原始还原与描述元数据成功；错误要求GPX全局前台造成截图受阻，修复窗口捕获条件后另起run |
| `20261029T125630.030432Z_r4-visual-retry_0b33aad1` | 三语真实像素通过；标签真实重叠被发现，旧图视觉整体failed保留 |
| `20261029T132227.123510Z_r4-label-final_9d13dc4c` | 新标签自动/实际像素通过；最后窗口frame保护门拒绝未记录的新值，原失败保留 |
| `20261029T133852.372561Z_r4-cleanup-final_b50062b0` | 精确匹配固定失败快照后只恢复窗口一键，root7项独立检查全过；零UI/测试重跑 |

最后清理将完整偏好字节还原为 `54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8`，没有整份覆盖偏好，没有残留GPX进程。[最终还原核验](label-cleanup-final-root-review.json)。先前锁屏黑图、保护门拒绝、局部测试失败和一次本地派发前门槛拒绝均保留；后者没有发出API请求，不计真实调用。

## 模型分工与记录

Astra Ultra负责分段/改时边界与后台CLI多轮协议设计；Sol Ultra负责关键实现、独立调研/审查、标签及安全恢复工具；DeepSeek V4.1 Flash/max执行有界复测、翻译/描述元数据与实际恢复。请求参数、agent/session标识、任务、正常过程/输出、错误/退出、结果、前后快照及独立审核均保存。未提供的服务端实际模型/思考强度回执、实际费用保持unknown/null；CLI估价不当账单。

T1–T13覆盖预算并发/未知费用、真实终态、全量快照、唯一恢复记录、权限语义、原生登记、Git限时、身份安全清理、结构化上限、正规后台等待及多轮结果关联。T13按session、UUID、连续index及task/run/origin严格验证合法续轮；保留前序错误和EOF不完整状态。SDK只做离线测试，真实网络路径由已配置DeepSeek CLI验证，不冒称SDK已做实网调用。[代理工具最终核验](background-protocol-root-review.md)。

`Selected model is at capacity. Please try a different model.` 表示当时所选模型服务容量不足。项目原Sol任务保存了此错误，后续仍用Sol Ultra恢复完成，没有静默降级；此错误本身不能证明项目代码、凭据或余额有问题。

[全部派发及回执索引](closeout-run-index.md) · [原始索引JSON与哈希](closeout-run-index.json)。索引只统计顶层登记尝试，离线mock不会冒充API调用。旧失败不改成成功，实际验收以本报告及所链接的独立证据为准。

没有安装或覆盖正式app，没有提交或推送Git。本轮无待完成验收项；四项既有考卷基线明确保留。
