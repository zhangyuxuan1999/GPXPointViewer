# DeepSeek 恢复轮最终报告

**Run**：`20261029T210624.045916Z_deepseek-bounded-finish_ecbb20c9`  
**恢复对象**：`20261029T205753.317876Z_deepseek-bounded-fixes_3c79b2ac`（70 turns 上限中断，`error_max_turns`，exit 1，`output.md` 为空）  
**请求模型**：`deepseek-flash` / `max`。服务端实际模型与费用回执 unknown/null；旧 run 的 `$6.082283` 只是 CLI 估价，不是 DeepSeek 实际账单。  
**本轮写入**：仅 `Tests/probes/deepseek-small/run.py`、本 run 的 `progress.md` 与 `artifacts/`；未编辑任何产品/文档文件。

## 结论

- 已补做旧轮从未执行的“抽取生产表达式 → 编译 → 执行”探针。编译 exit 0，运行 exit 0，真实结果 **`RESULT passed=19 failed=0`**。
- 只读静态核对 **18/18 组通过**（N25/N28/N31/N05、chunk_30、关键文档、`screens`、`≈` 作用域、25 suite/临时产物策略等）。
- 未发现需要修改产品的异常。给 root 两项证据/文档发现，见第 6 节；本轮未擅自改产品/文档。
- UI 视觉、德语换行、视频实际导出、完整工程编译、公共路网均未做，留 root 统一验收。

## 1. 旧轮状态与本轮范围

旧轮 `result.json`：`subtype=error_max_turns`、`runner_exit_code=1`、`cleanup_complete=true`、无越界改动；旧 `progress.md` 只完成到“准备写 retest-reason 与探针”，从未创建 `run.py`、没有编译/运行证据。旧 `changes.json` 与旧 after snapshot `status.txt` 一致：**10 modified + 2 added = 12 个旧文件**。本轮补上第 13 个相关文件 `Tests/probes/deepseek-small/run.py`。

原记录：

- 旧 task：`Tools/agents/records/2026-10-29-deepseek-response/deepseek/20261029T205753.317876Z_deepseek-bounded-fixes_3c79b2ac/task.md`
- 旧 result：同目录 `result.json`
- 旧 changes：同目录 `changes.json`
- 旧 after snapshot：同目录 `snapshots/after/status.txt`
- 旧 artifacts：同目录 `artifacts/`（只有 `retest-reason.md`、`before-hashes.txt`）
- 本轮执行前说明：`Tools/agents/records/2026-10-29-deepseek-response/deepseek/20261029T210624.045916Z_deepseek-bounded-finish_ecbb20c9/artifacts/retest-reason.md`

### 13 个相关文件与当前 SHA-256

| # | 文件 | 旧轮状态 | 当前 SHA-256 |
|---|---|---|---|
| 1 | `.gitignore` | modified | `774da2a44de6a683430be224b052bcb524fe2fb44928c99a6744ad97f8535427` |
| 2 | `GPXPointViewer/ContentView.swift` | modified | `a9933edee4dda872c16788810fa9812a517498636f26e4b9433ae8f7ea00b182` |
| 3 | `GPXPointViewer/RoadNetwork.swift` | modified | `49008ea9d1ca43f2cf8eab77ad49bde701cf8b9740d7989b1c352b71090210b8` |
| 4 | `GPXPointViewer/UITestHook.swift` | modified | `06440157a82423a9a60d1ed7f163b6048591c3f921691044340d3e9a95ac721d` |
| 5 | `GPXPointViewer/VideoExport.swift` | modified | `1b83fc339c8548a5e7a37098987dfd89aaba6a8acd259c7ef881825d3691c162` |
| 6 | `GPXQuickLook/PreviewViewController.swift` | modified | `918d34c340533787808cb626973082b1222a939919229de438d32852f4f90f97` |
| 7 | `README.md` | modified | `ba744279edc645aa89261864e33d8feded5047f826ebd7c408fdd839669905fb` |
| 8 | `Tests/README.md` | modified | `961ffae85cc34979c34f8f9c4d8181b3fb128a8a7d0667f2dac3b10fe460adf0` |
| 9 | `docs/cross-check-design.md` | modified | `44fae914f0e2a96280ea15d2c9b143889aa499ec2a4a4d35d723ed885b7bca13` |
| 10 | `docs/fill-plausibility-design.md` | modified | `510139ce42d0307fa909267d8e22c56d5fa1af23691da2b82110ba3625a427ad` |
| 11 | `Tests/l10n/translations/chunk_30.json` | added | `0e68268557a1a4d1ae229c05e4f2756710dbdb65226b3d2d70e4225bf0f9877a` |
| 12 | `Tests/probes/deepseek-small/main.swift` | added | `d76871f73c33fd5a8f422e32c7a9d8e9833ee6e042b072eb8c6b307770f389f4` |
| 13 | `Tests/probes/deepseek-small/run.py` | 本轮新增 | `bb6615173b1de08e5a796e5a7f9e12e3acfbe350c99edc75d2623c10e0e92e16` |

