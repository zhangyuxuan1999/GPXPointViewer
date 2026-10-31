# UI-L1 最终像素与修复验收：通过

2026-10-30。主代理直接查看子代理已经保存的六张原图，未重新运行 App、截图或功能测试。

## 证据归属与结论

- 新构建：Builds/20261030T060514Z_release_4bd65c63/archive/GPXPointViewer.app。
- executable SHA256：64d5101be7c3239d10e0cfd01109b3220899f992f9865d1eda0dc2b606b5e883。
- source SHA256：e2bfc9963f3ba993cd6506f0bc54de9565929779114bee584dbafb30ec07c175。
- 中文 daily-top/journey-lower：来自 deepseek/20261030T061054.914921Z_journey-summary-header-layout-visual_d936180c；已在 header-layout-zh-review.md 判通过，后续未重拍。
- 英文、德文各 daily-top/journey-lower：来自 deepseek/20261030T061550.887672Z_journey-summary-header-layout-visual-r2_586345c3；四张原图本次已逐图查看，全部通过。
- 图路径、SHA256、实际命令、构建、清理、偏好与 0 功能检查的原始 JSON 汇总分别见 header-layout-zh-evidence.json 和 header-layout-final-evidence.json。

三语顶部每日／行程切换器均为单行，冗余摘要列表标签不再挤成多行；来源与时区控件、时间范围、记录／估算距离和时长字段清晰可读。下半区长国家／地区名称自然换行，手动水路选择、说明和在主地图查看按钮均可读、可见。滚动区域在顶部图中未展示的下方内容不当作截断缺陷。未发现剩余 UI-L1 布局问题。辅助功能名称沿用同一本地化键有源码与编译证据；未另行宣称 VoiceOver 实测。

## 最小修复与证据继承

Sol 的 precise changes.diff 已由主代理检查：产品代码只新增 Picker 的 labelsHidden() 及原键 accessibilityLabel；无状态绑定、数值、Store、地区或翻译修改。测试驱动只新增 --layout-only 范围限制。静态 AST 证据表明该路径仅两个图片调用、零 check 调用。新旧构建输入清单仅 JourneySummaryWindow.swift 变化，见 header-build-inheritance.json。新构建成功；最终编译1221应用键、新增76键齐全且未漂移，见 final-build-localization.json。

原12项实际应用功能、核心22个不同用例、Store70项检查（含就绪检查）、解锁恢复轮的主地图筛选块与无时间戳界面证据均继承，没有因独立验收再跑。核心/Store审查与定向修复证据在原报告中保留。

## 执行、中断与清理

六图任务首次只完成中文两图；英文 preflight 确认 loginwindow，在测试 App 启动前退出1；德文未执行。该任务 verify=incomplete 保留。用户再次确认解锁后，新任务只恢复缺少的英德四图，wrapper exit0、complete=true，两语各0功能检查。临时 caffeinate 仅随拥有的驱动进程运行，已随正常退出释放，未修改系统偏好。

新构建三语测试副本均有退出记录，偏好精确恢复 true、实际 preferences_changed=false；所有 owned 进程清理 true，正式 App 未关闭。最新 DeepSeek provider succeeded/runner_exit0，无协议错误或源码修改，实际服务模型回执与实际费用 unknown/null。尝试额外读取 PNG 元数据的只读 CLI 命令被权限系统拒绝且未执行；根代理已有原图读取与 SHA256 证据，未为此重拍。此前原黑图、可见缺陷图、权限拒绝和中断日志全部保留。

结论：Sol 最小布局修复及 DeepSeek 四图恢复任务验收通过；新增每日／行程摘要在 docs/journey-summary-acceptance.md 所述功能与验证范围内验收通过。未把这次结果扩大为全项目完整回归或已安装发布。
