# 日期导航实现交付（供root独立验收）

已完成授权范围，产品与测试代码冻结。请求模型 GPT-6.1 Sol / ultra；工具未提供供应商实际模型、强度回执或费用，均unknown/null。

## 改动

- 主面板按钮、菜单及测试入口统一调用 `openSummaryFromMainFilter()`；每次显式打开含已开窗口都接收新日期并切每日。ViewFilterSpec捕获计算时calendar，入口依明确.day/同日.custom语义重建实际范围，再转换为同区Gregorian自然日；陈旧spec/行程chip不猜日期。
- 固定原生DatePicker+查看/Return，草稿与已提交日期分离。未选日只提示，无记录日期保留；选日不入cacheKey、不扫描点列、不启动builder。正文只当天日行或该日关联行程，保留跨午夜完整行程指标。
- 后台建立日/行程导航索引，与report共享归属、取消和publication token并一起发布；A→B期间报告晚到只解释最新B；换源/区/编辑/clear/关闭不能发布旧索引。
- root已接纳的ADR小适配：原生DatePicker用Gregorian UTC只作为civil组件载体，实际区一直显示在旁；业务在实际IANA区求日界并严格回读，可保留Apia跳过日YMD。切区使已选日不可用时立即显示错误并保持该日。
- UITestHook增加真实选中日期/草稿/revision/当天行及关联行程状态；persistsettings调用生产AppLanguage.apply与TrackStore.updateSetting，仅唯一测试ID/环境/真实sandbox全部一致时允许。AppLanguage/idle保存生产逻辑没有修改，App.swift保持原hash。
- 新 `Tests/ui/run_summary_navigation_tests.py` 只准备未执行的navigation/visual-only/persistence子集，使用签名Sol唯一ID副本API；旧summary驱动也已拒绝正式bundleID并核对实际domain/home，避免写正式偏好。

## 新验证和继承

未重跑旧核心22、Store70、原实际UI12；继承旧验收。此次只新导航缺证/局部修复。三次完整产品源测试编译均成功；测试生成规则、原/转换源hash、命令、stdout/stderr、真实退出码均在各attempt。最后源稳定为True。

1. `artifacts/store/20261031T013016.620842Z-0ea540cd` 首组执行在测试强解异步report处trap（原退出-5保存）。原进程stdout缓冲缺前段，原binary的PTY诊断正常输出在 `artifacts/capture/commands/20261031T013138_failed-run-output_f513d8ba/stdout.log`：27个此前通过事件（含4次ready）；旧chip在等待完成前的结论已标superseded。原日期语义/选日缓存等不再重跑。
2. `artifacts/store/20261031T013333.855208Z-ad543f09/run.stdout.txt` 只续跑缺证：26检查，25通过、1失败。失败为测试硬编码UTC枚举，而Foundation named UTC报告会规范为GMT；正确契约是接收chip实际捕获区和自然日界。源码检查证明不应要求别名拼写。原失败保留，后续通过不再跑。
3. `artifacts/store/20261031T013601.036689Z-7250993c/run.stdout.txt` 独立chip与改区Apia缺口：9/9，0失败，SOURCE_STABLE True；只必要setup及两项chip/三项Apia功能检查，4次ready。

按本轮原始正常输出及替代关系，接受45个功能通过事件、按描述去重44个功能检查（两个不同午夜夹具的“当天归属”描述相同）；15次ready另计，不能宣称某次44/44整组跑过。逐项列表与源版本关系见 `artifacts/navigation-evidence-inheritance.json`、`compiled-source-versions.json`、`compiled-first-to-final-*.diff`。最后对Store的产品改动仅O(1)的切区不可用日校验，不改此前入口/索引算法；继承范围由root审阅。

Python新/旧驱动AST与--help静态检查通过；实际App/UI/Release/安装均未执行，没有网络或正式偏好写入。

## 本地化与后续实际UI

`artifacts/new-localization-keys.json` 从第一次必要编译stringsdata精确抽取12个唯一新键（13处引用）；最终必要编译与首次键集增删均为空，见 `compiled-localization-key-diff.json`。没有为抽键额外编译，没有修改catalog/chunks。

`artifacts/ui-contract.md` 给出最终归档运行命令和三进程A/B/C持久化契约。navigation功能中文一次；visual-only中文6图、en/de各3图，0功能断言。原生DatePicker dateValue动作+真实Return可自动执行，但字面键入年/月/日分段仍需root实际电脑使用确认，明确不冒称通过。所有像素判定与实际持久化结果均pending。

## 文件证据

`artifacts/exact-file-changes.json` 和 `exact-changes.diff` 基于init前快照而非单独git diff，覆盖原未跟踪源和新增脚本；finish后snapshots/after提供最终manifest和变化清单。共9个修改文件+1个新增脚本，删除0。GPXPointViewerApp.swift未改；JourneySummary.swift核心未改。
