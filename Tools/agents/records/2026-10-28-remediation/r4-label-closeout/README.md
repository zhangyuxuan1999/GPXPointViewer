# 新构建标签定向复测

此入口只在新构建重建原 sec2 标签场景并 cleanup，不重跑已通过 11 组 UI、数值、自测或三语页脚。实现与离线测试由 Sol Ultra 执行，实际服务端模型/强度、token 和费用未知。真实执行须由主代理独立验收后派发 DeepSeek Flash/max，截图仍由主代理验像素。

## 固定调用与策略

```sh
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-closeout/driver.py run
```

只接受 `run`；不接受任意 app、manifest、policy 路径或环境覆盖。runner 提供全新、artifacts 为空的 `GPXPV_AGENT_RUN_DIR`。原恢复入口的单次目录拒绝规则继续生效；旧 run/证据绝不覆盖。后台任务通过正规通知机制等待，不让模型 sleep/轮询。只运行 `label_sec2`（原 sec2，900 秒）和 `label_cleanup`（原 cleanup，400 秒）；阶段预算不是完整命令的硬上界。

主代理提供并审核本目录唯一 `policy.json`。格式见 `policy.schema.json`，`policy.template.json` 中 null 必须填写后才能执行。仅七字段：

```json
{
  "schema_version": 1,
  "purpose": "r4-engine-label-only",
  "new_source_manifest": "<coordinator内绝对路径>",
  "new_source_manifest_sha256": "<64位小写SHA256>",
  "new_build_manifest": "<coordinator内绝对路径>",
  "new_build_manifest_sha256": "<64位小写SHA256>",
  "new_executable_sha256": "<64位小写SHA256>"
}
```

新 source manifest 沿用原 `identical_root` 与 `files` 格式，必须同一项目根、同样 50 个相对输入；哈希差异**必须且只能**是 `GPXPointViewer/ContentView.swift`。无差异、额外修改、增删输入、当前文件不符均拒绝。新 build manifest 至少包含绝对 `app`、`executable_sha256`、`source_manifest`；最后一项须精确绑定 policy 的新 source 路径。所有 manifest 文件和新 exe 都复核固定哈希。新旧 app 必须分离，不能使用 /Applications 或测试副本目的目录。

policy 的完整文件哈希在启动时固定，结束时再次核验；不允许测试中换策略。主代理本次提供的实际策略是旧 exe `445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb`、新 exe `22e77c206e74eb6a88d1a9b56cf1a3d6dc7b0928e7d1784cd1e29943c91d0cf2`。

## 新旧归属

旧 source/build manifest、旧 app 和旧证据继续只读核验；不改旧 helper、旧 manifest、旧 phase 的 build 字段。当前源码校验采用已通过严格白名单比较的新 source manifest；历史构建和继承结果仍保留旧 exe 身份，不能说 11 组与三语已测过新 exe。

继承共 26 个 phase：原 prep+11 UI、剩余十一阶段自动结果、旧视觉 retry 的三语页脚。三语截图来自 `20261029T125630.030432Z_r4-visual-retry_0b33aad1`，原 state/summary/结果与三张 PNG 固定哈希分别核验。该 run 的整体像素验收因标签碰撞 failed，不影响主代理单独接受的三语页脚；helper 不要求其整体 acceptance passed，也不把自己的文件核验冒充像素审核。

新原始 driver 在独立惰性模块中将 `MANIFEST_FILE` 指向新固定 manifest，再配置 `GPXPV_APP`，因此 sec2、cleanup、命令日志和新截图实际使用新 app。被继承结果全部标 imported/origin/original phase ID，build 不变。只有本次两阶段保存新 build；结束时再核对新结果的 build 身份。

## 安全、恢复与产物

直接复用固定 SHA256 的 `r4-visual-closeout/driver.py` 中屏幕门禁、精确 comm 进程检查、原窗口 ID shotwin、异常 finally cleanup 和精确窗口键 defaults 恢复。Safari/Harness 正常前台允许窗口捕获；loginwindow/屏保/unknown 仍阻止。恢复前要求所有路径 GPX executable 不在运行，禁止终止正式 app 或额外进程。只改指定窗口键、CFPreferences/磁盘双核对、其他键 typed 相等、完整偏好仅本地保存等边界不变。DeepSeek 仅读简要回执，不读取/上传完整偏好或进程列表。

本模块只修改惰性导入实例的当前 source 验证视图、两个 phase 清单和新 manifest 配置；旧 helper 源码不动。原结果、原命令与截图完整保留。新 `artifacts/label-version-receipt.json` 和 `label-closeout-summary.json` 显式分开 old/new manifest、exe、继承三语 PNG 与新两阶段。复用控制器的原始 `visual-closeout-summary.json` 也保留，不能删除失败证据。

结束复核 policy、新旧 source/build/app 与旧证据；自动步骤返回 0 仍为 `acceptance_status=pending`、`labels_pixel_verdict=PENDING_MAIN_AGENT_PIXEL_REVIEW`。主代理须看实际新标签 PNG。返回码沿用原封装：1 失败/不完整，2 配置拒绝，75 锁屏/未知，显式信号 128+signal。

## 离线与只读验证

```sh
python3 -B /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-label-closeout/test_driver.py
```

样本只在本目录临时 `.offline-fixture-*` 内，全部 UI/进程/defaults 模拟。覆盖旧新身份、同 50 输入唯一源变更、漂移拒绝、manifest 绑定、仅 sec2+cleanup、异常后完整恢复与旧结果 build 保留。实现任务未运行真实 app/UI/API/build/defaults、未读 live prefs。主代理提供策略后另做真实输入只读 preflight，结果见实现 native run；这不构成真实 UI 测试。
