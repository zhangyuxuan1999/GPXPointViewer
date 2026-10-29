# 开发报告 · 2026-10-28_fix_r3_taskdoc_and_profile_wait

## 改了什么（文件 + 要点）

只改了允许的两个文件；其它文件未碰，未构建、未跑 app、未安装、未联网。

### A. `Tests/tasks/2026-10-27_plausibility_card_r3.md`

- **T1（§4-2b 摘要字段，`Tests/tasks/2026-10-27_plausibility_card_r3.md:78`、`:121`）**：「批次摘要」命令不再读 `conflict` 字段（精确模式不一致时该字段为 null），改为打印 `status` / `cross` 两列（对 `it` 统计）。§4-2b 期望改成：`status Counter({'conflict:disagree': 100})`（100 项 status 为 `conflict:disagree`）、`cross Counter({'disagree': 100})`、`counts.disagree=100`；并说明该模式下 `drafted`/`src` 打印 0（`d` 只收 `status=='done'`）。另把「准备」第 10 条的 `state.batch` 字段说明由 `conflict` 订正为 `cross`（`:89`），与钩子实际输出一致。
- **T2（§6.1 bands，`:164`）**：删掉 `real` 档的期望；保留 `10-20s 30/30、20-60s 82/84、1-3min 78/82、3-8min 50/52`，补上 `<10s 2/2`；注明 5 道 real 题按时长归入 `20-60s` / `1-3min` / `3-8min` / `<10s`（两引擎合计 10 次已含在各档），数字以 `Tests/exam/baseline.json` 为准。
- **T3（§4 第 6 条大窗口，`:146`）**：`1130×990` → `1130×880`；期望改为 `resizewin now=1130x880`、恢复 `[1130, 880]`；补一句「若屏幕更小被夹取，以折叠前后一致为判据」。
- **T4（§7.4 shotwin，`:179`）**：判据改为用钩子 `windows` 读主窗口为 `w=960 h=800`（`frame` 回显一致）；`shotwin` 截图尺寸只作记录，并注明四边各带 34 pt 阴影边距（960×800 窗口输出 2056×1736），删掉「宽高比必须 1.2」。
- **T5（§1 第 6–8 条，`:102-112`）**：第 6 条结束只「紧接着跑 7」；第 8 条改为**单独新起副本**，写出完整起副本命令（`L`/`C`/`pkill`/`mkdir+rm+cp`/`open -n --env GPXPV_UITEST_DIR …`），等 `state` 含 `"points"` 后先发 `autotripmap 0`、`place 0`、`front`，再跑 `run_profile_tests.py`。
- **T6（「准备」第 2/5 步，`:36-43`、`:67`）**：第 2 步删掉 `python3 Tests/ui/ui.py info` 与「`front=`」；改到第 5 步起副本、`autotripmap 0 …` 之后执行 `info` 并抄 `front=`（副本没起来时 `info` 只会 TIMEOUT）。
- **T7（§1 第 1 条，`:97`）**：抄录说明改为 P1a 以 `counts.high=1` 结尾、P2a 以 `counts.high=49` 结尾、P3b 以 `50` 结尾。
- **文末修订记录（`:213` 起）**：新增「## 2026-10-28 修订记录」，逐条列出 T1–T7 与脚本 B 共 8 处改动。

### B. `Tests/ui/run_profile_tests.py`

- **顶部 docstring（`:2-3`）**：加一行「2026-10-28：载入后等重算完成，避免接在其它脚本后面跑时 P4/P5 误报」。
- **新增 `settled(s)`（`:10-13`）**：`refreshing` 字段存在时要求其为 false；不存在时退回「`profile` 非空」。
- **`load()`（`:14-20`）**：默认超时 90 → **180 s**；返回条件改为 `loading == false`、`points > 0`、`'candidates' in state` 且 `settled(s)`。
- **新增 `fill(timeout=60)`（`:21-28`）**：发 `fill` 后轮询，等到 `profile` 非空**且** `settled(s)` 才返回；两处调用点改为 `s = fill()`，删除固定 `sleep 800` / `sleep 1500`（`:30`、`:39`）。比字面「profile 非空」多等 `refreshing` 是必要的：换文件后旧画像仍非空，只看非空会把上一份 Garmin 画像当成 CSV 结果。
- **所有 `check(...)` 的期望值与检查文案未改。**

## 验证（命令、输出摘要、通过/失败）

1. **语法（任务书要求）**：`python3 -c "import ast,sys; ast.parse(open('Tests/ui/run_profile_tests.py').read())"` → 无输出、退出码 0；另跑 AST 解析输出 `functions: ['check', 'settled', 'load', 'fill']`，docstring 为两行预期文本。**通过**。
2. **Grep 自查（任务书要求）**：对任务书检索 `x.get('conflict')`、`real 10/10`、`1130x990`、`1130, 990` → **No matches found**。**通过**。
3. **附加：批次摘要 one-liner 编译**：从任务书 `:78` 抽出 Python 片段 `compile()` → `batch summary one-liner compiles: OK`、`contains original conflict read: False`。**通过**。
4. **附加：假 `ui` 状态机干跑（不启动 app）**：模拟 DeepSeek 的失败现场——CSV 载入完成后 `profile` 仍是上一份 Garmin、`candidates 0`，`fill` 后连续 3 次 `refreshing=true` 且旧画像，之后才出现 `phone` / `candidates 3952`。结果：P1–P6 全部 `ok`、`FAILS: none`；日志 `csv fill: saw refreshing=true for 3 polls, then returned fresh`。**通过（合成状态，非真实 app）**。
5. **附加：最终静态自查**：6 个 P 检查文案都在；脚本无固定 `sleep 800/1500`；180 s / 60 s 超时与 docstring 均在 → `final static self-check: OK`。**通过**。

## 没做到的项目及原因

- **未在真实测试副本上执行 `run_profile_tests.py`**：任务书明确「不构建、不跑 app」，故等待逻辑只用假 `ui` 状态机干跑验证；真实副本上的 P4/P5 需下一轮测试确认（预期 171 MB CSV 的 `fill` 会稳定等到重算完成）。
- **备注（不算未完成）**：任务书末尾第 203 行原有的一行未闭合四反引号（````）未处理，不在 T1–T7 范围内，DeepSeek 按文本读取执行不受影响。
- 其余无未完成项：未安装、未改产品代码、未改 `baseline.json`/期望值、未联网。

## 总结

**可以安装**：本次只改任务书与离线测试等待逻辑，未触碰产品代码，语法、Grep 自查、摘要 one-liner 编译与假 `ui` 干跑全部通过（真实 app 回归按要求未跑）。
