# R1 / R2 状态正确性 scratch 交付

已在唯一 `/private/tmp/gpxpv-state-6khf6cg_` 完成实现，**48/48 真实 Swift 回归通过**，旧生产 ChangeRevert 原函数的 4 个错误反例均已实际 Swift 复现。未写回产品工作区；全部 34 个 Swift 原文件仍与最初复制 hash 相同。主代理可先审阅本目录 artifacts/state-correctness.patch，再只整合 artifacts/after 下的 3 个文件。

角色为任务指定 GPT-6.1 Sol / ultra；请求参数与独立回执分开，实际模型/effort、token、费用均无独立回执，保持 unknown/null。没有新派发 agent/API、公共路网、启动产品 app、构建可安装产品或写 /Applications。期间按主代理 followup 临时返回修复工具自身日志权限，该任务独立记录于旧 runner-implementation；现已回到本任务并完成。

## 修改范围与行为

仅 scratch 中 `TrackStore.swift`、`ChangeLog.swift`、`PointMapView.swift` 有差异。PointMapView 是主代理 followup-01 明确授权的 3 处视频 callback token 传播，未修改 MetalPointRenderer / GPXParser / TrackData / GeoCompute / GapFill / GPXWriter / UITestHook。

R1：

- TrackStore 首次**接受的编辑提交**保存规范化当前轨迹的 COW 会话基线，包含四列、fileID、name/creator/accuracy；新文件或 clear 清空。全部 active 记录还原直接由该基线重建，精确保留重复次数、NaN 位、无时间顺序和同秒顺序，不从已被 mutation 更新的 files.parsed 反推原始轨迹。
- ChangeRevert 返回 `Result<ParsedTrack, Conflict>`，完整位键含 lat/lon/ele/time，未改全局增量导出 PointKey。部分还原采用 signed multiset，先抵消中间点，再精确删所需个数并插回实际 ChangePoint 候选；缺必要出现次数失败。NaN 使用 UInt64 位键。
- 检查后续未选记录 added/removed/anchors 对选中 touched 集的依赖；无稳定实例 ID 时保守拒绝相同位键的不确定依赖。需要插回无时间点、同一有限时间不同点顺序不明时明确 conflict，不近似成功，不扩大选区。插回顺序检查是 O(n+m) 扫描，未引入逐插点全轨扫描。
- 数据、files.parsed、fills、changes.reverted 只在受 owner 保护的同一 MainActor 提交中改变；冲突不改这些记录。undo 的快照现在包含完整 pre-transaction changes，修复原先只删 fillID 会遗留 delete-only fill 日志的边界。
- landing toast 计数绑定当前事务局部快照，不会因旧提交被丢弃而留给后来新文件/新 fill。

R2：

- 一个文档 revision + 按 lane 的 owner，token 包含文件 UUID 序列和编辑 source track.id。data/review/diff/fog/regions/playback/candidates/tripmap/batch resolve/run/per-row refetch 共用同一时钟。
- load 的 progress/error/parse 完成、parse→ingest→build、显示重建、同数不同文件比较、压测、fill/delete/revert/undo，均先核对 owner/revision/输入再发布。文件/轨迹身份 setter、display mode、clear/reload 等撤销旧 owner，clear 同步清 loading。
- 确认框延迟到下一个 runloop 执行的 fill job 在**入队时**也捕获 revision/track.id，避免等执行时把旧下标的 job 归给新的 current track。
- derived review/diff/fog/archive/region/candidate/trip 发布第一步核对统一 token，保留原局部 generation 作为补充。旧 trip finalizer 也不能清新任务进度。
- batch resolve 支持取消/重启独立 owner；每行 refetch 各自 owner，旧 refetch 必须过守卫后才能移除 handle，避免删掉后来同 id 的任务。batch outcome、进度与 finally 都核对 owner。已有单处路网 requestID 与 batch generation 在共同生命周期失效器里撤销，正确性不依赖 Task.cancel 是否及时生效。
- FWDB、GPX 导出、回放和视频的 loading/progress/error 同样守卫。视频由 began 返回 token，经 PointMapView 原样传给 progress/finished；旧完成只能释放自己 export busy，不能清新文档的 loading。
- 合法 build 在发布时按当前颜色设置重着色；不因轻量配色设置变动重做几何。真实 CPU 颜色回归通过；GPU 在途颜色版本由 P3 负责。

## 实际验证

最终编译/运行证据：

