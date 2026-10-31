# 测试说明（Tests/）

**一句话**：这里是 GPXPointViewer 的全部测试工具。真 app 的界面回归（`ui/`）、引擎检测器的合成数据回归（`synth/`）、单独排查用的离线探针（`probes/`）、四语本地化流水线（`l10n/`）。

> 第一次来先看「0. 速查」和「必读规则」，其余按需查。所有命令默认**在项目根目录** `/Users/zyx/Documents/GPXPointViewer` 下执行。

---

## 0. 速查

```sh
cd /Users/zyx/Documents/GPXPointViewer

# 构建并归档（UI 测试用脚本打印的 app；项目 Builds/<RUN>/archive/ 存 durable ZIP 与记录；保留工程签名）
python3 Tools/build_release.py --arch arm64

# 合成数据回归（第一次要加 REGEN=1 生成数据）
REGEN=1 Tests/synth/runner/run_all.sh      # 生成约 140 MB 数据 + 检查
Tests/synth/runner/run_all.sh              # 以后：复用数据，只编译 + 检查（约 40 秒）

# UI 回归（显式指定归档；不要依赖 DerivedData 自动回退）
Tests/ui/setup_data.sh                     # 只需一次：把测试轨迹拷进 app 沙盒（另有 3 个文件它不拷，见 2.3）
GPXPV_APP=/ABS/APP_FROM_BUILD/GPXPointViewer.app Tests/ui/run_suite.sh   # 全套，约 40 分钟，会占用屏幕
```

## 必读规则

1. **公共路网服务一次只允许一个客户端。** OSRM（routing.openstreetmap.de）、Valhalla（valhalla1.openstreetmap.de）、Overpass 都是公共免费服务。两个客户端同时请求会被限流（HTTP 429），然后整个 IP 被拒绝连接几分钟。所以：
   - 不要并行跑两个联网的 `run_*.py`；
   - UI 测试跑着的时候，不要再跑联网探针（routeprobe 等）；
   - 不要同时开两个测试副本，也别在测试时用正式 app 跑批量补点。
2. **不要为了让测试变绿去改期望值。** `synth/*/expect.json` 是"标准答案"，改它要按第 4 节的流程走，并写明理由。
3. **抽键结果不要输出到 `l10n/translations/`**，那里是已翻译好的块，会被空壳覆盖（见第 6 节）。
4. **验收通过后按 AGENTS.md 的持续授权覆盖安装；先保存编辑并正常退出所有实例，签名与可安装性验证见 2.2 和第 7 节。**
5. UI 测试会把测试窗口拉到最前面、抢键盘焦点。全套约 40 分钟，期间这台 Mac 最好别干别的。

---

## 1. 目录结构

```
Tests/
├── README.md            ← 本文件
├── .gitignore           ← 生成数据、编译产物、测试副本都不进 git
├── ui/                  ← 真 app 界面回归（通过 app 内置的自测钩子驱动）
│   ├── ui.py            ←   驱动：往沙盒里写命令文件、读结果；app_source() 决定测哪份 app
│   ├── run_suite.sh     ←   全套：重启测试副本 + 顺序跑 25 个脚本 + 汇总
│   ├── setup_data.sh    ←   把 data/ 里的轨迹拷进 app 沙盒（只需一次）
│   ├── run_*.py         ←   各个测试 / 诊断脚本（见第 3 节表格）
│   ├── GPXPointViewer.app  （运行时生成：测试副本，git 忽略）
│   └── perf/               （运行时生成：全套日志、性能采样、截图，git 忽略）
├── synth/               ← 合成数据回归（不开 app，直接编译引擎源码）
│   ├── <6 个数据族>/     ←   每族 gen.py（生成器）+ expect.json（标准答案）
│   └── runner/          ←   main.swift（synthrunner）+ check.py + run_all.sh
├── segments/            ← 显式源段、编辑与渲染回归（实际生产 Swift/Metal）
│   ├── core/            ←   解析/拓扑/写出及窗口外 Quick Look 像素检查
│   ├── render/          ←   离屏 Metal、原 shader 反例、颜色资源所有权与规模诊断
│   └── workflow/        ←   实际 TrackStore、交叠段编辑/还原、异步失效与补点覆盖
├── agents/              ← 调用与留档工具的离线 fixture 回归，不请求模型供应商
├── probes/              ← 离线探针（历史排查工具，每个目录一个 main.swift）
└── l10n/                ← 本地化：RULES.md（规则 + 术语表）、extract_keys.py、assemble.py、translations/
```

---

## 2. 跑之前要准备什么

### 2.1 工具

- Xcode 命令行工具（`xcodebuild`、`swiftc`）和系统自带的 `python3`。**不需要装任何 pip 包**，所有 Python 脚本只用标准库。

### 2.2 构建 Release 并归档

UI 测试必须测一份**带构建归属**的归档，不再从 DerivedData 或 `/Applications` 自动挑 app。

```sh
# 构建 Release；保留工程签名；保存完整命令/退出码/build.log/构建前后输入 SHA manifest。
# 正常构建把可运行 app 与相邻 build-manifest 留在 iCloud 外的唯一本地暂存目录；durable ZIP 与记录在项目 Builds/<RUN>/archive/。
python3 Tools/build_release.py --arch arm64

# 验证构建打印的 app 与构建清单
python3 Tools/archive_build.py /ABS/APP_FROM_BUILD/GPXPointViewer.app --validate
```

失败产物保留、不安装、不启动、不删除。`Tools/build_release.py` 正常构建会把可运行的已签名 app 与相邻的 `build-manifest.json` 留在 iCloud 之外的唯一本地暂存目录，并在项目 `Builds/<RUN>/archive/` 保存 durable ZIP、manifest、proof 与 paths 记录；脚本会打印实际的 `app`、`manifest`、`durable_zip`、`durable_manifest` 路径，下文 `/ABS/APP_FROM_BUILD/…` 都应替换为打印值，UI 测试、验证与安装使用打印的 app/manifest，不要假设项目内存在 `archive/GPXPointViewer.app`。历史 bundle 用 `python3 Tools/archive_build.py /ABS/OLD/GPXPointViewer.app` 归档到新的 `Builds/TIME_historical_UUID/`；它不冒称匹配当前源码。签名、安装与回滚见 [docs/local-install-signing.md](../docs/local-install-signing.md)。

构建默认保留工程三个 target 的签名配置（主 App、Quick Look、Thumbnail 各自的 entitlement，本地 ad-hoc）。`--no-sign` 只用于明确的研发／诊断；该 manifest 标记 `installable=false`，不能作为正式安装包，也不能作为默认正式安装示例。是否可安装由 `python3 Tools/archive_build.py /ABS/APP_FROM_BUILD/GPXPointViewer.app --validate --for-install` 与安装器对三个 bundle 的 `codesign --verify --strict`、bundle ID、实际 entitlement、CDHash 校验共同决定。验收后的已授权安装命令见第 7 节；完整签名、备份与回滚说明见 [docs/local-install-signing.md](../docs/local-install-signing.md)。

**UI 测试测的是哪份 app？**

1. 必须显式设置 `GPXPV_APP=/ABS/APP_FROM_BUILD/GPXPointViewer.app`（单脚本或 `run_suite.sh` 都一样）；
2. 需要时再设 `GPXPV_BUILD_MANIFEST=/ABS/APP_FROM_BUILD/build-manifest.json`；
3. `ui.app_source()` / `run_suite.sh` 会先校验完整 bundle 与当前源码/资源/工程输入 SHA，**通过后才**停止或覆盖测试副本；没有 manifest、源码变化或 bundle 变化都会拒绝；
4. 诊断旧版本只能显式 `GPXPV_ALLOW_UNVERIFIED_BUILD=1 GPXPV_APP=/ABS/OLD/GPXPointViewer.app ...`，会打印 `UNVERIFIED_EXPLICIT_OVERRIDE` 和 binary SHA，结果不得归属当前源码。

没有自动回退 DerivedData 或 `/Applications` 的路径，也不以文件 mtime 证明源码归属。脚本第一行仍会打印 `testing <路径>` 和 `BUILD_PROVENANCE`，测新代码时必须是刚验证过的归档。

### 2.3 把测试轨迹拷进 app 沙盒（只需一次）

app 开了沙盒，只能读自己容器里的文件，所以测试用的轨迹要先拷到：

```
~/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/
```

这个目录同时也是钩子的通信目录。

```sh
Tests/ui/setup_data.sh
```

它从项目的 `data/` 目录（不进 git）拷 6 个文件，缺哪个会打印「缺」：

| 容器里的名字 | 来源 `data/…` |
|---|---|
| Garmin_Roma_Da.gpx | Garmin_Roma_Da.gpx |
| RE1.gpx | 20260326_KoblenzHBF_TrierHBF_RE1.gpx |
| RE11.gpx | 20260326_TrierHBF_Luxembourg_RE11.gpx（目前没有脚本用它） |
| 2026.csv | 2026.01.01-2026.12.31.csv |
| backup2026.gpx | backUpData-2026.gpx |
| backupall.gpx | backUpData-all 6.gpx（483 MB） |

