# N05局部新增显示证据

执行按任务完成到sandbox允许的边界。已实际请求finish(provider=succeeded, acceptance=pending)，运行器因共享工作区差异返回1，实际result为provider_status=succeeded / acceptance_status=failed；待root独立核对并发归属。本run没有改产品、运行正式app/回放算法/整套测试/网络，没有重复已有测试。

## 已完成证据
- 真实ContentView.swift片段：全局说明、videoExportSheet、完整PlaybackBarView；真实VideoExport.swift drawRibbon及日期前缀调用。原始片段、源码SHA和行范围见artifacts/source-manifest.json；收尾source-final-check.json证明两个生产源文件SHA与提取时一致。
- 完成独立fixture Swift编译（exit0）与当前真实xcstrings四语编译（exit0）。精确命令/标准输出/错误与退出码分别见fixture-compile.*、catalog-compile.*。fixture方法、stub依赖及尺寸见fixture-method.md，源码DisplayFixture.swift。
- 16张视频丝带PNG（四语 × 1080p/4K × fwdb/GPX）成功：ribbon-{zh-Hans,zh-Hant,en,de}-{fwdb,gpx}-{1920,3840}.png。真实drawRibbon和生产日期前缀原样调用；日期格式与旧yMMMd模板一致。ribbon-metrics.json记录实际CTLine尺寸、字形边界与画框，16/16均在框内，fwdb均有≈，GPX均无≈。这是局部CG渲染，不是整段视频导出。
- 已读取ribbon-de-fwdb-1920.png及ribbon-zh-Hans-gpx-1920.png原PNG：德文≈清楚、日期未越界，GPX无≈。其他PNG待root直接阅读，不重新生成。

## UI缺证与可恢复入口
- 首次zh-Hans UI mode返回SIGABRT（child=-6，外层=250），stdout/stderr空，未生成UI PNG。不能锁定内部故障函数或归为产品缺陷；ui-failure.md保存限制。未作第二次尝试，也未重编。
- 已编译二进制与已编四语catalog保留在artifacts/DisplayFixture.app/。主代理可在具有UI服务的环境执行artifacts/execute-ui.sh（四个独立语言进程），保留原失败并新增ui-root-LANG日志。root随后直接阅读ui-LANG.png。
- 430pt新说明换行与108pt日期框的真实排版尚待该入口生成的局部UI图像验收；不能把CG丝带通过推成UI通过。

请求模型/强度gpt-6.1-sol/ultra；服务端实际模型、effort、token及费用未暴露，unknown/null。未派发任何agent或API。只写本run。

## 运行器终态的并发归属限制
finish stdout/stderr均空，真实exit1。changes.json记录added=`Tests/probes/deepseek-small/run.py`、modified=`Tools/agents/AGENT_LOG.md`并判out_of_scope。两处都未被本agent写入；全部直接写入、局部编译、PNG输出均在本run。共享快照不能自动归因，故保留原失败而不重复finish或篡改result，交root独立verify。完整finish命令/退出码与检查日志分别见artifacts/finish.command.json、finish-diagnostics.*、finish-scope.*。
