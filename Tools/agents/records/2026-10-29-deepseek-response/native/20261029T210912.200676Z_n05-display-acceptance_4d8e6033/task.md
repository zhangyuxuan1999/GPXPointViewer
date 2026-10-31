# N05新增提示的局部展示验收
请求 GPT-6.1 Sol / ultra，独立审查/定向视觉补证。用户要修DeepSeek结论并给可回复文件；默认验收已有证据不重跑。产品代码现冻结，root正在唯一Release，**禁止修改任何产品文件**。不要再运行N19核心/预览、Sol34/CPU19/GPU51、DeepSeek路由探针、旧UI套件；不要启动/关闭正式app、改用户偏好、路网请求、构建全工程或安装/提交。不得再派发agent/API。
新run只允许写自己的artifacts/progress，所有命令/工具输出/退出码/hash完整保存，主要阶段event。目标：N05新fwdb时间说明/≈标记缺视觉排版证据，这是具体缺失，所以只补它，不重新执行回放算法。
产品改动在ContentView.swift：全局fwdbArchiveDateNote、videoExportSheet（宽430，archive caption换行）、PlaybackBarView（fwdb分支≈ + 108日期框，其余内容原样）；VideoExport.swift drawRibbon调用给archive日期加≈，右对齐CTLine。翻译chunk30及catalog已组装。
请读取实际这些局部代码，做可追溯局部渲染fixture：优先抽取真实PlaybackBarView/真实videoExportSheet body，用最小stub数据/动作隔离，不复制一套自创布局。通过NSHostingView/AppKit在本run的独立小程序渲染，不启动正式GPX app；四语zh-Hans/zh-Hant/en/de，归档界面与一个普通GPX无≈对照。可以注入已编译catalog对应字符串和locale，明确这是局部fixture不是完整app流程；不要写全局AppleLanguages/UserDefaults。记录所抽源码hash/行范围、替代的依赖、尺寸及输出PNG。若sandbox无法访问UI服务/GPU，保存明确失败再给root精确已编二进制与命令补执行，别重编或重跑已有检查。
视频日期只需真实drawRibbon函数局部CG渲染或实际CTLine字体尺寸证据，取现生产date前缀逻辑；中文/英文/德文/繁中日期在1080p/4K范围内，符合旧格式并且≈可见、不出框；不导出整段视频、不跑视频算法。
在artifacts/retest-reason.md先写原代码/新变更与缺证原因。只渲染上述新展示，原截图/算法日志复用。若发现实际截断/条件错误，只报root具体修复，禁止在build期间改源码。root会读你的PNG作验收，不重新截图。完成output列证据、限制，finish succeeded/pending供root verify；未暴露model/token/cost一律unknown/null。