`setup_data.sh` 一共拷 9 个文件：上面 6 个，加上 `Garmin_Roma_Da_copy.gpx`（行程类测试）、`stepLife.csv`（来自 `data/backUpData-all 5/backUpData-all 5.csv`，171 MB，画像测试）、`stepLife2026.csv`（来自 `data/2026.01.01-2026.12.31.csv`，成因/依据测试）。data/ 里缺哪个，它会打印「缺」并跳过，用到那个文件的测试会失败。

以后如果脚本报找不到文件，再跑一次 `setup_data.sh` 就行。

### 2.4 屏幕与环境

- **屏幕要解锁、亮着，别合盖、别锁屏。** 锁屏时 macOS 会把窗口当成"不可见"：地图不重绘，拖动、右键类的步骤会失败，窗口截图是全白的。
- 测试会把测试窗口拉到最前面并抢焦点。有的脚本用 `place 0` 把窗口放到主屏中央；有的用 `frame 1320 -740 1320 860` 把窗口挪到屏幕外（只露右下角一点），免得挡住你。
- `run_dock_tests.py` 要求主窗口完整地在屏幕内，而且是按 **1440×932 的内建屏幕**写的（期望坐标写死，比如 `批量补点: x=470 y=61`）。换了显示器，这个脚本可能失败。

### 2.5 "测试副本"是什么

UI 测试不碰你平时用的那份 app。它会：

1. 把已通过 manifest/输入 SHA 校验的 `GPXPV_APP` 归档复制到 `Tests/ui/app.noindex/GPXPointViewer.app`；
2. 用 `open -n --env GPXPV_UITEST_DIR=<容器通信目录> … --args -AppleLanguages '(zh-Hans)'` 启动这份副本。

几点说明：

- **钉死简体中文**：钩子按中文文字找按钮（「替换」「保留」「回放点」），脚本也断言中文文案，换成别的语言就会失败。
- **和正式版共用设置**：测试副本和 /Applications 那份 bundle id 相同，所以共用同一个沙盒容器和偏好设置。
- **只开一个**：同一时间只能有一个测试副本，因为大家共用同一个通信目录。

> 小提示：`Tests/ui/app.noindex/GPXPointViewer.app` 在「文稿」目录里，Spotlight 可能把它当成第二个同名 app。测完不需要了可以 `rm -rf Tests/ui/app.noindex/GPXPointViewer.app`，下次跑全套会重新拷。

---

## 3. UI 回归（`Tests/ui/`）

### 3.1 原理（一段话）

app 以环境变量 `GPXPV_UITEST_DIR` 启动时，会每 0.12 秒查看通信目录里的 `cmd` 文件，每行一条命令，执行后把结果写进 `out.txt`。完整命令清单见 `GPXPointViewer/UITestHook.swift` 里的 `run(_:_:)`，常用的有：

- `open <路径>`、`fill`、`select <i>`、`apply`、`confirm replace`、`undo`
- `route car|rail`、`batchplan` / `batchrun` / `batchclose`、`review*`
- 地区统计：`regions`（开窗口）、`regionsmode points|fog`、`regionstate`（JSON）、`regionselect <id>|off`、`regionlookup <lat> <lon>`、`fogstats`；`set fogMap|heatMap 0/1`。`open` 对 `.fwdb` 目录会走存档导入。换边界数据：启动时加 `--env GPXPV_REGIONS_BIN=<容器里的 .bin>`
- `state`（返回 JSON 状态）、`windows`、`place` / `frame` / `front`
- `click` / `drag x y …`、`shotview <png>`、`sleep <毫秒>`

鼠标事件是投进 app 自己的事件队列的，不需要辅助功能权限。

没有这个环境变量时，钩子完全不启用。`ui.py` 就是"写命令、等结果"的小驱动，也能手动用（每个参数一行命令）：

```sh
python3 Tests/ui/ui.py state                       # 测试副本在跑就会返回一行 JSON；不在跑则 20 秒后打印 TIMEOUT
python3 Tests/ui/ui.py "open $HOME/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest/Garmin_Roma_Da.gpx" "fill"
```

app 端的日志在通信目录里的 `log.txt`。

### 3.2 跑全套

```sh
GPXPV_APP=/ABS/APP_FROM_BUILD/GPXPointViewer.app Tests/ui/run_suite.sh
# 可选：GPXPV_BUILD_MANIFEST=/ABS/APP_FROM_BUILD/build-manifest.json
```

它做的事：

1. 先校验显式指定的归档（完整 bundle + 当前源码/资源/工程输入 SHA），**通过后才**关掉旧测试副本（只关 `Tests/ui/app.noindex/GPXPointViewer.app`，不碰正式版）；
2. 重新复制、以中文启动测试副本，最多等 60 秒，等到会打印 `app up`；启动失败也会保留日志和 JSON；
3. **按固定顺序一个接一个**跑 25 个 suite 脚本（联网的不会并行），每个最多 40 分钟，超时记 `TIMEOUT`；`run_regions_stats_tests.py` 不在 suite 内，见 3.6；
4. 输出写入唯一目录 `Tests/ui/perf/suite_YYYYMMDDTHHMMSSZ_RANDOM/suite.log`，旁边 `suite.json` 保存启动归属、每脚本真实 `exit_code`、`FAILS` 汇总与状态；最后打印 `SUITE_RESULT` / `===== SUMMARY`。

**非零规则**：任一脚本非零退出、任一非 `none` 的 `FAILS`、或非诊断脚本缺少 `FAILS` 行，都会使 suite 非零；`run_drift_tests.py` 明确记为 diagnostic，不冒充通过。失败/启动错误日志只追加到新目录，旧失败不会被覆盖。旧记录没有完整锁定构建归属时，不能追认成当前源码的结果。

全套约 **35–40 分钟**，大头是 run_rail_tests（约 16–18 分钟）和 run_jitter_tests（约 10–11 分钟）。中途有脚本失败也会继续往下跑。

### 3.3 跑单个脚本

大多数脚本**假设测试副本已经在运行**，自己不会启动 app。所以先启动测试副本，再跑脚本。启动前必须先按 2.2 设置 `GPXPV_APP`（可选 `GPXPV_BUILD_MANIFEST`）；`ui.app_source()` 会校验归档归属，不再自动回退。下面这段和 `run_suite.sh` 开头的启动代码同一思路：

```sh
cd /Users/zyx/Documents/GPXPointViewer/Tests/ui
python3 - <<'PY'
import subprocess, shutil, os, time, ui
SP = os.path.dirname(os.path.abspath("ui.py")); C = os.environ["HOME"] + "/Library/Containers/de.wayne.GPXPointViewer/Data/tmp/uitest"
subprocess.run(["pkill", "-f", SP + "/GPXPointViewer.app"], capture_output=True); time.sleep(1.5)
src = ui.app_source(); print("testing", src)
dst = SP + "/GPXPointViewer.app"
if os.path.exists(dst): shutil.rmtree(dst)
shutil.copytree(src, dst, symlinks=True)
subprocess.run(["open", "-n", "--env", "GPXPV_UITEST_DIR=" + C, dst, "--args", "-AppleLanguages", "(zh-Hans)"], check=True)
for _ in range(60):
    time.sleep(1)
    if "points" in ui.state(): print("app up"); break
PY
python3 run_fill_tests.py          # 换成你要跑的脚本
```

以下脚本**会自己重启测试副本**，不用先启动：

- `run_jitter_tests.py`（中文）
- `run_lang_smoke.py`（指定语言）
- `run_perf_probe.py`（中文）
- `run_regions_stats_tests.py`（中文；地区统计：自带合成边界 + 合成轨迹，跑完会关掉副本）

离线探针 `Tests/probes/regions/run.sh`（swiftc 编 RegionIndex/RegionStats，约 20 秒）：点归属与浮点参考逐点一致、单元缓存与逐点一致、飞地/窄条/小岛/凸出/日界线/微型国/跨国格、迷雾面积守恒、夏令时天数；改了这两个文件必跑。

> ⚠️ `run_lang_smoke.py en` 之类跑完后，测试副本停在那个语言。之后再跑别的脚本前，要用上面那段重新启动中文副本，否则 `confirm` 会报 `button not found`。

### 3.4 怎么看结果

每个检查打印一行 `    ok   <说明>` 或 `    FAIL <说明>`，脚本最后打印一行：

- `FAILS: none`：全部通过；
- `FAILS: ['T7 拖锚点 B …', …]`：列出失败的检查项。

全套的 SUMMARY 会列出每个脚本的 `#####` 开头行、`FAILS:` 行、`exit=` 行和 `Traceback`；同一目录的 `suite.json` 是机器可读结果（启动归属、每脚本真实 `exit_code`、`FAILS` 汇总、整体状态）。

- **以 `FAILS:` 行为准，不要只看 exit 码。** 有 8 个脚本失败时也是 exit 0：dock、trip、region、profile、nature、route_notes、parallel、tripmap。
- **没有 `FAILS:` 行、却有 `Traceback`**：脚本中途崩了。最常见的原因是 app 没在跑，`state` 返回 TIMEOUT，然后取字段时报 KeyError。
- `run_drift_tests.py` 本来就不打印 `FAILS:` 行（它是诊断表，见 3.7）。
- `run_jitter_tests.py` 可能打印 `SKIP J2a/J2d`：公共服务 20 分钟内没跑完，落地断言被跳过，不算失败。

