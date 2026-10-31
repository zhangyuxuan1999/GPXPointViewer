# DeepSeek 有界实现：已审定的小修与文档

用户要核对 DeepSeek/N-01..31，需要修的修、不修的解释；本任务只做下面明确步骤。模型 deepseek-flash / max，凭据不得读取/记录，不准调用其它模型、工具代理或API；不要访问无关私人文件。不准安装/启动/关闭app，不跑UI/整套回归/完整构建，不联网路网，不改期望值求通过、不git提交/push/reset，不清理历史产物。遵守AGENTS.md证据复用，已通过检查不重跑。当前并发Sol仅改FogArchive/GPXWriter、MetalPointRenderer/ui.py/run_suite与build helpers，**不得碰这些文件**。完整正常输出和中间结果存本run artifacts，维护progress；不要内部思维链。只做已列步骤，遇不同事实报告，不扩张范围。长命令run_in_background后等待完成通知，不sleep/TaskOutput轮询。

## 输入与获准范围
可读 AGENTS.md、README.md、Tests/README.md、DeepSeek/issues.md（历史结论）、下列相关产品源码、docs、Tests/l10n。Astra/Sol已保存决策：
- Tools/agents/records/2026-10-29-deepseek-response/coordinator/architecture-decision.md
- Tools/agents/records/2026-10-29-deepseek-response/native/20261029T204816.855795Z_deepseek-core-fixes_69813bdb/output.md
- Tools/agents/records/2026-10-29-deepseek-response/native/20261029T204817.033883Z_deepseek-harness-renderer_f132cc89/artifacts/documentation-handoff.md
允许写且仅限：GPXPointViewer/RoadNetwork.swift、GPXPointViewer/UITestHook.swift、GPXPointViewer/ContentView.swift、GPXPointViewer/VideoExport.swift、GPXQuickLook/PreviewViewController.swift（仅注释）、README.md、Tests/README.md、docs/cross-check-design.md、docs/fill-plausibility-design.md、Tests/l10n/translations/chunk_30.json（新增）、.gitignore（仅新增Builds/）、Tests/probes/deepseek-small/（新目标）、本run progress/artifacts。不写DeepSeek目录（root最终统一回复）；不直接改xcstrings，root统一按编译器键表组装。

## 精确修改
1. N25：RoadNetwork.fetchValhalla错误映射当前混淆170/171且重复442。仅改该表达式：ec==442或170 -> NoRoute；171 -> NoSegment；其它保留 `Valhalla \(ec) \(err.prefix(60))`。172不得猜成其它。外部真值由Sol核对官方源码 https://raw.githubusercontent.com/valhalla/valhalla/master/src/exceptions.cc （170 OSRM_NO_ROUTE，171 OSRM_NO_SEGMENT，172 OSRM_BREAKAGE_EXCEEDED）及 https://valhalla.github.io/valhalla/api/route/api-reference/#internal-error-codes-and-conditions 。不改请求/重试/缓存/轨迹算法。
2. N28：在RailPath中 `let path = ids.compactMap { coord[$0] }` 后、任何1..<path.count或first!前加 `guard path.count == ids.count, path.count >= 2 else { throw RouteError.noRailPath }`。当前graph构造确保coords存在，故空路径只是防御加固，不冒称已复现产品崩溃。禁止随意补坐标或丢路径继续。
3. N31：UITestHook重复 `case "screens"`，保留靠前输出 `frame=… visible=…` 的分支，仅删后面enumerated那分支；不改place命令和输出协议。
4. N05：fwdb日期实际来自文件mtime，并非逐格/真实探索时间。只改文案，不改时间算法。
   - 统一新键：`归档回放日期取自区块文件修改时间，不代表实际探索时间。`，comment解释fwdb无逐格日期。
   - PlaybackBarView：fwdb模式日期前加独立 Text(verbatim: "≈")，可用小间距HStack包住符号+原有日期Text，保留原有日期frame(width:108)；help使用新键。普通轨迹显示保持原样。来源检测使用store.fwdbActive，勿给GPX加近似符号。
   - ContentView的videoExportSheet：只有fwdbMode时在已有描述后显示上述键caption，fixedSize(horizontal:false,vertical:true)，现430宽保持，确保多行德语可换行。
   - 时光机入口help：fwdb用上述新键；GPX保留已有完整轨迹说明键（别删所有语言的旧翻译）。
   - VideoExport：传给drawRibbon的date仅cfg.archive != nil时加通用 `≈ ` 前缀；不改真实GPX视频日期。现CTLine实际宽度右对齐，不加长语句到视频丝带。
