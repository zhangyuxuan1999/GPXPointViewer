# 语言／闲置设置持久化审计结论

审计完成；等待主代理独立验收。请求模型 gpt-6.1-sol / ultra，原生 agent ID `/root/settings_persistence_audit`；供应商实际模型与强度回执 unknown，费用 null。使用 engineering:debug 方法。未运行正式或测试App、未编译全App、未关闭当前201万点会话、未修改产品或真实偏好，未做UI／网络测试。

## 已证实根因与边界

本次覆盖安装确实改变了 sandbox 身份／设置存储路径，置信度高。旧安装备份主二进制 SHA256 `a901e819c26dab26af37366507792c7cbc670093f1c90050ccfa08f5a04c2210` 的签名是 ad-hoc+runtime，Identifier 为 `de.wayne.GPXPointViewer`，entitlement 含 app-sandbox=true、network.client=true、files.user-selected.read-write=true。两个旧appex同样含app-sandbox=true。

新归档和当前 /Applications 主二进制 SHA256 均为 `64d5101be7c3239d10e0cfd01109b3220899f992f9865d1eda0dc2b606b5e883`；Info.plist仍是同bundle ID，但仅linker-signed，签名Identifier变为可执行文件名，Info.plist未绑定，没有任何entitlement。两个新appex也没有entitlement。归档manifest的实际xcodebuild argv明确记录 `CODE_SIGNING_ALLOWED=NO`。项目三个target原有Release配置已经指定各自entitlements文件、CODE_SIGN_IDENTITY="-"、ENABLE_HARDENED_RUNTIME=YES；Tools/build_release.py:36–37通过--no-sign追加该覆盖值。当前安装动作只复制bundle、不写Library偏好，与上述存储路径变化一致。

2026-10-31T01:17:19Z，仅读取任务允许6键：

| 键 | 非容器 ~/Library/Preferences 域 | 容器 ~/Library/Containers/de.wayne.GPXPointViewer/Data/Library/Preferences 域 |
|---|---|---|
| AppleLanguages | [zh-Hans] | [zh-Hans] |
| idleDisabled | true（bool） | true（bool） |
| idleGlobeSeconds | 缺失 | 4.0（float） |
| idleMapSeconds | 缺失 | 4.0（float） |
| appearanceMode | 缺失 | 跟随系统（str） |
| mapStyle | 缺失 | 标准（str） |

非容器plist mtime为01:12:48，容器为01:00:48。这只能说明文件最后写入时间，不能给每个键排序。当前用户新设的语言和闲置开关已经存在于新域磁盘，证明至少本次选择有落盘。旧中文→新默认英文和闲置重设可由安装导致域切换直接解释。没有重启用户App，不能声称已复现或排除“以后每次普通启动都丢”的独立问题。

AppLanguage.stored读取本bundle持久域，apply set/remove AppleLanguages；TrackStore.init:932–946从UserDefaults.standard恢复5项，updateSetting:962–968异步发布后调用persistIdleSetting:982–992写回原键。未发现代码丢失读写、无条件启动清空或主路径写错键的证据。语言apply后立即创建新进程、idle更新跳main队列是可讨论的时序，但没有独立实证，不建议为防御而改这些产品逻辑或添加无依据synchronize。

## 既有测试证据的正确边界

Tests/ui/run_summary_tests.py:101–114固定备份容器域，:218–234恢复同一路径；最终三语原始cleanup均为preferences_changed=false、preferences_exact_bytes_restored=true。由于对应archive实际无sandbox，这些回执仅证明固定容器plist未改变／已恢复，不能证明测试进程真正使用的非容器域已恢复。所有这些运行还传-AppleLanguages参数，故多语像素不等于语言持久化测试。

没有证据表明这些摘要脚本改了AppleLanguages或idleDisabled，因此不能把测试cleanup缺口直接认定为这两键丢失的另一根因。应修复“按实际运行身份确定真实偏好域或明确隔离”的测试前提，保留历史回执及其原范围，不把原通过功能重跑一遍。

## 必要修复

1. 保留当前项目已有sandbox权限，通过Tools/build_release.py不传--no-sign进行新Release构建，让Xcode按依赖从内到外签两个appex和主App。本机原安装已使用无TeamIdentifier的ad-hoc sandbox签名，可沿用该本机开发方式；这不等于Developer ID发布／公证能力。无需新增证书依赖。
2. 构建／归档／安装守卫必须校验最终产物的签名与期望entitlements，不能只核对文件hash和源码关联。主App需要sandbox=true、network.client=true、files.user-selected.read-write=true；两个扩展各按自己的sandbox-only源码entitlements检查，Release不意外增加get-task-allow。检查Info.plist和codesign Identifier一致；缺少或超出预期权限须拒绝正式安装。
3. 手工补签仅能用于新的隔离派生副本；两个appex先各用自己的entitlements签名，最后主App；签名时不用--deep传播主App权限。优先让Xcode完成。最终签名后再生成新的不可变归档／manifest，保存新exe和全bundlehash、签名回执及原验收构建继承关系；不能悄改已验收archive再继续用旧manifest。
4. 对最终产物运行codesign --verify --deep --strict --verbose=2并检查每个nested bundle签名元数据。只读审计已发现新archive三者严格验证均exit1，原文为“code has no resources but signature indicates they must be present”。旧备份三者严格验证也exit1，但原因是backup bundle的com.apple.FinderInfo附加属性；审计未清xattr，不能声称旧备份严格验证已通过。若自有新生成物有这种附加属性，应仅在该生成物中按授权处理、重新签名后重新归档，保留失败证据。

