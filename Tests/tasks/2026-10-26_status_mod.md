# 任务：做一个常驻聊天旁边、自动刷新的「后台任务」面板（Claude Code mod）· 2026-10-26

## 背景
用户在 Claude Code 桌面版（Code 标签页）里和 Claude 协作开发 GPXPointViewer。后台经常同时有几种东西在跑：Claude API 任务（`Tools/agents/api_run.sh`）、DeepSeek 测试会话（`Tests/run_deepseek.sh`）、xcodebuild、自测用的测试副本 app、钩子测试脚本、合成套件 runner。
用户想要一个**常驻在聊天旁边、自动刷新**的面板，一眼看出「现在有几个任务在跑、各是什么」。
数据源已经做好：`Tools/agents/status.sh --json` 输出一行 JSON：
```json
{"time":"17:47:29","running":0,"ledger_usd":92.09,"items":[{"kind":"Claude API 任务","name":"map-sources","since":"16:21","detail":"最后活动 16:59 · 记录 20261026_162124_map-sources"}]}
```
`running` = 在跑的个数；`items[]` 每项：`kind`（类型）、`name`、`since`（开始时刻 HH:MM）、`detail`。人读格式是不带参数的 `Tools/agents/status.sh`。

## 要做什么
Claude Code 支持「mod」：对 Claude 自己界面的小扩展，可以是一个**留在聊天旁边并自动更新的面板（pane）**。**先用 Skill 工具加载 `plugin-authoring`（这个技能专门讲怎么做 mod：面板、状态行、钩子的文件结构与 API），严格按它的说明做**。若 Skill 工具里没有这个技能（列不出来 / 加载失败），**立刻停止**，在报告里写明「plugin-authoring 技能不可用」，不要凭猜测写。

面板要求：
1. 标题「后台任务」。每 10 秒执行一次 `Tools/agents/status.sh --json`（工作目录是本仓库根），按结果刷新。
2. 顶部一行大字：`现在有 N 个任务在跑` 或 `现在没有任务在跑`，带时间 `HH:MM:SS`。
3. 下面一个列表，每项一行：`类型 · 名字 · 从 HH:MM 开始 · 详情`；没有任务时列表区显示「—」。
4. 底部小字：`Claude API 台账合计 X 美元`。
5. 脚本执行失败或 JSON 解析失败时，面板显示「读取失败：<错误一行>」，不要崩、不要空白。
6. 面板文件放在技能说明的位置（通常是本仓库的 `.claude/` 下的 mod 目录，或 `~/.claude/` 下；按技能说的来）；mod 的名字 `background-tasks`。
7. 不要改 `Tools/agents/status.sh` 以外的现有文件；status.sh 如需补字段可以改，但人读格式和 `--json` 的现有字段不能删。

## 验证
- 按技能说明验证 mod 能被加载（技能里通常有检查/调试办法）；把加载/调试命令的输出写进报告。
- 用 `Tools/agents/status.sh --json` 的真实输出，以及一份手造的 JSON（含 2 个 items）各做一次渲染检查（若技能提供本地预览办法就用；没有就至少做 JSON 解析与模板的单元级检查，并说明怎么查）。
- 报告里写清：mod 文件放在哪里、用户怎么打开/关闭这个面板、怎么改刷新间隔。

## 硬规则
- 允许改/新建的文件：mod 目录下的文件、`Tools/agents/status.sh`。其它文件不许动。
- 不联网、不装 npm 包（如技能要求 node 运行时，只用系统已有的 node）。
- 做不了就明确说做不了和原因，不要做一半。
