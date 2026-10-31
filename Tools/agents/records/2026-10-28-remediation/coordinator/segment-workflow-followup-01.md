# P4-B接口与本地化协调

主代理接受PointKey增加segment UInt32、initializer默认0保持既有单段调用的兼容方案；syntheticKeys/anchorKeys和ChangePoint还原位键均包含segment，防止跨段相同值误标/误恢复。GPXWriter查询由主代理做一处窄改，并协调core harness stub同步，B不跨owner编辑Writer。

完成所有产品用户可见文案后，请列出新增或变动的String(localized:)键、上下文及旧键清单，供DeepSeek按现有翻译块补en/de/zh-Hant再统一assemble。请顺便检查ChangeReview中现有「还原按点的值找回，不按下标；逐处还原后其它修改不受影响」帮助：若为当前实现保留，可改成解释用户可行动的依赖规则，例如「若后续修改依赖此处，请一并还原相关修改。」不要把位键、下标或实现细节暴露给用户；仍保留完整新安全拒绝错误信息。

当前Astra正审查retime补点覆盖提案，两个反例修后无残余gap，98项risk不变，51自测/125考卷不变，原vMinRisk>50继续严格保留。最终决策会单独转发。
