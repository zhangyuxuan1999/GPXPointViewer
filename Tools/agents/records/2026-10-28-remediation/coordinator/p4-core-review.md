# P4-A与QuickLook后续修复主代理验收

主代理阅读A交付、解析词法结构、Writer段分组实现及新的GPXPreviewSampling代码。初次审查未放行：发现中间孤点不画、每段强留首尾超预算、全输入索引分配和跨段步长污染。后续Sol保留真实像素/规模反例并修复，未覆盖原失败。

主代理对shared最终core重新编译实际GPXParser/TrackData/GeoCompute/GPXWriter/TrackShape并执行：101/101核心、24/24无窗口像素/采样检查，退出0。命令和完整输出在commands/20261029T000910_core-preview-independent_8d55253a，持久副本在core-independent-evidence。该套GPU发布为nil stub；实际GPU已另在C完成独立94+17检查，两者不混称。

主代理实际查看自己运行生成的three-isolated.png：绿、蓝、红三点全部可见，无桥。10000两点来源/10000wpt都保留6000点；实际Writer两个段同time/lat/lon只有正确segment出现一次synthetic标记。Source与Support协调窄改保留，未新增产品文件或改变32MB分支。

通过的是核心/预览局部实现；B业务与最终app/扩展构建仍单独验收。编译输出保留原GPXParser memcpy返回值未使用警告，不冒称零警告。单次百万解析/内存诊断的性能数字见对应Sol报告，不当成全产品保证。
