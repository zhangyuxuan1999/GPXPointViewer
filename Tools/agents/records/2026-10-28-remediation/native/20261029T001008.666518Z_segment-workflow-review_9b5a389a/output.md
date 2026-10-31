# B 业务流独立审查

结论：当前冻结版本未发现需要 B owner 继续修改的新增实质缺陷。独立源码审查与真实生产 Swift CLI 验证完成；验收保持 pending，交主代理独立核验。没有修改共享或主工作区产品源码。

## 版本与方法

- 审查九文件：GapFill、BatchFill、TrackStore、ChangeLog、BatchFillWindow、ChangeReviewWindow、ContentView、UITestHook、PointMapView；读取完整业务任务/补充约定及 Astra 段拓扑、retime 设计。
- frozen-01 复制 34 Swift 无并发漂移。后发现四文件变化，逐项保存 increment-02 补丁；最新 frozen-02、父代理暂冻通知后的 frozen-03 全 34 Swift 完全一致。最终 2026-10-29 00:21:07 UTC 哈希核对无变化，见 artifacts/final-source-check.json。
- 编译完整 34 份实际 Swift，而非重写算法。测试副本只移除 App 的 @main、开放 TrackStore/UITestHook 私有函数访问。另编译原生产 retime 的移除连续尾链检查副本，作为 dense-tail 对照。所有编译/运行输入哈希见 artifacts/independent-inputs.json；全部测试副本保存在 artifacts/independent-compiled-source。
- xcrun swiftc -whole-module-optimization、arm64-apple-macosx14.0 编译 exit 0，实际 CLI 运行 exit 0。编译原有 unused/Swift 6 并发迁移等 warning 原样保留，未作为本轮已修问题或新业务缺陷。没有启动产品 app，没有公共路网/API/网络请求、安装、子代理。

## 实际验证结果

自写独立探针 29/29 通过，其中 15 条行为断言、14 条异步工作完成断言。另独立执行 B 当时最新增强工作流测试 183/183 通过。两者区分计数，B 测试复跑不冒称为独立撰写。

| 真实调用路径 | 结果 |
| --- | --- |
| TrackStore.performFills：交叠段 7/29 先填 A、再填 B；部分还原 A | A 的完整位键/NaN 海拔 payload 恢复，B 已填结果位级不变；只移除 A 导出记录 |
| 部分还原后 revertAllChanges | 精确恢复会话基线的全局序列、段列、四数据列，包括缺时间点的 NaN payload |
| 填 A 后实际删除其合成点，再单独还原填 A | 依赖拒绝，轨迹、日志、标记不发生部分落地；再全部还原精确恢复原基线 |
| 连续两次填后 undoLastFill | 恢复前次轨迹、段身份、fills 与完整 changes 历史 |
| actual Store 同段重叠两个 Job | 整笔拒绝，轨迹/fills/changes/undo 不发布 |
| publicationGate 延迟 fill 后替换 track | 旧 closure 无法覆盖新源，无法发布历史、fills 或 undo |
| 延迟 deletion 后 invalidate；enqueueEdit 后取消 | 删除 worker 与排队确认失效，数据/日志/加载状态不被旧提交复活；同源未取消队列可正常执行 |
| B T07–T13、merge 3/4 链、retime 边界、真实 Garmin 100 项 | 183/183，完整输出在 artifacts/run.stdout.txt |

真实 Garmin 两例再次走当前 GapRouteInputs → 假路线 → landingJob/assessBatchItem → GapSplice → TrackData → computeCandidates → ChangeRevert；不靠风险分数推断填满：

| 候选 | 新合成 / 改时 | 原风险 → 当前风险 | 实际剩余区间候选 |
| --- | --- | --- | --- |
| 84 | 169 / 3 | 0 → 10 | 0 |
| 97 | 112 / 5 | 0 → 85 | 0 |

