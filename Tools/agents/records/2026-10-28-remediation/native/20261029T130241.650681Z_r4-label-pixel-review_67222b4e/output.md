# R4 引擎标签像素与几何审查

**确证标签重叠，已完成局部修复与24/24定向Swift几何回归。**最终产品构建和修复后截图由root验收，本项验收保持pending。请求GPT-6.1 Sol / ultra；服务端模型/强度、token和费用没有独立回执，unknown/null。

## 原像素与真实几何

实际使用view_image查看了最新真实line_labels PNG：
`deepseek/20261029T125630.030432Z_r4-visual-retry_0b33aad1/artifacts/shots/20261029T125630.030432Z_r4-visual-retry_0b33aad1_20261029T125638_533487Z_e5b34415_line_labels.png`。

OSRM与Valhalla蓝底标签在路线中点边缘相压。源图2864×1944，在工具中缩放显示为1920×1303；没有拿显示后的像素坐标冒充原屏幕点。图片路径、SHA256、观察与显示缩放说明保存在pixel-observation-before.json。

随后精确抽取修改前生产`engineLabels`实现，与实际macOS系统semibold10字体和生产padding（水平4、垂直1）组成独立Swift反例。两路竖直重合时中心仅相距22pt，真实外矩形为：OSRM 38.628458×15pt，Valhalla 47.228086×15pt；交集20.928272×15pt，确认不是美观偏好。反例源与完整正常输出见before-production-font-probe.swift、before-font-collision.json和commands/before-font-probe.json。

## 最小修改与冻结

只修改GPXPointViewer/ContentView.swift的EngineLabel计算/显示局部，新增Tests/probes/engine-labels/{run.py,checks.swift,README.md}。没有修改其他UI、本地化、路线/风险/数值引擎、选择状态或测试期待。

- 保留屏幕弧长中点和原±11pt法向初始位置。
- 使用同一真实NSFont及显式外frame进行测量和显示，尺寸上取整，避免计算矩形与SwiftUI标签外框不同。
- 只有与已放置标签矩形实际相交时，沿该标签原侧法向移动至4pt间隔之外；0.5pt余量避免浮点边界接触。沿固定正向越过一个矩形后不会再次进入它；不删除或隐藏标签。
- 标签文字、status4/5筛选、默认90pt可见门、自定义门、lineLabels计数路径和选择/route状态保持。非碰撞标签仍在原位置。

完整ContentView before/after与SHA256、精准changes.patch、新增/删除清单均已保存；将两个允许局部剥离后全文相等（outside_label_blocks_identical=true）。ContentView修改前hash为`394e37443581905d505ca510ffec8186b7e443423fa89403c19d386bfc3cb95f`，冻结后为`33523e1f54f27923b5b8c14d8fd7a45c4b7161e59a583a5c0209f34952851950`。源码已经告知root冻结，此后未再修改。

## 定向验证

执行：

```sh
python3 Tests/probes/engine-labels/run.py <本run>/probe-final-r1
```

退出0，24/24，failures空。测试从当前ContentView精确抽取生产扩展，不复制替代布局算法；使用实际SwiftUI Font/NSFont与真实字体矩形，编译的只有该独立探针，不构建或启动产品。

覆盖竖直/水平/两种斜线重合、两路方向相反、近邻平行/交叉/弯折路线、零长度前段、8标签连续碰撞、非碰撞原坐标不变、89.999pt隐藏和90pt显示、自定义阈值、其他状态、单点/零长度，以及selected/included不改变文字/计数。24项完整标签矩形、坐标、正常stdout、stderr、实际退出码、生成Swift源码、source/check hash和argv保存在probe-final-r1目录。

修复后的竖直反例：OSRM中心11、Valhalla中心-37，显式frame宽39/48、高15，水平净间隔4.5pt，无交集。水平和原本分离的路线位置保持原值。展示字体仍为.AppleSystemUIFontDemi，10pt。

## 权限、恢复与产品证据边界

root在本项读取前已明确发送“API结束可编辑”，原文保存于root-followups.md；源码只在几何缺陷确证后修改。调查中一次旧设计文件名查找失败已原样记录，随后只读找到docs/cross-check-design.md，没有把错误当通过。所有可取得正常命令、错误、退出码和进度均在本run留档；没有读取凭据或环境全集。

本项没有启动app、运行UI、变更prefs、请求API/公共路网或构建产品。新隔离构建、源/可执行文件hash链和标签定向补图由root负责。原11组通过证据仍绑定其原构建，不被覆盖，也不冒称新二进制跑过那11组；按用户要求不重跑原11组或数值回归。三语固定两行等其他UI已由root看过，本项没有扩范围修改。最终像素结论保持等待root的修复后真实截图。

最终机器摘要见review-result.json；冻结文件与新增清单见frozen-source.json。根源码中除上述两个标签局部外无差异。
