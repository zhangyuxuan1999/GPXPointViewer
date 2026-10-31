# 视觉准备等待定向修复

原因已由原en hooks证明：003 open后立即004 summarymaindate/005 summary；006 ready=false、filterPoints0、主日范围虽已写入但sources尚空，Store入口按空来源清掉已提交日期；007载入完成清掉主filter/spec；008报告ready/11点/GMT时selectedDay仍空。因此它是驱动在异步fixture载入前设置日期的竞态，GMT不是根因，也没有Return产品回归证据。原始引用和精简状态见artifacts/cause-evidence.json。对应Store源码是apply清viewFilter/spec和applySummaryEntry的empty-sources reset，均没有修改。

只修改Tests/ui/run_summary_navigation_tests.py的visual-only准备：先等待通用state的loading=false、points=11，才设置主日并打开摘要；仍严格等待selectedDay=2026-10-16，不放宽结果。AST静态检查通过，visual-only 0功能断言。冻结SHA256：`901ba4f0ad7b89dac990be323735f9fe28ff5a0d0d56886c419d6e0caad3b63b`。

keyboard-r2虽然也在open后设all，但其目标本来是未提交日期，并在summary report ready后才focus，不存在已指定日被载入清掉的问题。只读ready.json确认ready=true、totalPoints11、selectedDay空、zoneUTC、filterPoints11；未修改或操作当前helper/进程。

本run没有启动App、UI、构建或测试；产品文件没改。既有44 Store、3+3导航、4 settings均继承不重跑。新驱动实际视觉补拍结果仍待root调度。精确前后hash/diff在artifacts/exact-file-changes.json及exact-changes.diff，只有1个driver修改。

请求Sol ultra；供应商实际模型/强度/费用未知null。