- `artifacts/test-attempts/r2-20261028T233031.634574Z-a7afd96a/`：编译 0、运行 0，STATE_SUMMARY count=48 failed=0。
- 此次 inputs.json 覆盖编译的完整源，测试后已逐一比对仍同 hash（command-output/20261028T233405.178770Z_15c615d1.txt）。
- `command-output/20261028T231722.989635Z_6ac9f6dc.txt`：原生产 ChangeLog.swift 实际 Swift 函数复现 4/4 缺陷：fill 后删 P 全还原残留、相同实例误全删、海拔不同误删、无时间多次删除插回错序。该旧函数仅用 DTO/展示依赖 stub，未替换还原算法。

新回归链接全部生产声明与真实 TrackStore/TrackData/GPXParser/ChangeRevert。只去掉产品 @main 注解，headless test main 为唯一入口；TrackStore 的测试 init 仅跳过 NSApp.appearance，不创建 NSApplication，不写偏好。所有并发测试用 MainActor 闭包 gate + continuation 控制完成顺序，没有 sleep 碰运气。

48 项包括：完整基线/位键/重复点/海拔/NaN/改时链/依赖拒绝/缺数量；真实 load A→clear、A build→B、相同文件数的比较换 C+D、旧错误与新 loading；真实 fill→删合成点→部分冲突且记录不动→全还原；先删除→fill→undo→全还原；delete-only fill 的 undo 日志一致；fill/delete/revert/undo 挂起后 clear/B；确认框旧 job 不采用 replacement；视频旧 progress/finished；删空再全还原；无时及同秒多批删除 partial 拒绝/全部精确；发布使用当前颜色；行级并行/refetch 重启/cancel owner；重复全还原 no-op。

初次默认编译 target 为 macOS26，旧 UITestHook 的废弃截图 API 被 SDK 拒绝；已保留失败。按项目部署目标 arm64-apple-macosx14.0 后完整源码 typecheck 与真实 harness 编译通过。另一次未指定 module cache 尝试被 sandbox 拒绝写 ~/.cache，随后改为 scratch 私有 cache，未扩大权限。遗留 async NSLock / macOS API 警告来自现有源码，本任务没有顺带治理。

## 主代理复核 / 整合入口

```sh
python3 绝对路径/artifacts/run-state-regression_r3.py
# 或对整合树，runner 自动建唯一 /private/tmp 工作目录：
python3 绝对路径/artifacts/run-state-regression_r3.py --source-dir /绝对/整合/GPXPointViewer
```

r3 是可搬移自洽入口，默认从 artifacts/scratch-src 的完整 34 文件复现；每次独立目录保存 inputs/hash/编译与运行 stdout/stderr/退出码。原始 r1/r2 失败证据不覆盖。r3 包装入口尚由主代理独立运行；48 项实际结果来自已执行 r2。

需拷入 shared scratch 的仅 `artifacts/after/GPXPointViewer/{TrackStore,ChangeLog,PointMapView}.swift`。`artifacts/state-correctness.patch` 为 3 文件相对当前冻结产品的完整 patch；before、after、完整 scratch-src、原 hash / after-manifest / source-changes 均在 artifacts。`publication-inventory.json` 给出异步出口位置。请保留 `init(applyAppearance: Bool = true)` 默认行为与 nil publicationGate；二者是 headless 测试 seam，不增加用户界面流程。

## 未验证与后续必要整合

- 新版本真实 UI 的 fill→delete→all 链未跑（任务禁止启动 app），应在主代理整合构建后做一条指定 UI 回归。没有调用真实公共路网；batch/路网回调的 owner 接线已源码核对且编译，取消/重启 primitive 受控验证，未用真实 OSRM/Overpass 回合证明网络行为。
- security-scoped URL 的释放继续在 worker defer；本地 fixture 未获得真实沙盒书签权限，成功授权分支的 OS 资源计数未单测。
- 新安全拒绝只有一个本地化 key：`无法安全还原这些修改。请连同后续相关修改一起还原，或还原全部修改。`。交主代理按 RULES.md 的 chunk→组装流程补 en/de/zh-Hant；未授权写本次产品本地化资源，当前 scratch 使用中文 fallback。
- 当前模型还没有 segmentID。P4-B 合并后必须扩展 `ChangePoint`、`ChangeRevert.PointBits`、`snapshot`、保留/插回数组、fill/deletion/review/preview/undo 传播；不同段同值的回归待 P4 的字段实际存在后补。现阶段不把这一项冒称已覆盖。
- 高层 R1/R2 与后续 P4-B 共用 TrackStore/PointMapView，须由主代理先核验本交付并明确拷入 shared scratch，再登记下一任务。我尚未修改 shared scratch。
