# 继续第4轮剩余复测，11组已过UI禁止重跑
请求DeepSeek V4.1 Flash / max。用户已明确允许仅本项目复测所需文件，且最新确认按原模型分工继续。工作区/Users/zyx/Documents/GPXPointViewer。每个正常工具调用/结果自动留档，实际费用未知为null。

原run deepseek/20261029T011600.159549Z_r4-final_fa1fd007 已因等待策略偏差由主代理安全中断，11/11 UI真实通过且已独立接受，synth到79/114的部分输出不算通过。这里创建全新上下文恢复run，不能复用原session或改原run。原失败永久保留。

已验收恢复入口：/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-final-recovery/driver.py
可先Read其README和coordinator/r4-final-partial-review.md。不要读整个原transcript或全部数据。

【执行顺序】
1 用Write在本run progress.md说明已完成/正在做/下一步；开始前绝对不要写任何artifacts文件（helper要求空artifacts，并会负责创建全部产物）。
2 只启动一次以下精确Bash命令，run_in_background:true：
`python3 -u /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-28-remediation/r4-final-recovery/driver.py run`
保存返回task_id/output_file到progress.md（不要写artifacts）。这是唯一允许执行的命令，不得另起python/shell或额外工具程序。
3 等CLI发送该task的完成/失败通知，再Read本run/artifacts/remaining-summary.json和必要phase JSON。禁止通过重复Read、ls/stat/date、sleep、短sleep拼接、driver waitsecs或改名等待器轮询；上次此行为已被Block，不得再做。TaskOutput在本地2.1.310已移除，不调用。通知不可用时明确告知宿主未完成，不臆造结果。通知完成前不能启动依赖任务/重复命令、不能宣布测试完成。
4 完成后更新progress.md，最终直接给出完整Markdown报告，由runner保存output.md。报告区分11个继承UI与本run新执行的11个phase，写出每项rc/fails/是否未验收和原证据路径。若helper非零或配置拒绝，原样报告并停止，不改脚本/期待/预算规避。

helper已经逐hash核验固定新构建exe 445940ea23807364b0b4c09ea99e73077ed0d5f6253da20b3653988c114b22cb、原driver/manifest/原结果/50源码输入，继承原prep偏好与正式PID，不重建基线。它会串行完整运行synth(114+125)、selftests51、sec2/3/4、sec5 zh-Hans/en/de、sec6严格风险、docs及finally cleanup。无需你手动拆阶段，禁止运行reg1..11，禁止再启动第二客户端。

验收标准沿用原任务不变：114/114；125考卷OSRM和Valhalla各121/125、artefact123/125 high、parallel125/125 high、high-and-pass0、requests sent0/replay255/missing0；自测8+31+5+7=51；sec6候选100、Valhalla至少95% high+原因+默认不勾选、vMinRisk严格>50、OSRM high0、counts一致；源冻结/真实结果/偏好清理不能省略。四个已知考卷未pass为保持的基线，不调分数或改baseline。

三语PNG、双路标签PNG、窗口尺寸和front证据都要给出绝对路径。最终视觉结论保持PENDING_MAIN_AGENT_PIXEL_REVIEW，必须由主代理真实看图。API正常结束和任务断言通过分别记录，不笼统称可发布。

禁止读凭据/环境全集/其他项目；禁止写产品、Tests、两份driver、其他run、工具、期待、数据或本地化；不得安装覆盖/Applications、关闭正式app、访问公共OSRM/Valhalla/Overpass、再派agent/API或联网搜索。仅允许写本run progress/output和helper自己的artifacts。历史失败/中断/副作用不能覆盖。
