# 修复后指定构建：DeepSeek 补完第4轮复测

模型 DeepSeek V4.1 Flash / max。本次有界执行，最多220轮、7200秒。用户已明确允许仅本项目复测所需源码、测试脚本、任务书、日志交由DeepSeek处理；授权原文见同目录deepseek-data-authorization.md。凭据、密钥、无关文件和其他项目禁止读取。服务端费用不可得时null，CLI估价不当账单。

这次验证修复后的本地构建。工作目录 /Users/zyx/Documents/GPXPointViewer。唯一执行入口是 `python3 -u Tools/agents/records/2026-10-28-remediation/r4-final-work/driver.py <phase> [argument]`。runner已经设置本轮唯一 `GPXPV_AGENT_RUN_DIR`，不得改成任何旧目录。driver读取同目录真实build-manifest.json，校验指定新app与二进制hash，并设置GPXPV_APP；不要沿用旧任务测/Applications的命令。正式app不能关闭、覆盖或安装。

先读driver的README、build-manifest、必要的driver函数，确认运行环境；随后按下列顺序串行执行，每阶段保存正常输出和进度。driver将精确argv、stdout/stderr、退出码、超时、JSON断言及截图写到本run/artifacts。命令失败也保留原件，不以最后tail成功替代真实退出码。不改driver、产品、测试脚本、期望、基线、数据或本地化；只写本run自己的progress/output/artifacts。不得使用任意shell命令、另起脚本、联网搜索、再派agent或其他API。

1. `prep`：必须校验manifest固定构建、五个版本字符串（包含UTF16）、测试数据、正式进程PID和偏好快照。没有prep不能把cleanup无证据的空PID视作通过。
2. `reg 1` 至 `reg 11`：严格逐个执行，分别plausibility、crosscheck、batch_review、batch_card、route_cache、map_sources、tunnel_fix、fill、review、network、profile。每项既要exit0，也须FAILS为none；某项失败不要修改它或跳过所有独立项。公共OSRM、Valhalla、Overpass请求禁止，只允许现有假引擎。
3. `synth`：从当前源码编译指定runner，114门全部通过，125题离线录音回放。OSRM/Valhalla各121/125；artefact123/125 high、parallel125/125 high、high-and-pass0、requests sent0/replay255/missing0。四道已知未pass题是保留的数据偏差，不改baseline。多段fixture的期待若已由独立真值审核迁移，以当前有记录的测试源为准，不自行迁移。
4. `selftests`：四组共51例（portal8/crosscheck31/tunnel5/plausibility7），每组按实际输出核对。
5. `sec2` → `sec3` → `sec4`：按顺序维持前置状态。双路分歧标签、视口隐藏标签、一键重取缺一路项、OSRM/Valhalla进度合一行，各项严格用driver原断言。双路标签PNG交主代理看像素。
6. `sec5 zh-Hans`、`sec5 en`、`sec5 de`：三种语言各一张真实截图、windows及front证据。窗口960×800以windows为准，PNG尺寸另记。主代理将看固定页脚和英文/德文中段侧栏是否完整。若锁屏/白图明确未验收，不冒称通过。
7. `sec6`：候选100，Valhalla high+reasons+默认不勾选比例≥95%，vMinRisk严格>50，OSRM high=0，counts.high=nHigh。55属于合法high，不写成偏差。不得调整阈值或任务期待。本节只检UI风险；两处实际underfill已由独立生产Store测试验证补满与还原，主代理另交该证据，不冒称driver测试了覆盖。
8. `docs`：按内容核对README实际主app34 Swift、Regions RGN1/29,411,770字节及文档条目、31个run_与suite25脚本；不执行整个run_suite，不把移动后的行号当失败。
9. `cleanup`：中途失败也执行。只关测试副本、恢复测试改动的偏好，保留正式PID。测前正式PID空、测后仍空是通过；测前有正式PID必须仍在。实际偏好差异、测试副本终止和正式app未安装证据都要记录。

可以读取每阶段本run的精简JSON结果来汇报；不要反复读取庞大原始事件或全部轨迹。不要把任何凭据或环境全集写进日志。长期命令由driver自带截止时间；遇到权限错误/超时原样保存，通知主代理，不能绕过授权边界。

每阶段更新progress.md的“已完成/正在做/下一步”，runner自动持久保存可见正常工具调用和结果；不要索取或保存内部思维链。最后output.md列出每个实际phase及真实退出/断言、版本hash、11回归/114门/125考卷/51自测汇总、三语与双路PNG绝对路径、清理/偏好差异、实际网络计数、全部失败或未验收项。最终视觉结论保持PENDING_MAIN_AGENT_PIXEL_REVIEW；只有主代理实际读图后才能验收。API结束成功与任务断言通过分开，不写笼统“可发布”。
