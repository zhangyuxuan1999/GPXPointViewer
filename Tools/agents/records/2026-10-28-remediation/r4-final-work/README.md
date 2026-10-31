# R4 最终调度脚本：仅准备完成，尚未复测

本目录只包含新 `driver.py` 与本说明，复制并修正旧 `r4-work/driver.py` 的调度功能。准备任务仅执行语法与纯函数检查，没有启动 app、prep、回归、合成考卷、自测、网络或模型 API，也没有另派 agent。当前不提供 `build-manifest.json`；主代理完成真实新构建后才可创建，不能以旧 `/Applications` 包或合成占位值冒充。

## 实际运行前

1. 主代理创建新的 runner run（`agent_run.py init`），保存完整复测任务、范围与权限。下列命令中的 `GPXPV_AGENT_RUN_DIR` 必须指向**本次实际执行**的绝对 run 目录；不得用旧基线或本次脚本准备 run。日志、状态、截图、偏好快照全部落该 run。
2. 主代理在本目录创建真实 `build-manifest.json`，至少包括绝对 `app` 路径和实际 `Contents/MacOS/GPXPointViewer` 的 `executable_sha256`（64位十六进制）。从真实新构建现算，不在本说明提供可误用的伪造示例。脚本每次进入阶段都会校验路径/二进制 SHA256，拒绝 `/Applications` 及测试副本目录作为源；环境里的旧 `GPXPV_APP` 会被固定新构建覆盖。`copy_app` 复制前重验，复制后再核验可执行文件。
3. 单独检查测试权限与允许命令后执行。只能一个测试副本（`Tests/ui/app.noindex/GPXPointViewer.app`）占用现有 uitest 通信目录，不可并行运行本脚本、另一 UI 客户端或公共路网客户端。保留正式 app；脚本只观察 `/Applications` 进程，不向它发关闭命令。
4. 只有已有离线脚本和假引擎允许执行。禁止 `run_suite.sh`、`--record`、真实公共 OSRM/Valhalla/Overpass 请求、安装或覆盖 `/Applications`。原 DeepSeek 准备调用被拒绝的记录保持不变；用户随后明确授权仅本项目复测所需文件交 DeepSeek 处理，见 `../coordinator/deepseek-data-authorization.md`。本脚本本身不代发模型。

## 执行顺序（供已授权的后续复测使用；本准备任务没有执行）

在项目根目录设置 `GPXPV_AGENT_RUN_DIR` 为新的真实复测 run。每条命令均以 `python3 -u Tools/agents/records/2026-10-28-remediation/r4-final-work/driver.py` 为入口，阶段参数按以下顺序串行传入：

1. `prep`：记录 manifest路径/hash、二进制hash/mtime、`ui.app_source()`、正式进程测前PID、五个字符串（UTF8、UTF16LE/BE、XML/二进制plist）、数据和偏好快照。缺失manifest时清楚报错并退出2，不寻找旧app。
2. `reg 1` 到 `reg 11`：依次为 plausibility、crosscheck、batch_review、batch_card、route_cache、map_sources、tunnel_fix、fill、review、network、profile。逐个保存实际退出码、超时标志、原日志及 `FAILS:`；不能以已派发当通过。也保留 `regs 1 ... 11` 顺序入口，但分阶段更易恢复。
3. `synth`：仅现有 `run_all.sh` 的离线录音回放，保留114/114、125题完整summary（含requests sent 0），不允许改基线或record。
4. `selftests`：四组原自测，仍为8、31、5、7例，逐字/分数阶梯基线保持。
5. `sec2` → `sec3` → `sec4`：双路分歧/标签、一键重新比对、单行取路进度；必须按顺序保留前置状态。标签截图也交主代理看像素。
6. `sec5 zh-Hans`、`sec5 en`、`sec5 de`：三种真实截图与各自 `windows`/`info front=` 证据。也保留 `sec5all` 入口。窗口必须由 `windows` 证明960×800，PNG尺寸只记录；文件名包含当前run和唯一阶段ID，不复用旧run图片。
7. `sec6`：严格保留 `vMinRisk > 50`、Valhalla high/reasons/默认不勾选比例≥95%、OSRM high=0、counts.high=nHigh及候选100。55为合法high，不再写偏差。**本节只检UI分数**；第97项及第84项两个underfill的实际落地重检由主代理新增独立生产测试并另交结果，本脚本不声称覆盖。其他候选、比例、分数、末行、超时基线没有放宽。
8. `docs`：以内容、实际Swift文件清单/数量、Regions文件头与大小、实际run_和suite名单核对；README行号仅记录，不断言160/185。仍要求主app34 Swift、31个run_、suite25个；计数变化必须FAIL并报告，不自动改期望。这里只读取run_suite清单，不执行它。
9. `cleanup`：中途失败也必须安排此阶段。按原流程复位偏好并关闭测试副本，记录偏好差异；测前正式app PID集合必须仍是测后集合的子集。空→空通过；缺少prep证据不冒充空集合。不会关闭正式app。

所有阶段退出码、子进程完整stdout/stderr、argv、开始/结束时间和timeout保存在当前run的 `artifacts/commands.jsonl`、`logs/`；`results/`和`results.jsonl`保存每次阶段结果，`state.json`只索引最新阶段。重跑使用唯一日志/结果/截图/偏好快照，不删除旧失败。总报告按实际命令、实际输出及未做事项交主代理，保留runner的正常事件/审批证据；不得记录环境变量全集或凭据。

`progress PATH` 只接受本工作目录或当前run内的 `.md`（resolve后检查，拒绝旧run或软链接逃逸），替换前保存旧progress快照；此辅助命令不会自动产生runner进度事件，实际调度仍需按AGENTS调用 `agent_run.py event`。

## 最终验收边界

截图存在、PNG非空、窗口尺寸正确均不能证明页脚无裁切。主代理必须逐张看zh-Hans/en/de像素，确认底两行位于操作条上方且完整、无省略号，锁屏/白图不判；同时看双路标签像素。脚本将visual_verdict明确保留为 `PENDING_MAIN_AGENT_PIXEL_REVIEW`。只有这些独立验收及两例underfill回归另交之后，主代理才能评估R4/发布结论。

准备阶段的语法/纯函数检查证据见native run `20261028T235531.920120Z_r4-final-driver-local_d2bf543b`，不能作为R4测试通过的证据。

## 当前验收状态（2026-10-29）

固定构建11组UI已通过且未重跑；恢复run剩余11阶段全断言通过，原CLI provider状态误判与四张锁屏黑图分别保留，不能将自动通过等同完整验收。最新结果、原始证据和未完成条件见[验收报告](../coordinator/completion-report.md)。本README更新不改变driver、构建或原run。

## 最终关闭

第4轮剩余复测与修复已完成；本目录原构建/driver保留。标签新构建定向验收、精确窗口恢复及旧证据继承关系见[最终验收](../coordinator/completion-report.md)。已通过11组未重跑；125题四项既有基线保留。
