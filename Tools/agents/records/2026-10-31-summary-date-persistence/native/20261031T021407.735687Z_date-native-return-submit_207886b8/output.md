# 原生日期Return定向修复交付

代码冻结，供root统一一次新构建及后续定向实际验收。请求 GPT-6.1 Sol / ultra；供应商实际模型/强度/费用工具未暴露，保持unknown/null。

原实际证据已复用：根因是SwiftUI DatePicker的原生字段先消费Return，仅提交字段值，窗口默认按钮不会收到该键。root实际输入2016-01-01后Return未改变selectedDay；点查看正确。原root键盘helper在360秒结束marker前过期，rc1及owned-child清理保留；先前AX/CUA观察有效，不能称整helper正常通过。DeepSeek原前3导航、settings A/B/C 4项及Store44均继承，不重跑。

Window改为小型NSDatePicker NSViewRepresentable bridge，固定Gregorian UTC只编辑civil组件。原生控件target-action更新草稿，continuous通知保护输入；只在此日期字段拥有first responder/editor且事件来自其窗口时，local monitor接收单次Return/键盘Enter，调用NSControl.validateEditing与window.makeFirstResponder结束字段编辑，读该dateValue后提交。查看按钮共用同一个flush方法，避免读取未提交的旧binding。新入口revision可覆盖旧字段编辑，ordinary更新不替换正在键入的分段；外部同步期间抑制旧编辑回写。控件移除/window拆除时移除monitor。Store、核心、日期来源/cache/索引算法未改。

UITestHook仅补NSApp.activate以确保事件送到其拥有的summary窗口；没有新增直接Store选日捷径。driver date_control移除Tab，仅从原生字段发一次Return。新增 `--mode navigation-remaining`：最小载入/打开准备后，仅剩余3断言（原生字段Return跨十年、空日不回退、当天跨午夜完整行程），不执行前3导航或持久化。捕获新chooser header、2016 header、空日及行程上下图；en/de仍可用visual-only的3图/0功能检查。

静态验证：只提取新增完整native bridge声明做SDK typecheck，rc0；最终continuous通知小改后再次typecheck rc0。提取规则与hash见native-typecheck-source/final-typecheck-source.json。Window/Hook syntax parse rc0；Python AST与AST检查remaining分支恰好3个check rc0。没有生成/启动App、Release构建、真实UI、安装或偏好操作。未抽键另编译；仅复用已存在的“查看日期”键，0新唯一键。

API依据为本地AppKit公开SDK，及Apple [local event monitor](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))、[NSControl字段编辑](https://developer.apple.com/documentation/AppKit/NSControl)、[field editor](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextEditing/TextEditing.html)。完整链接与用途保存在artifacts/native-api-evidence.json。

后续root冻结新归档后：

```sh
GPXPV_APP=/ABS/new/archive/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/ABS/new/archive/build-manifest.json python3 Tests/ui/run_summary_navigation_tests.py --mode navigation-remaining --language zh-Hans --evidence /ABS/new-evidence
```

真实字面年月日键入+单Return、未先Return直接点查看的pending-edit flush，以及更换原生控件后的布局仍需新App实际证据；此run没有声称行为或像素已通过。截图继承与补拍范围由root按具体控件影响确定。

三个修改文件的精确前后hash/diff在artifacts/exact-file-changes.json和exact-changes.diff，新增/删除0；finish后before/after快照可审阅。
