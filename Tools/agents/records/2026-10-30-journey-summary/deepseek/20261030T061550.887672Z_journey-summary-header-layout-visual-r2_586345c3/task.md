# UI-L1 剩余英德四图恢复 — DeepSeek Flash max
请求 deepseek-flash / max。用户再次确认已解锁、桌面可见。只执行一次命令，不重复中文或功能检查。
## 输入、原因和边界
读取此任务、同目录 run-summary-header-layout-r2.py、header-layout-zh-review.md、header-build-inheritance.json。不需要读取其他项目文件。前一轮中文两图通过；英文启动前 loginwindow 拦截，德文未执行，原记录保留。
新构建固定 Build20261030T060514Z_release_4bd65c63；exe SHA64d5101be7c3239d10e0cfd01109b3220899f992f9865d1eda0dc2b606b5e883；source SHAe2bfc9963f3ba993cd6506f0bc54de9565929779114bee584dbafb30ec07c175；driver SHA0f9381fbda2380b1bb4e1cbef12433b2a5c568c342abb35f9b2802f216fd2ef3。
## 唯一命令
python3 /Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-30-journey-summary/coordinator/run-summary-header-layout-r2.py
必须原样调用，不添加环境变量前缀、重定向或额外 shell 命令。GPXPV_AGENT_RUN_DIR 已由运行器注入。可使用 Bash timeout 420000 前景运行；若工具转后台，等待正常完成通知。不得用 sleep 或改名轮询。只执行一次，失败不自动重试。
脚本只运行 en/de --visual-only --layout-only，每种语言 daily-top、journey-lower 两图，共四图，0 功能检查。临时 caffeinate -d -u 随拥有的驱动进程存在，每语180秒运行器期限；不改系统偏好。保留 preflight，已知loginwindow立即在App启动前退出。
## 权限
仅可写本run progress.md/artifacts。禁止改源码、脚本、翻译、文档；禁止重拍中文/main-chip/untimed；禁止重跑原12功能、核心、Store或其他回归。只用唯一测试副本、合成夹具、自己的PID；偏好不读取/外传，按驱动恢复原字节。不关闭正式App、不安装、不读真实轨迹/密钥/无关文件、不用路由API、不派发子代理。
## 结果
读取 artifacts/header-layout-r2/summary.json、每语result/stdout/stderr，各evidence的execution-mode/results/cleanup/build-provenance/screen-preflight；列四PNG。确认0功能、results为空数组、偏好精确恢复、清理完成。保存progress和artifacts/visual-result.json及完整output。像素判断留给主代理：PENDING_ROOT_REVIEW。服务端实际模型和实际费用无证据记unknown/null。使用已有证据不再次执行。
