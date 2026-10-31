# DeepSeek：机械应用已独立核准的八文件测试迁移

模型DeepSeek V4.1 Flash / max，最多30轮/900秒。用户明确授权仅本项目复测所需文件交DeepSeek处理（本目录deepseek-data-authorization.md）。凭据、密钥、无关文件禁止读取。不再研究/决定期待，不调用其他agent/API。

临时工作区 /private/tmp/gpxpv-segment-integration-o3kf8civ；正式根项目产品暂未写回。独立Sol已用原单段Swift逐源+written-value生成器规则+新组合完整候选/trip集合证明四个多段旧期待需要迁移，Root已审查批准，证据coordinator/synth-truth-review.md。唯一最终来源为native/20261029T002806.674537Z_synth-multisegment-truth_15b1a189/artifacts/final-freeze.json及proposal/，不要用初稿。准确说明见该run artifacts/migration-instructions.md。

范围8文件：Tests/synth/runner/main.swift、check.py、exam.swift；Tests/synth/format-edge/gen.py、expect.json；Tests/synth/scale-mixed/gen.py、expect.json、README.md。原其它110期待不变，exam题/评分/baseline不动，数据不REGEN，产品API不改。root已在临时目录准备对应原始8文件供before快照。

请按顺序做：
1. 写自己run progress（已完成/正在做/下一步），读本任务、批准说明、final-freeze与migration-instructions；不要读取整个输入轨迹或无关历史。
2. 执行唯一允许的精确命令：
   python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/coordinator/apply_synth_migration.py
   脚本已被root核对，只把8份已批准副本复制到临时工作区。它先检查全部before/after/hash和实际产品GapFill版本，Python AST/JSON结构，再逐文件拷贝并保存本run artifacts/synth-migration-receipt.json；不编译，不运行app，不出产品网络，不写正式根项目。若任何检查失败立即报告，不改脚本、不绕过hash、不换来源，不另写脚本。
3. 读取receipt并抽核main的GapID/bySegment/实际邻接证明、保留iEnd，exam仅同步过滤segmentID，四expect值与说明一致。通过Read/Grep即可；不要把静态核对说成执行114/125。
4. 更新progress，最终直接回答完整报告由runner写output：执行命令及退出码、8文件变更、JSON/Python检查、四期待及独立依据、没有执行的正式编译/114/125/UI范围。Root会审实际changes和最终全复测。

四项真值：g13 gap0/trips5；s1 gap0/trips61（含每日边界重置既有30秒停留检查点影响）；s3 raw timegap150/stale0/trips2，手机146正常稀疏步+2本源隧道及Garmin2隧道，绝非150次失锁；s4 gaps[51311,51313]/trips1576保留原浮点容差。机器JSON只增加topology字段，旧iStart/iEnd/scalars保留，实际同段相邻检查严格。
