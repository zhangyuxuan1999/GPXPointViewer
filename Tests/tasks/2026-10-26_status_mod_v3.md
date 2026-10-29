# 任务：做一个常驻聊天旁边、自动刷新的「后台任务」面板（Claude Code mod）· 2026-10-26 · 第 3 版

第 1 版因为 DeepSeek 不能调用 Skill 工具而失败；第 2 版因为 `~/.claude/` 下的目录被权限系统判为敏感路径、一个文件都写不进去而失败。
**这一版：mod 写在仓库里的 `Tools/mods/background-tasks/`（你有写权限），校验用 `claude plugin validate Tools/mods/background-tasks`（这条命令已放行）。写好后由主会话拷到会话的 mod 目录加载。** 不要调用 Skill 工具，需要的资料全部用 Read / Grep 去读。

## 背景
用户在 Claude Code 桌面版里开发 GPXPointViewer（本仓库）。后台常有 Claude API 任务、DeepSeek 测试、xcodebuild、测试副本 app、钩子脚本在跑，用户想在聊天旁边有一个**自动刷新的面板**，一眼看出现在有几个任务在跑、各是什么。
数据源已就绪：`Tools/agents/status.sh --json`（在仓库根目录执行）输出一行 JSON：
```json
{"time":"17:47:29","running":1,"ledger_usd":92.09,"items":[{"kind":"Claude API 任务","name":"map-sources","since":"16:21","detail":"最后活动 16:59 · 记录 20261026_162124_map-sources"}]}
```

## Claude Code 的 mod 是什么（技能原文要点）
mod 是对 Claude Code 自己界面的小扩展，用一个 TypeScript 钩子模块写成，可以在聊天旁边开一个**面板（Pane）**并自己刷新。
- **写在哪里（本版）**：`/Users/zyx/Documents/GPXPointViewer/Tools/mods/background-tasks/`。四个文件：
  1. `.claude-plugin/plugin.json`：`{ "name": "background-tasks", "version": "0.1.0", "description": "后台任务面板：每 10 秒显示现在有几个任务在跑", "types": "./types/index.d.ts" }`
  2. `hooks/hooks.json`：`{ "modules": ["./register.tsx"] }`
  3. `hooks/register.tsx`：钩子模块，`export const register: Register = (on, options) => { ... }`，类型从 `'claude-code'` 导入
  4. `types/index.d.ts`：状态契约，在 `interface PluginState` 下以 mod 名声明每个 `$.state` 值（模板见下面的例子）
- **钩子怎么写**：`on(event, matcher?, hook)`；每个 hook 是 `($, e, next)`：`$` 是引擎接口（名词.方法），`e` 是事件输入（冻结的普通值），`next(e)` 把事件交给下层并得到结果。模块里**没有 DOM、没有 Node**，一切外部能力都走 `$`。JSX 用全局 `h` 编译，元素来自 `const { Box, Text } = $.ui.resolve(e)`。
- **面板**：`$.ui.open({ id, title })` 打开；由 `on('ui.render', { component: 'Pane', requestId: id }, hook)` 画，hook 返回一棵 `<Box>/<Text>` 树。
- **定时**：`$.clock.every(ms, fn)` 每 ms 毫秒调用 fn，返回可 `cancel()` 的句柄（类型文件第 3515 行起 `clock: {`）。
- **跑命令**：`await $.process.run(["Tools/agents/status.sh", "--json"], { cwd: "/Users/zyx/Documents/GPXPointViewer", timeoutMs: 15000 })` → `{ exitCode, stdout, stderr }`（类型文件第 3587 行起 `process: {`；argv 形式、无 shell）。
- **状态**：`import { atom, read, update } from 'claude-code'`；`const snap = atom({ plugin: 'background-tasks', key: 'snapshot' } as const, 初值)`；画面里 `await read($, snap)`，定时器里 `await update($, snap, old => 新值)`——写入会让面板重画。每个 atom 的键都要在 `types/index.d.ts` 的契约里声明。
- **命令**：`session.start` 里 `await $.command.register({ name: 'background-tasks', description: '…' })`，`on('command.run', { command: 'background-tasks' }, …)` 里重新 `$.ui.open` 并返回 `{ text }`，这样用户关掉面板后可以用 `/background-tasks` 再打开。