Apple官方说明entitlements在签名时加入，以及嵌套代码应由内到外签署：[Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)。签名时不要使用--deep，是因为它会把同一组选项／权限施加给不同嵌套代码：[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)。

## 当前用户值的迁回策略

此刻两个新域显式值与旧域相同，恢复sandbox本身即可得到用户当前中文／禁用闲置选择，不必为了“迁移”写任何真实键。最终安装前应先保全编辑、正常关闭App后重新读取白名单，处理审计后用户可能发生的新选择；当前会话不应因调查而关闭。

如果最终读到分歧，只以新的非容器域中实际存在、类型和值域有效的白名单键覆盖旧容器域对应键；false必须当显式值，不能用bool真值判断存在。缺失键不按文件mtime猜测、不删除旧域其他设置、不整plist覆盖。通过系统偏好API逐键写入并核对，以免直接替换plist与cfprefsd缓存脱节。写前保留两域可恢复备份、白名单差异和写后收据；旧域未触及键必须保留。真实写入由root最后阶段处理。

AppleLanguages缺键有特殊歧义：AppLanguage.apply(.system)主动删键，因此“缺失”可能是显式跟随系统，也可能是从未选择；仅凭plist和mtime无法区分。当前新域实际有zh-Hans，没有这项歧义。如果安装前变为缺失而旧域非空，不应无依据自动复活旧语言，也不应声称已知用户选择system；需要已有明确选择记录或用户意图作为清键依据，记录该分支。未来额外保存显式system标记是可选产品设计，当前未发现必须新增它才能修正构建根因。

## 最小后续验证与隔离要求

本审计不复跑已有功能／截图。缺证是“签名产物身份与跨进程设置往返”，因此修复run应预先记明这一原因和以下最小范围。

- 离线静态：三个目标签名严格验证、entitlements精确核对、最终归档hash／manifest一致；安装守卫用现有无sandbox归档作为拒绝样本，以最终正确签名归档作为接受样本。无需重跑全套UI／路线测试。
- 迁移逻辑：仅用临时字典／fixture验证新域true与false都能覆盖、缺失保留、类型错误拒绝、未知键不写、显式system删除不被误认成“从未设”；不对真实plist写测试值。
- 真正的持久化往返需要两个独立进程：先写、正常退出，再新进程读取，覆盖语言和闲置开关。必须使用独立测试bundle ID／专门测试用户或经验证确实隔离的偏好目录，不能把改变通信目录误认为隔离UserDefaults。测试app与正式bundle ID相同时会共享对应域，不得在当前201万点会话旁以此做破坏性设置测试。签名后的测试身份／entitlements、实际域路径、入参和读回值都须留证。
- 若最后使用真实安装后的用户值做只读启动验收，应保存安装前值、确认新App读回一致；不为了测试主动切语言或闲置开关。语言首次启动的界面本地化由启动阶段决定，不能只在App.init之后写AppleLanguages就宣称首启UI已经切换。
- 共享偏好backup/restore必须覆盖真实使用域，且不能与另一个写同域的App并行；通过系统偏好API恢复并确认进程退出。不能只恢复一个假定路径，也不能用参数域强制语言当作持久化通过。

## 主要证据入口

所有普通命令argv/stdout/stderr/退出码保存在本run artifacts/capture/journal.jsonl及commands/目录。重点：

- commands/20261031T011719_app-metadata-pref-whitelist_ed0dd585/stdout.log：旧／新／当前安装元数据及真实白名单6键。
- commands/20261031T011810_build-command-metadata_6d87fcdf/stdout.log：实际no-sign构建argv。
- commands/20261031T011831_signing-build-config_928ccb50/stdout.log、extension-entitlement-source_12c4c736：已有签名配置／权限。
- commands/20261031T011831_final-build-cleanup-raw_25bf8f8b/stdout.log：最终三语原始cleanup继承证据。
- commands/20261031T012000_signature-verification-frozen_1d82d664/stdout.log：三个旧／新产物完整签名检查和真实失败原因。
- commands/20261031T012018_build-release-source_4da57328、archive-validation-source_154346c4：当前构建／归档守卫缺少签名策略检查。
- artifacts/inspect_persistence.py与inspect_signature_validation.py：只读审计脚本；apple-primary-source-search.json：官方来源检索回执。

探索性rg两次因旧假定路径不存在exit2，原始失败已保留；后续定位实际GPXPointViewerApp.swift／Tools/build_release.py，没有覆写失败记录。未执行任何偏好写入或产品测试；本结论不是修复已交付或上线验收通过。