其余 98 项风险不变；四项 55 分仍是索引 3/25/45/53，本轮没有增加评分或调阈值。100 项逐候选来源身份一致。离线守卫 requestsSent=0、replayMisses=0。详见 artifacts/independent-fixtures/garmin-actual-chain.json。

## 源码审阅结论

- GapID 从原始/聚合候选、sampling/classify 字典、批量选择、预览 UUID 映射、地图缓存到钩子保持同一类型。mergeChains 的 eligibility 始终接收相邻原候选；聚合对象只携带输出，不再拿变化后的 ID 查原字典。旧 tA 仅在唯一匹配时回退，精确输出 ID 和 ordinal 仍可用。
- borrowed SegmentSamples 的 local/global 转换只在边界映射，路网 context、profile、trip/replay/jitter、retime keep/出口速度均在同段；全局时间交错不当邻接。Job membership 先全量校验，跨段锚点/foreign keep/过时 track/同段重叠失败时整笔拒绝。原始候选重叠还在 landingJob 提前拒绝；正常 shift 只在本段按 pathRank 截取。
- previewChange、记录删除集与 GapSplice 共用 membership；retimed 新/旧键与新增、删除、还原、Writer synthetic 的段号传播一致。同值跨段点不会互相标色或进入别段增量。
- P1 使用四列完整位键加段身份及多重集；全还原使用精确基线。不能证明的依赖、同时间排序或缺时插入安全拒绝。本轮没有引入稳定 pointID 的假设。
- P2 在新增编辑/删除/还原、候选/批量/预览 lane 保留 captured source 和 publication owner；真实延迟 worker 与确认队列探针均验证拒绝旧提交。TrackStore.track、files、displayMode 换代会撤销所有相关 owner/request generation。
- 接受的 retime 连续尾链只作用 staleClock；相邻检测使用实际下一 kept/B 的位置和新 dt，保留既有投影/单调/速度检查。dense tail、单出口、跳过坏点、A 侧裁剪、缺时/同位置、停车、非 stale、150m/20s/350km/h 与交叠段映射均实际通过。
- en/de 侧栏改为 ViewThatFits 的横排/两列布局，功能保持；颜色模式与显示开关均有回退布局，没有删除选项或额外缩字体来凑宽度。实际截图不在本任务权限内，由主代理验证。

## 边界与交接

没有新增可操作 finding，严重级别列表为空。这不宣称穷举所有 TrackStore 状态或 Swift 6 语言模式兼容；本任务未做 UI 截图、真实公共路网、全产品界面测试或 GPU 重复验证。B 的测试代码在运行前继续增加，因此归档实际执行的 183 项输入，而非沿用父代理较早 175 项计数。源码结论仅适用于冻结 manifest；若 owner 继续改产品需复核增量。

正常/失败工具输出、编译 warning、退出码、进度 event、消息与源快照均在本 run 保存；ps 沙箱拒绝作为失败证据单列保留，没有用它推断产品异常。正式验收、整合与三目标 Release 构建由主代理负责。

## finish 状态异常（证据保留）

2026-10-29 00:22:25 UTC 已实际执行 finish --provider-status succeeded --acceptance pending --exit-code 0，但运行器检测到注册后共享源的五文件并行变化，强制 acceptance_status=failed，finish exit 1。changes.json 明确说明无法自动归属并发共享写入；此为记录器范围/归属冲突，并非测试失败。provider_status 仍 succeeded。命令 039–043 和 artifacts/finish-attempt-{result,status,changes}.json 保存原始失败证据。

本代理没有产品写入，全部写操作均在本 run；父代理已提前告知 B 会并行修源。注册快照→frozen-01→frozen-02/03 的差异均归档，但需父代理对照 B 命令/快照作独立归属。未自行修改 allow_write、覆盖失败结果或把验收冒写为 pending；已向父代理报告，等待其核验处理。业务审查与 29+183 检查结论不变。
