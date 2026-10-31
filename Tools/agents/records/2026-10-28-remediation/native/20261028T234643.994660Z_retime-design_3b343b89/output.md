# StaleRetime 连续出口尾链修复：Astra 设计决策

**结论：采用Sol的7行连续出口尾链提案，移植到P4的同段采样view；不修改FillPlausibility，不放宽原`vMinRisk > 50`标准，不引入多区间补点。** 最终集成仍须执行下面列出的生产边界测试；本设计任务完成，独立验收pending。

## 为什么这是产品缺陷的最小修复

已核对生产`GapFill.swift:1506–1511`的语义及`:1533–1572`实现：StaleRetime把可保留点改时后加入Job，但只对A→最早保留点插值；保留点彼此及末保留点→B之间不插值。现有投影顺序和15–350km/h条件只能证明改时沿路合理，不能证明这些真实观察点已连续覆盖出口一段。

Sol实际Swift链和`coverage-comparison.json`给出两条确定反例：

| 候选 | 原计划 | 原落地残余gap | 提案计划 | 提案重检 |
|---|---|---|---|---|
| tA1792256646，第97项，Valhalla | 2合成+7改时 | 109秒、4195.402666m | 112合成+5改时，risk85 | 无残余候选 |
| tA1792244850，第84项，OSRM | 13合成+4改时 | 152秒、6866.020797m | 169合成+3改时，risk10 | 无残余候选 |

这两项的risk0原本正确描述“不完整实际落地几何”离raw很近，问题在覆盖；扩大评分或放宽测试min都会掩盖缺陷。修复后真实完整几何进入原评分：第97项自然升85，第84项仍low=10。其他98项分数与四项55保持原样，这是应保留的回归要求，不是调分目标。

## 采用的精确代码位置与不变量

保留既有顺序：投影接近路线、`h.s < nextS`、新时间严格位于`tA < t < nextT`、沿路回推速度15–350km/h。全部通过后、`kept.append`之前加入：

```swift
let nextIndex = kept.last?.index ?? ib
let meters = GeoMath.haversine(track.lat[k], track.lon[k],
                              track.lat[nextIndex], track.lon[nextIndex])
if GapDetector.isBreakStep(dt: nextT - t, meters: meters) { break }
```

必须使用**下一实际保留点或B**，不能使用原始`k+1`；被之前守卫跳过的坏点/重复点未参与落地。必须使用**改后的时间差**，不能使用滞后的原始时间戳。距离用两个落地原位置的地表距离；不要换成整条route长度或另外发明稀疏阈值。`break`停止继续收更早的点，把整段未覆盖前缀交回已有插值流程；不要改成仅`continue`而继续寻找可能折返近B的更早点。

归纳上，每次append都保证“当前保留点→已有尾链→B”每一条实际边不满足现有isBreakStep。随后A侧校验的`kept.removeLast`只移除最早保留点、延长插值前缀，不会新造尾链边；`landingPoints`按严格递增改时排列，保留该不变量。这里的“尾链”允许原算法跳过不合格观测，不承诺原始下标连续全部保留。

`GapDetector.isBreakStep`当前规则是：速度>350，或距离≥150m且dt≥20s。它与现有候选/上下文的断档口径一致。不要为这两个fixture增加特例或改边界，尤其不能把`>=`改成`>`。

## 对原点保护与范围的决定

这是**用户已选择的staleClock替换区间内**的一项保留优化。现有语义本来就将该区间内不满足retime条件的点替换，并保存完整删除记录。新增规则只减少不连续的早期“保留点”，不会扩大Job锚点、修改候选区间外点，也不应波及另一个segment。

因此本轮不需要多区间插值。多区间方案会增加每腿裁路、时间分配、重叠/重复点、预览计数、retimed键和出口速度一致性的接口，风险超过修复已证实缺陷所需。也不需要一遇断档就拒绝整个合法job：已有A→更晚出口的route足以铺完整前缀，原评分会重新评估实际落地几何；高风险项目按原规则不默认选中。

但不能声称“被排除的早期点都是假点”：它们可能是真实位置，只是不能作为**无需再插点的连续出口链**。修改记录必须保存原坐标/海拔/旧时间/segment，预览准确标为替换而非改时，全部还原能精确恢复。自动替换的范围仍由既有候选、用户选择及安全检查决定，不能把本条件挪到一般去噪、采样清洗或所有timeGap上。

缺失时间、坏段身份、无效速度等输入继续走既有Plan nil/无效job路径；不要通过补默认时间或借邻段出口速度强造retime计划。只有无法证明同段/版本有效等结构前提时应拒绝job；普通无可保留点的结果是Plan nil，并由原完整路线插值处理，不是失败评分。

## P4移植契约

- `plan`内部的k、hi/lo、nextIndex全部是**同一个SegmentSamples/view的local index**；出入口统一转换一次。全局gap的indexA/B、frozenA、shiftA/B必须先按同段rank解释，不能对全局时间下标直接±1。
- `exitSpeed`优先值必须来自同段candidate；fallback B→B+1必须是本段后继。segment末没有后继时不能借用全局下一点。
- 对外Plan.retimed.index与Job.keep保持owner已定的global index契约；`landingPoints`、`keys/oldKeys`、ChangePoint.removed、预览计数使用同一映射。不能将local index直接用来读取全局TrackData。
- 预览、单处Replace、批量`landingJob`和`assessBatchItem`必须调用同一个修复后的plan；重算后retimed数量/retimedKeys变化应进入真实Job、ChangeLog与内容指纹。不能只在最终GapSplice后补救，否则预览和risk仍基于旧小前缀。
- 同文件交叠段的原点必须不变；不同段同time/lat/lon必须靠segment/GapID区分，不能因PointKey相同而算作本job保留点。