**联网测试失败 ≠ 代码回归。** 公共服务限流、排队都会让联网测试失败（2026-10-24 的两次全量里，run_route_tests 的 R8c、run_rail_tests 的 R2、run_network_tests 的 N1/N2 都出现过）。判断方法：

1. 单独再跑一次；
2. 还不行就做 A/B：显式 `GPXPV_ALLOW_UNVERIFIED_BUILD=1 GPXPV_APP=/Applications/GPXPointViewer.app` 启动旧版（同一时间只开一个），跑同一个脚本；结果不归属当前源码。旧版也失败，就不是这次改坏的。

### 3.5 联网纪律（再强调一次）

- 「联网」列写「是」的脚本会请求公共 OSRM / Valhalla / Overpass。**一次只跑一个**，绝不并行。
- 「后台」的意思是：脚本里调用了 `batchplan`，app 进入批量时会**自动**去 Overpass 查行程是铁路还是公路。脚本不等结果，但请求确实发出去了，也算一个客户端。
- 联网探针（第 5 节）和 UI 测试不要同时跑。
- **精确模式（两路交叉验证）的测试一律用假引擎**：先 `python3 Tests/ui/ui.py "fakeroute all ok"`（或 `fakeroute valhalla offset 30` 等）再 `batchrun`，整条链路不出网；
  `fakeroute <osrm|valhalla|all> <ok|offset <米>|noroute|fail|slow <毫秒>|off>`，`crosstol <米>|off` 覆盖比对容差，`crosscheck 0|1` 是持久化开关（与 /Applications 的 app 共用，**测完必须 `crosscheck 0` + `fakeroute all off`**）。
  真实两路请求的在线验证只由 Claude 跑（`run_crosscheck_online.py`，约 16 处、34 个请求）。
  **`batchplan` 会自动查 Overpass 判段（真实联网）**：要彻底离线，启动副本后先 `autotripmap 0`（`run_crosscheck_tests.py` 已自带）。`batchreview`（批量第 3 步 → 修改记录窗口预览模式）、`reviewinclude <i> 0|1`（预览里第 i 处落不落地）、`reviewmap standard|imagery|hybrid [light 0|1]`（审阅底图）、`toastdismiss`、`routedump <容器内路径>`（当前单处草稿 + 两路草稿坐标/依据写成 JSON）、`set mapStyle 标准|卫星|混合`、`set mapOpacity x`；`reviewstate` 多了 `preview/mapStyle/light`，每条 `changes[]` 多了 `included/pending/straight/drafts/cross/warnings`；`state` 根多了 `toast`。需要"已有副本在跑"的脚本（run_review_tests / run_network_tests / run_profile_tests）要**各自用新起的副本**跑：在同一副本里接连跑它们，前一个留下的状态会让后一个误报（2026-10-26 run_profile_tests 的 P4/P5 就是这样）。（2026-10-28 起 run_profile_tests 已改为等重算完成，接在别人后面跑也可以；其它两个仍建议新起副本。）锁屏时 MapKit 不加载瓦片，run_map_sources_tests 的 M1c 会假失败，先确认屏幕已解锁。`fillpoints 0|1` 开关「显示补的点」（state 里 `showPoints`/`previewPoints`）。
  **落地前自检（FillPlausibility，2026-10-27，设计 `docs/fill-plausibility-design.md`）**：`state.batch.items[]` 每项多了 `risk`（0–100，无评估 null）、`riskLevel`（`low|medium|high`|null）、`riskReasons[]`；`state.batch.counts` 多了 `high`/`medium`；根 `route` 多了同样三个字段（手改过顶点后为 null）；`reviewstate.changes[]` 多了 `risk`/`riskLevel`。钩子 `riskthreshold <n>|off`：临时改 high 门槛（分 > n 为 high；默认 50），已有批次不重算，`batchrefetch all` 重评；`replay <录音目录>|off`：公路引擎的 HTTP 按考卷录音回放（不出网）。假引擎 `fakeroute … offset <m>` 的草稿把直弦当「路网原始折线」，所以 offset 30 会让该项 risk 升到 high（补点离路网 30 m），`ok` 为 low。high 的项默认不勾选落地。离线脚本 `run_plausibility_tests.py`。
  **自检界面 / 界面待办（2026-10-27 Opus）**：`batchriskonly 0|1`（批量表格「只看要看一眼的」= medium + high，与只看有疑点的/只看要你选的互斥；回显 `visible=N`）；`state.batch` 多了 `riskOnly`/`warnedOnly`/`conflictOnly`/`visibleCount`（表格实际列出的行数，过滤为空时回全表）与 `cardContentHeight`（单处卡片内容实测高度，窗口高 = 它 + 标题栏）；`reviewfollow 0|1`（修改记录详细页「主地图跟随」，偏好 `reviewFollowMap`，开着时 `reviewnext/prev` 后自动 `reviewgoto`；**测完要 `reviewfollow 0`**），`reviewstate.followMap`；`reviewstate.changes[]` 多了 `riskReasons[]`；`riskpopover 1|0`（打开/关上单处卡片或补点操作条上的徽标弹窗）；`shotwin +<标题> <png>`（标题前加 + 时连同本 app 打开着的 popover 小窗一起截，只截本进程窗口）。截图脚本 `shots_plausibility_ui.py <zh-Hans|en|de> [main|batch|all]`（不判通过/失败，存 `Tests/reports/plausibility_ui_shots/`）。
  **延后项收尾（2026-10-28 loose-ends）**：`state.batch.lineLabels`（等你选的两路线上实际画出的引擎名标签数；线在屏幕上 <90 pt 不标，缩小到看不清时为 0）；`batchrecross all|<i>`（只对「只有一路结果」的项两路忽略缓存重取，返回 `started=true/false` 或 `started=N`；不是 unverified 的项不动）；根多了 `routeProgressDetail`（单处交叉验证时引擎细节进度，悬停提示用）、`crossLegs`（`[OSRM, Valhalla]`：0 取路中 1 有结果 2 没有结果；`routeProgress` 此时是合成的一行「OSRM ✓ · Valhalla 取路中…」）、`netRequests`（RateLimiter 全局请求计数——`replay` 回放与假引擎外的真实 HTTP 才会涨；假引擎也计数）、`replayHits` / `replayMisses`（RouteReplay 回放命中/未命中）。`replay` 的录音目录必须在沙盒容器里（run_plausibility_tests R1 把 `Tests/exam/recordings` 拷到 `tmp/uitest/exam_recordings`）。离线自测 `synthrunner --tunnel-selftest`（OSRM intersections.classes → tunnelShare，5 例）。
  **路网结果缓存 / 重新获取 / 两路切换（2026-10-26）**：`routecache stats`（返回 `entries=N hits=M`）/ `routecache clear`；`batchrefetch all`（忽略缓存重跑第 2 步）/ `batchrefetch <i>`（只重取第 i 项）；`routerefetch`（单处按当前来源忽略缓存重取）；`reviewdraft osrm|valhalla|next|default`（修改记录详细页显示哪一份）。`state.batch` 多了 `cacheHits`，根多了 `routeCache{entries,hits}`；`reviewstate` 多了 `shownDraft`（RouteSource rawValue）与 `sameGeometry`。假引擎 `fakeroute` 的请求也按主机计入 `requestsByHost`，所以能用它证明"命中缓存时没再请求"；每次 `fakeroute …` 都会顺手清空路网缓存（换假模式 = 换服务器，否则同样输入会命中上一种模式的草稿，run_crosscheck_tests 的 B 段就会全部"一致"）。离线脚本 `run_route_cache_tests.py`（自己起副本，约 4 分钟）。
  **单处卡片 / 在主地图上看（2026-10-27）**：`batchcompact 0|1`（折叠时没选中项会先选第一处，等价点第一行）、`closebatchwin`（= 点批量窗口红色关闭按钮，批次留着）、`resizewin <标题子串> <宽> <高>`（保持左上角改外框）；`state.batch` 多了 `windowSize`（`[宽, 高]` 整数，外框含标题栏；窗口没开为 null）与 `dock`（停靠诊断）。`reviewgoto`（= 修改记录详细页「在主地图上看」，需已 `reviewselect`）；`reviewstate` 多了 `mainMapCenter:[lat,lon]`、`mainMapSpanKm`。主窗口候选列表 `select <i>` 在批次预览阶段会选中批次里那处并折叠成卡片。离线脚本 `run_batch_card_tests.py`（自己起副本，约 2 分钟；`KEEP=1` 跑完不关副本）。
  **隧道补点修正（2026-10-26）**：`pointat <i>`（第 i 个点的 `{index,time,lat,lon}`，time = Unix 秒）、`pointfind <lat> <lon>`（最近点的 `index/time/dist`）；`state` 多了 `promptInsert`（确认框「替换」插入的合成点数）/ `promptRetimed`（改时点数）；`reviewstate` 的 `changes[]` 多了 `retimed`，且 `added`/`removed` 改为净值（不含改时点的新/旧点）。候选数因「短断档门槛 V1」变化：Muenchen_Roma_Garmin 44→50、Garmin_Roma_Da 97→100（run_profile_tests P2 已改）；staleClock 候选的 A 可能因「冻结外推链」前移（`state.anchorA` 比老值小 3–6）。`relaunch` 钩子重开的实例通过容器 tmp 的交接文件拿到钩子目录（环境变量和 `-AppleLanguages` 等启动参数会被系统剥掉，存储的语言偏好仍生效）。
  **多来源底图 / OSM 隧道叠加层（2026-10-26，`docs/map-sources.md`）**：`set mapStyle 标准|卫星|混合|OpenStreetMap|OpenTopoMap|Esri 影像`（也认 standard/imagery/hybrid/osm/topo/esri）；`reviewmap standard|imagery|hybrid|osm|topo|esri [light 0|1]`；`faketiles 0|1`（瓦片不出网、返回画着 z/x/y 的假 PNG，开时清零 `tileRequests`；**自测副本启动即为 1**）；`tunnels 0|1`（偏好 `tunnelOverlay`）；`faketunnels <n>`（注入 n 条视野内合成隧道，0 关）；`tunnelrefresh`；`mapgoto <lat> <lon> <km>`（主地图视野置中）；`mapnotice [0|1]`（读/写「一次性说明已弹过」偏好，脚本结束要还原）；`tunnelnet 0|1`（**自测副本默认不让隧道层出网**：没有 faketunnels 时状态为 failed + "network disabled"；只在人工验证时 `tunnelnet 1`，一次一个客户端）。`state` 多了 `baseMap`（rawValue）、`tileRequests`、`fakeTiles`、`attribution`（外部来源的署名，Apple 为 null）、`tunnelOverlay{on,ways,state,lastError}`（state ∈ off/idle/tooFar/fetching/ready/cooling/failed）；`reviewstate` 多了 `baseMap`、`attribution`、`tunnelOverlay`（审阅地图没显示时 state 为 `noMap`）。**第一次切到外部底图会弹一次性说明**（偏好 `externalMapNoticeShown`）：钩子 `set mapStyle` 直接写设置不弹，`reviewmap osm` 走界面会弹，脚本里跟一句 `dismiss`。离线脚本 `run_map_sources_tests.py`（自己起副本，约 1 分钟）。测完复位：`set mapStyle 标准`、`reviewmap standard light 1`、`tunnels 0`、`faketunnels 0`、`faketiles 0`。