旧 `changes.json` 的 `out_of_scope` 为空。当前工作区由 root/Sol 继续整合；本报告只对上述文件当前内容做静态事实核对，不归属并发改动。

## 2. 探针实现：实际抽取生产源码，不是镜像实现

`Tests/probes/deepseek-small/run.py <证据目录>` 读取实际 `GPXPointViewer/RoadNetwork.swift`：

- `RoadNetwork.swift` 全文 SHA-256：`49008ea9d1ca43f2cf8eab77ad49bde701cf8b9740d7989b1c352b71090210b8`（166173 bytes）。
- `fetchValhalla` 函数范围：第 514–551 行。
- N25 唯一抽取第 542 行：

```swift
return .status(ec == 442 || ec == 170 ? "NoRoute" : (ec == 171 ? "NoSegment" : "Valhalla \(ec) \(err.prefix(60))"))
```

提取表达式原样放入测试函数：

```swift
func valhallaStatus(_ ec: Int, _ err: String) -> String {
    return ec == 442 || ec == 170 ? "NoRoute" : (ec == 171 ? "NoSegment" : "Valhalla \(ec) \(err.prefix(60))")
}
```

- N28 唯一抽取第 1387–1388 行：

```swift
let path = ids.compactMap { coord[$0] }
guard path.count == ids.count, path.count >= 2 else { throw RouteError.noRailPath }
```

原样放入：

```swift
func railPathExcerpt(ids: [Int], coord: [Int: Int]) throws -> [Int] {
    let path = ids.compactMap { coord[$0] }
    guard path.count == ids.count, path.count >= 2 else { throw RouteError.noRailPath }
    return path
}
```

- `run.py` 断言：`fetchValhalla` 唯一、含 `err.prefix(60)` 的 `return .status` 唯一、`err.prefix(60)` 全文唯一、compactMap 行与 guard 行各唯一且相邻、guard 在 `1..<path.count` 和 `ids.first!` 之前；任一断言不满足即拒绝生成/编译。
- 测试用 `RouteError.noRailPath` 只定义在生成的 support 文件中；产品完整 `RouteError` 没有被编译或替换。
- 生成 support：`artifacts/extracted-support.swift`，SHA-256 `1e6a61743e865390a794a0e8130d4582832ab5f1470bd25bb0198a07ed2b790b`。

## 3. 编译与运行：真实退出码与输出

执行命令（argv 完整记录在 `report.json`）：

```sh
/usr/bin/xcrun swiftc -swift-version 5 \
  -module-cache-path <artifacts>/module-cache \
  -Xcc -fmodules-cache-path=<artifacts>/module-cache \
  -o <artifacts>/deepseek-small-probe \
  Tests/probes/deepseek-small/main.swift \
  <artifacts>/extracted-support.swift

<artifacts>/deepseek-small-probe
```

- 编译：**exit 0**，耗时 `0.425794 s`，stderr 为空。
- 运行：**exit 0**，耗时 `0.131032 s`，stderr 为空。
- 真实结果行：**`RESULT passed=19 failed=0`**。
- 19 项逐条真实输出：

```text
PASS N25 442 -> NoRoute
PASS N25 170 -> NoRoute
PASS N25 171 -> NoSegment
PASS N25 172 -> fallback with code and text
PASS N25 unknown 0 -> fallback
PASS N25 negative code -> fallback
PASS N25 long error keeps only 60 characters
PASS N25 long error is not longer than 60 chars
PASS N25 172 is not mapped to NoRoute
PASS N25 172 is not mapped to NoSegment
PASS N25 171 is not mapped to NoRoute
PASS N28 empty ids
PASS N28 single id
PASS N28 missing middle coordinate
PASS N28 missing first coordinate
PASS N28 missing last coordinate
PASS N28 empty ids but non-empty coord
PASS N28 normal chain unchanged
PASS N28 normal chain preserves ids order
RESULT passed=19 failed=0
```