5. chunk_30.json 只新增两条 Localizable翻译（格式看chunk29），不可覆盖旧chunk：
   a `导出范围包含无效的点索引。` comment Error message when exporting GPX: the selected point indices are invalid。en: The export selection contains invalid point indices. de: Die Exportauswahl enthält ungültige Punktindizes. zh-Hant: 匯出範圍包含無效的點索引。
   b 上述归档说明；en: Archive playback dates come from block file modification times, not the actual exploration dates. de: Das Datum der Archivwiedergabe stammt aus der Änderungszeit der Blockdateien und entspricht nicht dem tatsächlichen Erkundungsdatum. zh-Hant: 存檔回放日期取自區塊檔案修改時間，不代表實際探索時間。
6. 文档精确修正：
   - PreviewViewController顶部>48MB改为现阈值>32MB，先核对常数；不动逻辑。
   - cross-check-design旧“未做（记录）”三条标历史且指向2026-10-28已实现，不抹历史，不承诺最远处（实际屏幕弧长中点）。
   - fill-plausibility-design表中“本期恒nil/本期不扣分”改符合§7：OSRM解析intersections.classes估tunnelShare，nil未知，无classes为0；达到占比/偏移条件免锚点扣分，具体见§7，公共端点classes在线表现仍未验证。不要改算法/现有测试期望。
   - README多窗口描述改“多个窗口共享同一TrackStore/数据与编辑会话；不是独立轨迹会话”，不要声称全UI状态同步，也不要实现多文档架构。
   - README导出递增说明：基于当前轨迹名称的_GPVexported后缀；重新导入已导出文件再导出才递增，同一轨迹重复导出默认名不自动按目标目录探测重名，覆盖由保存面板确认。先核对GPXWriter名称函数再写。
   - README性能表/首段/FAQ：数值只能作历史观察，不保证所有硬件/数据下满帧或固定秒数。增加统一“性能口径”：历史M4、优化构建观察，旧记录未完整锁定系统/编译器/样本hash/重复轮数，不能当当前版本可复现验收；后续基准应锁定以上信息、点数/分段/缺失字段、p50/p95/RSS/自动抽稀状态。不要编造跑过benchmark，修改“500万依然流畅”“全速/交互满帧”这类无条件措辞为有条件历史观察。
   - README快速构建与TestsREADME按Sol documentation-handoff准确加入新的Builds构建/manifest/GPXPV_APP，删除自动回退旧DerivedData的现行指导。根.gitignore加Builds/一行。TestsREADME区分25个suite+地区独立脚本；引用唯一日志/suite.json和非零规则；不在本任务运行它们。
   - TestsREADME补临时产物策略：本次受追溯引用的旧tmp目录不删；未来仅清理本任务所有、进程结束、原始证据与构建已完整归档并验证、确认无路径引用依赖的临时产物；禁止gpxpv-*全局通配删除；失败证据必须保留。3.4GB历史值不是实时测量。
   - README fwdb回放补上近似日期的明确解释，GPX真实记录时刻与fwdb分开。

## 定向验证和交付
先写artifacts/retest-reason.md：本次路由映射/守卫/重复case/展示字符串与文档修复，原发现链接；只验证这些范围，不重复N19或Sol34项。
允许执行python3或xcrun swiftc局部离线探针，不执行xcodebuild/open/defaults/UI脚本/网络。新Tests/probes/deepseek-small可直接抽取产品错误映射/guard并编译小Swift探针，必须实际执行生产表达式且测试期望来自上述官方合同，覆盖170/171/442/172/未知及空/单/缺中间坐标/正常链（正常输出不变）。静态确认screens只剩一分支、两新键三语齐全、仅fwdb加近似，保存命令/完整stdout/stderr/退出码/hash。无需为文档改动写镜像测试，不跑旧测试。
UI与视频的实际视觉/最终工程编译留root统一；未做如实说明。结果说明修改文件、逐N条目、测试与没测范围、任何疑问。不把“请求模型”当服务端证明；runner会记录actual字段未知/CLI回执。遇失败保存原失败后修目标，不覆盖证据。
