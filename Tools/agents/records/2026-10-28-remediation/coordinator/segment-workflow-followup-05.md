# 主代理源码复核发现：GapID合并链资格丢失

当前shared实现TrackStore.computeCandidates约1938用 `[GapID: GapNature]` 记录原候选，mergeChains回调仍 `nature[$0.id] == .lossOfLock && nature[$1.id] == .lossOfLock`。但GapFill.mergeChains将p和c合成m后改变indexB（因此m.id已不是原字典键），下一次第三候选加入时nature[m.id]不存在，三段及以上合并会无故截断。旧tA键之所以未出现此问题，是合并不改tA，不能机械换ID后保留旧假设。

请修复并加真实Swift三候选/四候选回归，保留“每个原候选都为lossOfLock才能并”的资格语义；混入稀疏/暂停候选不可跨过，跨段同tA仍不合并。可显式携带/查询原候选资格或调整内部合并追踪，但不要重新引入全局tA身份碰撞。若改变canMerge回调语义，核对全部消费者并说明兼容。

Tests/synth/runner/main.swift的窄迁移暂等你确定这套资格接口后再由主代理/独立任务处理；避免它也机械换GapID而复制这个缺陷。主代理尚未运行当前中间源，现发现为明确控制流反例，请先按真实Swift复现再修。原单段114及实际Garmin候选数必须保持。