期望值来自 Valhalla 官方合同与 Sol/issues 记录：170 `OSRM_NO_ROUTE`、171 `OSRM_NO_SEGMENT`、172 `OSRM_BREAKAGE_EXCEEDED`（保留 fallback，不猜成 NoRoute/NoSegment）、442 按官方异常实现归 NoRoute；不是拿产品实现自身当真理。

**第一次运行的测试脚本自身计数 bug**：探针本身第一次已是 19/0、编译/运行均 exit 0；但静态计数 check 把 helper 与 catch 兜底 `check(` 也计入，报 `22≠19`。原始报告已保留为 `artifacts/report.firstrun-static-count-bug.json`；修正计数逻辑后重跑，最终报告一致。该失败是测试脚本计数问题，不是产品失败。

## 4. 静态只读核对：18/18 通过

| 检查 | 结果 | 关键事实 |
|---|---|---|
| `N25_status_mapping` | PASS（5 断言） | 442/170→NoRoute，171→NoSegment，其它保留 `Valhalla \(ec) \(err.prefix(60))`；旧的 442/171→NoRoute、170/442→NoSegment 均不存在 |
| `N28_rail_path_guard` | PASS（5 断言） | 第 1388 行 guard 紧跟在 compactMap 后，且在 `1..<path.count` 与 `ids.first!` 前；两行各唯一 |
| `N31_screens_single_branch` | PASS（3 断言） | `case "screens"` 仅 1 个；保留 `frame=… visible=…` 原协议；无 enumerated 重复分支 |
| `N05_fwdb_only_ui` | PASS（9 断言） | 说明键存在；视频导出 sheet 仅 `fwdbMode` 显示说明，430 宽保留；`Text(verbatim: "≈")` 只在 `store.fwdbActive` 回放块；GPX else 分支无 ≈/说明且保留日期与 `frame(width:108)`；时光机 help fwdb/GPX 分流 |
| `N05_video_ribbon_archive_only` | PASS（3 断言） | 仅 `cfg.archive != nil ? "≈ " + ribbonDate : ribbonDate`；`"≈ "` 字面量全文恰 1 处；无无条件的 `date: "≈ " + ribbonDate` |
| `chunk30_exactly_two_entries_three_languages` | PASS（4 断言） | 恰 2 个对象；键/comment/en/de/zh-Hant 与规定逐字一致；仅 6 个字段；三语非空 |
| `doc_quicklook_32mb` | PASS（3 断言） | 顶部注释 >32MB；常量 `32 * 1024 * 1024`；旧 `>48MB` 不存在 |
| `doc_crosscheck_history` | PASS（4 断言） | 旧三条标为 2026-10-25 历史并指向 2026-10-28 已实现；写明屏幕弧长中点，不是“最远处” |
| `doc_fill_plausibility_tunnel_share` | PASS（7 断言） | `nil = 未知，不扣分`、`有 intersections 无 classes = 0`、`tunnelShare ≥ 0.5`、`tunnelSnapWaiveMax`、线上 classes 未验证 caveat；旧“本期恒nil/本期不扣分”不存在 |
| `readme_multi_window_export` | PASS（7 断言） | 多窗口共享同一 `TrackStore`/数据/编辑会话，不声称 UI 状态全同步；`_GPVexported` 递增、重新导入才递增、不探测目标目录重名、保存面板确认覆盖；与 `TrackStore.exportedFileName` 实现一致 |
| `readme_performance_scope` | PASS（11 断言） | “性能口径”历史 M4/优化构建、非可复现 benchmark、p50/p95、峰值 RSS、自动抽稀状态；“接近全速”“满帧”均为有条件历史观察；无“500万依然流畅/始终满帧” |
| `readme_builds_manifest` | PASS（5 断言） | `Builds/<UTC 秒>_<UUID>/`、`archive/build-manifest.json`、显式 `GPXPV_APP`；不再自动回退 DerivedData/`/Applications` |
| `readme_fwdb_approx_explanation` | PASS（4 断言） | 回放条与视频丝带标 `≈`；GPX 用真实记录时间；说明 mtime 可能被复制/恢复/同步改写 |
| `tests_readme_suites_and_artifacts` | PASS（9 断言） | 25 个 suite 脚本；`run_regions_stats_tests.py` 不在其中；唯一 `suite.log` + `suite.json`；非零规则；Builds/manifest/GPXPV_APP；不依赖 DerivedData 自动回退 |
| `tests_readme_temp_artifact_policy` | PASS（4 断言） | 3.4GB 为历史观察非实时测量；旧 tmp 不删；禁止 `gpxpv-*` 全局通配；失败证据保留 |
| `gitignore_builds` | PASS（1 断言） | `Builds/` 在 `.gitignore` |
| `old_changes_files_exist` | PASS（3 断言） | 旧 `changes.json` 可读，12 个旧文件全部存在 |
| `main_swift_expected_19_checks` | PASS（4 断言） | 7 个 `expectStatus` + 6 个 `expectNoRailPath` + 6 个直接积极检查 = 19 |