**必读的原始资料（用 Read 读全文）**：
- 例子（完整可加载的面板 mod，照它的结构写）：`/private/tmp/claude-501/bundled-skills/2.1.308/c8e1b2fa37791d3d2ab00c1fd3a7fd60/plugin-authoring/examples/pane.tsx` 和它的契约 `…/examples/pane-state.d.ts`、测试 `…/examples/pane.test.tsx`
- 长篇说明：`/private/tmp/claude-501/bundled-skills/2.1.308/c8e1b2fa37791d3d2ab00c1fd3a7fd60/plugin-authoring/reference.md`（266 行，重点看 ui.render、$.state 契约、校验与测试）
- API 类型（22,504 行，只 Grep 需要的名字，不要整读）：`/private/tmp/claude-501/bundled-skills/2.1.308/c8e1b2fa37791d3d2ab00c1fd3a7fd60/plugin-authoring/types/claude-code.d.ts` —— `grep -n "clock: {\|process: {\|Pane: {\|'ui.render'\|'session.start'\|'command.run'\|export type Register\|ui: {" <文件>`，再 `sed -n` 看附近；文件头部有 tsconfig 的写法（用于类型检查）。

## 面板要求
1. 标题「后台任务」。`session.start` 时打开面板、注册 `/background-tasks` 命令、启动 `$.clock.every(10000, …)` 定时刷新，并立即刷新一次。
2. 刷新 = 跑 `Tools/agents/status.sh --json`，解析 JSON 存进 atom；失败（exitCode ≠ 0、解析错误、异常）存 `error: 一行错误文字`，面板显示「读取失败：…」，不崩、不空白。
3. 画面：第一行大字 `现在有 N 个任务在跑`（N=0 时 `现在没有任务在跑`），后面带 `HH:MM:SS`；然后每个任务一行 `类型 · 名字 · 从 HH:MM 开始 · 详情`，没有任务时显示 `—`；最后一行小字（`dimColor`）`Claude API 台账合计 X 美元`。
4. 在终端（`e.surface === 'terminal'`）和桌面（`'desktop'`）两种表面都要能画：只用 `Box`、`Text` 两种元素，不要用别的。
5. 只允许写 `Tools/mods/background-tasks/` 里的文件；仓库其它文件一个都不改（`Tools/agents/status.sh` 也不改）。
6. `status.sh --json` 的 item 还有 `aux` 布尔字段：`aux:true` 的是构建/测试副本/脚本这类附带活动，不计入 N；面板里把它们列在任务下面，前缀「附带：」并用 `dimColor`。

## 验证（写进报告）
1. `claude plugin validate Tools/mods/background-tasks`（在仓库根目录执行，命令就这样写，不要加 bash/cd）——贴输出；有拒绝就改到通过。
2. 类型检查：系统没有 tsc、不许联网装，**跳过**；靠 validate 和下面的测试。
3. 写一个 `hooks/register.test.tsx`（照 `pane.test.tsx` 的写法）至少测：JSON 有 2 个 items 时画面含「现在有 2 个任务在跑」和两行任务；命令失败时画面含「读取失败」。跑 `claude plugin test Tools/mods/background-tasks`，贴输出。测试里凡是要跑 `status.sh` 的地方用假数据代替（不要真的起进程）。
4. 报告里写：文件放哪、用户怎么开关面板（`/background-tasks`）、怎么改刷新间隔（哪一行的 10000）、怎么在以后的会话里也加载（reference.md 里 `--plugin-dir` / `CLAUDE_CODE_PLUGIN_DIRS` 一节，抄要点）。主会话会把目录拷到 `~/.claude/dev-mods/84e7be0d-cf7d-470e-9701-04baedd4dc06/background-tasks/` 让本会话加载——所以 `hooks.json` 里的模块路径、`plugin.json` 里的 `types` 路径都必须是**相对路径**。

## 硬规则
- 不调用 Skill 工具；不联网、不装 npm 包（`tsc` 没有就跳过类型检查并说明）。
- 做不了就明确写做不了和原因；不要留下半成品让面板报错。
