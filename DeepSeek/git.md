# Git 基线与回滚（2026-10-29，DeepSeek 建立）

## 为什么有这次提交

仓库原本只有两个提交（`4c8eed5 initial commit` 2026-08-11、`b8927ed quicklook` 2026-08-16），
之后约两个半月的全部开发都留在工作区，没有版本历史（问题 N-01：误删/覆盖无法恢复，也无法用 `git diff` 界定改动）。
2026-10-29 经用户授权，建立两个本地提交：

| 标签 | 内容 |
|---|---|
| `baseline-2026-10-29` | 当时工作区的完整导入（源码、文档、测试、工具、资源），**N-19 修复前**的代码状态 |
| `n19-fix-2026-10-29` | N-19 修复 + 回归测试 + `DeepSeek/` 记录 |

**没有 push**：远程 `origin`（GitHub）保持原样，只在本机提交。要推送需用户另行决定。

## 提交哈希（2026-10-29）

| 内容 | 提交 | 标签 |
|---|---|---|
| 基线（N-19 修复前） | `f6a90494e3f8470a192eb69c530d4e1e9ea0a066`（短 `f6a9049`） | `baseline-2026-10-29` |
| N-19 修复 + 记录 | `4ab625e8a6bb4d1acb1b6209154486414dc27fcd`（短 `4ab625e`） | `n19-fix-2026-10-29` |

两个都是 annotated tag：`git rev-parse baseline-2026-10-29` 返回的是 tag 对象，
取提交要写 `git rev-parse baseline-2026-10-29^{commit}`（或直接用 `git log` 里显示的短哈希）。
远程 `origin/main` 仍停在 `b8927ed`。

## 提交范围

包含：`GPXPointViewer/`（含 `Regions.bin` 与纹理）、`GPXQuickLook/`、`GPXThumbnail/`、`GPXPointViewer.xcodeproj/`、
`docs/`、`Tests/`（脚本、题目、录音、报告截图）、`Tools/`（构建脚本、代理工具源码与文档）、`AGENTS.md`、`README.md`、
参考 PDF、`DeepSeek/`（第二个提交）。

## 明确排除（仍在磁盘上，只是不进版本库）

| 路径 | 大小 | 原因 |
|---|---|---|
| `data/` | 1.3 GB | 真实轨迹与存档，个人数据；已在原 `.gitignore` |
| `Tools/agents/records/` | 约 1 GB | 代理运行证据，体量过大；本次新增到 `.gitignore` |
| `Tests/ui/app.noindex/`、`Tests/ui/perf/` | 约 90 MB | 测试副本与日志，可重建；原有规则 |
| `Tests/synth/` 生成数据、`runner/synthrunner` | 约 28 MB | 生成物/二进制，可重建；原有规则 |
| `__pycache__/`、`.DS_Store`、`*.lock` | — | 缓存与系统杂物；本次新增到 `.gitignore` |
| `Tools/agents/runs/`、`Tools/agents/sdkenv/` | — | 原有规则 |

被排除的证据不会丢：`Tools/agents/records/` 仍在项目目录里，只是不随 git 走。

## 回滚方法

### A. 只回滚 N-19 修复（最常用）

```sh
cd /Users/zyx/Documents/GPXPointViewer

# 推荐：只把三个代码/测试文件退回基线，记录文件保留，再提交一次
git checkout baseline-2026-10-29 -- \
  GPXPointViewer/Colormaps.swift \
  GPXPointViewer/GeoCompute.swift \
  Tests/segments/core/main.swift
git commit -m "revert: N-19 修复（只回代码，保留记录）"
```

⚠️ **不要**直接 `git revert n19-fix-2026-10-29`：那个提交同时新增了 `DeepSeek/` 记录，
而记录在后续 `docs:` 提交里又被修改过，直接 revert 会触发 `modify/delete` 冲突
（它想删除 `DeepSeek/issues.md` 等文件，但这些文件在 HEAD 里已被改动）。

回滚后验证：`python3 Tests/segments/core/run.py /private/tmp/gpxpv-core-rollback`，
应回到 **101 项通过**（新增的 11 项随测试文件一起回滚）。

**2026-10-29 已实测**：按上面命令回滚后三个文件哈希回到修复前，core 为 **101/101**；
再 `git checkout HEAD -- <三个文件>` 恢复，哈希回到修复版、core 回到 **112/112**，工作区干净。

### B. 撤销整个基线提交（回到导入前的工作区）

```sh
# 保留文件内容，只拆掉提交（所有文件回到"未提交"状态）
git reset --soft baseline-2026-10-29^

# 或保留历史，用反向提交把导入整体撤掉（会删除基线新增的文件）
git revert --no-edit baseline-2026-10-29
```

### C. 完全回到 8 月的两个提交（危险）

```sh
# 先确认没有需要的本地改动；这会把工作区所有文件恢复到 8 月状态
git switch -c before-baseline b8927ed

# 确认无误后才考虑：
# git reset --hard b8927ed
```

`--hard` 会丢弃未提交改动与后续提交，执行前先 `git status` / `git stash`。

### D. 应急：git 不可用时

N-19 改动前的三个文件副本在 `/tmp/n19-backup/`：

```sh
cp /tmp/n19-backup/GPXPointViewer/Colormaps.swift GPXPointViewer/
cp /tmp/n19-backup/GPXPointViewer/GeoCompute.swift GPXPointViewer/
cp /tmp/n19-backup/Tests/segments/core/main.swift Tests/segments/core/
```

注意 `/tmp` 重启即失，**优先用 git 回滚**；这条只作为最后手段。

## 日常用法

```sh
git status                 # 看工作区
git log --oneline --graph  # 看历史
git show --stat n19-fix-2026-10-29   # 看修复改了哪些文件

git add -A
git commit -m "说明"       # 以后每个逻辑改动一个提交

git tag                    # 看基线标签
```

## 已知边界

- 基线提交包含大量历史遗留改动，提交粒度是"导入"，不是逐个功能。
- `Tools/agents/records/` 不纳入版本库，因此那部分证据只有本机副本；如需长期保存，应另行备份。
- 远程未推送；`git push` 前先确认账号与仓库权限。