### 3.6 全套里的 25 个脚本 + 地区统计独立脚本（按 run_suite.sh 的顺序）

`run_suite.sh` 只跑 25 个 suite 脚本；`run_regions_stats_tests.py` **不在其中**，需按 3.3 单独运行（它会自己起两次测试副本）。下表保留该独立脚本作索引，不表示 suite 已覆盖它。

2026-10-28 补齐：run_tunnel_fix / run_crosscheck / run_batch_review / run_batch_card / run_route_cache / run_map_sources 排在 run_plausibility 之后（都会自己重启测试副本）。run_map_sources_tests 的 M1c 在锁屏时会假失败：先 `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`，锁着就不判。

数据文件都在容器通信目录里（见 2.3）。耗时取自 2026-10-24 的全量日志（历史观察，不是当前版本的实时测量）。

| 脚本 | 测什么 | 数据文件 | 联网 | 约耗时 |
|---|---|---|---|---|
| run_fill_tests_onscreen.py | 补点模式鼠标交互 14 项：单击/双击段中点不加点、拖中点出新顶点、拖顶点、双击/右键删顶点、撤销、空白单击不加点、拖锚点 B 吸附到下一点并可撤销、拒绝拖到过时点、应用→确认替换落地。窗口在屏幕中央 | Garmin_Roma_Da.gpx | 否 | 15 s |
| run_fill_tests.py | 同上 14 项，但主窗口挪到屏幕外 | Garmin_Roma_Da.gpx | 否 | 15 s |
| run_review_tests.py | 修改记录窗口：补一处→删 50 点→总览合成轨迹点数对→详细页取景框住、地名三级、上一处/下一处→逐处还原→全部还原回原点数；顺带截图到容器目录 | Garmin_Roma_Da.gpx | 是（地名用 Apple 逆地理编码 CLGeocoder，不是 OSM） | 15 s |
| run_hover_perf_test.py | 60 次悬停不会让主界面整体重算（`bodyEvals` 增量 ≤2），普通/补点两种模式都测 | Garmin_Roma_Da.gpx | 否 | 10 s |
| run_drift_tests.py | **诊断表，无通过/失败**：对几处指定断档取公路草稿，打印锚点外推 shift、贴路 snap、顶点数、路长、警告、相关 notes。可带参数 `10:19,07:48`（本机时区的断档开始时刻） | Garmin_Roma_Da.gpx | 是（OSRM） | 30 s |
| run_network_tests.py | 网络状况横幅：模拟注入 3 次失败→横幅出现，再注入 6 次成功→横幅消失（注入是假的，不发请求） | Garmin_Roma_Da.gpx | 后台 | 7 s |
| run_keep_tests.py | 手机数据的隧道群候选：取草稿→应用→确认框里的「保留贴路点」数应等于 区间内点数 − 落地后实际删除数；至少要试成 3 处 | 2026.csv | 是（OSRM，最多 6 次） | 1 min |
| run_dock_tests.py | 批量窗口紧凑卡片停靠在固定位置；飞到断档时 A/B 两端不被卡片挡住。需要窗口完整在 1440×932 屏幕内 | Garmin_Roma_Da.gpx | 后台 | 20 s |
| run_trip_tests.py | 行程切分与按速度判公路/铁路；「只补公路」时铁路行程的断档默认跳过；`trip k road/auto` 切换 | Garmin_Roma_Da_copy.gpx | 后台（脚本注释写"离线"，但 batchplan 会触发） | 5 s |
| run_region_tests.py | 范围圈选/反选/清除、只补公路时疑似铁路默认跳过、批量 3 处公路 <15 s | Garmin_Roma_Da.gpx | 是（最后一步批量取草稿） | 10 s |
| run_regions_stats_tests.py（独立，不在 suite） | 地区统计（国家/省州/地级市）：合成边界（`Tests/synth/regions_synthetic.bin`，经 `GPXPV_REGIONS_BIN` 注入）下 13 个点归属探针（含边界、洞、海上）、点口径点数/天数/排序、迷雾口径格数层级求和/等级公式/每格面积、选中高亮多边形数、.fwdb 只有迷雾口径且全部未归属、内置 Regions.bin 路径 | 自己生成；data/2026.fwdb | 否 | 3 min（起两次副本） |
| run_profile_tests.py | 采样画像：Garmin = 专用记录仪、1 s / 27 m、半径 15、候选 97；一生足迹 = 手机、半径 20–50、有候选；选断档后点距自动跟随 | Garmin_Roma_Da.gpx + stepLife.csv（171 MB） | 否 | 10 s |
| run_nature_tests.py | 断档成因标签（失锁 / 采样稀疏）、`routeinputs` 导出、notes 内容、批量「跳过稀疏」 | Garmin_Roma_Da.gpx + stepLife2026.csv | 后台 | 12 s |
| run_route_notes_tests.py | 单处公路草稿带判断依据：notes 里有上下文/匹配/采样说明；手机数据匹配半径 ≥20 m | Garmin_Roma_Da.gpx + stepLife2026.csv | 是（OSRM） | 20 s |
| run_route_tests.py | 路网草稿 R1–R8：草稿到达、换候选后清空、挪锚点标记「已手动调整」、撤销、铁路请求失败不影响公路草稿、弹框期间到达的草稿挂起、确认落地 | Garmin_Roma_Da.gpx | 是（OSRM + Overpass） | 1–1.5 min |
| run_parallel_tests.py | 批量两路并行（OSRM + Valhalla）：8 处公路全部成功且 <20 s | Garmin_Roma_Da.gpx | 是（OSRM + Valhalla） | 15 s |
| run_tripmap_tests.py | 按行程用地图判断（问 Overpass 附近有没有铁路）：大巴段判公路、火车段判铁路 | Garmin_Roma_Da_copy.gpx | 是（Overpass） | 2–3 min |
| run_rail_tests.py | 铁路断档只补隧道：RE1 和 Garmin 铁路段的批量结果，铁路项全部处理完且没有「失败」 | RE1.gpx + Garmin_Roma_Da.gpx | 是（Overpass + 路网） | 16–18 min |
| run_jitter_tests.py | 乱跳/回放点：RE1 回放点约 4600 并一键清理；乱跳候选；批量处理乱跳（J2）；Garmin 零误报且候选 97；手机 CSV 回放 1–2 万、乱跳 200–500、关掉找乱跳后候选 192；单处只删点。**会自己重启测试副本** | RE1.gpx + Garmin_Roma_Da.gpx + 2026.csv | 是（J2；加 `--no-network` 跳过 J2） | 10–11 min |
| run_plausibility_tests.py | 补点「落地前自检」（2026-10-27，判通过/失败，约 20 项）：`fakeroute all ok` 下有草稿的公路项 risk 非 null、无 high、≥75% low；`fakeroute valhalla offset 30` 下 Valhalla 做的项 high + reasons 非空 + 默认不勾选、`counts.high` 一致；`riskthreshold 100` + `batchrefetch all` 后变 medium 并勾选；单处 `route car` 的 `state.route` 带 risk，落地后 `reviewstate.changes[].risk` 非 null；**界面接线 U1–U4**：`batchriskonly 1` 后 `visibleCount` = risk ≥ 20 的项数、`0` 恢复；`batchcompact 1` 后窗口高 ∈ [cardContentHeight, +60]；`reviewfollow 1` + `reviewnext` 主地图中心距该处 < 2 km、`reviewfollow 0` 翻页中心不动；`changes[].riskReasons` 是数组；**R1（2026-10-28）** `replay` 考卷录音下真实题 real_14 `route car` 不出网（`netRequests` 不变）且取到草稿 | Garmin_Roma_Da_copy.gpx（缺就从 data 拷）+ Muenchen_Roma_Garmin.gpx + 录音拷进容器 | **否**（假引擎 + `autotripmap 0`） | 自己重启测试副本（排在全套最后，2026-10-27 起）；约 4 分钟；结束 `batchriskonly 0`、`batchcompact 0`、`reviewfollow 0`、`crosscheck 0`、`fakeroute all off`、`riskthreshold off` |
| run_tunnel_fix_tests.py | 过时时钟点「保留位置、只改时间」（2026-10-26）：选第 14 处（9732）→ A 已前移到 9728（冻结外推链）→ 假引擎取路 → 确认框 promptRetimed 1 → 替换落地 +11 −4、9733 仍在且时间 23:12:14→23:12:21、修改记录 retimed 1 → 还原回原值；对照 21676 | Muenchen_Roma_Garmin.gpx（缺就从 data/compare 拷进容器） | **否**（`fakeroute all ok` + `autotripmap 0`） | 自己重启测试副本；约 1 分钟；结束 `crosscheck 0`、`fakeroute all off` |
| run_crosscheck_tests.py | 精确模式离线回归（判通过/失败，34 项；2026-10-27 起开头 `riskthreshold 100`，免得落地前自检把 high 的项默认不勾选而干扰 A2）：假引擎下 两路一致 / 不一致（选 OSRM·Valhalla·直线·都不补、批量按钮不碰手选、落地只落已选）/ 只有一路（停用提示、一键全部采用）/ 两路都连不上 / 普通模式不受影响 / 单处 `routecross` + `routeswap`；2026-10-28 加 B15/B16 `lineLabels`、R1–R3 `batchrecross`、E5/E6 合并进度行 | Garmin_Roma_Da_copy.gpx | **否**（假引擎；`batchplan` 仍会后台查 Overpass 判段） | 自己重启测试副本；约 4–5 分钟；结束自动 `crosscheck 0`、`fakeroute all off` |
| run_batch_review_tests.py | 落地前审阅（修改记录窗口预览模式）/ 落地横幅 / 落地记录带两路草稿 / 审阅底图切换：假引擎下不一致 → 选 3 处 → `batchreview` 进预览（项数、drafts、等你选不可勾、勾选联动批量 included）→ 翻页 → `reviewmap hybrid light 0` → `batchland` → toast、批量窗口关闭、审阅切回真实记录、记录带 drafts | Garmin_Roma_Da_copy.gpx | **否**（假引擎 + `autotripmap 0`） | 自己重启测试副本；约 3 分钟；结束 `crosscheck 0`、`fakeroute all off` |
| run_batch_card_tests.py | 批量单处卡片缩窗 / 修改记录「在主地图上看」（判通过/失败，13 项）：preview 后 `batchcompact 1` → windowSize ≤ 600×420、`0` 恢复；1130×990 大窗口同样缩并恢复；折叠中关窗 → 退出折叠、重开是原尺寸；无批次时主列表点一处不碰批量、预览中点一处 → 选中并折叠；`reviewgoto` → 主地图中心距该处 < 2 km、宽 < 10 km、仍能翻页 | Garmin_Roma_Da_copy.gpx | **否**（假引擎 + `autotripmap 0`） | 自己重启测试副本；约 2 分钟；截图 card_compact.png / card_review_goto.png；结束 `batchcompact 0`、`crosscheck 0`、`fakeroute all off`、`reviewmap standard light 1` |
| run_route_cache_tests.py | 路网结果缓存 / 重新获取 / 修改记录两路切换（判通过/失败，约 35 项）：精确模式假引擎第一次全部请求 → 关掉再跑一遍全部命中缓存（requestsByHost 空、cacheHits = 公路项数、各项结果一致）→ `batchrefetch all` 全部重取 → `batchrefetch <i>` 只多两路各 1 个请求、其它项不动 → 预览里 `reviewdraft` 切换、翻页复位、`sameGeometry` → 换文件缓存清空 → 单处 `routecross` 第二次带「来自缓存」、`routerefetch` 不带 | Garmin_Roma_Da_copy.gpx + Garmin_Roma_Da.gpx | **否**（假引擎 + `autotripmap 0`） | 自己重启测试副本；约 4 分钟；结束 `crosscheck 0`、`fakeroute all off`、`reviewmap standard light 1`、`fillpoints 0` |
| run_map_sources_tests.py | 多来源底图 / OSM 隧道叠加层（判通过/失败，约 22 项）：假瓦片下切 OpenStreetMap / OpenTopoMap / Esri 影像 → `state.baseMap`、`tileRequests` > 0、署名随来源变化 → 切回标准不再请求 → 修改记录窗口 `reviewmap osm/esri/standard` → 合成隧道 5 条 ready / 200 km tooFar / `faketunnels 3` / `tunnels 0` | 不需要轨迹 | **否**（`faketiles` + `faketunnels`） | 自己重启测试副本；约 1 分钟；结束 `set mapStyle 标准`、`reviewmap standard light 1`、`tunnels 0`、`faketunnels 0`、`faketiles 0` |

