# 单次 Xcode 协调读取绕过开关已实现

仅修改 `Tools/build_release.py`，新增显式 `--no-icloud-coordination`。启用时在 xcodebuild argv 增加 `-SynchronizeWithICloud=NO`；默认行为保持。`build-command.json` 总是记录布尔值 `requested_no_icloud_coordination`；help 明确说明此选项仅影响当前 xcodebuild 进程，不改全局 defaults。

主代理可执行一次新的唯一构建：

```sh
python3 Tools/build_release.py --arch arm64 --no-sign --no-icloud-coordination --timeout 1200
```

## 验证与证据

- 新增开关有/无两支的 mock 精确核对完整 xcodebuild argv、metadata、timeout、mock 构建失败码传递及 help；`artifacts/mock-r2-command.json` exit 0，详细结果 `artifacts/mock-results-r2.json`。
- mock 的 `run_owned` 固定返回 37，验证 builder 原样返回失败，未创建成功归档。`real_xcodebuild_calls=0`、`mock_run_owned_calls=2`；真实构建从未在本任务启动。
- 第一条 mock 在 21:27:46 执行，但源码修改的实际写入完成时间为 21:27:50；因本代理未等待前一命令完成而读到旧版，无新 metadata 导致 KeyError。首次失败原样保留 `artifacts/mock-command.json`、`artifacts/mock/default/`；定向补跑依据与范围见 `artifacts/mock-r2-reason.md`，没有覆盖旧失败。补跑使用写入后源码且通过，没有为通过修改期望值。
- 前后完整脚本快照、hash、允许修改清单见 `artifacts/build_release.before.py`、`artifacts/build_release.after.py`、`artifacts/source-change.json`；便于审查的差异见 `artifacts/build_release.patch`。未新增/删除仓库文件，唯一修改为 `Tools/build_release.py`。

最终脚本 SHA-256：`f99bbf1c941d055367e4de2186e5224735e2803cc1749d88e98bcfe0e8a1f264`。

## 范围与结论限制

本任务承接前轮 `20261029T211057.193397Z_release-build-diagnosis_47e230d2` 的原始采样/本机手册/反汇编证据：旧构建卡在工程的 NSFileCoordinator 协调读取，尚未进入编译。该旧构建已由 root owned helper 中断；exit130/child-15/cleanup_complete=true 由 root 告知，本任务没有重新执行或冒充本次采集。

没有改产品源码/工程/README/全局 Xcode 配置/用户偏好，没有联网/API/安装/启动/关闭 app/kill/真实 build；没有重跑旧 harness。此次 mock 只证明新增参数与记录接口正确，真实 Release 构建及归档结论由 root 后续取得。请求模型 GPT-6.1 Sol / ultra；服务端模型回执、token、实际费用未知/null。独立验收 pending。
