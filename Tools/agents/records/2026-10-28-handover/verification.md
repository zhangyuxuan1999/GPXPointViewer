# 主代理核验与范围

日期：2026-10-28（Europe/Berlin）；原始时间戳按 UTC 留档。

## 本轮实际执行
- Astra Ultra 架构研究；Sol Ultra 历史调查、调用独立审查。派发参数已保存，native 工具未返回独立服务端 model/usage/cost 回执，不能把 requested 字段当作底层路由审计证明。
- DeepSeek smoke r1：本地监听被沙盒拒绝；未请求 API。
- DeepSeek smoke r2：权限获准，2 次 HTTP 200，实际请求 deepseek-flash/max；观察器解析系统事件 KeyError，完整结果未保存，不计为成功。
- DeepSeek smoke r3：2 次 HTTP 200、请求 model=deepseek-flash、output_config.effort=max；Read + tool result + JSON 最终回答全部保存并通过 expected 比较。CLI exit 0、is_error false、2 turns。总共实际发出 4 次 DeepSeek 模型请求（r2+r3）；r2 usage 未保留，费用未知。
- 没有另行调用 OpenAI 公开 API、旧 Claude SDK 或公共路网；没有运行/构建/安装产品。

## 官方路由说明
- [DeepSeek V4.1 Flash 官方发布说明](https://www.deepseek.com/en/news/deepseek-v4-1-flash/)：服务别名 deepseek-flash 对应 V4.1 Flash；本次响应本身仅回显 deepseek-flash，不提供底层权重摘要。
- [DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)：Anthropic 格式使用 output_config.effort 控制强度，max 映射到 max。这里只证明发出了参数，不能测量服务器内部的计算强度。
- [DeepSeek Anthropic 兼容接口](https://api-docs.deepseek.com/guides/anthropic_api/)：base URL https://api.deepseek.com/anthropic；thinking/output_config.effort 支持。
- [OpenAI Multi-agent 说明](https://developers.openai.com/api/docs/guides/responses-multi-agent)：用于理解分派与隔离。当前本地工具的可用模型和参数以实际工具契约/派发结果为准，不拿公开 API 参数推断本地 ultra 的底层映射。

## 本地交叉核对
- 当前 HEAD 最近两条提交仍为 b8927ed（2026-08-16）、4c8eed5（2026-08-11）。大量后续源码在工作区，不能用提交记录代替现状，也不能只靠 git diff 保存未跟踪文件。
- /Applications/GPXPointViewer.app/Contents/MacOS/GPXPointViewer 存在，mtime=2026-10-28T13:12:04.417336Z。
- 历史 /private/tmp/claude-501/-Users-zyx-Documents-GPXPointViewer/84e7be0d-cf7d-470e-9701-04baedd4dc06/tasks/b6bydg7sy.output 记载：五组钩子 FAILS none、installed 14:12、chain-done、exit 0。属于历史验证，不是本轮重测，也不足以证明当前所有源码均与安装二进制一致。
- 已直接核对 TrackData/TrackStore/ChangeLog，以及渲染缓冲的源码。Shared Metal buffer 的初始构建仍有复制；不重复文档中“全程零拷贝”的宽泛说法。

## 后续界限
本次接手调查不等同于完成产品回归，也不自动执行 backlog。旧 Claude API 预算/到期描述过时且台账累计不可靠；未检查实时计费余额，不启动旧付费线路。当前产出是接手材料、可恢复派发记录、项目协作规则和最小诊断脚本。
