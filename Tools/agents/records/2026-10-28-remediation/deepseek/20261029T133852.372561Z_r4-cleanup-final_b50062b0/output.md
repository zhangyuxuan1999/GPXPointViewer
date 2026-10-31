# 第4轮清理恢复最终报告

## 执行结论

| 项目 | 结果 |
|---|---|
| 唯一 Bash 命令 | 已执行一次（`run_in_background: true`），收到 CLI 正规完成通知，未重试、未轮询 |
| status / exit | `passed` / `0` |
| restored | `true` |
| other_keys_preserved | `true` |
| baseline_byte_hash_restored | `true` |
| integrity_after | `true` |
| write_attempted | `true` |
| acceptance_status | `pending`（如实保留） |

## 核验依据

- 仅 Read 了本 run 的精简 summary：`.../deepseek/20261029T133852.372561Z_r4-cleanup-final_b50062b0/artifacts/cleanup-recovery-summary.json`；未读取其指向的完整 prefs / raw 进程日志。
- summary 作用域自述：`only the exact observed failed-run window key; no stages rerun`。
- 固定失败 run：`deepseek/20261029T132227.123510Z_r4-label-final_9d13dc4c`；`failed_result_sha256` 与 `baseline_sha256` 均由工具在恢复前核对通过，单键写入后完整原始字节 hash 恢复校验通过。
- 恢复收据路径记录于 summary（`artifacts/preferences/restore_20261029T133916_669892Z_608ed7ea.json`），未展开读取其完整内容。

## 未重跑项

- 未构建、未运行 UI、未截图、未重跑 11 组测试或任何已通过阶段。
- 像素结果此前由 root 单独通过，本轮未复查、未评论。
- 原失败 run 与旧 result 保持原样，未修改、未改称成功；本次仅恢复测试后窗口 frame 偏好。

## 记录与约束

- 已先写 `progress.md` 三栏并在完成后更新；未预建 artifacts（artifacts 由工具生成）。
- 未修改源码、helper、manifest、policy、旧 run、期望/数据；写入仅限本 run 的 progress/report。
- 未安装/关闭正式 app，未调用其他 API/agent，未读取密钥/全环境/无关私人文件；无路网请求。
- 模型实际回执与费用：`observed_model: null`、`token_usage: null`、`cost_usd: null`（unknown/null）。