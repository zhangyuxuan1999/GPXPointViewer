# 固定标签 run 的最后一次窗口单键恢复

此入口只清理 `20261029T132227.123510Z_r4-label-final_9d13dc4c` 的窗口偏好，不运行任何 UI、app、截图、数值测试、build 或网络。该 run 的新标签与 cleanup 两阶段自动检查已通过，新标签像素由 root 单独接受；原窗口恢复失败证据必须保留。

观察到的情况是：FrameTracker 在受控 place 回显后读偏好遇到 `preference file changed while reading`，没有记入新的 after；最后窗口为 `240 60 960 800 0 0 1440 903 `，原通用恢复入口保守拒绝。这里依据这次固定 after 的精确字节与单键差异恢复，不解释未验证的系统缓存成因，也不把此值加入通用白名单。

主代理独立验收后，新 DeepSeek Flash/max run 唯一命令：

```sh
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-cleanup-recovery/driver.py run
```

CLI 仅 `run`，无任意 path/value 参数。runner 必须提供全新 `GPXPV_AGENT_RUN_DIR`，存在 task/meta 且 artifacts 为空；旧原/失败目录、其祖先/后代和复用目录拒绝，排他 invocation。无需桌面前台，也不会尝试启动或终止任何 app。

固定失败 run 的最终 provider result、changes、label/raw summary、state，以及原 prep state 全部有固定哈希。最终 result 是 root 通知 API 已终结后才记录：`4b118a12682c02be1dea08d5e813e7d3671ca9d177810cb7c7a3a4d2af7cb242`。原失败 status/退出码/窗口恢复拒绝保留；标签与 cleanup 两阶段的通过结果分别核验，不能把旧失败改成成功。

归档 after SHA256 必须是 `a6af0275f47b1c1adb624817ac488cf7dc68a1e147cce1307997bd6868c89bf1`，原 baseline 必须是 `54e413eb9f2b470a41226ef20961c3fceb1963ed01668a834e570ba502e295a8`。本地 typed plist 比较证明只有原任务指定的 `NSWindow Frame SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<GPXPointViewer.ContentView, SwiftUI._FlexFrameLayout>, SwiftUI._AppearanceActionModifier>-1-AppWindow-1` 键不同，after 精确为上述 240/60/960/800 值，baseline 精确为 `60 21 1320 860 0 0 1440 903 `；两值尾空格均保留。

复用固定 visual helper 的精确 comm 进程检查、defaults/磁盘稳定读取、原 baseline 验证和单键 defaults 写入，再用本入口 `ExactPreferences` 加强：

- 当前 CFPreferences 与磁盘稳定且 typed-equal，磁盘字节 SHA 和完整值必须精确匹配该失败 run 的 after；即使仅序列化不同或已经 baseline，也不能冒充本次 after，直接拒绝。
- 写前重复读取与进程检查，最后紧邻写入再核对 after 字节/值。任何路径的 GPXPointViewer executable 在运行都拒绝，不终止它。
- 唯一实际写操作仍是固定 plist 路径、固定 key 的 `/usr/bin/defaults write ... -string <原baseline>`；不直接写 plist、不整域 import、不删除其他键。
- 写后 CFPreferences/磁盘再次稳定一致，完整 typed plist 必须为原 baseline，原始磁盘 SHA 必须精确回到 `54e413...`；否则失败并保留证据，不覆盖其他键补救。

原恢复函数的 baseline/legacy 默认检查没有修改；本入口的 exact after wrapper 在任何写前拒绝其他所有当前状态，因此不会将那个默认列表扩大为本次权限。仅把这次经过归档证明的 after 作为恢复参数，旧 helper 与旧 run 均不改。

新 run 的 `cleanup-evidence-receipt.json` 保存固定证据引用；完整 command 日志/前后 plist/defaults 导出仅留本地 artifacts。DeepSeek 只读 `artifacts/cleanup-recovery-summary.json` 的精简回执，不读/上传完整偏好或进程列表。摘要包含固定 hash、目标键、写入/还原/其他键保持、原始 hash 还原及原失败 run 引用。命令返回 0 表示这次恢复检查全部通过，任务独立验收仍 pending；1 失败，2 配置拒绝。显式 Python 中断由复用恢复函数留档并返回 128+signal。

离线验证命令：

```sh
python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-cleanup-recovery/test_driver.py
```

八项测试全部在本目录 `.offline-fixture-*` 的临时假偏好文件运行，进程/defaults/UI 都模拟，不读写真实偏好。覆盖 exact 成功、字节/值/其他键漂移、写前竞态、写后其他键变化、进程/缓存拒绝以及旧/复用输出目录。实现 native run 保存完整正常输出、诊断、源文件前后快照/哈希/patch与只读归档核验，实际服务端模型/token/费用未知保持 null。
