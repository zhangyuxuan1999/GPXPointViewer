# P4-A 主代理初审

已读实现报告、具体接口、真实测试入口及TrackShape生产代码。核心97项结果、单段额外CPU成本均有明确证据，尚未将其作为整个P4完成。

待修发现：新孤立段身份使TrackShape中间无边点不被draw画出（仅首尾dot）；分段首尾保留可能使1万短段越过原6000预览预算；单段Array(0..<n)新增O(n)索引分配；softbreak median仍可能采跨段距离。已形成quicklook-followup-task.md，排在当前R4风险审查后由同一Sol owner补修和真实像素回归。

当前只初审，不给core独立passed，避免用97项未覆盖的断言代替这些边界。
