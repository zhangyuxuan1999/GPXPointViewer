# QuickLook预览边界修复交付

完成实现与实际验证，修改只留在共享scratch；主产品未写回。请求模型Sol Ultra；服务端模型回执、token、费用未知。独立验收待主代理。

## 真实反例与修复

无NSApplication、无窗口，直接NSBitmapImageRep+NSGraphicsContext调用生产TrackShape.draw。修前PNG只有首绿/尾红，中间孤点不存在；真实像素断言失败。10000两点段实际保留20000点，10000wpt保留10000点，均超6000；跨段大距离污染median还压制同段1°软断。基线失败与完整PNG在artifacts/baseline-pixels-r2。

TrackShape现在为每个保留的无边点画蓝圆点，再叠原输入起点绿/终点红；来源边界及软断点都不造桥。原输入最后点即使因按源分组变成内部点，仍正确画红色终点。

新增preview-only GPXPreviewSampling：全局最多6000保留点；先用最多6000个全文件等距位置挑candidate source，再扫描这些源的真实首/尾/成员数；预算不足可丢部分短源，但所有保留多点源至少保留其真实首尾。剩余预算按保留源可采内部点数分配。candidate source摘要、索引桶及输出也最多6000，不构建主app拓扑，不建立全输入点索引数组。隐式/单一显式源走算术rank快路。

median只采真实同源原始邻接（最多4096个距离样本），原阈值max(50×median,0.5°)保留。第二次扫描将任何原始软断传播到下一保留点，LOD即使跳过异常点也不能跨软断连接。硬段始终独立。预览按原输入段内顺序，不承诺原XML无损往返。未改parser采样及QuickLook32MB分支。

## 实际验证

`python3 Tests/segments/core/run.py RUN/artifacts/full-core-r2`退出0：

- 原生产核心与新增Writer检查 **101/101**；真实无窗口像素/采样检查 **24/24**。
- 三孤点全部可见且中间桥像素为空；1/2点、交叠来源、原始首尾标记、硬/软断、LOD跳过原始软断均通过。
- 10000两点源和10000wpt都只保留6000点；不等长多源及30000点七源交叠也满足全局预算、每个保留源真实首尾和跨源必断。
- Writer实际执行（非模型模拟）：两个不同段time/lat/lon完全相同，仅segment7键synthetic；输出只在对应trkseg出现一次src标记，筛选出的真实双胞点也不误标。协调过的Writer与Support原件hash保持不变；README准确说明stub只隔离GPU发布/不链接路由，synthetic查询由真实Writer覆盖。
- 共享parser/GeoCompute+全部QuickLook/Thumbnail Swift独立typecheck退出0。
- 百万隐式点单进程rusage诊断：修前保留6026点/maxRSS33112064bytes，修后6000点/25018368bytes，约减少8.09MB；源码结构检查同时确认无Array(0..<n)和candidate源数上限6000。RSS为单次诊断，不是固定测试阈值。

实际修后PNG：artifacts/full-core-r2/preview/three-isolated.png（绿/蓝/红，无桥）。本代理也读取了修前/修后PNG确认所见与像素断言一致。

## 留档与范围

拥有修改：GPXQuickLook/TrackShape.swift、Tests/segments/core/main.swift、run.py、README.md，新增preview/main.swift及preview/run.py。前后hash/快照、新增清单及独立patch位于artifacts/*manifest.json、before/、after/、changes.json、quicklook-boundaries.patch。保护检查：artifacts/protected-writer-support-check.json。未碰主工作区产品、Writer实现、Support协调窄改、Parser、Metal、B业务文件；无产品app、API、联网、安装或另派代理。

失败未抹掉：最初单点像素只查(160,60)，但padding后真实绿点约(156,64)，因此测试坐标有误；产品编辑前已看PNG并修为中心邻域检查，缺中点等四个真实失败保持不变。旧原始harness和输出保留。首次Writer新增测试把throw放进nonthrow autoclosure导致编译失败，修为先读取XML后断言，最终全套通过。`time -l`因沙盒sysctl被拒无法给RSS，保留失败，改用子进程getrusage取得实际RSS。

主要阶段均调用agent_run.event更新活动证据。主代理接下来独立审查并整合，再做统一构建；本run不宣称主产品已发布。
