# 四个多段合成用例的独立真值核定

结论：四项失败属于明确 hard source segment 契约的测试迁移，本轮未发现新的产品算法误用。不能把 s3 的新增148项描述成148个新失锁：它们是原单段算法在 phone 源上本来就会检测出的146个普通后台稀疏采样步与2个本设备隧道缺口。产品/正式期待/生成数据均未修改；最终迁移提案留本run，由主代理验收与实施。

## 证据独立性与版本

原 root 未整合 P4 的 GapFill.swift 原单段 kernel、GPXParser 和 GeoCompute 已冻结，逐 XML source 段直接运行。kernel 是原文件起始到 breakOptions 扩展结尾的原文；TrackData 仅用四列引用包装，速度调用原 GeoCompute，未重写 detect/trips。BatchKind/Classifier 的未执行UI属性有最小stub，不参与本任务计数。

第二个独立 oracle 由标准 XML 解析 written lat/lon/time，调用原生成器 timegap_rule（原±0.01m/±0.01kmh）与已有 profile_port；它不调用新产品。原文档列出的 _work/trips_sim.py 在当前目录确实缺失，失败路径已记录，不冒称执行过。

第三条为完整新生产34 Swift编译的组合TrackTopology实际输出。逐候选规范化为(source ordinal,local A,local B,kind)，行程为(source ordinal,local start,local exclusive end)，旧逐源和新组合的完整集合SHA256四份全相等，而不只比计数。跨源候选均0。当前共享全部34源与本run初始冻结哈希一致，GapFill为34a542ea9a55d14a87d088be36e4ccfc20ba6fb71c48ae77a1184a3243f428f8。

## 核定结果

| 输入 | 独立段内timeGap真值 | 段内原kernel trips | 旧flat控制 | 最小迁移 |
| --- | --- | --- | --- | --- |
| g13，5段 | 0 | 5 | gap1、trips4 | gaps[0,0]、trips[5,5] |
| s1，12日段 | 0 | 61 | gap0、trips48 | trips[61,61]，其它数值不动 |
| s3，2源 | Garmin2 + phone148 =150，全timeGap，stale0 | 2 | gap2、trips1 | gaps/timegap[150,150]、stale[0,0]、trips[2,2] |
| s4，1576源 | 精确51312；原容差规则[51311,51313] | 1576 | gap51364、trips1576 | 只迁移gaps范围，保留容差 |

每源完整统计见xml-truth.json、old-truth.json；四份完整集合相等证据见comparison.json。所有旧、新probe编译/运行最终exit0。

### g13

五段各自连续（901/601/601/601/601点），各有1个trip。旧唯一gap是day1两个明确trkseg之间120s、约1.5km、约45km/h的跨源连边；它在原written-value规则可构成timeGap，但在hard段模型没有合法相邻边。30min同地点、隔夜、2h也不连接来源；trip必须逐源合计5，不能维持旧flat4。

### s1

每午夜已由生成器写入新trk/trkseg，12段分别86400点，末段49600点。原单段Swift逐日结果为5,5,5,6,5,5,5,5,5,6,5,4，合61。不能只按47个long_stop+1，也不能简单48+11：新增11个hard边界之外还有原kernel既有检查点起点效应2项。

插桩原Swift只加日志不改分支，证实6月4日单日扫描中心14:51:11、flat14:51:25相差14s，单日第一次离150m为18:52:01（150.2974m），flat同一停留一直扫描到次晨07:26:31（150.7576m）；6月10日相应扫描中心相差3s，单日21:44:27离150m（150.1552m），flat到次晨07:35:29（151.0331m）。源边界禁止借用次日，且重置原30s检查点，导致这两日各6个kernel trip。没有去重删除发生；早期“去重效应”只是待核假设，已被日志否定。这些数字是原单日算法输出，不宣称61次物理旅程，也未扩改原停留启发式。

### s3：新增148项的确切性质