### 3.7 不在全套里的诊断脚本（不判通过/失败，看输出数字）

| 脚本 | 做什么 | 数据 | 联网 | 备注 |
|---|---|---|---|---|
| run_batch_drift.py `[文件名]` | 批量补点全跑一遍，统计完成/有疑点/失败、锚点外推处数，列出有疑点的处。不带参数就用测试副本当前打开的文件 | 任意容器内文件 | 是，请求量大（地图判段 + 全部断档取草稿） | 需要测试副本已在运行；等待上限约 400 s + 900 s |
| run_perf_probe.py `[文件…]` | 卡顿探针：载入→静置→进补点→悬停 40 次→平移 6 次→批量规划，记录钩子往返耗时、`bodyEvals` 增量、CPU；用 macOS `sample` 抓主线程热点，存到 `perf/sample_*.txt` | 默认 Garmin_Roma_Da.gpx、2026.csv、backup2026.gpx | 后台 | 自己重启测试副本 |
| run_perf_probe2.py `[all\|batch\|big]` | `batch`：2026.csv 批量窗口期间的响应，含 25 秒真实批量运行后取消；`big`：483 MB 的 backupall.gpx 载入、悬停、平移、批量规划 | 2026.csv / backupall.gpx | batch 阶段联网 | 需要测试副本已在运行；big 载入最多等 15 分钟 |
| run_lang_smoke.py `<en\|de\|zh-Hant\|zh-Hans>` | 以指定语言重启测试副本：开文件→补点→批量窗口→修改记录窗口，截图并复制到 `Tests/ui/perf/lang_<语言>_*.png`，打印 lang/windows。看截图检查翻译和排版 | Garmin_Roma_Da.gpx | 后台 | 先 `mkdir -p Tests/ui/perf`；跑完记得重启中文副本 |

| run_crosscheck_online.py `[n=16]` | 精确模式在线验证：前 n 处自动判为公路的断档真实请求 OSRM + Valhalla，打印一致/不一致/没比对计数、每处两路长度与依据、按主机请求数，不一致的截图 | Garmin_Roma_Da_copy.gpx | **是**（两台主机各约 n+1 个请求） | 只由 Claude 跑、一次一个客户端；结束自动 `crosscheck 0` |

`run_drift_tests.py` 虽然在全套里，也属于这一类（见 3.6）。

### 3.8 常见问题

| 现象 | 多半是 |
|---|---|
| 每个脚本都 Traceback / KeyError，或 `ui.py state` 打印 TIMEOUT | 测试副本没在跑，或通信目录不存在。先 `setup_data.sh`，再按 3.3 启动 |
| `FileNotFoundError: …/uitest/cmd.tmp` | 通信目录不存在，跑 `Tests/ui/setup_data.sh` |
| 第一行是 `testing /Applications/…`（或不是你要的构建），但你想测新代码 | 没设 `GPXPV_APP` 或指向了旧归档；测试不再自动回退 DerivedData/`/Applications`（见 2.2），先运行 `Tools/build_release.py` 并显式指定归档 |
| `confirm: button not found` | 测试副本不是简体中文（比如刚跑过 run_lang_smoke），重新启动中文副本 |
| 拖动/右键类检查失败、截图全白 | 屏幕锁了或窗口被挡住了 |
| 只有联网的检查失败 | 公共服务限流或排队，见 3.4 的判断方法 |

### 3.9 临时产物与清理策略

