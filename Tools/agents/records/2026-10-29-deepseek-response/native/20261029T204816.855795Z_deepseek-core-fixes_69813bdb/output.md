# N20/N26 实现与 N06/N07/N19/N22/N24/N25/N28/N30 定向审查

本任务已完成：仅修改 `GPXPointViewer/FogArchive.swift`、`GPXPointViewer/GPXWriter.swift`，新增 `Tests/probes/deepseek-core/{main.swift,run.py,README.md}`。没有删除文件。新目标实际编译/运行 **34/34，exit 0**。独立验收留给主代理，当前 acceptance pending。

请求模型 `gpt-6.1-sol` / `ultra`；工具未暴露服务端模型、effort、token与实际费用回执，均为 unknown/null。没有自行再派发/API模型调用。

## 已修复

### N-20：文件名区块号溢出

`FogArchive.swift:284–291` 在每次乘加前按最大合法 block `512*512-1` 校验十进制前缀。只有合法区块编号才参与解压；没有用 wrapping 掩盖溢出，也没有按总长度拒绝合法零填充。合法block0、最大block262143、100位前导零、2^64溢出号、30位9、超世界号及混入无效文件的目录均在新探针覆盖，解析出的世界格键与独立格式真值一致。

### N-26：非法导出选择

`GPXWriter.swift:14–25,48–51` 新增 `GPXWriteError.invalidSelection`，发现负数/越界索引时通过原有 throws 接口返回可处理错误，在任何目标写入前拒绝整个请求。两个产品调用点 `TrackStore.swift:1352`、`:4333` 已有 catch 并展示 LocalizedError，无需改签名/调用链，也未用会导致崩溃的 precondition。

探针覆盖负值、Int32.min/max、上界、合法点夹非法点、多窗口中后段非法；均捕获指定错误、现有目标字节保留，新目标不创建。空选择仍返回noPoints；合法多段按真实来源拆分、保留调用窗口与点序、合成身份正确，单段20,001点并行分块无丢点/乱端点。

新增本地化键 `导出范围包含无效的点索引。`，comment `Error message when exporting GPX: the selected point indices are invalid`。已经发给root纳入翻译/组装；本任务无本地化文件写权限，不能将这一步冒称完成。

## 其余逐条结论

| 条目 | 结论与理由 | 当前源码 / 证据 |
|---|---|---|
| N-06 | 不需改。复用现有静态审查，当前全还原直接返回精确baseline；部分还原依赖/歧义/缺次数显式拒绝。调用点捕获完整history和baseline。未声称三个特定链都有新运行用例。 | ChangeLog.swift:136；TrackStore.swift:3078；artifacts/04-inherited-evidence.json、06-inherited-detail.json |
| N-07 | 不需改。复用29个入口静态审计，并核对当前publicationClock/invalidate/owns/publishData关键边界；没有遗漏证据。没有逐入口制造竞态或重跑workflow。 | TrackStore.swift:133–162；ChangeLog.swift:292；DeepSeek/2026-10-29-deep-review.md:208 |
| N-19 | 继承已修复。Colormaps、GeoCompute、core main三个当前SHA256与原报告精确匹配；原112核心/24预览exit0日志已持久复制。真实四模式、旧实现SIGTRAP仍属原报告证据，本次未重跑。 | Colormaps.swift:30,59；GeoCompute.swift:260；artifacts/input-hashes.json、inherited-n19-receipt.json、inherited-n19/ |
| N-22 | 性能优化保留，不盲改。多段串行与复制属实，但无A/B基准、慢样本或性能目标违约；当前真段输出正确。贸然并行会扩大排序/段界/峰值内存验证范围。未来应先测大段/多小段分布再决定按点块并行。 | GPXWriter.swift:59–70；原deep-review明确性能建议无A/B；新34项含实际XML分段检查 |
| N-24 | 性能优化保留，不盲改。逻辑申请8,470,528字节零缓冲属实，物理页提交/实际清零带宽未测，不能仅凭容量宣称每块写满8.4MB或上千块数GB无效写。倍增/stream会增加截断与重试边界，应有规模耗时/RSS基准后决定。 | FogArchive.swift:296–308；DeepSeek/2026-10-29-deep-review.md:160 |
| N-25 | 确认需要改，精确方案已给root派发。170/171现语义颠倒，且442第二分支死码。官方源码170/442→NoRoute、171→NoSegment；172保持含原码/文本fallback，勿猜成NoSegment。本人不写RoadNetwork。 | RoadNetwork.swift:542；artifacts/valhalla-evidence.md、valhalla-web-tools.json |
| N-28 | 当前正常生产链不满足“节点无坐标”前提：coord在入图/虚拟接入前赋值且不删除。建议防御性guard同时要求path.count==ids.count及>=2，否则noRailPath，避免未来compactMap丢中间点后path/ids/segTunnel错位。方案已给root，本人未改。 | RoadNetwork.swift:1273–1393；artifacts/03-targeted-source.json、valhalla-evidence.md |
| N-30 | 继承已补。当前新增11条确实走解析→真实TrackData→四模式与normalize/LUT边界，测试hash匹配既有112结果。不必机械放进只测解析/检测的synth。其他边界可在后续同类改动时按风险扩充，非当前已复现缺陷。 | Tests/segments/core/main.swift:166–193；原N19修复记录与inherited-n19/test.stdout |

N25资料来自[官方错误实现](https://raw.githubusercontent.com/valhalla/valhalla/master/src/exceptions.cc) 与[官方API表](https://valhalla.github.io/valhalla/api/route/api-reference/#internal-error-codes-and-conditions)，2026-10-29读取；前者含172，旧API表未列172。

## 本次验证与证据边界

执行前原因/原证据/范围已写 `artifacts/verification-plan.md`：N20/N26修复影响及零填充、溢出污染目录、失败不改目标的具体证据缺失。实际只执行一个新目标，没有为“独立确认”重跑已通过测试。

第一次 `artifacts/probe-post` 在编译阶段exit1：本机macOS SDK没有独立FoundationXML模块，尚未执行产品测试；完整失败保留。只将新测试的import改为canImport条件，未修改产品，执行前另记 `verification-plan-r2.md`。同一目标新目录 `artifacts/probe-post-r2` 的swiftc与运行都exit0，**34通过/0失败**，仅有GPXParser已有unused-buffer结果警告。`git diff --check` exit0。

实际命令：

```
python3 Tests/probes/deepseek-core/run.py Tools/agents/records/2026-10-29-deepseek-response/native/20261029T204816.855795Z_deepseek-core-fixes_69813bdb/artifacts/probe-post-r2
```

`probe-post-r2/{source-hashes.json,build-command.json,build-result.json,build.stdout,build.stderr,test-command.json,test-result.json,test.stdout,test.stderr,checks.json}` 保存全部源哈希、实际参数、stdout/stderr、退出码；测试夹具/实际导出也在同目录。JSON逐条结论见 `assessment.json`；改动前后快照和新增/修改/删除清单由runner保存。

最终产品SHA256：

```
94bc3490c3a7a6ac5d600ac70cba6bc5e4e991bc38dda3bcb8804cdd020dfb8b  FogArchive.swift
4fa2ff3ffc4fc5d902e5a3c1814175c7f5cb469d3f4a0e5ecc0993f059e9c50e  GPXWriter.swift
```

历史112/24结果只用于N19/N30的证据继承；本任务已改GPXWriter，不能将112/24描述为当前全部源码新跑通过。没有运行旧整套、UI、全工程build、app、公共路网、安装、提交或push。root可据已有34项日志与源hash验收；仅若出现具体矛盾/缺证或后续修复影响，才定向再测。
