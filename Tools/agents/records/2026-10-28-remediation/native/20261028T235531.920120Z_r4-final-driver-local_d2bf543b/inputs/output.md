# R4风险异常独立复核：发现真实retime覆盖缺陷，评分与任务说明分开处理

请求 GPT-6.1 Sol / ultra；服务端模型回执、token、实际费用未暴露，保持未知。审查及局部提案验证完成；主代理/Astra独立验收与P4-B整合待执行。主产品、P4共享scratch、审计scratch中的13个原生产文件均未修改（最终hash核对全同）。

## 结论

1. **产品缺陷已证实：StaleRetime只在A→最早保留点插值，却能保留中间相隔数公里的两组真实点。** 实际GapSplice后生产computeCandidates仍检出原窗口内的大断档。不能因为98% high通过、stale标签或risk0对应无偏移几何，就认定整处补完。
2. **FillPlausibility没有漏评该项实际落地的30m偏移。** 原R4第97项的偏移顶点确实被retime裁掉；实际仅新增2个近raw的点，7个原位置只改时间，risk0正确反映了这份不完整的落地几何。修复覆盖后完整路线实际落地，原评分自然升到85；没有改阈值或硬加分。
3. **任务说明有错误，严格验收不必放宽。** 四项55是合法high：max≤30m扣30，median>10m扣25。30m浮点投影可能落在边界两侧，不能写成必>30扣60，更不能用“约95–100”作精确期望。最终任务patch保留vMinRisk>50与≥95%断言，并补真实覆盖验证。

## 复现方法与真实执行边界

唯一审计scratch：`/private/tmp/gpxpv-r4-risk-audit-ui9dgc6y`。直接编译原GPXParser/TrackData/GapFill/RoadNetwork/FillPlausibility等Swift；TrackStore的computeCandidates、landingJob、assessBatchItem、spacing及其helper、UITestHook.installFakeRoutes机械提取原函数，仅去private访问限制。原函数行号/hash在`artifacts/extracted-functions.json`。GPU发布stub返回nil；无产品app/UI/安装、无API或公共路网。fake routeOverride强制生效，并设replay兜底；实际发送0。

固定输入Garmin_Roma_Da_copy.gpx为46267点，真实检测100候选。逐ID重现R4全量state，100个risk完全一致，Valhalla分布0×1、55×4、85×25、95×10、100×10。生产GapSplice的100个job点坐标/时间位级一致，前后原点全部未变。最终原版证据：`artifacts/probe-r6/actual-chain.json`、summary与命令/退出码；全部原始输入hash见input-manifest。

## risk0实际链：第97项 / tA1792256646

原锚45701→45709、118秒，fake draft的三个顶点偏raw约30m。StaleRetime保留45702…45708共7点，其中前2点接近A、只改时+2s，后5点在B附近、约改时+110s。最早保留点45702的新时1792256649，投影在首个偏移顶点之前，因此plan.vertices=[]、fillB改为这个真实点，合成点仅2个。

实际两合成点到raw距离0.285606/0.571213m；所有落地窗口点距raw最大1.561163m。raw是直弦，沿各相邻边的偏离也受端点最大值约束，所以不存在隐藏的30m偏移边。真实metrics：devRouteMax0.556145m、median0、allowance0、innerMaxOff1.585561m、detour1、速度比1.005876；risk0/reasons[]符合现有梯度。未裁的草稿仍保存在记录证据里，不能拿它代替actual jobPoints。

但实际落地46267→46269后，重新检测仍产生timeGap：1792256650→1792256759，109秒/4195.402666m，新index45705→45706。独立第84项（OSRM，tA1792244850、chain2）也有同类问题：原计划13合成+4改时，落地仍检出1792244961→1792245113，152秒/6866.020797m。

## 局部修复提案及对照

`artifacts/retime-coverage-proposal.patch`增加连续出口后缀判断：按已求得的改时t，比较当前真实点与下一保留点（或B）的真实位置/新时差；若触发现有GapDetector.isBreakStep，停止向前收点。这样只保留密集出口后缀，A→真正出口首点沿完整路线插值。它会将被排除的早期区间观察点交回既有替换流程；完整删除/新增记录应由P4-B照常保留。无需新阈值，亦不修改FillPlausibility。

未应用到任何拥有源码。为实际验证，swiftc直接将proposal artifact作为GapFill输入，其他生产实现保持原版。`artifacts/coverage-proposal-r2`退出0：

|项|原合成/改时|提案合成/改时|risk前→后|原窗口重检|
|---|---|---|---|---|
|97 / Valhalla|2 / 7|112 / 5|0→85|109s断档→无候选|
|84 / OSRM|13 / 4|169 / 3|0→10|152s断档→无候选|

其余98项risk精确不变，四项55仍55。第97项实际完整偏移max30.000000000073m、median29.999999999853m，原阶梯60+25=85；第84项完整路线尾段向真实出口点靠拢，max8.414152m、median≈0，原阶梯10+0=10，仍low。对照详情`artifacts/coverage-comparison.json`。

## 四项55的实际metrics

|0-based项 / tA|devMax m|devMedian m|allowance|计分|
|---|---:|---:|---:|---|
|3 / 1792189794|29.999999999894|29.860790|0|30+25=55|
|25 / 1792200955|29.999999999894|23.545920|0|30+25=55|
|45 / 1792220106|29.999999999911|29.999999999524|0|30+25=55|
|53 / 1792221747|29.999999999990|29.999999999716|0|30+25=55|

其余信号在这些项为0；均risk>50，high、有原因、默认不勾选。独立梯度边界回归验证29.99999999/30/30.00000001分别计30/30/60。

## 反例与回归

- 同第97项保留完整117个fake合成点：risk85；将其实际2个合成点偏移30m：max30.564495、median16.151492、risk85，证明没有stale通用豁免。
- 稀疏单顶点30m三角峰：确实采顶点，max25.078152（扣端部5.009848）、median9.689332，risk40。不能把单峰当平行平台强求high。审计自建负对照首次错要求>50，其失败与原harness保留；在下次执行前按几何/现有梯度明确修其契约，只要求真实偏离被测出并扣分。产品和原baseline期望未改。
- 提案直接编译后现有自测31 crosscheck+8 portal+5 tunnel+7 plausibility=51/51。125题录音考卷两引擎仍121/125，artefact123/125、parallel125/125、high∧pass0；requests sent0、replayed255、missing0，退出0。日志在existing-offline-proposal-r1/r2。首次portal夹具因scratch相对路径缺失失败，显式原夹具绝对路径重跑8/8通过；保留环境失败证据。
- 首个严格提案对照要求其余99分数完全不变，确实捕获第84项第二个覆盖缺陷而失败。保留失败原件，再按独立实际几何证明扩展为两例覆盖回归；不是为通过改原考卷或梯度。

## 最终交付与待办

采用`artifacts/retime-coverage-proposal.patch`与`artifacts/task-expectation-r2.patch`；两者git apply --check通过。**旧task-expectation.patch是未应用且已废弃的中间提案，不采用。** 最终任务patch保留原min>50和比例判据，只修说明/注释并增加实际落地重检。

完整原生产快照、哈希、机械提取的回归源码、每轮失败/成功输出、实际参数/退出码均留在本run。`artifacts/regression/`保存最终baseline与proposal两套CLI及恢复用脚本；source-final-check证明无产品改写。

主代理需让Astra审查后由P4-B把局部逻辑合进当前分段采样实现，再执行其集成与DeepSeek复测。本报告没有宣称主产品已修复/已发布；只是证实缺陷并交付实际验证过的局部提案。