静态检查只证明文本/结构事实，不等价于 UI 视觉或运行期全工程验证。

## 5. N 项核对结论（继承旧轮修复）

| 项 | 结论 |
|---|---|
| N25 | 静态映射正确；探针 11 项 N25 检查全 PASS（170/442/171/172/未知/负数/60 字符截断/172 不误映射） |
| N28 | guard 已在实际生产位置；探针 8 项 N28 检查全 PASS（空/单/缺中间/缺首/缺尾拒绝，正常链保序） |
| N31 | `screens` 只剩一个原协议分支，无重复 enumerated 分支 |
| N05 | fwdb 才加 `≈` 与完整说明；普通 GPX 回放/视频日期不加；时间算法未改 |
| 本地化 | `chunk_30.json` 恰两条新键、三语齐全且逐字符合 |
| 文档 | QuickLook 32MB、cross-check 历史说明、fill-plausibility §7、README 多窗口/导出/性能/Builds/fwdb、Tests README 25 suite/产物策略、`.gitignore` Builds/ 均已核对通过 |

## 6. 给 root 的发现（未擅自修改）

1. **探针 README 缺失（文档引用不一致）**  
   `Tests/README.md:418` 称 `Tests/probes/deepseek-small/` “有自己的 README 与 `run.py`”。实际目录只有 `main.swift` 与本轮新增 `run.py`，没有 `README.md`。本轮权限只允许写 `run.py`，未创建/修改文档。请 root 决定补 `Tests/probes/deepseek-small/README.md`，或改 `Tests/README.md:418` 的表述。

2. **旧轮“13 文件”与证据数量差异**  
   任务书称旧轮 13 文件；旧 `changes.json` 与旧 after snapshot 均为 12（10 modified + 2 added）。未在旧记录找到第 13 个旧改动；本轮补 `run.py` 后相关路径共 13 个。若第 13 个指的是 `Tests/README.md:418` 所称的探针 README，则该文件确实缺失，见发现 1。

3. **未发现产品异常需修**  
   N25/N28/N31/N05 与本地化、文档静态核对均通过；没有发现需要本轮改产品代码或改测试期望的问题。

## 7. 范围与明确未测项

未做且不计划做：

- `xcodebuild`、完整工程编译、Release/Debug 构建、归档；
- UI 脚本、截图、真实视觉、德语多行换行、视频实际导出与播放；
- 公共路网/任何网络请求（因此也不存在公共路由多客户端问题；本轮全程离线）；
- 安装、启动或关闭 app；
- N19、Sol 的 34 项、CPU 19/GPU 51 或旧 UI 回归；
- git commit/push/reset、清理旧文件。

完整工程编译与 UI/视频视觉验收留 root 统一完成。

## 8. 证据位置

本 run 目录：

`Tools/agents/records/2026-10-29-deepseek-response/deepseek/20261029T210624.045916Z_deepseek-bounded-finish_ecbb20c9/`

- `artifacts/report.json`：完整源码 hash、提取文本、support hash、compile/run argv/stdout/stderr/真实 exit、18 组静态检查、13 文件 hash、旧 changes 清单、findings。
- `artifacts/retest-reason.md`：执行前范围与原因。
- `artifacts/extracted-support.swift`：实际抽取的生产表达式/两行生成的 support。
- `artifacts/compile.stdout.txt`、`artifacts/compile.stderr.txt`
- `artifacts/run.stdout.txt`（19 项 PASS）、`artifacts/run.stderr.txt`
- `artifacts/report.firstrun-static-count-bug.json`：首次运行原始报告（探针 19/0，仅脚本计数 bug）。
- `progress.md`：已完成/正在做/下一步与中间结果。

全量 events 由 runner 保存。