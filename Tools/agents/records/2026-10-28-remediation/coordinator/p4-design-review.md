# P4 架构验收

主代理核对当前最终接口和实现分工：保留时间规范化语义；按段order/rank、run描述符和GPU映射支持交叠段、LOD尾边及孤点；批次membership与GapID覆盖跨段误删及键碰撞；CSV保留平面单文件；QuickLook有折线必须传播段。范围与原问题对应，Astra明确只有规格模型不是生产测试。

批准作为A/B/C实施依据，生产正确性仍待实际Swift/Metal/端到端验证。
