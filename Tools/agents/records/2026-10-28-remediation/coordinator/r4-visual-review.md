# R4 主代理视觉验收

查看本轮 artifacts/shots 的真实 PNG：r4_main_fill_zh-Hans.png、r4_main_fill_en.png、r4_main_fill_de.png 和 r4_line_labels.png。主窗口几何大小仍以对应 hook `windows` 结果为准，截图像素含阴影/缩放，不能以像素大小反推窗口尺寸。

- zh-Hans/en/de 左面板底部两行：导出/图片/删除/补点图标行及修改记录按钮完整可见，位于横跨窗口的补点条上方，无遮挡、无省略号。R4 §5 a/b 通过。中段可滚动/截短是任务允许行为。
- 两路地图标签：OSRM 与 Valhalla 均可见，分别贴近两条蓝色线路；与 hook lineLabels=2 证据一致。R4 §2 视觉通过。
- 图像正常，不是锁屏白图。
- 另记录已有布局问题：en/de 侧栏中段整体略越过左边界，部分文字首字和控件左侧被裁切；原任务明确将德文此项作为旧问题，不计R4失败。用户当前要求问题都修，已另交P4-B同一ContentView owner修复，最终构建需三语重新截图验收。

本次只评价这四张图，不代替其余脚本/数据/最终清理验收。