生成器先写Garmin6405点、phone1520点为两个明确trk，再把两源合并计算旧期望2。Garmin每秒真实位置配1–4s timestamp bunching；phone后台每20–30s一Fix。原profile_port：Garmin medianDt2/q90Dt4、medianStep31.4/q90Step32.5 => deviceLogger；phone medianDt2/q90Dt20、medianStep18.1/q90Step284 => phone。新产品没有误用组合profile，旧单源kernel结果同样2+148。

phone148的完整dt分布为20:16、21:10、22:19、23:11、24:16、25:14、26:13、27:15、28:10、29:13、30:9、70:1、113:1。前146项每项均满足原timeGap距离/速度条件，且每项原kernel source-local B=A+1；全部被产品标签判为sparse。它们是合法的原raw检测候选，不是GPS失锁或应删除的假点。旧组合Garmin密集点把这些phone原始邻接腿拆碎遮蔽；保留源身份后恢复它们。

两隧道每设备各有一腿：Garmin54s/1715.762m与95s/3012.391m；phone70s/2178.515m与113s/3541.609m。它们是同两次物理事件的不同源观察，不应跨源去重。LocalSampling是标签启发式：Garmin tau2均lol；phone tau25，70<3×25标sparse，113>=75标lol。最终标签147 phone sparse+1 phone lol，加Garmin2 lol；不是150次失锁，也不是148项staleClock误报。

### s4：不能去掉浮点容差

原written-value规则只对同源相邻步求和，51311 sure、51313 maybe、精确条件51312。两个内部门槛例：source ordinal256 local41→42，29s、149.991980m；source1049 local26→27，30s、150.004646m。因此保留[51311,51313]，不把实际51312硬写成精确范围。

旧flat多52项全为跨session的2401–3548s连边。其中51为sure、52为maybe；临界跨段一腿2708s、11285.472m、15.002843km/h解释旧范围[51362,51365]为何不能直接上下界都减52。源session间至少40min，段内trip各1，所以1576不变。

## 可实施提案与验收

artifacts/synth-contract-migration.patch及proposal/包含8文件最终稿。main/check保留所有原scalar字段，新增实际拓扑证明；timeGap必须同源、path相邻且实际nextInSegment==iB。分源不重叠同时保留全局时间排序；jitter inner依path。trip_list.iEnd保留为全局包络exclusive end，真成员依segment/pathStart/pathEnd。顶层profile仍汇总组合track，检测使用现有bySegment；没有为测试新增产品API。exam仅同步keep过滤段列一行。

原114个期待静态审计只有这4条改变，另外110条逐字段相等；125题/评分/baseline未动。cover/free是原整文件物理时间窗口：s3同两隧道且无free，s4会话不交叠，g13/s1无窗口，故旧二维窗口无需改为段指定契约。没有拿global包络作编辑成员集。

最终提案按最新真实14产品依赖+main/exam编译exit0，四目标真实runner exit0，check_expect和所有invariants均通过。另5反例（跳过同源点、跨源endpoint、伪造next、缺next、缺path）均拒绝；旧单段payload仍强制iB=iA+1。旧浮点0.051显示容差不变。

未来REGEN兼容已由gen修改覆盖：g13逐source view聚合；s1逐午夜真实分段调用原trip纯Python转录；s3分别设备求原规则再求和；s4逐session求原规则并保留±0.01容差。本run没有REGEN，但在四份原现有输入上独立执行这些纯函数，所有source trip计数与旧Swift逐源一致，四组range/count一致，见future-generator-helper-validation.json。

失败证据原样保留：读取不存在simulator/一次rg路径失败、诊断Python语法错误、初次完整CLI默认macOS26 target触发既有截图API可用性错误（修为项目macOS14目标）、第一次提案多传不存在shiftFrozenChains profiles参数。修后未改产品API；初稿proposal-attempt-01与所有stderr/退出码保留。本轮不跑另110已通过文件、不启动app、无网络/API/record/子代理。完成finish acceptance pending后交主代理独立核验、正式应用与完整回归。

最终8文件冻结表为 artifacts/final-freeze.json；patch SHA256 74bae78c3dc6f8651c46cf2da9ad988c38c8bb16070e66c8772f877d0157a180。正式根目录 git apply --check 实际exit0，未应用。
