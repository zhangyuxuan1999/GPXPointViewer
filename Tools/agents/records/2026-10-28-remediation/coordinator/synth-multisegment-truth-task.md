# 四个旧合成期望的独立分段真值核定

模型GPT-6.1 Sol / ultra。用户要求问题全修，旧单段行为不能回归；P4的明确hard segment语义已由Astra决定，但不能直接拿新实现输出改期望。本任务独立调研/审查，先给可证伪真值和具体测试迁移建议，不改产品、不改正式期望/生成器。

实际旧114门在新P4源上110过4失败，输入均显式多段：g13_multi_trk_seg.gpx=5段、s1_device_1M_11d.gpx=12段、s3_merged_garmin_phone.gpx=2段、s4_backup_3y_30s.gpx=1576段。B只读控制见native/20261029T002155.836673Z_segment-workflow-recovery_fb92c3ca/artifacts/legacy-gate-audit/audit.stdout.txt（如未定稿先读该run progress/目录）。其反事实仅抹segmentID保留其它四列位级一致：g13分段gap0/trips5，flat gap1跨段/trips4；s1分段61/flat48 trips；s3分段gap150（148非global相邻）/trips2，flatgap2/trips1；s4分段51312，flat51364，flat新增52跨段gap。不要只复述这些计数，必须独立解释原因。

源码：root Tests/synth/format-edge/gen.py、expect.json，scale-mixed/gen.py、expect.json、README.md、trips_sim.py和现有validate代码；真实生成输入仍在root Tests/synth子目录。原root产品是修前基线，新生产源shared /private/tmp/gpxpv-segment-integration-o3kf8civ，9业务源已暂冻且三目标Release通过。B最终真实业务202/202，125考卷经archive exam补漏滤segmentID一行后基线121/125、123/125、125/125保持，51自测通过，实际请求0。正式main/exam迁移将由DeepSeek做，现未修改。

请独立核定：
1. 逐源段用原单段算法/已有独立模拟器或生成器真值计算，再与组合新实现比较；说明哪些旧trip/gap来自跨段连接，哪些应在各段内存在。不得把新实现自身计数当唯一oracle。
2. 尤其s3新150不是简单2→2的边界变化：细看生成器的Garmin timestamp bunching+phone两条重叠路线，核对所有多出来的候选种类、profile与原因。判断是被另一条轨迹遮蔽的源段内异常，还是新的profile/算法误用造成真实误报；若发现真实产品缺陷立即给root/B复现，不修改期待掩盖。
3. 旧validator的timeGap必须global indexB=indexA+1是否需替换为真实段内相邻；列出准确helper/字段需求，不放宽为任意不相邻。其他单段invariants和114/125期望保持。
4. 给明确、可审查的expect.json与生成器/README/validator最小提案（保存patch在本run artifacts，不应用），每项新数字对应独立证据；保留原浮点容差必要性，不无据收紧/放宽。不得重新生成全部数据或改baseline。

你只写唯一run的日志/冻结副本/探针/报告/patch，可本地编译和跑四个目标输入的只读CLI，不跑全部已通过110、不启动app、无网络/API/record/新agent。大数据只提取必要统计，不输出整个GPX。记录source/hash/argv/stdout/stderr/退出和所有失败，阶段progress/event，完成finish acceptance pending。最终报告要明确产品缺陷与测试契约迁移，不以“分段合理”一句话放行。