## 必须补充的生产边界测试

下表是实现owner/Sol应运行的真实Swift测试要求；不是本设计已执行清单。

| 类别 | 输入与断言 |
|---|---|
| 两个实际underfill | 重跑第84/97项完整生产fake route→landingJob→GapSplice→computeCandidates，分别169+3/risk10、112+5/risk85，无原窗口残余gap；其它98分数、四项55不变。不能只断言合成点变多 |
| 正常密集出口 | 3–10个按原规则可retime的连续点，新旧Plan的index/time/vertices/fillB全部相同；单处、预览、批量落地数组位级相同 |
| 只有1个出口点 | 点→B不触发isBreak时可保留；若触发则kept为空、Plan nil、完整route插值；不能只补A→该稀疏点并遗留尾部gap |
| 最后一段到B | 构造最靠B的观察点本身与B相隔大gap；首次循环即break，不得因为kept为空而漏查B |
| 内部无效点 | 两个合格出口点中夹离路点/投影逆行点；新检查使用下一实际kept，不是k+1；若跨越后的实际边有gap则截断，否则保持原来保留结果 |
| 重复时间/重复位置 | 原time相同但推算新time可分开时按原规则保留；推算后同秒必须继续被`t<nextT`拒绝；新链无重复/倒序时间、不崩溃、没有负dt。重复位置/投影相同继续受`h.s<nextS`限制 |
| 缺时间/无速度 | A/B或候选不在有效timed view、无有效exitSpeed，Plan nil或上层拒绝；不使用NaN进行排序/整数转换，不从相邻segment取速度 |
| 停留/停车 | 比较新旧Plan：原投影/15kmh下限已排除的零移动/低速点不得被新规则重新接纳；小位移长dt不因“时间长”单独触发新break（规则要求距离≥150），不得增加新停车删除阈值 |
| 真正稀疏采样 | 非stale/timeGap时Plan继续nil，不改变正常保留/补点逻辑。若在已选stale替换区间内有200m/30s稀疏出口边，本轮明确不把它作为无需插值的尾链；进入route前缀覆盖并保留原点还原证据 |
| 阈值 | 149.999999m/20s不break；150m/20s break；150m/19.999999s不break；350km/h等号不break、略高break。使用实际同口径GeoMath构造和足够浮点容差，不因测试浮点误差改生产阈值 |
| A侧裁退 | 最早kept因A→first速度不合理被移除后，余下尾链仍连续、fillB/裁顶点改到新first；无残余gap、retimed键与Job实际点一致 |
| 分段交叠 | 在目标段的global时间间隙插入另一段点，包括相同时间/位置；候选结果和本段Job等于单独运行，另一段所有原点位级不变，改时数量不膨胀 |
| 原点还原 | 被截掉的早期点进入removed而非retimed；新旧时间/海拔/段标签准确，删除→全部还原回到基线；预览显示和最终计数相同 |

覆盖验收用**实际Job的A + points/kept + B**与落地后同段重检；不能拿未裁RouteDraft顶点替代实际落地几何。对retimed尾链可直接断言每条边`!isBreakStep`，这是小范围、可定位的核心不变量。

不新增“任意手动点距都必须零候选”的全局运行时拒绝器：用户可选择粗点距，`isBreakStep`也是保守间隙判据，不能把本修复扩成新密度策略。两个实际案例及默认自动点距必须完成覆盖；若某新合成边界显示完整route插值本身仍留gap，应单独记录实际原因并修对应生成路径，不能降原标准。

## 停留、长弯道与覆盖表述的界限

本条件检查的是实际保留点间的现有断档语义，不证明GPS观测一定真实，也不要求每个原route顶点都生成点。长时间但小位移可能是停车，不能只按dt决定删点；路线弧长大而原点弦长小也可能有折返/投影歧义，不能为了7行修复新增“弧长等于实际走过路程”的假设。原投影/速度/风险检查继续处理这些情形；本轮不改成`max(弧长,弦长)`新规则，不扩成多腿路由。如果这种输入在真实Swift测试中产生另一个可定位的覆盖错误，应保留反例另作针对修复，而不是声称本补丁证明所有路线模型正确。

## 实际审查证据与状态

本代理已读取：Sol完整风险报告、7行patch、实际coverage-comparison.json、生产与P4共享scratch的StaleRetime/landingPoints/isBreakStep、插值与相关设计文档/调用位置。确认Sol两处beforeDetected非空、afterDetected为空，且合成/改时/分数与报告一致。Sol已有51自测/125考卷通过是其执行证据，本代理没有复跑或冒称亲自执行。

本代理运行`artifacts/boundary-model.py`，14项规格模型通过，覆盖当前阈值等号、停车/稀疏谓词、连续尾链和A侧裁退不变量；完整输出在boundary-model.out.json。它是数学/逻辑模型，不是Swift产品测试。

没有编辑生产或scratch业务代码，没有构建或运行app、API、网络，也没有另派代理。正常命令/结果保存在artifacts/journal.jsonl，阶段活动已通过agent_run event记录。请求模型gpt-6-astra/ultra，服务端独立模型回执/token/费用未知。按任务要求finish provider succeeded、acceptance pending，由主代理核验后推进整合。