- `/private/tmp/gpxpv-*` 的「245 个目录、3.4 GB」是 2026-10-29 的一次历史观察，不是实时测量；其中不少目录被本仓库报告/记录追溯引用，**本任务不删除任何旧 tmp 目录**。
- 未来清理只允许处理同时满足以下条件的临时产物：属于当前任务自己创建；相关进程已结束；原始证据与构建已完整归档并验证；确认没有路径引用依赖。任一条件不满足就保留。
- **禁止** `rm -rf /private/tmp/gpxpv-*` 之类的全局通配删除；清理前必须先列出候选并留档。
- 失败证据（日志、截图、临时数据、失败构建）必须保留，不得以「清理」为名覆盖或删除。

---

## 4. 合成数据回归（`Tests/synth/`）

**它在测什么**：不开 app，直接把引擎源码（解析器、断档/回放点/乱跳检测、采样画像、隧道群合并、行程切分）编译成命令行程序 `synthrunner`，跑在一批人工生成、"真相"已知的轨迹上，和标准答案比对。速度快（检查本身约 5 秒），改完检测逻辑必跑。

### 4.1 6 个数据族（共 114 个文件）

| 数据族 | 文件数 | 覆盖什么 |
|---|---|---|
| format-edge | 50 | 格式边角。一生足迹 CSV 的各种变体：列序、无精度列、引号空行、CRLF/BOM、无表头、毫秒/ISO 时间、分号分隔、只有表头、坏行、单行…… GPX 的各种变体：0 字节、无 trkpt、1–2 个点、无时间/半有时间、乱序、重复时间戳/点、多 trk/seg、只有航点/路线、跨日界线、近极点、命名空间、时区偏移、1970/2100 年、单行、截断、坏时间格式、FIT 二进制伪装、HTML 错误页……要求不崩溃，点数/画像/断档数正确 |
| garmin-tunnels | 13 | Garmin 专用记录仪过隧道：纯空洞、「过时时钟」（重新定位后头几个点的时间戳接着进隧道前往下走）、隧道群、短隧道照常记录、低于门槛的短空洞、火车 40 km 失锁、隧道里停 1 小时、超速伪空洞、发卡弯、时间戳扎堆、堵车速度边界 |
| legit-motion | 16 | 干净的真实运动：步行、之字形徒步、骑车掉头、城市驾驶、立交匝道、手机 3 s、公交、火车、高铁、飞机、渡轮、手机后台稀疏、尽头站折返、5 小时冷启动、1–4 点短掉线。回放点和乱跳必须为 0（不该报的别报） |
| replay-artefacts | 15 | 回放点 / 乱跳的真实故障：Garmin Explore 回放扫描（逐位相同 / 有扰动）、手机延迟副本交错、隧道里两点乒乓、航位推算冲过头再弹回、单点离群、车站缓存回放、10 s 采样回放、空洞后接乒乓、20 分钟长乒乓 |
| scale-mixed | 6 | 规模与形状压力：100 万点 11 天 Garmin（99 MB）、30 万行 60 天手机 CSV、Garmin + 手机两条重叠 trk、3 年 30 s 备份、2000 km 航班压进 1 小时、100 Hz 同秒扎堆。带耗时预算，用来抓 O(n²) 退化。详见 `scale-mixed/README.md` |
| stationary-noise | 14 | 静止或步行时的定位假象：记录仪静止 2 小时漂移、Explore 扎堆、手机室内反复写同一缓存坐标（20 s / 5 s）及基站/Wi-Fi 远跳、多路径尖刺、慢漂移、突发相同行、手机静止 1 Hz 噪声、Wi-Fi/GPS 来回切换 |

### 4.2 怎么跑

```sh
# 第一次（或改了某个 gen.py 之后）：重新生成数据，再检查
REGEN=1 Tests/synth/runner/run_all.sh

# 平时：复用已生成的数据
Tests/synth/runner/run_all.sh

# 只跑某一族 / 某些文件，-v 显示每个文件的说明
Tests/synth/runner/run_all.sh --family garmin-tunnels -v
SKIP_BUILD=1 Tests/synth/runner/run_all.sh --file '*.csv'     # SKIP_BUILD=1：不重新编译 synthrunner

# 同一个二进制里还有两个离线自测（不读数据文件；退出码 0 = 全过，每个用例一行 JSON）：
Tests/synth/runner/synthrunner --crosscheck-selftest   # 精确模式几何比对：31 个合成用例（同路抽稀/离群节点/弦弧 必须一致；平行路 12–30 m/匝道/外推不同/中段换路/往返 必须不一致）
Tests/synth/runner/synthrunner --ratelimit-selftest    # 限速器：4 个并发调用方打同一主机，断言在途 ≤1、相邻开始 ≥1 s、取消后 2 s 内退出（约 8 s）
Tests/synth/runner/synthrunner --portal-selftest [Tests/synth/fixtures/tunnel]   # 隧道口后处理（trimEnds/taper）：诊断夹具 gap14/16/19 的真实几何 + 4 个合成反例 + anchorWarning，8 个用例（2026-10-26）
python3 -I Tests/synth/runner/check_garmin_tunnel.py Tests/synth/runner/synthrunner [data/compare/Muenchen_Roma_Garmin.gpx]   # 真实 Garmin 文件：候选 50（V1 新增 6 处）、冻结链前移 12 处、23756/21676 不动、Inntal 无新增；末行 FAILS: none
```
`Tests/synth/fixtures/tunnel/` 进 git（几十 KB：OSRM 上下文几何 + OSM way 节点）。`/tmp` 下的二进制在本机的运行器权限下跑不了，自测请用仓库内的 `Tests/synth/runner/synthrunner`。

`run_all.sh` 做三件事：

1. 用 `swiftc -O` 把 `runner/main.swift` 和引擎源码编译成 `runner/synthrunner`（约 30 秒，日志在 `runner/build.log`）；
2. 如果设了 `REGEN=1`，在每个族目录里执行 `python3 gen.py`。生成的数据约 140 MB，git 忽略；纯标准库、固定随机种子，每次生成的结果完全一样；
3. 运行 `check.py`。它对每个文件单独起一个 synthrunner 子进程（一个文件崩了不影响别的，会报 `CRASH` 和崩溃时所在的阶段），拿输出的 JSON 和 `expect.json` 比对，同时检查一组与输入无关的不变量。

**新克隆下来没有数据**：直接跑会报 `MISSING … (did gen.py run?)`，先跑一次 `REGEN=1`。

**看结果**：最后几行形如：

```
summary: 114 entries in 6 families, ok 114  (5.1 s)
  format-edge       50/50  ok
  ...
FAILED: <族>/<文件> …        ← 只有失败时才有
```

退出码：0 全过，1 有 FAIL/CRASH/TIMEOUT/MISSING，2 用法错，3 编译失败，4 某个 gen.py 失败。2026-10-24 的状态是 114 项全过。

### 4.4 合成断档考卷（`Tests/exam/`，2026-10-27）

**它在测什么**：从用户完整的 Garmin 轨迹里挖掉一段造出「已知答案」的断档，让 app 同一套补点流程（候选检测 → `GapRouteInputs` → `carRoute` 经济模式两个引擎 → `StaleRetime` + `FillPath.interpolate`）去补，再和挖掉的真实点比；路网回复录制一次后永远离线回放，所以它是回归测试。同时记每题的落地前自检（risk），汇总成混淆矩阵。设计、题目格式、判卷标准见 `docs/fill-plausibility-design.md` §2。

```sh
Tests/exam/run_exam.sh                 # 离线：回放 recordings → 判卷 → 与 baseline.json 对照；末行 exam summary: …；结果 Tests/exam/results/<时间>.json
Tests/exam/run_exam.sh --baseline      # 判卷后把每题通过/未通过写进 baseline.json（有意接受新结果时）
python3 -I Tests/exam/make_questions.py   # 重新出题（离线、固定种子；改了规则才需要）
Tests/exam/run_exam.sh --record --max-requests 700   # 唯一联网的一步：串行、≤1 req/s、UA GPXPointViewer-exam/1.0；已有录音的题自动跳过
```

- 题目 `questions/*.json`（125 题：120 道 synthetic 按时长 10–20 s / 20–60 s / 1–3 min / 3–8 min 分档、按 straight / curve 分路型；5 道 real = 诊断报告确认的隧道，答案是 OSM way 几何）；录音 `recordings/<keyHash>.json`（一处 × 一引擎一个文件，内含 1–5 次 HTTP 的原始回复）。
- 通过 ⇔ 补点折线与答案折线双向最大距离 ≤ 20 m 且 ≥95% 的补点在 20 m 内。找不到录音的题记 `noRecording`，不算失败。
- `run_all.sh` 跑全套（没带 `--family/--file`）时末尾会自动跑一遍考卷（几秒），有回归退出码 1。
- 10–20 s 档的题 app 检测不出候选（`minSeconds 20`），考卷按锚点直接补并记 `detected:false`，用来看取路本身的表现。

### 4.3 期望值（expect.json）的规矩

