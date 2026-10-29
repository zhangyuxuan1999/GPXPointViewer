# 任务：修 DeepSeek 第 3 轮任务书的 7 处问题 + 让 run_profile_tests.py 不再因时序误报 · 2026-10-28

## 背景
DeepSeek 第 3 轮测试报告 `Tests/reports/20261027_2334_2026-10-27_plausibility_card_r3.md` 的「任务书本身的问题」一节列了 T1–T7（原文照抄在下面）。任务书是 `Tests/tasks/2026-10-27_plausibility_card_r3.md`，以后还要按它重跑，所以要改到位。另外 T5 指出 `Tests/ui/run_profile_tests.py` 在前一个脚本留下的副本上接着跑时，171 MB 的一生足迹 CSV 还没算完就被 `fill` 抢跑，P4/P5 误报——把脚本改健壮。

## 允许改的文件（只有这两个）
- `Tests/tasks/2026-10-27_plausibility_card_r3.md`
- `Tests/ui/run_profile_tests.py`
其它文件一律不碰；不构建、不跑 app、不联网。

## 要改什么
### A. 任务书（逐条对应 T1–T7，改完后在文末加一节「2026-10-28 修订记录」列出改了哪几处）
- **T1（§4-2b 摘要字段用错）**：任务书给的摘要行用 `x.get('conflict')` 统计，但精确模式不一致时字段是 `status='conflict:disagree'` / `cross='disagree'`（`conflict` 为 null）。改成按 `status`/`cross` 统计，期望写成「100 项 status 为 conflict:disagree、counts.disagree=100」。
- **T2（§6.1 bands 期望过时）**：删掉「real 10/10」这一档的期望；5 道 real 题按时长归入 `20-60s` / `1-3min` / `3-8min` / `<10s`。其余数字保持（`10-20s 30/30、20-60s 82/84、1-3min 78/82、3-8min 50/52、<10s 2/2`），并注明以 `Tests/exam/baseline.json` 为准。
- **T3（§4-6 的 1130×990 超出屏幕）**：本机屏幕 1440×932，窗口高会被系统夹到 903。把尺寸改成 1130×880，期望 `now=1130x880`、恢复 `[1130,880]`；并写一句「若屏幕更小被夹取，以折叠前后一致为判据」。
- **T4（§7.4 shotwin 宽高比）**：`shotwin` 截图四边各带 34 pt 阴影边距（960×800 窗口输出 2056×1736）。把「截图尺寸 = 窗口尺寸」的判据改成「用钩子 `windows`/`frame` 读窗口尺寸为 960×800；截图尺寸只作记录」。
- **T5（第 1 节 6→7→8 顺序）**：改为 `run_profile_tests.py` **单独新起副本**跑（写出完整的起副本命令，照「准备」一节的写法），不接在 6 后面。
- **T6（准备第 2 步 info 顺序）**：把 `python3 Tests/ui/ui.py info` 抄 `front=` 这一步挪到起测试副本之后。
- **T7（小措辞）**：「抄 P1a、P2a、P3b（期望以 50 结尾）」改成只有 P3b 以 50 结尾，P1a 以 `counts.high=1` 结尾、P2a 以 `counts.high=49` 结尾（或直接删掉括号里的说法）。

### B. `Tests/ui/run_profile_tests.py`
- `load()` 现在只等 `loading` 为 false 且 `points` 非空；大 CSV 载入后还有一段「重算候选/画像」，加等待：`refreshing` 为 false（state 里若没有 `refreshing` 字段，就以 `profile` 非空为准）并且 `candidates` 字段存在，超时 180 s。
- `fill` 后也等到 `profile` 非空再取 `p = s['profile']`（最多 60 s），不要固定 `sleep 1500`。
- 不改任何期望值。改完后在文件顶部 docstring 加一行「2026-10-28：载入后等重算完成，避免接在其它脚本后面跑时 P4/P5 误报」。

## 验证
- `python3 -c "import ast,sys; ast.parse(open('Tests/ui/run_profile_tests.py').read())"` 无报错。
- 任务书用 Grep 自查：不再出现 `x.get('conflict')`、`real 10/10`、`1130x990`、`1130, 990`。

## 报告
按运行器要求输出：改了什么（逐条 T1–T7 + B 的两处）、自查命令输出、没做到的及原因。
