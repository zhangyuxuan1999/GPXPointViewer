# 第4轮最后四张有效截图与说明元数据收尾

模型DeepSeek V4.1 Flash / max。用户明确授权仅本项目复测必要文件；刚确认Mac已解锁。工作目录/Users/zyx/Documents/GPXPointViewer。原final的11UI通过、remaining的全部11新phase通过，本轮不重跑11UI、synth、51自测、125考卷、sec3/4/6/docs。用已独立验证的专用helper重建标签和三语场景，只补四图，最后恢复测试偏好。固定exe 445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb，不能重建/安装/改产品。

1. 先用Write更新自己progress.md三栏。不要写artifacts，helper要求空目录。
2. 只执行一次以下完整命令，用Bash run_in_background:true：
python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-visual-closeout/driver.py run
3. 仅通过CLI正规完成通知等待。收到通知前不读取产物、不sleep/短sleep/waitsecs/重复Read/ls/stat/date/Monitor轮询，不绕过Block，不启动依赖任务；可正常报告等待但不能报告完成。CLI会按正规通知恢复。
4. 通知后Read自己artifacts/visual-closeout-summary.json，以及必要的artifacts/results/visual_*.json；完整pref备份、defaults导出、日志中的其他偏好值只留本地，禁止读取或上传。summary及精简restore receipt已移除其他偏好值，可读取。不要运行其他shell或Python来探测，失败不得自行改helper/重试同run。
5. 前一步无论成功或明确失败，只要命令已终结，执行一次独立的描述元数据应用（无UI依赖）：
python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/coordinator/apply_fixture_labels.py
这个脚本按事先核准的hash只改Tests/synth/format-edge/{gen.py,expect.json}与scale-mixed/{gen.py,expect.json}中四desc，添加日期/调整理由。程序/数值/数据/baseline不改。应用前先读coordinator/fixture-label-proposal/manifest.json；应用后读自己artifacts/fixture-labels/receipt.json。失败只报告，不自行绕过hash约束。
6. 更新自己progress.md，最终完整报告：唯一命令/阶段退出、未执行/失败/截图路径、窗体尺寸/语言/front、偏好恢复receipt且其他键保持、源码完整性、描述元数据结果。像素始终PENDING_MAIN_AGENT_PIXEL_REVIEW，图片存在或rc0不等于视觉通过。费用和服务端未回传身份保持unknown/null。

允许写自己run/progress与artifacts及上述四fixture说明文件，仅通过固定脚本；不能改工具、driver、原run、期待数值/测试数据/产品/文档/本地化。公共OSRM/Valhalla/Overpass请求0，只有指定测试副本，不启动额外agent。所有原失败记录保留。正式app不得关闭，helper若发现其他实例或偏好漂移会拒绝写。屏幕再锁定返回75，报告blocked，不尝试解锁。