- `expect.json` 是**标准答案**。它由生成器按"造数据时就知道的真相"算出来，**不是**照当前程序的输出抄的。所以测试变红，首先要怀疑的是代码。
- **每次 `REGEN=1` 都会用 gen.py 重写 expect.json。** 只手改 expect.json，下次重新生成就没了。
- 确实要改期望（比如规则有意改变，两种结果都合理）时：
  1. 改对应族的 `gen.py` 里写该文件期望的地方；
  2. 在 `desc` 开头加 `[YYYY-MM-DD 调整]`，末尾加 `调整理由：……`，写清楚为什么改、以前是多少；
  3. 跑 `REGEN=1 Tests/synth/runner/run_all.sh`；
  4. 用 `git diff`（或和改前的备份对比）确认 expect.json 里只有你想改的那一项变了。

  现成的例子：`stationary-noise/gen.py` 和 `scale-mixed/gen.py` 里搜 `2026-10-24 调整`。
- 列出所有文件和它们的说明：`python3 Tests/synth/runner/check.py --list`

---

## 5. 离线探针（`Tests/probes/`）

这些是以前排查具体问题时写的一次性工具，**属于历史工具，不随产品维护**。引擎代码改了以后，它们可能要小改才能编译；2026-10-24 编译时 `railgraph` 和 `routeprobe2` 就因 API 变化编不过——要用得先修编译。它们不判通过/失败，只打印数字，供人看。

维护中的小型定向探针放在 `Tests/probes/deepseek-small/`（有自己的 README 与 `run.py`，从产品源码抽取被验证表达式后编译运行）；它不属于上面的历史探针表。

**编译**（在项目根目录执行，把 `<dir>` 换成目录名、`<name>` 随便起，单个约 30 秒）：

```sh
swiftc -O -o /tmp/<name> Tests/probes/<dir>/main.swift GPXPointViewer/GPXParser.swift GPXPointViewer/TrackData.swift GPXPointViewer/GapFill.swift GPXPointViewer/RoadNetwork.swift GPXPointViewer/GeoCompute.swift GPXPointViewer/MetalPointRenderer.swift GPXPointViewer/Colormaps.swift GPXPointViewer/Heat3D.swift GPXPointViewer/BatchFill.swift GPXPointViewer/PixelGlobe.swift GPXPointViewer/GPXWriter.swift GPXPointViewer/L10nSupport.swift
```

然后运行 `/tmp/<name> <参数>`。探针不是沙盒 app，文件参数可以直接用 `data/` 下的原始路径。

| 目录 | 用途（来自 main.swift 开头注释） | 参数 | 联网 |
|---|---|---|---|
| chainprobe | 隧道群（相邻断档之间露天段 ≤90 s / ≤800 m）统计、锚点附近定位噪声；可抽样问 OSRM 露天段点离路多远 | `<gpx> [osrmSamples]` | 给了 osrmSamples 才联网（OSRM） |
| jitter | 回放点数、乱跳簇、与已有候选的重叠、耗时（和同目录 Python 探针对照） | `<文件>…` | 否 |
| jitter/probe*.py | Python 版乱跳/回放点规则的几轮实验：probe 运动学乱跳；probe2 移动中坐标逐位重复；probe3 先去回放点再找乱跳；probe4 要求重复点处在移动中 | `python3 Tests/probes/jitter/probe.py <文件> [--verbose] [--from HH:MM:SS --to HH:MM:SS]` | 否 |
| mergeprobe | 合并隧道群前后的候选数、群大小分布、被并掉的点数 | `<gpx>…` | 否 |
| railgraph | 合成铁路图单测：同段、双线平行、分叉、多节点折线时最短路是否正确（目前编译不过） | 无 | 否 |
| railprobe | 复现 railRoute.finish 的每一步：带 tunnel 标签的 way 数、最短路段数/隧道段数、A/B 投影弧长、裁后占比 | `<gpx> <index>` | 是（Overpass） |
| railprobe2 | 直接调用 app 同一个 `RoadNetwork.railRoute`，打印补/不补及原因 | `<gpx> <i,i,…>` | 是（Overpass） |
| routeprobe | 指定时刻的断档：输入、上下文原始几何、A 前/B 后真实点到几何的垂距、B 附近经过次数、裁剪结果 | `<gpx> <HH:mm>[,…]` | 是（OSRM） |
| routeprobe2 | 走新版 carRoute（漂移外推 / 沿线裁剪 / 末端靠拢），两种引擎各一次，打印 shift、snap、长度比、警告（目前编译不过） | `<gpx> <HH:mm,…> [economy]` | 是（OSRM + Valhalla） |
| routeprobe3 | 从 A 直接路由到 B 之后第 k 个点（k = 0、5、10、20、30），看绕路比，判断绕圈是吸错路还是路本来就要绕 | `<gpx> <HH:mm>` | 是（OSRM） |
| sampletest | 断档路由输入（上下文点、行进方向点）的基线回归：`dump` 生成基线 JSONL，改代码后 `check` 对比不变量。环境变量 `SAMPLETEST_OLD=1` 复现第一轮行为 | `dump <文件> <out.jsonl>` / `check <文件> <baseline.jsonl>` | 否 |
| tunnelprobe | 同一趟车两台设备（一生足迹 + Garmin）同时记录：互相以对方的断档为准，看另一台在同一时间窗里记了什么 | `<footprint.gpx> <garmin1.gpx> [<garmin2.gpx>…]` | 否 |
| tunnelprobe2 | 指定时间窗内 Garmin 逐点：时间、步时、步长、转向、海拔、离 OSRM 道路几何的垂距 | `<footprint.gpx> <garmin.gpx> <HH:mm:ss-HH:mm:ss,…>` | 是（OSRM） |
| tunnelprobe3 | 两个方向的系统扫描：足迹每处空洞里 Garmin 有多少点、多远、是否共线，反过来也一样 | `<footprint.gpx> <garmin.gpx>` | 是（OSRM） |

联网的探针同样**一次只跑一个，也不要和 UI 联网测试同时跑**。

---

## 6. 本地化（`Tests/l10n/`）

**机制**：String Catalog。源语言是简体中文，**键就是中文原文**，翻译成 en / de / zh-Hant。字串表有两份：

- `GPXPointViewer/Localizable.xcstrings`（app）
- `GPXQuickLook/Localizable.xcstrings`（Quick Look 扩展）

各 target 的 `InfoPlist.xcstrings`（app 显示名）不经过脚本，要手改。完整规则与术语表见 `l10n/RULES.md`，最常用的几条：

- SwiftUI 字面量（`Text("…")`、`Button("…")` 等）会自动成键，不要再包一层；
- 在 String 语境里（赋值给变量、函数返回值、错误信息）写 `String(localized: "中文原文", comment: "在哪显示、各占位符含义")`；
- 不要本地化标识符类字符串：rawValue、持久化的值、钩子 JSON、`UITestHook.swift` 里的字面量（R1、R14）；
- 术语表 R25：比如 补点 = Gap Fill / Lücken füllen / 補點，断档 = gap / Lücke / 斷檔；
- 占位符必须一一对应（R27）；
- 繁体用台湾用语（R24）。

### 加了新的界面文案以后

```sh
cd /Users/zyx/Documents/GPXPointViewer
L=/tmp/gpxpv-l10n; rm -rf "$L"; mkdir -p "$L"

# 1) 导出：编译器抽出的权威键表（会顺带构建一次 Debug）
xcodebuild -exportLocalizations -project GPXPointViewer.xcodeproj -localizationPath "$L/export" \
  -exportLanguage en -exportLanguage de -exportLanguage zh-Hant

# 2) 抽键：生成 keys.jsonl + 未翻译的 chunk 空壳。必须输出到临时目录！
python3 -I Tests/l10n/extract_keys.py "$L/export" "$L/keys"

# 3) 找出还没有翻译的新键 → $L/new_keys.json
python3 -I - <<'PY'
import json, glob
have = {(t["table"], t["key"]) for f in glob.glob("Tests/l10n/translations/chunk_*.json") for t in json.load(open(f, encoding="utf-8"))}
new = [r for r in map(json.loads, open("/tmp/gpxpv-l10n/keys/keys.jsonl", encoding="utf-8")) if (r["table"], r["key"]) not in have]
json.dump([{k: r[k] for k in ("table", "key", "comment", "specifiers")} for r in new],
          open("/tmp/gpxpv-l10n/new_keys.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(new), "个新键 → /tmp/gpxpv-l10n/new_keys.json")
PY
```

**4) 翻译**：把新键翻好，存成一个新的块文件 `Tests/l10n/translations/chunk_NN.json`，NN 取下一个没用过的编号（`ls Tests/l10n/translations | sort | tail -1` 看最后一个；2026-10-26 已到 23）。格式和已有的块一样，是一个数组：

```json
[
  {"table": "Localizable", "key": "中文原文", "en": "English", "de": "Deutsch", "zh-Hant": "繁體"},
  {"table": "Localizable", "key": "%lld 个迷雾存档", "en": "%lld fog archives", "de": "%lld Fog-Archive", "zh-Hant": "%lld 個迷霧存檔",
   "plural": {"en": {"one": "%lld fog archive", "other": "%lld fog archives"}, "de": {"one": "%lld Fog-Archiv", "other": "%lld Fog-Archive"}}},
  {"table": "Localizable", "key": "", "en": "", "de": "", "zh-Hant": "", "noTranslate": true}
]
```

