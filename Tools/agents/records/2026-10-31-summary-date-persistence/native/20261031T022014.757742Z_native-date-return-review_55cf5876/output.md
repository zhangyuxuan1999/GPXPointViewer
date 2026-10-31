# 原生日期 Return 修复窄审查

结论：冻结补丁在静态审查范围通过，没有发现需修改的明确缺陷。前次日期导航独立审查保持有效；本报告不宣称新控件的实际单次 Return、未先 Return 直接点查看、或布局像素已经通过。

请求 GPT-6.1 Sol / ultra；服务端实际模型/强度、token、账单未暴露，unknown/null。本 run 没有执行任何测试、parse/typecheck/AST、编译、App/UI、截图、安装或真实偏好操作；仅读取冻结源码、diff、已有静态结果与主代理既有实际失败记录。只写自身记录，未派发其他代理/聊天。

## 输入与版本

作者 run：native/20261031T021407.735687Z_date-native-return-submit_207886b8，已读 task、output、result、精确前后文件差异及 typecheck/AST 正常输出。三个修改文件均与作者冻结 after hash 相等，见本 run artifacts/source-attribution.json。

- JourneySummaryWindow.swift：0a85d867684c3d1378537fef5d34790346c8e433490f09ea2b980739b8e25c4e
- UITestHook.swift：e8aff0c7d365c677afea608a01993aab1f463189aac931a1e3e209429ddbb901
- run_summary_navigation_tests.py：2119b111eb34470f67bb39a8d1dbab6c7b29e45aa3d3623eade5619502471659

Store、SummaryState、Summary核心、App均与前次已审查哈希相同，没有日期/cache/索引或保存逻辑新改动。作者最终typecheck的NativeDateBridge-final.swift与冻结源完整新增声明逐字相同（仅加import），hash e36377e2eee1e0576c201627b696a9670442e5cef537d5f5f8242d5a73a486fa，避免把不同提取版本证据混用。

主代理 coordinator/native-keyboard-first.json 明确记载旧控件的字面输入可用、Return失败而View按钮成功；其helper过期终态和owned cleanup保留，没有将局部CUA观察冒称整helper通过。settings-and-entry-inheritance.md保留既有A/B/C 4项及导航前3项通过范围。没有要求重复这些结果。

## 静态结论

1. Window:441–446 用 addLocalMonitor，限定事件来自 picker.window、picker 实际 ownsEditor、无 command/control/option modifier、Return/Enter 键码。ownsEditor:413–416识别自身/currentEditor/子视图；IANA时区输入及其他窗口不会被该监听器截获。监听器没有全局监控，也不读取/记录键入内容。满足条件后返回 nil 消费此 keyDown，避免它继续触发窗口默认按钮。
2. Window:437–452 在viewDidMoveToWindow先移除旧monitor，仅在有窗口时重建；dismantleNSView:400–402也明确移除。闭包weak self，没有monitor→picker强引用环；没有长期保留系统全局键盘数据。
3. Window:423–434 是button/Return共用提交路径：isSubmitting/isSynchronizing阻止重入及外部同步提交，validateEditing后尝试结束field editor，失败直接返回，不查询旧值；随后读取原生dateValue，onChange同步草稿，再onSubmit一次。changed只更新草稿，不另触发select；Return keyDown被消费，没发现同一事件同时走默认按钮的路径。
4. Window:366–379 使用NSDatePicker文本分段+步进样式、Gregorian+UTC civil载体，沿用“查看日期”本地化键。顶层回调仍将UTC civil组件交给既有selectSummaryDate，在实际摘要区严格校验；Store未被绕过。
5. Window:383–397 的普通update不覆盖正在编辑的字段；新的navigation revision先抑制旧action再同步新日期，明确主入口仍能覆盖旧编辑。controller对picker为弱引用，按钮与Return共用当前原生控件。草稿、selectedDay、来源、zone与缓存契约沿用前次已审代码。
6. UITestHook只新增两处NSApp.activate，事件仍发到其已找到的摘要窗口；没有直接调用Store补偿测试结果。driver去掉Tab，仅从日期字段发一个Return，仍通过产品桥接提交。日期dateValue action仍不等同于literal typing，作者与remaining分支都明确保留主代理实际字面键入检查。
7. navigation-remaining只准备同一小fixture、打开报告和截图，再执行原生字段Return跨十年、空日不回退、当前日跨午夜完整行程三个断言；没有执行前3导航或A/B/C，也没有Store新断言来替代真实UI。visual-only仍为布局准备与0功能断言。

## 已有静态证据与边界

已读取作者 capture 的021923_native-final-typecheck、product-syntax-parse、final-static元数据/stdout/stderr：各exit0；最终typecheck正常输出为空且stderr为空，AST正常输出为PYTHON_AST_OK、REMAINING_CHECKS 3及准确三项名称。这些是作者既有结果，本run未重跑。

实际控件对pending字段编辑的flush与NSEvent焦点行为必须由主代理新构建实际检查；typecheck不能证明运行时交互。接下来的最小验收是：新控件字面键入年/月/日后一次Return、不先Return直接点View的pending edit、remaining3和受控件变化影响的顶部/三语像素。旧通过的44个唯一导航功能名称、settings4和前3实际入口功能继续按原证据继承，无理由重复。

一次读取diff子串的辅助命令因不存在预设hunk文本退出1，完整错误留在capture；随后按真实行读取成功。这是审查读操作错误，没有执行或改变产品，也不是产品失败。