- `table` 只有两种值：`Localizable`（app）和 `GPXQuickLook/Localizable`（Quick Look）。
- 带数量的名词按 RULES.md R17 加 `plural`；不需要翻译的键写 `noTranslate: true`。

```sh
# 5) 组装：重写两份 Localizable.xcstrings
python3 -I Tests/l10n/assemble.py /tmp/gpxpv-l10n/keys/keys.jsonl Tests/l10n/translations .
```

必须看到 `missing 0` 和 `specifier problems 0`。占位符对不上时退出码为 1，并列出 `BAD` 行。

```sh
# 6) 删掉导出时顺带构建的 Debug 产物（免得 Spotlight 里多一个同名 app）
rm -rf ~/Library/Developer/Xcode/DerivedData/GPXPointViewer-fyolojbthtxcykfqygpxnxpflbft/Build/Products/Debug/GPXPointViewer.app

# 7) 构建 Release，再用 run_lang_smoke.py en / de / zh-Hant 截图检查（见 3.7）
```

几点说明：

- `assemble.py` 是**整份重写** xcstrings，不是合并。翻译一律改 chunk 文件，别直接手改 `Localizable.xcstrings`，下次组装会被覆盖。
- 组装只写 keys.jsonl 里有的键。代码里删掉的文案会自然消失；中文原文改了就算新键，要重新翻译。
- 命令行 `xcodebuild` 不会把新键写回 xcstrings，所以必须走上面的导出 → 组装流程。

---

## 7. 改完代码之后的推荐顺序

```sh
cd /Users/zyx/Documents/GPXPointViewer

# 1) 构建并归档 Release（保留工程签名；使用脚本打印的 app/manifest，项目 Builds/<RUN>/archive/ 保存 durable ZIP 与记录）
python3 Tools/build_release.py --arch arm64
python3 Tools/archive_build.py /ABS/APP_FROM_BUILD/GPXPointViewer.app --validate

# 2) 合成数据回归（约 40 秒；第一次或改了 gen.py 用 REGEN=1）
Tests/synth/runner/run_all.sh

# 3) 改了界面文案的话：走第 6 节的本地化流程，再回到 1)

# 4) UI 验证按实际影响选择目标（3.3）；默认复用已有日志/截图，不因“最后确认”强跑全套
# 只有影响范围确需全套时才运行下面示例；通常执行对应单脚本。
GPXPV_APP=/ABS/APP_FROM_BUILD/GPXPointViewer.app Tests/ui/run_suite.sh
# 确认 testing / BUILD_PROVENANCE 指向这份已验证归档，而不是 DerivedData 或 /Applications
```

**5) 安装：验收通过后按 AGENTS.md 的持续授权覆盖安装，先保存编辑并正常退出所有实例。** 只安装通过 manifest 与签名／权限验证的、`build_release.py` 打印的 app（下文 `/ABS/APP_FROM_BUILD/GPXPointViewer.app` 为占位），不要从 DerivedData、`--no-sign` 产物或未经验证的 bundle 安装。先运行 `python3 Tools/archive_build.py /ABS/APP_FROM_BUILD/GPXPointViewer.app --validate --for-install`，再运行 `python3 Tools/install_release.py /ABS/APP_FROM_BUILD/GPXPointViewer.app --execute --authorized-target /Applications/GPXPointViewer.app`；安装器会独立校验三个 target 的严格签名、bundle ID、实际 entitlement 与 CDHash，运行中拒绝安装，并把旧安装保留为同目录备份。完整流程见 [docs/local-install-signing.md](../docs/local-install-signing.md)。安装后可显式设置 `GPXPV_APP=/Applications/GPXPointViewer.app GPXPV_BUILD_MANIFEST=/ABS/APP_FROM_BUILD/build-manifest.json` 校验该副本；内容与当前源码均匹配时保留归属。只有有意对照无法归属的历史版本才用 `GPXPV_ALLOW_UNVERIFIED_BUILD=1`。

只改了引擎的检测逻辑（GapFill / GPXParser / TrackData 等）时，第 2 步最快能发现问题；只改了界面交互时，重点看第 4 步里对应的脚本（补点交互 → run_fill_tests*，修改记录 → run_review_tests，批量窗口 → run_dock_tests / run_parallel_tests）。


## 显式源段与调用工具回归（2026-10-29）

分段契约与编辑边界见 [轨迹分段设计](../docs/segment-topology-design.md)。下面三组不启动产品窗口、不请求公共路网；Metal 组需要本机设备，无设备退出77，应记为未验收。每次使用新的输出目录，保留原失败证据。

```sh
python3 Tests/segments/core/run.py /private/tmp/gpxpv-core-check-new
python3 Tests/segments/render/run.py --current-core --output /private/tmp/gpxpv-render-check-new
python3 Tests/segments/workflow/run.py --source-dir "$PWD/GPXPointViewer" --repository "$PWD" --evidence /private/tmp/gpxpv-workflow-check-new
```

core 包含实际解析、TrackTopology、同段测速、GPX 分段写出及预览孤点/预算；render 使用当前渲染器、shader 和三个当前 core 源，其余依赖固定在 tests/dependencies，便于隔离复现，不能把它当全业务回归。workflow 编译34份真实产品 Swift，在测试副本开放私有入口，覆盖精确基线还原、同值跨段点、编辑依赖、过期后台结果、连续出口改时及两个真实 underfill；没有用手写替代算法冒充生产行为。

原114门中四项多段期待已按独立真值迁移：g13 gap0/trips5，s1 trips61，s3 timegap150/stale0/trips2，s4 gaps[51311,51313]。它们经过旧单段算法逐源执行和生成器 written-value 规则核定，另外110项原期待不变，125考卷评分与baseline不变。s3包含146个正常稀疏采样候选，不表示150次失锁；s4保留原浮点容差。新JSON通过实际段号、path rank与nextInSegment证明相邻，不能用全局数组相邻或任意非相邻代替。证据与原110/114失败均保存在 [独立真值报告](../Tools/agents/records/2026-10-28-remediation/native/20261029T002806.674537Z_synth-multisegment-truth_15b1a189/output.md)。

模型调用入口、预算和留档说明见 [Tools/agents/README.md](../Tools/agents/README.md)。Tests/agents 使用本地模拟CLI/SDK及受控子进程，不读取供应商凭据；模拟费用不是真实账单。真实模型任务必须另记唯一run并独立验收，不能以离线fixture通过代替连通性。

### 2026-10-29 构建环境与证据复用补充

若本机采样确认 Xcode 在 `NSFileCoordinator` 等待工程协调读取，可显式运行 `python3 Tools/build_release.py --arch arm64 --no-icloud-coordination`；该开关只给本次 xcodebuild 传 `-SynchronizeWithICloud=NO`，不写全局 defaults，也不替代下载真实源码。历史上该段曾带 `--no-sign` 仅作诊断证据，不可安装；当前正式构建保留工程签名。源码为 iCloud 占位文件时先完成下载。只有具体矛盾、缺证或修复影响才定向复测；汇总脚本错误只修汇总并复用原始执行日志，不重跑已经通过的产品目标。

### 每日／行程摘要专项验证（2026-10-30）

本节仅说明摘要功能的定向验证。当前逻辑、构建、实际应用功能及中英德三语布局验收通过；精确源码／构建归属和证据继承见 [验收记录](../docs/journey-summary-acceptance.md)，不据此宣称全项目发布通过。

以下是发生相应修复或证据缺失时的具体命令示例，不要求每次重跑：

```sh
python3 Tests/summary/core/run.py --output-root /tmp/gpx-summary-core elevation-midnight-proportions
python3 Tests/summary/store/run.py --evidence /tmp/gpx-summary-store --group modeentry
```

核心 case 名称见 [核心验证说明](summary/core/README.md)。Store 支持 `cache`、`sources`、`ownership`、`map`、`provenance`、`lifecycle`、`modeentry`，可重复传入 `--group` 选择受影响组。输出使用新目录，失败和旧结果保留；执行前写明具体重测原因。

本轮核心22个不同用例、Store原53项加新增12＋5项、中文实际应用12项检查均已有证据。后续默认继承，不无差别重跑。窗口截图使用明确的 `GPXPV_APP` 和 `GPXPV_BUILD_MANIFEST` 指向同一冻结归档；`Tests/ui/run_summary_tests.py --visual-only` 仅补指定语言的视觉证据，不重复功能检查。完整功能流程只在具体新缺口或受影响修复确有需要时执行。实际截图仍需逐图判断；锁屏黑图不得当作布局通过或产品缺陷。

仅顶部／下半区布局受影响时，使用 `--visual-only --layout-only`，每种语言仅拍 daily-top 与 journey-lower 两图、0功能检查；不能与 `--visual-extras` 同用。2026-10-30 的 UI-L1 修复按此范围验收，中文两图与随后恢复的英德四图都保留，无需再拍。

日期导航与持久化的最终真实构建、实际 UI 和跨进程验收不由本节宣称通过，待 [docs/journey-summary-date-persistence-acceptance.md](../docs/journey-summary-date-persistence-acceptance.md) 给出；旧的 core22、Store70 与中文实际功能 12 项证据继续按原记录继承，不要求无差别重跑。
